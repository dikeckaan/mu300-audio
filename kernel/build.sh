#!/bin/sh
# Build the audio drivers for one kernel of kits/kits.lock, against that kernel's build kit:
#
#   kernel/build.sh KEY [OUTDIR]       KEY: 5.4, 6.18, 7.2 or 7.3; default OUTDIR: out/modules/KEY
#
# The kit is downloaded from this repository's release kits-<mu300-linux release> (KIT_DIR=DIR: a directory that has
# kit-KEY.tar.xz already) and used only when its sha256 is the one kits.lock pins. The build runs in Docker, in the
# image of kernel/5.4/Dockerfile or kernel/mainline/Dockerfile (the toolchains mu300-linux builds its kernels with),
# natively on arm64 (an Apple Silicon Mac, GitHub's ubuntu-24.04-arm): the kit's host programs are arm64 ones.
# Afterwards every module must be there (MODULES in this file), carry the kernel's vermagic, and be built from the
# patched sources (a marker each patch leaves). OUTDIR gets the .ko files and KERNEL (KEY, KREL, CONFIG).
# A KEY with more than one line in kits.lock (the kernel of the current mu300-linux release first, then earlier builds
# of it kept for the devices that have not updated yet): the first line's set goes to OUTDIR, each later one's to
# OUTDIR+<the first 12 digits of its CONFIG> (tools/make-extra.sh puts them side by side in the tarball).
set -eu
KEY=${1:?usage: kernel/build.sh 5.4|6.18|7.2|7.3 [OUTDIR]}
TOP=$(cd "$(dirname "$0")/.." && pwd)
OUT=${2:-$TOP/out/modules/$KEY}
REPO=${MU300_AUDIO_REPO:-dikeckaan/mu300-audio}
n=$(awk -v k="$KEY" '$1 == k' "$TOP/kernel/kits/kits.lock" | wc -l | tr -d ' ')
[ "$n" -gt 0 ] || { echo "no kernel $KEY in kernel/kits/kits.lock" >&2; exit 2; }
if [ -z "${MU300_KIT_LINE:-}" ]; then
    i=1
    while [ "$i" -le "$n" ]; do
        o=$OUT
        [ "$i" = 1 ] || o=$OUT+$(awk -v k="$KEY" -v i="$i" '$1 == k && ++c == i {print substr($3, 1, 12)}' "$TOP/kernel/kits/kits.lock")
        MU300_KIT_LINE=$i sh "$0" "$KEY" "$o" || exit $?
        i=$((i + 1))
    done
    exit 0
