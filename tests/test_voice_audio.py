"""Call audio (FINDINGS 24c): no phone number reaches a log in full, and mu300-hfp only talks to a bonded,
authenticated headset through a strict AT allow-list."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import TOP

VOICE = TOP / 'device' / 'bin' / 'mu300-voice'
HFP = TOP / 'src' / 'hfp' / 'mu300-hfp.c'


def shell_function(src, name):
    m = re.search(r'(?ms)^%s\(\) \{\n.*?\n\}\n' % re.escape(name), src)
    if not m:
        m = re.search(r'(?m)^%s\(\) \{.*\}$' % re.escape(name), src)
    assert m, name
    return m.group(0).rstrip('\n') + '\n'


class Masking(unittest.TestCase):
    NUMBERS = ['+447700900140', '07700900140', '7700900140', '+441632960961', '112233']

    def run_log(self, *lines):
        src = VOICE.read_text()
        script = shell_function(src, 'mask') + shell_function(src, 'log') + ''.join(
            'log %s\n' % repr(l).replace("'", "'") for l in lines)
        return subprocess.run(['sh', '-c', script], capture_output=True, text=True, check=True).stdout

    def test_numbers_masked(self):
        out = self.run_log('call state: 4 (+447700900140)',
                           '+CLCC: 1,1,4,0,0,"07700900140",129',
                           'RING +CLIP: "+441632960961",145,,,"",0',
                           'dial 7700900140 now', 'short 112233')
        for n in self.NUMBERS:
            self.assertNotIn(n, out)
        self.assertIn('+44********40', out)
        self.assertIn('"*********40"', out)
        self.assertIn('+44********61', out)
        self.assertIn('****33', out)

    def test_small_values_untouched(self):
        # card numbers, modes, rates and volumes are not phone numbers
        out = self.run_log('profiles: mode 28 (band 1) = 0x1c1c0005, VBC_VOLUME 7', 'hw:1,5 8000 Hz')
        self.assertIn('mode 28', out)
        self.assertIn('8000 Hz', out)
        self.assertIn('VBC_VOLUME 7', out)

    def test_every_number_path_masked(self):
        src = VOICE.read_text()
        self.assertIn('log() { echo "mu300-voice: $*" | mask; }', src)
        self.assertIn('echo "incoming: $line" | mask', src)
        self.assertRegex(src, r"at 'AT\+CLCC' 8 \| tr '\\n' ' ' \| mask")
        # the number only goes to the headset (ring), never to stdout unmasked
        for line in src.splitlines():
            if '$number' in line and 'log ' not in line:
                self.assertRegex(line, r'number=|hfp "ring \$number"')
        self.assertIn('umask 077', src)


class RunDirectory(unittest.TestCase):
    """/run is world-writable on the images, so /run/mu300-voice may be a directory somebody else made first: mu300-voice
    takes it with the system's lib/run-dir.sh (mu300-linux tests the helper itself) before it writes anything there."""

    def test_the_helper_comes_before_any_write(self):
        src = VOICE.read_text()
        self.assertIn('RUN_DIR_LIB=${MU300_RUN_DIR_LIB:-/opt/mu300/lib/run-dir.sh}', src)
        check = src.index('run_dir_take "$TMP"')
        for first_use in ('SAVED=$TMP/saved', 'chmod 700 "$TMP"', 'SCENE_PID=$TMP/scene.pid'):
            self.assertLess(check, src.index(first_use), first_use)
        self.assertNotIn('mkdir -p "$TMP"', src)
        # the headset's control fifo is inside it, not in /run itself
        self.assertIn('HFP_CTL=$TMP/hfp.ctl', src)
        self.assertNotIn('run_dir_ours() {', src)       # no copy of its own


class Hfp(unittest.TestCase):
    def test_security_in_source(self):
        c = HFP.read_text()
        self.assertIn('BT_SECURITY_MEDIUM', c)
        # security is set before the connect, and checked after it together with the peer address
        sec = c.index('setsockopt(rc, SOL_BLUETOOTH, BT_SECURITY')
        self.assertLess(sec, c.index('connect(rc,'))
        self.assertIn('getpeername(rc', c)
        self.assertIn('sec.level < BT_SECURITY_MEDIUM', c)
        # only bonded devices, never a listening socket
        self.assertIn('[LinkKey]', c.replace('\\\\', ''))
        self.assertNotRegex(c, r'\blisten\(|\baccept\(')
        self.assertIn('mkfifo(fifo, 0600)', c)
        # refused lines are not logged verbatim
        self.assertIn('refused (%zu bytes)', c)
        # the answer and hang-up commands inherit none of the headset's sockets
        child = c[c.index('static void run_bg'):c.index('static void ciev')]
        self.assertLess(child.index('close(fd)'), child.index('execl('))

    @unittest.skipUnless(shutil.which('cc'), 'no C compiler')
    def test_allow_list(self):
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / 'hfptest'
            subprocess.run(['cc', '-DMU300_HFP_TEST', '-o', str(exe), str(HFP)], check=True, capture_output=True)
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn(', 0 failed', r.stdout)


