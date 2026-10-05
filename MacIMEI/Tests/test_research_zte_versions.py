#!/usr/bin/env python3
"""Execute the exact release probe with local fake ubus/jsonfilter; no device."""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

MAC = pathlib.Path(__file__).resolve().parents[1]
SPEC = MAC / "Resources/FirmwareResearch/probes.json"
SECRET = "PRIVATE_FIXTURE_IMEI_PASSWORD_MUST_NOT_APPEAR"


class ZteVersionProbeTests(unittest.TestCase):
    def run_probe(self, response, *, code=0, missing=()):
        spec = json.loads(SPEC.read_text())
        command = next(p["command"] for p in spec["probes"] if p["id"] == "release")
        with tempfile.TemporaryDirectory(prefix="research-zte-version-") as directory:
            root = pathlib.Path(directory)
            binary = root / "bin"
            binary.mkdir()
            for name in ("awk", "head", "tr"):
                if name not in missing:
                    (binary / name).symlink_to("/usr/bin/" + name)
            data = root / "reply"
            data.write_bytes(response if isinstance(response, bytes) else json.dumps(response).encode())
            calls = root / "calls"
            if "ubus" not in missing:
                (binary / "ubus").write_text(
                    "#!" + sys.executable + "\n"
                    "import os,pathlib,sys\n"
                    "assert sys.argv[1:]==['-t','5','call','zwrt_web','device_info','{}']\n"
                    "with open(os.environ['CALLS'],'a') as f:f.write('device_info\\n')\n"
                    "sys.stderr.write(os.environ['SECRET'])\n"
                    "try: sys.stdout.buffer.write(pathlib.Path(os.environ['REPLY']).read_bytes());sys.stdout.buffer.flush()\n"
                    "except BrokenPipeError: os._exit(0)\n"
                    "sys.exit(int(os.environ['RPC_CODE']))\n")
                (binary / "ubus").chmod(0o700)
            if "jsonfilter" not in missing:
                (binary / "jsonfilter").write_text(
                    "#!" + sys.executable + "\n"
                    "import json,os,sys\n"
                    "assert len(sys.argv)==3 and sys.argv[1]=='-e'\n"
                    "assert sys.argv[2] in ('@.integrate_version','@.wa_inner_version')\n"
                    "try:\n"
                    " d=json.load(sys.stdin);assert isinstance(d,dict)\n"
                    " v=d.get(sys.argv[2][2:]);print('' if v is None else v)\n"
                    "except Exception:\n"
                    " sys.stderr.write(os.environ['SECRET']);sys.exit(1)\n")
                (binary / "jsonfilter").chmod(0o700)
            (root / "openwrt").write_text("DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='23.05.4'\nDISTRIB_ARCH='aarch64'\n")
            (root / "os-release").write_text('ID=openwrt\nVERSION_ID="23.05.4"\n')
            (root / "build.prop").write_text('ro.build.display.id=fixture-build\n')
            command = command.replace("PATH=/usr/sbin:/usr/bin:/sbin:/bin", "PATH=" + str(binary))
            for source, name in [("/etc/openwrt_release", "openwrt"), ("/etc/os-release", "os-release"), ("/etc/build.prop", "build.prop")]:
                command = command.replace(source, str(root / name))
            before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in root.rglob("*") if p.is_file() and not p.is_symlink()}
            environment = dict(os.environ, REPLY=str(data), CALLS=str(calls), RPC_CODE=str(code), SECRET=SECRET)
            result = subprocess.run(["/bin/sh", "-c", command], env=environment, capture_output=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            stdout = result.stdout.decode()
            self.assertNotIn(SECRET, stdout + result.stderr.decode())
            self.assertNotIn("FR_ZTE_RPC_EXIT", stdout)
            self.assertIn("FR_FACT openwrt_release=23.05.4", stdout)
            self.assertIn("FR_FACT package_arch=aarch64", stdout)
            self.assertIn("ro.build.display.id=fixture-build", stdout)
            after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in root.rglob("*") if p.is_file() and not p.is_symlink() and p != calls}
            self.assertEqual(before, after, "The probe changed fixture files")
            self.assertEqual(calls.read_text().splitlines() if calls.exists() else [], [] if missing else ["device_info"])
            return dict(line[len("FR_FACT "):].split("=", 1) for line in stdout.splitlines() if line.startswith("FR_FACT "))

    def test_mirrors_revision_and_count(self):
        self.assertEqual(SPEC.read_bytes(), (MAC.parent / "Windows_x64/Resources/FirmwareResearch/probes.json").read_bytes())
        spec = json.loads(SPEC.read_text())
        self.assertEqual(spec["revision"], 8)
        self.assertEqual(len(spec["probes"]), 46)

    def test_versions_only_secrets_and_stderr_never_exported(self):
        result = self.run_probe({"integrate_version": "CN_ZTE_MU5250V1.0.0B99", "wa_inner_version": "BD_CNMU5250V1.0.0B99", "imei": SECRET, "password": SECRET, "model": SECRET})
        self.assertEqual(result["zte_integrate_version"], "CN_ZTE_MU5250V1.0.0B99")
        self.assertEqual(result["zte_inner_version"], "BD_CNMU5250V1.0.0B99")
        self.assertNotIn("zte_model", result)

    def test_empty_missing_and_null_fields(self):
        for response in ({}, {"integrate_version": "", "wa_inner_version": None}):
            result = self.run_probe(response)
            self.assertEqual((result["zte_integrate_version"], result["zte_inner_version"]), ("missing", "missing"))

    def test_malformed_or_empty_json(self):
        for response in (b"", b"{invalid", b"[]", b"null"):
            result = self.run_probe(response)
            self.assertEqual((result["zte_integrate_version"], result["zte_inner_version"]), ("not-assessed", "not-assessed"))

    def test_absent_optional_tools(self):
        for name in ("ubus", "jsonfilter", "head", "tr"):
            result = self.run_probe({}, missing=(name,))
            self.assertEqual((result["zte_integrate_version"], result["zte_inner_version"]), ("not-assessed", "not-assessed"))

    def test_rpc_nonzero_ignores_even_valid_json(self):
        result = self.run_probe({"integrate_version": "SHOULD_NOT_EXPORT", "wa_inner_version": "SHOULD_NOT_EXPORT"}, code=7)
        self.assertEqual((result["zte_integrate_version"], result["zte_inner_version"]), ("not-assessed", "not-assessed"))

    def test_crlf_json(self):
        result = self.run_probe(json.dumps({"integrate_version": "VER_1", "wa_inner_version": "INNER_1"}, indent=2).replace("\n", "\r\n").encode() + b"\r\n")
        self.assertEqual((result["zte_integrate_version"], result["zte_inner_version"]), ("VER_1", "INNER_1"))

    def test_control_multiline_and_length_rejected(self):
        for value in ("X\nFR_FACT injected=" + SECRET, "X\r", "X\n", "X\t", "X" * 257, "X\x00Y"):
            result = self.run_probe({"integrate_version": value, "wa_inner_version": "GOOD_1"})
            self.assertEqual(result["zte_integrate_version"], "not-assessed")
            self.assertEqual(result["zte_inner_version"], "GOOD_1")
        result = self.run_probe({"integrate_version": "X" * 256})
        self.assertEqual(result["zte_integrate_version"], "X" * 256)

    def test_oversized_rpc_and_newline_truncation_rejected(self):
        for reply in (json.dumps({"integrate_version": "V1", "private": SECRET * 2000}).encode(), b"\n" * 70000):
            result = self.run_probe(reply)
            self.assertEqual((result["zte_integrate_version"], result["zte_inner_version"]), ("not-assessed", "not-assessed"))


if __name__ == "__main__":
    unittest.main()
