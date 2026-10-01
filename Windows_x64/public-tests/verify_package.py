#!/usr/bin/env python3
"""Read-only verification of the public Windows portable package, without a modem."""
from pathlib import Path
import argparse,hashlib,json,re,struct,subprocess,sys,zipfile
W=Path(__file__).resolve().parents[1]
R=W.parent

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def require(ok,message):
    if not ok:raise ValueError(message)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path);args=ap.parse_args()
    version=re.search(r'<Version>([^<]+)</Version>',(W/'src/ZteImeiStudio.Windows.csproj').read_text()).group(1)
    manifest=json.loads((W/f'dist/windows-{version}-build-manifest.json').read_text())
    portable=W/f'dist/portable{version}'
    require(manifest['version']==version and manifest['distribution']=='public','Wrong release identity')
    require(manifest['windowsOsRuntimeVerified'] is False,'Runtime boundary changed')
    subprocess.run([sys.executable,str(W/'sync_public_resources.py'),'--check'],cwd=R,check=True)
    source_resources={str(p.relative_to(W/'Resources')):digest(p) for p in (W/'Resources').rglob('*') if p.is_file()}
    actual_resources={str(p.relative_to(portable/'Resources')):digest(p) for p in (portable/'Resources').rglob('*') if p.is_file()}
    require(source_resources==actual_resources==manifest['resources'],'Resource hashes or exact coverage differ')
    require(not any(p.is_symlink() for p in (W/'Resources').rglob('*')),'Resource symlinks refused')
    for rel in source_resources:
        require(Path(rel).name not in ('trusted_known_hosts','ssclash-linux-arm64'),'Private-only resource found')
    for rel,expected in manifest['sources'].items():require(digest(W/rel)==expected,'Published source differs: '+rel)
    require(not list((W/'src').rglob('*.orig')),'Copied editor original found')
    require('PrivateLocalBuild' not in (W/'build.ps1').read_text(),'Private build bypass present')
    exe=portable/manifest['exe']['name'];data=exe.read_bytes()
    require(digest(exe)==manifest['exe']['sha256'] and len(data)==manifest['exe']['bytes'],'Executable hash/size mismatch')
    pe=struct.unpack_from('<I',data,0x3c)[0]
    require(data[:2]==b'MZ' and data[pe:pe+4]==b'PE\0\0' and struct.unpack_from('<H',data,pe+4)[0]==0x8664,'Not x64 PE')
    require(str(R).encode() not in data and str(R).encode('utf-16le') not in data,'Unmapped workspace path in executable')
    archive=W/'dist'/manifest['zip']['name']
    require(digest(archive)==manifest['zip']['sha256'],'ZIP hash differs')
    portable_files={str(p.relative_to(portable)):digest(p) for p in portable.rglob('*') if p.is_file()}
    with zipfile.ZipFile(archive) as z:
        require(z.testzip() is None,'ZIP CRC failure')
        names=[i.filename for i in z.infolist() if not i.is_dir()]
        require(len(names)==len(set(names)) and set(names)==set(portable_files),'ZIP file coverage differs')
        for name in names:require(hashlib.sha256(z.read(name)).hexdigest()==portable_files[name],'ZIP bytes differ: '+name)
    result={'schemaVersion':1,'ok':True,'version':version,'public':True,'actualWindowsOsVerified':False,'deviceAccess':False,'networkAccess':False,'resources':len(source_resources),'sources':len(manifest['sources']),'portableFiles':len(portable_files),'exe':manifest['exe'],'zip':manifest['zip'],'manifestSha256':digest(W/f'dist/windows-{version}-build-manifest.json'),'verifierSha256':digest(Path(__file__))}
    text=json.dumps(result,indent=2)+'\n'
    if args.output:args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(text)
    print(text)
if __name__=='__main__':main()
