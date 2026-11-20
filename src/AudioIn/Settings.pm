package Plugins::AudioIn::Settings;

# Stranica podesavanja (Slim::Web::Settings). Cuvanje ide kroz validate(): ili se sacuva sve, ili nista
# (greske se prikazuju uz uneto). Lista ulaza dolazi iz /proc/asound (Devices.pm); izbor ulaza se cuva
# kao device + format + rate + channels/leftChannel/rightChannel.

use strict;
use warnings;
use utf8;
use base qw(Slim::Web::Settings);

use JSON::PP ();

use Slim::Utils::Prefs;
use Slim::Utils::Strings;

use Plugins::AudioIn::Config;
use Plugins::AudioIn::Devices;
use Plugins::AudioIn::Sessions;
use Plugins::AudioIn::Tools;

our @SHOWN = qw(source device format rate inputMap testFile sourceType preroll listenDelay reaction ringMinutes
	idleClose flacLevel ripsDir resTag);

sub _creatable {
	my ($dir) = @_;
	my $p = $dir;
	$p =~ s{/[^/]*\z}{} while length $p && !-e $p;
	$p = '/' unless length $p;
	return -d $p && -w _ ? 1 : 0;
}

sub _abs_clean {
	my ($v) = @_;
	return defined $v && $v =~ m{^/} && $v !~ m{(?:^|/)\.\.(?:/|\z)} && $v !~ /[\x00-\x1f]/ ? 1 : 0;
}

