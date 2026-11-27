#!/usr/bin/env bash
# Uklanja plugin AudioIn. Pokrece se kao root:
#   sudo bash uninstall.sh
# Restartuje Lyrion. Snimljeni albumi (AudioIn-Rips) ostaju, a korisnik squeezeboxserver ostaje u grupi audio.
set -euo pipefail

STAGE="$(cd "$(dirname "$0")" && pwd)"
PREFS=/var/lib/squeezeboxserver/prefs
PLUGIN=/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/AudioIn
OLD_PLUGIN=/var/lib/squeezeboxserver/Plugins/AudioIn
EXT_PREFS="$PREFS/plugin/extensions.prefs"
REPO_URL=https://nas963.github.io/lyrion-audioin-plugin/repo.xml
CUSTOM="$PREFS/material-skin/custom.js"

# Uklanja samo AudioIn blok iz fajla (od "// AudioIn start" do "// AudioIn end"); ostalo se ne dira.
# Upis je atomski (privremeni fajl u istom folderu pa rename). Fajl bez bloka se ne menja.
remove_audioin_block() {
    perl -e '
        my $file = shift;
        open my $in, "<:raw", $file or die "$file: $!\n";
        local $/;
        my $text = <$in>;
        close $in;
        my ($s, $e) = ("// AudioIn start", "// AudioIn end");
        my $new = $text;
        $new =~ s/^\Q$s\E[ \t]*\r?\n.*?^\Q$e\E[ \t]*(?:\r?\n|\z)//ms;
        $new =~ s/^\Q$s\E[ \t]*(?:\r?\n|\z)(?:\(function \(\) \{[^\n]*\n.*?^\}\)\(\);[ \t]*(?:\r?\n|\z))?//ms;
        $new =~ s/^\Q$e\E[ \t]*(?:\r?\n|\z)//m;
        exit 0 if $new eq $text;
        my $mode = (stat $file)[2] & 07777;
        my $tmp = "$file.audioin.$$";
        open my $out, ">:raw", $tmp or die "$tmp: $!\n";
        print {$out} $new or die "$tmp: $!\n";
        close $out or die "$tmp: $!\n";
        chmod $mode, $tmp;
        rename $tmp, $file or do { unlink $tmp; die "$file: $!\n" };
    ' "$1"
}

main() {
    [ "$(id -u)" -eq 0 ] || { echo "Pokreni kao root: sudo bash uninstall.sh"; exit 1; }

    # Lyrion stoji dok se menjaju plugin i prefs (pri gasenju upisuje svoje prefs)
    systemctl stop lyrionmusicserver
    rm -rf "$PLUGIN" "$OLD_PLUGIN"
    if [ -f "$EXT_PREFS" ] && [ -f "$STAGE/lms-repo.py" ]; then
        python3 "$STAGE/lms-repo.py" remove "$EXT_PREFS" AudioIn "$REPO_URL"
    fi
    rm -f /etc/tmpfiles.d/audioin.conf
    rm -rf /run/audioin /dev/shm/audioin

    if [ -f "$CUSTOM" ]; then
        remove_audioin_block "$CUSTOM"
    fi

    echo "Snimci i albumi (AudioIn-Rips) i korisnik u grupi audio ostaju netaknuti."
    systemctl start lyrionmusicserver
    systemctl is-active lyrionmusicserver
    echo "UKLONJENO"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
