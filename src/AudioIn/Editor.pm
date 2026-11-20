package Plugins::AudioIn::Editor;

# Pesme u snimku: analiza (predlog granica), cuvanje izmena iz editora, pregled talasnog oblika.
# Cist Perl, radi nad Sessions (session.json + <take>.peaks/.json pored snimka).
#
# new(sessions => $Sessions, opt => sub -> {Analyze opcije})

use strict;
use warnings;
use utf8;

use Plugins::AudioIn::Analyze;
use Plugins::AudioIn::Metadata;
use Plugins::AudioIn::Peaks;

sub new {
	my ($class, %o) = @_;
	die "Editor: sessions je obavezan\n" unless $o{sessions};
	return bless { %o }, $class;
}

# ($session, $part, $take) | () za id sesije i ime snimka (A-1).
sub find_take {
	my ($self, $sid, $name) = @_;
	my $s = $self->{sessions}->get($sid) or return ();
	return () unless defined $name;
	for my $p (@{ $s->{parts} || [] }) {
		for my $t (@{ $p->{takes} || [] }) {
			return ($s, $p, $t) if $t->{name} eq $name;
		}
	}
	return ();
}

sub _peaks_path {
	my ($self, $s, $t) = @_;
	(my $f = $self->{sessions}->take_path($s, $t)) =~ s/\.flac\z/.peaks/;
	return $f;
}

sub read_peaks {
	my ($self, $s, $t) = @_;
	open(my $fh, '<:raw', $self->_peaks_path($s, $t)) or return [];
	local $/;
	my $b = <$fh>;
	close $fh;
	return Plugins::AudioIn::Peaks::parse($b);
}

# analyze($sid, $take, durations => [..]) -> (ok, err, $tracks)
# Postojeci naslovi i stikle se zadrzavaju po redosledu pesama. Ako deo ima pesme sa MusicBrainz-a
# (mb_tracks), njihova trajanja vode granice, a naslovi popunjavaju prazna mesta (mb_force: prepisuju sve).
sub analyze {
	my ($self, $sid, $name, %o) = @_;
	my ($s, $p, $t) = $self->find_take($sid, $name) or return (0, { error => 'no_take' });
	my $pk = $self->read_peaks($s, $t);
	my $mbt = $p->{mb_tracks} || [];
	my $dur = $o{durations};
	if (!$dur && @$mbt > 1 && !grep { !$_->{length} } @$mbt) { $dur = [ map { $_->{length} } @$mbt ] }
	my $r = Plugins::AudioIn::Analyze::analyze(peaks => $pk, rate => $t->{rate}, frames => $t->{frames},
		markers => $t->{markers}, ($dur ? (durations => $dur) : ()),
		opt => ($self->{opt} ? $self->{opt}->() : {}));
	my @old = @{ $t->{tracks} || [] };
	my @new;
	for my $i (0 .. $#{ $r->{tracks} }) {
		my $x = $r->{tracks}[$i];
		my $o = $old[$i] || {};
		my $m = $mbt->[$i] || {};
		my $title = $o->{title};
		$title = $m->{title} if defined $m->{title} && ($o{mb_force} || !(defined $title && length $title));
		push @new, { start => $x->{start}, end => $x->{end}, from => $x->{from}, title => $title,
			keep => exists $o->{keep} ? ($o->{keep} ? 1 : 0) : 1,
			(defined $m->{recording_id} ? (mbid => $m->{recording_id}) : ()),
			($s->{meta}{compilation} && defined $m->{artist} ? (artist => $m->{artist}) : ()) };
	}
	$t->{tracks} = \@new;
	$t->{analysis} = { floor_db => $r->{floor_db}, thr_db => $r->{thr_db}, music => $r->{music}, gaps => $r->{gaps}, at => time };
	$self->{sessions}->save($s) or return (0, { error => 'write' });
	return (1, undef, \@new);
}

