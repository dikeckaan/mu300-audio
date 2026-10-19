"""The drivers (kernel/): the mainline port of the Unisoc stack (kernel/mainline/sprd_audio, mu300-linux FINDINGS 188),
nothing of it loaded by udev, the DMA restart that panicked 5.4 (FINDINGS 24e) gone, the hardening of what userspace
can hand the vendor code, and the module lists of kernel/build.sh, mu300-audio-dsp and the release audit agreeing."""
import re
import unittest

from helpers import TOP

MOD = TOP / 'kernel' / 'mainline' / 'sprd_audio'
DSP = TOP / 'device' / 'bin' / 'mu300-audio-dsp'
PCM = MOD / 'sprd' / 'platform' / 'dmaengine_pcm' / 'sprd-dmaengine-pcm.c'
BUILD = TOP / 'kernel' / 'build.sh'


def c_function(src, name):
    """The body of a C function definition, by brace matching."""
    m = re.search(r'(?m)^[a-z].*\b%s\([^;{]*\)\s*\{' % re.escape(name), src)
    assert m, name
    i, depth = m.end() - 1, 0
    for j in range(i, len(src)):
        depth += {'{': 1, '}': -1}.get(src[j], 0)
        if depth == 0:
            return src[m.start():j + 1]
    raise AssertionError(name)


class Build(unittest.TestCase):
    def test_every_source_is_built_and_every_object_exists(self):
        kbuild = (MOD / 'Kbuild').read_text()
        objs = set(re.findall(r'([\w/.-]+)\.o\b', kbuild.split('obj-m', 1)[1]))
        sources = {str(p.relative_to(MOD))[:-2] for p in MOD.rglob('*.c')}
        # virt-dma.c is copied in from the kernel being built against (its kit, kernel/mainline/build-in.sh)
        self.assertEqual(sources - objs, set())
        composite = {o for o in objs if '/' in o}
        self.assertEqual(composite - sources - {'dma/virt-dma'}, set())

    def test_the_modules_are_the_ones_mu300_audio_dsp_loads(self):
        kbuild = (MOD / 'Kbuild').read_text()
        built = set(re.findall(r'([\w-]+)\.o', ' '.join(re.findall(r'obj-m \+= ([^\n]*(?:\\\n[^\n]*)*)', kbuild))))
        src = DSP.read_text()
        listed = set(re.search(r'MODULES="([^"]*)"', src.split('CORE_MODULES=', 1)[1]).group(1).split())
        dma = set(re.search(r'DMA_MODULES="([^"]*)"', src).group(1).split())
        # every module built is loaded by name (the 5.4-only ones may stay in the list: present() skips them)
        self.assertEqual(built - listed - dma, set())

    def test_nothing_loads_by_itself(self):
        # udev would load a module whose alias matches a vendor device tree node, without the parameters audio_mem
        # and the card need, and most of them cannot be unloaded again (FINDINGS 24b)
        for p in MOD.rglob('*.c'):
            for line in p.read_text(errors='replace').splitlines():
                code = re.sub(r'/\*.*?\*/', '', line)
                self.assertNotRegex(code, r'\bMODULE_(DEVICE_TABLE|ALIAS)\(', p)

class Hardening(unittest.TestCase):
    """FINDINGS 188: what userspace can hand the vendor code."""

    def test_enum_puts_check_the_value_they_use(self):
        for p in MOD.rglob('*.c'):
            src = p.read_text(errors='replace')
            self.assertNotRegex(src, r'value\.integer\.value\[0\] >= [\w>-]*items', p)

    def test_no_control_declares_a_maximum_below_zero(self):
        dai = (MOD / 'sprd' / 'dai' / 'vbc' / 'v4' / 'vbc_dai' / 'vbc-dai.c').read_text()
        self.assertIn('#define MAX_32_BIT (0x7fffffff)', dai)
        self.assertIn('#define VBC_PROFILE_CNT_MAX 0x7fffffff',
                      (MOD / 'sprd' / 'dai' / 'vbc' / 'v4' / 'vbc_dai' / 'vbc-phy-v4.h').read_text())

    def test_profiles_are_stored_checked(self):
        dai = (MOD / 'sprd' / 'dai' / 'vbc' / 'v4' / 'vbc_dai' / 'vbc-dai.c').read_text()
        store = c_function(dai, 'vbc_profile_store')
        for check in ('size < sizeof(hdr)', 'check_mul_overflow', 'VBC_PROFILE_MAX_BYTES', 'kfree(p_profile_setting->data'):
            self.assertIn(check, store)
        for user in ('vbc_turning_profile_loading', 'vbc_profile_loading'):
            self.assertIn('vbc_profile_store(', c_function(dai, user))
        self.assertIn('mode_offset >= p_profile_setting->hdr[profile_id].num_mode', c_function(dai, 'vbc_profile_try_apply'))

    def test_offload_is_off_unless_asked_for(self):
        compr = (MOD / 'sprd' / 'platform' / 'compr_2stage_dma' / 'sprd-compr-2stage-dma.c').read_text()
        self.assertIn('static bool allow_offload;', compr)
        self.assertIn('if (!allow_offload)\n\t\treturn -EPERM;', c_function(compr, 'sprd_cc_open'))


