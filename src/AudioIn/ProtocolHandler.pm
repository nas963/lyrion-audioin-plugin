package Plugins::AudioIn::ProtocolHandler;

# audioin://live: zvuk sa ulaza kao beskonacan stream za plejer.
#
# Nalaz iz LMS 9.1.1 izvora (Slim/Player/Song.pm open, TranscodingHelper.pm):
# - Za remote handler Song::open nudi stream modove ['I', 'R']. Pravilo u custom-convert.conf ima samo
#   sposobnost R, pa LMS ne otvara handler (new se ne poziva) nego pokrece komandu sa $URL$:
#   `[audioin-tap] $URL$ | [flac] ...`. [audioin-tap] se trazi u Bin/ foldera plugina
#   (PluginManager dodaje Bin u findbin), a pravila se citaju iz custom-convert.conf plugina.
# - $SAMPLERATE$/$SAMPLESIZE$/$CHANNELS$ dolaze iz RemoteTrack-a (samplerate, samplesize, channels),
#   koje getNextTrack popunjava iz trenutnog stanja ulaza.
# - Tip 'ain' je u custom-types.conf plugina (kategorija audio), pa je stavka pesma, ne lista.
#
# Plugin daje stanje ulaza: Plugins::AudioIn::ProtocolHandler->set_info(sub -> {rate, title, ...}).

use strict;
use warnings;
use utf8;

use base qw(Slim::Player::Protocols::File);

use Slim::Schema::RemoteTrack;
use Slim::Utils::Log;

my $log = logger('plugin.audioin');
my $INFO = sub { {} };

# Trajanje stavke: LMS (StreamingController::_CheckPaused) ZAUSTAVLJA remote stream nepoznatog trajanja
# cim se bafer plejera napuni u pauzi (pretpostavlja radio). Sa poznatim trajanjem ostavlja ga
# pauziranog: cev stoji, audioin-tap stoji na svojoj poziciji u ringu i Play nastavlja (timeshift).
use constant LIVE_SECS => 24 * 3600;

sub set_info { my ($class, $cb) = @_; $INFO = $cb if ref $cb eq 'CODE'; return }

sub url_for {
	my ($class, %o) = @_;
	my @q;
	push @q, "delay=$o{delay}" if defined $o{delay};
	push @q, "pos=$o{pos}" if defined $o{pos};
	push @q, "t=$o{t}" if defined $o{t};    # samo da svaki Slusaj bude nova stavka (nov start citaca)
	return 'audioin://live' . (@q ? '?' . join('&', @q) : '');
}

sub is_ours { my ($class, $url) = @_; return defined $url && $url =~ m{^audioin://live(?:\?|\z)} ? 1 : 0 }

sub isRemote        { 1 }
sub canDirectStream { 0 }
sub canSeek         { 0 }
sub isAudio         { 1 }
sub getFormatForURL { 'ain' }
sub pathFromFileURL { '' }
sub new             { undef }    # LMS ide preko komande (sposobnost R), nikad direktno

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $i = eval { $INFO->() } || {};
	return {
		title    => $i->{title} // 'Audio In',
		artist   => $i->{artist},
		album    => $i->{album},
		cover    => $i->{cover} // '/plugins/AudioIn/audioin-icon.png',
		icon     => $i->{cover} // '/plugins/AudioIn/audioin-icon.png',
		duration => LIVE_SECS,
		type     => $i->{rate} ? sprintf('PCM %d/%g', 24, $i->{rate} / 1000) : 'PCM',
		samplerate => $i->{rate},
		samplesize => 24,
		bitrate  => $i->{rate} ? sprintf('%d kbps', $i->{rate} * 48 / 1000) : undef,
	};
}

sub getIcon { '/plugins/AudioIn/audioin-icon.png' }

# Pre pokretanja: ulaz mora biti otvoren; RemoteTrack dobija format ulaza.
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $track = $song->currentTrack;
	my $url = $track->url;
	my $i = eval { $INFO->() } || {};
	unless ($i->{open} && $i->{rate}) {
		$log->warn("$url: ulaz nije otvoren");
		return $errorCb->('PLUGIN_AUDIOIN_NOT_OPEN', $url);
	}
	my %attr = (CT => 'ain', SECS => LIVE_SECS, RATE => $i->{rate}, SAMPLESIZE => 24, CHANNELS => 2, ENDIAN => 0,
		TITLE => $i->{title} // 'Audio In');
	$attr{ARTIST} = $i->{artist} if defined $i->{artist};
	$attr{ALBUM}  = $i->{album}  if defined $i->{album};
	eval { Slim::Schema::RemoteTrack->updateOrCreate($track, \%attr); 1 } or $log->warn("$url: $@");
	return $successCb->();
}

1;
