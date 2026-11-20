use strict;
use warnings;
use Test::More;

# Pomocni proces audioin-capture sa fajl izvorom (bez kartice): citac preko audioin-tap,
# snimanje sa pred-snimanjem, markerom i pauzom, .flac/.peaks/.json na kraju.

use File::Temp ();
use IPC::Open2 ();
use IO::Select ();
use JSON::PP ();
use POSIX ();
use Time::HiRes qw(time sleep);

use Plugins::AudioIn::Pcm;
use Plugins::AudioIn::Tools;

plan skip_all => 'nema flac/metaflac' unless Plugins::AudioIn::Tools::find('flac') && Plugins::AudioIn::Tools::find('metaflac');

my $dir = File::Temp::tempdir(CLEANUP => 1);
$ENV{AUDIOIN_RUN_DIR} = "$dir/run";
mkdir "$dir/run";

# 3 s, 48 kHz, 24 bit stereo: ton 1 kHz na -6 dBFS
my $rate = 48000;
my $wav = "$dir/in.wav";
{
	my $pcm = '';
	for my $i (0 .. $rate * 3 - 1) {
		my $v = int(0x400000 * sin(2 * 3.14159265 * 1000 * $i / $rate));
		$pcm .= Plugins::AudioIn::Pcm::pack_s24($v, -$v);
	}
	open(my $fh, '>:raw', $wav) or die;
	print $fh 'RIFF', pack('V', 36 + length $pcm), 'WAVE', 'fmt ', pack('V v v V V v v', 16, 1, 2, $rate, $rate * 6, 6, 24),
		'data', pack('V', length $pcm), $pcm;
	close $fh;
}

my $JSON = JSON::PP->new;
my $pid = IPC::Open2::open2(my $out, my $in, $^X, (map { "-I$_" } @INC), '-MPlugins::AudioIn::Capture',
	'-e', 'Plugins::AudioIn::Capture::main()', '--', '--run-dir', "$dir/run", '--ring-sec', 20);
my $sel = IO::Select->new($out);
my @events;
my $buf = '';

sub send_cmd { print $in $JSON->encode($_[0]), "\n"; $in->flush }

# Ceka dogadjaj koji zadovoljava $test, najvise $secs.
sub wait_ev {
	my ($test, $secs) = @_;
	my $deadline = time + ($secs || 5);
	while (time < $deadline) {
		for my $i (0 .. $#events) {
			return splice(@events, $i, 1) if $test->($events[$i]);
		}
		next unless $sel->can_read(0.1);
		my $n = sysread($out, my $chunk, 65536);
		last unless $n;
		$buf .= $chunk;
		while ($buf =~ s/\A([^\n]*)\n//) {
			my $e = eval { $JSON->decode($1) } or next;
			push @events, $e;
		}
	}
	return undef;
}

ok(wait_ev(sub { $_[0]{ev} eq 'ready' }), 'pomocnik spreman');
ok(-S "$dir/run/tap.sock", 'socket za citace postoji');

send_cmd({ cmd => 'open', src => 'file', path => "$dir/nema.wav" });
my $e = wait_ev(sub { $_[0]{ev} eq 'closed' });
is($e && $e->{err}, 'no_file', 'nepostojeci fajl: greska');

send_cmd({ cmd => 'open', src => 'file', path => $wav, loop => 1 });
$e = wait_ev(sub { $_[0]{ev} eq 'opened' });
ok($e, 'fajl izvor otvoren');
is($e && $e->{rate}, $rate, 'frekvencija iz fajla');

# merac
send_cmd({ cmd => 'meter', on => 1 });
$e = wait_ev(sub { $_[0]{ev} eq 'meter' }, 3);
ok($e, 'dogadjaj merca');
ok($e && abs($e->{pk}[0] - -6) < 0.5, 'merac: vrh oko -6 dBFS') or diag explain $e;

# citac preko audioin-tap: posle 1 s ima ~1 s + delay zvuka
sleep 1;
my $tap = "$INC[0]/Plugins/AudioIn/Bin/audioin-tap";
($tap) = grep { -f } map { "$_/Plugins/AudioIn/Bin/audioin-tap" } @INC unless -f $tap;
open(my $tfh, '-|', $^X, $tap, 'audioin://live?delay=0.5') or die "tap: $!";
binmode $tfh;
my $t0 = time;
my $got = '';
my $tsel = IO::Select->new($tfh);
while (time - $t0 < 1.5) {
	next unless $tsel->can_read(0.1);
	my $n = sysread($tfh, my $chunk, 65536);
	last unless $n;
	$got .= $chunk;
}
my $secs = length($got) / 6 / $rate;
ok($secs > 1.6 && $secs < 2.4, sprintf('citac: %.2f s zvuka za 1.5 s (0.5 s unapred + realno vreme)', $secs));
is(length($got) % 6, 0, 'citac: celi frejmovi');
my @v = Plugins::AudioIn::Pcm::top16(substr($got, 0, 600));
ok((grep { abs($_) > 10000 } @v), 'citac: u podacima je ton');
$e = wait_ev(sub { $_[0]{ev} eq 'client' && $_[0]{n} == 1 });
ok($e, 'pomocnik javlja citaca');
close $tfh;

