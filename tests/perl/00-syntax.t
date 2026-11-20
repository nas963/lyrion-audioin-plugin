use strict;
use warnings;
use Test::More;
use lib 't/lib';
use LMSBoot;

# Svi moduli plugina se ucitavaju u LMS okruzenju (Slim::* putanje).
my @mods = map { "lib/Plugins/AudioIn/$_.pm" } qw(Ring Pcm Peaks Paths Tools Jobs Config Sessions State Analyze Naming Export Editor Devices Settings Metadata Library Menu MaterialBridge
	Capture CaptureClient ProtocolHandler Web Plugin);
for my $f (@mods) {
	like(LMSBoot::syntax($f), qr/syntax OK/, $f);
}
like(scalar `perl -c lib/Plugins/AudioIn/Bin/audioin-tap 2>&1`, qr/syntax OK/, 'audioin-tap');
done_testing;
