#!/bin/sh
# The device half of uninstall.sh, run as root from the temporary directory lib/remote.sh made (and removes).
# Not meant to be run by hand.   remote-uninstall.sh DIR
set -u
SRC=$1
# STATE, MANIFEST, BK and the checks on them (device/state.sh): nothing is removed or restored from a list that
# someone other than root could have written, or that names a path install.sh never installs
. "$SRC/state.sh"
[ -f "$MANIFEST" ] || { echo "nothing installed by install.sh here"; exit 0; }
state_ok || exit 1
manifest_ok || exit 1
if [ -f /etc/openwrt_release ]; then
    /etc/init.d/mu300-voice stop 2>/dev/null; /etc/init.d/mu300-voice disable 2>/dev/null
else
    systemctl disable --now mu300-voice.service 2>/dev/null
fi
pkill -f 'mu300-voice watch' 2>/dev/null; pkill mu300-hfp 2>/dev/null; pkill pcmhost 2>/dev/null
while IFS= read -r p || [ -n "$p" ]; do
    # the first versions of install.sh listed mu300-linux's own scripts: those stay as the release has them
    case $p in /opt/mu300/bin/mu300-voice|/opt/mu300/bin/mu300-audio-dsp) continue ;; esac
    rm -rf "$p"
    if [ -e "$BK$p" ] && trusted_path "$BK$p"; then cp -a "$BK$p" "$p" && echo "restored $p"; fi
done < "$MANIFEST"
[ -d /run/systemd/system ] && systemctl daemon-reload
rm -rf "$STATE"
echo "removed. A DSP that is running stays up until the next reboot; reboot for a clean state."
