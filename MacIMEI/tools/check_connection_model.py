#!/usr/bin/env python3
"""Test production connection state with private temporary storage, without a modem."""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
(root / '.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='connection-model-', dir=root / '.build') as directory:
    work = Path(directory)
    source = (root / 'Sources/AppModel.swift').read_text()
    for old, new in [
        ('Library/Application Support/ZTE IMEI Studio', work / 'state'),
    ]:
        needle = 'FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("' + old + '")'
        if source.count(needle) != 1:
            raise SystemExit('Cannot prove AppModel test storage isolation: ' + old)
        source = source.replace(needle, 'URL(fileURLWithPath: ' + json.dumps(str(new)) + ')')
    model = work / 'AppModel.swift'
    model.write_text(source)
    sources = [str(p) for p in sorted((root / 'Sources').glob('*.swift')) if p.name not in ['AppModel.swift', 'Main.swift']]
    binary = work / 'ConnectionAppModelTests'
    command = ['/usr/bin/swiftc', '-module-cache-path', str(root / '.build/module-cache'), '-swift-version', '5',
               '-parse-as-library', '-target', 'arm64-apple-macosx13.0', *sources, str(model),
               str(root / 'Tests/ConnectionAppModelTests.swift'), '-o', str(binary)]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    if result.returncode == 0:
        result = subprocess.run([str(binary)], cwd=root, capture_output=True, text=True)
    log = root / '.build/verification/ConnectionAppModelTests.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    raise SystemExit(result.returncode)
