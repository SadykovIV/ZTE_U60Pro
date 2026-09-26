#!/usr/bin/env python3
"""Build the isolated diagnostic bundle from authenticated OpenWrt IPKs; never run package scripts."""
from pathlib import Path, PurePosixPath
import argparse, base64, hashlib, io, json, os, shutil, subprocess, tarfile, urllib.request
ROOT=Path(__file__).resolve().parents[1]
CACHE=ROOT/'ThirdParty/router-diagnostics'; OUT=ROOT/'Resources/DiagnosticTools'
REPOS={'packages':'https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/packages/',
 'base':'https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/base/',
 'core':'https://downloads.openwrt.org/releases/23.05.4/targets/ipq807x/generic/packages/'}
SELECT={'packages':['htop','iperf3','libiperf3','mtr-nojson'], 'base':['tcpdump','libpcap1','libncurses6','terminfo'], 'core':['libatomic1','libgcc1']}
CC=os.environ.get('ZTE_CROSS_CC') or shutil.which('aarch64-linux-musl-gcc')
OPENSSL=os.environ.get('ZTE_OPENSSL') or shutil.which('openssl')
READELF=os.environ.get('ZTE_READELF') or shutil.which('aarch64-linux-musl-readelf')
assert CC and OPENSSL and READELF, 'Install the ARM64 musl toolchain and OpenSSL 3'
MUSL=Path(os.environ['ZTE_MUSL_LIBC']) if os.environ.get('ZTE_MUSL_LIBC') else Path(subprocess.check_output([CC,'-print-file-name=libc.so'],text=True).strip())
sha=lambda b:hashlib.sha256(b).hexdigest()
def fetch(url,p):
 if not p.exists():
  req=urllib.request.Request(url,headers={'User-Agent':'ZTE-IMEI-Studio-build/1.17'})
  with urllib.request.urlopen(req,timeout=60) as r: data=r.read(10_000_001)
  assert len(data)<=10_000_000,url
  p.write_bytes(data)
 return p.read_bytes()
def verify_signature(index,sig,key):
 s=base64.b64decode(sig.splitlines()[1]); k=base64.b64decode(key.splitlines()[1])
 assert len(s)==74 and len(k)==42 and s[:10]==k[:10] and s[:2]==b'Ed'
 (CACHE/'verify-key.der').write_bytes(bytes.fromhex('302a300506032b6570032100')+k[10:])
 (CACHE/'verify-signature.bin').write_bytes(s[10:]);(CACHE/'verify-index').write_bytes(index)
 subprocess.run([OPENSSL,'pkeyutl','-verify','-pubin','-inkey',str(CACHE/'verify-key.der'),'-keyform','DER','-rawin','-sigfile',str(CACHE/'verify-signature.bin'),'-in',str(CACHE/'verify-index')],check=True,capture_output=True)
 return k[2:10].hex()
def package_metadata(index):
 result={}
 for para in index.decode().split('\n\n'):
  d=dict(line.split(': ',1) for line in para.splitlines() if ': ' in line and not line.startswith(' '))
  if 'Package' in d: result[d['Package']]=d
 return result
def safe_name(name):
 name=name.removeprefix('./').rstrip('/')
 assert name and not name.startswith('/') and all(p not in ('','..','.') for p in name.split('/')),name
 return name

