# AudioIn (Audio ulaz) za Lyrion

Plugin za Lyrion Music Server koji sluša i snima analogni izvor priključen na zvučnu karticu servera:
gramofon (preko phono pretpojačala), kasetofon, tjuner, instrument. Snimljenu stranu deli na pesme i
izvozi ih kao FLAC sa nazivima, omotom i tagovima.

## Šta radi

- **Slušanje na bilo kom plejeru** (Slušaj). Pauza na plejeru je prava pauza: Play nastavlja tačno gde je
  stalo (dok traje bafer, podrazumevano 10 minuta). „Uživo“ vraća na trenutni zvuk sa ulaza.
- **Snimanje** cele strane u jedan fajl, 24 bit (podrazumevano 96 kHz), sa pred-snimanjem od 5 sekundi da
  se ne propusti spuštanje igle. Tokom snimanja: **Nova pesma (marker)**, Pauza, Stop, Sledeća strana.
  Marker se postavlja po onome što **čuješ** na plejeru, ne po trenutku pritiska.
- **Podela na pesme**: posle snimanja plugin sam predlaže granice po tišini između pesama (klikovi i tihi
  delovi pesama ne seku pesmu). U editoru se granice vide na talasnom obliku, pomeraju se prevlačenjem,
  pesme se spajaju ili isključuju, a ▶ pušta snimak od granice da se proveri na uvo.
- **MusicBrainz**: pretraga albuma (vinil izdanja prva), nazivi pesama, strane (A1, B2…), trajanja (granice
  se poravnaju sa njima) i omot.
- **Izvoz** u `<Izvođač>/<Album> (godina) [24-96]/NN - Naslov.flac`, isečeno tačno na uzorak, bez promene
  zvuka, sa tagovima i ugrađenim omotom.
- **Premeštanje u biblioteku**: biraš glavni muzički folder, folder izvođača (postojeći ili nov) i naziv
  foldera albuma; Lyrion skenira samo taj folder.
- Kontrole su i u meniju „Audio In“ u aplikacijama (Material, iPeng, Squeezer…), pa se ploča može snimati
  i markirati sa telefona. Material Skin dobija stavku na početnoj strani.

## Instalacija

Na serveru sa Lyrion-om (Debian/Ubuntu, systemd):

```
curl -fsSL https://github.com/nas963/lyrion-audioin-plugin/releases/latest/download/get.sh | sudo bash
```

Skripta preuzima paket, proverava mu otisak, instalira plugin, dodaje korisnika `squeezeboxserver` u grupu
`audio`, pravi `/run/audioin` i restartuje Lyrion. Potrebni alati (Debian paketi): `alsa-utils`, `flac`.
Ako fale, skripta ispiše komandu za instalaciju.

Zatim u **Podešavanja → Audio In** izaberi zvučnu karticu, ulaze i rezoluciju. Nude se samo ulazi i
frekvencije koje kartica stvarno ima.

## Podešavanja

| Podešavanje | Podrazumevano | Značenje |
|---|---|---|
| Izvor zvuka | Zvučna kartica | ili test fajl (za probu bez kartice) |
| Ulazni uređaj | — | kartica po imenu (`hw:CARD=…,DEV=…`) |
| Ulazi | Stereo 1-2 | stereo par ili jedan mono ulaz u oba kanala |
| Rezolucija | 96 kHz | samo ono što kartica podržava; snimci su uvek 24-bitni FLAC |
| Podrazumevana vrsta izvora | Ploča | nazivi strana/delova i MEDIA tag novih albuma |
| Pred-snimanje | 5 s | snimak počinje ovoliko pre pritiska na Snimaj |
| Kašnjenje slušanja | 3 s | plejeri počinju ovoliko iza ulaza (pokriva razliku taktova) |
| Vreme reakcije za marker | 0,5 s | kad se sluša direktno, ne preko Lyrion plejera |
| Bafer za pauzu | 10 min | koristi RAM, oko 35 MB po minutu za 24/96 |
| Zatvori ulaz posle | 10 min | neaktivnosti; zatvoren ulaz oslobađa karticu |
| Folder za snimke | `/var/lib/squeezeboxserver/AudioIn-Rips` | snimci (skriveni `.sessions`) i izvezeni albumi |

## Ista kartica kao ulaz i DAC

Mnoge USB kartice imaju jedan takt za ulaz i izlaz. Plugin drži ulaz otvoren samo dok se sluša, snima ili
gleda merač; tada lokalni plejer na istoj kartici ne može da pusti fajl druge frekvencije (snimanje se ne
prekida). Za slušanje bez kašnjenja tokom snimanja koristi „direct monitor“ na samoj kartici.

## Uklanjanje

```
curl -fsSL https://github.com/nas963/lyrion-audioin-plugin/releases/latest/download/get.sh | sudo bash -s uninstall
```

Uklanja plugin, `/etc/tmpfiles.d/audioin.conf` i AudioIn blok iz Material `custom.js` (ostatak fajla se ne
dira). Snimci i albumi (AudioIn-Rips) ostaju.
