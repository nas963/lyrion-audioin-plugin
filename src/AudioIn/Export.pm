package Plugins::AudioIn::Export;

# Izvoz sesije u pesme: svaka stiklirana pesma je isecak snimka (tacno na uzorak, bez promene zvuka)
# u svom FLAC fajlu sa tagovima. Cist Perl; procesi idu preko ubacenog spawn-a (Jobs).
#
# plan(session => $s, take_path => sub($take) -> putanja, root => $folder, flac => $putanja, level => 5,
#      res_tag => 1) -> { dir, tracks => [ { n, take, skip, until, file, tags => [[K, V], ...] } ] } | (undef, $err)
# Runner: new(spawn => sub(%a) -> $job, on_change => sub, log => sub) ; start($plan) ; cancel ; snapshot

use strict;
use warnings;
use utf8;

use File::Path ();
use POSIX ();

use Plugins::AudioIn::Jobs;
use Plugins::AudioIn::Naming;
use Plugins::AudioIn::Sessions;

sub _kept_tracks {
	my ($s) = @_;
	my @out;
	for my $p (@{ $s->{parts} || [] }) {
		my $i = 0;    # fizicka pozicija na strani (broje se i pesme koje se ne cuvaju)
		for my $tk (@{ $p->{takes} || [] }) {
			next unless $tk->{ok};
			for my $t (@{ $tk->{tracks} || [] }) {
				$i++;
				next if exists $t->{keep} && !$t->{keep};
				push @out, { part => $p->{name}, take => $tk, track => $t, idx => $i };
			}
		}
	}
	return @out;
}

