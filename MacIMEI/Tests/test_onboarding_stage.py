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
        self.anchor = self.data / "zte-imei-studio"
        self.stage = self.anchor / ("stage-" + token)
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
        self.anchor.symlink_to(outside)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_DIRECTORY", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_writable_parent_rejected_before_stage_creation(self):
        parent = self.anchor
        parent.mkdir()
        parent.chmod(0o777)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_MODE", result.stderr)
        self.assertFalse(self.stage.exists())

    def test_foreign_owner_or_missing_marker_cannot_be_claimed(self):
        self.anchor.mkdir(mode=0o700)
        self.stage.mkdir(mode=0o700)
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

    def test_stock_writable_directories_are_untouched(self):
        legacy = [self.data / "local", self.data / "local/tmp", self.data / "bin", self.data / "dropbear"]
        for path in legacy:
            path.mkdir(exist_ok=True)
            path.chmod(0o777)
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(self.anchor.stat().st_mode), 0o700)
        for path in legacy:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o777)
        self.assertEqual(list((self.data / "local/tmp").iterdir()), [])

    def test_anchor_0755_is_not_silently_hardened(self):
        self.anchor.mkdir(mode=0o755)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(stat.S_IMODE(self.anchor.stat().st_mode), 0o755)
        self.assertFalse(self.stage.exists())

    def test_foreign_stage_path_rejected_before_creation(self):
        self.script = self.script.replace(str(self.stage), str(self.data / "foreign"))
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STAGE_PATH", result.stderr)
        self.assertFalse((self.data / "foreign").exists())

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