class Portability(unittest.TestCase):
    """The F50's card names the CVS selector "NXP Profile Select", and OpenWrt's busybox sleep takes no fractions."""

    def run_cvs_select(self, controls):
        src = VOICE.read_text()
        # a stand-in amixer that knows only the given controls
        fake = 'amixer() { case "$*" in %s) echo "  : values=5" ;; esac; }\n' % (
            '|'.join('*"name=%s"*' % c for c in controls) or '__none__')
        script = 'card=0\n' + fake + shell_function(src, 'cget') + shell_function(src, 'cvs_select') + 'cvs_select\n'
        return subprocess.run(['sh', '-c', script], capture_output=True, text=True, check=True).stdout.strip()

    def test_cvs_select_picks_the_name_the_card_has(self):
        self.assertEqual(self.run_cvs_select(['NXP Profile Select']), 'NXP Profile Select')
        self.assertEqual(self.run_cvs_select(['CVS Profile Select']), 'CVS Profile Select')
        self.assertEqual(self.run_cvs_select([]), 'CVS Profile Select')

    def test_profiles_use_the_selector_found(self):
        src = VOICE.read_text()
        body = src[src.index('profiles() {'):src.index('bt_rate() {')]
        self.assertIn('"$(cvs_select)"', body)
        self.assertNotIn("'CVS Profile Select'", body)

    def test_no_fractional_sleep(self):
        src = VOICE.read_text()
        code = '\n'.join(l for l in src.splitlines() if not l.lstrip().startswith('#'))
        # every fractional wait goes through nap; only nap itself may hand sleep a fraction
        self.assertNotRegex(code.replace('if sleep 0.01 2>/dev/null', ''), r'\bsleep +"?[0-9]*\.[0-9]')
        self.assertIn('nap 0.1', code)

    def test_nap_falls_back_to_whole_seconds(self):
        src = VOICE.read_text()
        start = src.index('if sleep 0.01 2>/dev/null; then')
        block = src[start:src.index('\nfi\n', start) + 4]
        with tempfile.TemporaryDirectory() as d:
            # a sleep like OpenWrt's: whole seconds only, records what it was asked for
            log = Path(d) / 'log'
            script = ('sleep() { case "$1" in *.*) echo "sleep: invalid number" >&2; return 1 ;; esac; '
                      'echo "sleep $1" >> %s; }\n' % log + 'PATH=/nonexistent\n' + block + 'nap 0.1\nnap 0.5\n')
            subprocess.run(['/bin/sh', '-c', 'awk() { %s "$@"; }\n' % shutil.which('awk') + script],
                           capture_output=True, text=True, check=True)
            self.assertEqual(log.read_text().split('\n')[:2], ['sleep 1', 'sleep 1'])


