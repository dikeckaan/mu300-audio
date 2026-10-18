"""How install.sh and uninstall.sh reach the device (lib/remote.sh): the password never on a command line, no user
input in the remote shell code, no fixed temporary paths. ssh, sshpass and sudo are stand-ins here; the remote
command itself runs in a local sh. Run: python3 -m unittest discover tests"""
import io
import os
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
LIB = TOP / 'lib' / 'remote.sh'
PW = 'S3cret pass;$(touch /nonexistent/pwned)'


def write_exe(path, text):
    path.write_text(text)
    path.chmod(0o755)


class Fakes:
    """A PATH with ssh / sshpass / sudo stand-ins. ssh records its argv and runs the remote command in a local sh,
    as the device would; sshpass checks -e and the environment; sudo takes the password line from stdin."""

    def __init__(self, d):
        self.d = Path(d)
        self.bin = self.d / 'bin'
        self.bin.mkdir()
        self.log = self.d / 'log'
        self.log.mkdir()
        write_exe(self.bin / 'ssh', '''#!/bin/sh
printf '%s\\n' "$@" > "$FAKELOG/ssh.argv"
ps -o args= -p $$ > "$FAKELOG/ssh.ps" 2>/dev/null
for last; do :; done
exec sh -c "$last"
''')
        write_exe(self.bin / 'sshpass', '''#!/bin/sh
printf '%s\\n' "$@" > "$FAKELOG/sshpass.argv"
[ "$1" = -e ] || { echo "sshpass without -e" >&2; exit 9; }
printf '%s' "$SSHPASS" > "$FAKELOG/sshpass.env"
shift
exec "$@"
''')
        write_exe(self.bin / 'sudo', '''#!/bin/sh
printf '%s\\n' "$@" > "$FAKELOG/sudo.argv"
[ "$1" = -S ] || exit 9
IFS= read -r p
printf '%s' "$p" > "$FAKELOG/sudo.pw"
shift 3
exec "$@"
''')

    def env(self, with_sshpass=True):
        e = dict(os.environ, FAKELOG=str(self.log), PATH='%s:%s' % (self.bin, os.environ['PATH']))
        if not with_sshpass:
            (self.bin / 'sshpass').unlink(missing_ok=True)
        return e


def payload(script):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as t:
        data = script.encode()
        info = tarfile.TarInfo('probe.sh'); info.size = len(data); info.mode = 0o755
        t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


PROBE = '''#!/bin/sh
d=$1
echo "args: $*" > "$FAKELOG/probe.args"
ls -ld "$d" | cut -c1-10 > "$FAKELOG/probe.mode"
echo "$d" > "$FAKELOG/probe.dir"
'''


class RemoteRun(unittest.TestCase):
    def run_remote(self, host, with_sshpass=True, arg='5.4.254-gb50db5b6224c'):
        with tempfile.TemporaryDirectory() as d:
            f = Fakes(d)
            r = subprocess.run(['sh', '-c', '. "$0"; remote_run "$1" "$2" probe.sh "$3"', str(LIB), host, PW, arg],
                               input=payload(PROBE), capture_output=True, env=f.env(with_sshpass))
            logs = {p.name: p.read_text() for p in f.log.iterdir()}
            return r, logs

    def test_password_never_on_a_command_line(self):
        for host in ('root@192.168.77.1', 'ubuntu@192.168.77.1'):
            for sp in (True, False):
                r, logs = self.run_remote(host, sp)
                self.assertEqual(r.returncode, 0, r.stderr)
                for name in ('ssh.argv', 'sshpass.argv', 'sudo.argv', 'probe.args', 'ssh.ps'):
                    self.assertNotIn('S3cret', logs.get(name, ''), (host, sp, name))
                if sp:
                    self.assertEqual(logs['sshpass.env'], PW)
                    self.assertEqual(logs['sshpass.argv'].splitlines()[0], '-e')

    def test_sudo_gets_the_password_on_stdin(self):
        r, logs = self.run_remote('ubuntu@192.168.77.1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(logs['sudo.pw'], PW)
        self.assertNotIn('sudo.pw', self.run_remote('root@192.168.77.1')[1])

    def test_no_password_or_input_runs_as_code(self):
        r, logs = self.run_remote('ubuntu@192.168.77.1')
        self.assertFalse(Path('/nonexistent/pwned').exists())
        self.assertIn('probe.sh', logs['ssh.argv'])

    def test_fresh_private_temporary_directory_removed_after(self):
        r, logs = self.run_remote('root@192.168.77.1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(logs['probe.mode'].strip(), 'drwx------')
        self.assertFalse(Path(logs['probe.dir'].strip()).exists())
        self.assertNotIn('mu300-audio-install', logs['probe.dir'])

    def test_bad_argument_refused(self):
        r, logs = self.run_remote('root@192.168.77.1', arg='x; reboot')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('ssh.argv', logs)


class HostCheck(unittest.TestCase):
    def ok(self, host):
        return subprocess.run(['sh', '-c', '. "$0"; check_host "$1"', str(LIB), host], capture_output=True).returncode == 0

    def test_accepts(self):
        for h in ('root@192.168.77.1', 'ubuntu@192.168.78.1', 'ubuntu@f50.lan', 'root@fe80::1'):
            self.assertTrue(self.ok(h), h)

    def test_refuses(self):
        for h in ('-oProxyCommand=touch x', 'root@-oProxyCommand=x', 'root@x;reboot', 'root@$(id)', 'nohost',
                  'root@', '@host', 'root@host name', 'root@host\nreboot'):
            self.assertFalse(self.ok(h), h)

    def test_scripts_check_the_host_before_anything_else(self):
        for s in ('install.sh', 'uninstall.sh'):
            r = subprocess.run(['sh', str(TOP / s), '--host', 'root@x;reboot'], capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, s)
            self.assertIn('USER@HOST', r.stderr)


class NoFixedTemporaryPaths(unittest.TestCase):
    def test_no_tmp_literals(self):
        for p in [TOP / 'install.sh', TOP / 'uninstall.sh', LIB, *(TOP / 'device').rglob('*.sh')]:
            for n, line in enumerate(p.read_text().splitlines(), 1):
                code = line.split('#', 1)[0]
                self.assertNotIn('/tmp/', code, '%s:%d' % (p.name, n))

    def test_local_staging_private(self):
        for s in ('install.sh', 'uninstall.sh'):
            src = (TOP / s).read_text()
            self.assertIn('umask 077', src)
            self.assertIn('mktemp -d', src)
            self.assertRegex(src, r"trap 'rm -rf \"\$[A-Z]+\"' EXIT INT TERM")


if __name__ == '__main__':
    unittest.main()