fi
line=$(awk -v k="$KEY" -v i="$MU300_KIT_LINE" '$1 == k && ++c == i' "$TOP/kernel/kits/kits.lock")
set -- $line
KREL=$2 CONFIG=$3 KITSHA=$4 TAG=$5
# the kit goes where the release's kernel source was (the headers' paths end up in __FILE__ strings, and the same path
# makes the same bytes)
case $KEY in 5.4) IMG=mu300-audio-k54; DF=$TOP/kernel/5.4; KB=/src/zte-u30air ;;
    *) IMG=mu300-audio-mainline; DF=$TOP/kernel/mainline; KB=/src/linux-$KREL
       # a mainline release's tree is linux-7.3 for the kernel release 7.3.0: the kit's build tree goes where it was
       [ "${KREL##*.}" != 0 ] || KB=/src/linux-${KREL%.0} ;; esac

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
W=$(mktemp -d)
# what the build wrote inside Docker is root's on a Linux host: removed from inside Docker as well
cleanup() { [ ! -d "$W/kit" ] || docker run --rm -v "$W:/w" "$IMG" sh -c 'rm -rf /w/kit /w/out' >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT INT TERM
# (a kit in KIT_DIR that is not this line's - another build of the same kernel - is not taken: downloaded instead)
if [ -n "${KIT_DIR:-}" ] && [ -f "$KIT_DIR/kit-$KEY.tar.xz" ] && [ "$(sha "$KIT_DIR/kit-$KEY.tar.xz")" = "$KITSHA" ]; then
    cp "$KIT_DIR/kit-$KEY.tar.xz" "$W/kit.tar.xz"
else
    url=https://github.com/$REPO/releases/download/kits-$TAG/kit-$KEY.tar.xz
    echo "downloading $url"
    curl -fsSL --proto '=https' --retry 3 -o "$W/kit.tar.xz" "$url"
fi
got=$(sha "$W/kit.tar.xz")
[ "$got" = "$KITSHA" ] || { echo "kit-$KEY.tar.xz is $got, kits.lock pins $KITSHA: not used" >&2; exit 1; }
mkdir -p "$W/kit" "$W/out"
xz -dc "$W/kit.tar.xz" | tar -xf - -C "$W/kit"
grep -qx "KREL=$KREL" "$W/kit/kit-$KEY/KIT" && grep -qx "CONFIG=$CONFIG" "$W/kit/kit-$KEY/KIT" ||
    { echo "kit-$KEY.tar.xz is not the kernel kits.lock names" >&2; exit 1; }

docker build -q -t "$IMG" "$DF" >/dev/null
docker run --rm -e KB="$KB" -v "$W/kit/kit-$KEY/build:$KB" -v "$W/kit/kit-$KEY:/kit:ro" -v "$TOP:/repo:ro" -v "$W/out:/out" "$IMG" bash "/repo/kernel/${DF##*/}/build-in.sh"

# what each kernel's set must hold: the 23 of 5.4, the 20 of mainline (no saudio, sprd_dai, vaudio, ucp1301 - nothing
# on these boards uses them - and the vendor AGCP DMA driver of its own)
COMMON="audio_mem agdsp_access audio_sipc sprd_audcp_boot sprd_audcp_dvfs audio-dsp-dump audio-pipe sprd_apipe
mcdt_hw_r2p0 sprd-dmaengine-pcm sprd-platform-pcm-routing sprd-compr-2stage-dma snd-soc-sprd-vbc-v4 snd-soc-sprd-vbc-fe
snd-soc-sprd-codec-ump9620-power snd-soc-sprd-codec-ump9620-power-dev snd-soc-sprd-codec-ump9620 snd-soc-sprd-dummy-codec
snd-soc-sprd-card"
case $KEY in
    5.4) MODULES="$COMMON saudio snd-soc-sprd-dai snd-soc-sprd-vaudio snd-soc-sprd-pa-ucp1301" ;;
    *) MODULES="$COMMON sprd-dma" ;;
esac
want=$(printf '%s\n' $MODULES | LC_ALL=C sort)
have=$(cd "$W/out" && ls *.ko | sed 's/\.ko$//' | LC_ALL=C sort)
[ "$want" = "$have" ] || { echo "the $KEY build made other modules than expected:"; diff -u /dev/fd/3 /dev/fd/4 3<<A 4<<B; exit 1; } >&2
$want
A
$have
B
for m in $MODULES; do
    v=$(LC_ALL=C tr '\0' '\n' < "$W/out/$m.ko" | LC_ALL=C sed -n 's/^vermagic=//p')
    case $v in "$KREL "*) ;; *) echo "$m.ko has vermagic '$v', not $KREL" >&2; exit 1 ;; esac
done
# the patches are in: a string each one adds to a module
for mark in 'audio_sipc:dropped a stale reply' 'mcdt_hw_r2p0:enabled the agcp mcdt clock' 'snd-soc-sprd-card:dummy_on_defer' \
        'audio_mem:shm_shift' 'snd-soc-sprd-vbc-v4:rejected (%d)'; do
    LC_ALL=C grep -aq "${mark#*:}" "$W/out/${mark%%:*}.ko" || { echo "${mark%%:*}.ko lacks its patch ('${mark#*:}')" >&2; exit 1; }
done
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$W/out"/*.ko "$OUT/"
printf 'KEY=%s\nKREL=%s\nCONFIG=%s\nTAG=%s\n' "$KEY" "$KREL" "$CONFIG" "$TAG" > "$OUT/KERNEL"
echo "$(ls "$OUT"/*.ko | wc -l | tr -d ' ') modules for $KREL in $OUT"
