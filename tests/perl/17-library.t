use strict;
use warnings;
use utf8;
use Test::More;

# Premesti u biblioteku sa izborom odredista: pregled foldera biblioteke, nov folder, odrediste.

use File::Temp ();
use Plugins::AudioIn::Library;
use Plugins::AudioIn::Naming;

my $root = File::Temp::tempdir(CLEANUP => 1);
my $fs = \&Plugins::AudioIn::Naming::fs_bytes;
my $mk = sub { my $p = $fs->($_[0]); my @parts = split m{/}, $p; my $acc = ''; for (@parts) { next unless length; $acc .= "/$_"; mkdir $acc } };
my ($cd, $sacd) = ("$root/Muzika/CD", "$root/Muzika/SACD");
$mk->("$cd/$_") for ('Enigma', 'enya', 'Đorđe Balašević', 'AC-DC', '.hidden');
$mk->("$sacd/Pink Floyd");
open(my $f, '>', $fs->("$cd/notes.txt")) or die; close $f;
my @media = ($cd, $sacd);

# koreni
my ($b, $e) = Plugins::AudioIn::Library::browse('', \@media);
is_deeply([ map { $_->{path} } @{ $b->{dirs} } ], \@media, 'bez putanje: muzicki folderi');
ok(!defined $b->{parent}, 'koren nema roditelja');

($b) = Plugins::AudioIn::Library::browse($cd, \@media);
is_deeply([ map { $_->{name} } @{ $b->{dirs} } ], [ 'AC-DC', 'Enigma', 'enya', 'Đorđe Balašević' ], 'izvodjaci: sortirano bez obzira na velika slova, bez skrivenih i fajlova');
ok(!defined $b->{parent}, 'muzicki folder: nema roditelja (ne ide iznad biblioteke)');
($b) = Plugins::AudioIn::Library::browse("$cd/Enigma", \@media);
is($b->{parent}, $cd, 'roditelj izvodjaca');
is_deeply($b->{dirs}, [], 'prazan folder izvodjaca');

(undef, $e) = Plugins::AudioIn::Library::browse("$root/Muzika", \@media);
is($e, 'outside_library', 'iznad muzickog foldera: odbijeno');
(undef, $e) = Plugins::AudioIn::Library::browse("$cd/../..", \@media);
is($e, 'outside_library', '.. odbijeno');
(undef, $e) = Plugins::AudioIn::Library::browse("$cd/Nema", \@media);
is($e, 'not_found', 'nepostojeci folder');
($b) = Plugins::AudioIn::Library::browse($cd, \@media, limit => 2);
ok($b->{truncated} && @{ $b->{dirs} } == 2, 'ogranicenje broja foldera');

# nov folder
my ($nd, $ne) = Plugins::AudioIn::Library::make_dir($cd, 'Bob Marley: Live?', \@media);
is($nd, "$cd/Bob Marley- Live", 'nov folder: bezbedno ime');
ok(-d $fs->($nd), 'nov folder napravljen');
($nd) = Plugins::AudioIn::Library::make_dir($cd, 'Enigma', \@media);
is($nd, "$cd/Enigma", 'postojeci folder: vraca se');
(undef, $ne) = Plugins::AudioIn::Library::make_dir($cd, 'notes.txt', \@media);
is($ne, 'exists', 'ime fajla: exists');
(undef, $ne) = Plugins::AudioIn::Library::make_dir($cd, '  ', \@media);
is($ne, 'bad_name', 'prazno ime');
(undef, $ne) = Plugins::AudioIn::Library::make_dir("$root/x", 'A', \@media);
is($ne, 'outside_library', 'van biblioteke');

# odrediste premestanja
my $rips = "$root/CD-Rips";
$mk->("$rips/Enigma/The Cross of Changes");
my ($dest, $err) = Plugins::AudioIn::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/Enigma", undef, $rips, \@media);
is($dest, "$cd/Enigma/The Cross of Changes", 'podrazumevano ime = ime foldera rip-a');
($dest) = Plugins::AudioIn::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/Enigma", 'Enigma - The Cross of Changes (1993)', $rips, \@media);
is($dest, "$cd/Enigma/Enigma - The Cross of Changes (1993)", 'zadato ime');
$mk->("$cd/Enigma/Taken");
(undef, $err) = Plugins::AudioIn::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/Enigma", 'Taken', $rips, \@media);
is($err, 'exists', 'postoji: nikad se ne prepisuje');
(undef, $err) = Plugins::AudioIn::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$root/Muzika", undef, $rips, \@media);
is($err, 'outside_library', 'odrediste van biblioteke');
(undef, $err) = Plugins::AudioIn::Library::plan_move_to("$root/x/y", "$cd/Enigma", undef, $rips, \@media);
is($err, 'outside_rips', 'izvor van rip foldera');
# odrediste samo za citanje (npr. mrezno deljenje montirano ro): not_writable pre kopiranja
$mk->("$cd/RO");
chmod 0555, $fs->("$cd/RO");
SKIP: {
	skip 'folder 0555 je i dalje upisiv (root ili FS bez prava)', 1 if -w $fs->("$cd/RO");
	(undef, $err) = Plugins::AudioIn::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/RO", undef, $rips, \@media);
	is($err, 'not_writable', 'odrediste samo za citanje: not_writable');
}
chmod 0755, $fs->("$cd/RO");

# drugi disk (EXDEV): cp -R u .part (bez -a/-p: exFAT/NTFS/SMB ne dozvoljavaju chown), pa rename
{
	require POSIX;
	$mk->("$rips/X/Album");
	open(my $af, '>', $fs->("$rips/X/Album/01.flac")) or die; print {$af} 'flac'; close $af;
	my (@argv, @res);
	Plugins::AudioIn::Library::move_async("$rips/X/Album", "$cd/X/Album",
		rename  => sub { $! = POSIX::EXDEV(); 0 },
		spawn   => sub { my ($a, $c) = @_; push @argv, [@$a]; $c->(system(@$a) >> 8) },
		on_done => sub { @res = @_ });
	is_deeply([ @{ $argv[0] }[0 .. 2] ], [ 'cp', '-R', '--' ], 'EXDEV: cp -R');
	ok(!(grep { /^-(?:a|p)\z|^--preserve/ } @{ $argv[0] }), 'EXDEV: vlasnik i prava se ne prenose');
	ok($res[0], 'EXDEV: premesteno') or diag $res[1];
	ok(-f $fs->("$cd/X/Album/01.flac") && !-d $fs->("$rips/X/Album"), 'EXDEV: kopija na odredistu, izvor obrisan');
}

# celo premestanje (isti FS)
my ($ok, $merr) = Plugins::AudioIn::Library::move("$rips/Enigma/The Cross of Changes", "$cd/Enigma/The Cross of Changes", rips_root => $rips);
ok($ok, 'premesteno') or diag $merr;
ok(-d $fs->("$cd/Enigma/The Cross of Changes"), 'na odredistu');
ok(!-d $fs->("$rips/Enigma"), 'prazan folder izvodjaca u rip folderu uklonjen');
done_testing;
