# AudioIn (Audio ulaz) – dizajn

Datum: 2026-11-19. Status: predlog dizajna, čeka pregled korisnika. Kod još ne postoji.

## 1. Cilj i obim

Lyrion (LMS 9.1.x) plugin **AudioIn** (`Plugins::AudioIn`, u UI-ju „Audio ulaz“) za **analogni izvor**
priključen na linijski ulaz AD konvertora (USB zvučna kartica, Class Compliant): gramofon preko phono
pretpojačala, kasetofon, tjuner, instrument… Izvorom se ne može upravljati, pa plugin upravlja
**zvukom sa ulaza**:

1. **Slušanje** zvuka sa ulaza na bilo kom Lyrion plejeru, sa pravom pauzom (timeshift).
2. **Snimanje** (strana ploče ili kasete, emisija, svirka) u jedan fajl, sa **markerima** za pesme
   postavljenim tokom snimanja.
3. **Uređivanje i sečenje** posle snimanja: automatski predlog granica pesama, ručna korekcija,
   izbor pesama koje se čuvaju, metapodaci sa interneta, izvoz u FLAC (jedna pesma = jedan fajl).

Ciljni sistem je Audio$OS (Debian 13 trixie, Perl 5.40, read-only root). Razvoj na razvojnom serveru
(Ubuntu 24.04, LMS 9.1.1, Material Skin), isti kao za AudioCD. Arhitektura i konvencije su preuzete iz
AudioCD-a (pomoćni proces za hardver, `Jobs.pm`, `Naming.pm`, `Library.pm`, Material most, `strings.txt` EN/SR).

### Odluke korisnika

