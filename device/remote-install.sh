#!/bin/sh
# The device half of install.sh, run as root from the temporary directory lib/remote.sh made (and removes).
# Not meant to be run by hand.   remote-install.sh DIR KREL
set -eu
SRC=$1
KREL=$2
export PATH="$PATH:/opt/mu300/bin:/opt/mu300/busybox-bin:/usr/sbin:/sbin"
umask 022
# STATE, BK, MANIFEST and the checks on them (device/state.sh): the list is acted on as root, so it is read only from
# a directory root alone can write, and only the paths this installer installs may be in it
. "$SRC/state.sh"
[ "$KREL" = "$KREL_AUDIO" ] || { echo "unexpected kernel release $KREL" >&2; exit 1; }
state_ok || exit 1
manifest_ok || exit 1

running=$(uname -r)
if [ "$running" != "$KREL" ] && [ ! -f "$SRC/stage-only" ]; then
    echo "this device runs kernel $running; the audio drivers are for $KREL (the vendor 5.4 kernel)." >&2
    echo "switch first:  mu300-update kernel 5.4  and reboot, then run install.sh again" >&2
    echo "(or pass --stage-only to install the files now; they take effect once 5.4 runs)" >&2
    echo "On the mainline kernels (6.18, 7.2) the audio drivers come with mu300-linux itself: only the firmware is" >&2
    echo "needed there (mu300-audio-dsp install FILE on the device)." >&2
    exit 1
fi
[ -d "/lib/modules/$KREL" ] || { echo "no /lib/modules/$KREL: this system has never had kernel 5.4 installed (mu300-update kernel 5.4)" >&2; exit 1; }

if [ -f /etc/openwrt_release ]; then SYS=openwrt; else SYS=systemd; fi
mkdir -p /etc/mu300
(umask 077; mkdir -p "$BK")
state_ok || exit 1
# back up a path once - the first install's original is the one uninstall restores
backup() {
    for p in "$@"; do
        [ -e "$p" ] || continue
        [ -e "$BK$p" ] && continue
        mkdir -p "$BK$(dirname "$p")"
        cp -a "$p" "$BK$p"
    done
}
installed() { for p in "$@"; do grep -qxF "$p" "$MANIFEST" 2>/dev/null || echo "$p" >> "$MANIFEST"; done; }
not_installed() {
    [ -f "$MANIFEST" ] || return 0
    for p in "$@"; do grep -vxF "$p" "$MANIFEST" > "$MANIFEST.new" || true; mv "$MANIFEST.new" "$MANIFEST"; done
}

A=/lib/modules/$KREL/audio
B=/opt/mu300/bin

# mu300-audio-dsp and mu300-voice are part of mu300-linux itself; the first versions of this installer put copies of
# their own over them, older than the release's now. fits FILE: a copy this stack is written for (mu300-linux
# v2026.10.18.1 or later: the driver directory lookup, the downlink from the VBC dump).
fits() { [ -x "$1" ] && { grep -q audio_dir "$1" || grep -q FE_ST_DUMP "$1"; }; }
# An install by such a version: the file stays if it is the release's (a release update has put it back since), or
# the backup comes back if that is; either way it leaves the list, since uninstall.sh has nothing of ours to remove.
for s in mu300-audio-dsp mu300-voice; do
    grep -qxF "$B/$s" "$MANIFEST" 2>/dev/null || continue
    if ! fits "$B/$s" && [ -f "$BK$B/$s" ] && fits "$BK$B/$s"; then
        cp -a "$BK$B/$s" "$B/$s" && echo "restored mu300-linux's own $B/$s"
    fi
    fits "$B/$s" || continue
    rm -f "$BK$B/$s"
    not_installed "$B/$s"
done
if ! fits "$B/mu300-audio-dsp" || ! fits "$B/mu300-voice" || [ ! -f /opt/mu300/lib/run-dir.sh ]; then
    echo "this mu300-linux is too old for this installer, or its $B/mu300-audio-dsp and $B/mu300-voice were" >&2
    echo "replaced by an older version of it: they come with mu300-linux, and v2026.10.18.1 or later is needed." >&2
    echo "Update (mu300-update), then run install.sh again." >&2
    exit 1
fi

backup "$A" "$B/pcmhost" "$B/ctlset" "$B/mu300-hfp" \
    /lib/firmware/agdsp.bin /lib/firmware/audio_structure /lib/firmware/dsp_vbc /lib/firmware/cvs \
    /etc/mu300/voice.conf /etc/systemd/system/mu300-voice.service /etc/init.d/mu300-voice

# drivers: mu300-audio-dsp insmods them from here; /etc/modprobe.d/mu300-audio.conf in the image keeps modprobe away
mkdir -p "$A"
for f in "$SRC"/modules/*.ko; do case ${f##*/} in ._*) continue ;; esac; cp "$f" "$A/"; done
installed "$A"
# the static tools mu300-voice runs (the scene, raw mixer writes, the headset link)
for f in "$SRC"/bin/*; do case ${f##*/} in ._*) continue ;; esac; cp "$f" "$B/${f##*/}"; chmod 755 "$B/${f##*/}"; installed "$B/${f##*/}"; done
# firmware: through mu300-audio-dsp, which checks it again and records its sha256 on the device. An install that
# passes no firmware keeps the one already there.
if [ -f "$SRC/fw/agdsp.bin" ]; then
    "$B/mu300-audio-dsp" install "$SRC/fw/agdsp.bin"
    installed /lib/firmware/agdsp.bin /etc/mu300/agdsp.sha256
elif [ ! -f /lib/firmware/agdsp.bin ]; then
    echo "note: no /lib/firmware/agdsp.bin on the device yet; the DSP stays down until you install one (install.sh --firmware FILE)" >&2
fi
for b in audio_structure dsp_vbc cvs; do
    [ -f "$SRC/fw/$b" ] || continue
    cp "$SRC/fw/$b" "/lib/firmware/$b"; installed "/lib/firmware/$b"
done
# configuration: kept if there is one, the headset address set if one was given
[ -f /etc/mu300/voice.conf ] || cp "$SRC/svc/voice.conf.example" /etc/mu300/voice.conf
installed /etc/mu300/voice.conf
if [ -f "$SRC/headset" ]; then
    h=$(cat "$SRC/headset")
    case $h in [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) echo "the headset address is not AA:BB:CC:DD:EE:FF; not set" >&2; exit 1 ;; esac
    sed -i "s/^BT_HEADSET=.*/BT_HEADSET=$h/" /etc/mu300/voice.conf
fi
# the call follower
if [ "$SYS" = systemd ]; then
    cp "$SRC/svc/mu300-voice.service" /etc/systemd/system/
    installed /etc/systemd/system/mu300-voice.service
    systemctl daemon-reload
    systemctl enable mu300-voice.service >/dev/null 2>&1
else
    cp "$SRC/svc/mu300-voice" /etc/init.d/mu300-voice; chmod 755 /etc/init.d/mu300-voice
    installed /etc/init.d/mu300-voice
    /etc/init.d/mu300-voice enable
fi
echo
echo "installed. Reboot to bring the sound card and the DSP up from a clean state:"
echo "  reboot"
echo "then check:  mu300-audio-dsp status   (dsp: running)  and  mu300-voice status"
