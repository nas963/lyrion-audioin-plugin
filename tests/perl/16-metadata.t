use strict;
use warnings;
use utf8;
use Test::More;

use Plugins::AudioIn::Metadata;

sub fx { my ($f) = @_; open(my $fh, '<:raw', "t/fixtures/mb/$f") or die "$f: $!"; local $/; return <$fh> }

# URL-ovi
my $u = Plugins::AudioIn::Metadata::search_url('Pink Floyd', 'The Dark Side of the Moon');
like($u, qr{^https://musicbrainz\.org/ws/2/release\?query=artist%3A%22Pink%20Floyd%22%20AND%20release%3A%22The%20Dark%20Side%20of%20the%20Moon%22&fmt=json&limit=25\z}, 'search url');
like(Plugins::AudioIn::Metadata::search_url('AC/DC', 'Đorđe: "X"'), qr/AC%5C%2FDC.*%C4%90or%C4%91e%5C%3A%20%5C%22X%5C%22/, 'Lucene escape + UTF-8');
ok(!defined Plugins::AudioIn::Metadata::search_url('', ''), 'prazna pretraga');
ok(!defined Plugins::AudioIn::Metadata::release_url('../x'), 'los id');

# pretraga
my $s = Plugins::AudioIn::Metadata::parse_search(fx('search-dsotm.json'), 'vinyl');
ok(@$s >= 1, 'rezultati pretrage');
is($s->[0]{artist}, 'Pink Floyd', 'izvodjac');
like($s->[0]{formats}, qr/Vinyl/, 'format');
ok($s->[0]{match}, 'vinil odgovara vrsti izvora');

# izdanje sa stranama A/B
my $r = Plugins::AudioIn::Metadata::parse_release(fx('release-dsotm2.json'));
is($r->{album}, 'The Dark Side of the Moon', 'album');
is($r->{year}, 2015, 'godina izdanja (reizdanje)');
is($r->{original_year}, 1973, 'originalna godina');
ok($r->{has_cover}, 'ima omot');
my $sides = Plugins::AudioIn::Metadata::sides($r);
is_deeply([ map { $_->{name} } @$sides ], [qw(A B)], 'strane A i B');
is(scalar @{ $sides->[0]{tracks} }, 5, 'strana A: 5 pesama');
ok($sides->[0]{tracks}[0]{length} > 30, 'trajanje u sekundama');
ok($sides->[0]{tracks}[0]{recording_id}, 'recording id');
my $a = Plugins::AudioIn::Metadata::assign($r, [ { name => 'A' }, { name => 'B' } ]);
is($a->{B}[0]{number}, 'B1', 'deo B dobija stranu B');

# dupli LP: strane A-D na dva medija
$r = Plugins::AudioIn::Metadata::parse_release(fx('release-wall.json'));
$sides = Plugins::AudioIn::Metadata::sides($r);
is_deeply([ map { $_->{name} } @$sides ], [qw(A B C D)], 'dupli LP: A-D');
$a = Plugins::AudioIn::Metadata::assign($r, [ map { { name => $_ } } qw(A B C D) ]);
is(scalar @{ $a->{D} }, 7, 'strana D: 7 pesama');

# izdanje bez oznaka strana (1..10): raspodela po trajanju muzike na snimku
$r = Plugins::AudioIn::Metadata::parse_release(fx('release-dsotm.json'));
$sides = Plugins::AudioIn::Metadata::sides($r);
ok(!defined $sides->[0]{name}, 'bez oznaka strana');
my @len = map { $_->{length} } @{ $sides->[0]{tracks} };
my $sideA = 0;
$sideA += $len[$_] for 0 .. 4;
$a = Plugins::AudioIn::Metadata::assign($r, [ { name => 'A', seconds => $sideA + 3 }, { name => 'B', seconds => 1000 } ]);
is(scalar @{ $a->{A} }, 5, 'strana A: prvih 5 po trajanju');
is(scalar @{ $a->{B} }, 5, 'strana B: ostatak');
done_testing;
