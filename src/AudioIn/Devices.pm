package Plugins::AudioIn::Devices;

# Ulazni (capture) uredjaji iz /proc/asound, bez otvaranja uredjaja (zauzeta kartica se i dalje vidi).
# Cist Perl.
#
# list(root => '/proc/asound') -> [ {
#     dev     => 'hw:CARD=Omega,DEV=0',   ime kartice, ne indeks (USB indeks se menja posle restarta)
#     card    => 1, card_id => 'Omega', card_name => 'Lexicon Omega', device => 0, pcm_name => 'USB Audio',
#     usb     => 1|0,
#     formats => ['S16_LE', 'S24_3LE'], rates => [44100, 48000], channels => [2]   (USB: iz streamN;
#                                                                                   ostalo: prazno = nepoznato)
#     label   => 'Lexicon Omega - USB Audio (hw:CARD=Omega,DEV=0)',
# } ]
# best_format(\@formats) -> najbolji 24-bitni format koji kartica ima (S24_3LE > S32_LE > S24_LE > S16_LE)

use strict;
use warnings;

our @FORMAT_ORDER = qw(S24_3LE S32_LE S24_LE S16_LE);
our @COMMON_RATES = (44100, 48000, 88200, 96000, 176400, 192000);

sub _slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $d = <$fh>;
	close $fh;
	return $d;
}

# /proc/asound/cards -> { indeks => { id, name } }
sub parse_cards {
	my ($text) = @_;
	my %c;
	for my $line (split /\n/, $text // '') {
		next unless $line =~ /^\s*(\d+)\s+\[([^\]]*?)\s*\]:\s*(\S+)\s+-\s+(.*?)\s*$/;
		$c{$1} = { id => $2, driver => $3, name => $4 };
	}
	return \%c;
}

# /proc/asound/pcm -> [ { card, device, name, capture } ]
sub parse_pcm {
	my ($text) = @_;
	my @p;
	for my $line (split /\n/, $text // '') {
		next unless $line =~ /^(\d+)-(\d+):\s*([^:]*?)\s*:\s*([^:]*?)\s*:(.*)$/;
		my ($card, $dev, $id, $name, $rest) = ($1 + 0, $2 + 0, $3, $4, $5);
		push @p, { card => $card, device => $dev, name => $name, capture => ($rest =~ /capture\s+\d+/ ? 1 : 0) };
	}
	return \@p;
}

# /proc/asound/cardN/streamM (USB) -> { formats, rates, channels } za Capture deo.
sub parse_stream {
	my ($text) = @_;
	my (%f, %r, %c);
	my $in = 0;
	for my $line (split /\n/, $text // '') {
		if ($line =~ /^(Playback|Capture):/) { $in = $1 eq 'Capture'; next }
		next unless $in;
		if ($line =~ /^\s+Format:\s*(\S+)/) { $f{$1} = 1 }
		elsif ($line =~ /^\s+Channels:\s*(\d+)/) { $c{$1} = 1 }
		elsif ($line =~ /^\s+Rates:\s*(.+)$/) {
			my $v = $1;
			if ($v =~ /^(\d+)\s*-\s*(\d+)/) {    # opseg (continuous): ponudi uobicajene unutar njega
				my ($lo, $hi) = ($1, $2);
				$r{$_} = 1 for grep { $_ >= $lo && $_ <= $hi } @COMMON_RATES;
			}
			else { $r{$_} = 1 for $v =~ /(\d+)/g }
		}
	}
	return {
		formats  => [ grep { $f{$_} } @FORMAT_ORDER, sort grep { my $x = $_; !grep { $_ eq $x } @FORMAT_ORDER } keys %f ],
		rates    => [ sort { $a <=> $b } keys %r ],
		channels => [ sort { $a <=> $b } keys %c ],
	};
}

