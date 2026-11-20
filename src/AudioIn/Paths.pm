package Plugins::AudioIn::Paths;

# Putanje koje dele LMS plugin, pomocni proces (audioin-capture) i audioin-tap. Cist Perl.
# Socket za citace je u prvom folderu iz liste koji moze da se napravi/upise; tap trazi isti
# redosled, pa se ne mora nigde zapisivati koji je izabran.

use strict;
use warnings;

use constant SOCK_NAME => 'tap.sock';

# AUDIOIN_RUN_DIR (testovi) zamenjuje celu listu.
sub run_dirs {
	return ($ENV{AUDIOIN_RUN_DIR}) if $ENV{AUDIOIN_RUN_DIR};
	my $uid = $<;
	return ('/run/audioin', '/dev/shm/audioin', ($ENV{TMPDIR} && $ENV{TMPDIR} =~ m{^/} ? "$ENV{TMPDIR}/audioin-$uid" : "/tmp/audioin-$uid"));
}

# Prvi folder koji postoji (ili moze da se napravi) i u koji moze da se pise.
sub pick_run_dir {
	my (@dirs) = @_ ? @_ : run_dirs();
	for my $d (@dirs) {
		mkdir $d, 0755 unless -d $d;
		return $d if -d $d && -w _;
	}
	return undef;
}

# Socket-i koji postoje, po redosledu (tap pokusava redom).
sub existing_sockets {
	my (@dirs) = @_ ? @_ : run_dirs();
	return grep { -S $_ } map { "$_/" . SOCK_NAME } @dirs;
}

1;
