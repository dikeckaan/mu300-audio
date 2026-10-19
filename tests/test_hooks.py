"""hooks/link and hooks/unlink: the audio extra into a system and out of it again, for Ubuntu (systemd) and OpenWrt
(procd), under every shell they run with. What a system had there itself (a release up to mu300-linux v2026.10.19.1
carried the stack, mu300-audio's old installer put its own tools there) moves aside and comes back; the firmware the
extra fetched goes into a system without one and out again only when it is still that copy."""
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import TOP, ShellTest

CMDS = ('mu300-audio-dsp', 'mu300-voice', 'pcmhost', 'ctlset', 'mu300-hfp')


class Hooks(ShellTest):
    def setUp(self):
        super().setUp()
        self.disk = self.tmp / 'disk'
        out = self.tmp / 'rel'
        subprocess.run(['sh', str(TOP / 'tools' / 'make-extra.sh'), str(out)], check=True, capture_output=True,
                       env=dict(os.environ, MU300_AUDIO_FAKE='1'))
        self.extra = self.disk / 'extra' / 'audio'
        self.extra.mkdir(parents=True)
        subprocess.run(['tar', '-xzf', str(out / 'mu300-audio-6.18.tar.gz'), '-C', str(self.extra)], check=True)
        self.fw = self.disk / 'extra' / '.audio-firmware' / 'agdsp.bin'

    def system(self, kind, old=False):
        r = self.tmp / kind
        shutil.rmtree(r, ignore_errors=True)
        (r / 'etc/mu300').mkdir(parents=True)
        if kind == 'openwrt':
            (r / 'etc/openwrt_release').write_text('DISTRIB_ID=OpenWrt\n')
        if old:
            # what a release up to v2026.10.19.1 had of its own
            (r / 'opt/mu300/bin').mkdir(parents=True)
            for c in ('mu300-audio-dsp', 'mu300-voice'):
                (r / 'opt/mu300/bin' / c).write_text('#!/bin/sh\necho old\n')
            if kind == 'openwrt':
                (r / 'etc/init.d').mkdir(parents=True)
                (r / 'etc/init.d/mu300-audio').write_text('old init\n')
            else:
                (r / 'etc/systemd/system').mkdir(parents=True)
                (r / 'etc/systemd/system/mu300-audio.service').write_text('old unit\n')
                (r / 'etc/modprobe.d').mkdir(parents=True)
                (r / 'etc/modprobe.d/mu300-audio.conf').write_text('old conf\n')
        return r

    def hook(self, shell, name, root):
        return self.script(shell, self.extra / 'hooks' / name, root, MU300_DISK=self.disk, MU300_EXTRA_DIR=self.extra,
                           MU300_AUDIO_LIVE='0')

    def test_a_card_that_is_down_is_started_even_when_no_link_changed(self):
        # F50-B, 7.3: the boot's mu300-audio failed (the extra was 7.2's); installing the 7.3 one changed no link
        bin_ = self.tmp / 'bin'
        bin_.mkdir()
        log = self.tmp / 'systemctl.log'
        (bin_ / 'systemctl').write_text(f'#!/bin/sh\necho "$*" >> {log}\n')
        (bin_ / 'systemctl').chmod(0o755)
        cards = self.tmp / 'cards'
        for shell in self.each_shell():
            r = self.system('ubuntu')
            env = dict(MU300_DISK=self.disk, MU300_EXTRA_DIR=self.extra, MU300_AUDIO_LIVE='1', MU300_ASOUND_CARDS=cards,
                       PATH=f'{bin_}:{os.environ["PATH"]}')
            self.assertEqual(self.script(shell, self.extra / 'hooks' / 'link', r, **env).returncode, 0)
            # linked already, the card up: nothing is started
            log.unlink(missing_ok=True)
            cards.write_text(' 1 [sprdphonesc2730]: sprdphone-sc273 - sprdphone-sc2730\n')
            self.assertEqual(self.script(shell, self.extra / 'hooks' / 'link', r, **env).returncode, 0)
            self.assertFalse(log.exists() and 'restart mu300-audio' in log.read_text())
            # linked already, the card down: it is started
            cards.write_text(' 0 [Loopback       ]: Loopback - Loopback\n')
            self.assertEqual(self.script(shell, self.extra / 'hooks' / 'link', r, **env).returncode, 0)
            self.assertIn('--no-block restart mu300-audio', log.read_text())

    def test_ubuntu_link_and_unlink(self):
        for shell in self.each_shell():
            r = self.system('ubuntu', old=True)
            p = self.hook(shell, 'link', r)
            self.assertEqual(p.returncode, 0, p.stderr)
            for c in CMDS:
                self.assertEqual(os.readlink(r / 'opt/mu300/bin' / c), str(self.extra / 'bin' / c))
            self.assertEqual((r / 'opt/mu300/bin/mu300-voice.builtin').read_text(), '#!/bin/sh\necho old\n')
            self.assertEqual((r / 'etc/systemd/system/mu300-audio.service.builtin').read_text(), 'old unit\n')
            for s in ('mu300-audio', 'mu300-voice'):
                self.assertEqual((r / f'etc/systemd/system/{s}.service').read_text(),
                                 (TOP / f'device/service/systemd/{s}.service').read_text())
                self.assertEqual(os.readlink(r / f'etc/systemd/system/multi-user.target.wants/{s}.service'),
                                 f'/etc/systemd/system/{s}.service')
            self.assertEqual((r / 'etc/modprobe.d/mu300-audio.conf').read_text(),
                             (TOP / 'device/etc/modprobe-mu300-audio.conf').read_text())
            self.assertTrue((r / 'etc/mu300/voice.conf.example').is_file())
            # again: nothing changes, nothing more is moved aside
            before = sorted(str(p.relative_to(r)) for p in r.rglob('*'))
            p = self.hook(shell, 'link', r)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(sorted(str(p.relative_to(r)) for p in r.rglob('*')), before)
            # out again: the system's own back, the enable links of what did not come back gone
            p = self.hook(shell, 'unlink', r)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual((r / 'opt/mu300/bin/mu300-voice').read_text(), '#!/bin/sh\necho old\n')
            self.assertFalse(os.path.lexists(r / 'opt/mu300/bin/pcmhost'))
            self.assertEqual((r / 'etc/systemd/system/mu300-audio.service').read_text(), 'old unit\n')
            self.assertEqual((r / 'etc/modprobe.d/mu300-audio.conf').read_text(), 'old conf\n')
            self.assertFalse(os.path.lexists(r / 'etc/systemd/system/mu300-voice.service'))
            self.assertFalse(os.path.lexists(r / 'etc/systemd/system/multi-user.target.wants/mu300-voice.service'))
            self.assertFalse(any(p.name.endswith('.builtin') for p in r.rglob('*')))
            # and again: a system that is not linked is left alone
            p = self.hook(shell, 'unlink', r)
            self.assertEqual(p.returncode, 0, p.stderr)

    def test_openwrt_link_and_unlink(self):
        for shell in self.each_shell():
            r = self.system('openwrt')
            p = self.hook(shell, 'link', r)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(os.readlink(r / 'etc/rc.d/S14mu300-audio'), '../init.d/mu300-audio')
            self.assertEqual(os.readlink(r / 'etc/rc.d/S96mu300-voice'), '../init.d/mu300-voice')
            self.assertTrue(os.access(r / 'etc/init.d/mu300-audio', os.X_OK))
            self.assertFalse((r / 'etc/systemd').exists())
            p = self.hook(shell, 'unlink', r)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertFalse(os.path.lexists(r / 'etc/rc.d/S14mu300-audio'))
            self.assertFalse(os.path.lexists(r / 'etc/init.d/mu300-voice'))
            self.assertFalse(os.path.lexists(r / 'opt/mu300/bin/mu300-audio-dsp'))

    @staticmethod
    def enabled(r, s):
        links = list((r / 'etc/rc.d').glob(f'S*{s}')) if (r / 'etc/rc.d').is_dir() else []
        w = r / f'etc/systemd/system/multi-user.target.wants/{s}.service'
        return links + ([w] if os.path.lexists(w) else [])

    def test_a_call_follower_of_the_systems_own_keeps_its_state(self):
        # mu300-audio's old installer put a mu300-voice service there; on this system it was disabled since
        for shell in self.each_shell():
            for kind in ('openwrt', 'ubuntu'):
                r = self.system(kind)
                if kind == 'openwrt':
                    (r / 'etc/init.d').mkdir(parents=True)
                    (r / 'etc/init.d/mu300-voice').write_text('old\n')
                else:
                    (r / 'etc/systemd/system').mkdir(parents=True)
                    (r / 'etc/systemd/system/mu300-voice.service').write_text('old\n')
                p = self.hook(shell, 'link', r)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.enabled(r, 'mu300-voice'), [], kind)
                # mu300-audio is enabled all the same
                self.assertEqual(len(self.enabled(r, 'mu300-audio')), 1, kind)
                # a later link leaves the enable links as they are: disabled by hand, it stays so
                for l in self.enabled(r, 'mu300-audio'):
                    l.unlink()
                p = self.hook(shell, 'link', r)
                self.assertEqual(self.enabled(r, 'mu300-audio'), [], kind)

    def test_the_firmware_goes_into_a_system_without_one_and_out_again(self):
        self.fw.parent.mkdir(parents=True)
        self.fw.write_bytes(b'AUDCP' * 100)
        sha = hashlib.sha256(self.fw.read_bytes()).hexdigest()
        for shell in self.each_shell():
            r = self.system('ubuntu')
            mine = self.system('openwrt')
            (mine / 'lib/firmware').mkdir(parents=True)
            (mine / 'lib/firmware/agdsp.bin').write_bytes(b'my own')
            for root in (r, mine):
                p = self.hook(shell, 'link', root)
                self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual((r / 'lib/firmware/agdsp.bin').read_bytes(), self.fw.read_bytes())
            self.assertEqual((r / 'etc/mu300/agdsp.sha256').read_text(), f'{sha}  agdsp.bin\n')
            self.assertEqual((r / 'etc/mu300/agdsp.extra').read_text(), sha + '\n')
            self.assertEqual((mine / 'lib/firmware/agdsp.bin').read_bytes(), b'my own')     # never touched
            self.assertFalse((mine / 'etc/mu300/agdsp.extra').exists())
            for root in (r, mine):
                p = self.hook(shell, 'unlink', root)
                self.assertEqual(p.returncode, 0, p.stderr)
            self.assertFalse((r / 'lib/firmware/agdsp.bin').exists())
            self.assertFalse((r / 'etc/mu300/agdsp.sha256').exists())
            self.assertEqual((mine / 'lib/firmware/agdsp.bin').read_bytes(), b'my own')
            # a copy the user replaced since stays
            p = self.hook(shell, 'link', r)
            (r / 'lib/firmware/agdsp.bin').write_bytes(b'replaced')
            p = self.hook(shell, 'unlink', r)
            self.assertEqual((r / 'lib/firmware/agdsp.bin').read_bytes(), b'replaced')
            self.assertFalse((r / 'etc/mu300/agdsp.extra').exists())

    def test_refuses_what_is_not_the_audio_extra(self):
        (self.extra / 'bin/mu300-audio-dsp').unlink()
        for shell in self.each_shell():
            p = self.hook(shell, 'link', self.system('ubuntu'))
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('is not the audio extra', p.stderr)


if __name__ == '__main__':
    unittest.main()