| Pitanje | Odluka |
|---|---|
| Izvori | **bilo koji analogni izvor** na linijskom ulazu AD kartice: gramofon (preko phono pretpojačala; RIAA nije posao plugina), kasetofon, tjuner, instrument… Plugin nije vezan za gramofon |
| Upravljanje izvorom | nemoguće; plugin upravlja samo tokom zvuka sa ulaza |
| Način snimanja | ceo snimak (strana ploče/kasete, emisija…) u jedan fajl + markeri; sečenje i izbor pesama naknadno |
| Format | FLAC, podrazumevano **24 bit / 96 kHz** (druge rezolucije po izboru) |
| Ista kartica kao DAC | **da**, ako kartica ima i AD i DA; dizajn to mora podržati (odeljak 2) |
| Folder za snimke | `AudioIn-Rips` (ime prati ime plugina, kao `CD-Rips`) |
| Naziv foldera albuma | sa oznakom rezolucije, bez vrste izvora: `<Album> (<godina>) [24-96]` |
| Platforma | samo Linux (kao AudioCD) |
| Hardver | kartica još nije kupljena: razvoj i testovi idu bez nje (odeljak 12) |
| Ime | **AudioIn** (`Plugins::AudioIn`, UI „Audio ulaz"); folder `AudioIn-Rips` |

### Van obima (prva verzija)
- Obrada zvuka: uklanjanje klikova, smanjenje šuma, ekvalizacija, normalizacija. Snimak je bit-identičan
  onome što daje AD konvertor (rez je na granici uzorka, bez ponovnog kodiranja sa gubicima).
- Više ulaza istovremeno (jedan uređaj i jedan stereo par).
- Upravljanje pojačanjem kartice (gain se podešava dugmetom na kartici; plugin daje merač nivoa).
- Windows.

## 2. Ograničenja

- Čist Perl i moduli koje LMS nosi, bez CPAN XS modula. Perl 5.38 i 5.40.
- Spoljni alati (Debian trixie): `arecord` (`alsa-utils`), `flac`, `metaflac`, `curl` (samo za notify,
  opciono). Bez `sox`/`ffmpeg` u prvoj verziji.
- **Snimanje ne sme da izgubi uzorke.** Hvatanje zvuka nije RT, ali ni `nice 10` kao kod ripa:
  `arecord` radi sa `nice 0`, velikim ALSA baferom (2 s), van `audio.slice`. Kodiranje, analiza i izvoz
  idu sa `nice -n 10 ionice -c3` (kroz `Jobs::low_prio`).
- **Kartica je ekskluzivna dok je ulaz otvoren** (`hw:` uređaj). Ulaz se otvara samo kad treba
  (slušanje, snimanje, merač) i zatvara posle neaktivnosti (podrazumevano 10 min).
- **Ista kartica kao ulaz i DAC (podržan slučaj)**: mnoge USB kartice (MOTU M2, Scarlett…) imaju jedan
  takt za AD i DA, pa ulaz i izlaz moraju raditi na istoj frekvenciji. Pravila:
  - ulaz je otvoren samo dok traje slušanje, snimanje ili merač; inače je zatvoren i lokalni plejer
    svira bit-perfect na izvornoj frekvenciji svakog fajla;
  - slušanje izvora na istoj kartici je uvek na frekvenciji ulaza (96 kHz), pa sukoba nema;
  - sukob postoji samo kad je ulaz otvoren (npr. snimanje) a lokalni plejer pusti fajl druge frekvencije.
    Tada plugin **ne prekida snimanje**: plejer dobija grešku, a stranica i plejer poruku
    „ulaz je otvoren na 96 kHz". Opcija za kasnije: plugin tokom snimanja privremeno uključi
    resamplovanje lokalnog plejera na frekvenciju ulaza;
  - za slušanje bez kašnjenja tokom snimanja preporuka je **direct monitor** na samoj kartici
    (dugme/prekidač na MOTU, Scarlett, Audient…): zvuk ide pravo sa ulaza na izlaz kartice, bez LMS-a;
  - u podešavanjima se označi da je kartica ujedno izlaz lokalnog plejera (automatski predlog: isto ime
    kartice u `squeezelite -o`), da bi poruke bile tačne.
  Kartice sa nezavisnim taktovima i posebni DAC nemaju ova ograničenja.
- Putanje nisu zakucane (lanac kao kod AudioCD-a): podešavanje → `AUDIOIN_RIPS_DIR` iz
  `/etc/audioos/audioos.conf` → `/usr/local/lib/audioos/defaults.conf` →
  `/var/lib/squeezeboxserver/AudioIn-Rips`.

## 3. Arhitektura

```
 izvor (gramofon+phono pretpoj., kasetofon, tjuner…) → AD kartica (USB)
                                     │ ALSA hw:CARD=<id>
                                     ▼
            arecord (nice 0, raw PCM na stdout, bafer 2 s)
                                     │
                                     ▼
 ┌──────────────── audioin-capture (pomoćni proces, dete LMS-a) ────────────────┐
 │  prsten (timeshift) u RAM-u/na disku   ── merač nivoa (peak/RMS na 100 ms)     │
 │        │                    │                                                  │
 │        │ čitači (tap)       └── snimač: PCM → flac (nice 10) → <take>.flac     │
 │        ▼                                  + <take>.peaks + <take>.json         │
 │  unix socket /run/audioin/tap.sock                                           │
 └───────────────────────────────▲────────────────────────────────────────────────┘
        stdin/stdout JSON linije │ (komande / događaji, kao audiocd-drive)
                                 │
 Plugin.pm ── CaptureClient.pm ──┘
   ├── ProtocolHandler.pm (audioin://live) + custom-convert.conf (tap | flac/pcm)
   ├── Session.pm   (album: vrsta izvora, delovi, snimci, markeri, metapodaci; JSON na disku)
   ├── Analyze.pm   (detekcija tišine iz .peaks, predlog granica, poravnanje sa trajanjima)
   ├── Export.pm    (sečenje: flac --skip/--until, tagovi, omot) ── Jobs.pm
   ├── Metadata/    (MusicBrainz pretraga po tekstu, Discogs opciono, Cover Art Archive)
   ├── Naming.pm, Library.pm, Config.pm, Jobs.pm   (preuzeto iz AudioCD-a)
   ├── Web.pm + HTML (stranica: kontrole, merač, editor talasnog oblika)
   ├── Menu.pm (stavka sa imenom plugina za aplikacije), MaterialBridge.pm
   └── Settings.pm
```

Čiste jedinice bez LMS-a (testiraju se same): prsten i čitači, parser `arecord` poruka, merač,
`Analyze`, proračun preseka (uzorci ↔ vreme), argumenti `flac`/`arecord`, `Session` (de)serijalizacija,
`Naming`, `Config`, MusicBrainz parsiranje.

### Zašto poseban proces
Isto kao `audiocd-drive`: LMS je jednonitni event loop. Čitanje 576 KB/s (24/96) bez prekida, prsten,
merač i snimač moraju raditi i kad je LMS zauzet (skeniranje, spor HTTP). Ako LMS padne, EOF na stdin-u
gasi pomoćnika, a otvoren snimak se pravilno zatvara (FLAC je ispravan do poslednjeg bloka).

## 4. Hvatanje zvuka (`audioin-capture`)

### Uređaj i format
- Uređaj se bira po **imenu kartice**, ne indeksu: `hw:CARD=<id>,DEV=0` (USB indeks se menja posle
  restarta). Lista iz `/proc/asound/cards` + `arecord -l`.
- Podržani formati i frekvencije: `arecord -D <dev> --dump-hw-params` (parsira se). Ponuda u
  podešavanjima samo onoga što kartica stvarno podržava: 44.1/48/88.2/96/176.4/192 kHz, S24_3LE /
  S32_LE / S16_LE. Interno se sve čuva kao 24 bit (S32_LE sa 24 značajna bita se skraćuje bez gubitka;
  provera da li su donji bitovi stvarno nula se loguje).
- Podrazumevano: 24 bit / 96 kHz. 192 kHz je dostupno, ali UI upozorava na veličinu fajlova.
- **Kanali**: kartica može davati više od 2 kanala hvatanja (npr. 4 ulaza). `--dump-hw-params` daje broj
  kanala; u podešavanjima se bira stereo par (1-2, 3-4…) ili mono ulaz udvojen u oba kanala (gitara,
  mikrofon). Hvata se onoliko kanala koliko uređaj traži, a pomoćni proces zadržava samo izabrani par.
  Neke kartice daju parove kao **posebne ALSA uređaje** (Lexicon Omega: `hw:CARD=Omega,DEV=0` i `DEV=1`,
  svaki 2 kanala): izbor ulaza je tada izbor uređaja, pa lista u podešavanjima prikazuje „kartica / uređaj / par“.
- Komanda: `arecord -D <dev> -f <fmt> -r <rate> -c <kanala> -t raw --buffer-time=2000000 -q`.
  `stderr` se čita: poruke `overrun!!!` postaju događaji `xrun` sa pozicijom u uzorcima.

### Vremenska osa
Sve pozicije su **broj uzorka (frame) od otvaranja ulaza** (64-bit). Snimci, markeri, čitači i merač
koriste istu osu, pa nema zaokruživanja na sekunde. Pri svakom xrun-u ili ponovnom otvaranju uređaja
počinje nova osa (novi `epoch`), a snimak u toku dobija oznaku prekida na tom mestu.

### Prsten (timeshift)
- Kružni bafer sirovog PCM-a. Veličina u minutima (podrazumevano 10 min; 24/96 ≈ 345 MB).
- Lokacija: `/run/audioin` (tmpfs) ako ima mesta, inače `/dev/shm`, inače LMS cache na disku
  (isti algoritam izbora kao Play keš AudioCD-a). Na disku se koristi jedan unapred alociran fajl.
- Služi za: pauzu slušanja, **pred-snimanje** (snimak može početi i do 30 s pre pritiska na „Snimaj",
  podrazumevano 5 s, da se ne propusti spuštanje igle) i čitače koji kasne.

### Merač nivoa
Na svakih 100 ms: peak i RMS po kanalu (dBFS), broj uzoraka na punoj skali (clipping) i `peak hold`
3 s. Šalje se samo dok neko gleda (stranica traži merač; isključuje se posle 30 s bez zahteva).
Na stranici: dve trake, oznake −6 i −1 dBFS, crveno upozorenje i brojač klipovanja za snimak u toku.

### Protokol (JSON linija, kao `audiocd-drive`)
```
stdin:  {"cmd":"open","dev":..,"rate":..,"fmt":..,"ring_min":..}  {"cmd":"close"}
        {"cmd":"meter","on":1}
        {"cmd":"rec_start","id":..,"path":..,"preroll_s":..}  {"cmd":"rec_pause"}  {"cmd":"rec_resume"}
        {"cmd":"rec_stop"}  {"cmd":"marker","id":..,"pos":N|null}
        {"cmd":"status"}  {"cmd":"quit"}
stdout: {"ev":"opened","epoch":..,"rate":..,"fmt":..}  {"ev":"closed","err":..}
        {"ev":"meter","pos":N,"pk":[..],"rms":[..],"clip":N}
        {"ev":"rec","state":"rec|paused|stopped","id":..,"frames":N}
        {"ev":"xrun","pos":N}  {"ev":"device_lost"}  {"ev":"error","err":..}
```
Čitači (tap-ovi) ne idu kroz ovaj kanal nego kroz unix socket (sledeći odeljak).

## 5. Slušanje (`audioin://live`)

### Put zvuka
- Plejlista dobija jednu stavku `audioin://live`. `ProtocolHandler.pm` je registruje kao poseban
  format `ain` (sirov PCM sa ulaza, poznata frekvencija/bitovi).
- `custom-convert.conf` u pluginu definiše pretvaranja (LMS bira prema plejeru):
  ```
  ain flc * *   [audioin-tap] $FILE$ | [flac] -cs --totally-silent -0 --endian=little --sign=signed --channels=2 --bps=24 --sample-rate=$SAMPLERATE$ -
  ain pcm * *   [audioin-tap] $FILE$
  ```
  `audioin-tap` (Perl skripta u `Bin/` plugina) se poveže na `/run/audioin/tap.sock`, pošalje
  poziciju početka i ispisuje PCM na stdout. Squeezelite dobija FLAC bez gubitaka; UPnPBridge PCM/WAV
  po svojim pravilima. Bez resamplovanja: plejer koji ne podržava frekvenciju ulaza dobija LMS-ovo
  standardno pretvaranje (ili se snima/sluša na 48/96 kHz).
- **Proveriti u fazi 0** (LMS izvor na serveru): da li LMS učitava `custom-convert.conf` i `Bin/` iz
  foldera plugina za ovaj slučaj (WaveInput plugin to radi na isti način) i kako se `$SAMPLERATE$`
  prosleđuje za remote stavku. Rezerva ako ne radi: pomoćni proces daje HTTP stream na
  `127.0.0.1:<port>/live.flac`, a handler nasleđuje `Slim::Player::Protocols::HTTP`.

### Pauza = timeshift
- Pauza na plejeru (iz bilo koje aplikacije) zaustavlja čitanje iz cevi; `audioin-tap` se blokira
  na pisanju, a njegova pozicija u prstenu stoji. Play nastavlja tačno odakle je stalo.
- Ako zaostatak premaši prsten: čitač skače na najstariji raspoloživ uzorak i stranica prikazuje
  „Pauza je bila duža od bafera (N min)".
- Dugme **„Uživo"** (stranica i meni): ponovo pokreće stavku na ivici prstena (zaostatak = početni).
- Stranica prikazuje zaostatak („−2:35 iza uživo").
- Premotavanje unazad unutar prstena (npr. −30 s) je moguće kao kasnija dopuna; u prvoj verziji ne.

### Kašnjenje i drift takta
- Čitač ne počinje na samoj ivici, nego **3 s iza uživo** (podešavanje). To pokriva razliku taktova AD
  kartice i DAC-a plejera: pri razlici od 50 ppm, 3 s rezerve traje ~16 h. Ako je AD brži, zaostatak
  polako raste (bezopasno, ograničeno prstenom).
- Ukupno kašnjenje od igle do zvučnika = 3 s + bafer plejera (obično 1–3 s). Za ploču je to prihvatljivo;
  za direktno slušanje bez kašnjenja koristi se pojačalo, a plugin samo snima.
- Metapodaci stavke: „Audio ulaz“ + naziv kartice, ili izvođač/album/omot ako je album već izabran
  u sesiji; tip `FLAC`, frekvencija/bitovi ulaza. Trajanje nepoznato (beskonačan stream).

## 6. Snimanje

### Sesija = album ili snimak
Sesija je jedna celina koja postaje jedan album: metapodaci, omot, **vrsta izvora** i lista **delova**.
Svaki deo ima jedan ili više **snimaka** (take); snimak je jedan neprekinut FLAC fajl.

| Vrsta izvora | Delovi | MEDIA tag | Pretraga metapodataka |
|---|---|---|---|
| Ploča | strane A, B, C… | `12" Vinyl` (7"/10" po izboru) | MusicBrainz, format Vinyl |
| Kaseta | strane A, B | `Cassette` | MusicBrainz, format Cassette |
| Tjuner / radio | jedan deo (emisija) | `Radio` | ne (ručni unos) |
| Uživo / instrument | jedan ili više delova (setovi) | — | ne (ručni unos) |
| Ostalo | slobodni nazivi delova | po izboru | MusicBrainz bez filtra formata |

Vrsta izvora menja samo podrazumevane vrednosti (nazivi delova, tag, filtar pretrage); tok snimanja,
analiza i izvoz su isti za sve. Podešavanje „podrazumevana vrsta izvora" (npr. Ploča).
Sesija se čuva u `AudioIn-Rips/.sessions/<sesija>/session.json`, snimci pored nje (isti fajl sistem kao
izvoz, pa je premeštanje `rename`).

### Kontrole
| Dugme | Šta radi |
|---|---|
| **Snimaj** | nov snimak za izabranu stranu; počinje `preroll` sekundi pre pritiska (iz prstena) |
| **Pauza / Nastavi** | prestaje/nastavlja upis u isti fajl; ono što svira tokom pauze se ne upisuje; mesto spoja postaje marker tipa `pause` (podrazumevano granica pesme) |
| **Marker** („Nova pesma") | dodaje granicu pesme na trenutno mesto (vidi kompenzaciju dole); snimanje ide dalje bez prekida |
| **Stop** | zatvara snimak; deo prelazi u stanje „za uređivanje" i pokreće se analiza |
| **Sledeći deo** | Stop + izbor sledećeg dela (strana A → B …), jedan klik dok se ploča ili kaseta okreće |

Originalna ideja korisnika („split" bez pauze u nov fajl) ostaje kao dugme **Marker**: granica je
tačna na uzorak i bez gubitka, a fizičko sečenje ide na izvozu, kad se granica može i proveriti.

### Kompenzacija kašnjenja za marker
Korisnik pritiska Marker kad **čuje** početak pesme, a to je 4–6 s posle igle (odeljak 5):
- ako se sluša preko Lyrion plejera: `pozicija = početak_čitača + odsvirano_na_plejeru × rate`
  (LMS zna `songElapsedSeconds` za `audioin://live`), tačnost oko 0,1–0,3 s;
- ako se sluša direktno preko pojačala: `pozicija = sada − reakcija` (podešavanje, podrazumevano 0,5 s).
Analiza (odeljak 7) svaki ručni marker pomera na najbližu pauzu u krugu ±8 s, ako takva postoji.

### Upis
- PCM iz prstena → `flac -5 --force-raw-format … -o <take>.flac.part -` (nice 10). Izlaz je fajl, pa
  `flac` na kraju upisuje STREAMINFO (trajanje, MD5). Preimenovanje u `.flac` posle Stop-a.
- Uporedo se pišu `<take>.peaks` (min/max/RMS po 10 ms, binarno, ~15 KB po minutu) i `<take>.json`
  (markeri, xrun-ovi, klipovanje, epoch, početni uzorak).
- Prekid (LMS restart, nestanak kartice): `flac` dobija EOF i zatvara fajl; snimak ostaje
  upotrebljiv do mesta prekida, sa oznakom „prekinut".
- Pre početka: provera slobodnog mesta za procenjenu dužinu dela (podrazumevano 30 min;
  24/96 FLAC ≈ 1,3 GB/h). Tokom snimanja upozorenje ispod 1 GB, Stop ispod 200 MB.
- Nema automatskog početka ni kraja u prvoj verziji. Kasnije: automatski Stop posle N sekundi
  tišine/zvuka izlaznog žleba (run-out groove).

## 7. Analiza i uređivanje

### Automatski predlog granica (`Analyze.pm`)
Iz `.peaks` (10 ms prozori):
1. **Pod šuma**: medijan RMS-a u prvih 2–4 s posle početka snimka (kod ploče uvodni žleb, kod kasete uvodna traka) i na kraju; prag tišine
   = pod šuma + 6 dB (podesivo), ali ne više od −45 dBFS.
2. **Pauze**: neprekidan niz prozora ispod praga dužine ≥ 1,0 s (podesivo); pojedinačni klikovi
   (kratki skokovi < 30 ms) se ignorišu.
3. **Početak i kraj muzike**: prvi i poslednji prozor iznad praga + 1 s.
4. **Granica** u pauzi: 0,5 s pre početka sledeće pesme (prethodna pesma zadržava fade-out i deo tišine);
   podesivo: „sredina pauze".
5. **Poravnanje sa metapodacima**: ako je izabrano izdanje sa trajanjima pesama za tu stranu, granice
   se biraju tako da trajanja najbolje odgovaraju (dinamičko programiranje nad kandidat-pauzama). Tiho
   prelaženje pesama (live albumi, miks) tako dobija granicu i bez pauze, sa oznakom „procena".
6. Ručni markeri iz snimanja imaju prednost; analiza ih samo pomera na pauzu u krugu ±8 s.

### Editor (stranica)
- Talasni oblik celog dela (iz `.peaks`), zum, markeri koji se prevlače, prikaz praga tišine.
- Lista pesama: pozicija (A1, A2…), početak, trajanje, naslov, **„Sačuvaj" (štiklirano)**. Pesma bez
  štikle se ne izvozi – to je zamena za „pauzom preskoči pesmu" iz originalne ideje.
- „Slušaj od markera": pušta snimak na izabranom plejeru od 3 s pre granice (snimak je običan FLAC,
  plejlista `file://` sa seek-om), da se granica proveri na uvo.
- Skraćivanje početka (spuštanje igle, uvodna traka) i kraja (izlazni žleb, šum trake) se vidi kao prva/poslednja granica.
- Upozorenja na pesmi: klipovanje, xrun u opsegu pesme, granica „procena".

## 8. Metapodaci

- **MusicBrainz pretraga po tekstu** (izvođač + album, opciono kataloški broj/barkod):
  `GET /ws/2/release?query=…&fmt=json`, filtar formata po vrsti izvora (`Vinyl` 12"/7"/10", `Cassette`; bez filtra za „Ostalo"), pa
  `GET /ws/2/release/<mbid>?inc=recordings+artist-credits+release-groups+media`. MusicBrainz daje
  strane ploče i kasete kao pozicije `A1`, `B2`… i trajanja, što hrani poravnanje (odeljak 7).
  User-Agent `AudioIn/<verzija> ( <repo URL> )` i najviše 1 zahtev/s, kao AudioCD.
- **Omot**: Cover Art Archive (`front-500`, rezerva release-group), ili ručno učitana slika.
- **Discogs** (opciono): pretraga traži lični token (podešavanje). Bez tokena se ne koristi.
- Ručni unos uvek moguć (izvođač, album, godina, pesme po delovima).
- Metapodaci se mogu izabrati pre, tokom ili posle snimanja; tokom slušanja se prikazuju na plejeru.

## 9. Izvoz

- Za svaku štikliranu pesmu: `flac -d -c --skip=<uzorak> --until=<uzorak> <take>.flac | flac -<nivo> … -o <pesma>.flac`
  sa tagovima. Rez je tačan na uzorak, audio je bit-identičan izvoru. (Varijanta bez dekodiranja nije
  moguća jer FLAC blokovi ne prate granice pesama.)
- Pesma koja prelazi preko pauze snimanja (marker `pause`) se izvozi kao spoj oba dela.
- Nazivi (`Naming.pm` iz AudioCD-a): `AudioIn-Rips/<Izvođač>/<Album> (<godina>) [24-96]/NN - <Naslov>.flac`
  (oznaka u zagradi podesiva/isključiva). Postojeći folder → ` (2)`.
- Tagovi: TITLE, ARTIST, ALBUM, ALBUMARTIST, TRACKNUMBER, TRACKTOTAL, DATE, MEDIA (po vrsti izvora, odeljak 6),
  DISCNUMBER/DISCTOTAL za više ploča/kaseta, MusicBrainz ID-jevi, pozicija na strani (A1…) kad postoji. Oznaka rezolucije u nazivu foldera je podesiva (podrazumevano uključena).
  Opciono ReplayGain (`metaflac --add-replay-gain`, samo ako su sve pesme iste frekvencije).
- Uz fajlove: `cover.jpg`, `<Album>.log` (uređaj, format, datum, nivo pika, klipovanje, xrun-ovi,
  granice u uzorcima).
- Posle izvoza: „Premesti u biblioteku" + skeniranje foldera (`Library.pm`), isto kao AudioCD.
- Snimci delova se čuvaju dok ih korisnik ne obriše (podešavanje: obriši posle uspešnog izvoza – isključeno),
  da se može ponovo iseći.

## 10. Korisnički interfejs

- **Stranica** `/plugins/AudioIn/index.html` (statični HTML + JS, JSON-RPC `["audioin", …]`):
  - zaglavlje: kartica, format, stanje ulaza, merač nivoa;
  - slušanje: plejer, Slušaj / Uživo / Stop, zaostatak;
  - snimanje: sesija (album, vrsta izvora), deo, Snimaj / Pauza / Marker / Stop / Sledeći deo, vreme, veličina,
    klipovanje, broj markera;
  - lista sesija i delova sa stanjem (snima se / za uređivanje / izvezeno), editor (odeljak 7),
    izvoz i napredak, istorija.
  - Komande: `status`, `open`, `close`, `listen`, `live`, `rec_start`, `rec_pause`, `rec_resume`,
    `rec_stop`, `marker`, `session_new`, `session_edit`, `lookup`, `select_release`, `analyze`,
    `markers_set`, `export`, `cancel`, `move`, `delete_take`, `history`.
  - Osvežavanje: merač preko kratkog polling-a (250 ms dok je stranica vidljiva), ostalo 1–2 s dok
    se snima, inače 10 s.
- **Meni** sa imenom plugina (My Music/Extras, za aplikacije i Material): Slušaj, Uživo, Snimaj, Marker,
  Pauza snimanja, Stop snimanja. Snimanje i marker su tako dostupni i sa telefona bez stranice.
- **Material**: `MaterialBridge.pm` (kao AudioCD) – stavka koja otvara stranicu u dijalogu.
- **Podešavanja**: uređaj (lista kartica), frekvencija i bitovi (samo podržani), veličina prstena,
  pred-snimanje, zaostatak čitača, reakcija za marker, prag i min. trajanje pauze, položaj granice,
  folder za snimke i za biblioteku, FLAC nivo, oznaka rezolucije u nazivu foldera, ReplayGain,
  Discogs token, zatvaranje ulaza posle neaktivnosti.
- Tekstovi EN i SR (`strings.txt`).

## 11. Greške

| Situacija | Ponašanje |
|---|---|
| Kartica nije priključena | stanje „nema uređaja", ponovni pokušaj na 5 s, poruka sa imenom kartice |
| Uređaj zauzet (drugi program, squeezelite na istoj kartici) | poruka ko drži uređaj (`/proc/asound/card*/pcm*c/sub0/status`, `fuser`) |
| Frekvencija nije podržana / sukob sa izlazom na istoj kartici | poruka sa podržanim frekvencijama |
| Nema prava | uputstvo: `squeezeboxserver` u grupi `audio` |
| xrun (izgubljeni uzorci) | oznaka u snimku i na pesmi, upozorenje u logu; snimanje se nastavlja |
| Kartica nestane tokom snimanja | snimak se zatvori kao „prekinut", ulaz čeka karticu |
| Klipovanje | brojač i upozorenje uživo; posle snimka označene pesme |
| Nema mesta | provera pre početka i tokom snimanja (odeljak 6) |
| Prsten prekoračen tokom pauze | čitač skače na najstariji uzorak, poruka |
| Nema interneta | ručni unos metapodataka, „Pokušaj ponovo" |

## 12. Razvoj i testovi bez kartice

Kartica još ne postoji, pa ceo lanac mora da se razvije i proveri bez nje:

1. **Izvor iz fajla**: `audioin-capture --source <fajl.flac|wav> --realtime` čita fajl umesto
   `arecord`, istim tempom kao pravi ulaz. Sve iznad `arecord`-a (prsten, merač, snimač, tap, slušanje,
   markeri, analiza, izvoz) testira se ovako.
2. **ALSA loopback** (`snd-aloop`) na razvojnom serveru, ako je dostupan `modprobe` (traži root, jednom):
   `aplay` pušta fajl u `hw:Loopback,0`, plugin snima sa `hw:Loopback,1`. Tako se proverava i pravi
   put kroz `arecord`, `--dump-hw-params`, xrun i nestanak uređaja.
3. **Sintetička ploča** (generator u `tools/`, čuva se u `tests/fixtures/` u kratkom obliku): pesme
   (ton/šum sa ovojnicom), pauze 1–4 s, šum površine (−55 do −60 dBFS ružičasti šum), klikovi, uvodni i
   izlazni žleb, jedan tihi prelaz bez pauze. Poznate granice → test tačnosti `Analyze` (±50 ms).
4. **Lexicon Omega** (korisnik je ima): prava kartica za razvoj, priključena na Audio$OS, prepoznata bez drajvera (USB 1.1 full speed):
   hvatanje i reprodukcija na dva stereo uređaja (DEV 0 i 1), S16_LE ili S24_3LE, samo 44.1/48 kHz,
   ujedno i DA. Na njoj se proverava ceo put kroz `arecord`, izbor kanala, merač, xrun, izvlačenje
   USB kabla i slučaj „ista kartica kao ulaz i DAC“. 96 kHz se proverava izvorom iz fajla i loopback-om.
5. **Pravi snimci** ploče, ako ih korisnik ima (bilo koji postojeći vinyl rip), za proveru praga tišine.

Perl testovi (`prove`, bez LMS-a): prsten (prelivanje, više čitača, zaostatak), parser
`--dump-hw-params` i `arecord` poruka, merač (poznati signali → dBFS), proračun pozicija i kompenzacije,
`Analyze` (sintetička ploča, poravnanje sa trajanjima), argumenti `flac` za izvoz (tačni `--skip/--until`),
spoj preko pauze, `Session` JSON, `Naming`, MusicBrainz fixture-i (vinyl izdanje sa stranama A/B,
dupli LP).

Kad kartica stigne: provera nivoa i pod šuma, xrun pod opterećenjem (skeniranje biblioteke + izvoz tokom
snimanja), drift (slušanje 2 h bez prekida), sukob ulaz/izlaz ako je ista kartica i DAC.

## 13. Faze

| Faza | Sadržaj | Treba kartica? |
|---|---|---|
| 0 | Provera LMS mehanizma (convert + `Bin/` iz plugina, remote stavka sa beskonačnim trajanjem, pauza na cevi); prototip `ain` → squeezelite iz fajla | ne |
| 1 | `audioin-capture` (izvor iz fajla), prsten, tap, slušanje sa timeshift-om, stranica sa kontrolama | ne |
| 2 | Snimanje (deo, pauza, marker, pred-snimanje), `.peaks`, sesije | ne |
| 3 | Analiza i editor, izvoz, nazivi, tagovi, biblioteka | ne |
| 4 | Metapodaci (MusicBrainz, CAA, Discogs), poravnanje sa trajanjima | ne |
| 5 | `arecord` + loopback, izbor uređaja/formata, merač, greške uređaja | loopback |
| 6 | Prava kartica: nivo, xrun, drift, `INTEGRATION.md` za Audio$OS, release | **da** |

## 14. Isporuka

- Poseban repo (kao `lyrion-cd-plugin`): `src/AudioIn/` (plugin, `Bin/audioin-tap`,
  `custom-convert.conf`), `tests/perl/`, `tools/` (test, deploy, generator sintetičke ploče),
  `packaging/`, README sr/en.
- `INTEGRATION.md` za Audio$OS: paketi (`alsa-utils`, `flac`), grupa `audio` za `squeezeboxserver`,
  tmpfiles (`/run/audioin`), `AUDIOIN_RIPS_DIR`, napomena o istoj kartici kao ulaz i DAC, prioriteti
  procesa, rezultati merenja.

## 15. Otvorena pitanja za korisnika

Nema otvorenih pitanja. Ime je izabrano (AudioIn), odluke su u odeljku 1.
