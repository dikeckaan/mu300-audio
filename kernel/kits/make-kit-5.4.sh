#!/bin/bash
# Make the build kit of the vendor 5.4 kernel of a mu300-linux release (see make-kit-mainline.sh for what a kit is).
# Run by the maintainer inside mu300-linux's 5.4 build image (kernel/Dockerfile) with the mu300-kernel volume the
# release's 5.4 kernel was built in (kernel/build-all.sh):
#
#   /src   that volume (zte-u30air: the source, out-linux: the build), read only
#   /out   where kit-5.4.tar.xz goes
#
#   bash make-kit-5.4.sh TAG [RELEASE_MODULES_DIR]
#
# 5.4 has modversions: every module carries the CRC of each kernel symbol it uses, and the kernel refuses one whose
# CRCs are not its own. With RELEASE_MODULES_DIR (the modules/ of the release's mu300-kernel.tar.gz) every CRC the
# release's own modules carry is checked against this tree's Module.symvers, and one that differs stops the kit: that
# is what says this tree builds modules the release's kernel takes.
# The tree is the one 5.4's own scripts/package/builddeb packs as linux-headers (deploy_kernel_headers), with .config
# and the headers under drivers/ and sound/ (the vendor's own headers include some of them by relative path).
set -euo pipefail
TAG=$1 REL=${2:-}
S=/src/zte-u30air
O=/src/out-linux
W=/tmp/kit-5.4
D=$W/kit-5.4
rm -rf "$W"; mkdir -p "$D/build"
krel=$(cat "$O/include/config/kernel.release")
(
    cd "$S"
    find . -path ./.git -prune -o \( -name 'Makefile*' -o -name 'Kconfig*' -o -name '*.pl' \) -print
    find arch/*/include include scripts -type f -o -type l
    find arch/arm64 -name module.lds -o -name Kbuild.platforms -o -name Platform
    find $(find arch/arm64 -name include -o -name scripts -type d) -type f
    # the vendor's headers include drivers' own headers by relative path (asm/io.h: ../drivers/soc/sprd/...)
    find drivers sound -name '*.h'
) | sort -u > "$W/src.list"
(cd "$S" && tar -cf - -T "$W/src.list") | (cd "$D/build" && tar -xf -)
(
    cd "$O"
    find arch/arm64/include Module.symvers include scripts -type f
) | sort -u > "$W/obj.list"
(cd "$O" && tar -cf - -T "$W/obj.list") | (cd "$D/build" && tar -xf -)
cp "$O/.config" "$D/build/.config"
find "$D/build" \( -name '.*.cmd' -o -name '*.o' \) -delete

if [ -n "$REL" ]; then
    python3 - "$D/build/Module.symvers" "$REL" <<'PY'
import struct, sys, os
syms = {}
for l in open(sys.argv[1]):
    f = l.split('\t')
    syms[f[1]] = int(f[0], 16)
def versions(path):
    d = open(path, 'rb').read()
    # ELF64 little endian: the section headers, their names, and __versions (struct modversion_info: u64 crc, char[56])
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    sh = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    names = sh[shstrndx]
    for s in sh:
        name = d[names[4] + s[0]:].split(b'\0', 1)[0]
        if name == b'__versions':
            for o in range(s[4], s[4] + s[5], 64):
                crc, = struct.unpack_from('<Q', d, o)
                yield d[o + 8:o + 64].split(b'\0', 1)[0].decode(), crc
n = bad = 0
for root, _, files in os.walk(sys.argv[2]):
    for f in files:
        if not f.endswith('.ko'):
            continue
        for sym, crc in versions(os.path.join(root, f)):
            if sym in ('module_layout',) or sym not in syms:
                continue
            n += 1
            if syms[sym] & 0xffffffff != crc & 0xffffffff:
                bad += 1
                print('CRC differs: %s %s' % (f, sym))
print('%d CRCs of the release modules checked, %d differ' % (n, bad))
sys.exit(1 if bad or n == 0 else 0)
PY
fi

cfg=$(grep -E '^(CONFIG_|# CONFIG_)' "$O/.config" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
printf 'KEY=5.4\nKREL=%s\nCONFIG=%s\nTAG=%s\n' "$krel" "$cfg" "$TAG" > "$D/KIT"
cat "$D/KIT"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -C "$W" -cf - kit-5.4 | xz -9e -T0 > /out/kit-5.4.tar.xz
ls -la /out/kit-5.4.tar.xz
sha256sum /out/kit-5.4.tar.xz
