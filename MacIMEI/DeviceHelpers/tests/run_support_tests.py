#!/usr/bin/env python3
"""Full CLI tests with fake DIAG, native sanitizers, and output privacy checks."""
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / ".build"
BUILD.mkdir(exist_ok=True)
compiler = shutil.which("clang")
if not compiler:
    raise SystemExit("clang required")
for name in ("support_nv", "support_config"):
    binary = BUILD / (name + "_tests")
    subprocess.run([compiler, "-std=c11", "-D_DARWIN_C_SOURCE", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(ROOT / (name + "_tests.c")),
                    "-pthread", "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True,
                            env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1"))
    output = result.stdout + result.stderr
    (BUILD / (name + ".log")).write_text(output)
    assert result.returncode == 0, output[-6000:]
    for secret in ("APP_IMEI", "APP_NV", "EFS_DATA_HEX", "EFS_FILE_COMPLETE", "PRIVATE_RECORD_MUST_NOT_ESCAPE"):
        assert secret not in output, secret
    assert "writes=0" in output
    if name == "support_nv":
        assert "status=5" in output and "diag_error=71" in output and "encoding_valid=0" in output
        assert "outcome=20" in output and "outcome=40" in output and "legacy_alias=0" in output
        assert "unmatched_frames=1 last_unmatched_length=1 last_unmatched_opcode=19" in output
    else:
        for token in ("flag102_count=1", "b31_layout=1", "reason=invalid_crc", "reason=duplicate_id",
                      "reason=invalid_record", "reason=unknown_header", "reason=invalid_header", "value=-1"):
            assert token in output, token
    print(output.splitlines()[-1])
print("SUPPORT_HELPERS_PASS; synthetic DIAG only; no modem access")
