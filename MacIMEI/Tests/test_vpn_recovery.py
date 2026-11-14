"""Exercise the real shell recovery across transaction crash boundaries."""
import pathlib, subprocess, tempfile, unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'Resources/VPN/manager.sh'
def shell_function(name):
    start = name + '() {'
    return start + SOURCE.read_text().split('\n' + start, 1)[1].split('\n}', 1)[0] + '\n}\n'

class RecoveryTests(unittest.TestCase):
    def check(self, directory, live, snapshot, expected):
        with tempfile.TemporaryDirectory(prefix='vpn-recovery-') as temp:
            root = pathlib.Path(temp)
            for name, text in live.items(): (root / name).write_text(text)
            journal = root / directory; journal.mkdir()
            for name, text in snapshot.items(): (journal / name).write_text(text)
            script = 'set -eu\nROOT="$1"\nlog() { :; }\ndisable_guest() { touch "$ROOT/disabled"; }\nsync() { :; }\n' + shell_function('recover') + 'recover\n'
            for _ in range(2):
                subprocess.run(['/bin/sh', '-c', script, 'test', temp], check=True, capture_output=True)
                for name, text in expected.items():
                    self.assertEqual((root / name).read_text() if (root / name).exists() else None, text)
                self.assertFalse((root / directory).exists())
    def test_partial_snapshot_never_rolls_back_live_pair(self):
        self.check('transaction.preparing', {'config.json':'old','active':'old-id'}, {'config.json':'partial'}, {'config.json':'old','active':'old-id'})
    def test_deletion_fences_startup_while_the_old_runtime_config_still_exists(self):
        with tempfile.TemporaryDirectory(prefix='vpn-boot-delete-') as temp:
            root = pathlib.Path(temp)
            (root / 'configured').touch()
            (root / 'config.json').write_text('{}')
            script = 'ROOT="$1"\nuci() { echo 0; }\n' + shell_function('runtime_wanted') + 'runtime_wanted'
            command = ['/bin/sh', '-c', script, 'test', temp]
            self.assertEqual(subprocess.run(command).returncode, 0)
            (root / 'catalog.delete-pending').touch()
            self.assertEqual(subprocess.run(command).returncode, 1)
    def test_interrupted_application_restores_both(self):
        self.check('transaction', {'config.json':'new','active':'old-id'}, {'config.json':'old','active':'old-id'}, {'config.json':'old','active':'old-id'})
    def test_interrupted_restore_is_idempotent(self):
        self.check('transaction', {'config.json':'old','active':'new-id'}, {'config.json':'old','active':'old-id'}, {'config.json':'old','active':'old-id'})
    def test_commit_cleanup_never_reverts_new_pair(self):
        self.check('transaction.done', {'config.json':'new','active':'new-id'}, {'active':'old-id'}, {'config.json':'new','active':'new-id'})
    def test_interrupted_first_activation_disables_guest(self):
        self.check('transaction', {'config.json':'new'}, {}, {'config.json':None,'active':None,'disabled':''})

if __name__ == '__main__': unittest.main()
