#!/usr/bin/env python3
from pathlib import Path
import sys,hashlib,tarfile,io,json,urllib.request,subprocess,base64,posixpath,concurrent.futures
ROOT=Path(__file__).resolve().parents[2]; OUT=Path(__file__).resolve().parent; CACHE=ROOT/'ThirdParty/router-diagnostics'
names=['opkg','busybox','libubox20230523','usign','uclient-fetch','libuclient20201210','libustream-mbedtls20201210','libmbedtls12','ca-bundle']
sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,str(ROOT/'tools'));from package_diagnostics import verify_signature,package_metadata
index=(CACHE/'base.index').read_bytes();key=(CACHE/'b5043e70f9a75cde.pub').read_bytes();verify_signature(index,(CACHE/'base.sig').read_bytes(),key)
meta=package_metadata(index);runtime={};links={};records=[]
def fetch(name):
 m=meta[name];p=CACHE/m['Filename'];url='https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/base/'+m['Filename']
 if not p.exists():
  with urllib.request.urlopen(url,timeout=60) as r:p.write_bytes(r.read(8_000_001))
 data=p.read_bytes();assert sha(data)==m['SHA256sum'] and len(data)==int(m['Size'])
 return name,m,data,url
for name,m,data,url in concurrent.futures.ThreadPoolExecutor(max_workers=5).map(fetch,names):
 records.append({'name':name,'version':m['Version'],'license':m.get('License',''),'sha256':sha(data),'url':url})
 with tarfile.open(fileobj=io.BytesIO(data)) as t:
  d=t.extractfile(next(x for x in t if x.name.removeprefix('./')=='data.tar.gz')).read()
 with tarfile.open(fileobj=io.BytesIO(d)) as t:
  for member in t:
   n=member.name.removeprefix('./').rstrip('/')
   if not n or member.isdir():continue
   assert not n.startswith('/') and '..' not in n.split('/')
   if not (n in ['bin/opkg','bin/busybox','usr/bin/usign','bin/uclient-fetch','etc/ssl/certs/ca-certificates.crt'] or n.startswith(('lib/lib','usr/lib/lib'))):continue
   if member.issym():links[n]=posixpath.normpath(posixpath.join(posixpath.dirname(n),member.linkname))
   else:assert member.isfile();runtime[n]=(t.extractfile(member).read(),0o700 if member.mode&0o111 else 0o600)
for n,target in links.items():
 seen={n}
 while target in links:assert target not in seen;seen.add(target);target=links[target]
 assert target in runtime,(n,target);runtime[n]=runtime[target]
gcc=(CACHE/'audit/libgcc_s.so.1').read_bytes();assert sha(gcc)=='0cc3fb17c6598501e58629e325c50d963a3a2c2c77cd30c398dfcd1a09a47b88'
runtime['lib/libgcc_s.so.1']=(gcc,0o700)
musl=(CACHE/'audit/libc.so').read_bytes();assert sha(musl)=='293be7050415dac10c0ac4595764e2d9d79f8c5e42f43095acbfbfef42f2f6a9'
for n in ['lib/libc.so','lib/ld-musl-aarch64.so.1']:runtime[n]=(musl,0o700)
for n in ['bin/sh','bin/gzip','bin/tar','bin/sha256sum','bin/mkdir','bin/dirname']:runtime[n]=runtime['bin/busybox']
runtime['usr/bin/wget']=runtime['bin/uclient-fetch']
runtime['bin/usign']=runtime['usr/bin/usign']
runtime['etc/opkg/keys/b5043e70f9a75cde']=(key,0o600)
runtime['usr/sbin/opkg-key']=(b'''#!/bin/sh
set -eu
[ "$#" = 3 ] && [ "$1" = verify ] || exit 1
# src/gz stores Packages.gz; the detached signature authenticates raw Packages.
decoded=$(/bin/busybox mktemp /tmp/opkg-index.XXXXXX)
trap '/bin/busybox rm -f "$decoded"' EXIT HUP INT TERM
/bin/gzip -dc "$3" > "$decoded" || exit 1
/bin/usign -V -P /etc/opkg/keys -x "$2" -m "$decoded"
''',0o700)
conf='dest root /\nlists_dir ext /var/opkg-lists\narch all 1\narch aarch64_cortex-a53 10\noption check_signature 1\noption verify_program /usr/sbin/opkg-key\n'
for feed,url in [('base','packages/aarch64_cortex-a53/base'),('packages','packages/aarch64_cortex-a53/packages'),('core','targets/ipq807x/generic/packages')]:conf+='src/gz official_'+feed+' https://downloads.openwrt.org/releases/23.05.4/'+url+'\n'
runtime['etc/opkg.conf']=(conf.encode(),0o600)
runtime['PROVENANCE.json']=(json.dumps({'packages':records,'feedKeySHA256':sha(key),'muslSHA256':sha(musl)},indent=2).encode()+b'\n',0o600)
manifest=''.join(sha(d)+'  '+n+'\n' for n,(d,mode) in sorted(runtime.items())).encode();runtime['RUNTIME.sha256']=(manifest,0o600)
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w:gz',format=tarfile.USTAR_FORMAT) as t:
 for n,(d,mode) in sorted(runtime.items()):
  m=tarfile.TarInfo(n);m.size=len(d);m.mode=mode;m.uid=m.gid=m.mtime=0;t.addfile(m,io.BytesIO(d))
data=buf.getvalue();(OUT/'runtime.tar.gz').write_bytes(data)
(OUT/'runtime.json').write_text(json.dumps({'schema':1,'sha256':sha(data),'bytes':len(data),'manifestSHA256':sha(manifest),'files':len(runtime),'opkgVersion':meta['opkg']['Version']},indent=2)+'\n')
(OUT/'PROVENANCE.json').write_bytes(runtime['PROVENANCE.json'][0]);print((OUT/'runtime.json').read_text())
