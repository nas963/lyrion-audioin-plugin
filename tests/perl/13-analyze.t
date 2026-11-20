use strict;
use warnings;
use Test::More;
use lib 't/lib';

use Plugins::AudioIn::Analyze;
use Plugins::AudioIn::Peaks;
use SynthRecord;

my $rec = SynthRecord::make(rate => 8000);
my $rate = $rec->{rate};
my $p = Plugins::AudioIn::Peaks->new(rate => $rate);
my $peaks = Plugins::AudioIn::Peaks::parse($p->add($rec->{pcm}) . $p->flush);
my @want = @{ $rec->{tracks} };

sub near { my ($got, $exp, $tol, $name) = @_; ok(abs($got - $exp) <= $tol, sprintf('%s (%.2f s, ocekivano %.2f s)', $name, $got / $rate, $exp / $rate)) }

# 1. samo tisina
my $r = Plugins::AudioIn::Analyze::analyze(peaks => $peaks, rate => $rate, frames => $rec->{frames});
ok($r->{floor_db} < -50 && $r->{floor_db} > -70, "pod suma $r->{floor_db} dBFS");
ok($r->{thr_db} <= -45, "prag $r->{thr_db} dBFS");
is(scalar @{ $r->{tracks} }, 4, '4 pesme (tih prolaz i klikovi ne seku)') or diag explain $r->{tracks};
my $tol = 0.06 * $rate;
near($r->{tracks}[0]{start}, $want[0][0] - 0.5 * $rate, $tol, 'prva pesma: 0.5 s pre zvuka');
for my $i (1 .. 3) {
	near($r->{tracks}[$i]{start}, $want[$i][0] - 0.5 * $rate, $tol, "pesma " . ($i + 1) . ": 0.5 s pre zvuka");
	is($r->{tracks}[$i]{from}, 'silence', "pesma " . ($i + 1) . ": granica iz pauze");
	is($r->{tracks}[ $i - 1 ]{end}, $r->{tracks}[$i]{start}, "pesme " . $i . "/" . ($i + 1) . " se nastavljaju bez rupe");
}
near($r->{tracks}[-1]{end}, $want[-1][1] + 1.5 * $rate, $tol, 'kraj: 1.5 s posle zvuka (izlazni zleb odsecen)');

# 2. sredina pauze
$r = Plugins::AudioIn::Analyze::analyze(peaks => $peaks, rate => $rate, opt => { place => 'middle' });
near($r->{tracks}[1]{start}, ($want[0][1] + $want[1][0]) / 2, 0.1 * $rate, 'granica na sredini pauze');

# 3. rucni marker 3 s posle pocetka pauze se pomera na pauzu; marker daleko od pauze ostaje
my $late = $want[1][0] + 3 * $rate;
my $far = $want[0][0] + 10 * $rate;    # sredina prve pesme: 10 s od pauza
$r = Plugins::AudioIn::Analyze::analyze(peaks => $peaks, rate => $rate,
	markers => [ { frame => $late, kind => 'user' }, { frame => $far, kind => 'user' } ]);
is(scalar @{ $r->{tracks} }, 5, q(marker usred prve pesme dodaje granicu));
is($r->{tracks}[2]{from}, q(user), 'marker blizu pauze -> granica pauze, izvor user');
near($r->{tracks}[2]{start}, $want[1][0] - 0.5 * $rate, $tol, q(marker pomeren na pauzu));
is($r->{tracks}[1]{start}, $far, 'marker bez pauze u krugu ostaje gde je');

# 4. ocekivana trajanja: 3 pesme po metapodacima (druga i treca su "jedna" pesma bez pauze nije moguce,
#    pa uzimamo trajanja koja spajaju pesme 3 i 4) -> bira 2 granice od 3 pauze
my @d = (($want[0][1] - $want[0][0]) / $rate + 2, ($want[1][1] - $want[1][0]) / $rate + 1.5,
	($want[3][1] - $want[2][0]) / $rate + 1.5);
$r = Plugins::AudioIn::Analyze::analyze(peaks => $peaks, rate => $rate, durations => \@d);
is(scalar @{ $r->{tracks} }, 3, 'trajanja: tacno 3 pesme');
near($r->{tracks}[2]{start}, $want[2][0] - 0.5 * $rate, $tol, 'trajanja: izostavljena pauza izmedju 3. i 4.');

# 5. trajanja bez pauze za granicu -> procena
@d = (10, 10, (($want[0][1] - $want[0][0]) / $rate) - 18 + 2, map { ($_->[1] - $_->[0]) / $rate + 2 } @want[ 1 .. 3 ]);
$r = Plugins::AudioIn::Analyze::analyze(peaks => $peaks, rate => $rate, durations => \@d);
is(scalar @{ $r->{tracks} }, 6, 'trajanja: 6 pesama');
ok((grep { $_->{from} eq 'estimate' } @{ $r->{tracks} }), 'granica bez pauze je procena');

# 6. prazno i tisina
$r = Plugins::AudioIn::Analyze::analyze(peaks => [], rate => $rate, frames => 1000);
is_deeply($r->{tracks}, [ { start => 0, end => 1000, from => 'edge' } ], 'prazno: ceo snimak');
$r = Plugins::AudioIn::Analyze::analyze(peaks => [ map { [ 2, 2, 1 ] } 1 .. 500 ], rate => $rate);
is(scalar @{ $r->{tracks} }, 1, 'samo sum: jedna celina');

done_testing;