def main():
 args=argparse.ArgumentParser();args.add_argument('--fetch',action='store_true');opt=args.parse_args()
 CACHE.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True)
 def get(url,p):
  if opt.fetch:return fetch(url,p)
  return p.read_bytes()
 records=[]; payloads={}; links={};dirs=set();keys={}
 for repo,names in SELECT.items():
  index=get(REPOS[repo]+'Packages',CACHE/(repo+'.index'))
  sig=get(REPOS[repo]+'Packages.sig',CACHE/(repo+'.sig'))
  keyid=base64.b64decode(sig.splitlines()[1])[2:10].hex()
  key=get('https://raw.githubusercontent.com/openwrt/keyring/master/usign/'+keyid,CACHE/(keyid+'.pub'))
  verify_signature(index,sig,key);keys[repo]={'key':keyid,'index_sha256':sha(index)}
  metadata=package_metadata(index)
  for name in names:
   p=metadata[name];assert p['Architecture']=='aarch64_cortex-a53'
   filename=p['Filename'];assert '/' not in filename and '..' not in filename
   ipk=get(REPOS[repo]+filename,CACHE/filename)
   assert len(ipk)==int(p['Size']) and sha(ipk)==p['SHA256sum'],filename
   records.append({**{k:p.get(k,'') for k in ['Package','Version','License','Depends','SHA256sum']},'url':REPOS[repo]+filename})
   with tarfile.open(fileobj=io.BytesIO(ipk),mode='r:*') as outer:
    members={m.name.removeprefix('./'):m for m in outer.getmembers()}
    assert 'data.tar.gz' in members
    data=outer.extractfile(members['data.tar.gz']).read()
   with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as inner:
    for m in inner.getmembers():
     if m.name in ['.','./']:continue
     n=safe_name(m.name)
     assert n.startswith(('usr/','lib/','etc/')) or n in ('usr','lib','etc'),n
     if m.isdir():dirs.add(n);continue
     # Only runtime/data payload is retained. No service, config, opkg or install scripts.
     assert not n.startswith(('etc/','usr/lib/opkg/')),n
     if m.issym():links[n]=str(PurePosixPath(n).parent/m.linkname);continue
     assert m.isfile() and not m.islnk(),n
     b=inner.extractfile(m).read();assert n not in payloads or payloads[n][0]==b,n
     payloads[n]=(b,0o700 if m.mode&0o111 else 0o600)
 for n,target in links.items():
  seen={n}
  while target in links:
   assert target not in seen;seen.add(target);target=links[target]
  assert target in payloads,(n,target)
  payloads[n]=payloads[target] # package library symlinks become regular private files
 musl=MUSL.read_bytes();assert musl[:6]==b'\x7fELF\x02\x01' and musl[18:20]==b'\xb7\x00'
 payloads['lib/libc.so']=(musl,0o700)
 runtime={'source':'Homebrew musl-cross 0.9.11 / aarch64-linux-musl, GCC 14.2.0','sha256':sha(musl)}
 programs={'htop':'usr/bin/htop','iperf3':'usr/bin/iperf3','mtr':'usr/bin/mtr','tcpdump':'usr/sbin/tcpdump','mtr-packet':'usr/bin/mtr-packet'}
 for name,path in programs.items():
  if path not in payloads:
   matches=[p for p in payloads if p.endswith('/'+name)]; assert len(matches)==1,(name,matches);programs[name]=matches[0]
 for name,path in programs.items():
  wrapper='''#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
unset LD_PRELOAD LD_LIBRARY_PATH
export TERMINFO="$base/usr/share/terminfo"
export MTR_PACKET="$base/bin/mtr-packet"
exec "$base/lib/libc.so" --library-path "$base/lib:$base/usr/lib" "$base/PROGRAM" "$@"
'''.replace('PROGRAM',path)
  payloads['bin/'+name]=(wrapper.encode(),0o700)
 versions={p['Package']:p['Version'] for p in records}
 payloads['VERSION']=(b'router-diagnostics-1\n',0o600)
 payloads['PROVENANCE.json']=(json.dumps({'packages':records,'signatures':keys,'runtime':runtime},indent=2).encode()+b'\n',0o600)
 manifest=''.join(sha(data)+'  '+name+'\n' for name,(data,mode) in sorted(payloads.items())).encode()
 bundle_id=sha(manifest);payloads['FILES.sha256']=(manifest,0o600)
 # All paths regular; no hardlinks/symlinks/devices, no absolute paths or archive scripts.
 buffer=io.BytesIO()
 with tarfile.open(fileobj=buffer,mode='w:gz',format=tarfile.USTAR_FORMAT) as tar:
  for name,(data,mode) in sorted(payloads.items()):
   member=tarfile.TarInfo(name);member.size=len(data);member.mode=mode;member.uid=member.gid=0;member.mtime=0
   tar.addfile(member,io.BytesIO(data))
 archive=buffer.getvalue();(OUT/'bundle.tar.gz').write_bytes(archive)
 (OUT/'bundle.json').write_text(json.dumps({'schema':1,'id':bundle_id,'archiveSHA256':sha(archive),'archiveBytes':len(archive),'unpackedBytes':sum(len(d) for d,m in payloads.values()),'fileCount':len(payloads),'versions':versions,'programs':programs},indent=2)+'\n')
 (OUT/'PROVENANCE.json').write_bytes(payloads['PROVENANCE.json'][0])
 # Host-side ELF dependency audit; no downloaded binary is executed.
 audit=CACHE/'audit';audit.mkdir(exist_ok=True)
 for name,(data,mode) in payloads.items():
  if not data.startswith(b'\x7fELF'):continue
  assert data[:6]==b'\x7fELF\x02\x01' and data[18:20]==b'\xb7\x00',name
  p=audit/Path(name).name;p.write_bytes(data)
  text=subprocess.check_output([READELF,'-d',str(p)],text=True)
  for line in text.splitlines():
   if '(NEEDED)' in line:
    needed=line.split('[')[1].split(']')[0]
    assert 'lib/'+needed in payloads or 'usr/lib/'+needed in payloads,(name,needed)
 print(json.dumps({'bundle':bundle_id,'archive':sha(archive),'files':len(payloads),'bytes':len(archive),'versions':versions},indent=2))
if __name__=='__main__':main()
