package Plugins::AudioIn::Metadata;

# MusicBrainz: pretraga izdanja po tekstu, parsiranje izdanja i raspodela pesama po stranama snimka.
# Cist Perl (HTTP radi Plugin). Omot: Cover Art Archive.
#
# search_url(artist, album) / parse_search($json, $type) -> [ { id, title, artist, date, country, label, catno,
#     formats, media, tracks, score, match } ]   (match = format odgovara vrsti izvora; ti su prvi)
# release_url($id) / parse_release($json) -> { id, release_group_id, artist, album, year, cover_url,
#     media => [ { format, position, tracks => [ { number, title, artist, length, recording_id } ] } ] }
# sides($release) -> [ { name => 'A'|undef, tracks => [...] } ]   (undef = izdanje nema oznake strana)
# assign($release, [ { name => 'A', seconds => trajanje muzike } ]) -> { 'A' => [tracks], ... }

use strict;
use warnings;
use utf8;

use JSON::PP ();

use constant MB_BASE  => 'https://musicbrainz.org/ws/2';
use constant CAA_BASE => 'https://coverartarchive.org';
use constant VARIOUS  => '89ad4ac3-39f7-470e-963a-56509c546377';

our %FORMAT_RE = (vinyl => qr/vinyl/i, cassette => qr/cassette/i);

sub _esc {
	my ($s) = @_;
	utf8::encode($s) if utf8::is_utf8($s);
	$s =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
	return $s;
}