# snimanje: pred-snimanje 0.5 s, marker, pauza 0.5 s, nastavak, stop
send_cmd({ cmd => 'rec_start', id => 't1', path => "$dir/take.flac", preroll => 0.5, level => 0 });
$e = wait_ev(sub { $_[0]{ev} eq 'rec' });
is($e && $e->{state}, 'rec', 'snimanje pocelo');
ok($e && abs($e->{preroll} - 0.5) < 0.01, 'pred-snimanje 0.5 s');
sleep 0.5;
send_cmd({ cmd => 'marker' });
$e = wait_ev(sub { $_[0]{ev} eq 'marker' });
ok($e && $e->{frame} > $rate * 0.9 && $e->{frame} < $rate * 1.2, 'marker oko 1 s u fajlu') or diag explain $e;
send_cmd({ cmd => 'rec_pause' });
ok(wait_ev(sub { $_[0]{ev} eq 'rec' && $_[0]{state} eq 'paused' }), 'pauza');
sleep 0.5;
send_cmd({ cmd => 'rec_resume' });
ok(wait_ev(sub { $_[0]{ev} eq 'marker' && $_[0]{kind} eq 'pause' }), 'nastavak pravi marker pauze');
sleep 0.5;
send_cmd({ cmd => 'rec_stop' });
$e = wait_ev(sub { $_[0]{ev} eq 'rec' && $_[0]{state} eq 'stopped' }, 15);
ok($e && $e->{ok}, 'snimak zavrsen') or diag explain $e;
ok(-f "$dir/take.flac", '.flac postoji');
ok(!-e "$dir/take.flac.part", 'nema .part');

my $meta = Plugins::AudioIn::Tools::find('metaflac');
my ($total, $srate, $bps) = split /\s+/, `$meta --show-total-samples --show-sample-rate --show-bps $dir/take.flac`;
is($total, $e->{frames}, 'broj uzoraka u fajlu = javljeno');
is($srate, $rate, 'frekvencija fajla');
is($bps, 24, '24 bit');
my $len = $total / $rate;
ok($len > 1.4 && $len < 1.9, sprintf(q(trajanje %.2f s: 0.5 pred-snimanje + ~0.5 do pauze + ~0.5 posle nastavka), $len));

my $peaks = -s "$dir/take.peaks";
is($peaks, 6 * POSIX::ceil($total / ($rate / 100)), '.peaks: jedan zapis po 10 ms');
open(my $jf, '<', "$dir/take.json") or die;
my $j = $JSON->decode(do { local $/; <$jf> });
is($j->{frames}, $total, '.json: frejmovi');
is(scalar @{ $j->{segments} }, 2, '.json: dva segmenta (pauza)');
is_deeply([ map { $_->{kind} } @{ $j->{markers} } ], [ 'user', 'pause' ], '.json: markeri');
ok($j->{done} && $j->{ok}, '.json: zavrsen');

# drugi snimak dok prvi ne postoji vise; zatvaranje izvora usred snimka zatvara snimak
send_cmd({ cmd => 'rec_start', id => 't2', path => "$dir/take2.flac", preroll => 0, level => 0 });
ok(wait_ev(sub { $_[0]{ev} eq 'rec' && $_[0]{state} eq 'rec' }), 'drugi snimak');
sleep 0.3;
send_cmd({ cmd => 'close' });
$e = wait_ev(sub { $_[0]{ev} eq 'rec' && $_[0]{state} eq 'stopped' }, 15);
ok($e && $e->{ok}, 'zatvaranje ulaza zavrsava snimak');

# EOF na stdin-u gasi pomocnika
close $in;
my $t = time;
while (time - $t < 5) { last if waitpid($pid, POSIX::WNOHANG()) == $pid; sleep 0.1 }
ok(!kill(0, $pid), 'pomocnik izlazi na EOF');
ok(!-e "$dir/run/tap.sock", 'socket obrisan');

done_testing;
