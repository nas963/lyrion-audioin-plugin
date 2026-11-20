package Plugins::AudioIn::Capture;

# Pomocni proces audioin-capture: JEDINI drzi ulaz (arecord ili fajl za razvoj), puni kruzni bafer
# (Ring.pm) i iz njega istovremeno hrani:
#   - citace (audioin-tap, preko unix socket-a): slusanje na plejerima sa timeshift-om; citac koji
#     ne cita (plejer pauziran) jednostavno stoji na svojoj poziciji u baferu;
#   - snimac: flac koder (nice 10) + .peaks + .json pored snimka;
#   - merac nivoa (dogadjaji na 100 ms dok ga neko trazi).
#
# Pokretanje (Plugin, preko Jobs::spawn; nice 0 jer ne sme da izgubi uzorke, nije RT):
#   perl -I<root> -MPlugins::AudioIn::Capture -e 'Plugins::AudioIn::Capture::main()' -- \
#        --run-dir /run/audioin --ring-sec 600
#
# Protokol (jedna JSON poruka po liniji, ASCII), stdin -> komande, stdout -> dogadjaji:
#   {"cmd":"open","src":"alsa","dev":"hw:CARD=Omega,DEV=0","fmt":"S24_3LE","rate":48000,"channels":2,
#    "left":0,"right":1}                                        -> {"ev":"opened",...} | {"ev":"closed","err":..}
#   {"cmd":"open","src":"file","path":"x.flac|x.wav","loop":1}  (za razvoj i testove, tempom realnog vremena)
#   {"cmd":"close"}                                             -> {"ev":"closed"}
#   {"cmd":"meter","on":1}                                      merac 30 s posle poslednjeg zahteva
#   {"cmd":"rec_start","id":..,"path":"/x/y.flac","preroll":5,"level":5}  -> {"ev":"rec","state":"rec",...}
#   {"cmd":"rec_pause"} {"cmd":"rec_resume"} {"cmd":"rec_stop"} -> {"ev":"rec","state":...}
#   {"cmd":"marker","pos":N|null,"back":s,"kind":"user"}               -> {"ev":"marker","frame":F,...}
#   {"cmd":"status"}                                            -> {"ev":"status",...}
#   {"cmd":"quit"}
# Dogadjaji bez zahteva: {"ev":"tick",...} svake sekunde dok je ulaz otvoren, {"ev":"meter",...},
#   {"ev":"xrun","pos":N}, {"ev":"client","n":N}, {"ev":"error","err":..}, {"ev":"log","msg":..}.
# Citac (tap) se poveze na <run-dir>/tap.sock i posalje jednu liniju: {"start":"live","delay":3}
# (ili {"pos":N}); posle toga dobija samo PCM (stereo S24_3LE). EOF na stdin-u gasi pomocnika
# (snimak u toku se pravilno zatvara).

use strict;
use warnings;

use Errno ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Basename ();
use IO::Socket::UNIX ();
use JSON::PP ();
use POSIX ();
use Socket ();
use Time::HiRes ();

use Plugins::AudioIn::Paths;
use Plugins::AudioIn::Pcm;
use Plugins::AudioIn::Peaks;
use Plugins::AudioIn::Ring;
use Plugins::AudioIn::Tools;

use constant FB            => Plugins::AudioIn::Pcm::FRAME_BYTES;
use constant TICK          => 0.02;     # s, osnovni korak petlje (tempo fajl izvora, tajmeri)
use constant METER_EVERY   => 0.1;      # s
use constant METER_HOLD    => 30;       # s, merac radi ovoliko posle poslednjeg zahteva
use constant STATUS_EVERY  => 1;        # s
use constant JSON_EVERY    => 10;       # s, .json snimka se osvezava (za slucaj pada)
use constant CHUNK_SEC     => 0.1;      # s, najvise ovoliko zvuka po jednom upisu citacu/koderu
use constant FLAC_WAIT     => 30;       # s, najduze cekanje da flac zavrsi posle EOF-a

my $JSON = JSON::PP->new->ascii->canonical;

sub new {
	my ($class, %o) = @_;
	my $self = bless {
		run_dir  => $o{run_dir},
		ring_sec => $o{ring_sec} || 600,
		out      => $o{out} || sub { syswrite(STDOUT, $_[0]) },
		now      => $o{now} || \&Time::HiRes::time,
		src      => undef,
		ring     => undef,
		epoch    => 0,
		clients  => {},
		rec      => undef,
		meter    => { until => 0, last => 0 },
		last_tick => 0,
		quit     => 0,
		children => {},    # pid => { name, on_exit }
	}, $class;
	return $self;
}

# ---------- izlaz ----------

sub emit {
	my ($self, %ev) = @_;
	delete $ev{$_} for grep { !defined $ev{$_} } keys %ev;
	$self->{out}->($JSON->encode(\%ev) . "\n");
	return;
}

sub _log { my ($self, $msg) = @_; $self->emit(ev => 'log', msg => $msg); return }

# ---------- deca ----------

sub _nonblock {
	my ($fh) = @_;
	my $fl = fcntl($fh, F_GETFL, 0);
	fcntl($fh, F_SETFL, $fl | O_NONBLOCK) if defined $fl;
	return $fh;
}

