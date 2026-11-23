package Plugins::AudioIn::Plugin;

# Veza AudioIn jedinica sa Lyrion-om: prefs, CLI komande ['audioin', ...], audioin:// handler,
# Jobs backend na LMS event loop-u, pomocni proces audioin-capture (jedini drzi ulaz).
# Pravila stanja su u State.pm (cist Perl); ovde je samo LMS sloj.

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use EV ();
use File::Spec ();
use POSIX ();
use File::Spec::Functions qw(catdir catfile);
use JSON::PP ();
use Time::HiRes ();

use Slim::Control::Request;
use Slim::Networking::Select;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::ProtocolHandlers;
use Slim::Player::Source;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings ();
use Slim::Utils::Unicode;
use Slim::Menu::BrowseLibrary;
use Slim::Music::Import;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Timers;

use Plugins::AudioIn::CaptureClient;
use Plugins::AudioIn::Config;
use Plugins::AudioIn::Editor;
use Plugins::AudioIn::Export;
use Plugins::AudioIn::Jobs;
use Plugins::AudioIn::Library;
use Plugins::AudioIn::MaterialBridge;
use Plugins::AudioIn::Menu;
use Plugins::AudioIn::Naming;
use Plugins::AudioIn::Metadata;
use Plugins::AudioIn::ProtocolHandler;
use Plugins::AudioIn::Sessions;
use Plugins::AudioIn::State;
use Plugins::AudioIn::Tools;

our $VERSION = '0.1.0';

use constant START_DELAY  => 2;     # s posle starta plugina
use constant IDLE_EVERY   => 30;    # s, provera neaktivnosti ulaza
use constant OPEN_WAIT    => 8;     # s, Slusaj ceka da se ulaz otvori

my $prefs = preferences('plugin.audioin');
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.audioin',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_AUDIOIN',
});

my ($STATE, $CAPTURE, $SESSIONS, $EDITOR, $EXPORT, $IDLE, $START);
my %TIMERS;
my %CHILD_W;

my $PLUGIN_DIR = do {
	my $f = File::Spec->rel2abs($INC{'Plugins/AudioIn/Plugin.pm'} // __FILE__);
	$f =~ s{/Plugin\.pm\z}{};
	$f;
};
(my $PLUGIN_ROOT = $PLUGIN_DIR) =~ s{/Plugins/AudioIn\z}{};

sub getDisplayName { 'PLUGIN_AUDIOIN' }

# ---------- tajmeri i Jobs backend ----------

sub _timer {
	my ($secs, $cb) = @_;
	my $h;
	$h = Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $secs, sub {
		delete $TIMERS{$h};
		$cb->();
	});
	$TIMERS{$h} = $h;
	return $h;
}

sub _cancel_timer {
	my ($h) = @_;
	return unless $h && delete $TIMERS{$h};
	Slim::Utils::Timers::killSpecific($h);
	return;
}

sub _io_backend {
	return {
		add_read     => sub { my ($fh, $cb) = @_; Slim::Networking::Select::addRead($fh, sub { $cb->($fh) }) },
		remove_read  => sub { Slim::Networking::Select::removeRead($_[0]) },
		timer        => \&_timer,
		cancel_timer => \&_cancel_timer,
		child        => sub {
			my ($pid, $cb) = @_;
			$CHILD_W{$pid} = EV::child($pid, 0, sub {
				my $st = $_[0]->rstatus;
				delete $CHILD_W{$pid};
				$cb->($st);
			});
			return $CHILD_W{$pid};
		},
	};
}

# ---------- pomocne ----------

sub _rips_dir { return Plugins::AudioIn::Config::rips_dir($prefs->get('ripsDir')) }

sub _helper_argv {
	my $sec = int(($prefs->get('ringMinutes') || 10) * 60);
	$sec = 60 if $sec < 60;
	return [ $^X, "-I$PLUGIN_ROOT", '-MPlugins::AudioIn::Capture', '-e', 'Plugins::AudioIn::Capture::main()', '--',
		'--ring-sec', $sec ];
}

