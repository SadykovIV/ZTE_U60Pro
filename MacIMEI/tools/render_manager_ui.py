#!/usr/bin/env python3
"""Render production SwiftUI screens with temporary model data, never a modem.

The UI harness uses a disconnected model, isolated preferences, synthetic inventory
and a temporary .app. No existing connection profile or catalog cache is used.
"""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
output = root / 'dist/ui-preview'
output.mkdir(parents=True, exist_ok=True)
(root / '.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='manager-ui-', dir=root / '.build') as directory:
    work = Path(directory)
    source = (root / 'Sources/AppModel.swift').read_text()
    for old, new in [('Library/Application Support/ZTE IMEI Studio', work / 'state')]:
        literal = 'FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("' + old + '")'
        assert literal in source, f'Storage isolation needs update: {old}'
        source = source.replace(literal, 'URL(fileURLWithPath: ' + json.dumps(str(new)) + ')')
    model = work / 'AppModel.swift'
    model.write_text(source)
    # Fail closed if a future view change reintroduces discovery during rendering.
    # This temporary backend guard never alters the production UI implementation.
    connections = work / 'AppModelConnections.swift'
    connections_source = (root / 'Sources/AppModelConnections.swift').read_text()
    discovery = 'discoverConnections(authenticate: false)'
    assert connections_source.count(discovery) == 1
    connections.write_text(connections_source.replace(discovery, 'preconditionFailure("UI preview attempted modem discovery")'))
    app = work / 'ManagerUIPreview.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    resources = app / 'Resources'
    resources.mkdir()
    for name in ['Branding', 'Localization', 'Catalog', 'Terminal']:
        shutil.copytree(root / 'Resources' / name, resources / name)
    (resources / 'DiagnosticTools').mkdir()
    shutil.copy2(root / 'Resources/DiagnosticTools/bundle.json', resources / 'DiagnosticTools/bundle.json')
    with (app / 'Info.plist').open('wb') as handle:
        plistlib.dump({'CFBundleIdentifier': 'local.zte.manager-ui-preview',
                      'CFBundleExecutable': 'ManagerUIPreview', 'CFBundleName': 'Manager UI Preview',
                      'CFBundleVersion': '25', 'CFBundleShortVersionString': '1.20.0',
                      'NSHighResolutionCapable': False, 'LSUIElement': True}, handle)
    binary = app / 'MacOS/ManagerUIPreview'
    sources = [str(p) for p in sorted((root / 'Sources').glob('*.swift')) if p.name not in ['AppModel.swift', 'AppModelConnections.swift', 'Main.swift']]
    command = ['/usr/bin/swiftc', '-module-cache-path', str(root / '.build/module-cache'),
               '-swift-version', '5', '-parse-as-library', '-target', 'arm64-apple-macosx13.0',
               *sources, str(model), str(connections), str(root / 'Tests/ManagerUIPreview.swift'), '-o', str(binary)]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    log = result.stdout + result.stderr
    if result.returncode == 0:
        result = subprocess.run([str(binary), str(output)], cwd=root, capture_output=True, text=True, timeout=90)
        log += result.stdout + result.stderr
    log_path = root / '.build/verification/ManagerUIPreview.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(log)
    print(log, end='')
    raise SystemExit(result.returncode)
