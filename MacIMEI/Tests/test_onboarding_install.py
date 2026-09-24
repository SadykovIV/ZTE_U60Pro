#!/usr/bin/env python3
"""Host-only mock filesystem tests; never invokes adb, SSH, or a modem.

Production scripts contain no environment bypass. For this test only, absolute
device paths are replaced in an in-memory copy and system commands are mocked.
"""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest

RES = Path(__file__).resolve().parents[1] / 'Resources/Onboarding'
CID = '0123456789abcdef0123456789abcdef'
TOKEN = '11111111-2222-3333-4444-555555555555'
FIRMWARE = '604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263'
ROUTER = '55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-onboarding-test-')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'mock-bin'
        self.bin.mkdir()
        self.stage = self.root / f'data/local/tmp/zte-imei-setup-{TOKEN}'
        self.stage.mkdir(parents=True)
        self.journal = self.root / f'data/local/tmp/zte-imei-installations/{TOKEN}'
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin', MOCK_ROOT=str(self.root))
        self.write('/etc/rc.local', '#!/bin/sh\necho 1 > /sys/class/android_usb/android0/usb_op\n# preserved\nexit 0\n', 0o751)
        self.write('/sys/block/mmcblk0/device/cid', CID + '\n')
        self.write('/proc/net/tcp', '  0: 00000000:08AE 00000000:0000 0A\n')
        self.write('/proc/net/tcp6', '')
        self.write('/firmware/image/modem.b16', 'firmware')
        self.write('/usr/bin/diag-router', 'router')
        self.command('id', '#!/bin/sh\necho 0\n')
        self.command('uname', '#!/bin/sh\necho aarch64\n')
        self.command('sync', '#!/bin/sh\nexit 0\n')
        self.command('sleep', '#!/bin/sh\nexit 0\n')
        self.command('df', '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 200000 0 200000 0 /\\n"\n')
        self.command('pidof', '#!/bin/sh\n[ -f "$MOCK_ROOT/running" ] || exit 1\necho 1234\n')
        self.command('readlink', '#!/bin/sh\nprintf "%s/data/zte-agent\\n" "$MOCK_ROOT"\n')
        self.command('sha256sum', f'''#!{shutil.which('python3')}
from pathlib import Path
import hashlib,sys
def h(p):
 if p.endswith('/firmware/image/modem.b16'): return '{FIRMWARE}'
 if p.endswith('/usr/bin/diag-router'): return '{ROUTER}'
 return hashlib.sha256(Path(p).read_bytes()).hexdigest()
if sys.argv[1]=='-c':
 for line in Path(sys.argv[2]).read_text().splitlines():
  expected,path=line.split(None,1)
  if h(path)!=expected: sys.exit(1)
else: print(h(sys.argv[1])+'  '+sys.argv[1])
''')
        for name in ['setup-agent.sh', 'start_zte_imei_studio.sh']:
            text = (RES / name).read_text()
            for prefix in ['/data/', '/etc/', '/proc/', '/sys/', '/firmware/', '/usr/bin/diag-router']:
                text = text.replace(prefix, str(self.root) + prefix)
            text = text.replace('"/$target"', '"' + str(self.root) + '/$target"')
            # Fixed directory literals also occur without a trailing slash.
            for suffix in [' /data ', ' /etc ']:
                text = text.replace(suffix, ' ' + str(self.root) + suffix[1:])
            (self.stage / name).write_text(text)
        (self.stage / 'zte-agent').write_text('#!/bin/sh\nexit 0\n')
        (self.stage / 'dropbear').write_text('''#!/bin/sh
case "$1" in
 -t) printf 'mock host key\n' > "$4";;
 -y) grep -q 'mock host key' "$3" || exit 1; printf 'ssh-ed25519 AAAA mock\n';;
 *) exit 0;;
esac
''')
        (self.stage / 'id_ed25519.pub').write_text('ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAAIGenericTestKey test\n')
        (self.stage / 'start-agent.sh').write_text('#!/bin/sh\ntouch "$MOCK_ROOT/running"\n')

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, text, mode=0o600):
        p = self.root / path.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        return p

    def command(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o700)

    def run_setup(self, cid=CID, agent_hash=None):
        args = [str(self.stage), cid, agent_hash or digest(self.stage/'zte-agent'), digest(self.stage/'dropbear'), digest(self.stage/'id_ed25519.pub')]
        return subprocess.run(['/bin/sh', str(self.stage/'setup-agent.sh'), *args], env=self.env, capture_output=True, text=True)

    def commit(self):
        return subprocess.run(['/bin/sh', str(self.stage/'setup-agent.sh'), '--commit', str(self.journal), CID], env=self.env, capture_output=True, text=True)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fresh_setup_snapshot_commit_preserves_rc(self):
        original = (self.root/'etc/rc.local').read_bytes()
        self.assert_success(self.run_setup())
        self.assertEqual((self.journal/'before/etc_rc.local').read_bytes(), original)
        rc = (self.root/'etc/rc.local').read_text()
        self.assertIn('echo 1 > /sys/', rc)
        self.assertEqual((self.root/'etc/rc.local').stat().st_mode & 0o777, 0o751)
        self.assertEqual(rc.count('start_zte_imei_studio.sh'), 1)
        self.assertLess(rc.index('start_zte_imei_studio.sh'), rc.index('exit 0'))
        self.assertEqual((self.journal/'state').read_text().strip(), 'ready')
        self.assert_success(self.commit())
        self.assertEqual((self.journal/'state').read_text().strip(), 'complete')
        self.assertFalse((self.journal.parent/'active').exists())
        self.assert_success(self.commit())

    def test_wrong_identity_before_install_mutations(self):
        result = self.run_setup(cid='f'*32)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CID_MISMATCH', result.stderr)
        self.assertFalse(self.journal.parent.exists())
        self.assertFalse((self.root/'data/zte-agent').exists())

    def test_wrong_payload_hash_before_install_mutations(self):
        result = self.run_setup(agent_hash='0'*64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AGENT_HASH', result.stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_pending_recovery_blocks(self):
        self.write('/data/local/tmp/zte-imei-installations/active', 'earlier\n')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RECOVERY_PENDING', result.stderr)
        self.assertFalse((self.root/'data/zte-agent').exists())

    def test_existing_agent_credentials_and_keys_preserved(self):
        agent = self.write('/data/zte-agent', '#!/bin/sh\n# old agent\n', 0o700)
        startup = self.write('/data/local/tmp/start_zte_agent.sh', '#!/bin/sh\n# old private credentials\ntouch "$MOCK_ROOT/running"\n', 0o700)
        keys = self.write('/etc/dropbear/authorized_keys', 'ssh-ed25519 AAAA old\n')
        old_agent, old_startup = agent.read_bytes(), startup.read_bytes()
        self.assert_success(self.run_setup())
        self.assertEqual(agent.read_bytes(), old_agent)
        self.assertEqual(startup.read_bytes(), old_startup)
        self.assertIn('ssh-ed25519 AAAA old\n', keys.read_text())
        self.assert_success(self.commit())

    def test_orphan_agent_blocks_without_replacing(self):
        self.write('/data/zte-agent', '#!/bin/sh\n', 0o700)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('EXISTING_AGENT_STARTUP_MISSING', result.stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_symlink_authorized_keys_rejected(self):
        target = self.write('/elsewhere', 'untouched')
        (self.root/'etc/dropbear').mkdir()
        (self.root/'etc/dropbear/authorized_keys').symlink_to(target)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('EXISTING_FILE_TYPE', result.stderr)
        self.assertEqual(target.read_text(), 'untouched')

    def test_commit_rejects_changed_deployment(self):
        self.assert_success(self.run_setup())
        self.write('/data/zte-agent', '# changed after ready\n', 0o700)
        result = self.commit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DEPLOYMENT_CHANGED', result.stderr)
        self.assertTrue((self.journal.parent/'active').exists())

    def test_repeat_completed_commit_preserves_another_owner(self):
        self.assert_success(self.run_setup())
        self.assert_success(self.commit())
        other = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'
        self.write('/data/local/tmp/zte-imei-installations/active', other)
        self.write('/data/local/tmp/zte-imei-installations/lock/owner', other)
        self.assert_success(self.commit())
        self.assertEqual((self.journal.parent/'active').read_text(), other)
        self.assertEqual((self.journal.parent/'lock/owner').read_text(), other)

    def test_incomplete_setup_retains_snapshot_and_active(self):
        self.write('/etc/dropbear/dropbear_ed25519_host_key', 'invalid existing key')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HOST_KEY_INVALID', result.stderr)
        self.assertIn('INSTALL_INCOMPLETE', result.stderr)
        self.assertTrue((self.journal/'before/etc_rc.local').exists())
        self.assertTrue((self.journal.parent/'active').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