# Sta plejer svira i koliko je odsvirao (za marker po onome sto korisnik cuje).
sub _player_pos {
	my ($id) = @_;
	my $client = Slim::Player::Client::getClient($id) or return ();
	my $url = eval { Slim::Player::Playlist::url($client) } or return ();
	my $el = eval { Slim::Player::Source::songTime($client) };
	return ($url, $el);
}

# Uredjaj koji je trenutno otvoren (Settings ga ne ispituje dok je u upotrebi).
sub input_device {
	return undef unless $STATE && $STATE->{input}{open} && ($STATE->{input}{src} // '') eq 'alsa';
	return $STATE->{input}{dev};
}

sub _input_info {
	my $in = $STATE ? $STATE->{input} : {};
	my $s = $STATE ? $STATE->current_session : undef;
	my $m = $s ? $s->{meta} : {};
	return {
		open   => $in->{open},
		rate   => $in->{rate},
		title  => $m->{album} // Slim::Utils::Strings::string('PLUGIN_AUDIOIN'),
		cover  => ($s && $m->{cover}) ? "/plugins/AudioIn/cover/$s->{id}.jpg" : undef,
		artist => $m->{artist},
		album  => defined $m->{album} ? $m->{album} : undef,
	};
}

# ---------- init / shutdown ----------

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	$prefs->init({ %Plugins::AudioIn::Config::DEFAULTS });
	Plugins::AudioIn::Jobs::set_io_backend(_io_backend());

	# zip paket ne cuva uvek x bit: tap mora biti izvrsan da bi ga LMS nasao (findbin trazi -x)
	my $tap = catfile($PLUGIN_DIR, 'Bin', 'audioin-tap');
	chmod 0755, $tap if -f $tap && !-x $tap;

	$SESSIONS = Plugins::AudioIn::Sessions->new(root => \&_rips_dir);
	$EDITOR = Plugins::AudioIn::Editor->new(sessions => $SESSIONS);
	$EXPORT = Plugins::AudioIn::Export->new(
		spawn => sub { Plugins::AudioIn::Jobs->spawn(@_) },
		log   => sub { my ($lvl, $m) = @_; $lvl eq 'warn' ? $log->warn($m) : $log->info($m) },
	);
	$STATE = Plugins::AudioIn::State->new(
		send       => sub { $CAPTURE ? $CAPTURE->send($_[0]) : 0 },
		pref       => sub { $prefs->get($_[0]) },
		sessions   => $SESSIONS,
		player_pos => \&_player_pos,
		on_take    => sub { my ($sid, $name, $ok) = @_; $EDITOR->analyze($sid, $name) if $ok && $EDITOR },
		log        => sub { my ($lvl, $m) = @_; $lvl eq 'warn' ? $log->warn($m) : $log->info($m) },
	);

	Slim::Player::ProtocolHandlers->registerHandler(audioin => 'Plugins::AudioIn::ProtocolHandler');
	Plugins::AudioIn::ProtocolHandler->set_info(\&_input_info);

	$CAPTURE = Plugins::AudioIn::CaptureClient->new(
		argv         => \&_helper_argv,
		spawn        => sub { Plugins::AudioIn::Jobs->spawn(@_) },
		timer        => \&_timer,
		cancel_timer => \&_cancel_timer,
		on_event     => sub { $STATE->on_event($_[0]) if $STATE },
		log          => sub { my ($lvl, $m) = @_; $lvl eq 'warn' ? $log->warn($m) : $log->info($m) },
	);
	$START = _timer(START_DELAY, sub { $CAPTURE->start if $CAPTURE });
	$IDLE = _timer(IDLE_EVERY, \&_idle_tick);

	# promena ulaza: ako je otvoren, ponovo se otvara sa novim podesavanjima
	# (stranica podesavanja menja vise prefs-a odjednom: jedno ponovno otvaranje, ne po jedno za svaki)
	my $reopen;
	$prefs->setChange(sub {
		return unless $STATE && $STATE->{input}{open} && !$STATE->{rec};
		_cancel_timer($reopen);
		$reopen = _timer(0.5, sub {
			undef $reopen;
			return unless $STATE->{input}{open} && !$STATE->{rec};
			$STATE->close_input;
			my $tries = 0;
			my $go;
			$go = sub {    # ceka 'closed' pa otvara sa novim podesavanjima
				if ($STATE->{input}{open} && ++$tries < 25) { _timer(0.2, $go); return }
				undef $go;
				$STATE->open_input;
			};
			_timer(0.2, $go);
		});
	}, qw(source device format rate channels leftChannel rightChannel testFile));

	require Plugins::AudioIn::Settings;
	Plugins::AudioIn::Settings->new;

	require Plugins::AudioIn::Web;
	Plugins::AudioIn::Web->init(sessions => $SESSIONS);

	# meni "Audio ulaz" za aplikacije i Material, i stavka na Material pocetnoj strani
	Slim::Menu::BrowseLibrary->registerNode(Plugins::AudioIn::Menu::node(sub {
		my ($client, $cb, $args) = @_;
		Plugins::AudioIn::Menu::feed($client, $cb, $args, $STATE ? $STATE->snapshot : undef, {
			string => sub { my ($token, @a) = @_; my $s = Slim::Utils::Strings::cstring($client, $token, @a); return defined $s && $s ne $token ? $s : undef },
		});
	}));
	eval { Plugins::AudioIn::MaterialBridge::install(catdir(Slim::Utils::Prefs::dir(), 'material-skin')); 1 }
		or $log->error("Material Skin dodatak nije postavljen: $@");

	my %cmd = (
		status         => [ 0, 1, 1, \&_cli_status ],
		open           => [ 0, 0, 1, \&_cli_open ],
		close          => [ 0, 0, 1, \&_cli_close ],
		listen         => [ 0, 0, 1, \&_cli_listen ],
		meter          => [ 0, 1, 1, \&_cli_meter ],
		rec_start      => [ 0, 0, 1, \&_cli_rec_start ],
		rec_pause      => [ 0, 0, 1, sub { _simple($_[0], $STATE->rec_pause) } ],
		rec_resume     => [ 0, 0, 1, sub { _simple($_[0], $STATE->rec_resume) } ],
		rec_stop       => [ 0, 0, 1, sub { _simple($_[0], $STATE->rec_stop) } ],
		next_part      => [ 0, 0, 1, sub { my ($ok, $err, $p) = $STATE->next_part; _done($_[0], $ok, $err, part => $p) } ],
		marker         => [ 0, 0, 1, \&_cli_marker ],
		session_new    => [ 0, 0, 1, \&_cli_session_new ],
		session_select => [ 0, 0, 1, \&_cli_session_select ],
		session_edit   => [ 0, 0, 1, \&_cli_session_edit ],
		sessions       => [ 0, 1, 1, \&_cli_sessions ],
		take           => [ 0, 1, 1, \&_cli_take ],
		analyze        => [ 0, 0, 1, \&_cli_analyze ],
		tracks         => [ 0, 0, 1, \&_cli_tracks ],
		preview        => [ 0, 0, 1, \&_cli_preview ],
		export         => [ 0, 0, 1, \&_cli_export ],
		export_cancel  => [ 0, 0, 1, sub { _simple($_[0], $EXPORT->cancel) } ],
		mb_search      => [ 0, 1, 1, \&_cli_mb_search ],
		mb_apply       => [ 0, 0, 1, \&_cli_mb_apply ],
		browse         => [ 0, 1, 1, \&_cli_browse ],
		mkdir          => [ 0, 0, 1, \&_cli_mkdir ],
		move           => [ 0, 0, 1, \&_cli_move ],
	);
	Slim::Control::Request::addDispatch([ 'audioin', $_ ], $cmd{$_}) for keys %cmd;

	$log->info("AudioIn $VERSION: izvor " . ($prefs->get('source') // '') . ' ' . ($prefs->get('device') // '')
		. ', snimci ' . _rips_dir());
	return;
}

sub shutdownPlugin {
	eval { Slim::Menu::BrowseLibrary->deregisterNode('audioin') };
	_cancel_timer($START);
	_cancel_timer($IDLE);
	if ($CAPTURE) {
		my $job = $CAPTURE->stop;    # quit + EOF: pomocnik zavrsava snimak u toku
		undef $CAPTURE;
		# kratko cekanje da flac zatvori fajl, pa kill (Jobs::kill_all) za sve sto je ostalo
		my $t = Time::HiRes::time() + 3;
		while ($job && $job->is_running && Time::HiRes::time() < $t) {
			Time::HiRes::sleep(0.1);
			waitpid($job->pid, POSIX::WNOHANG()) == $job->pid and last;
		}
	}
	Plugins::AudioIn::Jobs::kill_all();
	_cancel_timer($_) for values %TIMERS;
	%TIMERS = ();
	%CHILD_W = ();
	return;
}

sub _idle_tick {
	$IDLE = _timer(IDLE_EVERY, \&_idle_tick);
	eval { $STATE->idle_check if $STATE; 1 } or $log->error("idle: $@");
	return;
}

# ---------- CLI ----------

sub _done {
	my ($request, $ok, $err, %extra) = @_;
	if ($ok) {
		$request->addResult(ok => 1);
		$request->addResult($_ => $extra{$_}) for grep { defined $extra{$_} } sort keys %extra;
	}
	else {
		$err ||= { error => 'failed' };
		$request->addResult(error => $err->{error});
		$request->addResult($_ => $err->{$_}) for grep { $_ ne 'error' } sort keys %$err;
	}
	$request->setStatusDone;
	return;
}

sub _simple { my ($request, $ok, $err) = @_; _done($request, $ok, $err) }

sub _param {
	my ($request, $name) = @_;
	my $v = $request->getParam($name);
	return defined $v && length $v ? $v : undef;
}

sub _cli_status {
	my ($request) = @_;
	my $snap = $STATE->snapshot;
	$snap->{export} = $EXPORT->snapshot;
	$snap->{config} = { source => $prefs->get('source'), device => $prefs->get('device'), rate => $prefs->get('rate'),
		testFile => $prefs->get('testFile'), ripsDir => _rips_dir() };
	$request->addResult($_ => $snap->{$_}) for keys %$snap;
	$request->setStatusDone;
	return;
}

sub _cli_open  { my ($r) = @_; _simple($r, $STATE->open_input) }
sub _cli_close { my ($r) = @_; _simple($r, $STATE->close_input) }

sub _cli_meter {
	my ($request) = @_;
	my $m = $STATE->meter_on;
	$request->addResult(ok => 1);
	$request->addResult(meter => $m ? { pk => $m->{pk}, rms => $m->{rms}, clip => $m->{clip} } : undef);
	$request->setStatusDone;
	return;
}

sub _client_of {
	my ($request) = @_;
	my $id = _param($request, 'player');
	my $c = defined $id ? Slim::Player::Client::getClient($id) : $request->client;
	return $c;
}

# Slusaj: otvara ulaz ako treba, ceka da se otvori, pa pusta audioin://live na plejeru.
sub _cli_listen {
	my ($request) = @_;
	my $client = _client_of($request) or return _done($request, 0, { error => 'no_player' });
	my ($ok, $err) = $STATE->open_input;
	return _done($request, 0, $err) unless $ok;
	my $deadline = Time::HiRes::time() + OPEN_WAIT;
	my $go;
	$go = sub {
		if (!$STATE->{input}{open}) {
			if (Time::HiRes::time() < $deadline && !defined $STATE->{last_err}) {
				_timer(0.2, $go);
				return;
			}
			undef $go;
			return _done($request, 0, { error => 'not_open', reason => $STATE->{last_err} });
		}
		undef $go;
		my $url = Plugins::AudioIn::ProtocolHandler->url_for(delay => $prefs->get('listenDelay') // 3, t => int(Time::HiRes::time()));
		my $i = _input_info();
		my $track = Slim::Schema->updateOrCreate({ url => $url, attributes => {
			CT => 'ain', SECS => Plugins::AudioIn::ProtocolHandler::LIVE_SECS, TITLE => $i->{title}, RATE => $i->{rate}, SAMPLESIZE => 24, CHANNELS => 2,
			(defined $i->{artist} ? (ARTIST => $i->{artist}) : ()), (defined $i->{album} ? (ALBUM => $i->{album}) : ()),
		} });
		return _done($request, 0, { error => 'play_failed' }) unless $track;
		$STATE->listen_started($client->id);
		$client->execute([ 'power', 1 ]) unless $client->power;
		$client->execute([ 'playlist', 'playtracks', 'listRef', [ $track ] ]);
		_done($request, 1, undef, player => $client->id);
	};
	$request->setStatusProcessing;
	$go->();
	return;
}

sub _cli_rec_start {
	my ($request) = @_;
	my ($ok, $err) = $STATE->open_input;
	return _done($request, 0, $err) unless $ok;
	my $part = _param($request, 'part');
	my $deadline = Time::HiRes::time() + OPEN_WAIT;
	my $go;
	$go = sub {
		if (!$STATE->{input}{open} && Time::HiRes::time() < $deadline && !defined $STATE->{last_err}) {
			_timer(0.2, $go);
			return;
		}
		undef $go;
		_simple($request, $STATE->rec_start(defined $part ? (part => $part) : ()));
	};
	$request->setStatusProcessing;
	$go->();
	return;
}

sub _cli_marker {
	my ($request) = @_;
	my $client = _client_of($request);
	my ($ok, $err, $how) = $STATE->marker(player => $client ? $client->id : undef);
	_done($request, $ok, $err, how => $how);
}

sub _cli_session_new {
	my ($request) = @_;
	my %o = map { my $v = _param($request, $_); defined $v ? ($_ => $v) : () } qw(type artist album year);
	my ($ok, $err, $s) = $STATE->session_new(%o);
	_done($request, $ok, $err, id => $s ? $s->{id} : undef);
}

sub _cli_session_select {
	my ($request) = @_;
	_simple($request, $STATE->session_select(_param($request, 'id'), _param($request, 'part')));
}

sub _cli_session_edit {
	my ($request) = @_;
	my %m = map { my $v = $request->getParam($_); defined $v ? ($_ => $v) : () } qw(type artist album year);
	_simple($request, $STATE->session_edit(_param($request, 'id'), %m));
}

sub _cli_sessions {
	my ($request) = @_;
	my $list = $SESSIONS->list;
	$request->addResult(sessions => [ map { Plugins::AudioIn::State::_session_summary($_) } @$list ]);
	$request->setStatusDone;
	return;
}

# ---------- pesme: pregled, analiza, izmene, slusanje granice, izvoz ----------

sub _cli_take {
	my ($request) = @_;
	my ($ov, $err) = $EDITOR->overview(_param($request, 'id'), _param($request, 'take'), _param($request, 'points'));
	return _done($request, 0, $err) unless $ov;
	$request->addResult($_ => $ov->{$_}) for keys %$ov;
	$request->setStatusDone;
	return;
}

sub _cli_analyze {
	my ($request) = @_;
	my $d = _param($request, 'durations');
	my @dur = defined $d ? grep { $_ > 0 } split /,/, $d : ();
	my ($ok, $err, $tracks) = $EDITOR->analyze(_param($request, 'id'), _param($request, 'take'), @dur > 1 ? (durations => \@dur) : ());
	return _done($request, 0, $err) unless $ok;
	$request->addResult(ok => 1);
	$request->addResult(tracks => $tracks);
	$request->setStatusDone;
	return;
}

sub _cli_tracks {
	my ($request) = @_;
	my $json = $request->getParam('tracks');
	my $tracks = eval { JSON::PP->new->utf8(0)->decode($json // '') };
	_simple($request, $EDITOR->set_tracks(_param($request, 'id'), _param($request, 'take'), $tracks));
}

# Pusta snimak na plejeru od zadatog frejma (minus 3 s), da se granica proveri na uvo.
sub _cli_preview {
	my ($request) = @_;
	my $client = _client_of($request) or return _done($request, 0, { error => 'no_player' });
	my ($s, $p, $t) = $EDITOR->find_take(_param($request, 'id'), _param($request, 'take'));
	return _done($request, 0, { error => 'no_take' }) unless $t;
	my $path = $SESSIONS->take_path($s, $t);
	return _done($request, 0, { error => 'no_file' }) unless -f $path;
	my $secs = (_param($request, 'frame') // 0) / ($t->{rate} || 48000) - 3;
	$secs = 0 if $secs < 0;
	my $url = Slim::Utils::Misc::fileURLFromPath($path);
	$client->execute([ 'power', 1 ]) unless $client->power;
	$client->execute([ 'playlist', 'play', $url ]);
	_timer(1.5, sub { $client->execute([ 'time', sprintf('%.2f', $secs) ]) }) if $secs > 0;
	_done($request, 1, undef, seconds => sprintf('%.1f', $secs));
}

sub _cli_export {
	my ($request) = @_;
	my $sid = _param($request, 'id');
	my $s = $SESSIONS->get($sid) or return _done($request, 0, { error => 'no_session' });
	my $flac = Plugins::AudioIn::Tools::find('flac') or return _done($request, 0, { error => 'no_flac' });
	my $root = _rips_dir();
	my ($plan, $perr) = Plugins::AudioIn::Export::plan(session => $s, take_path => sub { $SESSIONS->take_path($s, $_[0]) },
		root => $root, res_tag => $prefs->get('resTag'), cover => $SESSIONS->cover_path($s));
	return _done($request, 0, { error => $perr }) unless $plan;
	_simple($request, $EXPORT->start(plan => $plan, session => $sid, root => $root, flac => $flac,
		level => $prefs->get('flacLevel'), on_done => sub {
			my ($r) = @_;
			my $fresh = $SESSIONS->get($sid) or return;
			push @{ $fresh->{exports} ||= [] }, { dir => $r->{dir}, at => time, tracks => $r->{total} };
			$SESSIONS->save($fresh);
			$STATE->_changed if $STATE;
		}));
}

# ---------- premestanje u biblioteku ----------

use constant MOVE_LIMIT => 1800;    # s, cp preko diskova se ubija posle ovoliko
my %MOVING;                          # id sesije -> 1 dok traje

sub media_dirs {
	return [ map { Slim::Utils::Unicode::utf8decode_locale($_) } grep { defined && length } @{ Slim::Utils::Misc::getMediaDirs('audio') || [] } ];
}

sub _cli_browse {
	my ($request) = @_;
	my ($b, $err) = Plugins::AudioIn::Library::browse(_param($request, 'path'), media_dirs());
	return _done($request, 0, { error => $err }) unless $b;
	$request->addResult($_ => $b->{$_}) for grep { defined $b->{$_} } qw(path parent roots dirs truncated);
	$request->setStatusDone;
	return;
}

sub _cli_mkdir {
	my ($request) = @_;
	my ($dir, $err) = Plugins::AudioIn::Library::make_dir(_param($request, 'path'), _param($request, 'name'), media_dirs());
	_done($request, $dir ? 1 : 0, $dir ? undef : { error => $err }, $dir ? (path => $dir) : ());
}

# Poslednji izvoz sesije (jos u folderu za snimke) ide u izabrani folder biblioteke, pa se skenira samo on.
sub _cli_move {
	my ($request) = @_;
	my $sid = _param($request, 'id');
	my $s = $SESSIONS->get($sid) or return _done($request, 0, { error => 'no_session' });
	my ($ex) = grep { !$_->{moved} && -d Plugins::AudioIn::Naming::fs_bytes($_->{dir}) } reverse @{ $s->{exports} || [] };
	return _done($request, 0, { error => 'no_export' }) unless $ex;
	return _done($request, 0, { error => 'busy' }) if $MOVING{$sid};
	my ($dest, $err) = Plugins::AudioIn::Library::plan_move_to($ex->{dir}, _param($request, 'dir'), _param($request, 'name'),
		_rips_dir(), media_dirs());
	return _done($request, 0, { error => $err }) if $err;
	my $src = $ex->{dir};
	$MOVING{$sid} = 1;
	my ($timed_out, @sync, @cp_out);
	Plugins::AudioIn::Library::move_async($src, $dest,
		rips_root => _rips_dir(),
		spawn     => sub {
			my ($argv, $on_exit) = @_;
			my $job = Plugins::AudioIn::Jobs->spawn(argv => [ Plugins::AudioIn::Jobs::low_prio(@$argv) ], on_exit => $on_exit,
				on_line => sub { push @cp_out, $_[0]; shift @cp_out if @cp_out > 5 });    # poruke cp-a za log
			_timer(MOVE_LIMIT, sub { $timed_out = 1; $job->kill if $job->is_running });
		},
		on_done => sub {
			my ($ok, $merr, $warn) = @_;
			@sync = @_;
			delete $MOVING{$sid};
			my $fresh = $SESSIONS->get($sid);
			my ($e) = $fresh ? grep { $_->{dir} eq $src && !$_->{moved} } @{ $fresh->{exports} || [] } : ();
			if ($ok && $e) {
				@$e{qw(dir moved from)} = ($dest, time, $src);
				$e->{warning} = $warn if $warn;
				delete $e->{move_error};
			}
			elsif ($e) { $e->{move_error} = $timed_out ? 'timeout' : ($merr || 'move_failed') }
			$SESSIONS->save($fresh) if $fresh;
			$STATE->_changed if $STATE;
			return $log->error("premestanje u biblioteku: " . ($merr || 'move_failed') . (@cp_out ? ' | ' . join(' | ', @cp_out) : '')) unless $ok;
			Plugins::AudioIn::Library::rescan_when_idle($dest,
				still_scanning => sub { eval { Slim::Music::Import->stillScanning } ? 1 : 0 },
				timer          => sub { _timer(@_); return },
				run            => sub { Slim::Control::Request::executeRequest(undef, $_[0]) },
				log            => sub { $log->warn($_[0]) },
			);
		},
	);
	return _done($request, 0, { error => $sync[1] || 'move_failed' }) if @sync && !$sync[0];
	_done($request, 1, undef, started => 1, dest => $dest);
}

# ---------- MusicBrainz ----------

use constant HTTP_TIMEOUT => 15;
use constant MB_GAP       => 1.1;    # s izmedju zahteva (MusicBrainz pravilo: najvise 1 u sekundi)

my $UA = "AudioIn/$VERSION ( https://github.com/nas963/lyrion-audioin-plugin )";
my @MB_QUEUE;
my $MB_NEXT = 0;
my $MB_TIMER;

# Zahtevi prema musicbrainz.org idu kroz red sa razmakom MB_GAP; ostali (omot) odmah.
sub _http_get {
	my ($url, $ok, $err, %o) = @_;
	my $go = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub { my ($http) = @_; $ok->($http->content, $http->code, $http) },
			sub { my ($http, $error) = @_; $err->($error // 'http') },
			{ timeout => HTTP_TIMEOUT },
		)->get($url, 'User-Agent' => $UA, 'Accept' => $o{accept} // 'application/json');
	};
	return $go->() unless $url =~ m{^https://musicbrainz\.org/};
	push @MB_QUEUE, $go;
	_mb_pump();
	return;
}

sub _mb_pump {
	return if $MB_TIMER || !@MB_QUEUE;
	my $wait = $MB_NEXT - Time::HiRes::time();
	if ($wait > 0) {
		$MB_TIMER = _timer($wait, sub { undef $MB_TIMER; _mb_pump() });
		return;
	}
	$MB_NEXT = Time::HiRes::time() + MB_GAP;
	(shift @MB_QUEUE)->();
	_mb_pump() if @MB_QUEUE;
	return;
}

sub _json_get {
	my ($url, $cb) = @_;
	_http_get($url, sub {
		my ($body, $code) = @_;
		return $cb->(undef, 'mb_busy') if ($code // 200) == 503;
		my $j = eval { JSON::PP->new->utf8->decode($body) };
		return $cb->(undef, 'mb_bad_response') unless ref $j;
		return $cb->(undef, 'mb_busy') if $j->{error};
		$cb->($j, undef);
	}, sub {
		my ($e) = @_;
		$log->warn("MusicBrainz $url: " . ($e // '?'));
		$cb->(undef, ($e // '') =~ /503|busy|unavailable|rate/i ? 'mb_busy' : 'mb_unreachable');
	});
	return;
}

# Ponovni pokusaj kad je MusicBrainz zauzet (cesto vraca "server busy").
sub _json_get_retry {
	my ($url, $cb, $tries) = @_;
	$tries //= 3;
	_json_get($url, sub {
		my ($j, $err) = @_;
		return _timer(2, sub { _json_get_retry($url, $cb, $tries - 1) }) if $err && $err eq 'mb_busy' && $tries > 1;
		$cb->($j, $err);
	});
	return;
}

sub _cli_mb_search {
	my ($request) = @_;
	my $s = $SESSIONS->get(_param($request, 'id'));
	my $artist = _param($request, 'artist') // ($s ? $s->{meta}{artist} : undef);
	my $album  = _param($request, 'album') // ($s ? $s->{meta}{album} : undef);
	my $url = Plugins::AudioIn::Metadata::search_url($artist, $album, catno => _param($request, 'catno'),
		barcode => _param($request, 'barcode'));
	return _done($request, 0, { error => 'mb_no_query' }) unless $url;
	$request->setStatusProcessing;
	_json_get_retry($url, sub {
		my ($j, $err) = @_;
		return _done($request, 0, { error => $err }) if $err;
		my $list = Plugins::AudioIn::Metadata::parse_search($j, $s ? $s->{type} : $prefs->get('sourceType'));
		$request->addResult(ok => 1);
		$request->addResult(releases => [ @$list[ 0 .. ($#$list < 24 ? $#$list : 24) ] ]);
		$request->setStatusDone;
	});
	return;
}

# Izdanje -> sesija (metapodaci, pesme po stranama, ponovna analiza snimaka), pa omot u pozadini.
sub _cli_mb_apply {
	my ($request) = @_;
	my $sid = _param($request, 'id');
	my $s = $SESSIONS->get($sid) or return _done($request, 0, { error => 'no_session' });
	my $url = Plugins::AudioIn::Metadata::release_url(_param($request, 'release'))
		or return _done($request, 0, { error => 'bad_release' });
	$request->setStatusProcessing;
	_json_get_retry($url, sub {
		my ($j, $err) = @_;
		return _done($request, 0, { error => $err }) if $err;
		my $rel = Plugins::AudioIn::Metadata::parse_release($j) or return _done($request, 0, { error => 'mb_bad_response' });
		my ($ok, $e, $res) = $EDITOR->apply_release($sid, $rel);
		return _done($request, 0, $e) unless $ok;
		_fetch_cover($SESSIONS->get($sid), $rel);    # izdanje bez omota: omot grupe izdanja
		$request->addResult(ok => 1);
		$request->addResult(parts => $res->{parts});
		$request->addResult(analyzed => $res->{analyzed});
		$request->setStatusDone;
		$STATE->_changed if $STATE;
	});
	return;
}

sub _fetch_cover {
	my ($s, $rel, @urls) = @_;
	return unless $s;
	@urls = Plugins::AudioIn::Metadata::cover_urls($rel) unless @urls;
	my $url = shift @urls or return;
	_http_get($url, sub {
		my ($body, $code) = @_;
		if (($code // 200) == 200 && length($body // '') > 1000 && substr($body, 0, 3) eq "\xFF\xD8\xFF") {
			my $path = $SESSIONS->cover_path($s);
			if (open(my $fh, '>:raw', "$path.tmp")) {
				print $fh $body;
				close $fh;
				rename("$path.tmp", $path);
				my $fresh = $SESSIONS->get($s->{id});
				if ($fresh) { $fresh->{meta}{cover} = time; $SESSIONS->save($fresh) }
				$STATE->_changed if $STATE;
				return;
			}
		}
		_fetch_cover($s, $rel, @urls);
	}, sub { _fetch_cover($s, $rel, @urls) }, accept => 'image/jpeg');
	return;
}

1;
