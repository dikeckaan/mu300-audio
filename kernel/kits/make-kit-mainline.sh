#!/bin/bash
# Make the build kit of one mainline kernel of a mu300-linux release: what an out-of-tree module needs to be built
# against that exact kernel build, and nothing else. Run by the maintainer, once per mu300-linux release, inside
# mu300-linux's mainline build image (upstream/Dockerfile) with the release's own build tree:
#
#   /src   a copy of the tree upstream/build.sh and build-modules.sh built the release in (linux-$KV, out-$KV)
#   /m     mu300-linux at the release's tag (its upstream/modules: the modem stack the audio stack links against)
#   /out   where kit-$KEY.tar.xz goes
#
#   bash make-kit-mainline.sh KV KEY TAG       e.g. 6.18.57 6.18 v2026.10.19.1 (7.3: 7.3 7.3 TAG, the tree linux-7.3)
#
# The kit (kit-KEY.tar.xz, one directory kit-KEY/):
#   build/          the kernel's own external-module tree (scripts/package/install-extmod-build: headers, scripts,
#                   Module.symvers, include/config, include/generated) with .config, and vmlinux without its DWARF
#                   (the base the modules' BTF is made against)
#   ext/sprd_modem/ the modem stack's headers and Module.symvers (agdsp_access calls sipc-core's exports), built
#                   here from /m against the same tree; its sipc-core.ko, stripped as the release strips it, must be
#                   byte for byte the release's (passed as RELEASE_SIPC_CORE): that is what says /src is the release's tree
#   ext/wcn_bsp/    the headers the modem stack's headers include
#   ext/dma/        the kernel's virt-dma.c, virt-dma.h and dmaengine.h, which the vendor AGCP DMA driver compiles in
#   KIT             what the kit is: KEY, KREL, CONFIG (the sha256 of the .config's settings, the check
#                   mu300-audio-dsp makes against /proc/config.gz before it loads anything), TAG (the mu300-linux release)
set -euo pipefail
KV=$1 KEY=$2 TAG=$3
K=/src/linux-$KV
O=/src/out-$KV
W=/tmp/kit-$KEY
D=$W/kit-$KEY
rm -rf "$W"; mkdir -p "$D/build" "$D/ext/dma" "$D/ext/sprd_modem" "$D/ext/wcn_bsp"
krel=$(cat "$O/include/config/kernel.release")
# (a mainline release's tree is linux-7.3, its kernel release 7.3.0)
[ "$krel" = "$KV" ] || [ "$krel" = "$KV.0" ] || { echo "$O is $krel, not $KV" >&2; exit 1; }

# the kernel's own recipe for a tree to build modules against
(cd "$O" && srctree=$K objtree=$O SRCARCH=arm64 KBUILD_EXTMOD= CC=gcc HOSTCC=gcc MAKE=make \
    sh "$K/scripts/package/install-extmod-build" "$D/build")
cp "$O/.config" "$D/build/.config"
strip --strip-debug -o "$D/build/vmlinux" "$O/vmlinux"

# the modem stack, as build-modules.sh builds it (wcn_bsp first: its headers and exports)
# (built where build-modules.sh builds them, /src/mod-build: the path is in the objects. /src must be a copy of the
# release's tree, not the tree itself: this writes there)
mb=${MOD_BUILD:-/src/mod-build}
mkdir -p "$mb"; rm -rf "$mb/wcn_bsp" "$mb/sprd_modem"
cp -r /m/upstream/modules/wcn_bsp /m/upstream/modules/sprd_modem "$mb/"
make -C "$O" ARCH=arm64 M="$mb/wcn_bsp" -j"$(nproc)" modules > "$W/wcn_bsp.log" 2>&1 || { tail -20 "$W/wcn_bsp.log"; exit 1; }
make -C "$O" ARCH=arm64 M="$mb/sprd_modem" KBUILD_EXTRA_SYMBOLS="$mb/wcn_bsp/Module.symvers" -j"$(nproc)" modules \
    > "$W/sprd_modem.log" 2>&1 || { tail -20 "$W/sprd_modem.log"; exit 1; }
if [ -n "${RELEASE_SIPC_CORE:-}" ]; then
    strip --strip-debug -o "$W/sipc-core.ko" "$(find "$mb/sprd_modem" -name sipc-core.ko)"
    cmp "$W/sipc-core.ko" "$RELEASE_SIPC_CORE" || { echo "sipc-core.ko built here is not the release's: /src is another tree" >&2; exit 1; }
    echo "sipc-core.ko: the release's, byte for byte"
fi
cp "$mb/sprd_modem/Module.symvers" "$D/ext/sprd_modem/Module.symvers"
cp -r "$mb/sprd_modem/kinclude" "$D/ext/sprd_modem/kinclude"
cp -r "$mb/wcn_bsp/kinclude" "$D/ext/wcn_bsp/kinclude"
cp "$K/drivers/dma/virt-dma.c" "$K/drivers/dma/virt-dma.h" "$K/drivers/dma/dmaengine.h" "$D/ext/dma/"

cfg=$(grep -E '^(CONFIG_|# CONFIG_)' "$O/.config" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
{
    echo "KEY=$KEY"
    echo "KREL=$krel"
    echo "CONFIG=$cfg"
    echo "TAG=$TAG"
} > "$D/KIT"
cat "$D/KIT"
# a fixed order, owner and time: the same tree makes the same kit
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -C "$W" -cf - "kit-$KEY" | xz -9e -T0 > "/out/kit-$KEY.tar.xz"
ls -la "/out/kit-$KEY.tar.xz"
sha256sum "/out/kit-$KEY.tar.xz"
