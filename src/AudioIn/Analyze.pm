package Plugins::AudioIn::Analyze;

# Predlog granica pesama u snimku iz .peaks zapisa (Peaks.pm: prozori od 10 ms). Cist Perl.
#
# analyze(peaks => [[maxL, maxR, rms], ...], rate => 96000, window_ms => 10,
#         markers => [ { frame, kind } ],          rucni markeri iz snimanja (user / pause)
#         durations => [ s1, s2, ... ],            ocekivana trajanja pesama (metapodaci), opciono
#         opt => { gap_s => 1.0, above_floor_db => 6, max_thr_db => -45, lead_s => 0.5, tail_s => 1.5,
#                  snap_s => 8, place => 'before'|'middle' })
# -> { floor_db, thr_db, music => [start, end] (frejmovi), gaps => [[from, to], ...],
#      tracks => [ { start, end, from => 'silence'|'user'|'pause'|'estimate'|'edge' } ] }
#
# Pravila:
# 1. Pod suma = 10. percentil RMS-a (zaglavljen ka tisini: uvodni zleb, pauze izmedju pesama).
#    Prag tisine = pod + above_floor_db, ali najvise max_thr_db.
# 2. RMS prozora prolazi kroz medijan od 50 ms (klikovi od nekoliko ms ne prekidaju tisinu).
# 3. Pauza = neprekidno ispod praga >= gap_s, izmedju pocetka i kraja muzike.
# 4. Granica u pauzi: lead_s pre pocetka sledece pesme ('before') ili sredina pauze ('middle').
# 5. Prva pesma pocinje lead_s pre pocetka muzike, poslednja se zavrsava tail_s posle kraja.
# 6. Rucni marker se pomera na granicu najblize pauze u krugu snap_s; inace ostaje gde je.
#    Pauze bez markera su takodje granice (korisnik ih brise u editoru).
# 7. Sa ocekivanim trajanjima: od kandidata (pauze i markeri) bira se tacno N-1 granica koje
#    najbolje odgovaraju trajanjima (dinamicko programiranje); fali li kandidat, granica se
#    procenjuje iz trajanja ('estimate').

use strict;
use warnings;

use constant FS => 32768;

our %DEFAULTS = (gap_s => 1.0, above_floor_db => 6, max_thr_db => -45, min_thr_db => -70, lead_s => 0.5,
	tail_s => 1.5, snap_s => 8, place => 'before', music_min_s => 0.3);

sub _db { my ($v) = @_; return $v > 0 ? 20 * log($v / FS) / log(10) : -120 }

