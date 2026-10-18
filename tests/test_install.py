"""Checks install.sh makes on this computer before anything reaches a device: a wrong firmware file or headset
address stops it there. Run: python3 -m unittest discover tests"""
import subprocess
import tempfile
import unittest
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
INSTALL = TOP / 'install.sh'


def run(*args):
    # an address nothing answers on: a check that passed would fail on ssh instead, and say so
    return subprocess.run(['sh', str(INSTALL), *args, '--host', 'root@192.0.2.1'], capture_output=True, text=True,
                          timeout=60)


class FirmwareChecks(unittest.TestCase):
    def test_missing_file(self):
        r = run('--firmware', '/nonexistent/agdsp.img')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('no file', r.stderr)

    def test_too_small(self):
        with tempfile.NamedTemporaryFile() as f:
            f.write(b'SharkL5_AUDCP_test' + bytes(1000)); f.flush()
            r = run('--firmware', f.name)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('1-7 MiB', r.stderr)

    def test_no_audcp_header(self):
        with tempfile.NamedTemporaryFile() as f:
            f.write(bytes(6291456)); f.flush()
            r = run('--firmware', f.name)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('no AUDCP header', r.stderr)

    def test_bad_headset_address(self):
        r = run('--headset', 'not-an-address')
        self.assertEqual(r.returncode, 2)
        self.assertIn('AA:BB:CC:DD:EE:FF', r.stderr)

    def test_unknown_option(self):
        self.assertEqual(run('--frimware', 'x').returncode, 2)


class Payload(unittest.TestCase):
    def test_modules_and_tools(self):
        mods = list((TOP / 'kernel' / 'modules' / '5.4.254-gb50db5b6224c').glob('*.ko'))
        self.assertEqual(len(mods), 23)
        for t in ('pcmhost', 'ctlset', 'mu300-hfp'):
            self.assertEqual((TOP / 'device' / 'bin' / t).read_bytes()[:4], b'\x7fELF', t)

    def test_no_firmware_or_vendor_files(self):
        out = subprocess.run(['git', 'ls-files'], cwd=TOP, capture_output=True, text=True).stdout.split()
        for f in out:
            self.assertFalse(f.endswith(('.img', '.bin', '.xml', '.pac')), f)
            self.assertFalse(f.startswith(('firmware/', 'params/', 'local/')), f)


if __name__ == '__main__':
    unittest.main()
