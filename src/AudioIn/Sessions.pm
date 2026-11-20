package Plugins::AudioIn::Sessions;

# Sesije snimanja. Cist Perl.
# Sesija = jedan album (ploca, kaseta, emisija...): vrsta izvora, metapodaci i delovi (strane A, B...);
# svaki deo ima snimke (take) = neprekinute FLAC fajlove sa .peaks i .json pored.
# Na disku: <root>/.sessions/<id>/session.json, snimci <id>/<deo>-<n>.flac (isti FS kao izvoz).
#
# new(root => sub -> $folder_za_snimke)

use strict;
use warnings;
use utf8;

use File::Path ();
use JSON::PP ();
use POSIX ();

my $JSON = JSON::PP->new->utf8->canonical->pretty;

our %SOURCE_TYPES = (
	vinyl    => { parts => [qw(A B C D E F G H)], media => '12" Vinyl' },
	cassette => { parts => [qw(A B)],             media => 'Cassette' },
	radio    => { parts => [qw(1 2 3 4)],         media => 'Radio' },
	live     => { parts => [qw(1 2 3 4)],         media => '' },
	other    => { parts => [qw(1 2 3 4)],         media => '' },
);

sub new {
	my ($class, %o) = @_;
	die "Sessions: root je obavezan\n" unless $o{root};
	return bless { root => $o{root} }, $class;
}

sub dir { my ($self) = @_; return $self->{root}->() . '/.sessions' }

sub _sdir { my ($self, $id) = @_; return $self->dir . "/$id" }

sub valid_id { my ($id) = @_; return defined $id && $id =~ /\A[0-9]{8}-[0-9]{6}(?:-[0-9]+)?\z/ ? 1 : 0 }

sub _read_json {
	my ($path) = @_;
	open(my $fh, '<:raw', $path) or return undef;
	local $/;
	my $d = eval { $JSON->decode(<$fh>) };
	close $fh;
	return $d;
}

sub _write_json {
	my ($path, $data) = @_;
	open(my $fh, '>:raw', "$path.tmp") or return 0;
	print $fh $JSON->encode($data);
	close $fh or return 0;
	return rename("$path.tmp", $path) ? 1 : 0;
}

sub default_parts {
	my ($type) = @_;
	my $t = $SOURCE_TYPES{ $type // '' } || $SOURCE_TYPES{other};
	return @{ $t->{parts} };
}

# create(type => 'vinyl', title => ..., artist => ...) -> $session | undef, $err
sub create {
	my ($self, %o) = @_;
	my $type = $SOURCE_TYPES{ $o{type} // '' } ? $o{type} : 'vinyl';
	my $base = POSIX::strftime('%Y%m%d-%H%M%S', localtime($o{now} // time));
	my $id = $base;
	my $n = 1;
	$id = "$base-" . ++$n while -e $self->_sdir($id);
	my $dir = $self->_sdir($id);
	eval { File::Path::make_path($dir, { mode => 0755 }); 1 } or return (undef, 'mkdir');
	return (undef, 'mkdir') unless -d $dir;
	my $s = {
		id      => $id,
		type    => $type,
		created => $o{now} // time,
		meta    => { map { defined $o{$_} ? ($_ => $o{$_}) : () } qw(artist album year) },
		parts   => [ map { { name => $_, takes => [] } } (default_parts($type))[0, 1] ],
	};
	$s->{meta}{album} //= $o{title} if defined $o{title};
	$self->save($s) or return (undef, 'write');
	return ($s, undef);
}

sub save {
	my ($self, $s) = @_;
	return 0 unless ref $s eq 'HASH' && valid_id($s->{id});
	$s->{updated} = time;
	return _write_json($self->_sdir($s->{id}) . '/session.json', $s);
}

sub get {
	my ($self, $id) = @_;
	return undef unless valid_id($id);
	my $s = _read_json($self->_sdir($id) . '/session.json');
	return ref $s eq 'HASH' ? $s : undef;
}

# Najnovije prve.
sub list {
	my ($self) = @_;
	my $dir = $self->dir;
	opendir(my $dh, $dir) or return [];
	my @ids = sort { $b cmp $a } grep { valid_id($_) } readdir $dh;
	closedir $dh;
	return [ grep { defined } map { $self->get($_) } @ids ];
}

sub part {
	my ($self, $s, $name) = @_;
	my ($p) = grep { $_->{name} eq $name } @{ $s->{parts} || [] };
	return $p;
}

# Deo po imenu; ako ne postoji, dodaje se (sledeci iz liste za vrstu izvora ili zadato ime).
sub ensure_part {
	my ($self, $s, $name) = @_;
	if (!defined $name || !length $name) {
		my %have = map { $_->{name} => 1 } @{ $s->{parts} };
		($name) = grep { !$have{$_} } default_parts($s->{type});
		$name //= scalar(@{ $s->{parts} }) + 1;
	}
	return undef unless $name =~ /\A[A-Za-z0-9]{1,8}\z/;
	my $p = $self->part($s, $name);
	unless ($p) {
		$p = { name => $name, takes => [] };
		push @{ $s->{parts} }, $p;
	}
	return $p;
}

# Deo posle zadatog (za "Sledeci deo"): postojeci ili nov.
sub next_part {
	my ($self, $s, $name) = @_;
	my @parts = @{ $s->{parts} };
	for my $i (0 .. $#parts - 1) {
		return $parts[ $i + 1 ] if $parts[$i]{name} eq $name;
	}
	my @def = default_parts($s->{type});
	for my $i (0 .. $#def - 1) {
		return $self->ensure_part($s, $def[ $i + 1 ]) if $def[$i] eq $name;
	}
	return $self->ensure_part($s, undef);
}

# Putanja za nov snimak dela: <sesija>/<deo>-<n>.flac (n = 1, 2, ...).
sub new_take_path {
	my ($self, $s, $part) = @_;
	my $dir = $self->_sdir($s->{id});
	my $n = 1;
	$n++ while -e "$dir/$part->{name}-$n.flac" || -e "$dir/$part->{name}-$n.flac.part";
	return ("$dir/$part->{name}-$n.flac", "$part->{name}-$n");
}

# Zavrsen snimak: upis u deo (frejmovi, markeri iz .json snimka).
sub add_take {
	my ($self, $s, $part_name, %t) = @_;
	my $p = $self->ensure_part($s, $part_name) or return 0;
	my $dir = $self->_sdir($s->{id});
	my $info = _read_json("$dir/$t{name}.json") || {};
	push @{ $p->{takes} }, {
		name    => $t{name},
		file    => "$t{name}.flac",
		ok      => $t{ok} ? 1 : 0,
		frames  => $info->{frames} // $t{frames},
		rate    => $info->{rate} // $t{rate},
		markers => $info->{markers} || [],
		xruns   => $info->{xruns} || [],
		clip_windows => $info->{clip_windows} || 0,
		recorded => $info->{started} // time,
	};
	return $self->save($s);
}

sub cover_path { my ($self, $s) = @_; return $self->_sdir($s->{id}) . '/cover.jpg' }

sub take_path {
	my ($self, $s, $take) = @_;
	return $self->_sdir($s->{id}) . "/$take->{file}";
}

1;