sub list {
	my (%o) = @_;
	my $root = $o{root} // '/proc/asound';
	my $cards = parse_cards(_slurp("$root/cards"));
	my @out;
	for my $p (@{ parse_pcm(_slurp("$root/pcm")) }) {
		next unless $p->{capture};
		my $c = $cards->{ $p->{card} } or next;
		my $st = _slurp("$root/card$p->{card}/stream$p->{device}");
		my $caps = defined $st ? parse_stream($st) : { formats => [], rates => [], channels => [] };
		my $dev = "hw:CARD=$c->{id},DEV=$p->{device}";
		push @out, {
			dev => $dev, card => $p->{card}, card_id => $c->{id}, card_name => $c->{name}, device => $p->{device},
			pcm_name => $p->{name}, usb => ($c->{driver} eq 'USB-Audio' ? 1 : 0), %$caps,
			label => "$c->{name} - $p->{name} ($dev)",
		};
	}
	return \@out;
}

# `arecord --dump-hw-params` -> { formats, rates, channels } (za kartice bez stream fajla, npr. HDA).
sub parse_hw_params {
	my ($text) = @_;
	my (@f, @r, @c);
	for my $line (split /\n/, $text // '') {
		if ($line =~ /^FORMAT:\s+(.+)$/) {
			my %have = map { $_ => 1 } split ' ', $1;
			@f = ((grep { $have{$_} } @FORMAT_ORDER), sort grep { my $x = $_; !grep { $_ eq $x } @FORMAT_ORDER } keys %have);
		}
		elsif ($line =~ /^RATE:\s+(.+)$/) {
			my $v = $1;
			if ($v =~ /^[\[(]\s*(\d+)\s+(\d+)\s*[\])]/) { my ($lo, $hi) = ($1, $2); @r = grep { $_ >= $lo && $_ <= $hi } @COMMON_RATES }
			else { @r = sort { $a <=> $b } $v =~ /(\d+)/g }
		}
		elsif ($line =~ /^CHANNELS:\s+(.+)$/) {
			my $v = $1;
			if ($v =~ /^\[\s*(\d+)\s+(\d+)\s*\]/) { @c = ($1 .. ($2 > 32 ? 32 : $2)) }
			else { @c = $v =~ /(\d+)/g }
		}
	}
	return { formats => \@f, rates => \@r, channels => [ map { $_ + 0 } @c ] };
}

# Ispituje uredjaj (kratko ga otvara): arecord --dump-hw-params, najvise ~3 s. Zauzet uredjaj -> undef.
# $run: sub(@argv) -> izlaz (za testove); podrazumevano pokretanje sa rokom.
sub probe {
	my ($dev, %o) = @_;
	my $arecord = $o{arecord} or return undef;
	my @argv = ($arecord, '-D', $dev, '--dump-hw-params', '-d', '1', '-t', 'raw', '/dev/null');
	my $out = $o{run} ? $o{run}->(@argv) : _run_limited(3, @argv);
	return undef unless defined $out && $out =~ /^FORMAT:/m;
	return parse_hw_params($out);
}

sub _run_limited {
	my ($secs, @argv) = @_;
	pipe(my $r, my $w) or return undef;
	my $pid = fork;
	return undef unless defined $pid;
	if (!$pid) {
		eval {
			close $r;
			for my $h (\*STDOUT, \*STDERR) { untie *$h if tied *$h }
			open(STDOUT, '>&', $w); open(STDERR, '>&', $w); open(STDIN, '<', '/dev/null');
			exec { $argv[0] } @argv;
		};
		require POSIX;
		POSIX::_exit(127);
	}
	close $w;
	my ($out, $end) = ('', time + $secs);
	while (time <= $end) {
		my $rin = '';
		vec($rin, fileno($r), 1) = 1;
		my $n = select(my $rout = $rin, undef, undef, 0.2);
		next unless $n && $n > 0;
		my $got = sysread($r, my $buf, 8192);
		last unless $got;
		$out .= $buf;
	}
	close $r;
	kill 'KILL', $pid;
	waitpid($pid, 0);
	return $out;
}

sub best_format {
	my ($formats) = @_;
	my %have = map { $_ => 1 } @{ $formats || [] };
	for (@FORMAT_ORDER) { return $_ if $have{$_} }
	return 'S24_3LE';
}

# Najblize podrzana frekvencija zeljenoj (prvo jednaka, pa najveca manja, pa najmanja veca).
sub best_rate {
	my ($rates, $want) = @_;
	my @r = @{ $rates || [] };
	return $want unless @r;
	return $want if grep { $_ == $want } @r;
	my @lower = grep { $_ < $want } @r;
	return @lower ? $lower[-1] : $r[0];
}

1;
