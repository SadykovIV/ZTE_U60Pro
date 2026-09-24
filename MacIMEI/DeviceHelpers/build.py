#!/usr/bin/env python3
"""Build modem-side Linux arm64 helpers, without accessing a modem."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
compiler = os.environ.get("ZTE_CROSS_CC") or shutil.which("aarch64-linux-musl-gcc")
if not compiler:
    raise SystemExit("Install aarch64-linux-musl-gcc, or set ZTE_CROSS_CC")
(ROOT / "bin").mkdir(exist_ok=True)
files = []
for name in ("zte_nv", "zte_config", "zte_config_read"):
    source, output = ROOT / "src" / (name + ".c"), ROOT / "bin" / name
    command = [compiler, "-std=c11", "-Os", "-Wall", "-Wextra", "-Werror",
               "-fstack-protector-strong", "-s", f"-ffile-prefix-map={ROOT}=DeviceHelpers", str(source), "-ldl", "-pthread", "-o", str(output)]
    subprocess.run(command, check=True)
    files.append({"name": name, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                  "binary_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                  "size": output.stat().st_size})
manifest = {"platform": "Linux aarch64 musl (modem-side, not macOS)",
            "compiler": subprocess.check_output([compiler, "--version"], text=True).splitlines()[0],
            "plan_io_sha256": hashlib.sha256((ROOT / "src/plan_io.h").read_bytes()).hexdigest(),
            "private_device_data_embedded": False, "helpers": files}
(ROOT / "bin/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
