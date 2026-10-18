#!/bin/sh
# Install call audio on an MU300 (ZTE F50 / U30 Air) running mu300-linux, from this computer, over ssh.
#
#   ./install.sh [--firmware FILE | --download-firmware] [--params DIR] [--headset AA:BB:CC:DD:EE:FF] [--host USER@IP] [--password PW]
#
#   --firmware FILE   the AGDSP image you extracted yourself (README.md, "The AGDSP firmware"). Required the first
#                     time; a later run without it keeps the image already on the device.
#   --download-firmware  fetch the measured image (a ZTE Voyage 41S AGDSP image the owner published in
#                     github.com/dikeckaan/mu300-audio-firmware) and use it only if its sha256 is exactly the pinned
#                     one; any other file is refused. Instead of --firmware.
#   --params DIR      a directory with the vendor parameter XMLs (audio_structure.xml, dsp_vbc.xml, cvs.xml) or the
#                     blobs built from them (audio_structure, dsp_vbc, cvs). Optional but recommended.
#   --headset ADDR    the Bluetooth headset calls go to (pair it first; README.md, "Bluetooth headset").
#   --host USER@IP    default root@192.168.77.1 (OpenWrt) - use ubuntu@... for Ubuntu
#   --password PW     for sshpass and sudo (default: ubuntu); without sshpass, ssh asks
#   --stage-only      copy and install the files even if the device does not run kernel 5.4 yet
#
# Everything replaced is backed up on the device under /var/lib/mu300-audio/backup (on OpenWrt, whose /var is
# tmpfs: /etc/mu300/audio/backup), and ./uninstall.sh puts it back. The firmware's sha256 is written to
# local/firmware.sha256 here (git-ignored) and /etc/mu300/agdsp.sha256 on the device.
set -eu
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/remote.sh"
KREL=5.4.254-gb50db5b6224c
HOST=root@192.168.77.1
PW=ubuntu
FW= PARAMS= HEADSET= STAGE_ONLY= DOWNLOAD=
while [ $# -gt 0 ]; do
    case $1 in
        --firmware) FW=$2; shift 2 ;;
        --download-firmware) DOWNLOAD=1; shift ;;
        --params) PARAMS=$2; shift 2 ;;
        --headset) HEADSET=$2; shift 2 ;;
        --host) HOST=$2; shift 2 ;;
        --password) PW=$2; shift 2 ;;
        --stage-only) STAGE_ONLY=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
check_host "$HOST" || exit 2
[ -z "$FW" ] || [ -f "$FW" ] || { echo "no file $FW" >&2; exit 1; }
case $HEADSET in ''|[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) echo "--headset wants an address like AA:BB:CC:DD:EE:FF" >&2; exit 2 ;; esac

# --- check the firmware here first, so nothing on the device changes for a wrong file ---
KNOWN=378ceea78dbf013e10625e71efd6fab487d727e371884ae8daf078da2828b937   # ZTE Voyage 41S, measured on an F50
FW_URL=https://github.com/dikeckaan/mu300-audio-firmware/releases/download/v1.0/agdsp.bin
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT INT TERM
mkdir -p "$STAGE/fw"
if [ -n "$DOWNLOAD" ]; then
    [ -z "$FW" ] || { echo "--download-firmware or --firmware, not both" >&2; exit 2; }
    echo "downloading $FW_URL"
    curl -fsSL --proto '=https' -o "$STAGE/download.bin" "$FW_URL" || { echo "download failed" >&2; exit 1; }
    got=$(sha256 "$STAGE/download.bin")
    [ "$got" = "$KNOWN" ] || { echo "the download's sha256 is $got, not the pinned $KNOWN: refused, nothing installed" >&2; exit 1; }
    FW=$STAGE/download.bin
fi
if [ -n "$FW" ]; then
    size=$(wc -c < "$FW" | tr -d ' ')
    [ "$size" -ge 1048576 ] && [ "$size" -le 7340032 ] || { echo "$FW is $size bytes; an AGDSP image is 1-7 MiB (6 MiB on the 41S)" >&2; exit 1; }
    head -c 65536 "$FW" | LC_ALL=C tr -c 'A-Za-z0-9_' '\n' | grep -q AUDCP ||
        { echo "$FW has no AUDCP header in its first 64 KiB: not an AGDSP image" >&2; exit 1; }
    sum=$(sha256 "$FW")
    # a file of your own is recorded here (git-ignored); the pinned download needs no record
    [ -n "$DOWNLOAD" ] || mkdir -p "$HERE/local"
    [ -n "$DOWNLOAD" ] || printf '%s  %s  %s\n' "$sum" "$(basename "$FW")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HERE/local/firmware.sha256"
    echo "firmware: $FW, $size bytes, $(head -c 65536 "$FW" | LC_ALL=C tr -c 'A-Za-z0-9_' '\n' | grep -m1 AUDCP), sha256 $sum"
    if [ "$sum" = "$KNOWN" ]; then echo "  that is the ZTE Voyage 41S image measured on an F50"
    else echo "  not the image measured so far (sha256 378ceea7...b937); untested, installing it anyway"; fi
    cp "$FW" "$STAGE/fw/agdsp.bin"
else
    echo "no --firmware: the AGDSP image already on the device is kept (a first install needs one)"
fi

# --- parameter blobs ---
if [ -n "$PARAMS" ]; then
    if [ -f "$PARAMS/dsp_vbc.xml" ]; then
        python3 "$HERE/tools/vbc-profile/vbc-profile.py" "$PARAMS/dsp_vbc.xml" "$PARAMS/audio_structure.xml" "$PARAMS/cvs.xml" -o "$STAGE/fw" >/dev/null
    else
        for b in audio_structure dsp_vbc cvs; do [ -f "$PARAMS/$b" ] && cp "$PARAMS/$b" "$STAGE/fw/"; done
    fi
    for b in audio_structure dsp_vbc cvs; do
        [ -f "$STAGE/fw/$b" ] || { echo "no $b from $PARAMS" >&2; exit 1; }
        head -c 13 "$STAGE/fw/$b" | grep -q audio_profile || { echo "$b is not an audio_profile blob" >&2; exit 1; }
    done
    echo "profiles: audio_structure, dsp_vbc, cvs from $PARAMS"
fi

# --- the rest of the payload ---
mkdir -p "$STAGE/modules" "$STAGE/bin" "$STAGE/svc"
cp "$HERE/kernel/modules/$KREL/"*.ko "$STAGE/modules/"
cp "$HERE/device/bin/"* "$STAGE/bin/"
chmod 755 "$STAGE/bin/"*
cp "$HERE/device/systemd/mu300-voice.service" "$HERE/device/openwrt/mu300-voice" "$HERE/device/voice.conf.example" "$STAGE/svc/"
cp "$HERE/device/remote-install.sh" "$HERE/device/state.sh" "$STAGE/"
[ -n "$HEADSET" ] && echo "$HEADSET" > "$STAGE/headset"
[ -n "$STAGE_ONLY" ] && touch "$STAGE/stage-only"

# --- ship it and run the device half (lib/remote.sh: the password never on a command line) ---
echo "copying to $HOST and installing..."
# COPYFILE_DISABLE: macOS's tar would add an AppleDouble ._ file for every file with extended attributes
COPYFILE_DISABLE=1 tar -C "$STAGE" -cf - . | remote_run "$HOST" "$PW" remote-install.sh "$KREL"
