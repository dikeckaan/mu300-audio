#!/bin/sh
# Build the release files of the audio extra:
#   tools/make-extra.sh OUTDIR [TAG]      (TAG: vMAJOR.MINOR.PATCH, default v0.0.0-dev)
#   OUTDIR/mu300-audio-5.4.tar.gz    the audio extra for each kernel of kernel/kits/kits.lock: the call-audio stack with
#   OUTDIR/mu300-audio-6.18.tar.gz   that kernel's drivers (modules/<release>/, built by kernel/build.sh against the
#   OUTDIR/mu300-audio-7.2.tar.gz    kernel's own build); mu300-extra installs the one of the kernel the device uses,
#                                    and mu300-update takes the other one when the kernel changes
#   OUTDIR/VERSIONS                  extra, version, bytes, kernel release, asset - TSV
#   OUTDIR/SHA256SUMS                all of the above, in sha256sum's format
# Inputs: out/modules/KEY/ (kernel/build.sh KEY) and out/bin/{pcmhost,ctlset,mu300-hfp} (src/*/build.sh, static
# arm64). MU300_AUDIO_FAKE=1 puts small stand-ins in place of both (tests/, no Docker).
# Each unpacks into mu300-extra's directory for it ($DISK/extra/audio): files and directories only, owned by root,
# modes set here (programs and hooks 755, the rest 644), the same bytes from macOS and Linux for the same inputs.
# Besides its files: VERSION and release (= TAG), name (audio), requires (the mu300-linux release it needs), kernel
# (the kernel choice it is for: 5.4, 6.18 or 7.2), components, and manifest (the sha256 of every other file).
# No firmware: the DSP image is fetched on the device at install time (mu300-extra install audio), checked
# against its pinned sha256, and never part of a release here.
set -eu
OUT=${1:?usage: tools/make-extra.sh OUTDIR [TAG]}
TAG=${2:-v0.0.0-dev}
case $TAG in v[0-9]*) ;; *) echo "TAG is vMAJOR.MINOR.PATCH" >&2; exit 2 ;; esac
TOP=$(cd "$(dirname "$0")/.." && pwd)
# the first mu300-linux release whose kernels these drivers are built for: the kits' own (kits.lock), the same for all
REQUIRES="mu300-linux $(awk '!/^#/ && NF {print $5; exit}' "$TOP/kernel/kits/kits.lock")"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
FAKE=${MU300_AUDIO_FAKE:-}
KEYS=$(awk '!/^#/ && NF {print $1}' "$TOP/kernel/kits/kits.lock")

