#!/usr/bin/env python3
"""Package verified public builds. Does not publish or connect to a device."""
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import re
import shutil
import tarfile
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, default=ROOT / 'release')
parser.add_argument('--previous-release', required=True)
parser.add_argument('--build-source-commit', required=True)
args = parser.parse_args()
if re.fullmatch(r'v\d+\.\d+(?:\.\d+)?', args.previous_release) is None or re.fullmatch(r'[0-9a-f]{40}', args.build_source_commit) is None:
    raise SystemExit('Invalid previous release or build source commit')
OUT = args.output_dir
RES = ROOT / 'MacIMEI/Resources'
VERSION = re.search(r'<Version>([^<]+)</Version>', (ROOT / 'Windows_x64/src/ZteImeiStudio.Windows.csproj').read_text()).group(1)
AGENT_VERSION = re.search(r'static let version = "([^"]+)"', (ROOT / 'MacIMEI/Sources/BundledAgent.swift').read_text()).group(1)
RELEASE_URL = f'https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v{VERSION}/'
OUT.mkdir(parents=True, exist_ok=True)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def vpnctl_metadata(root):
    """Describe measured inputs; the Cargo version is not proof of a source commit."""
    cargo_path = root / 'ModemAgent/vpnctl/Cargo.toml'
    cargo = tomllib.loads(cargo_path.read_text())['package']
    version = cargo.get('version')
    if cargo.get('name') != 'zte-vpnctl' or not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise SystemExit('Invalid VPN controller package/version')
    resources = root / 'MacIMEI/Resources'
    binary_hash = sha(resources / 'VPN/vpnctl')
    archive_path = resources / 'Esim/eSIM-sources.tar.gz'
    archive_hash = sha(archive_path)
    for app in ['MacIMEI', 'Windows_x64']:
        base = root / app / 'Resources'
        manifest = json.loads((base / 'VPN/SHA256.json').read_text())
        provenance = json.loads((base / 'Esim/PROVENANCE.json').read_text())
        if sha(base / 'VPN/vpnctl') != binary_hash or manifest.get('vpnctl') != binary_hash:
            raise SystemExit('VPN controller identity mismatch: ' + app)
        if sha(base / 'Esim/eSIM-sources.tar.gz') != archive_hash or provenance.get('source_archive_sha256') != archive_hash:
            raise SystemExit('VPN corresponding-source archive mismatch: ' + app)
    inputs = {'ModemAgent/Cargo.toml', 'ModemAgent/Cargo.lock'}
    for folder in ['ModemAgent/vpnctl', 'ModemAgent/process-runner', 'ModemAgent/.cargo']:
        inputs.update(p.relative_to(root).as_posix() for p in (root / folder).rglob('*')
                      if p.is_file() and not {'target', '.git'}.intersection(p.relative_to(root / folder).parts)
                      and (p.suffix in {'.rs', '.toml'} or p.name == 'Cargo.lock'))
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = archive.getmembers()
        if len({m.name for m in members}) != len(members):
            raise SystemExit('Duplicate corresponding-source member')
        names = {m.name: m for m in members}
        for name in sorted(inputs):
            member = names.get(name)
            if member is None or not member.isfile() or archive.extractfile(member).read() != (root / name).read_bytes():
                raise SystemExit('Stale VPN corresponding source: ' + name)
    return {'version': version, 'sha256': binary_hash, 'versionSource': 'ModemAgent/vpnctl/Cargo.toml',
            'versionSourceSha256': sha(cargo_path), 'correspondingSourceArchiveSha256': archive_hash,
            'verifiedSourceInputs': {name: sha(root / name) for name in sorted(inputs)}}


def desktop_build_identity(root, version, controller):
    """Bind packaging inputs to build hashes without treating Git HEAD as a build ID."""
    manifests = {}
    for app, filename in [('MacIMEI', 'build-manifest.json'), ('Windows_x64', f'windows-{version}-build-manifest.json')]:
        base = root / app
        path = base / 'dist' / filename
        data = json.loads(path.read_text())
        if data.get('version') != version:
            raise SystemExit('Desktop build version mismatch: ' + app)
        if app == 'MacIMEI':
            sources = data['source_sha256']
            actual = {p.relative_to(base).as_posix() for p in (base / 'Sources').glob('*.swift')}
            archive = base / f'dist/ZTE-U60Pro-Manager-{version}-arm64.zip'
            expected_zip_hash = data['zip_sha256']
            resources = data['bundle_resources_sha256']
        else:
            sources = data['sources']
            actual = {p.relative_to(base).as_posix() for p in (base / 'src').rglob('*')
                      if p.is_file() and not {'bin', 'obj'}.intersection(p.relative_to(base / 'src').parts)
                      and (p.suffix in {'.cs', '.csproj'} or p.name == 'packages.lock.json')}
            archive = base / f'dist/ZTE-U60Pro-Manager-{version}-Windows-x64-portable.zip'
            expected_zip_hash = data['zip']['sha256']
            resources = data['resources']
        if not sources or set(sources) != actual or any(sha(base / name) != digest for name, digest in sources.items()):
            raise SystemExit('Desktop sources differ from build manifest: ' + app)
        if sha(archive) != expected_zip_hash:
            raise SystemExit('Desktop ZIP differs from build manifest: ' + app)
        if resources.get('VPN/vpnctl') != controller['sha256'] or resources.get('Esim/eSIM-sources.tar.gz') != controller['correspondingSourceArchiveSha256']:
            raise SystemExit('Desktop VPN/source resources differ from release inputs: ' + app)
        manifests[app] = sha(path)
    try:
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=root, stderr=subprocess.DEVNULL))
    except (subprocess.CalledProcessError, FileNotFoundError):
        head, dirty = None, None
    return {'basis': 'Exact desktop source, ZIP and controller/source-archive hashes from build manifests',
            'buildSourceCommitInformationalOnly': True, 'packagingHead': head, 'workingTreeDirty': dirty,
            'desktopBuildManifestSha256': manifests}


