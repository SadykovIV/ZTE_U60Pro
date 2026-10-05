#!/usr/bin/env python3
"""Execute the production startup shell against a private fake /proc tree.

No device, socket, SSH, signal or privileged path is used. Only absolute paths
in a test-only script copy are remapped; listener ownership logic is unchanged.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'Resources/Onboarding/start_zte_imei_studio.sh'


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-ssh-startup-')
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / 'mock-bin'; self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin)+':/usr/bin:/bin', MOCK_ROOT=str(self.root))
        self.write('/proc/net/tcp', '')
        self.write('/proc/net/tcp6', '')
        self.write('/data/zte-agent', '#!/bin/sh\nexit 0\n', 0o700)
        self.write('/data/zte-imei-studio/start_zte_agent.sh', '#!/bin/sh\nexit 90\n', 0o700)
        self.command('pidof', '''#!/bin/sh
case "$1" in
 zte-agent) echo 1234;;
 dropbear) test ! -f "$MOCK_ROOT/owned" || echo 5678; test ! -f "$MOCK_ROOT/stock" || echo 5679;;
 *) exit 1;;
esac
''')
        self.command('sleep', '''#!/bin/sh
printf x >> "$MOCK_ROOT/polls"
''')
        self.write('/data/zte-imei-studio/bin/dropbear', '''#!/bin/sh
printf '%s\n' "$@" > "$MOCK_ROOT/launched-arguments"
test "${MOCK_SPAWN_FAIL:-0}" != 1 || exit 7
test "${MOCK_NO_LISTENER:-0}" != 1 || exit 0
printf '0: 00000000:08AE 00000000:0000 0A 0 0 0 0 0 4242\n' >> "$MOCK_ROOT/proc/net/tcp"
: > "$MOCK_ROOT/owned"
exit 0
''', 0o700)
        fd=self.root/'proc/5678/fd'; fd.mkdir(parents=True)
        (fd/'3').symlink_to('socket:[4242]')
        (fd.parent/'exe').symlink_to(self.root/'data/zte-imei-studio/bin/dropbear')
        text=SOURCE.read_text()
        text=re.sub(r'(?<![A-Za-z0-9_/])/(data|etc|proc|var)(?=/)',lambda m:str(self.root)+m.group(0),text)
        self.script=self.root/'startup.sh';self.script.write_text(text)

    def tearDown(self): self.temp.cleanup()

    def write(self, path, value, mode=0o600):
        p=self.root/path.lstrip('/');p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(value);p.chmod(mode);return p

    def command(self, name, value):
        p=self.bin/name;p.write_text(value);p.chmod(0o700)

    def listener(self, port=2222, inode=4242, owned=True, ipv6=False):
        path=self.root/('proc/net/tcp6' if ipv6 else 'proc/net/tcp')
        with path.open('a') as f:f.write(f'0: 00000000:{port:04X} 00000000:0000 0A 0 0 0 0 0 {inode}\n')
        if owned:(self.root/'owned').touch()

    def run_start(self):
        return subprocess.run(['/bin/sh',str(self.script)],env=self.env,capture_output=True,text=True,timeout=5)

    def assert_started_2222(self):
        args=(self.root/'launched-arguments').read_text().splitlines()
        self.assertEqual(args[args.index('-p')+1],'2222')
        self.assertNotIn('22',args)

    def test_no_listener_starts_owned_2222(self):
        result=self.run_start();self.assertEqual(result.returncode,0,result.stderr)
        self.assert_started_2222()

    def test_stock_22_is_preserved_and_does_not_replace_2222(self):
        self.listener(22,101,False);before=(self.root/'proc/net/tcp').read_text()
        (self.root/'stock').touch()
        self.write('/proc/5679/placeholder','')
        (self.root/'proc/5679/exe').symlink_to('/usr/sbin/dropbear')
        result=self.run_start();self.assertEqual(result.returncode,0,result.stderr)
        self.assert_started_2222()
        self.assertTrue((self.root/'proc/net/tcp').read_text().startswith(before))
        self.assertTrue((self.root/'stock').exists())

    def test_existing_owned_2222_is_not_started_again(self):
        self.listener();result=self.run_start()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'launched-arguments').exists())

    def test_existing_ipv6_owned_2222_is_ready(self):
        self.listener(ipv6=True);result=self.run_start()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'launched-arguments').exists())

    def test_foreign_2222_is_refused_without_start_or_kill(self):
        self.listener(inode=9999,owned=False);before=(self.root/'proc/net/tcp').read_bytes()
        result=self.run_start()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SSH_LISTENER_UNVERIFIED_2222',result.stderr)
        self.assertFalse((self.root/'launched-arguments').exists())
        self.assertEqual((self.root/'proc/net/tcp').read_bytes(),before)

    def test_correct_executable_with_other_socket_does_not_own_2222(self):
        self.listener(inode=9999,owned=True);result=self.run_start()
        self.assertIn('SSH_LISTENER_UNVERIFIED_2222',result.stderr)
        self.assertNotEqual(result.returncode,0)

    def test_mixed_owned_ipv4_and_foreign_ipv6_is_not_ready(self):
        self.listener();self.listener(inode=9999,owned=False,ipv6=True)
        result=self.run_start()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SSH_LISTENER_UNVERIFIED_2222',result.stderr)
        self.assertFalse((self.root/'launched-arguments').exists())

    def test_owned_and_malformed_listener_is_not_ready(self):
        self.listener();self.listener(inode='bad',owned=False,ipv6=True)
        result=self.run_start()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SSH_LISTENER_UNVERIFIED_2222',result.stderr)

    def test_spawn_exit_zero_without_listener_is_not_ready(self):
        self.env['MOCK_NO_LISTENER']='1';result=self.run_start()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SSH_NOT_LISTENING_2222',result.stderr)
        self.assertEqual((self.root/'polls').read_text(),'x'*9)
        self.assert_started_2222()

    def test_spawn_failure_has_fixed_error_and_no_other_port(self):
        self.env['MOCK_SPAWN_FAIL']='1';result=self.run_start()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SSH_START_FAILED_2222',result.stderr)
        self.assert_started_2222()

    def test_malformed_inode_does_not_prove_listener_ownership(self):
        self.listener(inode='not-an-inode');result=self.run_start()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SSH_LISTENER_UNVERIFIED_2222',result.stderr)


if __name__ == '__main__': unittest.main(verbosity=2)
