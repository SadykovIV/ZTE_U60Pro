#!/usr/bin/env python3
"""Build the temporary QMI observation helper offline; never accesses a modem."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CRATE = ROOT / "tools/radio-inspect"
NAME = "zte-support-qmi"
TARGET = "aarch64-unknown-linux-musl"
SOURCE_FILES = (
    "tools/radio-inspect/Cargo.toml",
    "tools/radio-inspect/Cargo.lock",
    "tools/radio-inspect/src/main.rs",
    "tools/radio-inspect/build.py",
    "tools/removable-euicc/device/src/qmi/qrtr.rs",
    "tools/removable-euicc/device/src/qmi/tlv.rs",
    "tools/esim-app/build_runtime.py",
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def environment():
    spec = importlib.util.spec_from_file_location("esim_runtime_build", ROOT / "tools/esim-app/build_runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    env = module.environment()
    env["CARGO_TARGET_DIR"] = str(CRATE / "target")
    linker_key = "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"
    linker = env.get(linker_key) or env.get("ZTE_CROSS_CC") or shutil.which("aarch64-linux-musl-gcc")
    if not linker:
        raise SystemExit("aarch64-linux-musl-gcc required, or set ZTE_CROSS_CC")
    env[linker_key] = linker
    return env


def run(args, env):
    subprocess.run(args, cwd=CRATE, env=env, check=True)


def validate_binary(data):
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or int.from_bytes(data[18:20], "little") != 183:
        raise SystemExit("Expected Linux ARM64 ELF")
    offset = int.from_bytes(data[32:40], "little")
    size = int.from_bytes(data[54:56], "little")
    count = int.from_bytes(data[56:58], "little")
    if size < 56 or count == 0 or offset + size * count > len(data):
        raise SystemExit("Invalid ELF program headers")
    if any(int.from_bytes(data[offset + i * size:offset + i * size + 4], "little") == 3 for i in range(count)):
        raise SystemExit("QMI helper must be static; ELF interpreter found")
    if str(ROOT).encode() in data or str(Path.home()).encode() in data:
        raise SystemExit("Private build prefix found")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", action="store_true", help="Run native fixture tests before cross-compiling")
    args = parser.parse_args()
    env = environment()
    if args.tests:
        run(["cargo", "test", "--offline", "--locked"], env)
    run(["cargo", "build", "--offline", "--locked", "--release", "--target", TARGET], env)
    source = CRATE / "target" / TARGET / "release" / NAME
    data = source.read_bytes()
    validate_binary(data)
    report = {
        "schema": 1,
        "name": NAME,
        "command": "--inspect-current-card",
        "target": TARGET,
        "sha256": sha(data),
        "size": len(data),
        "rustc": subprocess.check_output([env.get("RUSTC", "rustc"), "--version"], env=env, text=True).strip(),
        "cargo": subprocess.check_output(["cargo", "--version"], env=env, text=True).strip(),
        "linker": subprocess.check_output([env["CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"], "--version"], env=env, text=True).splitlines()[0],
        "source_date_epoch": env["SOURCE_DATE_EPOCH"],
        "offline_locked": True,
        "device_access_performed": False,
        "identifiers_exported": False,
        "qmi_queries": [{"service": 2, "message": 45}, {"service": 11, "message": 47}, {"service": 11, "message": 71}],
        "sources": [{"path": name, "sha256": sha((ROOT / name).read_bytes())} for name in SOURCE_FILES],
    }
    for relative in ("MacIMEI/Resources/FirmwareSupport", "Windows_x64/Resources/FirmwareSupport"):
        folder = ROOT / relative
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, folder / NAME)
        (folder / NAME).chmod(0o755)
        (folder / "radio-inspect-build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
