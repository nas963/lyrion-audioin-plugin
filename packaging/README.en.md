# AudioIn for Lyrion

A Lyrion Music Server plugin that plays and records an analog source connected to the server's sound
card: a turntable (through a phono preamp), cassette deck, tuner or instrument. It splits a recorded side
into tracks and exports them as FLAC with titles, cover art and tags.

## What it does

- **Listen on any player.** Pausing a player is a real pause: Play continues exactly where it stopped
  (within the buffer, 10 minutes by default). "Back to live" returns to the current input.
- **Record** a whole side into one file, 24-bit (96 kHz by default), with 5 seconds of pre-recording so the
  needle drop is not missed. While recording: **New track (marker)**, Pause, Stop, Next side. A marker is
  placed where you **hear** it on the player, not where the button was pressed.
- **Track splitting**: after recording the plugin suggests boundaries from the silence between tracks
  (clicks and quiet passages do not split a track). In the editor the boundaries are shown on the
  waveform and can be dragged; tracks can be joined or left out, and ▶ plays from a boundary.
- **MusicBrainz**: album search (vinyl releases first), track titles, sides (A1, B2…), track lengths (the
  boundaries are aligned to them) and cover art.
- **Export** to `<Artist>/<Album> (year) [24-96]/NN - Title.flac`, cut sample-exact without changing the
  audio, with tags and embedded cover.
- **Move to library**: choose the main music folder, the artist folder (existing or new) and the album
  folder name; Lyrion scans only that folder.
- The controls are also in the "Audio In" menu of the apps (Material, iPeng, Squeezer…), so a record can be
  recorded and marked from a phone. Material Skin gets an item on its home screen.

## Install

On the Lyrion server (Debian/Ubuntu, systemd):

```
curl -fsSL https://github.com/nas963/lyrion-audioin-plugin/releases/latest/download/get.sh | sudo bash
```

The script downloads the package, checks its checksum, installs the plugin, adds the `squeezeboxserver`
user to the `audio` group, creates `/run/audioin` and restarts Lyrion. Required tools (Debian packages):
`alsa-utils`, `flac`. If they are missing, the script prints the install command.

Then choose the sound card, inputs and resolution in **Settings → Audio In**. Only the inputs and sample
rates the card really has are offered.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| Source | Sound card | or a test file (to try it without a card) |
| Input device | — | the card by name (`hw:CARD=…,DEV=…`) |
| Inputs | Stereo 1-2 | a stereo pair, or one mono input in both channels |
| Resolution | 96 kHz | only what the card supports; recordings are always 24-bit FLAC |
| Default source type | Vinyl | side/part names and MEDIA tag of new albums |
| Pre-recording | 5 s | a recording starts this much before Record is pressed |
| Listening delay | 3 s | players start this far behind the input (absorbs clock differences) |
| Marker reaction time | 0.5 s | when listening directly, not through a Lyrion player |
| Timeshift buffer | 10 min | uses RAM, about 35 MB per minute at 24/96 |
| Close input after | 10 min | of inactivity; a closed input frees the card |
| Recordings folder | `/var/lib/squeezeboxserver/AudioIn-Rips` | recordings (hidden `.sessions`) and exported albums |

## Same card as input and DAC

Many USB cards use one clock for input and output. The plugin keeps the input open only while listening,
recording or showing the meter; during that time a local player on the same card cannot play a file at a
different sample rate (recording is not interrupted). For zero-latency listening while recording, use the
card's own "direct monitor".

## Uninstall

```
curl -fsSL https://github.com/nas963/lyrion-audioin-plugin/releases/latest/download/get.sh | sudo bash -s uninstall
```

Removes the plugin, `/etc/tmpfiles.d/audioin.conf` and the AudioIn block from Material's `custom.js` (the
rest of the file is untouched). Recordings and albums (AudioIn-Rips) stay.