# spawn(argv => [...], stdin => 'pipe'|undef, stdout => 'pipe'|'null', stderr => 'pipe'|'null')
# -> { pid, in, out, err }
sub _spawn {
	my ($self, %a) = @_;
	my @argv = @{ $a{argv} };
	my ($in_r, $in_w, $out_r, $out_w, $err_r, $err_w);
	pipe($in_r, $in_w)   or die "pipe: $!\n" if ($a{stdin} // '') eq 'pipe';
	pipe($out_r, $out_w) or die "pipe: $!\n" if ($a{stdout} // '') eq 'pipe';
	pipe($err_r, $err_w) or die "pipe: $!\n" if ($a{stderr} // '') eq 'pipe';
	my $pid = fork();
	die "fork: $!\n" unless defined $pid;
	if (!$pid) {
		eval {
			POSIX::setpgid(0, 0);
			$SIG{PIPE} = 'DEFAULT';
			$SIG{CHLD} = 'DEFAULT';
			if ($in_r) { close $in_w; open(STDIN, '<&', $in_r) or die; close $in_r }
			else       { open(STDIN, '<', '/dev/null') }
			if ($out_w) { close $out_r; open(STDOUT, '>&', $out_w) or die; close $out_w }
			else        { open(STDOUT, '>', '/dev/null') }
			if ($err_w) { close $err_r; open(STDERR, '>&', $err_w) or die; close $err_w }
			else        { open(STDERR, '>', '/dev/null') }
			exec { $argv[0] } @argv;
		};
		POSIX::_exit(127);
	}
	my %p = (pid => $pid, name => File::Basename::basename($argv[0]));
	if ($in_w)  { close $in_r;  $p{in}  = _nonblock($in_w) }
	if ($out_r) { close $out_w; $p{out} = _nonblock($out_r) }
	if ($err_r) { close $err_w; $p{err} = _nonblock($err_r); $p{errbuf} = '' }
	$self->{children}{$pid} = \%p;
	return \%p;
}

sub _kill_child {
	my ($self, $p, $sig) = @_;
	return unless $p && $p->{pid};
	kill($sig || 'TERM', -$p->{pid});
	kill($sig || 'TERM', $p->{pid});
	return;
}

# Pokupi zavrsenu decu; vraca listu { pid, name, status } (status kao Jobs: kod ili 128+signal).
sub _reap {
	my ($self) = @_;
	my @done;
	while ((my $pid = waitpid(-1, POSIX::WNOHANG())) > 0) {
		my $st = $?;
		my $p = delete $self->{children}{$pid} or next;
		$p->{status} = ($st & 127) ? 128 + ($st & 127) : $st >> 8;
		$p->{exited} = 1;
		push @done, $p;
	}
	return @done;
}

# ---------- izvor ----------

sub cmd_open {
	my ($self, $c) = @_;
	$self->_close_src('reopen') if $self->{src};
	my $src = eval { ($c->{src} // 'alsa') eq 'file' ? $self->_open_file($c) : $self->_open_alsa($c) };
	unless ($src) {
		my $err = $@ || 'open_failed';
		chomp $err;
		$self->emit(ev => 'closed', err => $err);
		return;
	}
	my $same = $self->{ring} && $self->{rate} && $self->{rate} == $src->{rate};
	unless ($same) {
		$self->_drop_clients('rate_changed');
		$self->{ring} = Plugins::AudioIn::Ring->new(frames => int($src->{rate} * $self->{ring_sec}), frame_bytes => FB);
		$self->{epoch}++;
	}
	$self->{rate} = $src->{rate};
	$self->{src} = $src;
	$src->{t0} = $self->{now}->();
	$src->{fed} = 0;
	$self->emit(ev => 'opened', src => $src->{kind}, rate => $src->{rate}, fmt => $src->{fmt},
		channels => $src->{channels}, dev => $src->{dev}, path => $src->{path}, epoch => $self->{epoch},
		head => $self->{ring}->head, ring_sec => $self->{ring_sec});
	return;
}

sub _open_alsa {
	my ($self, $c) = @_;
	my $arecord = Plugins::AudioIn::Tools::find('arecord') or die "no_arecord\n";
	my $dev  = $c->{dev}  or die "no_device\n";
	my $fmt  = $c->{fmt}  || 'S24_3LE';
	my $rate = $c->{rate} || 48000;
	my $ch   = $c->{channels} || 2;
	die "bad_format\n" unless Plugins::AudioIn::Pcm::sample_bytes($fmt);
	my $conv = Plugins::AudioIn::Pcm::converter(fmt => $fmt, channels => $ch, left => $c->{left} // 0,
		right => $c->{right} // ($ch > 1 ? 1 : 0));
	my $p = $self->_spawn(argv => [ $arecord, '-D', $dev, '-f', $fmt, '-r', $rate, '-c', $ch, '-t', 'raw',
		'--buffer-time=2000000', '-q' ], stdout => 'pipe', stderr => 'pipe');
	return { kind => 'alsa', proc => $p, conv => $conv, rate => $rate + 0, fmt => $fmt, channels => $ch + 0,
		dev => $dev, realtime => 0 };
}

# Fajl kao izvor (razvoj bez kartice): .flac preko `flac -d`, .wav direktno; tempom realnog vremena.
sub _open_file {
	my ($self, $c) = @_;
	my $path = $c->{path};
	die "no_file\n" unless defined $path && -r $path;
	my %s = (kind => 'file', path => $path, loop => $c->{loop} ? 1 : 0, realtime => 1);
	if ($path =~ /\.flac\z/i) {
		my $meta = Plugins::AudioIn::Tools::find('metaflac') or die "no_metaflac\n";
		my $info = `'$meta' --show-sample-rate --show-bps --show-channels -- '$path' 2>/dev/null`;
		my ($rate, $bps, $ch) = split /\s+/, $info;
		die "bad_file\n" unless $rate && $bps && $ch;
		$s{rate} = $rate + 0;
		$s{channels} = $ch + 0;
		$s{fmt} = $bps == 16 ? 'S16_LE' : $bps == 24 ? 'S24_3LE' : die "bad_bps\n";
		$s{decoder} = 1;
	}
	elsif ($path =~ /\.wav\z/i) {
		my $h = _wav_header($path) or die "bad_wav\n";
		@s{qw(rate channels fmt data_off data_len)} = @$h{qw(rate channels fmt off len)};
	}
	else {
		die "bad_file\n";
	}
	$s{conv} = Plugins::AudioIn::Pcm::converter(fmt => $s{fmt}, channels => $s{channels},
		left => 0, right => ($s{channels} > 1 ? 1 : 0));
	$s{ifb} = Plugins::AudioIn::Pcm::in_frame_bytes($s{fmt}, $s{channels});
	$self->_start_file(\%s);
	return \%s;
}

sub _start_file {
	my ($self, $s) = @_;
	if ($s->{decoder}) {
		my $flac = Plugins::AudioIn::Tools::find('flac') or die "no_flac\n";
		$s->{proc} = $self->_spawn(argv => [ $flac, '-dcs', '--force-raw-format', '--endian=little',
			'--sign=signed', '--', $s->{path} ], stdout => 'pipe');
	}
	else {
		open(my $fh, '<:raw', $s->{path}) or die "bad_file\n";
		seek($fh, $s->{data_off}, 0);
		$s->{fh} = $fh;
		$s->{left} = $s->{data_len};
	}
	return;
}

sub _wav_header {
	my ($path) = @_;
	open(my $fh, '<:raw', $path) or return undef;
	read($fh, my $h, 12) == 12 or return undef;
	return undef unless substr($h, 0, 4) eq 'RIFF' && substr($h, 8, 4) eq 'WAVE';
	my %r;
	while (read($fh, my $ch, 8) == 8) {
		my ($id, $len) = unpack('a4 V', $ch);
		if ($id eq 'fmt ') {
			read($fh, my $f, $len) == $len or return undef;
			my ($tag, $chans, $rate, undef, undef, $bits) = unpack('v v V V v v', $f);
			$tag = unpack('v', substr($f, 24, 2)) if $tag == 0xFFFE && $len >= 26;
			return undef unless $tag == 1;
			$r{rate} = $rate;
			$r{channels} = $chans;
			$r{fmt} = $bits == 16 ? 'S16_LE' : $bits == 24 ? 'S24_3LE' : $bits == 32 ? 'S32_LE' : return undef;
		}
		elsif ($id eq 'data') {
			$r{off} = tell($fh);
			$r{len} = $len;
			last;
		}
		else {
			seek($fh, $len + ($len & 1), 1);
		}
	}
	return $r{fmt} && defined $r{off} ? \%r : undef;
}

sub cmd_close {
	my ($self) = @_;
	$self->_close_src(undef);
	return;
}

sub _close_src {
	my ($self, $err) = @_;
	my $s = delete $self->{src} or return;
	if (my $p = $s->{proc}) {
		$self->_kill_child($p);
		close $p->{out} if $p->{out};
		close $p->{err} if $p->{err};
	}
	close $s->{fh} if $s->{fh};
	# snimak u toku se zavrsava na poslednjem primljenom uzorku
	$self->_rec_stop_at($self->{ring}->head, $err || q(closed)) if $self->{rec} && ($err // q()) ne q(reopen);
	$self->emit(ev => 'closed', err => $err) unless ($err // '') eq 'reopen';
	return;
}

# Primljeni uzorci (u formatu izvora) -> ring, merac.
sub _ingest {
	my ($self, $bytes) = @_;
	my $s24 = $self->{src}{conv}->($bytes);
	return unless length $s24;
	$self->{ring}->write($s24);
	if ($self->{meter}{until} > $self->{now}->()) {
		my $l = Plugins::AudioIn::Pcm::levels($s24);
		my $m = $self->{meter};
		$m->{n}  += $l->{frames};
		$m->{clip} += $l->{clip};
		for my $i (0, 1) {
			$m->{pk}[$i] = $l->{peak}[$i] if $l->{peak}[$i] > ($m->{pk}[$i] // 0);
			$m->{ss}[$i] += $l->{sumsq}[$i];
		}
	}
	return;
}

sub _read_src {
	my ($self) = @_;
	my $s = $self->{src} or return;
	my $p = $s->{proc};
	if ($s->{kind} eq 'alsa' || !$s->{realtime}) {
		while (1) {
			my $n = sysread($p->{out}, my $buf, 65536);
			if (!defined $n) {
				return if $!{EAGAIN} || $!{EWOULDBLOCK};
				next if $!{EINTR};
				return $self->_src_eof;
			}
			return $self->_src_eof if $n == 0;
			$self->_ingest($buf);
		}
	}
	return;
}

# Fajl izvor: dozvoljeno je onoliko frejmova koliko je proteklo realnog vremena.
sub _pace_file {
	my ($self) = @_;
	my $s = $self->{src} or return;
	return unless $s->{kind} eq 'file';
	my $due = int(($self->{now}->() - $s->{t0}) * $s->{rate}) - $s->{fed};
	return if $due <= 0;
	my $want = $due * $s->{ifb};
	my $got = '';
	if ($s->{fh}) {
		$want = $s->{left} if $want > $s->{left};
		read($s->{fh}, $got, $want) if $want > 0;
		$s->{left} -= length $got;
	}
	elsif ($s->{proc}) {
		while (length($got) < $want) {
			my $n = sysread($s->{proc}{out}, my $buf, $want - length $got);
			last if !defined $n && ($!{EAGAIN} || $!{EWOULDBLOCK});
			next if !defined $n && $!{EINTR};
			if (!$n) { $s->{eof} = 1; last }
			$got .= $buf;
		}
	}
	$s->{fed} += int(length($got) / $s->{ifb});
	$self->_ingest($got) if length $got;
	if (($s->{fh} && $s->{left} <= 0) || $s->{eof}) {
		if ($s->{loop}) {
			close $s->{fh} if $s->{fh};
			if ($s->{proc}) { close $s->{proc}{out}; $self->_kill_child($s->{proc}) }
			delete @$s{qw(fh proc eof)};
			$self->_start_file($s);
		}
		else {
			$self->_src_eof;
		}
	}
	return;
}

sub _src_eof {
	my ($self) = @_;
	my $s = $self->{src} or return;
	my $err = $s->{kind} eq 'alsa' ? ($s->{last_err} || 'device_lost') : 'eof';
	$self->_close_src($err);
	return;
}

sub _read_src_err {
	my ($self) = @_;
	my $s = $self->{src} or return;
	my $p = $s->{proc} or return;
	while (1) {
		my $n = sysread($p->{err}, my $buf, 4096);
		last if !defined $n || $n == 0;
		$p->{errbuf} .= $buf;
	}
	while ($p->{errbuf} =~ s/\A([^\n]*)\n//) {
		my $line = $1;
		if ($line =~ /overrun/i) {
			my $pos = $self->{ring}->head;
			$self->emit(ev => 'xrun', pos => $pos);
			push @{ $self->{rec}{xruns} }, $self->_rec_file_pos($pos) if $self->{rec} && !$self->{rec}{paused};
		}
		elsif (length $line) {
			# prva greska je uzrok; posle nje arecord ispisuje detalje ("Available formats:", "- S16_LE")
			$s->{last_err} //= _arecord_err($line) unless $line =~ /^\s*-\s|^Available /;
			$self->_log("arecord: $line");
		}
	}
	return;
}

sub _arecord_err {
	my ($line) = @_;
	return 'busy'       if $line =~ /busy/i;
	return 'no_device'  if $line =~ /No such (file|device)|cannot find card|Cannot get card index|Unknown PCM/i;
	return 'permission' if $line =~ /Permission denied/i;
	return 'bad_format' if $line =~ /format|rate|channels|Invalid argument/i;
	return 'device_error';
}

# ---------- citaci (tap) ----------

sub _listen {
	my ($self) = @_;
	my $dir = $self->{run_dir} or die "no_run_dir\n";
	my $path = "$dir/" . Plugins::AudioIn::Paths::SOCK_NAME;
	unlink $path;
	my $sock = IO::Socket::UNIX->new(Type => Socket::SOCK_STREAM(), Local => $path, Listen => 8)
		or die "socket $path: $!\n";
	chmod 0660, $path;
	_nonblock($sock);
	$self->{listen} = $sock;
	$self->{sock_path} = $path;
	return;
}

sub _accept {
	my ($self) = @_;
	while (my $c = $self->{listen}->accept) {
		_nonblock($c);
		$self->{clients}{ fileno $c } = { fh => $c, hello => '', pos => undef, out => '', since => $self->{now}->() };
	}
	return;
}

sub _client_read {
	my ($self, $cl) = @_;
	my $n = sysread($cl->{fh}, my $buf, 4096);
	if (defined $n && $n == 0) { return $self->_drop_client($cl) }
	return unless defined $n;
	return if defined $cl->{pos};    # posle pozdrava citac nista ne salje
	$cl->{hello} .= $buf;
	return unless $cl->{hello} =~ /\n/;
	my ($line) = split /\n/, $cl->{hello};
	my $h = eval { $JSON->decode($line) } || {};
	my $ring = $self->{ring};
	unless ($ring && $self->{src}) {
		return $self->_drop_client($cl);    # ulaz nije otvoren: plejer dobija kraj stream-a
	}
	if (defined $h->{pos}) {
		$cl->{pos} = $h->{pos};
	}
	else {
		my $d = $h->{delay} // 3;
		$cl->{pos} = $ring->head - int($d * $self->{rate});
	}
	$cl->{pos} = $ring->tail if $cl->{pos} < $ring->tail;
	$cl->{pos} = $ring->head if $cl->{pos} > $ring->head;
	$cl->{start} = $cl->{pos};
	$self->emit(ev => 'client', n => $self->_ready_clients, start => $cl->{pos}, epoch => $self->{epoch});
	return;
}

sub _ready_clients { my ($self) = @_; return scalar grep { defined $_->{pos} } values %{ $self->{clients} } }

sub _client_write {
	my ($self, $cl) = @_;
	my $ring = $self->{ring} or return;
	unless (length $cl->{out}) {
		my ($d, $from) = $ring->read($cl->{pos}, int($self->{rate} * CHUNK_SEC));
		if ($from > $cl->{pos}) {
			$self->emit(ev => 'client_skip', lost => $from - $cl->{pos});
		}
		return unless length $d;
		$cl->{out} = $d;
		$cl->{pos} = $from + length($d) / FB;
	}
	local $SIG{PIPE} = 'IGNORE';
	my $n = syswrite($cl->{fh}, $cl->{out});
	if (!defined $n) {
		return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
		return $self->_drop_client($cl);
	}
	substr($cl->{out}, 0, $n, '');
	return;
}

sub _drop_client {
	my ($self, $cl) = @_;
	my $fn = fileno $cl->{fh};
	close $cl->{fh};
	delete $self->{clients}{$fn} if defined $fn;
	$self->emit(ev => 'client', n => $self->_ready_clients);
	return;
}

sub _drop_clients {
	my ($self, $why) = @_;
	close $_->{fh} for values %{ $self->{clients} };
	my $had = %{ $self->{clients} } ? 1 : 0;
	$self->{clients} = {};
	$self->emit(ev => 'client', n => 0, why => $why) if $had;
	return;
}

# ---------- snimanje ----------

sub cmd_rec_start {
	my ($self, $c) = @_;
	return $self->emit(ev => 'rec', state => 'error', err => 'busy', id => $c->{id}) if $self->{rec};
	return $self->emit(ev => 'rec', state => 'error', err => 'not_open', id => $c->{id}) unless $self->{src};
	my $path = $c->{path};
	return $self->emit(ev => 'rec', state => 'error', err => 'no_path', id => $c->{id}) unless defined $path && $path =~ /\.flac\z/;
	my $flac = Plugins::AudioIn::Tools::find('flac') or return $self->emit(ev => 'rec', state => 'error', err => 'no_flac', id => $c->{id});
	my $ring = $self->{ring};
	my $pre = $c->{preroll} // 5;
	my $start = $ring->head - int($pre * $self->{rate});
	$start = $ring->tail if $start < $ring->tail;
	my $level = defined $c->{level} && $c->{level} =~ /^[0-8]\z/ ? $c->{level} : 5;
	(my $base = $path) =~ s/\.flac\z//;
	my @nice = ('nice', '-n', '10');
	my $p = eval {
		$self->_spawn(argv => [ (Plugins::AudioIn::Tools::find('nice') ? @nice : ()), $flac, '--silent', "-$level",
			'--force-raw-format', '--endian=little', '--sign=signed', '--channels=2', '--bps=24',
			"--sample-rate=$self->{rate}", '-f', '-o', "$path.part", '-' ], stdin => 'pipe', stderr => 'pipe');
	};
	return $self->emit(ev => 'rec', state => 'error', err => 'spawn', id => $c->{id}) unless $p;
	open(my $pk, '>:raw', "$base.peaks.part") or do {
		$self->_kill_child($p);
		return $self->emit(ev => 'rec', state => 'error', err => 'peaks_open', id => $c->{id});
	};
	$self->{rec} = {
		id       => $c->{id},
		path     => $path,
		base     => $base,
		proc     => $p,
		peaks    => Plugins::AudioIn::Peaks->new(rate => $self->{rate}),
		peaks_fh => $pk,
		pos      => $start,      # sledeci frejm iz ringa za koder
		stop_at  => undef,       # kraj (frejm u ringu) posle Stop-a
		paused   => 0,
		frames   => 0,           # frejmova poslato koderu (= duzina fajla)
		segments => [ { from => $start, to => undef, file => 0 } ],
		markers  => [],
		xruns    => [],
		clip_windows => 0,
		out      => '',
		started  => time,
		epoch    => $self->{epoch},
		rate     => $self->{rate},
		preroll  => ($ring->head - $start) / $self->{rate},
	};
	$self->_rec_json;
	$self->emit(ev => 'rec', state => 'rec', id => $c->{id}, path => $path, start => $start,
		preroll => $self->{rec}{preroll}, rate => $self->{rate});
	return;
}

# Frejm u ringu -> frejm u fajlu (preko segmenata; pozicija u pauzi -> pocetak sledeceg segmenta).
sub _rec_file_pos {
	my ($self, $pos) = @_;
	my $r = $self->{rec} or return undef;
	my $file = 0;
	for my $s (@{ $r->{segments} }) {
		my $to = $s->{to} // $self->{ring}->head;
		return $s->{file} if $pos < $s->{from};
		return $s->{file} + ($pos - $s->{from}) if $pos <= $to;
		$file = $s->{file} + ($to - $s->{from});
	}
	return $file;
}

sub cmd_rec_pause {
	my ($self) = @_;
	my $r = $self->{rec} or return;
	return if $r->{paused} || defined $r->{stop_at};
	my $at = $self->{ring}->head;
	$r->{segments}[-1]{to} = $at;
	$r->{paused} = 1;
	$self->emit(ev => 'rec', state => 'paused', id => $r->{id}, frames => $self->_rec_planned);
	return;
}

sub cmd_rec_resume {
	my ($self) = @_;
	my $r = $self->{rec} or return;
	return unless $r->{paused} && !defined $r->{stop_at};
	my $file = $self->_rec_planned;
	my $at = $self->{ring}->head;
	push @{ $r->{segments} }, { from => $at, to => undef, file => $file };
	push @{ $r->{markers} }, { frame => $file, kind => 'pause' };
	$r->{paused} = 0;
	$self->_rec_json;
	$self->emit(ev => 'rec', state => 'rec', id => $r->{id}, frames => $file);
	$self->emit(ev => 'marker', id => $r->{id}, frame => $file, kind => 'pause');
	return;
}

# Ukupna duzina snimka po segmentima (sta ce biti u fajlu kad koder stigne).
sub _rec_planned {
	my ($self) = @_;
	my $r = $self->{rec} or return 0;
	my $s = $r->{segments}[-1];
	return $s->{file} + (($s->{to} // $self->{ring}->head) - $s->{from});
}

sub cmd_rec_stop {
	my ($self) = @_;
	my $r = $self->{rec} or return;
	return if defined $r->{stop_at};
	$self->_rec_stop_at($self->{ring}->head, undef);
	return;
}

sub _rec_stop_at {
	my ($self, $at, $why) = @_;
	my $r = $self->{rec} or return;
	return if defined $r->{stop_at};
	$r->{segments}[-1]{to} //= $at;
	$r->{stop_at} = 1;
	$r->{why} = $why;
	$self->emit(ev => 'rec', state => 'stopping', id => $r->{id}, frames => $self->_rec_planned, why => $why);
	return;
}

sub cmd_marker {
	my ($self, $c) = @_;
	my $r = $self->{rec} or return $self->emit(ev => 'error', err => 'not_recording');
	my $pos = defined $c->{pos} ? $c->{pos} : $self->{ring}->head - int(($c->{back} || 0) * $self->{rate});
	my $frame = $self->_rec_file_pos($pos);
	my $m = { frame => $frame, kind => $c->{kind} || 'user' };
	push @{ $r->{markers} }, $m;
	$self->_rec_json;
	$self->emit(ev => 'marker', id => $r->{id}, frame => $frame, kind => $m->{kind}, pos => $pos);
	return;
}

# Segment u kom je sledeci frejm za koder; preskace pauze. undef = nema vise za sada.
sub _rec_next_range {
	my ($self) = @_;
	my $r = $self->{rec};
	my $head = $self->{ring}->head;
	for my $s (@{ $r->{segments} }) {
		my $to = $s->{to} // $head;
		next if $r->{pos} >= $to;
		$r->{pos} = $s->{from} if $r->{pos} < $s->{from};
		return ($r->{pos}, $to) if $r->{pos} < $to;
	}
	return;
}

sub _rec_feed {
	my ($self) = @_;
	my $r = $self->{rec} or return;
	my $p = $r->{proc};
	return unless $p->{in};
	unless (length $r->{out}) {
		my ($from, $to) = $self->_rec_next_range;
		if (!defined $from) {
			$self->_rec_finish_input if $r->{stop_at};
			return;
		}
		my $max = $to - $from;
		my $lim = int($self->{rate} * CHUNK_SEC);
		$max = $lim if $max > $lim;
		my ($d, $got) = $self->{ring}->read($from, $max);
		if ($got > $from) {
			$r->{lost} += $got - $from;    # koder je kasnio vise od ringa (ne bi smelo)
			$self->emit(ev => 'error', err => 'rec_overrun', lost => $got - $from);
		}
		return unless length $d;
		my $nf = length($d) / FB;
		$r->{pos} = $got + $nf;
		$r->{frames} += $nf;
		$r->{out} = $d;
		my $pk = $r->{peaks}->add($d);
		if (length $pk) {
			print { $r->{peaks_fh} } $pk;
			for (my $i = 0; $i < length $pk; $i += 6) {
				my ($a, $b) = unpack('v2', substr($pk, $i, 4));
				$r->{clip_windows}++ if $a >= 32767 || $b >= 32767;
			}
		}
	}
	local $SIG{PIPE} = 'IGNORE';
	my $n = syswrite($p->{in}, $r->{out});
	if (!defined $n) {
		return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
		$self->_log("flac stdin: $!");
		close $p->{in};
		delete $p->{in};
		$r->{failed} = 'encoder';
		return;
	}
	substr($r->{out}, 0, $n, '');
	return;
}

sub _rec_finish_input {
	my ($self) = @_;
	my $r = $self->{rec};
	my $p = $r->{proc};
	return unless $p->{in};
	close $p->{in};
	delete $p->{in};
	print { $r->{peaks_fh} } $r->{peaks}->flush;
	close $r->{peaks_fh};
	$r->{wait_until} = $self->{now}->() + FLAC_WAIT;
	return;
}

# Posle izlaska kodera: preimenovanje .part fajlova, .json, dogadjaj.
sub _rec_done {
	my ($self, $status) = @_;
	my $r = delete $self->{rec} or return;
	my $ok = defined $status && $status == 0 && !$r->{failed};
	if ($ok) {
		rename("$r->{path}.part", $r->{path}) or $ok = 0;
		rename("$r->{base}.peaks.part", "$r->{base}.peaks");
	}
	$r->{done} = 1;
	$r->{ok} = $ok ? 1 : 0;
	$self->_rec_json($r);
	$self->emit(ev => 'rec', state => 'stopped', id => $r->{id}, ok => $r->{ok}, frames => $r->{frames},
		path => $ok ? $r->{path} : "$r->{path}.part", why => $r->{why} || $r->{failed}, status => $status);
	return;
}

sub _rec_json {
	my ($self, $r) = @_;
	$r ||= $self->{rec} or return;
	my %j = (
		id => $r->{id}, rate => $r->{rate}, bits => 24, channels => 2, frames => $r->{frames},
		planned => ($self->{rec} && $self->{rec} == $r) ? $self->_rec_planned : $r->{frames},
		segments => [ map { { from => $_->{from}, to => $_->{to}, file => $_->{file} } } @{ $r->{segments} } ],
		markers => $r->{markers}, xruns => $r->{xruns}, clip_windows => $r->{clip_windows},
		peaks_window_ms => Plugins::AudioIn::Peaks::WINDOW_MS, started => $r->{started},
		preroll => $r->{preroll}, epoch => $r->{epoch}, lost => $r->{lost} || 0,
		($r->{done} ? (done => 1, ok => $r->{ok}, why => $r->{why}) : ()),
	);
	if (open(my $fh, '>', "$r->{base}.json.tmp")) {
		print $fh JSON::PP->new->canonical->pretty->encode(\%j);
		close $fh;
		rename("$r->{base}.json.tmp", "$r->{base}.json");
	}
	$r->{json_at} = $self->{now}->();
	return;
}

# ---------- merac i status ----------

sub cmd_meter {
	my ($self, $c) = @_;
	my $m = $self->{meter};
	$m->{until} = $c->{on} ? $self->{now}->() + METER_HOLD : 0;
	return;
}

sub _meter_tick {
	my ($self) = @_;
	my $m = $self->{meter};
	my $now = $self->{now}->();
	return unless $m->{until} > $now && $now - $m->{last} >= METER_EVERY;
	$m->{last} = $now;
	return unless $m->{n};
	$self->emit(ev => 'meter', pos => $self->{ring} ? $self->{ring}->head : 0,
		pk => [ map { Plugins::AudioIn::Pcm::dbfs($m->{pk}[$_]) } 0, 1 ],
		rms => [ map { Plugins::AudioIn::Pcm::rms_dbfs($m->{ss}[$_], $m->{n}) } 0, 1 ],
		clip => $m->{clip} || 0);
	@$m{qw(n clip)} = (0, 0);
	$m->{pk} = [ 0, 0 ];
	$m->{ss} = [ 0, 0 ];
	return;
}

sub status {
	my ($self) = @_;
	my $ring = $self->{ring};
	my $r = $self->{rec};
	my $head = $ring ? $ring->head : 0;
	return (
		open => $self->{src} ? 1 : 0,
		src  => $self->{src} ? $self->{src}{kind} : undef,
		rate => $self->{rate},
		epoch => $self->{epoch},
		head => $head,
		tail => $ring ? $ring->tail : 0,
		ring_sec => $self->{ring_sec},
		clients => [ map { { pos => $_->{pos}, lag => ($head - $_->{pos}) / ($self->{rate} || 1) } }
			grep { defined $_->{pos} } values %{ $self->{clients} } ],
		rec => $r ? { id => $r->{id}, state => (defined $r->{stop_at} ? 'stopping' : $r->{paused} ? 'paused' : 'rec'),
			frames => $self->_rec_planned, written => $r->{frames}, markers => scalar @{ $r->{markers} },
			xruns => scalar @{ $r->{xruns} }, clip_windows => $r->{clip_windows}, path => $r->{path} } : undef,
	);
}

sub cmd_status { my ($self) = @_; $self->emit(ev => 'status', $self->status); return }

sub _status_tick {
	my ($self) = @_;
	my $now = $self->{now}->();
	return unless $now - $self->{last_tick} >= STATUS_EVERY;
	$self->{last_tick} = $now;
	$self->emit(ev => 'tick', $self->status) if $self->{src} || $self->{rec};
	my $r = $self->{rec};
	$self->_rec_json if $r && !$r->{wait_until} && $now - ($r->{json_at} || 0) >= JSON_EVERY;
	return;
}

# ---------- komande ----------

my %CMD = (
	open       => \&cmd_open,
	close      => \&cmd_close,
	meter      => \&cmd_meter,
	rec_start  => \&cmd_rec_start,
	rec_pause  => \&cmd_rec_pause,
	rec_resume => \&cmd_rec_resume,
	rec_stop   => \&cmd_rec_stop,
	marker     => \&cmd_marker,
	status     => \&cmd_status,
	quit       => sub { $_[0]{quit} = 1 },
);

sub command {
	my ($self, $line) = @_;
	my $c = eval { $JSON->decode($line) };
	return $self->emit(ev => 'error', err => 'bad_json') unless ref $c eq 'HASH';
	my $f = $CMD{ $c->{cmd} // '' } or return $self->emit(ev => 'error', err => 'bad_cmd');
	eval { $f->($self, $c); 1 } or do { my $e = $@; chomp $e; $self->emit(ev => 'error', err => 'exception', msg => $e) };
	return;
}

# ---------- petlja ----------

sub run {
	my ($self, %o) = @_;
	my $in = $o{stdin} || \*STDIN;
	_nonblock($in);
	my $inbuf = '';
	my $in_eof = 0;
	$self->_listen if $self->{run_dir};
	$SIG{PIPE} = 'IGNORE';
	$SIG{TERM} = sub { $self->{quit} = 1 };

	while (1) {
		if ($self->{quit} || $in_eof) {
			# zavrsi snimak, pa izadji
			$self->_close_src(undef) if $self->{src};
			last unless $self->{rec};
			$self->_rec_stop_at($self->{ring}->head, 'quit') unless defined $self->{rec}{stop_at};
		}

		my ($rin, $win) = ('', '');
		vec($rin, fileno($in), 1) = 1 unless $in_eof;
		vec($rin, fileno($self->{listen}), 1) = 1 if $self->{listen};
		my $s = $self->{src};
		if ($s && $s->{proc}) {
			vec($rin, fileno($s->{proc}{out}), 1) = 1 if $s->{proc}{out} && !$s->{realtime};
			vec($rin, fileno($s->{proc}{err}), 1) = 1 if $s->{proc}{err};
		}
		my $head = $self->{ring} ? $self->{ring}->head : 0;
		for my $cl (values %{ $self->{clients} }) {
			vec($rin, fileno($cl->{fh}), 1) = 1;
			vec($win, fileno($cl->{fh}), 1) = 1 if defined $cl->{pos} && (length $cl->{out} || $cl->{pos} < $head);
		}
		my $r = $self->{rec};
		if ($r && $r->{proc}{in}) {
			vec($win, fileno($r->{proc}{in}), 1) = 1 if length $r->{out} || defined $self->_peek_rec;
		}
		if ($r && $r->{proc}{err}) {
			vec($rin, fileno($r->{proc}{err}), 1) = 1;
		}

		my $n = select(my $rout = $rin, my $wout = $win, undef, TICK);
		if ($n && $n > 0) {
			if (!$in_eof && vec($rout, fileno($in), 1)) {
				my $got = sysread($in, my $buf, 65536);
				if (defined $got && $got == 0) { $in_eof = 1 }
				elsif (defined $got) {
					$inbuf .= $buf;
					while ($inbuf =~ s/\A([^\n]*)\n//) { $self->command($1) if length $1 }
				}
			}
			$self->_accept if $self->{listen} && vec($rout, fileno($self->{listen}), 1);
			$s = $self->{src};
			if ($s && $s->{proc}) {
				$self->_read_src_err if $s->{proc}{err} && vec($rout, fileno($s->{proc}{err}), 1);
				$s = $self->{src};
				$self->_read_src if $s && $s->{proc} && $s->{proc}{out} && !$s->{realtime} && vec($rout, fileno($s->{proc}{out}), 1);
			}
			for my $cl (values %{ $self->{clients} }) {
				next unless defined fileno $cl->{fh};
				my $fn = fileno $cl->{fh};
				if (vec($rout, $fn, 1)) { $self->_client_read($cl); next unless defined fileno $cl->{fh} }
				$self->_client_write($cl) if vec($wout, $fn, 1);
			}
			$r = $self->{rec};
			if ($r && $r->{proc}{in} && vec($wout, fileno($r->{proc}{in}), 1)) { $self->_rec_feed }
			if ($r && $r->{proc}{err} && vec($rout, fileno($r->{proc}{err}), 1)) {
				my $got = sysread($r->{proc}{err}, my $buf, 4096);
				if (defined $got && $got > 0) { $self->_log("flac: $_") for grep { length } split /\n/, $buf }
				elsif (defined $got) { close $r->{proc}{err}; delete $r->{proc}{err} }
			}
		}

		$self->_pace_file;
		$r = $self->{rec};
		$self->_rec_feed if $r && $r->{stop_at} && !length $r->{out} && !defined $self->_peek_rec && $r->{proc}{in};

		for my $p ($self->_reap) {
			if ($self->{rec} && $self->{rec}{proc}{pid} == $p->{pid}) {
				$self->_rec_done($p->{status});
			}
			elsif ($self->{src} && $self->{src}{proc} && $self->{src}{proc}{pid} == $p->{pid} && $self->{src}{kind} eq 'alsa') {
				$self->_read_src_err if $self->{src}{proc}{err};
				$self->_read_src;    # ostatak iz pipe-a pa EOF
				$self->_src_eof if $self->{src};
			}
		}
		$r = $self->{rec};
		if ($r && $r->{wait_until} && $self->{now}->() > $r->{wait_until}) {
			$self->_kill_child($r->{proc}, 'KILL');
			$r->{failed} = 'encoder_timeout';
		}

		$self->_meter_tick;
		$self->_status_tick;
		last if ($self->{quit} || $in_eof) && !$self->{rec};
	}
	$self->_drop_clients('quit');
	if ($self->{listen}) { close $self->{listen}; unlink $self->{sock_path} }
	return;
}

# Da li koder ima sta da dobije (bez pomeranja pozicije).
sub _peek_rec {
	my ($self) = @_;
	my $r = $self->{rec} or return undef;
	my $head = $self->{ring}->head;
	for my $s (@{ $r->{segments} }) {
		my $to = $s->{to} // $head;
		return 1 if $r->{pos} < $to && $s->{from} < $to;
	}
	return undef;
}

sub main {
	my %o = (ring_sec => 600);
	my @a = @ARGV;
	while (@a) {
		my $k = shift @a;
		if    ($k eq '--run-dir')  { $o{run_dir}  = shift @a }
		elsif ($k eq '--ring-sec') { $o{ring_sec} = shift @a }
	}
	$o{run_dir} //= Plugins::AudioIn::Paths::pick_run_dir();
	$| = 1;
	my $self = __PACKAGE__->new(%o);
	$self->emit(ev => 'ready', run_dir => $o{run_dir}, pid => $$);
	$self->run;
	return;
}

1;
