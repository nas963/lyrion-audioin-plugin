package Plugins::AudioIn::CaptureClient;

# LMS strana pomocnog procesa audioin-capture: pokretanje preko Jobs-a (stdin pipe), komande,
# dogadjaji, restart sa backoff-om ako pomocnik umre. Cist Perl; spawn i tajmeri se ubacuju.
#
# new(argv => sub -> [argv], spawn => sub(%a) -> $job, timer => sub($s, $cb) -> $h,
#     cancel_timer => sub($h), on_event => sub(\%ev), log => sub($nivo, $poruka),
#     [backoff => [1, 2, 5, 10, 30, 60], stable => 60, now => sub])
# send(\%cmd) -> 1|0. Dogadjaj {"ev":"helper","state":"down"} kad pomocnik umre (pre restarta).

use strict;
use warnings;
use utf8;

use JSON::PP ();
use Time::HiRes ();

my $JSON = JSON::PP->new->ascii->canonical;

sub new {
	my ($class, %o) = @_;
	for (qw(argv spawn timer)) { die "CaptureClient: $_ je obavezan\n" unless $o{$_} }
	return bless {
		%o,
		backoff => $o{backoff} || [ 1, 2, 5, 10, 30, 60 ],
		stable  => $o{stable} // 60,
		now     => $o{now} || \&Time::HiRes::time,
		job     => undef,
		fails   => 0,
		stopped => 0,
		restart => undef,
		ready   => 0,
	}, $class;
}

sub _log {
	my ($self, $lvl, $msg) = @_;
	eval { $self->{log}->($lvl, $msg) if $self->{log}; 1 };
	return;
}

sub running { my ($self) = @_; return $self->{job} && $self->{job}->is_running ? 1 : 0 }
sub ready   { $_[0]{ready} }
sub pid     { my ($self) = @_; return $self->{job} ? $self->{job}->pid : undef }

sub start {
	my ($self) = @_;
	return if $self->{stopped} || $self->{job};
	$self->_cancel_restart;
	my $job;
	$job = eval {
		$self->{spawn}->(
			argv    => $self->{argv}->(),
			stdin   => 'pipe',
			on_line => sub { $self->_line($_[0]) },
			on_exit => sub { $self->_exited($job, $_[0]) },
		);
	};
	unless ($job) {
		$self->_log(warn => 'audioin-capture nije pokrenut: ' . ($@ || 'nema posla'));
		$self->_schedule_restart;
		return;
	}
	$self->{job}     = $job;
	$self->{ready}   = 0;
	$self->{started} = $self->{now}->();
	return;
}

# Gasenje: quit + EOF (pomocnik zavrsava snimak u toku), pa kill posle roka u Jobs-u.
sub stop {
	my ($self) = @_;
	$self->{stopped} = 1;
	$self->_cancel_restart;
	my $job = $self->{job} or return;
	$job->write_stdin($JSON->encode({ cmd => 'quit' }) . "\n");
	$job->close_stdin;
	return $job;
}

sub send {
	my ($self, $msg) = @_;
	my $job = $self->{job};
	return 0 unless $job && $job->is_running;
	return $job->write_stdin($JSON->encode($msg) . "\n") ? 1 : 0;
}

sub _line {
	my ($self, $line) = @_;
	my $ev = $line =~ /^\{/ ? eval { $JSON->decode($line) } : undef;
	unless (ref $ev eq 'HASH' && defined $ev->{ev}) {
		$self->_log(info => "audioin-capture: $line") if length $line;
		return;
	}
	if ($ev->{ev} eq 'log') {
		$self->_log(info => "audioin-capture: $ev->{msg}");
		return;
	}
	$self->{ready} = 1 if $ev->{ev} eq 'ready';
	eval { $self->{on_event}->($ev) if $self->{on_event}; 1 } or $self->_log(warn => "dogadjaj $ev->{ev}: $@");
	return;
}

sub _exited {
	my ($self, $job, $status) = @_;
	return unless $self->{job} && $job && $self->{job} == $job;
	$self->{job} = undef;
	$self->{ready} = 0;
	eval { $self->{on_event}->({ ev => 'helper', state => 'down', status => $status }) if $self->{on_event}; 1 };
	return if $self->{stopped};
	$self->_log(warn => "audioin-capture je izasao (status $status)");
	$self->{fails} = 0 if $self->{started} && $self->{now}->() - $self->{started} > $self->{stable};
	$self->_schedule_restart;
	return;
}

sub _schedule_restart {
	my ($self) = @_;
	return if $self->{stopped} || $self->{restart};
	my $b = $self->{backoff};
	my $d = $b->[ $self->{fails} < @$b ? $self->{fails} : -1 ];
	$self->{fails}++;
	$self->{restart} = $self->{timer}->($d, sub { $self->{restart} = undef; $self->start });
	return;
}

sub _cancel_restart {
	my ($self) = @_;
	my $t = delete $self->{restart} or return;
	$self->{cancel_timer}->($t) if $self->{cancel_timer};
	return;
}

1;
