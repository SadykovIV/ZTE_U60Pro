#!/usr/bin/env python3
"""Compile production eSIM types and exercise fixed diagnostics without a device."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "MacIMEI/.build/esim-card-diagnostics"
OUT.mkdir(parents=True, exist_ok=True)
source = ROOT / "MacIMEI/Sources/EsimTypes.swift"
test = Path(__file__).with_name("MacEsimCardDiagnosticTests.swift")
catalog = ROOT / "tools/esim-app/fixtures/component-error-codes.json"
binary = OUT / "MacEsimCardDiagnosticTests"
compile_result = subprocess.run([
    "/usr/bin/swiftc", "-module-cache-path", str(ROOT / "MacIMEI/.build/module-cache"),
    "-swift-version", "5", "-parse-as-library", str(source), str(test), "-o", str(binary)
], capture_output=True, text=True)
(OUT / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
if compile_result.returncode:
    print(compile_result.stderr)
    raise SystemExit(compile_result.returncode)
result = subprocess.run([str(binary), str(catalog)], capture_output=True, text=True)
(OUT / "tests.log").write_text(result.stdout + result.stderr)
inputs = [source, test, catalog, Path(__file__), *[
    ROOT / "MacIMEI/Sources" / name for name in ["EsimService.swift", "AppModelEsim.swift", "UIEsim.swift"]
]]
(OUT / "receipt.json").write_text(json.dumps({
    "network": False, "device": False, "exit": result.returncode,
    "inputs": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
}, indent=2) + "\n")
print(result.stdout, end="")
if result.returncode:
    print(result.stderr)
raise SystemExit(result.returncode)
