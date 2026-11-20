package Plugins::AudioIn::Menu;

# Cvor "Audio ulaz" u My Music (aplikacije i Material): slusanje, snimanje, marker, pauza, stop,
# sledeca strana. Stavke zavise od stanja (State snapshot). feed() i node() su cisti (bez Slim::*),
# pa se testiraju bez LMS-a; LMS se dodiruje tek u default_run() (audioin CLI preko executeRequest).
# Komande idu sa klijentom iz kog je meni otvoren: Slusaj pusta na tom plejeru, a marker se racuna
# po onome sto taj plejer svira.

use strict;
use warnings;
use utf8;

use constant ICON   => 'plugins/AudioIn/audioin-icon.png';
use constant WEIGHT => 96;

sub node {
	my ($feed) = @_;
	return {
		type         => 'link',
		name         => 'PLUGIN_AUDIOIN',
		id           => 'audioin',
		feed         => $feed,
		icon         => ICON,
		jiveIcon     => ICON,
		weight       => WEIGHT,
		homeMenuText => 'PLUGIN_AUDIOIN',
	};
}

sub _tr {
	my ($o, $token, @args) = @_;
	my $s = $o->{string}->($token, @args);
	return defined $s && length $s ? $s : $token;
}

sub default_run {
	my ($client, $cmd) = @_;
	require Slim::Control::Request;
	my $req = Slim::Control::Request::executeRequest($client, $cmd);
	my $err = $req ? $req->getResult('error') : 'failed';
	return defined $err ? (undef, { error => $err }) : (1, undef);
}

sub _mmss {
	my ($s) = @_;
	$s = int($s || 0);
	my $h = int($s / 3600);
	my $m = int($s / 60) % 60;
	return $h ? sprintf('%d:%02d:%02d', $h, $m, $s % 60) : sprintf('%d:%02d', $m, $s % 60);
}

# Stavka-link: izvrsi komandu i odgovori jednom tekstualnom stavkom (uz "nextWindow: refresh" za Jive).
sub _action {
	my ($o, $name, $cmd, $ok_token) = @_;
	return {
		name => $name,
		type => 'link',
		url  => sub {
			my ($client, $cb) = @_;
			my ($ok, $err) = $o->{run}->($client, $cmd);
			my $code = uc(($err && $err->{error}) || 'failed');
			my $text = $ok ? _tr($o, $ok_token) : _tr($o, "PLUGIN_AUDIOIN_ERR_$code");
			$text = _tr($o, 'PLUGIN_AUDIOIN_ERR_FAILED') . " ($code)" if !$ok && $text eq "PLUGIN_AUDIOIN_ERR_$code";
			$cb->({ items => [ { name => $text, type => 'text', nextWindow => 'parent' } ] });
		},
		nextWindow => 'refresh',
	};
}

# feed($client, $cb, $args, $snapshot, \%opts)  opts: string => sub($token, @args), run => sub($client, \@cmd)
sub feed {
	my ($client, $cb, $args, $snap, $opts) = @_;
	my %o = (string => sub { $_[0] }, run => \&default_run, %{ $opts || {} });
	$snap ||= {};
	my $in = $snap->{input} || {};
	my $rec = $snap->{rec};
	my $ses = $snap->{session};
	my @items;

	unless ($snap->{helper}) {
		return $cb->({ name => _tr(\%o, 'PLUGIN_AUDIOIN'), items => [ { name => _tr(\%o, 'PLUGIN_AUDIOIN_ERR_HELPER'), type => 'text' } ] });
	}

	# stanje ulaza
	my $state = $in->{open}
		? _tr(\%o, 'PLUGIN_AUDIOIN_UI_INPUT') . ': 24 bit / ' . (($in->{rate} || 0) / 1000) . ' kHz'
			. ($snap->{listeners} ? ' · ' . _tr(\%o, 'PLUGIN_AUDIOIN_UI_LISTENERS') . ": $snap->{listeners}" : '')
		: _tr(\%o, 'PLUGIN_AUDIOIN_UI_CLOSED');
	push @items, { name => $state, type => 'text' };

	# slusanje
	push @items, _action(\%o, _tr(\%o, $snap->{listeners} ? 'PLUGIN_AUDIOIN_UI_LIVE' : 'PLUGIN_AUDIOIN_UI_LISTEN'),
		[ 'audioin', 'listen' ], 'PLUGIN_AUDIOIN_MENU_LISTENING');

	# snimanje
	my $album = $ses && $ses->{meta} ? join(' – ', grep { defined && length } @{ $ses->{meta} }{qw(artist album)}) : '';
	if ($rec) {
		my $paused = ($rec->{state} // '') eq 'paused';
		push @items, { name => ($paused ? '❚❚ ' : '● ') . _tr(\%o, 'PLUGIN_AUDIOIN_UI_RECORDING') . " $rec->{part} · " . _mmss($rec->{seconds})
			. ' · ' . _tr(\%o, 'PLUGIN_AUDIOIN_UI_MARKERS') . ': ' . ($rec->{markers} || 0), type => 'text' };
		push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_MARKER'), [ 'audioin', 'marker' ], 'PLUGIN_AUDIOIN_MENU_MARKER_SET')
			unless $paused;
		push @items, $paused
			? _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_RESUME'), [ 'audioin', 'rec_resume' ], 'PLUGIN_AUDIOIN_MENU_RESUMED')
			: _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_PAUSE'), [ 'audioin', 'rec_pause' ], 'PLUGIN_AUDIOIN_MENU_PAUSED');
		push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_STOP'), [ 'audioin', 'rec_stop' ], 'PLUGIN_AUDIOIN_MENU_STOPPED');
		push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_NEXT_PART'), [ 'audioin', 'next_part' ], 'PLUGIN_AUDIOIN_MENU_NEXT_PART');
	}
	else {
		my $part = $snap->{part} // 'A';
		my $label = _tr(\%o, 'PLUGIN_AUDIOIN_UI_RECORD') . ' · ' . _tr(\%o, 'PLUGIN_AUDIOIN_UI_PART') . " $part";
		$label .= " · $album" if length $album;
		push @items, _action(\%o, $label, [ 'audioin', 'rec_start' ], 'PLUGIN_AUDIOIN_MENU_RECORDING');
		push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_NEXT_PART'), [ 'audioin', 'next_part' ], 'PLUGIN_AUDIOIN_MENU_NEXT_PART')
			if $ses;
		push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOIN_UI_CLOSE'), [ 'audioin', 'close' ], 'PLUGIN_AUDIOIN_UI_CLOSED')
			if $in->{open};
	}
	return $cb->({ name => _tr(\%o, 'PLUGIN_AUDIOIN'), items => \@items });
}

1;
