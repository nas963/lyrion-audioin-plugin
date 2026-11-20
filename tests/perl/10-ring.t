use strict;
use warnings;
use Test::More;

use Plugins::AudioIn::Ring;

my $fr = sub { join '', map { pack('a6', sprintf('%06d', $_)) } @_ };    # frejm = 6 cifara rednog broja

my $r = Plugins::AudioIn::Ring->new(frames => 10, frame_bytes => 6);
is($r->head, 0, 'prazan: head 0');
is($r->tail, 0, 'prazan: tail 0');
my ($d, $from) = $r->read(0, 5);
is($d, '', 'prazan: nista za citanje');

is($r->write($fr->(0 .. 3)), 4, 'upis 4 frejma');
($d, $from) = $r->read(0, 10);
is($d, $fr->(0 .. 3), 'citanje svih');
is($from, 0, 'od 0');
($d, $from) = $r->read(2, 1);
is($d, $fr->(2), 'citanje jednog od sredine');

# nepotpun frejm se cuva za sledeci upis
is($r->write(substr($fr->(4), 0, 4)), 0, 'pola frejma: 0 upisano');
is($r->write(substr($fr->(4), 4) . $fr->(5)), 2, 'ostatak + jos jedan');
is($r->head, 6, 'head 6');

# prelivanje: kapacitet 10, upis do 15
$r->write($fr->(6 .. 15));
is($r->head, 16, 'head 16');
is($r->tail, 6, 'tail 6 (najstariji raspoloziv)');
($d, $from) = $r->read(2, 3);
is($from, 6, 'pozicija ispod tail-a se pomera na tail');
is($d, $fr->(6 .. 8), 'podaci od tail-a');
($d, $from) = $r->read(8, 100);
is($d, $fr->(8 .. 15), 'citanje preko granice bafera (wrap)');
($d, $from) = $r->read(16, 5);
is($d, '', 'na head-u nema podataka');
($d, $from) = $r->read(20, 5);
is($d, '', 'iznad head-a nema podataka');

# upis veci od kapaciteta odjednom
my $r2 = Plugins::AudioIn::Ring->new(frames => 4, frame_bytes => 6);
$r2->write($fr->(0 .. 9));
is($r2->head, 10, 'veliki upis: head');
($d) = $r2->read(0, 10);
is($d, $fr->(6 .. 9), 'veliki upis: ostaju poslednja 4');

eval { Plugins::AudioIn::Ring->new(frames => 0) };
like($@, qr/frames/, 'kapacitet 0 nije dozvoljen');

done_testing;
