package Plugins::AudioIn::Web;

# Web stranica plugina: /plugins/AudioIn/index.html (podaci i komande idu preko JSON-RPC-a)
# i stavka u Extras meniju klasicnog web-a. Tekstovi: svi tokeni PLUGIN_AUDIOIN_UI_* / _ERR_* idu u
# stranicu kao JSON (jezik servera), JS koristi t('UI_...').

use strict;
use warnings;
use utf8;

use File::Basename ();
use File::Spec ();
use JSON::PP ();

use constant PAGE => 'plugins/AudioIn/index.html';

my $DIR = File::Basename::dirname(__FILE__);

sub ui_tokens {
	my ($file) = @_;
	$file //= File::Spec->catfile($DIR, 'strings.txt');
	open my $fh, '<:encoding(UTF-8)', $file or return ();
	my @t;
	while (my $l = <$fh>) {
		push @t, $1 if $l =~ /^(PLUGIN_AUDIOIN(?:_\w+)?)\s*$/;
	}
	close $fh;
	return @t;
}

sub html_json {
	my ($data) = @_;
	my $j = JSON::PP->new->ascii->canonical->encode($data);
	$j =~ s/</\\u003c/g;
	$j =~ s/>/\\u003e/g;
	$j =~ s/&/\\u0026/g;
	return $j;
}

sub ui_strings {
	my ($string, @tokens) = @_;
	my %s;
	for my $tok (@tokens) {
		(my $key = $tok) =~ s/^PLUGIN_AUDIOIN_?//;
		$key = 'TITLE' if $key eq '';
		next if $key ne 'TITLE' && $key !~ /^(?:UI|ERR)_/;
		$s{$key} = $string->($tok);
	}
	return \%s;
}

sub _stamp {
	my $m = 0;
	for my $f (qw(audioin.js audioin.css folderpick.js)) {
		my $t = (stat File::Spec->catfile($DIR, 'HTML', 'EN', 'plugins', 'AudioIn', $f))[9];
		$m = $t if $t && $t > $m;
	}
	return $m;
}

# Omot sesije: plugins/AudioIn/cover/<id>[.<bilo sta>][_WxH[_m]].jpg (Material dodaje sufiks velicine).
# Tacka posle id-a prekida ime koje trazi LMS-ov resizer, isto kao kod AudioCD-a.
use constant COVER_RE => qr{^plugins/AudioIn/cover/(\d{8}-\d{6}(?:-\d+)?)(?:\.\d+)?(?:_[0-9]{1,4}x[0-9]{1,4}(?:_[a-z])?)?\.jpg\z};

sub cover_file {
	my ($path, $sessions) = @_;
	(my $p = $path // '') =~ s{^/+}{};
	return undef unless $p =~ COVER_RE && $sessions;
	my $s = $sessions->get($1) or return undef;
	my $f = $sessions->cover_path($s);
	return -f $f ? $f : undef;
}

sub init {
	my ($class, %a) = @_;
	my $sessions = $a{sessions};
	require Slim::Utils::Strings;
	require Slim::Web::HTTP;
	require Slim::Web::Pages;

	Slim::Web::Pages->addPageFunction(PAGE, sub {
		my ($client, $params) = @_;
		$params->{audioinData} = html_json({
			strings => ui_strings(sub { Slim::Utils::Strings::string($_[0]) }, ui_tokens()),
			player  => $client ? $client->id : undef,
		});
		$params->{audioinStamp} = _stamp();
		($params->{audioinLang} = lc(Slim::Utils::Strings::getLanguage() // 'en')) =~ tr/_/-/;
		return Slim::Web::HTTP::filltemplatefile(PAGE, $params);
	});
	my $generic = File::Spec->catfile($DIR, 'HTML', 'EN', 'plugins', 'AudioIn', 'audioin-icon.png');
	Slim::Web::Pages->addRawDownload(COVER_RE, sub { cover_file($_[0], $sessions) // $generic },
		sub { cover_file($_[0], $sessions) ? 'image/jpeg' : 'image/png' });
	# Ikonica: LMS ne servira staticki .png iz foldera plugina bez sufiksa velicine (sa sufiksom ga
	# smanjuje resizer); ova ruta pokriva oba oblika (audioin-icon.png, audioin-icon_WxH[_m].png).
	Slim::Web::Pages->addRawDownload(qr{^plugins/AudioIn/audioin-icon(?:_[0-9]{1,4}x[0-9]{1,4}(?:_[a-z])?)?\.png\z},
		sub { $generic }, 'image/png');
	Slim::Web::Pages->addPageLinks('plugins', { PLUGIN_AUDIOIN => PAGE });
	return;
}

1;
