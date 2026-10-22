"""Exercise the actual Mac/Windows read-only state probe on local fixtures."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InstallationStateProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        swift = (ROOT / 'MacIMEI/Sources/OnboardingAccess.swift').read_text()
        windows = (ROOT / 'Windows_x64/src/Core/OnboardingEngine.cs').read_text()
        cls.scripts = [textwrap.dedent('# ZTE_INSTALL_STATE_PROBE' + source.split('# ZTE_INSTALL_STATE_PROBE', 1)[1].split('"""', 1)[0]).strip()
                       for source in (swift, windows)]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-state-probe-', dir='/private/tmp' if Path('/private/tmp').exists() else None)
        self.root = Path(self.temp.name)
        self.path = self.root / "space and 'quote" / 'state'
        self.path.parent.mkdir()

    def tearDown(self):
        if self.path.is_file() and not self.path.is_symlink():
            self.path.chmod(0o600)
        self.temp.cleanup()

    def probe(self, expected, path=None, prelude=''):
        for script in self.scripts:
            command = prelude + '\nstate_path=' + shlex.quote(str(path or self.path)) + '\n' + script
            result = subprocess.run(['/bin/sh', '-c', command], capture_output=True, text=True, timeout=3)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, 'INSTALL_STATE ' + expected + '\n', ''))

    def test_missing_state_and_missing_parent(self):
        self.probe('MISSING')
        self.probe('UNEXPECTED_TYPE', Path('relative/state'))
        self.probe('MISSING', self.path.parent / 'missing' / 'state')

    def test_recognized_states_are_returned_without_changes(self):
        for state in ('ready', 'complete', 'preparing', 'pending', 'rolled-back'):
            for ending in ('', '\n', '\r\n'):
                data = (state + ending).encode()
                self.path.write_bytes(data)
                self.probe(state)
                self.assertEqual(self.path.read_bytes(), data)

    def test_empty_invalid_and_large_content_are_never_printed(self):
        for data, expected in [(b'', 'EMPTY'), (b'synthetic-private-content', 'INVALID_CONTENT'), (b'ready\nsynthetic-private-content', 'INVALID_CONTENT'), (b'x' * 1048576, 'INVALID_CONTENT'), (b'ready' + b'\n' * 80 + b'synthetic-private-content', 'INVALID_CONTENT'), (b'rea\x00dy\n', 'INVALID_CONTENT'), (b'INSTALL_STATE ready\n', 'INVALID_CONTENT')]:
            self.path.write_bytes(data)
            self.probe(expected)
            self.assertEqual(self.path.read_bytes(), data)

    def test_directory_fifo_and_symlink_are_not_read(self):
        self.path.mkdir(); self.probe('UNEXPECTED_TYPE'); self.path.rmdir()
        os.mkfifo(self.path); self.probe('UNEXPECTED_TYPE'); self.path.unlink()
        secret = self.root / 'private'; secret.write_text('synthetic-private-content')
        self.path.symlink_to(secret); self.probe('UNEXPECTED_TYPE'); self.path.unlink()
        self.path.symlink_to(self.root / 'absent'); self.probe('UNEXPECTED_TYPE')
        self.assertEqual(secret.read_text(), 'synthetic-private-content')

    def test_unsafe_or_unreadable_parent_is_not_reported_missing(self):
        regular = self.root / 'regular'; regular.write_text('synthetic-private-content')
        self.probe('UNEXPECTED_TYPE', regular / 'state')
        link = self.root / 'linked'; link.symlink_to(self.path.parent)
        self.probe('UNEXPECTED_TYPE', link / 'state')
        if os.geteuid() != 0:
            self.path.parent.chmod(0)
            try:
                self.probe('UNREADABLE')
            finally:
                self.path.parent.chmod(0o700)

    def test_failed_read_is_unreadable_without_stderr(self):
        self.path.write_text('ready\n')
        self.probe('UNREADABLE', prelude="od() { printf 'synthetic-private-content' >&2; return 1; }")
        if os.geteuid() != 0:
            self.path.chmod(0)
            self.probe('UNREADABLE')


if __name__ == '__main__':
    unittest.main()
