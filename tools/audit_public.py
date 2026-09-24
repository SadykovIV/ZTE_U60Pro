#!/usr/bin/env python3
"""Audit tracked source and optional release archives. Never prints secret values."""
from pathlib import Path,PurePosixPath
import argparse,io,re,subprocess,tarfile,zipfile,sys,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--artifacts',action='store_true');p.add_argument('--forbidden-file',type=Path,help='Private JSON array of extra strings; never add it to Git');a=p.parse_args()
forbidden=[s.encode() for s in json.loads(a.forbidden_file.read_text())] if a.forbidden_file else []
problems=[];count=0;total=0;public_test_fixtures=0
DENIED={'id_ed25519','id_rsa','authorized_keys','known_hosts','trusted_known_hosts','connection.json','nv0.bin','nv1.bin','config.original.bin','back_parameter','ssclash-linux-arm64'}
def inspect(name,data,depth=0):
 global count,total,public_test_fixtures
 count+=1;total+=len(data)
 if count>20000 or total>2*1024**3:raise RuntimeError('Archive audit limit exceeded')
 leaf=PurePosixPath(name).name
 if leaf in DENIED:problems.append((name,'private/prohibited filename'))
 if any(s and s in data for s in forbidden):problems.append((name,'private value'))
 # A complete PEM key requires both delimiters, so redaction test strings are allowed.
 if re.search(rb'-----BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{80,}-----END',data):
  # Verbatim public upstream test fixture in the GPL corresponding-source archive.
  # This exact content is not installed and is not an owner's credential.
  if name.endswith('/transport/openvpn/config_test.go') and hashlib.sha256(data).hexdigest()=='0c652ff75e9644ef94822227966079f036bf0cc55d12ecf673801b4435e3bdf5':public_test_fixtures+=1
  else:problems.append((name,'private key'))
 for match in re.finditer(rb'vless://[0-9a-fA-F-]{36}@([^:?/#\s"\\]+)',data):
  host=match[1].decode(errors='ignore')
  if host not in ('example.com','example.test','vpn.example.com','192.0.2.1','198.51.100.1','203.0.113.1'):
   problems.append((name,'non-example VPN profile'))
 if depth>=5:return
 stream=io.BytesIO(data)
 if zipfile.is_zipfile(stream):
  with zipfile.ZipFile(stream) as z:
   for m in z.infolist():
    if m.is_dir():continue
    if m.file_size>100*1024**2:raise RuntimeError('Oversized ZIP member: '+name)
    inspect(name+'!'+m.filename,z.read(m),depth+1)
 elif name.endswith(('.tar.gz','.tgz','.tar.xz')):
  with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as tar:
   for m in tar:
    if not m.isfile():continue
    if m.size>100*1024**2:raise RuntimeError('Oversized TAR member: '+name)
    inspect(name+'!'+m.name,tar.extractfile(m).read(),depth+1)
files=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
for name in filter(None,files):
 path=ROOT/name
 if path.is_symlink():problems.append((name,'symlink in source'))
 else:inspect(name,path.read_bytes())
if a.artifacts:
 for path in sorted((ROOT/'release').glob('*')):
  if path.is_file():inspect('release/'+path.name,path.read_bytes())
for name,reason in sorted(set(problems)):print('FAIL',name,reason)
print(f'Audit: {count} files/archive members, {len(set(problems))} findings; {public_test_fixtures} known public upstream test fixture')
sys.exit(bool(problems))