def support_dependency_paths(root):
    """Keep generated adaptation tools rebuildable from the dependency download."""
    names = {'NOTICE-QMI.txt', 'README.txt', 'collect.sh', 'radio-inspect-build.json',
             'support-helpers.json', 'support-sources.tar.gz',
             'zte-support-config', 'zte-support-nv', 'zte-support-qmi'}
    paths = []
    reference = None
    for app in ['MacIMEI', 'Windows_x64']:
        base = root / app / 'Resources/FirmwareSupport'
        manifest = json.loads((base / 'SHA256.json').read_text())
        if set(manifest) != names:
            raise SystemExit('Unexpected firmware support resource set: ' + app)
        if reference is not None and manifest != reference:
            raise SystemExit('Firmware support resources differ between desktop clients')
        reference = manifest
        for name in sorted(names | {'SHA256.json'}):
            source = base / name
            if not source.is_file() or source.is_symlink():
                raise SystemExit('Missing regular firmware support resource: ' + app + '/' + name)
            if name in manifest and sha(source) != manifest[name]:
                raise SystemExit('Firmware support resource hash mismatch: ' + app + '/' + name)
            paths.append(source.relative_to(root).as_posix())
    return paths


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
source_root = ROOT / '.cache/public-sources'
for path in [source_root / 'SOURCES.json', source_root / 'SHA256SUMS',
             ROOT / '.cache/mihomo-v1.19.31-source.tar.gz', ROOT / '.cache/opendoas-6.8.2.tar.xz']:
    if not path.is_file():
        raise SystemExit('Missing corresponding-source input: ' + path.name)
for line in (source_root / 'SHA256SUMS').read_text().splitlines():
    expected, name = line.split('  ', 1)
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts or sha(source_root / relative) != expected:
        raise SystemExit('Invalid corresponding-source input: ' + name)
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

controller_metadata = vpnctl_metadata(ROOT)
build_source_identity = desktop_build_identity(ROOT, VERSION, controller_metadata)
support_paths = support_dependency_paths(ROOT)

artifacts = []
artifacts.append(copy_artifact(ROOT / f'MacIMEI/dist/ZTE-U60Pro-Manager-{VERSION}-arm64.zip',
                               f'ZTE-U60Pro-Manager-{VERSION}-macOS-arm64.zip'))
artifacts.append(copy_artifact(ROOT / f'Windows_x64/dist/ZTE-U60Pro-Manager-{VERSION}-Windows-x64-portable.zip',
                               f'ZTE-U60Pro-Manager-{VERSION}-Windows-x64-portable.zip'))
agent = copy_artifact(RES / 'Onboarding/zte-agent', f'zte-agent-{AGENT_VERSION}-aarch64-linux-musl')
agent.chmod(0o755)
artifacts.append(agent)
entries = {'zte-agent': agent, 'README.md': ROOT / 'docs/AGENT-PACKAGE.md',
           f'RELEASE-{VERSION}.md': ROOT / f'docs/RELEASE-{VERSION}.md',
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
paths = ['MacIMEI/Resources/Onboarding/adb', *support_paths]
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
sources['firmware-support-sources.tar.gz'] = RES / 'FirmwareSupport/support-sources.tar.gz'
sources['firmware-support-NOTICE-QMI.txt'] = RES / 'FirmwareSupport/NOTICE-QMI.txt'
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
release_manifest.write_text(json.dumps({'version': VERSION, 'previousRelease': args.previous_release, 'agentVersion': AGENT_VERSION,
                                      'buildSourceCommit': args.build_source_commit,
                                      'buildSourceIdentity': build_source_identity,
                                      'testedDevice': {'model': 'ZTE U60 Pro / MU5250', 'firmware': 'CN_ZTE_MU5250V1.0.0B31',
                                                       'innerVersion': 'BD_CNMU5250V1.0.0B31'},
                                      'windowsNativeRuntimeVerified': False, 'b28HardwareVerified': False, 'b04HardwareVerified': False,
                                      'vpnctlVersion': controller_metadata['version'], 'vpnctl': controller_metadata, 'esim': {'card': 'physical removable eUICC',
                                      'historicallyTestedCard': '9eSIM V0', 'testedFirmware': 'CN_ZTE_MU5250V1.0.0B31',
                                      'profileMutationsHardwareTestedInThisRelease': False,
                                      'builtInZteSupported': False, 'qmiEs10LicenseStatus': 'unspecified'},
                                      'artifacts': {path.name: {'bytes': path.stat().st_size, 'sha256': sha(path)}
                                                    for path in sorted(artifacts)}}, indent=2) + '\n')
artifacts.append(release_manifest)
(OUT / 'SHA256SUMS').write_text(''.join(f'{sha(path)}  {path.name}\n' for path in sorted(artifacts)))
print('Public release artifacts:', ', '.join(path.name for path in artifacts))