for KEY in $KEYS; do
    set -- $(awk -v k="$KEY" '$1 == k' "$TOP/kernel/kits/kits.lock")
    KREL=$2 CONFIG=$3 KTAG=$5
    d=$tmp/$KEY
    mkdir -p "$d/bin" "$d/modules/$KREL" "$d/service/systemd" "$d/service/procd" "$d/etc" "$d/hooks" "$d/licence"
    cp "$TOP/device/bin/mu300-audio-dsp" "$TOP/device/bin/mu300-voice" "$d/bin/"
    cp "$TOP/device/service/systemd/mu300-audio.service" "$TOP/device/service/systemd/mu300-voice.service" "$d/service/systemd/"
    cp "$TOP/device/service/procd/mu300-audio" "$TOP/device/service/procd/mu300-voice" "$d/service/procd/"
    cp "$TOP/device/etc/modprobe-mu300-audio.conf" "$TOP/device/etc/voice.conf.example" "$d/etc/"
    cp "$TOP/hooks/link" "$TOP/hooks/unlink" "$d/hooks/"
    cp "$TOP/LICENSE" "$d/licence/LICENSE"; cp "$TOP/kernel/COPYING" "$d/licence/COPYING"
    if [ "$FAKE" = 1 ]; then
        for b in pcmhost ctlset mu300-hfp; do printf '#!/bin/sh\necho "%s (fake for tests)"\n' "$b" > "$d/bin/$b"; done
        for m in audio_mem agdsp_access audio_sipc sprd_audcp_boot snd-soc-sprd-card; do
            printf 'vermagic=%s SMP\n' "$KREL" > "$d/modules/$KREL/$m.ko"
        done
        printf 'KEY=%s\nKREL=%s\nCONFIG=%s\nTAG=%s\n' "$KEY" "$KREL" "$CONFIG" "$KTAG" > "$d/modules/$KREL/KERNEL"
    else
        for b in pcmhost ctlset mu300-hfp; do
            [ -s "$TOP/out/bin/$b" ] || { echo "no out/bin/$b (src/*/build.sh)" >&2; exit 1; }
            cp "$TOP/out/bin/$b" "$d/bin/"
        done
        m=$TOP/out/modules/$KEY
        grep -qx "KREL=$KREL" "$m/KERNEL" 2>/dev/null && grep -qx "CONFIG=$CONFIG" "$m/KERNEL" ||
            { echo "out/modules/$KEY is not the kernel kits.lock names (kernel/build.sh $KEY)" >&2; exit 1; }
        cp "$m"/*.ko "$m/KERNEL" "$d/modules/$KREL/"
    fi
    echo "$TAG" > "$d/VERSION"; echo "$TAG" > "$d/release"; echo audio > "$d/name"; echo "$REQUIRES" > "$d/requires"
    echo "$KEY" > "$d/kernel"
    printf 'mu300-audio %s\nkernel %s (%s, mu300-linux %s)\n' "$TAG" "$KEY" "$KREL" "$KTAG" > "$d/components"
done

# python's tarfile, not tar: the same root-owned archive from macOS (bsdtar) and Linux (GNU tar), sorted, with fixed
# modes and times (SOURCE_DATE_EPOCH, else the last commit's time, else 0) and a gzip header without a time or name
args=
for KEY in $KEYS; do args="$args $tmp/$KEY $OUT/mu300-audio-$KEY.tar.gz"; done
python3 - "${SOURCE_DATE_EPOCH:-$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || echo 0)}" $args <<'PY'
import gzip, hashlib, io, os, sys, tarfile
mtime = int(sys.argv[1] or 0)
def executable(rel):
    return rel.startswith(('bin/', 'hooks/', 'service/procd/'))
def build(src, out):
    files = []
    for d, ds, fs in os.walk(src):
        ds.sort()
        for f in sorted(fs):
            files.append(os.path.relpath(os.path.join(d, f), src))
    with open(os.path.join(src, 'manifest'), 'w') as m:
        for rel in sorted(files):
            m.write('%s  ./%s\n' % (hashlib.sha256(open(os.path.join(src, rel), 'rb').read()).hexdigest(), rel))
    files.append('manifest')
    entries = set()
    for rel in files:
        parts = rel.split('/')
        for i in range(1, len(parts)):
            entries.add(('/'.join(parts[:i]), True))
        entries.add((rel, False))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as t:
        for rel, isdir in sorted(entries):
            ti = tarfile.TarInfo('./' + rel)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = mtime
            if isdir:
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                t.addfile(ti)
            else:
                data = open(os.path.join(src, rel), 'rb').read()
                ti.size, ti.mode = len(data), 0o755 if executable(rel) else 0o644
                t.addfile(ti, io.BytesIO(data))
    with open(out, 'wb') as f, gzip.GzipFile(filename='', mode='wb', fileobj=f, mtime=0, compresslevel=9) as g:
        g.write(buf.getvalue())
args = sys.argv[2:]
for i in range(0, len(args), 2):
    build(args[i], args[i + 1])
PY
( cd "$OUT"
  for KEY in $KEYS; do
      f=mu300-audio-$KEY.tar.gz
      printf 'audio\t%s\t%s\t%s\t%s\n' "$TAG" "$(wc -c < "$f" | tr -d ' ')" "$(awk -v k="$KEY" '$1 == k {print $2}' "$TOP/kernel/kits/kits.lock")" "$f"
  done > VERSIONS
  for f in $(for KEY in $KEYS; do echo "mu300-audio-$KEY.tar.gz"; done) VERSIONS; do
      s=$(shasum -a 256 "$f" 2>/dev/null || sha256sum "$f"); printf '%s  %s\n' "${s%% *}" "$f"
  done > SHA256SUMS )
for KEY in $KEYS; do echo "mu300-audio-$KEY.tar.gz ($TAG): $(du -h "$OUT/mu300-audio-$KEY.tar.gz" | cut -f1)"; done
echo "SHA256SUMS: $OUT/SHA256SUMS"