class DspClock(unittest.TestCase):
    """FINDINGS 24d: the voice back end's IIS port 1 has no clock on this board unless the VBC makes one; without
    it the DSP takes no modem frame and the far end hears silence. Bluetooth brings its own clock."""

    @staticmethod
    def func(src, name):
        # these functions carry a usage comment on their first line, which shell_function does not expect
        m = re.search(r'(?ms)^%s\(\) \{[^\n]*\n.*?\n\}\n' % re.escape(name), src)
        assert m, name
        return m.group(0)

    def run_routes(self, out):
        src = VOICE.read_text()
        script = ('put() { echo "$1=$2"; }\nbt_rate() { :; }\ndump_tap() { :; }\n' + shell_function(src, 'dsp_clock') +
                  self.func(src, 'routes') + 'routes %s\n' % out)
        lines = subprocess.run(['sh', '-c', script], capture_output=True, text=True, check=True).stdout.splitlines()
        return dict(l.split('=', 1) for l in lines)

    def test_dsp_output_clocks_iis_port_1(self):
        c = self.run_routes('dsp')
        self.assertEqual(c['VBC_IIS_MASTER_ENALBE'], 'enable')
        self.assertEqual(c['VBC_IIS_MST_SEL_1_TYPE'], 'VBC_MASTER_INTERNAL')
        self.assertEqual(c['VBC_IIS_MST_SEL_0_TYPE'], 'VBC_MASTER_INTERNAL')

    def test_bluetooth_keeps_the_controllers_clock(self):
        c = self.run_routes('bt')
        self.assertNotIn('VBC_IIS_MASTER_ENALBE', c)
        self.assertNotIn('VBC_IIS_MST_SEL_1_TYPE', c)

    def test_clock_goes_through_the_undo_log(self):
        # put() records the old value, so "audio stop" puts the VBC back to slave mode
        body = shell_function(VOICE.read_text(), 'dsp_clock')
        self.assertNotIn('amixer', body)
        self.assertEqual(body.count('put '), 3)

    def test_clock_reapplied_after_the_scene_starts(self):
        body = self.func(VOICE.read_text(), 'audio_start')
        self.assertLess(body.index('pcmhost'), body.index('dsp_clock'))


class Dtmf(unittest.TestCase):
    """FINDINGS 24d: DTMF goes out as RTP events, one AT+VTS per key, and only while the call's audio is running: with
    the scene down the modem answers OK and sends nothing."""

    def run_dtmf(self, keys, call=True, scene=True, answer='OK'):
        # a stand-in modem: a call is up or not, the scene runs or not, and every AT+VTS gets the given answer; the
        # commands are logged
        script = ('in_call() { %s; }\nvoice_running() { %s; }\nat() { echo "$1" >&3; echo "%s"; }\n'
                  % ('true' if call else 'false', 'true' if scene else 'false', answer) +
                  DspClock.func(VOICE.read_text(), 'dtmf') + 'dtmf %s 3>&1 1>/dev/null\n' % keys)
        r = subprocess.run(['sh', '-c', script], capture_output=True, text=True)
        return r.returncode, r.stdout.splitlines()

    def test_one_vts_per_key_in_order(self):
        rc, sent = self.run_dtmf("'1a*#9D'")
        self.assertEqual(rc, 0)
        self.assertEqual(sent, ['AT+VTS="1"', 'AT+VTS="A"', 'AT+VTS="*"', 'AT+VTS="#"', 'AT+VTS="9"', 'AT+VTS="D"'])

    def test_nothing_sent_for_a_bad_key_without_a_call_or_without_the_scene(self):
        for keys in ("'12x'", "''", "'1 2'", "'E'", "'e'", "'1\"'", "'1;AT+CHUP'", "'$(id)'", "'1\n2'", "'\uff11'",
                     "'1\\'", "'1,2'"):
            with self.subTest(keys=keys):
                rc, sent = self.run_dtmf(keys)
                self.assertEqual((rc, sent), (2, []))
        self.assertEqual(self.run_dtmf("'5'", call=False), (1, []))
        self.assertEqual(self.run_dtmf("'5'", scene=False), (1, []))

    def test_a_refused_key_stops_the_rest(self):
        # mu300-at exits 0 on the modem's ERROR too: only the OK counts
        self.assertEqual(self.run_dtmf("'123'", answer='ERROR'), (1, ['AT+VTS="1"']))

    def test_the_scene_is_the_voice_pcm_running_in_either_direction(self):
        fn = shell_function(VOICE.read_text(), 'voice_running')
        with tempfile.TemporaryDirectory() as d:
            for c, p, running in (('', '', False), ('state: PREPARED', '', False), ('state: RUNNING', '', True),
                                  ('', 'state: RUNNING', True), ('closed', 'closed', False)):
                with self.subTest(capture=c, playback=p):
                    for sub, text in (('pcm4c', c), ('pcm4p', p)):
                        f = Path(d, 'card0', sub, 'sub0', 'status')
                        f.parent.mkdir(parents=True, exist_ok=True)
                        f.unlink(missing_ok=True)
                        if text:
                            f.write_text(text + '\n')
                    r = subprocess.run(['sh', '-c', 'card=0 VOICE=4\n' + fn.replace('/proc/asound', d) + 'voice_running'])
                    self.assertEqual(r.returncode == 0, running)


if __name__ == '__main__':
    unittest.main()
