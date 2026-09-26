"""Execute the actual Swift-embedded staging script against private local fixtures.

Only fixed /data paths and root uid reports are mapped. No ADB or modem access.
"""
from pathlib import Path
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid


class StageTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="zte-onboarding-stage-"))
        self.data = self.root / "data"
        self.data.mkdir(mode=0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir(mode=0o700)
        helper = self.bin / "stat"
        helper.write_text(f"#!{sys.executable}\n" + """import os,stat,sys
info=os.lstat(sys.argv[3]); fmt=sys.argv[2]
print({'%u':'0', '%a':format(stat.S_IMODE(info.st_mode),'o'), '%h':str(info.st_nlink)}[fmt])
""")
        helper.chmod(0o700)
        token = str(uuid.uuid4())
        self.stage = self.data / "local/tmp" / ("zte-imei-setup-" + token)
        self.owner = token + " " + "a" * 32 + " b31 " + "b" * 64 + " " + "c" * 64
        source = (Path(__file__).resolve().parents[1] / "Sources/Onboarding.swift").read_text()
        match = re.search(r'static func stagePreparationCommand[\s\S]*?"""\n([\s\S]*?)\n        """', source)
        self.assertIsNotNone(match)
        self.script = textwrap.dedent(match[1]).replace("/data", str(self.data))
        self.script = self.script.replace(r'\(shellQuote(stage))', shlex.quote(str(self.stage)))
        self.script = self.script.replace(r'\(shellQuote(owner))', shlex.quote(self.owner)).replace('\\\\', '\\')

    def tearDown(self):
        shutil.rmtree(self.root)

    def run_stage(self):
        return subprocess.run(["/bin/sh", "-c", self.script], capture_output=True, text=True,
                              env={**os.environ, "PATH": str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin"}, timeout=15)

    def test_missing_parents_created_and_owned_stage_can_resume_without_truncation(self):
        first = self.run_stage()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, "INSTALL_STAGE_READY\n")
        self.assertEqual((self.stage / ".owner").read_text(), self.owner + "\n")
        self.assertEqual(stat.S_IMODE(self.stage.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.stage / ".owner").stat().st_mode), 0o600)
        payload = self.stage / "setup-agent.sh"
        payload.write_text("previous verified installer")
        second = self.run_stage()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(payload.read_text(), "previous verified installer")

    def test_symlink_parent_rejected_without_writing_target(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.data / "local").symlink_to(outside)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_DIRECTORY", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_writable_parent_rejected_before_stage_creation(self):
        parent = self.data / "local"
        parent.mkdir()
        parent.chmod(0o777)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_MODE", result.stderr)
        self.assertFalse(self.stage.exists())

    def test_foreign_owner_or_missing_marker_cannot_be_claimed(self):
        self.stage.mkdir(parents=True, mode=0o700)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_OWNER_FILE", result.stderr)
        marker = self.stage / ".owner"
        marker.write_text("foreign\n")
        marker.chmod(0o600)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_OWNER", result.stderr)
        self.assertEqual(marker.read_text(), "foreign\n")

    def test_launched_installer_stage_is_never_reopened_for_upload(self):
        self.assertEqual(self.run_stage().returncode, 0)
        (self.stage / ".install-requested").write_text(self.owner + "\n")
        payload = self.stage / "setup-agent.sh"
        payload.write_text("installer still running")
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_INSTALL_REQUESTED", result.stderr)
        self.assertEqual(payload.read_text(), "installer still running")


if __name__ == "__main__":
    unittest.main()
