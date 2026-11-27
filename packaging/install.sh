#!/usr/bin/env bash
# Instalira plugin AudioIn (Audio ulaz). Pokrece se kao root iz raspakovanog paketa:
#   sudo bash install.sh
# Plugin ide tamo gde ga stavlja i Lyrion (cache/InstalledPlugins) i upisuje se u Lyrion sa svojim
# repozitorijumom, pa ga Lyrion posle azurira sam, kao bilo koji drugi plugin. Ova skripta je potrebna
# samo jednom, zbog sistemskog dela (tmpfiles, grupa audio) koji Lyrion ne moze sam.
# Lyrion stoji dok se menjaju plugin i podesavanja, sto prekida reprodukciju na svim plejerima.
# Pakete (alsa-utils, flac) ne instalira sam: samo ispise sta fali.
set -euo pipefail

STAGE="$(cd "$(dirname "$0")" && pwd)"
LMS=/var/lib/squeezeboxserver
INSTALLED="$LMS/cache/InstalledPlugins/Plugins"
PLUGIN="$INSTALLED/AudioIn"
OLD_PLUGIN="$LMS/Plugins/AudioIn"    # rucna instalacija: Lyrion je ne azurira
EXT_PREFS="$LMS/prefs/plugin/extensions.prefs"
REPO_URL=https://nas963.github.io/lyrion-audioin-plugin/repo.xml

# alat -> Debian paket
TOOLS="arecord:alsa-utils flac:flac metaflac:flac"

[ "$(id -u)" -eq 0 ] || { echo "Pokreni kao root: sudo bash install.sh"; exit 1; }
command -v systemctl >/dev/null || { echo "Paket je za Debian/Ubuntu sa systemd-om."; exit 1; }
systemctl cat lyrionmusicserver >/dev/null 2>&1 || { echo "Nije nadjen servis lyrionmusicserver."; exit 1; }
[ -f "$STAGE/AudioIn/install.xml" ] || { echo "Nema plugina u $STAGE"; exit 1; }

command -v python3 >/dev/null || { echo "Potreban je python3."; exit 1; }
echo "Lyrion se zaustavlja dok traje instalacija (reprodukcija se prekida)."

trap 'echo "GREŠKA: instalacija nije završena. Vraćanje: curl -fsSL https://github.com/nas963/lyrion-audioin-plugin/releases/latest/download/get.sh | sudo bash -s uninstall"; systemctl start lyrionmusicserver || true' ERR

# Plugin: vlasnik squeezeboxserver, folderi 755, fajlovi 644, audioin-tap izvrsan (LMS ga trazi sa -x).
# Plugin: kao da ga je instalirao Lyrion, i upis u extensions.prefs (plugin + repozitorijum).
# Lyrion mora da stoji: pri gasenju upisuje svoje prefs.
systemctl stop lyrionmusicserver
rm -rf "$OLD_PLUGIN"
mkdir -p "$INSTALLED"
chown squeezeboxserver:nogroup "$LMS/cache/InstalledPlugins" "$INSTALLED"
rm -rf "$PLUGIN"
cp -r "$STAGE/AudioIn" "$PLUGIN"
chown -R squeezeboxserver:nogroup "$PLUGIN"
find "$PLUGIN" -type d -exec chmod 755 {} +
find "$PLUGIN" -type f -exec chmod 644 {} +
chmod 755 "$PLUGIN/Bin/audioin-tap"
install -d -o squeezeboxserver -g nogroup -m 755 "$(dirname "$EXT_PREFS")"
python3 "$STAGE/lms-repo.py" add "$EXT_PREFS" AudioIn "$REPO_URL"
chown squeezeboxserver:nogroup "$EXT_PREFS"
echo "Plugin je u $PLUGIN; azurira ga Lyrion (repozitorijum $REPO_URL)."

# Folder za socket pomocnog procesa (u RAM-u); bez njega plugin koristi /dev/shm/audioin.
if [ -f "$STAGE/system/tmpfiles-audioin.conf" ]; then
    install -m 644 "$STAGE/system/tmpfiles-audioin.conf" /etc/tmpfiles.d/audioin.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/audioin.conf
    echo "Napravljen je /run/audioin (tmpfiles)."
fi

# Pristup zvucnoj kartici.
if getent group audio >/dev/null && id squeezeboxserver >/dev/null 2>&1; then
    usermod -aG audio squeezeboxserver
    echo "Korisnik squeezeboxserver je u grupi audio."
fi

# Alati: samo provera.
missing=""
for pair in $TOOLS; do
    tool="${pair%%:*}"
    pkg="${pair#*:}"
    if [ ! -x "/usr/bin/$tool" ] && [ ! -x "/bin/$tool" ] && ! command -v "$tool" >/dev/null; then
        case " $missing " in *" $pkg "*) ;; *) missing="$missing $pkg" ;; esac
    fi
done
if [ -n "$missing" ]; then
    echo
    echo "Nedostaju alati. Instaliraj ih ovako, pa ponovo pokreni Lyrion:"
    echo "  sudo apt install$missing"
    echo
fi

systemctl start lyrionmusicserver
systemctl is-active lyrionmusicserver
echo "INSTALIRANO"
