#!/usr/bin/env python3
"""Execute the actual removal script in an isolated filesystem with proc/service stubs.
No SSH, modem access, installation, or elevated privileges are used.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'Resources/Applications/ssclash-remove.sh'
TOKEN = '12345678-1234-1234-1234-123456789abc'
sha = lambda data: hashlib.sha256(data).hexdigest()

class RemovalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-app-removal-test-')
        self.root = Path(self.temp.name)
        self.base = self.root / 'data/zte-imei-apps'
        self.app = self.base / 'ssclash'
        self.service = self.root / 'etc/init.d/zte_imei_ssclash'
        for name in ['data', 'data/zte-imei-apps/ssclash/bin', 'data/zte-imei-apps/ssclash/.ssclash', 'etc/init.d', 'etc/rc.d', 'proc', 'tmp', 'stubs']:
            path = self.root / name
            path.mkdir(parents=True, exist_ok=True)
        for path in self.root.rglob('*'):
            if path.is_dir(): path.chmod(0o700)
        self.write(self.base / '.zte-imei-owner', b'zte-imei-apps-v1\n')
        self.write(self.app / '.zte-imei-owner', b'zte-imei-ssclash-v1\n')
        self.write(self.app / 'bin/ssclash', b'verified SSClash fixture binary', 0o700)
        self.write(self.app / '.ssclash/password', b'pbkdf2$private-fixture-hash\n')
        self.write(self.root / 'proc/mounts', b'')
        self.write(self.root / 'etc/rc.local', b'#!/bin/sh\nexit 0\n')
        self.write(self.service, b'#!/bin/sh\n[ "$1" = stop ] || exit 1\nprintf stopped > "$TESTROOT/stopped"\nrm -f "$TESTROOT/proc/123/exe"\n', 0o700)
        self.web = self.root / 'proc/123'
        self.web.mkdir(mode=0o700)
        (self.web / 'exe').symlink_to(self.app / 'bin/ssclash')
        (self.root / 'etc/rc.d/S95zte_imei_ssclash').symlink_to('../init.d/zte_imei_ssclash')
        self.foreign = self.base / 'unrelated'
        self.foreign.mkdir(mode=0o700)
        self.write(self.foreign / 'important', b'foreign app retained')
        self.write(self.root / 'stubs/stat', (f'#!{sys.executable}\n' + '''import os,sys,stat
field,path=sys.argv[2:4]
s=os.stat(path)
if field=='%u': print(501 if path==os.environ.get('TEST_BAD_OWNER') else 0)
elif field=='%a': print(oct(stat.S_IMODE(s.st_mode))[2:])
elif field=='%s': print(s.st_size)
else: sys.exit(2)
''').encode(), 0o700)
        for command in ['iptables-save', 'ip6tables-save']:
            self.write(self.root / ('stubs/' + command), b'#!/bin/sh\n[ "${TEST_FIREWALL:-}" != 1 ] || printf \'%s\\n\' \'-A PREROUTING -j CLASH\'\nexit 0\n', 0o700)
        self.write(self.root / 'stubs/df', b'#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 1000000 1 %s 1%% /data\\n" "${TEST_FREE:-900000}"\n', 0o700)
        self.env = {**os.environ, 'PATH': str(self.root / 'stubs') + ':/usr/bin:/bin:/usr/sbin:/sbin', 'TESTROOT': str(self.root)}
        script = SCRIPT.read_text()
        script = script.replace('tar -czf "$TXN/archive.tar.gz" -C / ', 'tar -czf "$TXN/archive.tar.gz" -C "' + str(self.root) + '" ')
        # Replace device paths only; archive members remain relative to the fixture root.
        for prefix in ['/data', '/etc', '/proc', '/tmp']:
            script = script.replace(prefix, '__FIXTURE_ROOT__' + prefix)
        # macOS temp paths can themselves contain /tmp: substitutions above must not
        # recursively rewrite an already substituted root. Use a /private/var temp root.
        self.script = script.replace('__FIXTURE_ROOT__', str(self.root)).replace('${link#/}', '${link#"$TESTROOT/"}')
        self.binary_hash = sha((self.app / 'bin/ssclash').read_bytes())
        self.service_hash = sha(self.service.read_bytes())
        self.recovery = self.base / '.removals' / TOKEN

    def tearDown(self): self.temp.cleanup()
    def write(self, path, data, mode=0o600):
        path.write_bytes(data); path.chmod(mode)
    def run_script(self, action='prepare', digest=None, token=TOKEN, ok=True):
        args = ['/bin/sh', '-s', '--', action, token, self.binary_hash, self.service_hash]
        if digest is not None: args.append(digest)
        result = subprocess.run(args, input=self.script, text=True, capture_output=True, env=self.env, timeout=15)
        if ok: self.assertEqual(result.returncode, 0, result.stderr)
        else: self.assertNotEqual(result.returncode, 0, result.stdout)
        return result
    def prepare(self):
        result = self.run_script()
        fields = dict(item.split('=', 1) for item in result.stdout.strip().split()[1:])
        data = (self.recovery / 'archive.tar.gz').read_bytes()
        self.assertEqual(fields['sha256'], sha(data))
        self.assertEqual(int(fields['bytes']), len(data))
        self.assertEqual((self.recovery / 'archive.tar.gz').stat().st_mode & 0o777, 0o600)
        return fields['sha256']
    def untouched(self):
        self.assertTrue(self.app.exists()); self.assertTrue(self.service.exists())
        self.assertFalse((self.root / 'stopped').exists())
        self.assertEqual((self.foreign / 'important').read_bytes(), b'foreign app retained')

    def test_prepare_and_commit_preserve_private_recovery_and_foreign_app(self):
        digest = self.prepare()
        self.assertTrue(self.app.exists()); self.assertTrue(self.service.exists())
        with tarfile.open(self.recovery / 'archive.tar.gz') as archive:
            self.assertEqual(archive.extractfile('data/zte-imei-apps/ssclash/.ssclash/password').read(), b'pbkdf2$private-fixture-hash\n')
            self.assertIn('etc/rc.d/S95zte_imei_ssclash', archive.getnames())
        self.run_script('commit', digest)
        self.assertFalse(self.app.exists()); self.assertFalse(self.service.exists())
        self.assertFalse((self.root / 'etc/rc.d/S95zte_imei_ssclash').is_symlink())
        self.assertEqual((self.recovery / 'phase').read_text().strip(), 'removed')
        self.assertEqual((self.foreign / 'important').read_bytes(), b'foreign app retained')
        self.assertTrue((self.recovery / 'archive.tar.gz').exists())

    def test_changed_binary_is_never_stopped_or_removed(self):
        (self.app / 'bin/ssclash').write_bytes(b'changed')
        self.run_script(ok=False); self.untouched()
    def test_changed_service_is_never_executed(self):
        self.service.write_bytes(b'#!/bin/sh\ntouch /should-never-run\n')
        self.run_script(ok=False); self.untouched()
    def test_foreign_owner_is_protected(self):
        (self.app / '.zte-imei-owner').write_text('another owner')
        self.run_script(ok=False); self.untouched()
    def test_writable_parent_is_protected(self):
        self.base.chmod(0o777)
        self.run_script(ok=False); self.untouched()
    def test_foreign_uid_is_protected(self):
        self.env['TEST_BAD_OWNER'] = str(self.app)
        self.run_script(ok=False); self.untouched()
    def test_symlinked_binary_is_protected(self):
        binary = self.app / 'bin/ssclash'; binary.unlink(); binary.symlink_to(self.foreign / 'important')
        self.run_script(ok=False); self.untouched()
    def test_owned_proxy_must_be_stopped_by_its_normal_workflow(self):
        proc = self.root / 'proc/124'; proc.mkdir(); (proc / 'exe').symlink_to(self.app / 'bin/clash')
        self.run_script(ok=False); self.untouched()
    def test_foreign_proxy_process_is_not_killed(self):
        proc = self.root / 'proc/124'; proc.mkdir(); (proc / 'exe').symlink_to('/foreign/bin/clash')
        digest = self.prepare(); self.run_script('commit', digest)
        self.assertTrue((proc / 'exe').is_symlink())
    def test_unknown_startup_link_is_protected(self):
        (self.root / 'etc/rc.d/S10zte_imei_ssclash').symlink_to('../init.d/zte_imei_ssclash')
        self.run_script(ok=False); self.untouched()
    def test_custom_rc_local_is_protected(self):
        (self.root / 'etc/rc.local').write_text(str(self.service) + ' start\n')
        self.run_script(ok=False); self.untouched()
    def test_nested_mount_is_protected(self):
        (self.root / 'proc/mounts').write_text('foreign ' + str(self.app / 'profiles') + ' ext4 rw 0 0\n')
        self.run_script(ok=False); self.untouched()
    def test_proxy_firewall_rules_fail_before_stop(self):
        self.env['TEST_FIREWALL'] = '1'; self.run_script(ok=False); self.untouched()
    def test_low_space_fails_before_stop(self):
        self.env['TEST_FREE'] = '1'; self.run_script(ok=False); self.untouched()
    def test_corrupt_archive_prevents_commit(self):
        digest = self.prepare(); (self.recovery / 'archive.tar.gz').write_bytes(b'corrupt')
        self.run_script('commit', digest, ok=False)
        self.assertTrue(self.app.exists()); self.assertTrue(self.service.exists())
    def test_restart_between_backup_and_commit_prevents_commit(self):
        digest = self.prepare(); (self.web / 'exe').symlink_to(self.app / 'bin/ssclash')
        self.run_script('commit', digest, ok=False)
        self.assertTrue(self.app.exists()); self.assertTrue(self.service.exists())
    def test_token_injection_is_rejected(self):
        self.run_script(token='../../outside; true', ok=False); self.untouched()
    def test_symlinked_recovery_directory_is_protected(self):
        (self.base / '.removals').symlink_to(self.foreign)
        self.run_script(ok=False); self.untouched()

if __name__ == '__main__': unittest.main(verbosity=2)
