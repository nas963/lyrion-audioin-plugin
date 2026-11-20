use strict;
use warnings;
use Test::More;

use File::Temp ();
use Plugins::AudioIn::Sessions;
use Plugins::AudioIn::State;

my $root = File::Temp::tempdir(CLEANUP => 1);
my $ses = Plugins::AudioIn::Sessions->new(root => sub { $root });

# ---------- Sessions ----------
my ($s, $err) = $ses->create(type => 'vinyl', artist => 'Miles Davis', album => 'Kind of Blue', now => 1700000000);
ok($s, 'sesija napravljena') or diag $err;
like($s->{id}, qr/^\d{8}-\d{6}\z/, 'id sesije');
is_deeply([ map { $_->{name} } @{ $s->{parts} } ], [qw(A B)], 'ploca: strane A i B');
my ($s2) = $ses->create(type => 'radio', now => 1700000000);
is($s2->{id}, "$s->{id}-2", 'ista sekunda: sufiks -2');
is_deeply([ map { $_->{name} } @{ $s2->{parts} } ], [qw(1 2)], 'radio: delovi 1 i 2');
is(scalar @{ $ses->list }, 2, 'lista sesija');
is($ses->get('../etc'), undef, 'los id se odbija');

my $p = $ses->next_part($s, 'B');
is($p->{name}, 'C', 'posle B ide C');
ok(!$ses->ensure_part($s, 'A/B'), 'neispravno ime dela');
my ($path, $name) = $ses->new_take_path($s, $ses->part($s, 'A'));
is($name, 'A-1', 'prvi snimak strane A');
open(my $fh, '>', $path) or die; close $fh;
(undef, $name) = $ses->new_take_path($s, $ses->part($s, 'A'));
is($name, 'A-2', 'drugi snimak strane A');

# ---------- State ----------
my (@sent, $now, %player);
$now = 1000;
my %prefs = (source => 'file', testFile => '/x.flac', preroll => 5, flacLevel => 5, reaction => 0.5, idleClose => 10,
	sourceType => 'vinyl');
my $st = Plugins::AudioIn::State->new(
	send => sub { push @sent, $_[0]; 1 }, pref => sub { $prefs{ $_[0] } }, sessions => $ses, now => sub { $now },
	player_pos => sub { @{ $player{ $_[0] } || [] } },
);

my ($ok, $e) = $st->open_input;
is($e->{error}, 'helper', 'bez pomocnika nema otvaranja');
$st->on_event({ ev => 'ready' });
($ok) = $st->open_input;
ok($ok, 'otvaranje poslato');
is($sent[-1]{src}, 'file', 'komanda: fajl izvor');
$st->on_event({ ev => 'opened', rate => 48000, src => 'file', epoch => 1, head => 0 });
ok($st->snapshot->{input}{open}, 'ulaz otvoren');

# slusanje: citac koji se javi posle Slusaj pripada plejeru
$st->listen_started('aa:bb');
$st->on_event({ ev => 'client', n => 1, start => 480000, epoch => 1 });
$player{'aa:bb'} = [ 'audioin://live?delay=3', 2.5 ];
is($st->player_frame('aa:bb'), 480000 + 120000, 'pozicija plejera = start + odsvirano');

# snimanje bez sesije pravi novu
@sent = ();
($ok, $e) = $st->rec_start;
ok($ok, 'snimanje pocelo') or diag explain $e;
is($sent[0]{cmd}, 'rec_start', 'komanda rec_start');
like($sent[0]{path}, qr{/\.sessions/\d{8}-\d{6}(-\d+)?/A-1\.flac\z}, 'putanja snimka');
is($sent[0]{preroll}, 5, 'pred-snimanje iz podesavanja');
my $sid = $st->snapshot->{session}{id};
($ok, $e) = $st->rec_start;
is($e->{error}, 'recording', 'drugo snimanje nije dozvoljeno');

$st->on_event({ ev => 'rec', state => 'rec', id => $sent[0]{id}, preroll => 5 });
($ok, undef, my $how) = $st->marker(player => 'aa:bb');
is($how, 'player', 'marker po plejeru');
is($sent[-1]{pos}, 600000, 'marker: pozicija plejera');
($ok, undef, $how) = $st->marker(player => 'cc:dd');
is($how, 'reaction', 'marker bez plejera: reakcija');
is($sent[-1]{back}, 0.5, 'marker: unazad 0.5 s');

# kraj snimka upisuje take u sesiju
$st->on_event({ ev => 'rec', state => 'stopped', id => $sent[0]{id}, ok => 1, frames => 96000 });
ok(!$st->snapshot->{rec}, 'snimanje zavrseno');
my $sess = $ses->get($sid);
is(scalar @{ $ses->part($sess, 'A')->{takes} }, 1, 'snimak upisan u stranu A');

($ok, undef, my $next) = $st->next_part;
is($next, 'B', 'sledeca strana B');

# neaktivnost zatvara ulaz
$st->on_event({ ev => 'client', n => 0 });
@sent = ();
$now += 11 * 60;
ok($st->idle_check, 'posle 10 min neaktivnosti ulaz se zatvara');
is($sent[0]{cmd}, 'close', 'komanda close');

# pomocnik umre usred snimanja
$st->on_event({ ev => 'opened', rate => 48000, epoch => 2 });
$st->rec_start;
$st->on_event({ ev => 'helper', state => 'down' });
ok(!$st->snapshot->{rec}, 'snimanje oznaceno kao prekinuto');
ok(!$st->snapshot->{input}{open}, 'ulaz zatvoren kad pomocnik umre');

done_testing;
