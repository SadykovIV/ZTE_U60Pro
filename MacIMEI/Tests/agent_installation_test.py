"""Exercise the actual installer with process controls replaced by its filesystem test hook."""
from pathlib import Path
import tempfile, os, subprocess, hashlib, unittest
SCRIPT = Path(__file__).resolve().parents[1] / 'Resources/AgentInstallation/manager.sh'
class Installation(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.bin=self.root/'bin';self.bin.mkdir()
        # Translate GNU stat flags on macOS; ownership is simulated as root.
        (self.bin/'stat').write_text('#!/bin/sh\ncase "$2" in %u) echo 0;; %u:%a) printf "0:"; /usr/bin/stat -f %OLp "$3";; *) exit 1;; esac\n')
        (self.bin/'stat').chmod(0o700)
        self.env={**os.environ,'PATH':str(self.bin)+':'+os.environ['PATH'],'ZTE_AGENT_TEST_ROOT':str(self.root)}
        self.agent=self.root/'data/zte-agent';self.agent.parent.mkdir()
        self.agent.write_bytes(b'previous-agent');self.agent.chmod(0o700)
        startup=self.root/'data/local/tmp/start_zte_agent.sh';startup.parent.mkdir(parents=True);startup.write_text('#!/bin/sh\ntrue\n')
        cid=self.root/'sys/block/mmcblk0/device/cid';cid.parent.mkdir(parents=True);cid.write_text('0123456789abcdef0123456789abcdef\n')
        self.stage=self.root/'tmp/zte-agent-stage-test';self.stage.mkdir(parents=True,mode=0o700)
        self.source=self.stage/'agent.bin';self.source.write_bytes(b'new-agent')
        self.base=self.root/'data/zte-agent-installer'
        (self.root/'running').touch()
    def tearDown(self):self.tmp.cleanup()
    def run_action(self,action,*args):return subprocess.run(['/bin/sh',str(SCRIPT),action,*map(str,args)],env=self.env,capture_output=True,text=True)
    def install(self):return self.run_action('install',self.source,hashlib.sha256(self.source.read_bytes()).hexdigest())
    def test_install_restore(self):
        r=self.install();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(self.agent.read_bytes(),b'new-agent')
        self.assertEqual((self.base/'previous.bin').read_bytes(),b'previous-agent')
        self.assertFalse((self.base/'pending').exists())
        r=self.run_action('restore');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
        self.assertTrue((self.root/'running').exists())
    def test_failed_start_preserves_recoverable_snapshot(self):
        (self.root/'fail-start').touch()
        r=self.install();self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
        self.assertTrue((self.base/'pending').exists())
        (self.root/'fail-start').unlink()
        r=self.run_action('restore');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse((self.base/'pending').exists())
    def test_failure_after_start_rolls_back(self):
        (self.root/'fail-after-start').touch()
        r=self.install();self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
        self.assertIn('AGENT_ROLLBACK restored',r.stderr)
    def test_wrong_hash_never_stops_or_replaces_current_agent(self):
        r=self.run_action('install',self.source,'f'*64);self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent');self.assertTrue((self.root/'running').exists())
    def test_pending_rejects_new_install(self):
        self.assertEqual(self.install().returncode,0)
        (self.base/'pending').write_text('interrupted')
        self.source.write_bytes(b'third-agent')
        r=self.install();self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'new-agent')
        self.assertEqual((self.base/'previous.bin').read_bytes(),b'previous-agent')
    def test_bad_backup_or_foreign_cid_cannot_restore(self):
        self.assertEqual(self.install().returncode,0)
        (self.base/'previous.bin').write_bytes(b'corrupted')
        self.assertNotEqual(self.run_action('restore').returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'new-agent')
        (self.base/'previous.bin').write_bytes(b'previous-agent')
        (self.base/'cid').write_text('f'*32)
        self.assertNotEqual(self.run_action('restore').returncode,0)
    def test_foreign_directory_or_symlink_refused(self):
        self.base.mkdir(mode=0o700)
        self.assertNotEqual(self.install().returncode,0)
        self.base.rmdir()
        foreign=self.root/'foreign';foreign.mkdir()
        self.base.symlink_to(foreign)
        self.assertNotEqual(self.install().returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
    def test_other_deployment_refused(self):
        active=self.root/'data/local/tmp/open-u60-transactions/active'
        active.parent.mkdir();active.write_text('other')
        self.assertNotEqual(self.install().returncode,0)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
    def test_private_startup_supports_update_and_restore(self):
        legacy=self.root/'data/local/tmp/start_zte_agent.sh'
        legacy.unlink()
        startup=self.root/'data/zte-imei-studio/start_zte_agent.sh'
        startup.parent.mkdir(mode=0o700)
        startup.write_text('#!/bin/sh\ntrue\n');startup.chmod(0o700)
        original=startup.read_bytes()
        r=self.install();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        r=self.run_action('restore');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(startup.read_bytes(),original)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
    def test_invalid_private_startup_does_not_fall_back_to_legacy(self):
        startup=self.root/'data/zte-imei-studio/start_zte_agent.sh'
        startup.parent.mkdir(mode=0o700)
        startup.symlink_to(self.root/'data/local/tmp/start_zte_agent.sh')
        r=self.install();self.assertNotEqual(r.returncode,0)
        self.assertIn('AGENT_ERROR PREPARE_FIRST',r.stderr)
        self.assertEqual(self.agent.read_bytes(),b'previous-agent')
        self.assertFalse((self.base/'pending').exists())
if __name__=='__main__':unittest.main()