sub analyze {
	my (%a) = @_;
	my $pk = $a{peaks} || [];
	my $rate = $a{rate} || 48000;
	my $wms = $a{window_ms} || 10;
	my %o = (%DEFAULTS, %{ $a{opt} || {} });
	my $wf = $rate * $wms / 1000;                 # frejmova po prozoru
	my $total = $a{frames} // int(@$pk * $wf);
	my $n = @$pk;
	return { floor_db => undef, thr_db => undef, music => [ 0, $total ], gaps => [], tracks => [ { start => 0, end => $total, from => 'edge' } ] }
		unless $n;

	# RMS (dB) po prozoru, pa medijan kroz 5 prozora: klik od nekoliko ms podigne jedan prozor i
	# medijan ga ignorise (prosek bi ga razvukao na 50 ms iznad praga).
	my @db = map { _db($_->[2]) } @$pk;
	my $k = int(50 / $wms) || 1;
	my $h = int($k / 2);
	my @sm;
	for my $i (0 .. $n - 1) {
		my $a0 = $i - $h < 0 ? 0 : $i - $h;
		my $a1 = $i + $h > $n - 1 ? $n - 1 : $i + $h;
		my @w = sort { $a <=> $b } @db[ $a0 .. $a1 ];
		$sm[$i] = $w[ int(@w / 2) ];
	}

	my @sorted = sort { $a <=> $b } @sm;
	my $floor = $sorted[ int(@sorted * 0.10) ];
	my $thr = $floor + $o{above_floor_db};
	$thr = $o{max_thr_db} if $thr > $o{max_thr_db};
	$thr = $o{min_thr_db} if $thr < $o{min_thr_db};

	# pocetak i kraj muzike: prvi/poslednji niz iznad praga duzi od music_min_s
	my $need = int($o{music_min_s} * 1000 / $wms) || 1;
	my ($m0, $m1);
	my $run = 0;
	for my $i (0 .. $n - 1) {
		$run = $sm[$i] > $thr ? $run + 1 : 0;
		if ($run >= $need) { $m0 = $i - $need + 1; last }
	}
	$run = 0;
	for (my $i = $n - 1; $i >= 0; $i--) {
		$run = $sm[$i] > $thr ? $run + 1 : 0;
		if ($run >= $need) { $m1 = $i + $need; last }
	}
	unless (defined $m0 && defined $m1 && $m1 > $m0) {
		return { floor_db => _r($floor), thr_db => _r($thr), music => [ 0, $total ], gaps => [],
			tracks => [ { start => 0, end => $total, from => 'edge' } ] };
	}

	# pauze izmedju m0 i m1
	my $gapw = int($o{gap_s} * 1000 / $wms) || 1;
	my @gaps;
	my $g0;
	for my $i ($m0 .. $m1) {
		my $quiet = $i < $m1 && $sm[$i] <= $thr;
		if ($quiet) { $g0 //= $i; next }
		if (defined $g0) {
			push @gaps, [ $g0, $i ] if $i - $g0 >= $gapw;
			undef $g0;
		}
	}
	my $f = sub { my $x = int($_[0] * $wf + 0.5); $x < 0 ? 0 : $x > $total ? $total : $x };
	my $lead = int($o{lead_s} * $rate);
	my @gapf = map { [ $f->($_->[0]), $f->($_->[1]) ] } @gaps;
	my $boundary = sub {
		my ($g) = @_;
		return int(($g->[0] + $g->[1]) / 2) if $o{place} eq 'middle';
		my $b = $g->[1] - $lead;
		return $b < $g->[0] ? $g->[0] : $b;
	};
	my $start = $f->($m0) - $lead;
	$start = 0 if $start < 0;
	my $end = $f->($m1) + int($o{tail_s} * $rate);
	$end = $total if $end > $total;

	# kandidati: pauze (sa granicom) i rucni markeri (pomereni na pauzu u krugu snap_s)
	my %cand;    # frejm -> izvor
	$cand{ $boundary->($_) } = 'silence' for @gapf;
	my $snap = int($o{snap_s} * $rate);
	for my $m (@{ $a{markers} || [] }) {
		my $fr = $m->{frame} // next;
		next if $fr <= $start || $fr >= $end;
		my ($best, $bd);
		for my $g (@gapf) {
			my $b = $boundary->($g);
			my $d = $fr < $g->[0] ? $g->[0] - $fr : $fr > $g->[1] ? $fr - $g->[1] : 0;
			($best, $bd) = ($b, $d) if $d <= $snap && (!defined $bd || $d < $bd);
		}
		my $kind = ($m->{kind} // 'user') eq 'pause' ? 'pause' : 'user';
		if (defined $best) { $cand{$best} = $kind } else { $cand{$fr} = $kind }
	}
	my @cands = sort { $a <=> $b } grep { $_ > $start && $_ < $end } keys %cand;

	my @bounds;
	if (my $dur = $a{durations} and @{ $a{durations} || [] } > 1) {
		@bounds = _fit_durations([ map { $_ * $rate } @$dur ], \@cands, \%cand, $start, $end, $rate);
	}
	else {
		@bounds = map { [ $_, $cand{$_} ] } @cands;
	}

	# from = odakle je granica na POCETKU pesme (prva pesma: edge)
	my @starts = ([ $start, q(edge) ], @bounds);
	my @tracks;
	for my $i (0 .. $#starts) {
		push @tracks, { start => $starts[$i][0], end => $i < $#starts ? $starts[ $i + 1 ][0] : $end, from => $starts[$i][1] };
	}
	return { floor_db => _r($floor), thr_db => _r($thr), music => [ $f->($m0), $f->($m1) ],
		gaps => \@gapf, tracks => \@tracks };
}

sub _r { return defined $_[0] ? sprintf('%.1f', $_[0]) + 0 : undef }

# Bira N-1 granica (N = broj trajanja) iz kandidata tako da zbir kvadrata odstupanja duzina pesama od
# ocekivanih bude najmanji. Kandidat moze i da se preskoci; ako ih ima manje nego granica, ili je
# najbolje resenje losije od procene, granica je procena (kumulativno trajanje, 'estimate').
sub _fit_durations {
	my ($dur, $cands, $kind, $start, $end, $rate) = @_;
	my $n = @$dur;
	# skaliranje: snimak moze biti malo brzi/sporiji (gramofon), ocekivane duzine se skaliraju na ukupnu
	my $exp = 0;
	$exp += $_ for @$dur;
	my $scale = $exp > 0 ? ($end - $start) / $exp : 1;
	$scale = 1 if $scale < 0.8 || $scale > 1.25;    # mnogo razlicito: ne skalirati (fale/viska pesama)
	my @d = map { $_ * $scale } @$dur;
	my @cum = ($start);
	push @cum, $cum[-1] + $_ for @d;

	# kandidat po granici: za granicu j (1..n-1) biraju se kandidati u rastucem redu ili procena
	my @pts = (@$cands);
	my $INF = 9**9**9;
	# dp[j][i]: najmanja cena kad je granica j na kandidatu i (i = -1 znaci procena)
	my (@dp, @bk);
	for my $j (1 .. $n - 1) {
		my @opts = ((map { [ $_, $pts[$_] ] } 0 .. $#pts), [ -1, $cum[$j] ]);
		for my $o (@opts) {
			my ($i, $pos) = @$o;
			my $pen = $i < 0 ? (2 * ($rate || 48000)) ** 2 : 0;    # procena je skuplja od dobrog kandidata (~2 s greske)
			my ($best, $bi) = ($INF, undef);
			if ($j == 1) {
				my $len = $pos - $start;
				$best = ($len - $d[0]) ** 2 + $pen;
			}
			else {
				for my $p (keys %{ $dp[ $j - 1 ] }) {
					my ($pc, $ppos) = @{ $dp[ $j - 1 ]{$p} };
					next if $ppos >= $pos;
					next if $i >= 0 && $p >= 0 && $p >= $i;
					my $c = $pc + ($pos - $ppos - $d[ $j - 1 ]) ** 2 + $pen;
					($best, $bi) = ($c, $p) if $c < $best;
				}
			}
			next if $best >= $INF;
			$dp[$j]{$i} = [ $best, $pos ];
			$bk[$j]{$i} = $bi;
		}
	}
	return () unless $n > 1 && $dp[ $n - 1 ];
	my ($bestc, $last) = ($INF, undef);
	for my $i (keys %{ $dp[ $n - 1 ] }) {
		my ($c, $pos) = @{ $dp[ $n - 1 ]{$i} };
		$c += ($end - $pos - $d[-1]) ** 2;
		($bestc, $last) = ($c, $i) if $c < $bestc;
	}
	my @sel;
	my $i = $last;
	for (my $j = $n - 1; $j >= 1; $j--) {
		my $pos = $dp[$j]{$i}[1];
		unshift @sel, [ int($pos), $i < 0 ? 'estimate' : $kind->{ $pts[$i] } ];
		$i = $bk[$j]{$i};
	}
	return @sel;
}

1;
