#!/usr/bin/env python3
"""Host-only ASan/UBSan protocol, plan-validation and transaction regressions.

All payloads are synthetic. Device main functions are renamed and never called.
No SSH, network, libdiag loading, modem connection or modem write occurs.
"""
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / ".build"
BUILD.mkdir(exist_ok=True)
compiler = shutil.which("clang")
if not compiler:
    raise SystemExit("clang is required for host-only sanitizer tests")
names = ("nv_plan_tests", "nv_protocol_tests", "nv_restore_tests", "config_plan_tests",
         "config_transaction_tests", "config_read_tests")
for name in names:
    command = [compiler, "-std=c11", "-D_DARWIN_C_SOURCE", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
               "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
               str(ROOT / (name + ".c")), "-pthread", "-o", str(BUILD / name)]
    subprocess.run(command, check=True)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1")
    result = subprocess.run([str(BUILD / name)], capture_output=True, text=True, env=env)
    (BUILD / (name + ".log")).write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout[-6000:] + result.stderr[-6000:])
        raise SystemExit(f"FAIL {name}: {result.returncode}")
    print(f"PASS {name}: " + result.stdout.splitlines()[-1])
print("ALL_HELPER_TESTS_PASS; no modem access")
