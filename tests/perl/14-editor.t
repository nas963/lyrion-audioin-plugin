use strict;
use warnings;
use Test::More;
use lib 't/lib';

use File::Temp ();
use Plugins::AudioIn::Editor;
use Plugins::AudioIn::Peaks;
use Plugins::AudioIn::Sessions;
use SynthRecord;

my $root = File::Temp::tempdir(CLEANUP => 1);
my $ses = Plugins::AudioIn::Sessions->new(root => sub { $root });
my ($s) = $ses->create(type => 'vinyl');
my $rec = SynthRecord::make(rate => 8000);
my $dir = $ses->dir . "/$s->{id}";
my $p = Plugins::AudioIn::Peaks->new(rate => 8000);
open(my $fh, '>:raw', "$dir/A-1.peaks") or die; print $fh $p->add($rec->{pcm}) . $p->flush; close $fh;
open($fh, '>', "$dir/A-1.flac") or die; close $fh;
open($fh, '>', "$dir/A-1.json") or die; print $fh qq({"frames":$rec->{frames},"rate":8000,"markers":[]}); close $fh;
$ses->add_take($s, 'A', name => 'A-1', ok => 1);

my $ed = Plugins::AudioIn::Editor->new(sessions => $ses);
my ($ok, $err, $tracks) = $ed->analyze($s->{id}, 'A-1');
ok($ok, 'analiza') or diag explain $err;
is(scalar @$tracks, 4, '4 pesme');
ok((grep { $_->{keep} } @$tracks) == 4, 'sve stiklirane');

# naslovi i stikle ostaju posle ponovne analize
$tracks->[0]{title} = 'Prva';
$tracks->[2]{keep} = 0;
($ok) = $ed->set_tracks($s->{id}, 'A-1', $tracks);
ok($ok, 'izmene sacuvane');
($ok, $err, $tracks) = $ed->analyze($s->{id}, 'A-1');
is($tracks->[0]{title}, 'Prva', 'naslov ostaje posle analize');
is($tracks->[2]{keep}, 0, 'stikla ostaje posle analize');

($ok, $err) = $ed->set_tracks($s->{id}, 'A-1', [ { start => 100, end => 50 } ]);
is($err->{error}, 'bad_tracks', 'kraj pre pocetka');
($ok, $err) = $ed->set_tracks($s->{id}, 'A-1', [ { start => 0, end => 9e9 } ]);
is($err->{error}, 'bad_tracks', 'van snimka');
($ok, $err) = $ed->set_tracks($s->{id}, 'A-1', [ { start => 0, end => 100 }, { start => 50, end => 200 } ]);
is($err->{error}, 'bad_tracks', 'preklapanje');
($ok, $err) = $ed->set_tracks($s->{id}, 'X-9', [ { start => 0, end => 100 } ]);
is($err->{error}, 'no_take', 'nepostojeci snimak');

my ($ov) = $ed->overview($s->{id}, 'A-1', 500);
ok(@{ $ov->{points} } >= 500 && @{ $ov->{points} } <= 502, 'pregled: ~500 tacaka');
ok((grep { $_->[0] > 0.2 } @{ $ov->{points} }), 'pregled: ima muzike');
is($ov->{part}, 'A', 'pregled: strana');

# MusicBrainz izdanje: metapodaci, strane, naslovi i ID-jevi na snimku strane A
use Plugins::AudioIn::Metadata;
my $rel = Plugins::AudioIn::Metadata::parse_release(do { local (@ARGV, $/) = 't/fixtures/mb/release-dsotm2.json'; <> });
($ok, $err, my $res) = $ed->apply_release($s->{id}, $rel);
ok($ok, 'izdanje primenjeno') or diag explain $err;
is_deeply($res->{parts}, { A => 5, B => 5 }, 'strane A i B po 5 pesama');
is_deeply($res->{analyzed}, ['A-1'], 'snimak strane A ponovo analiziran');
my $s2 = $ses->get($s->{id});
is($s2->{meta}{album}, 'The Dark Side of the Moon', 'album');
is($s2->{meta}{year}, 1973, 'originalna godina');
is($s2->{meta}{mb_MUSICBRAINZ_ALBUMID}, $rel->{id}, 'MB album id');
my $tk = $s2->{parts}[0]{takes}[0];
is(scalar @{ $tk->{tracks} }, 5, 'snimak podeljen na 5 pesama po trajanjima');
is($tk->{tracks}[0]{title}, $rel->{media}[0]{tracks}[0]{title}, 'naslov sa izdanja');
like($tk->{tracks}[0]{mbid} // '', qr/^[0-9a-f-]{36}\z/, 'recording id');
ok($s2->{parts}[1]{mb_tracks}, 'strana B ceka snimak sa spremnim pesmama');
($ok) = $ed->set_tracks($s->{id}, 'A-1', $tk->{tracks});
is($ses->get($s->{id})->{parts}[0]{takes}[0]{tracks}[0]{mbid}, $tk->{tracks}[0]{mbid}, 'mbid ostaje posle cuvanja izmena');
done_testing;
