#!/bin/sh
# Build pcmhost as a static arm64 binary (no alsa-lib needed: it uses the kernel's ALSA ioctls directly).
#   src/pcmhost/build.sh [OUT]      default: out/bin/pcmhost (tools/make-extra.sh puts it in the extra's bin/)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${1:-$HERE/../../out/bin/pcmhost}; mkdir -p "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 -v "$HERE":/w alpine:3.20 sh -c \
  'apk add -q gcc musl-dev linux-headers && gcc -O2 -s -static -o /w/pcmhost.out /w/pcmhost.c'
mv "$HERE/pcmhost.out" "$OUT"; echo "built $OUT"