sub plan {
	my (%a) = @_;
	my $s = $a{session} or return (undef, 'no_session');
	my @kept = _kept_tracks($s);
	return (undef, 'no_tracks') unless @kept;
	my $m = $s->{meta} || {};
	my $type = $s->{type} // 'vinyl';
	my $media = ($Plugins::AudioIn::Sessions::SOURCE_TYPES{$type} || {})->{media} // '';
	my $sided = $type eq 'vinyl' || $type eq 'cassette';
	my $rate = $kept[0]{take}{rate};
	my $album = {
		artist => (defined $m->{artist} && length $m->{artist}) ? $m->{artist} : 'Unknown Artist',
		album  => (defined $m->{album} && length $m->{album}) ? $m->{album} : 'Unknown Album',
		year   => $m->{year},
		res    => $a{res_tag} ? Plugins::AudioIn::Naming::res_tag(24, $rate) : '',
	};
	my $dir = Plugins::AudioIn::Naming::album_dir($a{root}, $album);
	my $total = @kept;
	my @tracks;
	my $n = 0;
	for my $k (@kept) {
		$n++;
		my $t = $k->{track};
		my $title = defined $t->{title} && length $t->{title} ? $t->{title} : "Track $n";
		my @tags = (
			[ TITLE => $title ], [ ARTIST => $t->{artist} // $album->{artist} ], [ ALBUMARTIST => $album->{artist} ],
			[ ALBUM => $album->{album} ], [ TRACKNUMBER => $n ], [ TRACKTOTAL => $total ],
		);
		push @tags, [ DATE => $album->{year} ] if defined $album->{year} && length $album->{year};
		push @tags, [ MEDIA => $media ] if length $media;
		push @tags, [ VINYLTRACK => $k->{part} . $k->{idx} ] if $sided;
		push @tags, [ ENCODER => 'AudioIn (Lyrion)' ];
		push @tags, [ $_ => $m->{"mb_$_"} ] for grep { defined $m->{"mb_$_"} } qw(MUSICBRAINZ_ALBUMID MUSICBRAINZ_RELEASEGROUPID);
		push @tags, [ MUSICBRAINZ_TRACKID => $t->{mbid} ] if defined $t->{mbid};
		my $file = Plugins::AudioIn::Naming::track_file($album, { n => $n, title => $title });
		push @tracks, {
			n => $n, take_path => $a{take_path}->($k->{take}), skip => int($t->{start}), until => int($t->{end}),
			rate => $k->{take}{rate}, file => $file, tags => \@tags, title => $title,
		};
	}
	my $cover = $a{cover} && -f $a{cover} && -s _ ? $a{cover} : undef;
	$_->{cover} = $cover for @tracks;
	return { dir => $dir, tracks => \@tracks, rate => $rate, cover => $cover };
}

# Argv za jednu pesmu: dekodiranje isecka | kodiranje sa tagovima, oba sa nice/ionice.
sub track_argv {
	my ($t, %o) = @_;
	my $flac = $o{flac} || 'flac';
	my $lvl = defined $o{level} && $o{level} =~ /^[0-8]\z/ ? $o{level} : 5;
	my @dec = Plugins::AudioIn::Jobs::low_prio($flac, '-dcs', '--force-raw-format', '--endian=little', '--sign=signed',
		"--skip=$t->{skip}", "--until=$t->{until}", '--', $t->{take_path});
	my @enc = Plugins::AudioIn::Jobs::low_prio($flac, '--silent', "-$lvl", '--force-raw-format', '--endian=little',
		'--sign=signed', '--channels=2', '--bps=24', "--sample-rate=$t->{rate}",
		(map { ('-T', "$_->[0]=$_->[1]") } @{ $t->{tags} }), ($t->{cover} ? ("--picture=$t->{cover}") : ()),
		'-f', '-o', $o{out}, '-');
	return Plugins::AudioIn::Jobs::pipeline(\@dec, \@enc);
}

# ---------- runner ----------

sub new {
	my ($class, %o) = @_;
	return bless { %o, cur => undef, last => undef }, $class;
}

sub busy { $_[0]{cur} ? 1 : 0 }

sub snapshot {
	my ($self) = @_;
	my $c = $self->{cur};
	return { running => 1, session => $c->{session}, done => $c->{done}, total => scalar @{ $c->{plan}{tracks} },
		title => $c->{title} } if $c;
	return $self->{last};
}

sub _changed { my ($self) = @_; eval { $self->{on_change}->() if $self->{on_change}; 1 }; return }
sub _log { my ($self, $l, $m) = @_; eval { $self->{log}->($l, $m) if $self->{log}; 1 }; return }

# start(plan => $plan, session => $id, root => $root, flac => .., level => .., exists => sub($p)) -> (ok, err)
sub start {
	my ($self, %a) = @_;
	return (0, { error => 'export_busy' }) if $self->{cur};
	my $plan = $a{plan};
	my $tmp = "$a{root}/.export-tmp/$a{session}";
	File::Path::remove_tree($tmp) if -d $tmp;
	eval { File::Path::make_path($tmp, { mode => 0755 }); 1 } or return (0, { error => 'mkdir' });
	return (0, { error => 'mkdir' }) unless -d $tmp;
	if ($plan->{cover}) {
		require File::Copy;
		File::Copy::copy($plan->{cover}, "$tmp/cover.jpg");
	}
	$self->{cur} = { %a, tmp => $tmp, done => 0, log => [] };
	$self->_next;
	$self->_changed;
	return (1, undef);
}

sub cancel {
	my ($self) = @_;
	my $c = $self->{cur} or return (0, { error => 'not_running' });
	$c->{cancelled} = 1;
	$c->{job}->kill if $c->{job};
	return (1, undef);
}

sub _next {
	my ($self) = @_;
	my $c = $self->{cur} or return;
	my $t = $c->{plan}{tracks}[ $c->{done} ];
	return $self->_finish unless $t;
	$c->{title} = $t->{title};
	my $out = "$c->{tmp}/" . Plugins::AudioIn::Naming::fs_bytes($t->{file});
	my @out;
	$c->{job} = eval {
		$self->{spawn}->(
			argv    => [ track_argv($t, flac => $c->{flac}, level => $c->{level}, out => $out) ],
			umask   => 022,
			on_line => sub { push @out, $_[0] if @out < 20 },
			on_exit => sub {
				my ($st) = @_;
				delete $c->{job};
				if ($c->{cancelled}) { return $self->_fail('cancelled') }
				if ($st != 0) { return $self->_fail("flac $st: " . join(' | ', @out)) }
				push @{ $c->{log} }, sprintf('%02d  %-50s  %s .. %s', $t->{n}, $t->{title}, _ts($t->{skip}, $t->{rate}), _ts($t->{until}, $t->{rate}));
				$c->{done}++;
				$self->_changed;
				$self->_next;
			},
		);
	};
	return $self->_fail('spawn: ' . ($@ || '?')) unless $c->{job};
	return;
}

sub _ts { my ($f, $r) = @_; my $s = $f / ($r || 1); return sprintf('%d:%06.3f', int($s / 60), $s - 60 * int($s / 60)) }

sub _finish {
	my ($self) = @_;
	my $c = delete $self->{cur};
	my $dest = Plugins::AudioIn::Naming::unique_dir($c->{plan}{dir}, $c->{exists} || sub { -e Plugins::AudioIn::Naming::fs_bytes($_[0]) });
	my $dest_b = Plugins::AudioIn::Naming::fs_bytes($dest);
	(my $parent = $dest_b) =~ s{/[^/]*\z}{};
	eval { File::Path::make_path($parent, { mode => 0755 }); 1 };
	if (open(my $fh, '>:utf8', "$c->{tmp}/audioin.log")) {
		print $fh "AudioIn export " . POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime) . "\n";
		print $fh "session $c->{session}, $c->{plan}{rate} Hz, 24 bit\n\n";
		print $fh "$_\n" for @{ $c->{log} };
		close $fh;
	}
	unless (rename($c->{tmp}, $dest_b)) {
		return $self->_fail_done($c, "rename: $!");
	}
	$self->{last} = { running => 0, ok => 1, session => $c->{session}, dir => $dest, total => $c->{done}, at => time };
	$self->_log(info => "izvoz $c->{session}: $c->{done} pesama -> $dest");
	eval { $c->{on_done}->($self->{last}) if $c->{on_done}; 1 };
	$self->_changed;
	return;
}

sub _fail {
	my ($self, $err) = @_;
	my $c = delete $self->{cur} or return;
	return $self->_fail_done($c, $err);
}

sub _fail_done {
	my ($self, $c, $err) = @_;
	File::Path::remove_tree($c->{tmp}) if $c->{tmp} && -d $c->{tmp};
	$self->{last} = { running => 0, ok => 0, session => $c->{session}, error => $err, at => time };
	$self->_log(warn => "izvoz $c->{session}: $err");
	$self->_changed;
	return;
}

1;
