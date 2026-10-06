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
GROUPS = ('Onboarding', 'VPN', 'AgentDashboard', 'AgentDashboardInstall', 'AgentInstallation', 'Esim', 'FirmwareSupport', 'ScreenLocalization', 'SSHAccounts')
PINS = {
    'src/Core/AgentPackage.cs': {'Sha256': 'Onboarding/zte-agent'},
    'src/Features/VpnFeatures.cs': {'VpnHelperHash': 'VPN/vpnctl', 'DashboardHash': 'AgentDashboard/index.html', 'LauncherHash': 'VPN/launcher.so'},
    'src/Features/AccessFeatures.cs': {'AccessScriptHash': 'SSHAccounts/access-services.sh'},
    'src/Features/LauncherFeatures.cs': {'LauncherManifestHash': 'VPN/launcher.sha256'},
    'src/Features/AgentDashboardFeatures.cs': {'DashboardInstallerHash': 'AgentDashboardInstall/dashboard.sh'},
    'src/Features/AdminFeatures.cs': {'AgentManagerHash': 'AgentInstallation/manager.sh', 'ScreenManagerHash': 'ScreenLocalization/install.sh'},
    'src/Research/FirmwareResearch.cs': {'ExpectedSpecificationSha256': 'FirmwareResearch/probes.json'},
    'src/Diagnostics/FirmwareSupportCollector.cs': {'ExpectedHelperSha256': 'FirmwareSupport/collect.sh'},
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

def swift_agent_upgrade_hashes(source):
    """Read the explicit reviewed Swift registry; reject executable expressions."""
    pins = re.findall(r'static let sha256 = "([0-9a-f]{64})"', source)
    registries = re.findall(r'static let supportedUpgradeHashes:\s*Set<String>\s*=\s*\[(.*?)\]', source, re.S)
    if len(pins) != 1 or len(registries) != 1:
        raise ValueError('Missing or ambiguous Swift agent registry')
    tokens = [part.strip() for part in re.sub(r'//[^\n]*', '', registries[0]).split(',')]
    if tokens and not tokens[-1]: tokens.pop()
    if tokens.count('sha256') != 1 or any(token != 'sha256' and not re.fullmatch(r'"[0-9a-f]{64}"', token) for token in tokens):
        raise ValueError('Unsupported Swift agent registry expression')
    return pins[0], {pins[0]} | {token[1:-1] for token in tokens if token != 'sha256'}


def synchronize_agent_upgrade_hashes(source, current, hashes):
    pins = re.findall(r'const string Sha256\s*=\s*"([0-9a-f]{64})";', source)
    if pins != [current] or current not in hashes:
        raise ValueError('Swift/Windows current agent pin mismatch')
    pattern = r'(SupportedUpgradeHashes\s*=\s*new\[\]\s*\{)(.*?)(\}\.ToFrozenSet\(StringComparer\.Ordinal\);)'
    body = '\n        Sha256,\n' + ''.join('        "' + value + '",\n' for value in sorted(hashes - {current})) + '    '
    updated, count = re.subn(pattern, lambda match: match[1] + body + match[3], source, flags=re.S)
    if count != 1:
        raise ValueError('Missing or ambiguous Windows agent registry')
    return updated

def synchronize_agent_access_registry(root, check=False):
    """Generate service ownership checks from the same reviewed release registry."""
    _, hashes = swift_agent_upgrade_hashes((root / 'MacIMEI/Sources/BundledAgent.swift').read_text())
    folder = root / 'MacIMEI/Resources/SSHAccounts'
    script = regular(folder / 'access-services.sh')
    source = script.read_text()
    begin, end = '# BEGIN_REVIEWED_AGENT_HASHES', '# END_REVIEWED_AGENT_HASHES'
    if source.count(begin) != 1 or source.count(end) != 1:
        raise ValueError('Missing or ambiguous service agent registry')
    body = (begin + '\nknown_agent_hash() {\n    case "$1" in\n      '
            + '|'.join(sorted(hashes)) + ') return 0;;\n      *) return 1;;\n    esac\n}\n' + end)
    updated = re.sub(re.escape(begin) + r'.*?' + re.escape(end), lambda _: body, source, flags=re.S)
    if check:
        if updated != source: raise ValueError('Service agent upgrade registry mismatch')
    else:
        # Validate all previous resource bytes before updating this one generated entry.
        manifest = validate_group(folder)
        script.write_text(updated)
        manifest['access-services.sh'] = sha(script)
        (folder / 'SHA256.json').write_text(json.dumps(manifest, indent=2) + '\n')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='Verify mirrored resources and compiled pins without edits')
    args = parser.parse_args()
    swift_current, upgrade_hashes = swift_agent_upgrade_hashes((ROOT / 'MacIMEI/Sources/BundledAgent.swift').read_text())
    synchronize_agent_access_registry(ROOT, check=args.check)
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
    if swift_current != sha(DEST / 'Onboarding/zte-agent'): raise ValueError('Swift/current resource agent pin mismatch')
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
            updated = synchronize_agent_upgrade_hashes(text, swift_current, upgrade_hashes)
            if args.check and updated != text: raise ValueError('Windows agent upgrade registry mismatch')
            text = updated
        if not args.check: path.write_text(text)
    print('PASS public resource identity, exact manifests, helpers and Windows compiled pins')

if __name__ == '__main__':
    main()