# Lucene: navodnici i specijalni znakovi se escape-uju; prazna polja se izostavljaju.
sub _lucene { my ($s) = @_; $s =~ s/([+\-&|!(){}\[\]^"~*?:\\\/])/\\$1/g; return $s }

sub search_url {
	my ($artist, $album, %o) = @_;
	my @q;
	push @q, 'artist:"' . _lucene($artist) . '"' if defined $artist && length $artist;
	push @q, 'release:"' . _lucene($album) . '"' if defined $album && length $album;
	push @q, 'catno:"' . _lucene($o{catno}) . '"' if defined $o{catno} && length $o{catno};
	push @q, 'barcode:' . _lucene($o{barcode}) if defined $o{barcode} && length $o{barcode};
	return undef unless @q;
	return MB_BASE . '/release?query=' . _esc(join(' AND ', @q)) . '&fmt=json&limit=' . ($o{limit} || 25);
}

sub release_url {
	my ($id) = @_;
	return undef unless defined $id && $id =~ /\A[0-9a-f-]{36}\z/;
	return MB_BASE . "/release/$id?inc=recordings+artist-credits+release-groups+media+labels&fmt=json";
}

sub cover_urls {
	my ($rel) = @_;
	my @u;
	push @u, CAA_BASE . "/release/$rel->{id}/front-500" if $rel->{id} && ($rel->{has_cover} // 1);
	push @u, CAA_BASE . "/release-group/$rel->{release_group_id}/front-500" if $rel->{release_group_id};
	return @u;
}

sub _credit {
	my ($c) = @_;
	return '' unless ref $c eq 'ARRAY';
	return join('', map { ref $_ eq 'HASH' ? (($_->{name} // ($_->{artist} || {})->{name} // '') . ($_->{joinphrase} // '')) : '' } @$c);
}

sub _decode { my ($j) = @_; return ref $j ? $j : eval { JSON::PP->new->utf8->decode($j) } }

# "2×12\" Vinyl" iz liste medija
sub _formats {
	my (@media) = @_;
	my (%n, @order);
	for my $m (@media) {
		my $f = $m->{format} // '?';
		push @order, $f unless $n{$f}++;
	}
	return join(' + ', map { ($n{$_} > 1 ? "$n{$_}×" : '') . $_ } @order);
}

sub parse_search {
	my ($json, $type) = @_;
	my $j = _decode($json) or return [];
	my $re = $FORMAT_RE{ $type // '' };
	my @out;
	for my $r (@{ $j->{releases} || [] }) {
		my @media = @{ $r->{media} || [] };
		my $tracks = 0;
		$tracks += ($_->{'track-count'} // 0) for @media;
		my $li = ($r->{'label-info'} || [])->[0] || {};
		my $formats = _formats(@media);
		push @out, {
			id => $r->{id}, title => $r->{title}, artist => _credit($r->{'artist-credit'}), date => $r->{date} // '',
			country => $r->{country} // '', label => ($li->{label} || {})->{name} // '', catno => $li->{'catalog-number'} // '',
			formats => $formats, media => scalar @media, tracks => $tracks, score => $r->{score} // 0,
			match => ($re && $formats =~ $re) ? 1 : 0,
		};
	}
	return [ sort { $b->{match} <=> $a->{match} || $b->{score} <=> $a->{score} || ($a->{date} cmp $b->{date}) } @out ];
}

sub parse_release {
	my ($json) = @_;
	my $j = _decode($json) or return undef;
	return undef unless $j->{id};
	my $rg = $j->{'release-group'} || {};
	my $date = $j->{date} || $rg->{'first-release-date'} || '';
	my ($year) = $date =~ /^(\d{4})/;
	my ($orig) = ($rg->{'first-release-date'} // '') =~ /^(\d{4})/;
	my $artist = _credit($j->{'artist-credit'});
	my @media;
	for my $m (@{ $j->{media} || [] }) {
		push @media, {
			format => $m->{format} // '', position => $m->{position} // 0,
			tracks => [ map { {
				number => $_->{number} // $_->{position}, title => $_->{title} // ($_->{recording} || {})->{title},
				artist => _credit($_->{'artist-credit'} || ($_->{recording} || {})->{'artist-credit'}),
				length => defined($_->{length} // ($_->{recording} || {})->{length}) ? ($_->{length} // $_->{recording}{length}) / 1000 : undef,
				recording_id => ($_->{recording} || {})->{id},
			} } @{ $m->{tracks} || [] } ],
		};
	}
	my $first = ($j->{'artist-credit'} || [])->[0] || {};
	return {
		id => $j->{id}, release_group_id => $rg->{id}, artist => $artist, album => $j->{title}, year => $year, original_year => $orig // $year,
		compilation => (($first->{artist} || {})->{id} // '') eq VARIOUS ? 1 : 0,
		has_cover => ($j->{'cover-art-archive'} || {})->{front} ? 1 : 0,
		media => \@media,
	};
}

# Strane po oznakama pozicija (A1, B2, ... ili A, B kod singlova); bez oznaka: jedna lista po mediju.
sub sides {
	my ($rel) = @_;
	my @all = map { @{ $_->{tracks} } } @{ $rel->{media} || [] };
	my $lettered = @all && !grep { ($_->{number} // '') !~ /\A([A-Za-z])\d*\z/ } @all;
	if ($lettered) {
		my (@out, %idx);
		for my $t (@all) {
			my ($s) = uc($t->{number}) =~ /\A([A-Z])/;
			unless (exists $idx{$s}) { $idx{$s} = @out; push @out, { name => $s, tracks => [] } }
			push @{ $out[ $idx{$s} ]{tracks} }, $t;
		}
		return \@out;
	}
	return [ map { { name => undef, tracks => [ @{ $_->{tracks} } ] } } @{ $rel->{media} || [] } ];
}

# Pesme za delove snimka. Izdanje sa oznakama strana: deo A dobija stranu A itd.
# Bez oznaka: pesme redom; svaki deo dobija onoliko narednih pesama koliko najbolje odgovara trajanju
# muzike u njegovom snimku (poslednji deo dobija sve preostale).
sub assign {
	my ($rel, $parts) = @_;
	my $sides = sides($rel);
	my %out;
	if (@$sides && defined $sides->[0]{name}) {
		my %by = map { $_->{name} => $_->{tracks} } @$sides;
		for my $p (@$parts) { $out{ $p->{name} } = $by{ uc $p->{name} } if $by{ uc $p->{name} } }
		return \%out;
	}
	my @queue = map { @{ $_->{tracks} } } @$sides;
	for my $i (0 .. $#$parts) {
		my $p = $parts->[$i];
		last unless @queue;
		if ($i == $#$parts || !$p->{seconds}) { $out{ $p->{name} } = [ splice(@queue, 0, $i == $#$parts ? scalar @queue : 1) ]; next }
		my ($best, $bd, $sum) = (1, undef, 0);
		for my $k (1 .. scalar @queue) {
			$sum += $queue[ $k - 1 ]{length} // 0;
			my $d = abs($sum - $p->{seconds});
			($best, $bd) = ($k, $d) if !defined $bd || $d < $bd;
		}
		$out{ $p->{name} } = [ splice(@queue, 0, $best) ];
	}
	return \%out;
}

1;
