#!/bin/sh
# The device half of install.sh, run as root from the temporary directory lib/remote.sh made (and removes).
# Not meant to be run by hand.   remote-install.sh DIR
# DIR/payload: the release's mu300-audio-*.tar.gz and SHA256SUMS (checked again here), agdsp.bin (own-firmware: the
# user's own image), headset.
set -eu
P=$1/payload
export PATH="$PATH:/opt/mu300/bin:/opt/mu300/busybox-bin:/usr/sbin:/sbin"
umask 022
command -v mu300-extra >/dev/null 2>&1 || { echo "this mu300-linux has no mu300-extra: update it first (mu300-update apply)" >&2; exit 1; }
# the kernel the device uses (mu300-update kernel; none chosen: the release's 5.4)
k=$(cat /mnt/mu300-disk/boot/kernel 2>/dev/null || true)
case $k in 5.4|6.18|7.2|7.3) ;; *) k=5.4 ;; esac
t=mu300-audio-$k.tar.gz
[ -f "$P/$t" ] || { echo "the release files have no $t (for kernel $k)" >&2; exit 1; }
(cd "$P" && grep "  $t\$" SHA256SUMS | sha256sum -c - >/dev/null) || { echo "$t does not match SHA256SUMS" >&2; exit 1; }
fw=
[ ! -f "$P/agdsp.bin" ] || [ ! -f "$P/own-firmware" ] || fw=$P/agdsp.bin
if mu300-extra list 2>/dev/null | grep -q '^audio '; then
    # a release that knows the audio extra: the firmware is taken from the directory (pinned) or given as your own
    if [ -n "$fw" ]; then MU300_AUDIO_FIRMWARE=$fw mu300-extra install audio --from "$P"
    else mu300-extra install audio --from "$P"; fi
else
    # a release up to v2026.10.19.1: its mu300-extra installs it as an extra of your own, audio.tar.gz with a
    # SHA256SUMS that lists it (the release's SHA256SUMS vouched for it above)
    mkdir -p "$P/own"
    cp "$P/$t" "$P/own/audio.tar.gz"
    (cd "$P/own" && sha256sum audio.tar.gz > SHA256SUMS)
    mu300-extra install audio --from "$P/own"
    if [ -f "$P/agdsp.bin" ]; then
        if [ -n "$fw" ] || [ ! -f /lib/firmware/agdsp.bin ]; then /opt/mu300/bin/mu300-audio-dsp install "$P/agdsp.bin"; fi
    fi
fi
if [ -f "$P/headset" ]; then
    h=$(cat "$P/headset")
    case $h in [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) echo "the headset address is not AA:BB:CC:DD:EE:FF; not set" >&2; exit 1 ;; esac
    [ -f /etc/mu300/voice.conf ] || cp /etc/mu300/voice.conf.example /etc/mu300/voice.conf
    if grep -q '^BT_HEADSET=' /etc/mu300/voice.conf; then sed -i "s/^BT_HEADSET=.*/BT_HEADSET=$h/" /etc/mu300/voice.conf
    else echo "BT_HEADSET=$h" >> /etc/mu300/voice.conf; fi
    echo "headset: $h (/etc/mu300/voice.conf)"
fi
echo
echo "installed. Check:  mu300-audio-dsp status   (dsp: running - it answered)"
