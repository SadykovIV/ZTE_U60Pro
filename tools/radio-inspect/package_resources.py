#!/usr/bin/env python3
"""Package read-only modem research helpers and their corresponding sources."""
from pathlib import Path
import gzip, hashlib, io, json, re, shutil, tarfile
ROOT=Path(__file__).resolve().parents[2]
FOLDER=ROOT/'MacIMEI/Resources/FirmwareSupport'
def sha(data): return hashlib.sha256(data).hexdigest()
def main():
    names=('zte-support-nv','zte-support-config','zte-support-qmi')
    hashes={name:sha((FOLDER/name).read_bytes()) for name in names}
    for name in names:
        data=(FOLDER/name).read_bytes()
        if data[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(data[18:20],'little')!=183 or b'/Users/' in data or b'/home/' in data:
            raise SystemExit('Invalid ARM64 helper or leaked host path: '+name)
    source_names=['MacIMEI/DeviceHelpers/build_support.py','MacIMEI/DeviceHelpers/src/zte_nv.c',
        'MacIMEI/DeviceHelpers/src/zte_config_read.c','MacIMEI/DeviceHelpers/src/support_config.h',
        'tools/radio-inspect/Cargo.toml','tools/radio-inspect/Cargo.lock','tools/radio-inspect/src/main.rs',
        'tools/radio-inspect/build.py','tools/radio-inspect/package_resources.py','tools/esim-app/build_runtime.py',
        'tools/removable-euicc/device/src/qmi/qrtr.rs','tools/removable-euicc/device/src/qmi/tlv.rs',
        'tools/removable-euicc/device/COMPONENT-NOTICE.txt','LICENSE-SCOPE.md']
    buf=io.BytesIO()
    with gzip.GzipFile(fileobj=buf,mode='wb',filename='',mtime=0) as compressed,tarfile.open(fileobj=compressed,mode='w') as archive:
        for name in sorted(source_names):
            data=(ROOT/name).read_bytes(); entry=tarfile.TarInfo(name);entry.size=len(data);entry.mode=0o644;entry.mtime=0
            archive.addfile(entry,io.BytesIO(data))
    (FOLDER/'support-sources.tar.gz').write_bytes(buf.getvalue())
    (FOLDER/'NOTICE-QMI.txt').write_bytes((ROOT/'tools/removable-euicc/device/COMPONENT-NOTICE.txt').read_bytes())
    (FOLDER/'README.txt').write_text('''Read-only firmware adaptation tools

The desktop app uploads these ARM64 Linux tools to a private temporary directory
through the selected SSH connection, runs them sequentially, and removes them.
No installed agent is required. NV/config writes are excluded from the C builds.
Only response metadata and validation results are exported, never device records.
QMI queries: DMS GetOperatingMode, UIM GetCardStatus and GetSlotsStatus.
No slot switching, APDU, eSIM download, radio reset or IMEI change is performed.
These queries do not establish support for IMEI writes or eSIM provisioning.

For both SIM variants, collect separate archives with each selected and ready.
QMI reports numerical slot references without guessing physical/built-in routing.
Unsupported requests are recorded as unavailable, not as an empty card/profile.

Sources and build scripts: support-sources.tar.gz.
Build C tools: python3 MacIMEI/DeviceHelpers/build_support.py
Build QMI tool: python3 tools/radio-inspect/build.py
Package: python3 tools/radio-inspect/package_resources.py
Requirements: aarch64-linux-musl-gcc, Rust musl target, pinned Cargo dependencies.
QMI transport notice: NOTICE-QMI.txt; its upstream license is unspecified.
''')
    manifest={p.name:sha(p.read_bytes()) for p in sorted(FOLDER.iterdir()) if p.is_file() and p.name!='SHA256.json'}
    (FOLDER/'SHA256.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for name in manifest.keys()|{'SHA256.json'}:
        target=ROOT/'Windows_x64/Resources/FirmwareSupport'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(FOLDER/name,target)
    swift=ROOT/'MacIMEI/Sources/FirmwareRadioSupport.swift';text=swift.read_text()
    value='[\n'+''.join('        "'+name+'": "'+digest+'",\n' for name,digest in hashes.items())+'    ]'
    text,count=re.subn(r'static let hashes: \[String: String\] = \[[^\]]*\]', 'static let hashes: [String: String] = '+value,text,flags=re.S)
    if count!=1:raise SystemExit('Swift support pin location changed')
    swift.write_text(text)
    windows=ROOT/'Windows_x64/src/Diagnostics/FirmwareRadioSupport.cs';text=windows.read_text()
    value='new() {\n'+''.join('        ["'+name+'"] = "'+digest+'",\n' for name,digest in hashes.items())+'    };'
    text,count=re.subn(r'internal static readonly Dictionary<string,string> Hashes = new\(\) \{.*?\};', 'internal static readonly Dictionary<string,string> Hashes = '+value,text,flags=re.S)
    if count!=1:raise SystemExit('Windows support pin location changed')
    windows.write_text(text)
    print(json.dumps(hashes,indent=2))
if __name__=='__main__':main()
