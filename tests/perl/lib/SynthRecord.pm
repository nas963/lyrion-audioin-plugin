package SynthRecord;

# Sinteticka "strana ploce" za testove analize: uvodni zleb, pesme (ton sa ovojnicom), pauze sa sumom
# povrsine i klikovima, tih prolaz unutar pesme (ne sme da se sece), izlazni zleb.
# make(rate => 8000, seed => 1) -> { pcm => stereo S24_3LE, rate, frames, tracks => [[start, end] u frejmovima] }
# Granice u "tracks" su pocetak i kraj zvuka svake pesme (bez lead/tail).

use strict;
use warnings;

use Plugins::AudioIn::Pcm;

# opis: [vrsta, sekunde, (za pesmu) ima_tih_prolaz]
our @LAYOUT = (
	[ lead => 2 ],
	[ song => 20 ],
	[ gap  => 2 ],
	[ song => 15 ],
	[ gap  => 1.5 ],
	[ song => 18, 1 ],    # tih prolaz od 0.6 s na sredini (ispod -40 dBFS, iznad suma)
	[ gap  => 3 ],
	[ song => 10 ],
	[ out  => 4 ],
);

sub make {
	my (%o) = @_;
	my $rate = $o{rate} || 8000;
	srand($o{seed} // 1);
	my $noise = 10 ** (-58 / 20) * 0x7FFFFF;    # sum povrsine ~ -58 dBFS
	my $amp   = 10 ** (-12 / 20) * 0x7FFFFF;
	my @v;
	my @tracks;
	my $pos = 0;
	my $click_every = int($rate * 0.7);
	for my $seg (@LAYOUT) {
		my ($kind, $secs, $quiet) = @$seg;
		my $n = int($secs * $rate);
		my $fade = int(0.4 * $rate);
		for my $i (0 .. $n - 1) {
			my $s = ($i % 2 ? 1 : -1) * $noise * (rand() * 2 - 1) * 1.7;
			if ($kind eq 'song') {
				my $env = 1;
				$env = $i / $fade if $i < $fade;
				$env = ($n - $i) / $fade if $n - $i < $fade;
				$env *= 0.008 if $quiet && $i > $n / 2 - 0.3 * $rate && $i < $n / 2 + 0.3 * $rate;
				$s += $amp * $env * sin(2 * 3.14159265 * 440 * $i / $rate) * (0.6 + 0.4 * sin($i / $rate));
			}
			elsif ($i % $click_every == 100) {
				$s = 0x500000;    # klik od jednog uzorka
			}
			$s = int($s);
			push @v, $s, -$s;
		}
		push @tracks, [ $pos, $pos + $n ] if $kind eq 'song';
		$pos += $n;
	}
	return { pcm => Plugins::AudioIn::Pcm::pack_s24(@v), rate => $rate, frames => $pos, tracks => \@tracks };
}

1;