# inputMap "kanala:levi:desni" (0-based) <-> prefs channels/leftChannel/rightChannel
sub input_map { my ($p) = @_; return join(':', map { $p->{$_} // 0 } qw(channels leftChannel rightChannel)) }

# Opcije za izbor kanala za uredjaj sa $n kanala: stereo parovi i mono kanali.
sub map_options {
	my ($n) = @_;
	$n = 2 unless $n && $n > 0;
	my @o;
	for (my $i = 0; $i + 1 < $n; $i += 2) { push @o, { value => "$n:$i:" . ($i + 1), stereo => 1, a => $i + 1, b => $i + 2 } }
	push @o, { value => "$n:$_:$_", stereo => 0, a => $_ + 1 } for 0 .. $n - 1;
	return \@o;
}

sub _num {
	my ($v, $lo, $hi, $int) = @_;
	return undef unless defined $v && $v =~ /^\d+(?:\.\d+)?\z/;
	return undef if $int && $v != int $v;
	return $v >= $lo && $v <= $hi ? $v + 0 : undef;
}

# validate(\%ulaz) -> (\%za_cuvanje, \%greske)
sub validate {
	my ($in) = @_;
	my (%c, %e);
	my $s = sub { my $v = $in->{ $_[0] }; defined $v ? do { (my $t = $v) =~ s/^\s+|\s+$//g; $t } : '' };

	my $src = $s->('source');
	if ($src eq 'alsa' || $src eq 'file') { $c{source} = $src } else { $e{source} = 'PLUGIN_AUDIOIN_SET_ERR_SOURCE' }

	my $dev = $s->('device');
	if ($dev eq '' || $dev =~ /\A(?:plug)?hw:[A-Za-z0-9_=,.-]+\z/) { $c{device} = $dev }
	else { $e{device} = 'PLUGIN_AUDIOIN_SET_ERR_DEVICE' }
	$e{device} = 'PLUGIN_AUDIOIN_SET_ERR_DEVICE' if ($c{source} // '') eq 'alsa' && $dev eq '';

	my $fmt = $s->('format');
	if (grep { $_ eq $fmt } @Plugins::AudioIn::Devices::FORMAT_ORDER) { $c{format} = $fmt }
	else { $e{format} = 'PLUGIN_AUDIOIN_SET_ERR_FORMAT' }

	if (defined(my $r = _num($s->('rate'), 8000, 384000, 1))) { $c{rate} = $r } else { $e{rate} = 'PLUGIN_AUDIOIN_SET_ERR_RATE' }

	my $map = $s->('inputMap');
	if ($map =~ /\A(\d{1,2}):(\d{1,2}):(\d{1,2})\z/ && $1 >= 1 && $2 < $1 && $3 < $1) {
		@c{qw(channels leftChannel rightChannel)} = ($1 + 0, $2 + 0, $3 + 0);
	}
	else { $e{inputMap} = 'PLUGIN_AUDIOIN_SET_ERR_CHANNELS' }

	my $tf = $s->('testFile');
	if ($tf eq '' || (_abs_clean($tf) && $tf =~ /\.(?:flac|wav)\z/i)) { $c{testFile} = $tf } else { $e{testFile} = 'PLUGIN_AUDIOIN_SET_ERR_TEST_FILE' }
	$e{testFile} = 'PLUGIN_AUDIOIN_SET_ERR_TEST_FILE' if ($c{source} // '') eq 'file' && !($tf ne '' && -r $tf);

	my $st = $s->('sourceType');
	if ($Plugins::AudioIn::Sessions::SOURCE_TYPES{$st}) { $c{sourceType} = $st } else { $e{sourceType} = 'PLUGIN_AUDIOIN_SET_ERR_SOURCE' }

	my %num = (preroll => [ 0, 30, 0 ], listenDelay => [ 1, 30, 0 ], reaction => [ 0, 5, 0 ], ringMinutes => [ 1, 120, 1 ],
		idleClose => [ 0, 240, 1 ], flacLevel => [ 0, 8, 1 ]);
	for my $k (sort keys %num) {
		my $v = _num($s->($k), @{ $num{$k} });
		if (defined $v) { $c{$k} = $v } else { $e{$k} = 'PLUGIN_AUDIOIN_SET_ERR_NUMBER' }
	}

	my $rips = $s->('ripsDir');
	if ($rips eq '' || (_abs_clean($rips) && _creatable($rips))) { $c{ripsDir} = $rips }
	else { $e{ripsDir} = 'PLUGIN_AUDIOIN_SET_ERR_RIPS_DIR' }

	$c{resTag} = $in->{resTag} ? 1 : 0;
	return (\%c, \%e);
}

# Kartice koje ne javljaju mogucnosti kroz /proc (nisu USB) se kratko ispituju preko arecord-a.
# Rezultat se pamti 10 min; uredjaj koji je otvoren (snimanje/slusanje) se ne dira.
my %PROBED;
use constant PROBE_TTL => 600;

sub _probe_unknown {
	my ($devs) = @_;
	my $arecord = Plugins::AudioIn::Tools::find('arecord') or return;
	my $state = Plugins::AudioIn::Plugin->can('input_device') ? Plugins::AudioIn::Plugin::input_device() : undef;
	for my $d (@$devs) {
		next if @{ $d->{rates} || [] } || !$d->{card_id};
		my $c = $PROBED{ $d->{dev} };
		if (!$c || time - $c->{at} > PROBE_TTL) {
			next if defined $state && $state eq $d->{dev};
			my $caps = Plugins::AudioIn::Devices::probe($d->{dev}, arecord => $arecord) or next;
			$c = $PROBED{ $d->{dev} } = { at => time, caps => $caps };
		}
		$d->{$_} = $c->{caps}{$_} for qw(formats rates channels);
	}
	return;
}

# ---------- Slim::Web::Settings ----------

sub name { return Slim::Web::HTTP::CSRF->protectName('PLUGIN_AUDIOIN') }
sub page { return Slim::Web::HTTP::CSRF->protectURI('plugins/AudioIn/settings/basic.html') }

sub prefs { return (Slim::Utils::Prefs::preferences('plugin.audioin'), sort keys %Plugins::AudioIn::Config::DEFAULTS) }

sub handler {
	my ($class, $client, $params, @rest) = @_;
	my $prefs = Slim::Utils::Prefs::preferences('plugin.audioin');
	my %cur = map { $_ => $prefs->get($_) } keys %Plugins::AudioIn::Config::DEFAULTS;
	my %view = (%cur, inputMap => input_map(\%cur));

	if ($params->{saveSettings}) {
		my %in = map { $_ => $params->{"pref_$_"} } @SHOWN;
		my ($clean, $err) = validate(\%in);
		if (%$err) {
			%view = (%view, %in);
			$view{resTag} = $in{resTag} ? 1 : 0;
			$params->{warning} = join '<br/>', map { Slim::Utils::Strings::string($err->{$_}) } grep { $err->{$_} } @SHOWN;
		}
		else {
			# ulaz se menja odjednom (jedan ponovni start ulaza, ne po jedan za svaki pref)
			$prefs->set($_, $clean->{$_}) for grep { $_ ne 'device' } sort keys %$clean;
			$prefs->set('device', $clean->{device});
			%view = (%view, %$clean, inputMap => input_map($clean));
			$params->{warning} = Slim::Utils::Strings::string('PLUGIN_AUDIOIN_SET_SAVED');
		}
	}

	my $devs = Plugins::AudioIn::Devices::list();
	_probe_unknown($devs);
	if (length($view{device} // '') && !grep { $_->{dev} eq $view{device} } @$devs) {
		push @$devs, { dev => $view{device}, label => $view{device} . ' - ' . Slim::Utils::Strings::string('PLUGIN_AUDIOIN_SET_NOT_PRESENT'),
			formats => [], rates => [], channels => [] };
	}
	$params->{audioin} = \%view;
	$params->{audioinDevices} = $devs;
	$params->{audioinDevicesJson} = Plugins::AudioIn::Web::html_json([ map { { dev => $_->{dev}, formats => $_->{formats},
		rates => $_->{rates}, channels => $_->{channels} } } @$devs ]);
	$params->{audioinTypes} = [ map { { value => $_, label => Slim::Utils::Strings::string('PLUGIN_AUDIOIN_UI_TYPE_' . uc $_) } }
		qw(vinyl cassette radio live other) ];
	$params->{audioinRipsDefault} = Plugins::AudioIn::Config::default_rips_dir();
	$params->{audioinStrings} = Plugins::AudioIn::Web::html_json({
		stereo => Slim::Utils::Strings::string('PLUGIN_AUDIOIN_SET_STEREO'),
		mono   => Slim::Utils::Strings::string('PLUGIN_AUDIOIN_SET_MONO'),
		unknown => Slim::Utils::Strings::string('PLUGIN_AUDIOIN_SET_UNKNOWN_CAPS'),
	});

	delete $params->{saveSettings};
	return $class->SUPER::handler($client, $params, @rest);
}

1;
