"""The prebuilt 5.4 drivers carry their patches: audio_sipc.ko drops a DSP reply nobody waited for instead of failing
the next command with it (kernel/patches/audio-sipc-stale-reply.patch). Run: python3 -m unittest discover tests"""
import re
import unittest
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
MODS = TOP / 'kernel' / 'modules' / '5.4.254-gb50db5b6224c'
PATCHES = TOP / 'kernel' / 'patches'


class StaleReply(unittest.TestCase):
    def test_patch_and_module(self):
        patch = (PATCHES / 'audio-sipc-stale-reply.patch').read_text()
        self.assertIn('+++ b/sprd_audio/audiosipc/audio-sipc.c', patch)
        self.assertIn('dropped a stale reply', patch)
        ko = (MODS / 'audio_sipc.ko').read_bytes()
        self.assertIn(b'dropped a stale reply', ko)
        self.assertIn(b'vermagic=5.4.254-gb50db5b6224c ', ko)

    def test_readme_counts_the_patches(self):
        n = len(list(PATCHES.glob('*.patch')))
        words = {7: 'seven', 8: 'eight', 9: 'nine', 10: 'ten'}
        self.assertRegex((TOP / 'README.md').read_text(), r'applies the same %s patches' % re.escape(words[n]))


if __name__ == '__main__':
    unittest.main()
