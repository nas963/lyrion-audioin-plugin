use strict;
use warnings;
use utf8;
use Test::More;

use Plugins::AudioIn::Menu;

my @ran;
my %o = (string => sub { $_[0] }, run => sub { my ($c, $cmd) = @_; push @ran, $cmd; $cmd->[1] eq 'marker' ? (undef, { error => 'not_recording' }) : (1, undef) });
my $feed = sub { my ($snap) = @_; my $r; Plugins::AudioIn::Menu::feed('client', sub { $r = $_[0] }, {}, $snap, \%o); return $r };
my $names = sub { [ map { $_->{name} } @{ $_[0]{items} } ] };

my $n = Plugins::AudioIn::Menu::node(sub { });
is($n->{id}, 'audioin', 'cvor');

my $r = $feed->({ helper => 0 });
is($r->{items}[0]{name}, 'PLUGIN_AUDIOIN_ERR_HELPER', 'bez pomocnika: poruka');

$r = $feed->({ helper => 1, input => { open => 0 }, part => 'A' });
is_deeply($names->($r), [ 'PLUGIN_AUDIOIN_UI_CLOSED', 'PLUGIN_AUDIOIN_UI_LISTEN', 'PLUGIN_AUDIOIN_UI_RECORD · PLUGIN_AUDIOIN_UI_PART A' ], 'zatvoren ulaz: slusaj, snimaj');

$r = $feed->({ helper => 1, input => { open => 1, rate => 96000 }, listeners => 1, part => 'B',
	session => { meta => { artist => 'Enigma', album => 'MCMXC' } } });
like($r->{items}[0]{name}, qr/96 kHz.*1/, 'stanje ulaza');
is($r->{items}[1]{name}, 'PLUGIN_AUDIOIN_UI_LIVE', 'neko slusa: Uzivo');
like($r->{items}[2]{name}, qr/PART B · Enigma – MCMXC/, 'snimaj: strana i album');
ok((grep { $_ eq 'PLUGIN_AUDIOIN_UI_CLOSE' } @{ $names->($r) }), 'zatvori ulaz');

$r = $feed->({ helper => 1, input => { open => 1, rate => 48000 }, rec => { state => 'rec', part => 'A', seconds => 754, markers => 3 } });
like($r->{items}[2]{name}, qr/^● .* A · 12:34 · .*: 3$/, 'snimanje: vreme i markeri');
is_deeply([ @{ $names->($r) }[ 3 .. 6 ] ], [qw(PLUGIN_AUDIOIN_UI_MARKER PLUGIN_AUDIOIN_UI_PAUSE PLUGIN_AUDIOIN_UI_STOP PLUGIN_AUDIOIN_UI_NEXT_PART)],
	'snimanje: marker, pauza, stop, sledeca strana');

# akcija izvrsava komandu i vraca tekst
my $out;
$r->{items}[4]{url}->('client', sub { $out = $_[0] });
is_deeply($ran[-1], [ 'audioin', 'rec_pause' ], 'pauza: komanda');
is($out->{items}[0]{name}, 'PLUGIN_AUDIOIN_MENU_PAUSED', 'pauza: poruka');
$r->{items}[3]{url}->('client', sub { $out = $_[0] });
like($out->{items}[0]{name}, qr/NOT_RECORDING/, 'greska: poruka sa kodom');

$r = $feed->({ helper => 1, input => { open => 1, rate => 48000 }, rec => { state => 'paused', part => 'A', seconds => 5 } });
ok(!(grep { $_ eq 'PLUGIN_AUDIOIN_UI_MARKER' } @{ $names->($r) }), 'pauza: nema markera');
ok((grep { $_ eq 'PLUGIN_AUDIOIN_UI_RESUME' } @{ $names->($r) }), 'pauza: nastavi');
done_testing;
