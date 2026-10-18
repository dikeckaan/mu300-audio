#!/bin/sh
# Take call audio off the device again: every file install.sh put there is removed, and what it replaced comes back
# from the backup device/remote-install.sh made (/var/lib/mu300-audio, on OpenWrt /etc/mu300/audio).
#
#   ./uninstall.sh [--host USER@IP] [--password PW]
set -eu
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/remote.sh"
HOST=root@192.168.77.1
PW=ubuntu
while [ $# -gt 0 ]; do
    case $1 in
        --host) HOST=$2; shift 2 ;;
        --password) PW=$2; shift 2 ;;
        *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
check_host "$HOST" || exit 2
# the device half below goes over as a file, into a fresh temporary directory there (lib/remote.sh)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
cat > "$T/remote-uninstall.sh" <<'EOF'
set -u
# where device/remote-install.sh keeps them: /etc/mu300/audio on OpenWrt (its /var is tmpfs), /var/lib/mu300-audio
# elsewhere - and on OpenWrt an install from before that, if this boot still has it
STATE=
for d in /etc/mu300/audio /var/lib/mu300-audio; do
    [ -f "$d/installed" ] && { STATE=$d; break; }
done
[ -n "$STATE" ] || { echo "nothing installed by install.sh here (or, on OpenWrt, installed before /etc/mu300/audio and rebooted since: nothing left to restore from)"; exit 0; }
if [ -f /etc/openwrt_release ]; then
    /etc/init.d/mu300-voice stop 2>/dev/null; /etc/init.d/mu300-voice disable 2>/dev/null
else
    systemctl disable --now mu300-voice.service 2>/dev/null
fi
pkill -f 'mu300-voice watch' 2>/dev/null; pkill mu300-hfp 2>/dev/null; pkill pcmhost 2>/dev/null
while IFS= read -r p; do
    # the first versions of install.sh listed mu300-linux's own scripts: those stay as the release has them
    case $p in /opt/mu300/bin/mu300-voice|/opt/mu300/bin/mu300-audio-dsp) continue ;; esac
    rm -rf "$p"
    [ -e "$STATE/backup$p" ] && cp -a "$STATE/backup$p" "$p" && echo "restored $p"
done < "$STATE/installed"
[ -d /run/systemd/system ] && systemctl daemon-reload
rm -rf "$STATE"
echo "removed. A DSP that is running stays up until the next reboot; reboot for a clean state."
EOF
COPYFILE_DISABLE=1 tar -C "$T" -cf - remote-uninstall.sh | remote_run "$HOST" "$PW" remote-uninstall.sh
