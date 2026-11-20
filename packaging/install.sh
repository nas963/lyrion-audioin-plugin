#!/usr/bin/env bash
# Instalira plugin AudioIn (Audio ulaz). Pokrece se kao root iz raspakovanog paketa:
#   sudo bash install.sh
# Na kraju restartuje Lyrion, sto prekida reprodukciju na svim plejerima.
# Pakete (alsa-utils, flac) ne instalira sam: samo ispise sta fali.
set -euo pipefail

STAGE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT=/var/lib/squeezeboxserver/Plugins
PLUGIN="$PLUGIN_ROOT/AudioIn"

# alat -> Debian paket
TOOLS="arecord:alsa-utils flac:flac metaflac:flac"

[ "$(id -u)" -eq 0 ] || { echo "Pokreni kao root: sudo bash install.sh"; exit 1; }
command -v systemctl >/dev/null || { echo "Paket je za Debian/Ubuntu sa systemd-om."; exit 1; }
systemctl cat lyrionmusicserver >/dev/null 2>&1 || { echo "Nije nadjen servis lyrionmusicserver."; exit 1; }
[ -f "$STAGE/AudioIn/install.xml" ] || { echo "Nema plugina u $STAGE"; exit 1; }

echo "Ova instalacija na kraju restartuje Lyrion (reprodukcija se prekida)."

trap 'echo "GREŠKA: instalacija nije završena. Vraćanje: curl -fsSL https://github.com/nas963/lyrion-audioin-plugin/releases/latest/download/get.sh | sudo bash -s uninstall"' ERR

# Plugin: vlasnik squeezeboxserver, folderi 755, fajlovi 644, audioin-tap izvrsan (LMS ga trazi sa -x).
mkdir -p "$PLUGIN_ROOT"
chown squeezeboxserver:nogroup "$PLUGIN_ROOT"
rm -rf "$PLUGIN"
cp -r "$STAGE/AudioIn" "$PLUGIN"
chown -R squeezeboxserver:nogroup "$PLUGIN"
find "$PLUGIN" -type d -exec chmod 755 {} +
find "$PLUGIN" -type f -exec chmod 644 {} +
chmod 755 "$PLUGIN/Bin/audioin-tap"
echo "Plugin je u $PLUGIN"

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

systemctl restart lyrionmusicserver
systemctl is-active lyrionmusicserver
echo "INSTALIRANO"
