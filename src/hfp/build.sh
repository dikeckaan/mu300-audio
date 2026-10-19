#!/bin/sh
# Build mu300-hfp as a static arm64 binary (no libbluetooth needed: it uses the kernel's Bluetooth sockets directly).
#   src/hfp/build.sh [OUT]      default: out/bin/mu300-hfp (tools/make-extra.sh puts it in the extra's bin/)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${1:-$HERE/../../out/bin/mu300-hfp}; mkdir -p "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 -v "$HERE":/w alpine:3.20 sh -c \
  'apk add -q gcc musl-dev linux-headers && gcc -Wall -O2 -s -static -o /w/mu300-hfp.out /w/mu300-hfp.c'
mv "$HERE/mu300-hfp.out" "$OUT"; echo "built $OUT"
