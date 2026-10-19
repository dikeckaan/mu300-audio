#!/bin/bash
# Build the mainline audio drivers against a kit, inside kernel/mainline/Dockerfile's image (kernel/build.sh runs
# this): /kit the unpacked kit (kit-KEY/), /repo this repository (read only), /out where the .ko files go.
# Built where mu300-linux's build-modules.sh built them for the release (/src/mod-build/sprd_audio, next to the modem
# stack's headers): the path is in the objects, and the same path makes the same bytes.
set -euo pipefail
B=${KB:-/kit/build}
mb=/src/mod-build
rm -rf "$mb"; mkdir -p "$mb/sprd_modem" "$mb/wcn_bsp"
cp -r /repo/kernel/mainline/sprd_audio "$mb/sprd_audio"
cp -r /kit/ext/sprd_modem/kinclude "$mb/sprd_modem/kinclude"
cp /kit/ext/sprd_modem/Module.symvers "$mb/sprd_modem/Module.symvers"
cp -r /kit/ext/wcn_bsp/kinclude "$mb/wcn_bsp/kinclude"
# the vendor AGCP DMA driver compiles the kernel's own virt-dma in (sprd_audio/Kbuild)
cp /kit/ext/dma/virt-dma.c /kit/ext/dma/virt-dma.h /kit/ext/dma/dmaengine.h "$mb/sprd_audio/dma/"
make -C "$B" ARCH=arm64 M="$mb/sprd_audio" KBUILD_EXTRA_SYMBOLS="$mb/sprd_modem/Module.symvers" -j"$(nproc)" modules \
    > /out/build.log 2>&1 || { tail -40 /out/build.log; exit 1; }
for ko in $(find "$mb/sprd_audio" -name '*.ko'); do
    # as the release strips its out-of-tree modules: the DWARF goes, the .BTF stays
    strip --strip-debug -o "/out/${ko##*/}" "$ko"
done
