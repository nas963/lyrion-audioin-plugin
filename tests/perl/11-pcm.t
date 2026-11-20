use strict;
use warnings;
use Test::More;

use Plugins::AudioIn::Pcm;
use Plugins::AudioIn::Peaks;

my $s24 = \&Plugins::AudioIn::Pcm::pack_s24;

# pack_s24 / top16
is(unpack('H*', $s24->(1, -1)), '010000ffffff', 'pack_s24: 1 i -1');
is_deeply([ Plugins::AudioIn::Pcm::top16($s24->(0x7FFF00, -0x800000)) ], [ 32767, -32768 ], 'top16');

# konverzije u stereo S24_3LE
my $c = Plugins::AudioIn::Pcm::converter(fmt => 'S16_LE', channels => 2);
is(unpack('H*', $c->(pack('s<2', 0x1234, -2))), '003412' . '00feff', 'S16 -> S24 (sirenje nulom)');
is($c->(pack('C', 1)), '', 'S16: nepotpun frejm ceka');
is(unpack('H*', $c->(pack('C3', 0, 0, 0))), '000100000000', 'S16: ostatak + novi bajtovi');

$c = Plugins::AudioIn::Pcm::converter(fmt => 'S32_LE', channels => 2);
is(unpack('H*', $c->(pack('l<2', 0x12345600, -256))), '563412' . 'ffffff', 'S32 -> S24 (najnizi bajt pada)');

$c = Plugins::AudioIn::Pcm::converter(fmt => 'S24_3LE', channels => 2);
my $x = $s24->(5, 6, 7, 8);
is($c->($x), $x, 'S24_3LE stereo: bez promene');

$c = Plugins::AudioIn::Pcm::converter(fmt => 'S24_3LE', channels => 4, left => 2, right => 3);
is($c->($s24->(1, 2, 3, 4, 5, 6, 7, 8)), $s24->(3, 4, 7, 8), '4 kanala: par 3-4');

$c = Plugins::AudioIn::Pcm::converter(fmt => 'S16_LE', channels => 2, left => 0, right => 0);
is($c->(pack('s<2', 1, 9)), "\0\1\0\0\1\0", 'mono: levi kanal u oba');

eval { Plugins::AudioIn::Pcm::converter(fmt => 'S24_3LE', channels => 2, left => 2) };
like($@, qr/opsega/, 'kanal van opsega');

# nivoi
my $l = Plugins::AudioIn::Pcm::levels($s24->(0x400000, -0x200000, -0x400000, 0));
is($l->{frames}, 2, 'levels: frejmovi');
is_deeply($l->{peak}, [ 16384, 8192 ], 'levels: vrhovi');
is($l->{clip}, 0, 'levels: bez klipovanja');
is(Plugins::AudioIn::Pcm::dbfs(16384), -6, 'dbfs pola skale');
ok(!defined Plugins::AudioIn::Pcm::dbfs(0), 'dbfs tisina');
is(Plugins::AudioIn::Pcm::levels($s24->(0x7FFFFF, 0))->{clip}, 1, 'klipovanje');

# peaks
my $p = Plugins::AudioIn::Peaks->new(rate => 1000);    # prozor 10 frejmova
is($p->window_frames, 10, 'prozor 10 ms');
my $out = $p->add($s24->((0x100000, -0x200000) x 15));
my $rec = Plugins::AudioIn::Peaks::parse($out);
is(scalar @$rec, 1, 'jedan zavrsen prozor');
is_deeply([ @{ $rec->[0] }[ 0, 1 ] ], [ 4096, 8192 ], 'vrhovi u prozoru');
is($rec->[0][2], int(sqrt((4096**2 + 8192**2) / 2) + 0.5), 'rms prozora');
$rec = Plugins::AudioIn::Peaks::parse($p->flush);
is(scalar @$rec, 1, 'flush: nepotpun prozor');
is($p->flush, '', 'drugi flush prazan');

done_testing;
