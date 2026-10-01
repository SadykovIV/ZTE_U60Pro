#!/usr/bin/env python3
"""Exercise the bundled starter's real log guard with local command adapters."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'MacIMEI/Resources/VPN/start-dashboard.sh'


class DashboardLogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-dashboard-log-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ['data/local/tmp', 'data/zte-dashboard-runtime', 'data/www', 'bin', 'tmp']:
            (self.root / name).mkdir(parents=True, exist_ok=True)
        for name in ['data', 'data/local', 'data/local/tmp']:
            (self.root / name).chmod(0o755)
        (self.root / 'tmp').chmod(0o1777)
        (self.root / 'data/zte-dashboard-runtime').chmod(0o700)
        (self.root / 'data/zte-dashboard-runtime/current').symlink_to(self.root / 'data/www')
        self.log = self.root / 'data/zte-dashboard-runtime/dashboard.log'
        self.marker = self.root / 'called'
        self.exec_file('data/zte-dashboard-runtime/stop-owned-listener.sh', f'#!/bin/sh\nprintf called > "{self.marker}"\n')
        self.exec_file('data/zte-dashboard-runtime/dashboard-html.sh', '#!/bin/sh\nexit 0\n')
        self.exec_file('bin/readlink', f'#!{sys.executable}\nimport os,sys\nprint(os.path.realpath(sys.argv[-1]))\n')
        self.exec_file('bin/sleep', '#!/bin/sh\nexit 0\n')
        self.exec_file('bin/nohup', '#!/bin/sh\nprintf server-start\n')
        # Only root ownership is modeled; links and permissions use real lstat.
        self.exec_file('bin/stat', f'''#!{sys.executable}
import os, pathlib, stat, sys
fmt, path = sys.argv[2:]
info = os.stat(path)
uid = 99 if os.environ.get('BAD_OWNER') == path else 0
print(fmt.replace('%u', str(uid)).replace('%a', format(stat.S_IMODE(info.st_mode), 'o')).replace('%h', str(info.st_nlink)))
''')
        body = SOURCE.read_text().replace('/data', str(self.root / 'data')).replace('/var/run', str(self.root / 'run'))
        self.script = self.root / 'start.sh'
        self.script.write_text(body)

    def exec_file(self, name, body):
        path = self.root / name
        path.write_text(body)
        path.chmod(0o700)

    def run_start(self, bad_owner=None):
        env = dict(os.environ, PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])
        if bad_owner:
            env['BAD_OWNER'] = str(bad_owner)
        return subprocess.run(['/bin/sh', str(self.script)], env=env, capture_output=True, timeout=5)

    def refused_before_stop(self, bad_owner=None):
        result = self.run_start(bad_owner)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_shared_tmp1777_is_irrelevant_to_private_log(self):
        self.assertEqual(self.run_start().returncode, 0)
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.marker.exists())

    def test_existing_plain_root_log_allowed(self):
        self.log.write_text('old')
        self.log.chmod(0o600)
        self.assertEqual(self.run_start().returncode, 0)

    def test_symlink_does_not_truncate_target(self):
        victim = self.root / 'victim'
        victim.write_text('unchanged')
        self.log.symlink_to(victim)
        self.refused_before_stop()
        self.assertEqual(victim.read_text(), 'unchanged')

    def test_hard_link_does_not_truncate_target(self):
        victim = self.root / 'victim'
        victim.write_text('unchanged')
        os.link(victim, self.log)
        self.refused_before_stop()
        self.assertEqual(victim.read_text(), 'unchanged')

    def test_writable_or_foreign_log_refused(self):
        self.log.write_text('unchanged')
        self.log.chmod(0o666)
        self.refused_before_stop()
        self.log.chmod(0o600)
        self.refused_before_stop(self.log)
        self.assertEqual(self.log.read_text(), 'unchanged')

    def test_writable_or_foreign_parent_refused_without_hardening(self):
        parent = self.root / 'data/zte-dashboard-runtime'
        parent.chmod(0o777)
        self.refused_before_stop()
        self.assertEqual(parent.stat().st_mode & 0o777, 0o777)
        self.assertFalse(self.log.exists())
        parent.chmod(0o700)
        self.refused_before_stop(parent)

    def test_parent_symlink_refused(self):
        parent = self.root / 'data/zte-dashboard-runtime'
        original = self.root / 'original'
        parent.rename(original)
        parent.symlink_to(original, target_is_directory=True)
        self.refused_before_stop()


if __name__ == '__main__':
    unittest.main()
