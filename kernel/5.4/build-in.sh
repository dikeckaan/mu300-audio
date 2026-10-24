#!/bin/bash
# Build the 5.4 audio drivers against the kit, inside kernel/5.4/Dockerfile's image (kernel/build.sh runs this): /kit
# the unpacked kit (kit-5.4/), /repo this repository (read only), /out where the .ko files go.
#
# The sources are Unisoc's 5.4 audio drivers as realme published them (audio_driver/, the revision in SOURCE), with
# the patches/ applied. Three things about this build are not obvious and cost an evening each:
#
#   * Order matters and one pass is not enough. audio_sipc needs symbols from agdsp_access, the DAIs need the
#     platform, the card needs all of them. Dependencies are resolved by building repeatedly and handing every
#     Module.symvers produced so far to the next attempt.
#   * A failed attempt has to be cleaned before it is retried. The leftover objects link a second time and the
#     error is "duplicate symbol: __this_module", which says nothing about the real problem.
#   * The UMP9620 codec only compiles with BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig. Its Kbuild hides
#     -DCONFIG_SND_SOC_UNISOC_CODEC_UMP9620 behind that, and without it the failure is an implicit declaration
#     of TO_STRING several hundred lines away.
#
# Two directories never build and should not: dmaengine_2stage_pcm and i2s are for older Unisoc SoCs (their
# VBC_DAI_NORMAL comes from the pike2/sharkl3/sharkle headers), and this one uses VBC v4.
set -euo pipefail
B=${KB:-/kit/build}
A=/src/ext-audio
rm -rf "$A"; mkdir -p "${A%/*}"
cp -r /repo/kernel/5.4/audio_driver "$A"
# the order of mu300-linux's kernel/build-audio.sh, which built them for the releases up to v2026.10.19.1, then the
# voice capture tap's MCDT watermark and DMA fragment as module parameters, voice_c_wmk and voice_c_frag (mu300-linux
# PR #336; the defaults are the vendor's 160/160), the bounds checks of the mainline port (audio-ctl-bounds), its
# bounded wait for the AGDSP power domain (agdsp-access-bounded-wait), and the headset's regulators switched off before
# they are put (headset-power-deinit-disable)
for p in audio-mem-fixed-region audio-mem-shm-shift mcdt-enable-clock sprd-card-dummy-on-defer \
         audio-pcm-period-timer audio-pcm-pointer-agcp-access audio-fe-dai-formats audio-sipc-stale-reply \
         audio-fe-voice-c-mcdt-params audio-ctl-bounds agdsp-access-bounded-wait headset-power-deinit-disable; do
    (cd "$A" && patch -p1 -s -f < "/repo/kernel/5.4/patches/$p.patch")
done
[ "$(ls /repo/kernel/5.4/patches/*.patch | wc -l)" = 12 ] || { echo "patches/ has a patch this build does not apply" >&2; exit 1; }

# headers these Kbuilds include by name without putting the directory on their own path
INC="-I$A/sprd_audio/agdsp_access -I$A/sprd_audio/audiomem -I$A/sprd_audio/audiosipc"
INC="$INC -I$A/sprd/include -I$A/sprd/platform/include -I$A/sprd/platform/dmaengine_pcm"
INC="$INC -I$A/sprd/codec/sprd -I$A/sprd/dai/vbc/v4/vbc_dai"

DIRS="sprd_audio/agdsp_access sprd_audio/audiomem sprd_audio/audiosipc sprd_audio/audiocpboot
sprd_audio/audiodvfs sprd_audio/audiodspdump sprd_audio/mcdt/mcdt_r2p0 sprd_audio/audio_pipe
sprd_audio/audiopipe sprd_audio/saudio
sprd/platform/platform_routing sprd/platform/dmaengine_pcm sprd/platform/compr_2stage_dma
sprd/dai/sprd_dai sprd/dai/vaudio sprd/dai/vbc/v4/vbc_dai sprd/dai/vbc/v4/fe_dai
sprd/codec/sprd/ump9620/power sprd/codec/sprd/ump9620/power_dev sprd/codec/sprd/ump9620/codec
sprd/codec/dummy-codec sprd/codec/sprd/ucp1301
sprd/machine/sprd_card"

syms() { find $A -name Module.symvers | tr "\n" " "; }
build() {
    d=$A/$1
    [ -f "$d/Kbuild" ] || return 0
    ls "$d"/*.ko >/dev/null 2>&1 && return 0          # already built in an earlier pass
    find "$d" -name "*.o" -delete 2>/dev/null || true # or the retry links __this_module twice
    rm -f "$d"/*.mod "$d"/*.mod.c "$d"/Module.symvers "$d"/modules.order 2>/dev/null || true
    make -C "$B" ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld -j"$(nproc)" \
        M="$d" KCFLAGS="$INC" BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig \
        KBUILD_EXTRA_SYMBOLS="$(syms)" modules >> /out/build.log 2>&1 \
        || echo "   still unbuilt: $1 ($(grep -m1 -E "error:|undefined!" /out/build.log | cut -c1-110))"
}
: > /out/build.log
for pass in 1 2 3; do
    echo "==> pass $pass"
    for d in $DIRS; do build "$d"; done
done
for ko in $(find "$A" -name '*.ko'); do
    llvm-strip --strip-debug -o "/out/${ko##*/}" "$ko"
done
