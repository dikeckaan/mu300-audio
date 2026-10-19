"""mu300-audio-dsp finds the drivers it loads: the extra's set for the running kernel (modules/<release>/ next to its
bin/), and only when that set was built against the running kernel's own configuration (its KERNEL names the sha256 of
the settings, /proc/config.gz has the kernel's) - else where the releases up to mu300-linux v2026.10.19.1 kept them, or
none, with the reason. mu300-voice asks it the same."""
import gzip
import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import TOP, shells

DSP = TOP / 'device' / 'bin' / 'mu300-audio-dsp'
VOICE = TOP / 'device' / 'bin' / 'mu300-voice'
CONFIG = 'CONFIG_SND_SOC=m\n# CONFIG_FOO is not set\nCONFIG_LOCALVERSION=""\n'


def config_sum(text):
    lines = sorted(l for l in text.splitlines() if l.startswith(('CONFIG_', '# CONFIG_')))
    return hashlib.sha256(''.join(l + '\n' for l in lines).encode()).hexdigest()


class Drivers(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(['rm', '-rf', str(self.tmp)]))
        self.extra = self.tmp / 'extra' / 'audio'
        (self.extra / 'bin').mkdir(parents=True)
        self.lib = self.tmp / 'lib-modules'
        self.lib.mkdir()
        self.cfg = self.tmp / 'config.gz'
        with gzip.open(self.cfg, 'wt') as f:
            f.write('#\n# Automatically generated file; DO NOT EDIT.\n' + CONFIG)

    def put_set(self, krel='6.18.57', config=None):
        d = self.extra / 'modules' / krel
        d.mkdir(parents=True, exist_ok=True)
        (d / 'sprd_audcp_boot.ko').write_text('')
        (d / 'KERNEL').write_text(f'KEY=6.18\nKREL={krel}\nCONFIG={config or config_sum(CONFIG)}\nTAG=v2026.10.19.1\n')
        return d

    def run_dsp(self, shell, *args, **env):
        e = dict(os.environ, MU300_AUDIO_DIR=str(self.extra), MU300_LIB_MODULES=str(self.lib), MU300_KREL='6.18.57',
                 MU300_KCONFIG=str(self.cfg))
        e.update(env)
        return subprocess.run(shell + [str(DSP)] + list(args), capture_output=True, text=True, env=e)

    def test_the_set_built_for_this_kernel(self):
        d = self.put_set()
        for shell in shells():
            r = self.run_dsp(shell, 'drivers')
            self.assertEqual((r.returncode, r.stdout.strip()), (0, str(d)), r.stderr)

    def test_a_set_of_another_build_is_not_loaded(self):
        self.put_set(config='0' * 64)
        for shell in shells():
            r = self.run_dsp(shell, 'drivers')
            self.assertEqual(r.returncode, 1)
            self.assertIn('built for another build of it (mu300-linux v2026.10.19.1)', r.stderr)
            self.assertIn('mu300-extra install audio', r.stderr)
            # asked for anyway
            r = self.run_dsp(shell, 'drivers', MU300_AUDIO_ANY_BUILD='1')
            self.assertEqual(r.returncode, 0)
            # a kernel without /proc/config.gz cannot be told apart: not loaded
            r = self.run_dsp(shell, 'drivers', MU300_KCONFIG=str(self.tmp / 'none.gz'))
            self.assertEqual(r.returncode, 1)

    def test_a_set_for_another_kernel(self):
        self.put_set(krel='7.2.11')
        for shell in shells():
            r = self.run_dsp(shell, 'drivers')
            self.assertEqual(r.returncode, 1)
            self.assertIn('the audio extra has drivers for 7.2.11 and this is 6.18.57', r.stderr)

    def test_where_the_older_releases_kept_them(self):
        for sub, want in (('audio', 'audio'), ('extra', 'extra'), ('', '')):
            for shell in shells():
                (self.lib / sub).mkdir(exist_ok=True)
                (self.lib / sub / 'sprd_audcp_boot.ko').write_text('')
                r = self.run_dsp(shell, 'drivers')
                self.assertEqual((r.returncode, r.stdout.strip()), (0, str(self.lib / want).rstrip('/')))
                (self.lib / sub / 'sprd_audcp_boot.ko').unlink()

    def test_none(self):
        for shell in shells():
            r = self.run_dsp(shell, 'drivers')
            self.assertEqual(r.returncode, 1)
            self.assertIn('no audio drivers for 6.18.57 (mu300-extra install audio)', r.stderr)
            r = self.run_dsp(shell, 'status')
            self.assertIn('drivers:  none - no audio drivers', r.stdout)

    def test_the_settings_are_taken_as_the_kits_take_them(self):
        # kernel/kits/make-kit-*.sh: grep -E '^(CONFIG_|# CONFIG_)' .config | LC_ALL=C sort | sha256sum
        for f in ('make-kit-mainline.sh', 'make-kit-5.4.sh'):
            self.assertIn("grep -E '^(CONFIG_|# CONFIG_)' \"$O/.config\" | LC_ALL=C sort | sha256sum",
                          (TOP / 'kernel' / 'kits' / f).read_text(), f)
        self.assertIn("grep -E '^(CONFIG_|# CONFIG_)' | LC_ALL=C sort |", DSP.read_text())

    def test_mu300_voice_asks_mu300_audio_dsp(self):
        src = VOICE.read_text()
        self.assertIn('mu300-audio-dsp drivers', src)
        self.assertIn('export PATH="$HERE:$PATH', src)


if __name__ == '__main__':
    unittest.main()
