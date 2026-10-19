#!/bin/sh
# Install call audio (the audio extra) on an MU300 (ZTE F50 / U30 Air) running mu300-linux, from this computer, over
# ssh - for a device without internet, or one whose mu300-linux is v2026.10.19.1 (its mu300-extra does not know the
# audio extra by name yet: it installs it as an extra of your own). On a device with internet and a newer release,
# `sudo mu300-extra install audio` there does the same by itself.
#
#   ./install.sh [--host USER@IP] [--password PW] [--from DIR | --release TAG]
#                [--download-firmware | --firmware FILE | --no-firmware] [--headset AA:BB:CC:DD:EE:FF]
#
#   --from DIR        the release files (mu300-audio-*.tar.gz and SHA256SUMS: a release's, or tools/make-extra.sh's
#                     out/release); default: downloaded from this repository's latest release (--release TAG: that one)
#   --download-firmware  fetch the measured DSP image (github.com/dikeckaan/mu300-audio-firmware) here and send it
#                     along, only if its sha256 is exactly the pinned one. Default when the device has no firmware.
#   --firmware FILE   your own AGDSP image instead (checked: 1 to 6 MiB, an AUDCP header)
#   --no-firmware     none (the device keeps the one it has; without one the DSP stays down)
#   --headset ADDR    the Bluetooth headset calls go to (pair it first; README.md, "Bluetooth headset")
#   --host USER@IP    default root@192.168.77.1 (OpenWrt) - use ubuntu@... for Ubuntu (it uses sudo)
#   --password PW     for sshpass and sudo (default: ubuntu); without sshpass, ssh asks
#
# Every file is checked here first (the tarballs against SHA256SUMS, the firmware), and again on the device. The
# device installs the tarball of the kernel it uses (mu300-update kernel) and links it into every system.
set -eu
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/remote.sh"
HOST=root@192.168.77.1
PW=ubuntu
FROM= TAG= FW= FWMODE=auto HEADSET=
while [ $# -gt 0 ]; do
    case $1 in
        --from) FROM=$2; shift 2 ;;
        --release) TAG=$2; shift 2 ;;
        --download-firmware) FWMODE=download; shift ;;
        --firmware) FW=$2; FWMODE=own; shift 2 ;;
        --no-firmware) FWMODE=none; shift ;;
        --headset) HEADSET=$2; shift 2 ;;
        --host) HOST=$2; shift 2 ;;
        --password) PW=$2; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (--help)" >&2; exit 2 ;;
    esac
done
check_host "$HOST" || exit 2
case $HEADSET in ''|[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) echo "--headset wants an address like AA:BB:CC:DD:EE:FF" >&2; exit 2 ;; esac
case $TAG in ''|v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "--release wants a tag like v1.0.0" >&2; exit 2 ;; esac

KNOWN=378ceea78dbf013e10625e71efd6fab487d727e371884ae8daf078da2828b937   # ZTE Voyage 41S, measured on an F50
FW_URL=https://github.com/dikeckaan/mu300-audio-firmware/releases/download/v1.0/agdsp.bin
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT INT TERM
P=$STAGE/payload
mkdir -p "$P"

# --- the release files, checked against their SHA256SUMS ---
if [ -z "$FROM" ]; then
    if [ -n "$TAG" ]; then base=https://github.com/dikeckaan/mu300-audio/releases/download/$TAG
    else base=https://github.com/dikeckaan/mu300-audio/releases/latest/download; fi
    FROM=$STAGE/dl; mkdir -p "$FROM"
    echo "downloading the audio extra from $base"
    curl -fsSL --proto '=https' -o "$FROM/SHA256SUMS" "$base/SHA256SUMS" || { echo "download failed" >&2; exit 1; }
    for f in $(awk '$2 ~ /^mu300-audio-[0-9.]+\.tar\.gz$/ {print $2}' "$FROM/SHA256SUMS"); do
        curl -fsSL --proto '=https' -o "$FROM/$f" "$base/$f" || { echo "download of $f failed" >&2; exit 1; }
    done
fi
[ -f "$FROM/SHA256SUMS" ] || { echo "no SHA256SUMS in $FROM" >&2; exit 1; }
n=0
for f in $(awk '$2 ~ /^mu300-audio-[0-9.]+\.tar\.gz$/ {print $2}' "$FROM/SHA256SUMS"); do
    want=$(awk -v f="$f" '$2 == f {print $1}' "$FROM/SHA256SUMS")
    [ -f "$FROM/$f" ] && [ "$(sha256 "$FROM/$f")" = "$want" ] || { echo "$FROM/$f does not match SHA256SUMS" >&2; exit 1; }
    cp "$FROM/$f" "$P/"; n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "SHA256SUMS in $FROM lists no mu300-audio-*.tar.gz" >&2; exit 1; }
cp "$FROM/SHA256SUMS" "$P/SHA256SUMS"

# --- the firmware, checked here first ---
case $FWMODE in
    download|auto)
        echo "downloading $FW_URL"
        if curl -fsSL --proto '=https' -o "$STAGE/agdsp.bin" "$FW_URL"; then
            got=$(sha256 "$STAGE/agdsp.bin")
            [ "$got" = "$KNOWN" ] || { echo "the download's sha256 is $got, not the pinned $KNOWN: refused, nothing installed" >&2; exit 1; }
            cp "$STAGE/agdsp.bin" "$P/agdsp.bin"
        elif [ "$FWMODE" = download ]; then
            echo "download failed" >&2; exit 1
        else
            echo "note: the firmware could not be downloaded here; the device keeps its own, or fetches it itself when it is online" >&2
        fi ;;
    own)
        [ -f "$FW" ] || { echo "no file $FW" >&2; exit 1; }
        size=$(wc -c < "$FW" | tr -d ' ')
        [ "$size" -ge 1048576 ] && [ "$size" -le 6291456 ] || { echo "$FW is $size bytes; an AGDSP image is 1 to 6 MiB" >&2; exit 1; }
        head -c 65536 "$FW" | LC_ALL=C tr -c 'A-Za-z0-9_' '\n' | grep -q AUDCP ||
            { echo "$FW has no AUDCP header in its first 64 KiB: not an AGDSP image" >&2; exit 1; }
        cp "$FW" "$P/agdsp.bin"; : > "$P/own-firmware" ;;
esac
[ -z "$HEADSET" ] || echo "$HEADSET" > "$P/headset"
cp "$HERE/device/remote-install.sh" "$STAGE/"

# --- ship it and run the device half (lib/remote.sh: the password never on a command line) ---
echo "copying to $HOST and installing..."
# COPYFILE_DISABLE: macOS's tar would add an AppleDouble ._ file for every file with extended attributes
COPYFILE_DISABLE=1 tar -C "$STAGE" -cf - remote-install.sh payload | remote_run "$HOST" "$PW" remote-install.sh
