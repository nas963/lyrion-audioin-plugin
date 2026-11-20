package Plugins::AudioIn::State;

# Stanje plugina i pravila (cist Perl, testira se bez LMS-a): ulaz, slusanje po plejerima, merac,
# snimanje u sesije, markeri sa kompenzacijom kasnjenja. Plugin.pm je samo LMS sloj.
#
# new(send => sub(\%cmd) -> 1|0          komanda pomocnom procesu
#     pref => sub($ime) -> vrednost
#     sessions => Plugins::AudioIn::Sessions
#     player_pos => sub($player_id) -> ($url, $elapsed_s) | ()   sta plejer svira i koliko je odsvirao
#     on_take => sub($session_id, $take_name, $ok)  posle zavrsenog snimka (analiza)
#     now => sub, log => sub($nivo, $poruka), on_change => sub)

use strict;
use warnings;
use utf8;

use Time::HiRes ();

use Plugins::AudioIn::Sessions;

use constant METER_FRESH   => 1;     # s, merac stariji od ovoga se ne prikazuje
use constant LISTEN_BIND   => 10;    # s, citac koji se javi u ovom roku posle Slusaj pripada tom plejeru

sub new {
	my ($class, %o) = @_;
	for (qw(send pref sessions)) { die "State: $_ je obavezan\n" unless $o{$_} }
	return bless {
		%o,
		now       => $o{now} || \&Time::HiRes::time,
		helper    => 0,
		input     => { open => 0 },
		meter     => undef,
		rec       => undef,     # { state, session, part, name, path, frames, markers, ... }
		listeners => {},        # player_id => { start, epoch, rate, t }
		pending   => [],        # [ { player, t } ] Slusaj ceka svog citaca
		session   => undef,     # id izabrane sesije
		part      => undef,     # ime izabranog dela
		activity  => 0,         # poslednja aktivnost (za zatvaranje ulaza posle neaktivnosti)
		clients   => 0,
		last_err  => undef,
		events    => [],        # poslednjih nekoliko vaznih dogadjaja (xrun, greske) za stranicu
	}, $class;
}

sub _log { my ($self, $l, $m) = @_; eval { $self->{log}->($l, $m) if $self->{log}; 1 }; return }
sub _changed { my ($self) = @_; eval { $self->{on_change}->() if $self->{on_change}; 1 }; return }
sub _pref { my ($self, $k) = @_; return $self->{pref}->($k) }

sub _note {
	my ($self, %e) = @_;
	$e{t} = time;
	push @{ $self->{events} }, \%e;
	shift @{ $self->{events} } while @{ $self->{events} } > 20;
	return;
}

sub touch { my ($self) = @_; $self->{activity} = $self->{now}->(); return }

# ---------- ulaz ----------

sub open_cmd {
	my ($self) = @_;
	my $src = $self->_pref('source') || 'alsa';
	if ($src eq 'file') {
		my $f = $self->_pref('testFile');
		return { cmd => 'open', src => 'file', path => $f, loop => 1 };
	}
	return {
		cmd => 'open', src => 'alsa', dev => $self->_pref('device'), fmt => $self->_pref('format'),
		rate => $self->_pref('rate') + 0, channels => $self->_pref('channels') + 0,
		left => $self->_pref('leftChannel') + 0, right => $self->_pref('rightChannel') + 0,
	};
}

# open -> (ok, err)
sub open_input {
	my ($self) = @_;
	return (0, { error => 'helper' }) unless $self->{helper};
	$self->touch;
	return (1, undef) if $self->{input}{open};
	my $c = $self->open_cmd;
	return (0, { error => 'no_device' }) if $c->{src} eq 'alsa' && !(defined $c->{dev} && length $c->{dev});
	return (0, { error => 'no_file' }) if $c->{src} eq 'file' && !(defined $c->{path} && length $c->{path});
	$self->{input}{opening} = 1;
	$self->{send}->($c) or return (0, { error => 'helper' });
	return (1, undef);
}

sub close_input {
	my ($self) = @_;
	$self->{send}->({ cmd => 'close' });
	return (1, undef);
}

# Ulaz moze da se zatvori: niko ne slusa, ne snima se, merac miruje, proteklo idleClose minuta.
sub idle_check {
	my ($self) = @_;
	return 0 unless $self->{input}{open};
	return 0 if $self->{clients} || $self->{rec};
	my $min = $self->_pref('idleClose') // 10;
	return 0 unless $min > 0;
	return 0 if $self->{now}->() - $self->{activity} < $min * 60;
	$self->_log(info => "ulaz se zatvara posle $min min neaktivnosti");
	$self->close_input;
	return 1;
}

