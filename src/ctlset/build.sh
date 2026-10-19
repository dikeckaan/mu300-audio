#!/bin/sh
# Build ctlset as a static arm64 binary (no alsa-lib needed: it uses the kernel's ALSA ioctls directly).
#   src/ctlset/build.sh [OUT]      default: out/bin/ctlset (tools/make-extra.sh puts it in the extra's bin/)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${1:-$HERE/../../out/bin/ctlset}; mkdir -p "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 -v "$HERE":/w alpine:3.20 sh -c \
  'apk add -q gcc musl-dev linux-headers && gcc -O2 -s -static -o /w/ctlset.out /w/ctlset.c'
mv "$HERE/ctlset.out" "$OUT"; echo "built $OUT"
