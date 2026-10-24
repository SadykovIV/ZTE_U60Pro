#!/usr/bin/env python3
"""Execute the exact desktop IPA appendix on a private synthetic filesystem only."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
MAC = REPO / 'MacIMEI/Sources/ModemInformation.swift'
WIN = REPO / 'Windows_x64/src/Diagnostics/ModemLogCollector.cs'
COMMAND = MAC.read_text().split('static let ipaMetadataCommand = #"""\n', 1)[1].split('\n"""#', 1)[0]
BOOT = '01234567-89ab-cdef-0123-456789abcdef'
CANARY = 'PRIVATE-IPA-CANARY-NOT-FOR-EXPORT'


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ipa-diagnostic-')
        self.root = Path(self.temp.name)
        for name in ['bin', 'data/zte-vpn/ipa-backup/deltas', 'proc/sys/kernel/random', 'usr/bin']:
            (self.root / name).mkdir(parents=True, mode=0o700, exist_ok=True)
        self.vpn = self.root / 'data/zte-vpn'
        for p in [self.vpn / 'ipa-backup', self.vpn / 'ipa-backup/deltas']:
            p.chmod(0o700)
        self.write('proc/sys/kernel/random/boot_id', BOOT + '\n')
        self.write('proc/uptime', '100.00 100.00\n')
        self.write('data/zte-vpn/ipa-runtime', BOOT + ' 4242\n')
        self.write('flags', '0\n1\n')
        self.write('usr/bin/ipacm', CANARY)
        self.write('data/zte-vpn/manager.sh', 'exit 99\n' + CANARY)
        self.write('data/zte-vpn/ipa-backup/state', 'close=0\ndisabled=0\nclose_pending=0\ndisabled_pending=0\n')
        self.write('data/zte-vpn/ipa-backup/zwrt_router', 'secret=' + CANARY + '\n')
        self.manifest()
        self.process(4242)
        self.tool('stat', '''import os,sys
p=sys.argv[-1];s=os.stat(p,follow_symlinks=False)
if os.environ.get('STAT_CANARY'): sys.stderr.write('PRIVATE-STAT-CANARY\\n')
if os.environ.get('STAT_FAIL'): sys.exit(1)
v={'%u':'0','%h':str(s.st_nlink),'%a':format(s.st_mode&0o7777,'o'),'%s':str(s.st_size),'%d':str(s.st_dev),'%i':str(s.st_ino),'%Y':str(s.st_mtime_ns),'%Z':str(s.st_ctime_ns)}
out=sys.argv[2]
for k,x in v.items():out=out.replace(k,x)
print(out)
''')
        self.tool('sha256sum', '''import hashlib,sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()+'  -')
''')
        self.tool('uci', '''import os,pathlib,sys
if sys.argv[1:3]!=['-q','get']: sys.exit(99)
keys=['zwrt_router.tmp_router.close_ipa_acce','zwrt_router.other.ipa_disable']
if sys.argv[3] not in keys:sys.exit(99)
p=pathlib.Path(__file__).parent.parent/'flags'
values=p.read_text().splitlines()
print(values[keys.index(sys.argv[3])])
if os.environ.get('UCI_FAIL'):sys.exit(1)
''')
        self.command = COMMAND.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin', f'PATH={self.root}/bin:/usr/bin:/bin')
        self.command = re.sub(r'/data/|/proc/|/usr/bin/ipacm', lambda m: str(self.root) + m.group(), self.command)
        self.command = self.command.replace('safe_dir /data ', f'safe_dir {self.root}/data ')

    def close(self):
        self.temp.cleanup()

    def write(self, path, value):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(value.encode() if isinstance(value, str) else value)
        p.chmod(0o600)

    def tool(self, name, body):
        self.write('bin/' + name, '#!' + sys.executable + '\n' + body)
        (self.root / 'bin' / name).chmod(0o700)

    def process(self, pid, *, state='S', mapped=True):
        fields = [state] + ['0'] * 49
        fields[19] = '123456'
        self.write(f'proc/{pid}/stat', f'{pid} (ipacm) ' + ' '.join(fields) + '\n')
        if mapped:
            (self.root / f'proc/{pid}/exe').symlink_to(self.root / 'usr/bin/ipacm')

    def manifest(self):
        parts = []
        for name in ['state', 'zwrt_router']:
            parts.append(hashlib.sha256((self.vpn / 'ipa-backup' / name).read_bytes()).hexdigest() + '  ' + name + '\n')
        self.write('data/zte-vpn/ipa-backup/SHA256SUMS', ''.join(parts))

    def snapshot(self):
        return {str(p.relative_to(self.root)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else '') for p in self.root.rglob('*')}

    def run(self, **env):
        before = self.snapshot()
        result = subprocess.run(['/bin/sh', '-c', "set -e; printf 'EXISTING_RUNTIME_OUTPUT\\n'; " + self.command + "; printf 'COLLECTION_CONTINUES\\n'"], text=True, capture_output=True, timeout=15, env={**os.environ, **env})
        assert result.returncode == 0, result.stderr
        assert result.stderr == '', result.stderr
        assert self.snapshot() == before, 'metadata collection wrote fixture files'
        for private in [CANARY, 'PRIVATE-STAT-CANARY', BOOT, str(self.root), '/data/', '4242', '123456', 'secret=']:
            assert private not in result.stdout, private
        assert result.stdout.startswith('EXISTING_RUNTIME_OUTPUT\n')
        assert result.stdout.endswith('COLLECTION_CONTINUES\n')
        for line in result.stdout.splitlines():
            if '=' in line:
                assert re.fullmatch(r'[a-z_]+=(?:[01]|[0-9]+|valid|invalid|unknown|absent|yes|no|not-assessed|current-observation)', line), line
        return result.stdout


class IpaDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()

    def tearDown(self):
        self.f.close()

    def test_exact_platform_parity_and_existing_report_appendix(self):
        win = WIN.read_text().split('IpaMetadataCommand = """\n', 1)[1].split('\n        """;', 1)[0]
        self.assertEqual(COMMAND, '\n'.join(line[8:] for line in win.splitlines()))
        self.assertIn('" + "\\n" + ipaMetadataCommand)', MAC.read_text())
        self.assertIn('" + "\\n" + IpaMetadataCommand)', WIN.read_text())
        self.assertNotIn('sha256sum -c', COMMAND)
        self.assertNotIn('source ', COMMAND)

    def test_current_metadata_accepts_close_zero_and_disabled_one_read_only(self):
        out = self.f.run()
        for line in ['ipa_snapshot=valid', 'close_ipa_acce=0', 'ipa_disable=1', 'mapped_ipacm_count=1', 'ipacm_scan_complete=1', 'runtime_marker_matches_current_boot_pid=yes']:
            self.assertIn(line + '\n', out)

    def test_stale_marker_does_not_disclose_boot_or_pid(self):
        self.f.write('data/zte-vpn/ipa-runtime', 'ffffffff-ffff-ffff-ffff-ffffffffffff 4242\n')
        self.assertIn('runtime_marker_matches_current_boot_pid=no\n', self.f.run())

    def test_multiple_mapped_processes_are_counted_without_pid_output(self):
        self.f.process(4243)
        out = self.f.run()
        self.assertIn('mapped_ipacm_count=2\n', out)
        self.assertIn('runtime_marker_matches_current_boot_pid=no\n', out)

    def test_unreadable_mapping_is_unknown_while_zombie_is_ignored(self):
        self.f.process(4243, mapped=False)
        out = self.f.run()
        self.assertIn('ipacm_scan_complete=0\n', out)
        self.assertIn('runtime_marker_matches_current_boot_pid=unknown\n', out)
        self.f.process(4243, state='Z', mapped=False)
        self.assertIn('ipacm_scan_complete=1\n', self.f.run())

    def test_empty_or_missing_stat_with_mapped_executable_is_unknown(self):
        for value in [b'', b'PRIVATE-IPA-CANARY-NOT-FOR-EXPORT']:
            self.f.write('proc/4242/stat', value)
            out = self.f.run()
            self.assertIn('ipacm_scan_complete=0\n', out)
            self.assertIn('runtime_marker_matches_current_boot_pid=unknown\n', out)
        (self.f.root / 'proc/4242/stat').unlink()
        self.assertIn('ipacm_scan_complete=0\n', self.f.run())

    def test_snapshot_corruption_and_private_manifest_paths_are_not_printed(self):
        self.f.write('data/zte-vpn/ipa-backup/zwrt_router', CANARY + '-changed')
        self.assertIn('ipa_snapshot=invalid\n', self.f.run())
        self.f.write('data/zte-vpn/ipa-backup/SHA256SUMS', 'a' * 64 + '  /private/' + CANARY + '\n')
        self.assertIn('ipa_snapshot=invalid\n', self.f.run())

    def test_absent_and_unsafe_metadata_are_distinct(self):
        shutil.rmtree(self.f.vpn / 'ipa-backup')
        (self.f.vpn / 'ipa-runtime').unlink()
        out = self.f.run()
        self.assertIn('ipa_snapshot=absent\n', out)
        self.assertIn('runtime_marker_matches_current_boot_pid=absent\n', out)
        (self.f.vpn / 'ipa-backup').symlink_to(self.f.root / 'bin')
        (self.f.vpn / 'ipa-runtime').symlink_to(self.f.root / 'flags')
        out = self.f.run()
        self.assertIn('ipa_snapshot=invalid\n', out)
        self.assertIn('runtime_marker_matches_current_boot_pid=unknown\n', out)

    def test_oversized_and_non_enum_values_do_not_escape(self):
        self.f.write('data/zte-vpn/ipa-backup/state', 'close=0\n' + CANARY * 100)
        self.f.write('flags', CANARY + '\n' + CANARY + '\n')
        out = self.f.run()
        self.assertIn('ipa_snapshot=unknown\n', out)
        self.assertIn('close_ipa_acce=unknown\n', out)
        self.assertIn('ipa_disable=unknown\n', out)

    def test_error_stderr_is_suppressed_and_does_not_abort_existing_report(self):
        self.assertIn('ipa_snapshot=valid\n', self.f.run(STAT_CANARY='1'))
        self.assertIn('ipa_snapshot=unknown\n', self.f.run(STAT_FAIL='1', STAT_CANARY='1'))
        self.f.command = self.f.command.replace('for tool in stat ', 'for tool in deliberately_missing_ipa_utility stat ')
        self.assertIn('ipa_metadata=not-assessed\n', self.f.run())

    def test_partial_uci_output_with_failed_read_is_unknown(self):
        out = self.f.run(UCI_FAIL='1')
        self.assertIn('close_ipa_acce=unknown\n', out)
        self.assertIn('ipa_disable=unknown\n', out)

    def test_scan_time_budget_is_incomplete_instead_of_false_absence(self):
        self.f.command = self.f.command.replace('scan_started=$(clock_seconds) || scan_started=', 'scan_started=0')
        out = self.f.run()
        self.assertIn('ipacm_scan_complete=0\n', out)
        self.assertIn('runtime_marker_matches_current_boot_pid=unknown\n', out)
        self.assertIn('ipa_snapshot=valid\n', out)

    def test_embedded_nul_marker_is_not_accepted_as_current(self):
        self.f.write('data/zte-vpn/ipa-runtime', (BOOT + ' 4242').encode() + b'\0\n')
        self.assertIn('runtime_marker_matches_current_boot_pid=no\n', self.f.run())


if __name__ == '__main__':
    unittest.main(verbosity=2)
