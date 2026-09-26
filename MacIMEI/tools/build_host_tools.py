#!/usr/bin/env python3
"""Build static ARM64 modem host helpers from local source; no network access."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Resources/HostTools"
SOURCE = ROOT / "Native/zte_timeout.c"
CC = shutil.which("aarch64-linux-musl-gcc")
READELF = shutil.which("aarch64-linux-musl-readelf")
assert CC and READELF, "Install the local musl-cross AArch64 toolchain first"
OUT.mkdir(parents=True, exist_ok=True)
FLAGS = ["-std=c11", "-Os", "-static", "-s", "-Wall", "-Wextra", "-Werror",
         "-fno-ident", "-fstack-protector-strong", "-Wl,--build-id=none"]
TARGET = OUT / "zte-timeout"
subprocess.run([CC, *FLAGS, str(SOURCE), "-o", str(TARGET)], check=True,
               env={**os.environ, "SOURCE_DATE_EPOCH": "0"})
raw = TARGET.read_bytes()
assert raw[:6] == b"\x7fELF\x02\x01" and raw[18:20] == b"\xb7\x00", "Expected AArch64 ELF"
audit = subprocess.check_output([READELF, "-l", "-d", str(TARGET)], text=True)
assert "INTERP" not in audit and "(NEEDED)" not in audit, "Helper must be fully static"
TARGET.chmod(0o755)
sha = lambda data: hashlib.sha256(data).hexdigest()
manifest = {"zte-timeout": sha(raw)}
(OUT / "SHA256.json").write_text(json.dumps(manifest, indent=2) + "\n")
provenance = {"version": "1.0.0", "source": "Native/zte_timeout.c", "sourceSHA256": sha(SOURCE.read_bytes()),
              "compiler": subprocess.check_output([CC, "--version"], text=True).splitlines()[0],
              "flags": FLAGS, "architecture": "aarch64", "linkage": "static musl", "bytes": len(raw), "sha256": sha(raw)}
(OUT / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
print(json.dumps(provenance, indent=2))
