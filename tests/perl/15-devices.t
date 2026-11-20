use strict;
use warnings;
use Test::More;

use File::Copy ();
use File::Temp ();
use Plugins::AudioIn::Devices;

my $fx = 't/fixtures/asound';

# Audio$OS sa Omegom: SMSL (samo izlaz) + Omega (2 stereo ulaza)
my $root = File::Temp::tempdir(CLEANUP => 1);
File::Copy::copy("$fx/omega-cards.txt", "$root/cards");
File::Copy::copy("$fx/omega-pcm.txt", "$root/pcm");
mkdir "$root/card0";
mkdir "$root/card1";
File::Copy::copy("$fx/smsl-stream0.txt", "$root/card0/stream0");
File::Copy::copy("$fx/omega-stream0.txt", "$root/card1/stream0");
File::Copy::copy("$fx/omega-stream1.txt", "$root/card1/stream1");

my $l = Plugins::AudioIn::Devices::list(root => $root);
is(scalar @$l, 2, 'dva ulaza (SMSL nema capture)');
is($l->[0]{dev}, 'hw:CARD=Omega,DEV=0', 'ime po kartici, ne indeksu');
is($l->[1]{dev}, 'hw:CARD=Omega,DEV=1', 'drugi ulaz');
is($l->[0]{card_name}, 'Lexicon Omega', 'naziv kartice');
ok($l->[0]{usb}, 'USB');
is_deeply($l->[0]{formats}, [qw(S24_3LE S16_LE)], 'formati za snimanje, 24 bit prvi');
is_deeply($l->[0]{rates}, [ 44100, 48000 ], 'frekvencije');
is_deeply($l->[0]{channels}, [2], 'kanali');
is(Plugins::AudioIn::Devices::best_format($l->[0]{formats}), 'S24_3LE', 'najbolji format');
is(Plugins::AudioIn::Devices::best_rate($l->[0]{rates}, 96000), 48000, '96 kHz nije podrzano -> 48 kHz');
is(Plugins::AudioIn::Devices::best_rate([ 44100, 48000, 96000 ], 96000), 96000, '96 kHz podrzano');
is(Plugins::AudioIn::Devices::best_rate([ 88200, 96000 ], 48000), 88200, 'samo vece -> najmanja');

# SMSL stream: samo playback, capture deo prazan
my $s = Plugins::AudioIn::Devices::parse_stream(do { local (@ARGV, $/) = "$fx/smsl-stream0.txt"; <> });
is_deeply($s->{formats}, [], 'SMSL: nema capture formata');

# Razvojni server: HDA kartica (nije USB, nema stream fajla -> mogucnosti nepoznate)
my $dev = do { local (@ARGV, $/) = "$fx/devsrv.txt"; <> };
my ($cards, $pcm) = split /^===\n/m, $dev;
my $r2 = File::Temp::tempdir(CLEANUP => 1);
open(my $fh, '>', "$r2/cards") or die; print $fh $cards; close $fh;
open($fh, '>', "$r2/pcm") or die; print $fh $pcm; close $fh;
$l = Plugins::AudioIn::Devices::list(root => $r2);
is_deeply([ map { $_->{dev} } @$l ], [ 'hw:CARD=PCH,DEV=0', 'hw:CARD=PCH,DEV=2' ], 'HDA: dva analogna ulaza, HDMI preskocen');
ok(!$l->[0]{usb}, 'HDA nije USB');
is_deeply($l->[0]{rates}, [], 'HDA: frekvencije nepoznate');

# opseg frekvencija u stream fajlu
$s = Plugins::AudioIn::Devices::parse_stream("Capture:\n  Interface 1\n    Format: S32_LE\n    Channels: 4\n    Rates: 44100 - 192000 (continuous)\n");
is_deeply($s->{rates}, [ 44100, 48000, 88200, 96000, 176400, 192000 ], 'opseg -> uobicajene');
is_deeply($s->{channels}, [4], '4 kanala');

is_deeply(Plugins::AudioIn::Devices::list(root => '/nema'), [], 'nema /proc/asound');

# arecord --dump-hw-params (HDA)
my $hw = do { local (@ARGV, $/) = "$fx/hda-hw-params.txt"; <> };
my $caps = Plugins::AudioIn::Devices::parse_hw_params($hw);
is_deeply($caps->{formats}, [qw(S32_LE S16_LE)], q(HDA: formati, 32 bit pre 16));
is_deeply($caps->{rates}, [ 44100, 48000, 88200, 96000, 176400, 192000 ], q(HDA: opseg frekvencija));
is_deeply($caps->{channels}, [2], q(HDA: kanali));
is(Plugins::AudioIn::Devices::best_format($caps->{formats}), q(S32_LE), q(HDA: najbolji format S32_LE));
my @argv;
$caps = Plugins::AudioIn::Devices::probe(q(hw:CARD=PCH,DEV=0), arecord => q(/x/arecord), run => sub { @argv = @_; $hw });
is_deeply($caps->{rates}[0], 44100, q(probe: parsira izlaz));
is($argv[2], q(hw:CARD=PCH,DEV=0), q(probe: uredjaj u argv));
ok(!Plugins::AudioIn::Devices::probe(q(x), arecord => q(/x), run => sub { q(arecord: audio open error: Device or resource busy) }), q(probe: zauzet -> undef));
done_testing;
