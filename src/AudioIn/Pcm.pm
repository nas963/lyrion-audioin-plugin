package Plugins::AudioIn::Pcm;

# PCM pomocne funkcije, cist Perl.
# Interni format je uvek stereo S24_3LE (6 B po frejmu): sve sto dolazi sa ulaza se pretvara u njega
# (izbor para kanala ili mono udvojen u oba kanala), bez promene vrednosti uzoraka (16 bit se
# siri nulama, 32 bit gubi samo najnizi bajt koji kod 24-bitnih AD konvertora nosi nule).
# Nivoi se racunaju iz gornjih 16 bita svakog uzorka: dovoljno za merac i detekciju tisine
# (dinamika ~96 dB), a brze jer unpack radi u C-u.

use strict;
use warnings;

use constant FRAME_BYTES => 6;
use constant FULL_SCALE  => 32768;

our %SAMPLE_BYTES = (S16_LE => 2, S24_3LE => 3, S24_LE => 4, S32_LE => 4);

sub sample_bytes { my ($fmt) = @_; return $SAMPLE_BYTES{$fmt} }

# Bajtova po ulaznom frejmu za format i broj kanala.
sub in_frame_bytes {
	my ($fmt, $channels) = @_;
	my $sb = $SAMPLE_BYTES{$fmt} or return undef;
	return $sb * ($channels || 2);
}

# Jedan uzorak (bajtovi u formatu $fmt) -> 3 bajta S24_3LE.
sub _sample_to_s24 {
	my ($fmt) = @_;
	return sub { "\0" . $_[0] } if $fmt eq 'S16_LE';
	return sub { $_[0] } if $fmt eq 'S24_3LE';
	return sub { substr($_[0], 1, 3) } if $fmt eq 'S32_LE';
	return sub { substr($_[0], 0, 3) } if $fmt eq 'S24_LE';    # 24 bita u donja 3 bajta od 4
	die "Pcm: nepoznat format $fmt\n";
}

# converter(fmt => 'S24_3LE', channels => 2, left => 0, right => 1)
# -> sub($bytes) -> stereo S24_3LE. left/right su indeksi kanala (0-based); mono = isti indeks.
# Nepotpun frejm na kraju se cuva za sledeci poziv.
sub converter {
	my (%o) = @_;
	my $fmt = $o{fmt} || 'S24_3LE';
	my $ch  = $o{channels} || 2;
	my $l   = $o{left}  // 0;
	my $r   = $o{right} // ($ch > 1 ? 1 : 0);
	my $sb  = $SAMPLE_BYTES{$fmt} or die "Pcm: nepoznat format $fmt\n";
	die "Pcm: kanal van opsega\n" if $l < 0 || $r < 0 || $l >= $ch || $r >= $ch;
	my $ifb = $sb * $ch;
	my $part = '';

	# brzi putevi za najcesce slucajeve
	if ($ch == 2 && $l == 0 && $r == 1) {
		my $fast;
		$fast = sub { $_[0] } if $fmt eq 'S24_3LE';
		$fast = sub { my $d = $_[0]; $d =~ s/(..)/\0$1/gs; $d } if $fmt eq 'S16_LE';
		$fast = sub { my $d = $_[0]; $d =~ s/.(...)/$1/gs; $d } if $fmt eq 'S32_LE';
		$fast = sub { my $d = $_[0]; $d =~ s/(...)./$1/gs; $d } if $fmt eq 'S24_LE';
		return sub {
			my $d = $part . (defined $_[0] ? $_[0] : '');
			my $rest = length($d) % $ifb;
			$part = $rest ? substr($d, -$rest, $rest, '') : '';
			return $fast->($d);
		};
	}

	my $conv = _sample_to_s24($fmt);
	return sub {
		my $d = $part . (defined $_[0] ? $_[0] : '');
		my $frames = int(length($d) / $ifb);
		$part = substr($d, $frames * $ifb);
		my $out = '';
		for my $i (0 .. $frames - 1) {
			my $base = $i * $ifb;
			$out .= $conv->(substr($d, $base + $l * $sb, $sb)) . $conv->(substr($d, $base + $r * $sb, $sb));
		}
		return $out;
	};
}

# Gornjih 16 bita svih uzoraka stereo S24_3LE bloka: (L0, R0, L1, R1, ...).
sub top16 { return unpack('(x s<)*', $_[0]) }

# levels($s24) -> { frames, peak => [l, r], sumsq => [l, r], clip => n } (vrednosti u 16-bitnoj skali)
sub levels {
	my ($data) = @_;
	my @v = top16($data);
	my ($pl, $pr, $sl, $sr, $clip) = (0, 0, 0, 0, 0);
	for (my $i = 0; $i < @v; $i += 2) {
		my ($a, $b) = ($v[$i], $v[$i + 1]);
		$clip++ if $a >= 32767 || $a <= -32768 || $b >= 32767 || $b <= -32768;
		$a = -$a if $a < 0;
		$b = -$b if $b < 0;
		$pl = $a if $a > $pl;
		$pr = $b if $b > $pr;
		$sl += $a * $a;
		$sr += $b * $b;
	}
	return { frames => int(@v / 2), peak => [ $pl, $pr ], sumsq => [ $sl, $sr ], clip => $clip };
}

# Vrednost u 16-bitnoj skali -> dBFS (zaokruzeno na 0.1); 0 -> undef (tisina, -inf).
sub dbfs {
	my ($v) = @_;
	return undef unless defined $v && $v > 0;
	return sprintf('%.1f', 20 * log($v / FULL_SCALE) / log(10)) + 0;
}

sub rms_dbfs {
	my ($sumsq, $n) = @_;
	return undef unless $n && $sumsq > 0;
	return dbfs(sqrt($sumsq / $n));
}

# Pakovanje sirovih brojeva u S24_3LE (za testove i generator): (L0, R0, ...) u 24-bitnoj skali.
sub pack_s24 {
	my (@v) = @_;
	return join '', map { my $x = $_ < 0 ? $_ + (1 << 24) : $_; pack('Cv', $x & 0xFF, $x >> 8) } @v;
}

1;
