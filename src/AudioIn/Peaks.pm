package Plugins::AudioIn::Peaks;

# Pregled talasnog oblika snimka (.peaks): za svaki prozor od WINDOW_MS ms tri broja u 16-bitnoj
# skali: najveca apsolutna vrednost levog i desnog kanala i RMS oba kanala zajedno.
# Zapis: 'v3' po prozoru (6 B), bez zaglavlja; trajanje prozora i frekvencija su u .json snimka.
# Za 10 ms to je 600 B/s (~36 KB po minutu). Cist Perl.
#
# Pisac:  my $p = Plugins::AudioIn::Peaks->new(rate => 96000);  my $bytes = $p->add($s24);  $p->flush
# Citanje: Plugins::AudioIn::Peaks::parse($bytes) -> [ [maxL, maxR, rms], ... ]

use strict;
use warnings;

use constant WINDOW_MS    => 10;
use constant RECORD_BYTES => 6;

sub new {
	my ($class, %o) = @_;
	my $rate = $o{rate} || 48000;
	my $w = int($rate * WINDOW_MS / 1000) || 1;
	return bless { w => $w, n => 0, ml => 0, mr => 0, ss => 0 }, $class;
}

sub window_frames { $_[0]{w} }

# Dodaje stereo S24_3LE blok, vraca zapise za sve zavrsene prozore.
sub add {
	my ($self, $data) = @_;
	my @v = unpack('(x s<)*', defined $data ? $data : '');
	my $out = '';
	my ($w, $n, $ml, $mr, $ss) = @$self{qw(w n ml mr ss)};
	for (my $i = 0; $i < @v; $i += 2) {
		my ($a, $b) = ($v[$i], $v[$i + 1]);
		$ss += $a * $a + $b * $b;
		$a = -$a if $a < 0;
		$b = -$b if $b < 0;
		$ml = $a if $a > $ml;
		$mr = $b if $b > $mr;
		if (++$n >= $w) {
			$out .= _rec($ml, $mr, $ss, $n);
			($n, $ml, $mr, $ss) = (0, 0, 0, 0);
		}
	}
	@$self{qw(n ml mr ss)} = ($n, $ml, $mr, $ss);
	return $out;
}

# Zapis za nepotpun poslednji prozor (na kraju snimka).
sub flush {
	my ($self) = @_;
	return '' unless $self->{n};
	my $out = _rec(@$self{qw(ml mr ss n)});
	@$self{qw(n ml mr ss)} = (0, 0, 0, 0);
	return $out;
}

sub _rec {
	my ($ml, $mr, $ss, $n) = @_;
	my $rms = int(sqrt($ss / (2 * $n)) + 0.5);
	$_ > 32767 and $_ = 32767 for $ml, $mr, $rms;
	return pack('v3', $ml, $mr, $rms);
}

sub parse {
	my ($bytes) = @_;
	my @v = unpack('v*', defined $bytes ? $bytes : '');
	my @r;
	push @r, [ @v[ $_ * 3 .. $_ * 3 + 2 ] ] for 0 .. int(@v / 3) - 1;
	return \@r;
}

1;
