#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/dist/ZTE U60Pro Manager.app"
if [[ -e "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build/module-cache"
/usr/bin/swiftc -module-cache-path "$PWD/.build/module-cache" -swift-version 5 -parse-as-library -debug-prefix-map "$PWD"=MacIMEI -O -target arm64-apple-macosx13.0 Sources/*.swift -o "$APP/Contents/MacOS/ZTEU60ProManager"
cp DeviceHelpers/bin/zte_nv DeviceHelpers/bin/zte_config DeviceHelpers/bin/zte_config_read "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Onboarding"
cp Resources/Onboarding/* "$APP/Contents/Resources/Onboarding/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp Resources/Licenses/* "$APP/Contents/Resources/Licenses/"
mkdir -p "$APP/Contents/Resources/SSHAccounts" "$APP/Contents/Resources/Applications" "$APP/Contents/Resources/ScreenLocalization" "$APP/Contents/Resources/TTL" "$APP/Contents/Resources/DeviceBackups" "$APP/Contents/Resources/AgentDashboard"
cp Resources/SSHAccounts/* "$APP/Contents/Resources/SSHAccounts/"
if [[ -d Resources/Applications ]]; then cp -R Resources/Applications/. "$APP/Contents/Resources/Applications/"; fi
mkdir -p "$APP/Contents/Resources/VPN"
cp Resources/VPN/* "$APP/Contents/Resources/VPN/"
mkdir -p "$APP/Contents/Resources/AgentInstallation"
cp Resources/AgentInstallation/* "$APP/Contents/Resources/AgentInstallation/"
cp Resources/ScreenLocalization/* "$APP/Contents/Resources/ScreenLocalization/"
cp Resources/TTL/* "$APP/Contents/Resources/TTL/"
cp Resources/DeviceBackups/* "$APP/Contents/Resources/DeviceBackups/"
mkdir -p "$APP/Contents/Resources/SystemBackups"
cp Resources/SystemBackups/* "$APP/Contents/Resources/SystemBackups/"
mkdir -p "$APP/Contents/Resources/DiagnosticTools"
cp Resources/DiagnosticTools/* "$APP/Contents/Resources/DiagnosticTools/"
mkdir -p "$APP/Contents/Resources/ExperimentalOpkg"
mkdir -p "$APP/Contents/Resources/HostTools"
for name in zte-timeout SHA256.json README.md PROVENANCE.json LICENSES.txt; do
    cp "Resources/HostTools/$name" "$APP/Contents/Resources/HostTools/$name"
done
for name in manager.sh runtime.tar.gz runtime.json PROVENANCE.json SHA256.json; do
    cp "Resources/ExperimentalOpkg/$name" "$APP/Contents/Resources/ExperimentalOpkg/$name"
done
if [[ -f Resources/ExperimentalOpkg/LICENSES.txt ]]; then cp Resources/ExperimentalOpkg/LICENSES.txt "$APP/Contents/Resources/ExperimentalOpkg/"; fi
mkdir -p "$APP/Contents/Resources/Terminal"
cp Resources/Terminal/* "$APP/Contents/Resources/Terminal/"
for folder in Branding Localization Catalog; do
    mkdir -p "$APP/Contents/Resources/$folder"
    cp -R "Resources/$folder/." "$APP/Contents/Resources/$folder/"
done
cp -R Resources/AgentDashboard/. "$APP/Contents/Resources/AgentDashboard/"
/usr/bin/codesign --force --sign - "$APP/Contents/Resources/Onboarding/adb"
python3 - "$APP" <<'PY'
import hashlib,json,pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); res=app/'Contents/Resources'
(res/'helpers.json').write_text(json.dumps({n:hashlib.sha256((res/n).read_bytes()).hexdigest() for n in ['zte_nv','zte_config','zte_config_read']},indent=2)+'\n')
info={'CFBundleName':'ZTE U60Pro Manager','CFBundleDisplayName':'ZTE U60Pro Manager','CFBundleIdentifier':'local.zte.imei-studio','CFBundleVersion':'25','CFBundleShortVersionString':'1.20.0','CFBundleExecutable':'ZTEU60ProManager','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0','LSArchitecturePriority':['arm64'],'NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsArbitraryLoads':True},'NSPrincipalClass':'NSApplication','NSLocalNetworkUsageDescription':'Подключение к вашему модему для чтения, резервного копирования и настройки устройства.','CFBundleIconFile':'AppIcon'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
setup=res/'Onboarding'
(setup/'SHA256.json').write_text(json.dumps({n:hashlib.sha256((setup/n).read_bytes()).hexdigest() for n in ['adb','zte-agent','dropbear','setup-agent.sh','start_zte_imei_studio.sh']},indent=2)+'\n')
PY
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/ZTE-U60Pro-Manager-1.20.0-arm64.zip"
(cd dist && /usr/bin/shasum -a 256 "ZTE-U60Pro-Manager-1.20.0-arm64.zip") > "$PWD/dist/SHA256SUMS"
python3 - "$APP" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1]); root = pathlib.Path.cwd(); res = app/'Contents/Resources'
info = plistlib.loads((app/'Contents/Info.plist').read_bytes()); version = info['CFBundleShortVersionString']
archive = root/'dist'/f'ZTE-U60Pro-Manager-{version}-arm64.zip'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
resources = {str(p.relative_to(res)): sha(p) for p in sorted(res.rglob('*')) if p.is_file()}
for name in resources:
    if pathlib.Path(name).name in {'id_ed25519', 'id_rsa', 'nv0.bin', 'nv1.bin', 'config.bin', 'back_parameter', 'connection.json'}:
        raise SystemExit('Private device file in application bundle: ' + name)
for manifest, directory in [('helpers.json', res), ('Onboarding/SHA256.json', res/'Onboarding'), ('SSHAccounts/SHA256.json', res/'SSHAccounts'), ('ScreenLocalization/SHA256.json', res/'ScreenLocalization'), ('TTL/SHA256.json', res/'TTL'), ('VPN/SHA256.json', res/'VPN'), ('Applications/SHA256.json', res/'Applications'), ('DeviceBackups/SHA256.json', res/'DeviceBackups'), ('SystemBackups/SHA256.json', res/'SystemBackups'), ('DiagnosticTools/SHA256.json', res/'DiagnosticTools'), ('ExperimentalOpkg/SHA256.json', res/'ExperimentalOpkg'), ('HostTools/SHA256.json', res/'HostTools'), ('Terminal/SHA256.json', res/'Terminal'), ('AgentDashboard/SHA256.json', res/'AgentDashboard'), ('AgentInstallation/SHA256.json', res/'AgentInstallation')]:
    for name, expected in json.loads((res/manifest).read_text()).items():
        if sha(directory/name) != expected: raise SystemExit('Resource hash mismatch: ' + name)
data = {'checked_at': datetime.datetime.now().astimezone().isoformat(), 'version': version,
        'bundle': 'dist/ZTE U60Pro Manager.app', 'zip': str(archive.relative_to(root)),
        'zip_sha256': sha(archive), 'zip_size': archive.stat().st_size,
        'executable_sha256': sha(app/'Contents/MacOS/ZTEU60ProManager'), 'architecture': 'arm64', 'minimum_macos': '13.0',
        'signature': 'ad-hoc; codesign --verify --deep --strict passed', 'resource_manifests_match': True,
        'private_keys_or_device_backups_packaged': False,
        'bundled_agent_version': '2.8.0', 'bundled_agent_sha256': sha(res/'Onboarding/zte-agent'),
        'dashboard_auto_installed': False, 'ssclash_payload': 'not bundled; downloaded from the official release on explicit install',
        'source_sha256': {str(p.relative_to(root)): sha(p) for p in sorted((root/'Sources').glob('*.swift'))},
        'bundle_resources_sha256': resources}
(root/'dist/build-manifest.json').write_text(json.dumps(data, indent=2, ensure_ascii=False)+'\n')
PY
print "Built: $APP"
