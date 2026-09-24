#!/usr/bin/env python3
"""Fetch the pinned public build inputs; no private project or device required."""
from pathlib import Path
import hashlib,json,tarfile,urllib.request,os
ROOT=Path(__file__).resolve().parents[1]
meta=json.loads((ROOT/'tools/dependencies.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
missing=[n for n,h in meta['files'].items() if not (ROOT/n).is_file() or sha(ROOT/n)!=h]
if not missing:
 print('Build dependencies already verified');raise SystemExit(0)
cache=ROOT/'.cache';cache.mkdir(exist_ok=True)
archive=cache/meta['archive']
if not archive.exists() or sha(archive)!=meta['sha256']:
 req=urllib.request.Request(meta['url'],headers={'User-Agent':'ZTE-U60Pro-build'})
 tmp=archive.with_suffix('.download')
 with urllib.request.urlopen(req,timeout=120) as response,tmp.open('wb') as out:
  count=0
  while block:=response.read(1024*1024):
   count+=len(block)
   if count>128*1024*1024:raise SystemExit('Dependency archive exceeds limit')
   out.write(block)
 if sha(tmp)!=meta['sha256']:
  tmp.unlink();raise SystemExit('Dependency archive checksum mismatch')
 os.replace(tmp,archive)
# Extract only known regular files by explicit names. No extractall, links or traversal.
with tarfile.open(archive,'r:gz') as tar:
 for name,expected in meta['files'].items():
  part=Path(name)
  if part.is_absolute() or '..' in part.parts:raise SystemExit('Unsafe manifest path')
  member=tar.getmember(name)
  if not member.isfile() or member.size>80*1024*1024:raise SystemExit('Invalid dependency file')
  data=tar.extractfile(member).read()
  if hashlib.sha256(data).hexdigest()!=expected:raise SystemExit('Dependency hash mismatch: '+name)
  target=ROOT/name;target.parent.mkdir(parents=True,exist_ok=True)
  target.write_bytes(data);target.chmod(0o755)
print('Pinned build dependencies installed')