# ---------- slusanje ----------

# Plejer trazi slusanje: Plugin pusta URL; ovde se pamti da sledeci citac pripada tom plejeru.
sub listen_started {
	my ($self, $player) = @_;
	$self->touch;
	push @{ $self->{pending} }, { player => $player, t => $self->{now}->() };
	return;
}

# Pozicija (frejm u ringu) koju plejer trenutno pusta, ako slusa ulaz.
sub player_frame {
	my ($self, $player) = @_;
	return undef unless defined $player && $self->{player_pos};
	my $l = $self->{listeners}{$player} or return undef;
	return undef unless ($l->{epoch} // -1) == ($self->{input}{epoch} // -2);
	my ($url, $el) = $self->{player_pos}->($player);
	return undef unless defined $url && $url =~ m{^audioin://} && defined $el;
	return $l->{start} + int($el * $l->{rate});
}

# ---------- merac ----------

sub meter_on {
	my ($self) = @_;
	$self->touch;
	$self->{send}->({ cmd => 'meter', on => 1 });
	my $m = $self->{meter};
	return $m && $self->{now}->() - $m->{at} <= METER_FRESH ? $m : undef;
}

# ---------- sesije i snimanje ----------

sub current_session {
	my ($self) = @_;
	return defined $self->{session} ? $self->{sessions}->get($self->{session}) : undef;
}

sub session_new {
	my ($self, %o) = @_;
	my ($s, $err) = $self->{sessions}->create(type => $o{type} // $self->_pref('sourceType'), %o);
	return (0, { error => $err || 'session' }) unless $s;
	$self->{session} = $s->{id};
	$self->{part} = $s->{parts}[0]{name};
	$self->_changed;
	return (1, undef, $s);
}

sub session_select {
	my ($self, $id, $part) = @_;
	my $s = $self->{sessions}->get($id) or return (0, { error => 'no_session' });
	return (0, { error => 'recording' }) if $self->{rec};
	$self->{session} = $s->{id};
	my $p = defined $part ? $self->{sessions}->ensure_part($s, $part) : $s->{parts}[0];
	return (0, { error => 'bad_part' }) unless $p;
	$self->{sessions}->save($s);
	$self->{part} = $p->{name};
	$self->_changed;
	return (1, undef);
}

sub session_edit {
	my ($self, $id, %meta) = @_;
	my $s = $self->{sessions}->get($id) or return (0, { error => 'no_session' });
	for my $k (qw(artist album year)) {
		next unless exists $meta{$k};
		if (defined $meta{$k} && length $meta{$k}) { $s->{meta}{$k} = $meta{$k} } else { delete $s->{meta}{$k} }
	}
	$s->{type} = $meta{type} if defined $meta{type} && $Plugins::AudioIn::Sessions::SOURCE_TYPES{ $meta{type} };
	$self->{sessions}->save($s) or return (0, { error => 'write' });
	$self->_changed;
	return (1, undef);
}

sub rec_start {
	my ($self, %o) = @_;
	return (0, { error => 'recording' }) if $self->{rec};
	return (0, { error => 'helper' }) unless $self->{helper};
	return (0, { error => 'not_open' }) unless $self->{input}{open};
	my $s = $self->current_session;
	unless ($s) {
		my ($ok, $err) = $self->session_new;
		return (0, $err) unless $ok;
		$s = $self->current_session or return (0, { error => 'session' });
	}
	my $p = $self->{sessions}->ensure_part($s, $o{part} // $self->{part}) or return (0, { error => 'bad_part' });
	$self->{sessions}->save($s);
	my ($path, $name) = $self->{sessions}->new_take_path($s, $p);
	my $id = "$s->{id}/$name";
	$self->{send}->({ cmd => 'rec_start', id => $id, path => $path, preroll => $self->_pref('preroll') + 0,
		level => $self->_pref('flacLevel') + 0 }) or return (0, { error => 'helper' });
	$self->{rec} = { state => 'starting', id => $id, session => $s->{id}, part => $p->{name}, name => $name,
		path => $path, frames => 0, markers => 0, xruns => 0, clip_windows => 0 };
	$self->{part} = $p->{name};
	$self->touch;
	$self->_changed;
	return (1, undef);
}

sub rec_pause  { my ($self) = @_; return $self->_rec_cmd('rec_pause') }
sub rec_resume { my ($self) = @_; return $self->_rec_cmd('rec_resume') }
sub rec_stop   { my ($self) = @_; return $self->_rec_cmd('rec_stop') }

sub _rec_cmd {
	my ($self, $cmd) = @_;
	return (0, { error => 'not_recording' }) unless $self->{rec};
	$self->{send}->({ cmd => $cmd }) or return (0, { error => 'helper' });
	$self->touch;
	return (1, undef);
}

# Stop + izbor sledeceg dela (strana A -> B).
sub next_part {
	my ($self) = @_;
	my $s = $self->current_session or return (0, { error => 'no_session' });
	my $cur = $self->{rec} ? $self->{rec}{part} : $self->{part};
	$self->rec_stop if $self->{rec};
	my $p = $self->{sessions}->next_part($s, $cur // $s->{parts}[0]{name}) or return (0, { error => 'bad_part' });
	$self->{sessions}->save($s);
	$self->{part} = $p->{name};
	$self->_changed;
	return (1, undef, $p->{name});
}

# Marker: mesto koje korisnik CUJE. Ako slusa preko ovog plejera -> pozicija plejera;
# inace trenutni ulaz minus vreme reakcije.
sub marker {
	my ($self, %o) = @_;
	return (0, { error => 'not_recording' }) unless $self->{rec} && $self->{rec}{state} =~ /^(rec|starting)\z/;
	my $pos = $self->player_frame($o{player});
	my %c = (cmd => 'marker', kind => 'user');
	if (defined $pos) { $c{pos} = $pos } else { $c{back} = ($self->_pref('reaction') // 0) + 0 }
	$self->{send}->(\%c) or return (0, { error => 'helper' });
	$self->touch;
	return (1, undef, defined $pos ? 'player' : 'reaction');
}

# ---------- dogadjaji pomocnog procesa ----------

sub on_event {
	my ($self, $ev) = @_;
	my $t = $ev->{ev};
	my $in = $self->{input};
	if ($t eq 'ready') {
		$self->{helper} = 1;
		$self->{input} = { open => 0 };
	}
	elsif ($t eq 'helper') {
		$self->{helper} = 0;
		$self->{input} = { open => 0 };
		$self->{clients} = 0;
		$self->{listeners} = {};
		if ($self->{rec}) {
			$self->_note(kind => 'error', err => 'helper_died', take => $self->{rec}{id});
			$self->_finish_take(0, 'helper_died');
		}
	}
	elsif ($t eq 'opened') {
		$self->{input} = { open => 1, rate => $ev->{rate}, src => $ev->{src}, fmt => $ev->{fmt},
			dev => $ev->{dev}, path => $ev->{path}, epoch => $ev->{epoch}, head => $ev->{head}, since => time };
		$self->{last_err} = undef;
		$self->touch;
	}
	elsif ($t eq 'closed') {
		$self->{input} = { open => 0 };
		$self->{last_err} = $ev->{err};
		$self->_note(kind => 'closed', err => $ev->{err}) if $ev->{err};
	}
	elsif ($t eq 'tick') {
		$in->{head} = $ev->{head};
		$in->{tail} = $ev->{tail};
		$in->{lags} = [ map { $_->{lag} } @{ $ev->{clients} || [] } ];
		if (my $r = $self->{rec}) {
			if (my $hr = $ev->{rec}) {
				$r->{frames} = $hr->{frames};
				$r->{xruns} = $hr->{xruns};
				$r->{clip_windows} = $hr->{clip_windows};
				$r->{markers} = $hr->{markers};
			}
		}
	}
	elsif ($t eq 'meter') {
		$self->{meter} = { at => $self->{now}->(), pk => $ev->{pk}, rms => $ev->{rms}, clip => $ev->{clip} };
		return;    # cesto: bez on_change
	}
	elsif ($t eq 'client') {
		$self->{clients} = $ev->{n} // 0;
		if (defined $ev->{start}) {
			my $now = $self->{now}->();
			@{ $self->{pending} } = grep { $now - $_->{t} <= LISTEN_BIND } @{ $self->{pending} };
			if (my $p = shift @{ $self->{pending} }) {
				$self->{listeners}{ $p->{player} } = { start => $ev->{start}, epoch => $ev->{epoch},
					rate => $in->{rate} || 48000, t => $now };
			}
		}
		$self->touch;
	}
	elsif ($t eq 'rec') {
		my $r = $self->{rec};
		if ($ev->{state} eq 'error') {
			$self->_note(kind => 'error', err => "rec_$ev->{err}");
			$self->{rec} = undef;
		}
		elsif ($r && ($ev->{id} // $r->{id}) eq $r->{id}) {
			if ($ev->{state} eq 'stopped') {
				$self->_finish_take($ev->{ok}, $ev->{why}, $ev->{frames});
			}
			else {
				$r->{state} = $ev->{state};
				$r->{frames} = $ev->{frames} if defined $ev->{frames};
				$r->{preroll} = $ev->{preroll} if defined $ev->{preroll};
			}
		}
	}
	elsif ($t eq 'marker') {
		$self->{rec}{markers}++ if $self->{rec};
	}
	elsif ($t eq 'xrun') {
		$self->_note(kind => 'xrun', pos => $ev->{pos});
		$self->{rec}{xruns}++ if $self->{rec};
	}
	elsif ($t eq 'error') {
		$self->_note(kind => 'error', err => $ev->{err});
		$self->_log(warn => "audioin-capture: $ev->{err}" . (defined $ev->{msg} ? " ($ev->{msg})" : ''));
	}
	$self->_changed;
	return;
}

sub _finish_take {
	my ($self, $ok, $why, $frames) = @_;
	my $r = delete $self->{rec} or return;
	my $s = $self->{sessions}->get($r->{session});
	if ($s) {
		$self->{sessions}->add_take($s, $r->{part}, name => $r->{name}, ok => $ok, frames => $frames // $r->{frames},
			rate => $self->{input}{rate});
	}
	eval { $self->{on_take}->($r->{session}, $r->{name}, $ok) if $self->{on_take} && $s; 1 }
		or $self->_log(warn => "posle snimka: $@");
	$self->_note(kind => $ok ? 'take' : 'error', take => $r->{id}, err => $ok ? undef : ($why || 'rec_failed'));
	return;
}

# ---------- stanje za stranicu ----------

sub snapshot {
	my ($self) = @_;
	my $in = $self->{input};
	my $rate = $in->{rate} || 0;
	my $r = $self->{rec};
	my $s = $self->current_session;
	my $m = $self->{meter};
	return {
		helper => $self->{helper},
		input  => {
			open => $in->{open} ? 1 : 0, src => $in->{src}, rate => $in->{rate}, fmt => $in->{fmt},
			dev => $in->{dev}, path => $in->{path},
			buffered => $rate && defined $in->{head} ? sprintf('%.1f', (($in->{head} - ($in->{tail} // 0)) / $rate)) + 0 : 0,
			lags => $in->{lags} || [], error => $self->{last_err},
		},
		listeners => $self->{clients},
		meter => $m && $self->{now}->() - $m->{at} <= METER_FRESH ? { pk => $m->{pk}, rms => $m->{rms}, clip => $m->{clip} } : undef,
		rec => $r ? {
			state => $r->{state}, part => $r->{part}, take => $r->{name},
			seconds => $rate ? sprintf('%.1f', $r->{frames} / $rate) + 0 : 0,
			markers => $r->{markers}, xruns => $r->{xruns}, clip_windows => $r->{clip_windows},
		} : undef,
		session => $s ? _session_summary($s) : undef,
		part => $self->{part},
		events => [ _last(5, @{ $self->{events} }) ],
	};
}

sub _last { my ($n, @a) = @_; return @a > $n ? @a[ -$n .. -1 ] : @a }

sub _session_summary {
	my ($s) = @_;
	return {
		id => $s->{id}, type => $s->{type}, meta => $s->{meta},
		exports => [ map { { dir => $_->{dir}, moved => $_->{moved} ? 1 : 0, tracks => $_->{tracks}, error => $_->{move_error} } } @{ $s->{exports} || [] } ],
		parts => [ map {
			my $p = $_;
			{ name => $p->{name}, takes => [ map { {
				name => $_->{name}, ok => $_->{ok}, seconds => $_->{rate} ? sprintf('%.1f', ($_->{frames} || 0) / $_->{rate}) + 0 : 0,
				markers => scalar @{ $_->{markers} || [] }, xruns => scalar @{ $_->{xruns} || [] },
				clip_windows => $_->{clip_windows} } } @{ $p->{takes} || [] } ] }
		} @{ $s->{parts} || [] } ],
	};
}

1;
