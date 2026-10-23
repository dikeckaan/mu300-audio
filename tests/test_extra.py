"""tools/make-extra.sh: the release files mu300-extra installs - one tarball per kernel of kernel/kits/kits.lock, in the
layout mu300-update's extra_unpack takes from a module (plain names, at most four levels, files and directories only,
./VERSION, ./requires, ./kernel, ./manifest, the hooks), the same bytes for the same inputs, and no firmware."""
import hashlib
import io
import os
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

from helpers import TOP

LOCK = TOP / 'kernel' / 'kits' / 'kits.lock'
ENTRY = re.compile(r'\.|\./[A-Za-z0-9_+-][A-Za-z0-9._+-]*(/[A-Za-z0-9_+-][A-Za-z0-9._+-]*){0,3}')   # mu300-update MODULE_ENTRY


def kits():
    return [l.split() for l in LOCK.read_text().splitlines() if l.strip() and not l.startswith('#')]


def primaries():
    """the first line of each kernel: the kernel of the current mu300-linux release (later lines: earlier builds)"""
    seen = {}
    for k in kits():
        seen.setdefault(k[0], k)
    return list(seen.values())


def tag_key(tag):
    return tuple(int(x) for x in tag[1:].split('.'))


class Release(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.out = cls.tmp / 'a'
        env = dict(os.environ, MU300_AUDIO_FAKE='1', SOURCE_DATE_EPOCH='1700000000')
        subprocess.run(['sh', str(TOP / 'tools/make-extra.sh'), str(cls.out), 'v1.2.3'], check=True, capture_output=True, env=env)
        subprocess.run(['sh', str(TOP / 'tools/make-extra.sh'), str(cls.tmp / 'b'), 'v1.2.3'], check=True, capture_output=True, env=env)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['rm', '-rf', str(cls.tmp)])

    def test_one_tarball_per_kernel_of_the_lock(self):
        keys = [k[0] for k in primaries()]
        self.assertEqual(keys, ['5.4', '6.18', '7.2', '7.3'])
        names = sorted(p.name for p in self.out.iterdir())
        self.assertEqual(names, sorted([f'mu300-audio-{k}.tar.gz' for k in keys] + ['SHA256SUMS', 'VERSIONS']))
        sums = dict(reversed(l.split('  ')) for l in (self.out / 'SHA256SUMS').read_text().splitlines())
        for n, h in sums.items():
            self.assertEqual(hashlib.sha256((self.out / n).read_bytes()).hexdigest(), h)

    def test_the_layout_extra_unpack_takes(self):
        oldest = min((k[4] for k in kits()), key=tag_key)
        for key, krel, config, _, tag in primaries():
            with tarfile.open(self.out / f'mu300-audio-{key}.tar.gz') as t:
                members = t.getmembers()
                for m in members:
                    self.assertTrue(m.isfile() or m.isdir(), m.name)
                    self.assertRegex(m.name.rstrip('/'), ENTRY)
                    self.assertEqual((m.uid, m.gid), (0, 0))
                    if m.isfile():
                        self.assertEqual(m.mode, 0o755 if m.name.startswith(('./bin/', './hooks/', './service/procd/')) else 0o644, m.name)
                files = {m.name: t.extractfile(m).read() for m in members if m.isfile()}
            self.assertEqual(files['./VERSION'], b'v1.2.3\n')
            self.assertEqual(files['./release'], b'v1.2.3\n')
            self.assertEqual(files['./name'], b'audio\n')
            self.assertEqual(files['./kernel'], f'{key}\n'.encode())
            self.assertEqual(files['./requires'], f'mu300-linux {oldest}\n'.encode())
            self.assertIn(f'./modules/{krel}/KERNEL', files)
            self.assertIn(f'CONFIG={config}\n'.encode(), files[f'./modules/{krel}/KERNEL'])
            # the current set, and beside it only the earlier builds kits.lock names (of this release or an earlier one)
            # the earlier builds of this kernel beside it, each under its CONFIG's first 12 digits
            sets = {n.split('/')[2] for n in files if n.startswith('./modules/')}
            earlier = [k for k in kits() if k[0] == key][1:]
            self.assertEqual(sets, {krel} | {f'{k[1]}+{k[2][:12]}' for k in earlier})
            for k in earlier:
                self.assertIn(f'CONFIG={k[2]}\nTAG={k[4]}\n'.encode(), files[f'./modules/{k[1]}+{k[2][:12]}/KERNEL'])
            for b in ('mu300-audio-dsp', 'mu300-voice', 'pcmhost', 'ctlset', 'mu300-hfp'):
                self.assertIn(f'./bin/{b}', files)
            for h in ('link', 'unlink'):
                self.assertEqual(files[f'./hooks/{h}'], (TOP / 'hooks' / h).read_bytes())
            # the manifest lists every other file with its hash
            man = dict(reversed(l.split('  ')) for l in files['./manifest'].decode().splitlines())
            self.assertEqual(set(man), set(files) - {'./manifest'})
            for n, h in man.items():
                self.assertEqual(hashlib.sha256(files[n]).hexdigest(), h, n)
            # no firmware: fetched on the device, never part of a release
            for n, data in files.items():
                self.assertNotRegex(n.lower(), r'agdsp\.(bin|img)|firmware')
                self.assertLess(len(data), 1 << 20, n)

    def test_the_same_inputs_make_the_same_bytes(self):
        for f in self.out.iterdir():
            self.assertEqual(f.read_bytes(), (self.tmp / 'b' / f.name).read_bytes(), f.name)

    def test_versions(self):
        lines = (self.out / 'VERSIONS').read_text().splitlines()
        self.assertEqual([l.split('\t')[0] for l in lines], ['audio'] * len(primaries()))
        self.assertEqual([l.split('\t')[3] for l in lines], [k[1] for k in primaries()])


class Lock(unittest.TestCase):
    def test_every_kernel_is_pinned(self):
        for key, krel, config, kit, tag in kits():
            self.assertRegex(config, r'^[0-9a-f]{64}$')
            self.assertRegex(kit, r'^[0-9a-f]{64}$')
            self.assertRegex(tag, r'^v\d{4}\.\d{2}\.\d{2}(\.\d+)?$')
            self.assertTrue(krel.startswith(key + '.'), krel)

    def test_one_set_per_build(self):
        # a kernel's lines: the current build first, then earlier ones - of the same release with another configuration,
        # or of an earlier stable release (6.18.57 beside 6.18.58, with the same configuration). Each earlier set goes to
        # modules/<release>+<12 digits of CONFIG>/ in the tarball and to out/modules/KEY+<12 digits> in the build: both
        # names must be unique
        for key in {k[0] for k in kits()}:
            lines = [k for k in kits() if k[0] == key]
            self.assertEqual(len({(k[1], k[2][:12]) for k in lines}), len(lines), key)
            self.assertEqual(len({k[2][:12] for k in lines[1:]}), len(lines) - 1, key)
            self.assertEqual(sorted(lines, key=lambda k: tag_key(k[4]), reverse=True), lines, key)

    def test_build_takes_a_kit_only_with_its_hash(self):
        src = (TOP / 'kernel' / 'build.sh').read_text()
        self.assertIn('[ "$got" = "$KITSHA" ] ||', src)
        self.assertIn('releases/download/kits-$TAG/kit-$KEY.tar.xz', src)
        self.assertIn('case $v in "$KREL "*)', src)


if __name__ == '__main__':
    unittest.main()
