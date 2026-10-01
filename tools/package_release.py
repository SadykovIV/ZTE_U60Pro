#!/usr/bin/env python3
"""Package verified public builds. Does not publish or connect to a device."""
from pathlib import Path
import gzip
import hashlib
import json
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'release'
RES = ROOT / 'MacIMEI/Resources'
VERSION = '1.23.2'
AGENT_VERSION = '2.7.0-esim.8'
RELEASE_URL = f'https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v{VERSION}/'
OUT.mkdir(exist_ok=True)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def tar_gz(path, entries):
    with path.open('wb') as dest, gzip.GzipFile(filename='', fileobj=dest, mode='wb', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w') as tar:
            for name, source in sorted(entries.items()):
                source = Path(source)
                if not source.is_file() or source.is_symlink():
                    raise SystemExit('Expected regular release input: ' + name)
                info = tarfile.TarInfo(name)
                info.size = source.stat().st_size
                info.mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
                info.mtime = 0
                with source.open('rb') as stream:
                    tar.addfile(info, stream)


def copy_artifact(source, name):
    target = OUT / name
    if target.exists():
        raise SystemExit('Refusing to overwrite release artifact: ' + name)
    shutil.copyfile(source, target)
    return target


# Refuse inconsistent or private inputs before creating any release output.
if any(OUT.iterdir()):
    raise SystemExit('Release output must be empty; preserve previous artifacts in a separate directory')
agent_hash = sha(RES / 'Onboarding/zte-agent')
for app in ['MacIMEI', 'Windows_x64']:
    resources = ROOT / app / 'Resources'
    if sha(resources / 'Onboarding/zte-agent') != agent_hash or sha(resources / 'Esim/zte-agent-esim') != agent_hash:
        raise SystemExit('Permanent/RPC agent mismatch: ' + app)
    for path in resources.rglob('*'):
        if path.is_file() and path.name in {'trusted_known_hosts', 'known_hosts', 'ssclash-linux-arm64', 'id_ed25519', 'id_rsa', 'connection.json'}:
            raise SystemExit('Private/prohibited resource: ' + path.name)
    for group in ['Esim', 'Onboarding', 'VPN', 'AgentDashboard', 'AgentDashboardInstall', 'AgentInstallation']:
        base = resources / group
        expected = json.loads((base / 'SHA256.json').read_text())
        for name, want in expected.items():
            if sha(base / name) != want:
                raise SystemExit('Resource hash mismatch: ' + app + '/' + group + '/' + name)
for name in [f'MacIMEI/dist/ZTE-U60Pro-Manager-{VERSION}-arm64.zip',
             f'Windows_x64/dist/ZTE-U60Pro-Manager-{VERSION}-Windows-x64-portable.zip',
             'MacIMEI/dist/build-manifest.json', f'Windows_x64/dist/windows-{VERSION}-build-manifest.json']:
    if not (ROOT / name).is_file():
        raise SystemExit('Missing verified build: ' + name)

artifacts = []
artifacts.append(copy_artifact(ROOT / f'MacIMEI/dist/ZTE-U60Pro-Manager-{VERSION}-arm64.zip',
                               f'ZTE-U60Pro-Manager-{VERSION}-macOS-arm64.zip'))
artifacts.append(copy_artifact(ROOT / f'Windows_x64/dist/ZTE-U60Pro-Manager-{VERSION}-Windows-x64-portable.zip',
                               f'ZTE-U60Pro-Manager-{VERSION}-Windows-x64-portable.zip'))
agent = copy_artifact(RES / 'Onboarding/zte-agent', f'zte-agent-{AGENT_VERSION}-aarch64-linux-musl')
agent.chmod(0o755)
artifacts.append(agent)
entries = {'zte-agent': agent, 'README.md': ROOT / 'docs/AGENT.md',
           'LICENSE': ROOT / 'ModemAgent/LICENSE', 'THIRD_PARTY_NOTICES.md': ROOT / 'THIRD_PARTY_NOTICES.md', 'LICENSE-SCOPE.md': ROOT / 'LICENSE-SCOPE.md'}
for folder, prefix in [(RES / 'AgentDashboard', 'dashboard'), (RES / 'Esim', 'esim'), (RES / 'AgentDashboardInstall', 'dashboard-install'), (RES / 'AgentInstallation', 'agent-install'), (ROOT / 'licenses', 'licenses')]:
    for path in folder.rglob('*'):
        if path.is_file():
            entries[f'{prefix}/{path.relative_to(folder).as_posix()}'] = path
manifest = OUT / 'agent-SHA256SUMS'
manifest.write_text(''.join(f'{sha(path)}  {name}\n' for name, path in sorted(entries.items())))
entries['SHA256SUMS'] = manifest
agent_archive = OUT / f'ZTE-Agent-{AGENT_VERSION}-aarch64-linux-musl.tar.gz'
tar_gz(agent_archive, entries)
manifest.unlink()
artifacts.append(agent_archive)

# Explicit allowlist: runtime dependencies and generated modem payloads allow a
# Windows-only checkout to build without macOS or an ARM64 cross compiler.
common = ['Onboarding/dropbear', 'Onboarding/zte-agent', 'SSHAccounts/dropbear', 'SSHAccounts/doas',
          'VPN/mihomo', 'VPN/dashboard-uhttpd', 'VPN/vpnctl', 'VPN/launcher.so', 'VPN/dashboard.tar.gz',
          'HostTools/zte-timeout', 'DiagnosticTools/bundle.tar.gz', 'ExperimentalOpkg/runtime.tar.gz',
          'Esim/zte-agent-esim', 'Esim/eSIM-sources.tar.gz',
          'AgentDashboardInstall/dashboard.tar.gz', 'AgentDashboardInstall/dashboard-uhttpd']
paths = ['MacIMEI/Resources/Onboarding/adb']
for base in ['MacIMEI/Resources', 'Windows_x64/Resources']:
    paths.extend(f'{base}/{relative}' for relative in common)
    paths.extend(path.relative_to(ROOT).as_posix() for path in sorted((ROOT / base / 'AgentDashboard/assets').glob('*')) if path.is_file())
for name in ['zte_nv', 'zte_config', 'zte_config_read']:
    paths.extend([f'MacIMEI/DeviceHelpers/bin/{name}', f'Windows_x64/Resources/Helpers/{name}'])
paths.extend(['MacIMEI/DeviceHelpers/bin/manifest.json', 'ModemAgent/agent/resources/esim/bridge',
              'ModemAgent/agent/resources/esim/lpac'])
paths.extend(path.relative_to(ROOT).as_posix() for path in sorted((ROOT / 'Windows_x64/Resources/Tools').rglob('*'))
             if path.is_file() and path.suffix.lower() in ('.exe', '.dll'))
deps = {name: ROOT / name for name in sorted(set(paths))}
deps['THIRD_PARTY_NOTICES.md'] = ROOT / 'THIRD_PARTY_NOTICES.md'
deps['LICENSE-SCOPE.md'] = ROOT / 'LICENSE-SCOPE.md'
for base in [RES, ROOT / 'Windows_x64/Resources', ROOT / 'licenses']:
    for path in base.rglob('*'):
        if path.is_file() and (base.name == 'licenses' or 'LICENSE' in path.name.upper() or 'NOTICE' in path.name.upper()):
            deps['notices/' + path.relative_to(ROOT).as_posix()] = path
dependency_archive = OUT / f'Build-dependencies-{VERSION}.tar.gz'
tar_gz(dependency_archive, deps)
meta = {'archive': dependency_archive.name, 'url': RELEASE_URL + dependency_archive.name,
        'sha256': sha(dependency_archive), 'files': {name: sha(ROOT / name) for name in sorted(set(paths))}}
(ROOT / 'tools/dependencies.json').write_text(json.dumps(meta, indent=2) + '\n')
artifacts.append(dependency_archive)

# Sources are separate so a normal build need not download the GCC source tree.
source_root = ROOT / '.cache/public-sources'
if not (source_root / 'SOURCES.json').is_file():
    raise SystemExit('Missing .cache/public-sources/SOURCES.json and corresponding sources')
sources = {}
for line in (source_root / 'SHA256SUMS').read_text().splitlines():
    expected, name = line.split('  ', 1)
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit('Unsafe corresponding-source path')
    path = source_root / relative
    if sha(path) != expected:
        raise SystemExit('Corresponding-source hash mismatch: ' + name)
    sources[name] = path
for name in ['mihomo-v1.19.31-source.tar.gz', 'opendoas-6.8.2.tar.xz']:
    sources[name] = ROOT / '.cache' / name
sources['eSIM-sources.tar.gz'] = RES / 'Esim/eSIM-sources.tar.gz'
sources['eSIM-PROVENANCE.json'] = RES / 'Esim/PROVENANCE.json'
sources['ESIM-SOURCES.md'] = ROOT / 'third_party/ESIM-SOURCES.md'
for path in (RES / 'Esim').glob('LICENSE-*.txt'):
    sources['eSIM-licenses/' + path.name] = path
sources['THIRD_PARTY_NOTICES.md'] = ROOT / 'THIRD_PARTY_NOTICES.md'
sources['LICENSE-SCOPE.md'] = ROOT / 'LICENSE-SCOPE.md'
source_sums = OUT / 'sources-SHA256SUMS'
source_sums.write_text(''.join(f'{sha(path)}  {name}\n' for name, path in sorted(sources.items())))
sources['SHA256SUMS'] = source_sums
source_archive = OUT / f'Third-party-sources-{VERSION}.tar.gz'
tar_gz(source_archive, sources)
source_sums.unlink()
artifacts.append(source_archive)
artifacts.append(copy_artifact(ROOT / 'MacIMEI/dist/build-manifest.json', 'macOS-build-manifest.json'))
artifacts.append(copy_artifact(ROOT / f'Windows_x64/dist/windows-{VERSION}-build-manifest.json', 'Windows-build-manifest.json'))
release_manifest = OUT / 'release-manifest.json'
release_manifest.write_text(json.dumps({'version': VERSION, 'previousRelease': 'v1.20.0', 'agentVersion': AGENT_VERSION,
                                      'vpnctlVersion': '1.3.0', 'esim': {'card': 'physical removable eUICC',
                                      'testedCard': '9eSIM V0', 'testedFirmware': 'CN_ZTE_MU5250V1.0.0B31',
                                      'builtInZteSupported': False, 'qmiEs10LicenseStatus': 'unspecified'},
                                      'artifacts': {path.name: {'bytes': path.stat().st_size, 'sha256': sha(path)}
                                                    for path in sorted(artifacts)}}, indent=2) + '\n')
artifacts.append(release_manifest)
(OUT / 'SHA256SUMS').write_text(''.join(f'{sha(path)}  {path.name}\n' for path in sorted(artifacts)))
print('Public release artifacts:', ', '.join(path.name for path in artifacts))
