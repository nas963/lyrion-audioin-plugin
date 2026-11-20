# AudioIn za Audio$OS: uputstvo za integraciju

Za Audio$OS sesiju. Plugin AudioIn (Lyrion/LMS 9.1.x) sluša i snima analogni izvor sa zvučne kartice servera,
deli snimak na pesme i izvozi FLAC. Ovaj fajl opisuje šta treba ugraditi u ISO, šta se očekuje od sistema i kako
se proverava. Dizajn: `docs/specs/2026-11-19-audioin-design.md`.

## 1. Paketi (Debian 13 trixie)

| Paket | Alat | Zašto |
|---|---|---|
| `alsa-utils` | `/usr/bin/arecord` | hvatanje zvuka sa kartice (pomoćni proces `audioin-capture`) |
| `flac` | `/usr/bin/flac`, `/usr/bin/metaflac` | kodiranje snimka, sečenje i izvoz pesama, tagovi i omot |

- Alati se traže redom `/usr/bin`, `/bin`, `/usr/local/bin`, pa `PATH`.
- Za slušanje LMS koristi svoj `flac` iz `Bin/` (već u paketu Lyrion-a) i `Bin/audioin-tap` iz plugina.
- Plugin ne traži nijedan XS modul iz CPAN-a ni `python3`.

## 2. Gde se plugin instalira

- `/var/lib/squeezeboxserver/Plugins/AudioIn`, vlasnik `squeezeboxserver:nogroup`, folderi 755, fajlovi 644,
  **`Bin/audioin-tap` 755** (LMS traži izvršni fajl; plugin ga pri startu sam ispravlja ako nije, ali ne na read-only
  sloju).
- Kao kod AudioCD-a: u ISO ide sadržaj `src/AudioIn/` (ili raspakovan `dist/audioin.zip`, folder `AudioIn`), u sloj
  koji se kopira na `/data`. Alternativa: `packaging/install.sh` (root).

## 3. Sistemski fajlovi

| Izvor | Odredište | Mod |
|---|---|---|
| `system/tmpfiles-audioin.conf` | `/etc/tmpfiles.d/audioin.conf` | 644 |

`d /run/audioin 0755 squeezeboxserver nogroup -`: tu je unix socket pomoćnog procesa (`tap.sock`). Bez njega plugin
koristi `/dev/shm/audioin`, pa `/tmp/audioin-<uid>`. Nema udev pravila ni systemd servisa: pomoćni proces je dete LMS-a.

## 4. Grupe i prava

- `squeezeboxserver` mora biti u grupi `audio` (`/dev/snd/*` su `root:audio` 660).
- Kartica se bira po imenu (`hw:CARD=<id>,DEV=<n>`), pa redosled USB uređaja nije bitan.

## 5. Putanje i RAM

- Folder za snimke: pref `ripsDir` → `AUDIOIN_RIPS_DIR` iz `/etc/audioos/audioos.conf` → isti ključ iz
  `/usr/local/lib/audioos/defaults.conf` → `/var/lib/squeezeboxserver/AudioIn-Rips`. Predlog za Audio$OS:
  `AUDIOIN_RIPS_DIR=/data/AudioIn-Rips` (Samba share kao `CD-Rips`). Unutra: skriveni `.sessions` (snimci strana:
  `.flac`, `.peaks`, `.json`, omot) i izvezeni albumi. Strana od 25 min na 24/96 je oko 550 MB FLAC-a.
- **Timeshift bafer je u RAM-u pomoćnog procesa**: `ringMinutes` (podrazumevano 10) × ~35 MB po minutu na 24/96
  (~17 MB/min na 48 kHz). 10 min = ~350 MB RAM dok je ulaz otvoren. Ulaz se zatvara posle `idleClose` (10 min) bez
  slušanja/snimanja, i tada se memorija oslobađa (pomoćni proces ostaje, mali).

## 6. Prioriteti procesa

| Proces | Prioritet | Zašto |
|---|---|---|
| `audioin-capture` (Perl) i `arecord` | nice 0, ionice podrazumevano | ne sme da izgubi uzorke; ALSA bafer 2 s |
| `flac` koder snimka | nice 10 | sme da kasni (ide iz bafera) |
| sečenje/izvoz, `cp` pri premeštanju | `nice -n 10 ionice -c3` | pozadinski poslovi |
| `audioin-tap` + `flac` za slušanje | kako ih pokrene LMS | isto kao bilo koje transkodovanje |

Ništa nije RT i ništa ne ide u `audio.slice`. Ako Audio$OS izoluje jezgra za DAC/squeezelite, `arecord` treba da ostane
na neizolovanim jezgrima (nasleđuje LMS-ov cgroup). Gubitak uzoraka se javlja kao `xrun` (log, stranica, oznaka u
snimku).

## 7. Ista kartica kao ulaz i DAC

Kartice sa jednim taktom (MOTU M2, Scarlett, Omega…) rade na jednoj frekvenciji za ulaz i izlaz. Dok je ulaz otvoren,
lokalni squeezelite na istoj kartici ne može da otvori drugu frekvenciju (plejer dobija grešku, snimanje se ne prekida).
Ulaz je otvoren samo dok se sluša/snima/gleda merač. Predlog za Audio$OS: kartica za snimanje odvojena od DAC-a
(npr. SMSL za reprodukciju, Omega/Scarlett za snimanje), kao što je sada.

## 8. Material Skin

Plugin pri startu dodaje svoj blok u `<prefs>/material-skin/custom.js` (između `// AudioIn start` i `// AudioIn end`),
kao AudioCD i Unified Music; tuđi blokovi se ne diraju. Uklanjanje: `packaging/uninstall.sh`.

## 9. Provera (smoke test)

```sh
cat /proc/asound/cards; arecord -l                 # kartica se vidi
id squeezeboxserver | grep -q audio && echo ok      # grupa
ls -l /var/lib/squeezeboxserver/Plugins/AudioIn/Bin/audioin-tap   # -rwxr-xr-x
curl -s -X POST -d '{"id":1,"method":"slim.request","params":["",["audioin","status"]]}' http://localhost:9000/jsonrpc.js
```

Zatim na stranici (Extras → Audio In): Otvori ulaz → merač se pomera kad izvor svira → Slušaj na plejeru → Pauza 1 min
pa Play (nastavlja gde je stao) → Snimaj 1 min, Marker, Stop → Uredi pesme → Izvezi album.

## 10. Stanje provere (2026-11-20)

- Sve funkcije su proverene na razvojnom serveru (Ubuntu 24.04, LMS 9.1.1) sa fajlom kao izvorom i sa ugrađenom HDA
  karticom (`arecord`, S32_LE, 24/96, bez xrun-a).
- Lexicon Omega na Audio$OS-u: prepoznata, `arecord` 24/48 sa oba ulaza ispravno (šum ~ -101 dBFS). Snimanje stvarnog
  izvora čeka kablove.
- Nije provereno: dugotrajno slušanje (drift taktova, više sati), kartica sa više od 2 kanala, 192 kHz.
- Poznato: LMS stream sa nepoznatim trajanjem zaustavlja posle pauze, zato `audioin://live` ima trajanje 24 h (aplikacije
  prikazuju 24:00:00).
