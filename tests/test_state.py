"""device/state.sh: the install's list of files and its backups are acted on as root by the uninstaller, so they are
read only from a directory root alone can write, and the list may only name paths install.sh installs.
Also install.sh --download-firmware: only the pinned image is ever used. Run: python3 -m unittest discover tests"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
STATE = TOP / 'device' / 'state.sh'
PINNED = '378ceea78dbf013e10625e71efd6fab487d727e371884ae8daf078da2828b937'


def call(fn, *args, uid=None):
    env = dict(os.environ)
    if uid is not None:
        env['MU300_AUDIO_STATE_UID'] = str(uid)
    r = subprocess.run(['sh', '-c', '. "$0"; %s "$@"' % fn, str(STATE), *args], capture_output=True, text=True,
                       env=env)
    return r.returncode == 0


class Ownership(unittest.TestCase):
    def test_owner_and_mode(self):
        me = os.getuid()
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'state'; p.mkdir()
            p.chmod(0o755)
            self.assertTrue(call('owned', str(p), uid=me))
            if me != 0:
                self.assertFalse(call('owned', str(p), uid=0), 'not root-owned')
            for mode in (0o775, 0o757, 0o777):
                p.chmod(mode)
                self.assertFalse(call('owned', str(p), uid=me), oct(mode))
            p.chmod(0o755)
            link = Path(d) / 'link'; link.symlink_to(p)
            self.assertFalse(call('owned', str(link), uid=me), 'symlink')

    def test_world_writable_parent_refused(self):
        # /tmp is world-writable (or, on macOS, a symlink): a state directory under it never counts
        d = tempfile.mkdtemp(dir='/tmp')
        try:
            os.chmod(d, 0o755)
            self.assertFalse(call('trusted_path', d, uid=os.getuid()))
        finally:
            os.rmdir(d)

    def test_root_owned_chain_accepted(self):
        self.assertTrue(call('trusted_path', '/usr/bin', uid=0))


class Manifest(unittest.TestCase):
    def check(self, lines):
        with tempfile.TemporaryDirectory() as d:
            m = Path(d) / 'installed'
            m.write_text(''.join(l + '\n' for l in lines))
            r = subprocess.run(['sh', '-c', '. "$0"; MANIFEST=$1; manifest_ok', str(STATE), str(m)],
                               capture_output=True, text=True)
            return r.returncode == 0

    def test_known_paths(self):
        self.assertTrue(self.check(['/lib/modules/5.4.254-gb50db5b6224c/audio', '/opt/mu300/bin/pcmhost',
                                    '/lib/firmware/agdsp.bin', '/etc/mu300/voice.conf', '/etc/init.d/mu300-voice']))

    def test_anything_else_refused(self):
        for bad in ('/etc/shadow', '/', '/opt/mu300/bin/../../../etc/passwd', '/lib/modules/x/audio',
                    '/opt/mu300/bin/pcmhost ', 'relative/path', '/etc/init.d/mu300-voice/../dropbear'):
            self.assertFalse(self.check(['/opt/mu300/bin/pcmhost', bad]), bad)

    def test_scripts_check_before_acting(self):
        inst = (TOP / 'device' / 'remote-install.sh').read_text()
        un = (TOP / 'device' / 'remote-uninstall.sh').read_text()
        for src in (inst, un):
            self.assertIn('. "$SRC/state.sh"', src)
            self.assertIn('state_ok || exit 1', src)
            self.assertIn('manifest_ok || exit 1', src)
        # the old OpenWrt migration read a list from /var/lib (tmpfs under /tmp there): gone
        self.assertNotIn('/var/lib/mu300-audio "$STATE"', inst)
        self.assertLess(un.index('manifest_ok || exit 1'), un.index('rm -rf "$p"'))


class DownloadFirmware(unittest.TestCase):
    def run_install(self, fake_sum=None):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = d / 'bin'; b.mkdir()
            served = d / 'served.bin'
            served.write_bytes(b'SharkL5_AUDCP_2022Y_VER_2548\0' + bytes(1048576))
            (b / 'curl').write_text('#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && out=$2; shift; done\n'
                                    'echo "$1" > "%s/url"\ncp "%s" "$out"\n' % (d, served))
            (b / 'ssh').write_text('#!/bin/sh\ntouch "%s/ssh-called"\ncat >/dev/null\n' % d)
            if fake_sum:
                (b / 'sha256sum').write_text('#!/bin/sh\necho "%s  $1"\n' % fake_sum)
            for f in b.iterdir():
                f.chmod(0o755)
            env = dict(os.environ, PATH='%s:/usr/bin:/bin' % b)
            r = subprocess.run(['sh', str(TOP / 'install.sh'), '--download-firmware', '--host', 'root@192.0.2.1'],
                               capture_output=True, text=True, env=env, cwd=d)
            return r, (d / 'ssh-called').exists(), (d / 'url').read_text().strip()

    def test_mismatch_refused_before_the_device(self):
        r, ssh, url = self.run_install()
        self.assertEqual(r.returncode, 1)
        self.assertIn('refused', r.stderr)
        self.assertFalse(ssh)
        self.assertEqual(url, 'https://github.com/dikeckaan/mu300-audio-firmware/releases/download/v1.0/agdsp.bin')

    def test_pinned_image_goes_on(self):
        r, ssh, url = self.run_install(fake_sum=PINNED)
        self.assertTrue(ssh, r.stderr)
        self.assertIn('ZTE Voyage 41S', r.stdout)


if __name__ == '__main__':
    unittest.main()