# apply_release($sid, $release) -> (ok, err, { parts => { A => broj_pesama }, analyzed => [take...] })
# Metapodaci albuma u sesiju, pesme po delovima (mb_tracks), pa ponovna analiza snimljenih delova.
sub apply_release {
	my ($self, $sid, $rel) = @_;
	my $s = $self->{sessions}->get($sid) or return (0, { error => 'no_session' });
	return (0, { error => 'bad_release' }) unless ref $rel eq 'HASH' && $rel->{id};
	my $m = $s->{meta} ||= {};
	$m->{artist} = $rel->{artist};
	$m->{album} = $rel->{album};
	$m->{year} = $rel->{original_year} // $rel->{year};
	$m->{release_year} = $rel->{year};
	$m->{compilation} = $rel->{compilation} ? 1 : 0;
	$m->{mb_MUSICBRAINZ_ALBUMID} = $rel->{id};
	$m->{mb_MUSICBRAINZ_RELEASEGROUPID} = $rel->{release_group_id} if $rel->{release_group_id};

	# delovi koje izdanje ima (strane) se dodaju ako ih jos nema
	my $sides = Plugins::AudioIn::Metadata::sides($rel);
	$self->{sessions}->ensure_part($s, $_->{name}) for grep { defined $_->{name} } @$sides;

	my @parts;
	for my $p (@{ $s->{parts} }) {
		my ($tk) = grep { $_->{ok} } @{ $p->{takes} || [] };
		my $secs;
		if ($tk && $tk->{analysis} && $tk->{analysis}{music} && $tk->{rate}) {
			my ($a, $b) = @{ $tk->{analysis}{music} };
			$secs = ($b - $a) / $tk->{rate};
		}
		push @parts, { name => $p->{name}, seconds => $secs, has_take => $tk ? 1 : 0 };
	}
	# bez oznaka strana raspodela po trajanju ima smisla samo za snimljene delove
	my $lettered = @$sides && defined $sides->[0]{name};
	my $asg = Plugins::AudioIn::Metadata::assign($rel, [ grep { $lettered || $_->{has_take} } @parts ]);
	my %count;
	for my $p (@{ $s->{parts} }) {
		my $tr = $asg->{ $p->{name} };
		if ($tr) { $p->{mb_tracks} = $tr; $count{ $p->{name} } = scalar @$tr }
		else { delete $p->{mb_tracks} }
	}
	$self->{sessions}->save($s) or return (0, { error => 'write' });

	my @done;
	for my $p (@{ $s->{parts} }) {
		next unless $p->{mb_tracks};
		for my $tk (grep { $_->{ok} } @{ $p->{takes} || [] }) {
			my ($ok) = $self->analyze($sid, $tk->{name}, mb_force => 1);
			push @done, $tk->{name} if $ok;
			last;    # pesme sa izdanja idu na prvi ispravan snimak dela
		}
	}
	return (1, undef, { parts => \%count, analyzed => \@done });
}

# set_tracks($sid, $take, [ {start, end, title, keep} ]) -> (ok, err)
# Granice moraju biti rastuce i u okviru snimka; pesme se nastavljaju (end = start sledece) ili ne.
sub set_tracks {
	my ($self, $sid, $name, $tracks) = @_;
	my ($s, $p, $t) = $self->find_take($sid, $name) or return (0, { error => 'no_take' });
	return (0, { error => 'bad_tracks' }) unless ref $tracks eq 'ARRAY' && @$tracks;
	my @clean;
	my $prev = -1;
	for my $x (@$tracks) {
		return (0, { error => 'bad_tracks' }) unless ref $x eq 'HASH';
		my ($a, $b) = (int($x->{start} // -1), int($x->{end} // -1));
		return (0, { error => 'bad_tracks' }) if $a < 0 || $b <= $a || $b > $t->{frames} || $a < $prev;
		$prev = $b;
		my $title = defined $x->{title} ? "$x->{title}" : undef;
		$title = substr($title, 0, 300) if defined $title;
		push @clean, { start => $a, end => $b, title => $title, keep => $x->{keep} ? 1 : 0,
			(defined $x->{from} ? (from => $x->{from}) : ()), (defined $x->{artist} && length $x->{artist} ? (artist => "$x->{artist}") : ()),
			(defined $x->{mbid} && $x->{mbid} =~ /\A[0-9a-f-]{36}\z/ ? (mbid => $x->{mbid}) : ()) };
	}
	$t->{tracks} = \@clean;
	$self->{sessions}->save($s) or return (0, { error => 'write' });
	return (1, undef);
}

# Pregled za crtanje: $points tacaka, svaka [vrh 0..1, rms 0..1] (max kroz grupu prozora).
sub overview {
	my ($self, $sid, $name, $points) = @_;
	my ($s, $p, $t) = $self->find_take($sid, $name) or return (undef, { error => 'no_take' });
	my $pk = $self->read_peaks($s, $t);
	$points = 1000 unless $points && $points > 10;
	$points = 4000 if $points > 4000;
	my $n = @$pk;
	my @out;
	if ($n) {
		my $per = $n / $points;
		$per = 1 if $per < 1;
		for (my $x = 0; $x < $n; $x += $per) {
			my ($mx, $mr) = (0, 0);
			for my $i (int($x) .. int($x + $per) - 1) {
				last if $i >= $n;
				my $r = $pk->[$i];
				my $m = $r->[0] > $r->[1] ? $r->[0] : $r->[1];
				$mx = $m if $m > $mx;
				$mr = $r->[2] if $r->[2] > $mr;
			}
			push @out, [ sprintf('%.4f', $mx / 32768) + 0, sprintf('%.4f', $mr / 32768) + 0 ];
		}
	}
	return ({
		take => $t->{name}, part => $p->{name}, rate => $t->{rate}, frames => $t->{frames},
		window_frames => $n ? $t->{frames} / $n : 0, points => \@out,
		markers => $t->{markers} || [], xruns => $t->{xruns} || [], tracks => $t->{tracks} || [],
		analysis => $t->{analysis}, meta => $s->{meta}, type => $s->{type},
	}, undef);
}

1;