class DmaRestart(unittest.TestCase):
    """FINDINGS 24e: a stream prepared and started again after an xrun submitted the same descriptor twice."""

    def test_trigger_submits_each_descriptor_once(self):
        trig = c_function(PCM.read_text(), 'sprd_pcm_trigger')
        start = trig.split('case SNDRV_PCM_TRIGGER_START:', 1)[1].split('case SNDRV_PCM_TRIGGER_STOP:', 1)[0]
        self.assertIn('if (rtd->submitted[i]) {', start)
        self.assertIn('dmaengine_resume(rtd->dma_chn[i])', start)
        self.assertIn('rtd->submitted[i] = true;', start)
        # the submit is behind the check
        self.assertLess(start.index('if (rtd->submitted[i]) {'), start.index('dmaengine_submit('))

    def test_prepare_rebuilds_the_descriptors_of_a_stream_that_ran(self):
        src = PCM.read_text()
        prep = c_function(src, 'sprd_pcm_prepare')
        self.assertIn('dmaengine_terminate_sync(', prep)
        self.assertIn('sprd_pcm_prep_desc(substream)', prep)
        self.assertLess(prep.index('dmaengine_terminate_sync('), prep.index('sprd_pcm_prep_desc(substream)'))
        build = c_function(src, 'sprd_pcm_prep_desc')
        self.assertIn('device_prep_slave_sg(', build)
        self.assertIn('rtd->submitted[i] = false;', build)

    def test_every_place_that_drops_a_descriptor_forgets_it_was_submitted(self):
        src = PCM.read_text()
        for line_no, line in enumerate(src.splitlines()):
            if re.search(r'rtd->dma_tx_des\[i\] = NULL;', line):
                near = '\n'.join(src.splitlines()[line_no:line_no + 3])
                self.assertIn('submitted[i] = false', near)


class ModuleLists(unittest.TestCase):
    def build_list(self, key):
        src = BUILD.read_text()
        common = re.search(r'COMMON="([^"]*)"', src).group(1).split()
        own = re.search(r'%s\) MODULES="\$COMMON ([^"]*)"' % re.escape(key), src).group(1).split()
        return set(common + own)

    def test_kernel_build_wants_what_the_kbuild_builds(self):
        kbuild = (MOD / 'Kbuild').read_text().replace('\\\n', ' ')
        built = {o[:-2] for l in kbuild.splitlines() if re.match(r'obj-m\s*\+?=', l)
                 for o in l.split('=', 1)[1].split() if o.endswith('.o')}
        src = BUILD.read_text()
        common = set(re.search(r'COMMON="([^"]*)"', src).group(1).split())
        mainline = common | set(re.search(r'\*\) MODULES="\$COMMON ([^"]*)"', src).group(1).split())
        self.assertEqual(built, mainline)
        self.assertEqual(len(mainline), 20)
        five = common | set(re.search(r'5\.4\) MODULES="\$COMMON ([^"]*)"', src).group(1).split())
        self.assertEqual(len(five), 23)

    def test_mu300_audio_dsp_loads_every_one(self):
        src = DSP.read_text()
        listed = set(re.search(r'MODULES="([^"]*)"', src.split('CORE_MODULES=', 1)[1]).group(1).split())
        dma = set(re.search(r'DMA_MODULES="([^"]*)"', src).group(1).split())
        src = BUILD.read_text()
        common = set(re.search(r'COMMON="([^"]*)"', src).group(1).split())
        for key in ('5.4', r'\*'):
            own = set(re.search(r'%s\) MODULES="\$COMMON ([^"]*)"' % key, src).group(1).split())
            self.assertEqual((common | own) - listed - dma, set(), key)

    def test_the_5_4_build_applies_every_patch(self):
        src = (TOP / 'kernel' / '5.4' / 'build-in.sh').read_text()
        order = re.search(r'for p in ([^;]*); do', src).group(1).replace('\\', ' ').split()
        patches = sorted(p.stem for p in (TOP / 'kernel' / '5.4' / 'patches').glob('*.patch'))
        self.assertEqual(sorted(order), patches)
        self.assertIn('= %d ]' % len(patches), src)


if __name__ == '__main__':
    unittest.main()
