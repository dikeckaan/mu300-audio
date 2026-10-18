#!/bin/sh
# Build pcmhost as a static arm64 binary (no alsa-lib needed: it uses the kernel's ALSA ioctls directly).
#   src/pcmhost/build.sh [OUT]      default: device/bin/pcmhost (install.sh puts it in /opt/mu300/bin)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${1:-$HERE/../../device/bin/pcmhost}
docker run --rm --platform linux/arm64 -v "$HERE":/w alpine sh -c \
  'apk add -q gcc musl-dev linux-headers && gcc -O2 -s -static -o /w/pcmhost.out /w/pcmhost.c'
mv "$HERE/pcmhost.out" "$OUT"; echo "built $OUT"
