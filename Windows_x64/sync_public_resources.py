#!/usr/bin/env python3
"""Sync rebuilt public modem payloads into Windows; never uses the private checkout."""
from pathlib import Path
import hashlib
import json
import re
import shutil

WINDOWS = Path(__file__).resolve().parent
ROOT = WINDOWS.parent
SOURCE = ROOT / 'MacIMEI' / 'Resources'
DEST = WINDOWS / 'Resources'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def copy_file(source, destination):
    if not source.is_file() or source.is_symlink():
        raise SystemExit('Missing regular public resource: ' + str(source.relative_to(ROOT)))
    data = source.read_bytes()
    locally_built = source.name in ('zte-agent', 'vpnctl', 'launcher.so', 'zte_nv', 'zte_config', 'zte_config_read')
    if locally_built and data[:4] == b'\x7fELF' and (b'/Users/' in data or b'/home/' in data):
        raise SystemExit('Native resource contains an unremapped host build path: ' + source.name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)

def copy_category(name):
    source = SOURCE / name
    manifest = json.loads((source / 'SHA256.json').read_text())
    for rel, expected in manifest.items():
        path = source / rel
        if not path.resolve().is_relative_to(source.resolve()) or sha(path) != expected:
            raise SystemExit('Invalid public resource manifest: ' + name + '/' + rel)
    destination = DEST / name
    if destination.exists():
        shutil.rmtree(destination)
    for path in sorted(source.rglob('*')):
        if path.is_file():
            copy_file(path, destination / path.relative_to(source))

copy_file(SOURCE / 'Onboarding/zte-agent', DEST / 'Onboarding/zte-agent')
copy_file(SOURCE / 'Onboarding/provenance.json', DEST / 'Onboarding/provenance.json')
copy_category('VPN')
copy_category('AgentDashboard')

helper_hashes = {}
for name in ('zte_nv', 'zte_config', 'zte_config_read'):
    copy_file(ROOT / 'MacIMEI/DeviceHelpers/bin' / name, DEST / 'Helpers' / name)
    helper_hashes[name] = sha(DEST / 'Helpers' / name)
(DEST / 'Helpers/helpers.json').write_text(json.dumps(helper_hashes, indent=2) + '\n')

pins = {
    'src/Features/VpnFeatures.cs': {
        'VpnHelperHash': 'VPN/vpnctl',
        'VpnAgentHash': 'Onboarding/zte-agent',
        'DashboardHash': 'AgentDashboard/index.html',
        'LauncherHash': 'VPN/launcher.so',
    },
    'src/Features/LauncherFeatures.cs': {'LauncherManifestHash': 'VPN/launcher.sha256'},
}
for relative, fields in pins.items():
    path = WINDOWS / relative
    text = path.read_text()
    for field, resource in fields.items():
        text, count = re.subn(r'(const string ' + field + r' = ")[0-9a-f]{64}(";)',
            lambda m: m[1] + sha(DEST / resource) + m[2], text)
        if count != 1:
            raise SystemExit('Expected exactly one C# resource pin: ' + field)
    path.write_text(text)

for name in ('Onboarding', 'VPN', 'AgentDashboard'):
    folder = DEST / name
    manifest = {str(p.relative_to(folder)): sha(p) for p in sorted(folder.rglob('*'))
                if p.is_file() and p.name != 'SHA256.json'}
    (folder / 'SHA256.json').write_text(json.dumps(manifest, indent=2) + '\n')

print('Synchronized public agent, VPN, launcher, dashboards and IMEI helpers; C# pins refreshed.')
