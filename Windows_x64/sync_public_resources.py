#!/usr/bin/env python3
"""Sync verified public Mac resources and refresh Windows pins; no private paths/network."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import re
import shutil

WINDOWS = Path(__file__).resolve().parent
ROOT = WINDOWS.parent
SOURCE = ROOT / 'MacIMEI/Resources'
DEST = WINDOWS / 'Resources'
GROUPS = ('Onboarding', 'VPN', 'AgentDashboard', 'AgentDashboardInstall', 'AgentInstallation', 'Esim')
PINS = {
    'src/Core/AgentPackage.cs': {'Sha256': 'Onboarding/zte-agent'},
    'src/Features/VpnFeatures.cs': {'VpnHelperHash': 'VPN/vpnctl', 'DashboardHash': 'AgentDashboard/index.html', 'LauncherHash': 'VPN/launcher.so'},
    'src/Features/LauncherFeatures.cs': {'LauncherManifestHash': 'VPN/launcher.sha256'},
    'src/Features/AgentDashboardFeatures.cs': {'DashboardInstallerHash': 'AgentDashboardInstall/dashboard.sh'},
    'src/Features/AdminFeatures.cs': {'AgentManagerHash': 'AgentInstallation/manager.sh'},
    'src/Research/FirmwareResearch.cs': {'ExpectedSpecificationSha256': 'FirmwareResearch/probes.json'},
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def regular(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError('Expected a regular public resource: ' + path.name)
    if path.name in ('ssclash-linux-arm64', 'trusted_known_hosts'):
        raise ValueError('Private-only resource refused')
    return path

def validate_group(folder):
    regular(folder / 'SHA256.json')
    manifest = json.loads((folder / 'SHA256.json').read_text())
    if not isinstance(manifest, dict) or not manifest:
        raise ValueError('Empty or invalid manifest: ' + folder.name)
    for name, expected in manifest.items():
        rel = PurePosixPath(name)
        if rel.is_absolute() or '..' in rel.parts or str(rel) != name or '\\' in name or not re.fullmatch('[0-9a-f]{64}', expected):
            raise ValueError('Invalid manifest entry')
        path = folder / name
        if any(parent.is_symlink() for parent in (path, *path.parents)) or sha(regular(path)) != expected:
            raise ValueError('Resource hash or path mismatch: ' + folder.name + '/' + name)
    actual = {str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != set(manifest) | {'SHA256.json'}:
        raise ValueError('Manifest does not cover exact file set: ' + folder.name)
    return manifest

def copy_file(source, destination):
    regular(source)
    data = source.read_bytes()
    locally_built = source.name in ('zte-agent', 'zte-agent-esim', 'vpnctl', 'launcher.so', 'zte_nv', 'zte_config', 'zte_config_read')
    if locally_built and data[:4] == b'\x7fELF' and (b'/Users/' in data or b'/home/' in data):
        raise ValueError('Unremapped host build path in native resource: ' + source.name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='Verify mirrored resources and compiled pins without edits')
    args = parser.parse_args()
    manifests = {name: validate_group(SOURCE / name) for name in GROUPS}
    for name, manifest in manifests.items():
        destination = DEST / name
        if not args.check:
            if destination.exists(): shutil.rmtree(destination)
            for rel in sorted(set(manifest) | {'SHA256.json'}):
                copy_file(SOURCE / name / rel, destination / rel)
        if validate_group(destination) != manifest or sha(destination / 'SHA256.json') != sha(SOURCE / name / 'SHA256.json'):
            raise ValueError('Mac/Windows resource mismatch: ' + name)
    for rel in ('FirmwareResearch/probes.json',):
        if not args.check: copy_file(SOURCE / rel, DEST / rel)
        if sha(DEST / rel) != sha(SOURCE / rel): raise ValueError('Resource mismatch: ' + rel)
    helpers = {}
    for name in ('zte_nv', 'zte_config', 'zte_config_read'):
        source = ROOT / 'MacIMEI/DeviceHelpers/bin' / name
        if not args.check: copy_file(source, DEST / 'Helpers' / name)
        helpers[name] = sha(source)
        if sha(DEST / 'Helpers' / name) != helpers[name]: raise ValueError('Helper mismatch: ' + name)
    if not args.check: (DEST / 'Helpers/helpers.json').write_text(json.dumps(helpers, indent=2) + '\n')
    if json.loads((DEST / 'Helpers/helpers.json').read_text()) != helpers: raise ValueError('Helper manifest mismatch')
    version = json.loads((DEST / 'Onboarding/provenance.json').read_text())['local_agent_version']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.]+)?', version): raise ValueError('Invalid agent version')
    if sha(DEST / 'Esim/zte-agent-esim') != sha(DEST / 'Onboarding/zte-agent'): raise ValueError('RPC and installed agents differ')
    for relative, fields in PINS.items():
        path = WINDOWS / relative
        text = path.read_text()
        for field, resource in fields.items():
            pattern = r'(const string ' + field + r'\s*=\s*")[0-9a-f]{64}(";)'
            updated, count = re.subn(pattern, lambda m: m[1] + sha(DEST / resource) + m[2], text)
            if count != 1 or (args.check and updated != text): raise ValueError('C# resource pin mismatch: ' + field)
            text = updated
        if relative == 'src/Core/AgentPackage.cs':
            updated, count = re.subn(r'(const string Version = ")[^"]+(";)', lambda m: m[1] + version + m[2], text)
            if count != 1 or (args.check and updated != text): raise ValueError('Agent version mismatch')
            text = updated
        if not args.check: path.write_text(text)
    print('PASS public resource identity, exact manifests, helpers and Windows compiled pins')

if __name__ == '__main__':
    main()
