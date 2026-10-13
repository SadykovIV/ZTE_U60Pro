#!/usr/bin/env python3
"""Build dedicated read-only adaptation tools; leaves production write helpers intact."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parent.parent
compiler = os.environ.get("ZTE_CROSS_CC") or shutil.which("aarch64-linux-musl-gcc")
if not compiler:
    raise SystemExit("Install aarch64-linux-musl-gcc, or set ZTE_CROSS_CC")
folders = [PROJECT / "MacIMEI/Resources/FirmwareSupport", PROJECT / "Windows_x64/Resources/FirmwareSupport"]
for folder in folders:
    folder.mkdir(parents=True, exist_ok=True)
helpers = []
for name, source_name, command in (("zte-support-nv", "zte_nv.c", "--inspect-nv550"),
                                    ("zte-support-config", "zte_config_read.c", "--inspect-config")):
    source = ROOT / "src" / source_name
    output = folders[0] / name
    subprocess.run([compiler, "-std=c11", "-DZTE_SUPPORT_READONLY", "-Os", "-Wall", "-Wextra", "-Werror",
                    "-fstack-protector-strong", "-s", f"-ffile-prefix-map={ROOT}=DeviceHelpers",
                    str(source), "-ldl", "-pthread", "-o", str(output)], check=True)
    data = output.read_bytes()
    for marker in (b"APP_NV", b"EFS_DATA_HEX", b"--apply-plan", b"--enable-flag", b"--restore-plan-original"):
        if marker in data:
            raise SystemExit(f"Unexpected mutable/raw-output marker in {name}: {marker!r}")
    shutil.copyfile(output, folders[1] / name)
    (folders[1] / name).chmod(0o755)
    helpers.append({"name": name, "command": command,
                    "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
manifest = {"schema": 1, "platform": "Linux aarch64 musl; modem-side temporary SSH tools",
            "compiler": subprocess.check_output([compiler, "--version"], text=True).splitlines()[0],
            "build_define": "ZTE_SUPPORT_READONLY", "persistent_writes": False, "raw_device_records_exported": False,
            "support_config_header_sha256": hashlib.sha256((ROOT / "src/support_config.h").read_bytes()).hexdigest(),
            "helpers": helpers}
for folder in folders:
    (folder / "support-helpers.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
