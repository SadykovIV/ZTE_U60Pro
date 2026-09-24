#!/usr/bin/env python3
"""Compile/run native regression tests without touching a modem."""
from pathlib import Path
import concurrent.futures
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
NAMES = sys.argv[1:] or ['DiagnosticArchiveTests', 'AgentInstallationTests', 'ManagementInformationTests',
                        'OnboardingTests', 'DeviceBackupsTests', 'AccessManagementTests', 'TTLSettingsManagerTests']
SOURCES = [str(p) for p in sorted((ROOT / 'Sources').glob('*.swift'))
           if not p.name.startswith(('UI', 'AppModel')) and p.name != 'Main.swift']
OUT = ROOT / '.build' / 'verification'
OUT.mkdir(parents=True, exist_ok=True)
def run(name):
    source = ROOT / 'Tests' / (name + '.swift')
    if source.parent != ROOT / 'Tests' or not source.is_file():
        return name, 1, 'Unknown test'
    binary = OUT / name
    cmd = ['/usr/bin/swiftc', '-module-cache-path', str(ROOT / '.build/module-cache'), '-swift-version', '5',
           '-target', 'arm64-apple-macosx13.0', '-parse-as-library', *SOURCES, str(source), '-o', str(binary)]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode == 0:
        result = subprocess.run([str(binary)], cwd=ROOT, capture_output=True, text=True)
    text = result.stdout + result.stderr
    (OUT / (name + '.log')).write_text(text)
    return name, result.returncode, text
failed = False
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for name, code, output in pool.map(run, NAMES):
        print(name, 'PASS' if code == 0 else 'FAIL', flush=True)
        if code: print(output, flush=True)
        failed |= code != 0
sys.exit(1 if failed else 0)
