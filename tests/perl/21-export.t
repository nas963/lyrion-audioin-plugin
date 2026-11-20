use strict;
use warnings;
use utf8;
use Test::More;
use lib 't/lib';

# Izvoz: sinteticka strana -> take.flac, analiza -> pesme, izvoz u FLAC-ove sa tagovima,
# bit-identican isecak (dekodirani uzorci pesme = isti opseg snimka).

use File::Temp ();
use Plugins::AudioIn::Analyze;
use Plugins::AudioIn::Export;
use Plugins::AudioIn::Jobs;
use Plugins::AudioIn::Peaks;
use Plugins::AudioIn::Tools;
use SynthRecord;

my $flac = Plugins::AudioIn::Tools::find('flac');
my $meta = Plugins::AudioIn::Tools::find('metaflac');
plan skip_all => 'nema flac/metaflac' unless $flac && $meta;

my $dir = File::Temp::tempdir(CLEANUP => 1);
my $rec = SynthRecord::make(rate => 8000);
my $rate = $rec->{rate};
my $take = "$dir/A-1.flac";
{
	open(my $fh, '|-', $flac, '--silent', '-0', '--force-raw-format', '--endian=little', '--sign=signed', '--channels=2',
		'--bps=24', "--sample-rate=$rate", '-o', $take, '-') or die;
	binmode $fh;
	print $fh $rec->{pcm};
	close $fh or die "flac: $?";
}
my $p = Plugins::AudioIn::Peaks->new(rate => $rate);
my $an = Plugins::AudioIn::Analyze::analyze(peaks => Plugins::AudioIn::Peaks::parse($p->add($rec->{pcm}) . $p->flush), rate => $rate);
is(scalar @{ $an->{tracks} }, 4, 'analiza: 4 pesme');

my @titles = ('Prva', 'Druga: deo/2', 'Treća', 'Četvrta');
my @tracks = map { { start => $an->{tracks}[$_]{start}, end => $an->{tracks}[$_]{end}, title => $titles[$_], keep => 1 } } 0 .. 3;
$tracks[2]{keep} = 0;    # treca se ne cuva
my $s = {
	id => '20261119-120000', type => 'vinyl', meta => { artist => 'Test Izvođač', album => 'Ploča', year => '1979' },
	parts => [ { name => 'A', takes => [ { name => 'A-1', file => 'A-1.flac', ok => 1, rate => $rate, frames => $rec->{frames},
		tracks => \@tracks } ] }, { name => 'B', takes => [] } ],
};

my ($plan, $err) = Plugins::AudioIn::Export::plan(session => $s, take_path => sub { $take }, root => "$dir/out", res_tag => 1);
ok($plan, 'plan') or diag $err;
is($plan->{dir}, "$dir/out/Test Izvođač/Ploča (1979) [24-8]", 'folder albuma sa godinom i rezolucijom');
is(scalar @{ $plan->{tracks} }, 3, 'izvoze se samo stiklirane pesme');
is($plan->{tracks}[1]{file}, '02 - Druga- deo-2.flac', 'naziv fajla bezbedan za Windows');
my %tags = map { @$_ } @{ $plan->{tracks}[2]{tags} };
is($tags{TRACKNUMBER}, 3, 'numeracija preskace necuvanu');
is($tags{VINYLTRACK}, 'A4', 'pozicija na strani ostaje A4');
is($tags{MEDIA}, '12" Vinyl', 'MEDIA');

my ($none) = Plugins::AudioIn::Export::plan(session => { parts => [] }, take_path => sub { $take }, root => $dir);
ok(!$none, 'bez pesama nema plana');

my $ex = Plugins::AudioIn::Export->new(spawn => sub { Plugins::AudioIn::Jobs->spawn(@_) });
my ($ok) = $ex->start(plan => $plan, session => $s->{id}, root => "$dir/out", flac => $flac, level => 0);
ok($ok, 'izvoz pokrenut');
my ($ok2, $e2) = $ex->start(plan => $plan, session => $s->{id}, root => "$dir/out");
is($e2->{error}, 'export_busy', 'drugi izvoz dok traje: busy');
Plugins::AudioIn::Jobs::run_loop_for_tests(60);
my $last = $ex->snapshot;
ok($last->{ok}, 'izvoz uspeo') or diag explain $last;
is($last->{total}, 3, '3 pesme');
my $out = $plan->{dir};
ok(-f "$out/01 - Prva.flac", 'prva pesma');
ok(-f "$out/audioin.log", 'log izvoza');
ok(!-d "$dir/out/.export-tmp/$s->{id}", 'privremeni folder uklonjen');

for my $i (0, 1) {
	my $t = $plan->{tracks}[$i];
	my $f = "$out/$t->{file}";
	my $n = `'$meta' --show-total-samples '$f'`;
	chomp $n;
	is($n, $t->{until} - $t->{skip}, "pesma " . ($i + 1) . ": broj uzoraka = granice");
	my $pcm = `'$flac' -dcs --force-raw-format --endian=little --sign=signed '$f'`;
	ok($pcm eq substr($rec->{pcm}, $t->{skip} * 6, ($t->{until} - $t->{skip}) * 6), "pesma " . ($i + 1) . ": bit-identicna snimku");
}
my $title = `'$meta' --show-tag=TITLE '$out/02 - Druga- deo-2.flac'`;
like($title, qr/TITLE=Druga: deo\/2/, 'tag TITLE sa originalnim znakovima');

# drugi izvoz iste sesije ne gazi prvi
($ok) = $ex->start(plan => $plan, session => $s->{id}, root => "$dir/out", flac => $flac, level => 0);
Plugins::AudioIn::Jobs::run_loop_for_tests(60);
is($ex->snapshot->{dir}, "$plan->{dir} (2)", 'ponovni izvoz ide u " (2)"');

done_testing;
