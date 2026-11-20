package Plugins::AudioIn::Ring;

# Kruzni bafer PCM-a u memoriji (timeshift, pred-snimanje, citaci koji kasne). Cist Perl.
#
# Pozicije su apsolutni brojevi frejmova od otvaranja ulaza (0, 1, 2, ...), ne bajtovi u baferu.
# head = broj upisanih frejmova; najstariji raspoloziv frejm je tail = max(0, head - capacity).
# Frejm je fiksne velicine (podrazumevano 6 B: stereo S24_3LE).
#
# new(frames => N, frame_bytes => 6)
# write($bytes)              upisuje cele frejmove (ostatak < frame_bytes se cuva za sledeci upis)
# read($pos, $max) -> ($bytes, $from)   najvise $max frejmova od $pos; $pos ispod tail-a se
#                                       pomera na tail ($from je stvarni pocetak), iznad head-a -> ''
# head, tail, capacity, frame_bytes

use strict;
use warnings;

sub new {
	my ($class, %o) = @_;
	my $fb = $o{frame_bytes} || 6;
	my $n  = int($o{frames} || 0);
	die "Ring: frames mora biti > 0\n" unless $n > 0;
	return bless {
		fb   => $fb,
		cap  => $n,
		buf  => "\0" x ($n * $fb),
		head => 0,
		part => '',
	}, $class;
}

sub capacity    { $_[0]{cap} }
sub frame_bytes { $_[0]{fb} }
sub head        { $_[0]{head} }

sub tail {
	my ($self) = @_;
	my $t = $self->{head} - $self->{cap};
	return $t > 0 ? $t : 0;
}

# Upisuje bajtove; vraca broj upisanih celih frejmova.
sub write {
	my ($self, $data) = @_;
	return 0 unless defined $data && length $data;
	my $fb = $self->{fb};
	if (length $self->{part}) {
		$data = $self->{part} . $data;
		$self->{part} = '';
	}
	my $frames = int(length($data) / $fb);
	my $rest = length($data) - $frames * $fb;
	$self->{part} = substr($data, -$rest) if $rest;
	return 0 unless $frames;

	# samo poslednjih cap frejmova ima smisla upisati
	my $skip = 0;
	if ($frames > $self->{cap}) {
		$skip = $frames - $self->{cap};
	}
	my $pos = ($self->{head} + $skip) % $self->{cap};
	my $todo = $frames - $skip;
	my $off = $skip * $fb;
	while ($todo > 0) {
		my $n = $self->{cap} - $pos;
		$n = $todo if $n > $todo;
		substr($self->{buf}, $pos * $fb, $n * $fb) = substr($data, $off, $n * $fb);
		$off += $n * $fb;
		$todo -= $n;
		$pos = ($pos + $n) % $self->{cap};
	}
	$self->{head} += $frames;
	return $frames;
}

sub read {
	my ($self, $pos, $max) = @_;
	$pos = 0 unless defined $pos && $pos > 0;
	my $tail = $self->tail;
	$pos = $tail if $pos < $tail;
	my $avail = $self->{head} - $pos;
	return ('', $pos) if $avail <= 0 || !$max || $max <= 0;
	my $n = $avail < $max ? $avail : $max;
	my $fb = $self->{fb};
	my $i = $pos % $self->{cap};
	my $first = $self->{cap} - $i;
	if ($first >= $n) {
		return (substr($self->{buf}, $i * $fb, $n * $fb), $pos);
	}
	return (substr($self->{buf}, $i * $fb, $first * $fb) . substr($self->{buf}, 0, ($n - $first) * $fb), $pos);
}

1;
