#!/usr/bin/env python3
"""Package built public artifacts; does not publish or connect to a device."""
from pathlib import Path
import hashlib,json,tarfile,gzip,io,shutil
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'release';OUT.mkdir(exist_ok=True)
RES=ROOT/'MacIMEI/Resources';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def tar_gz(path,entries):
 with path.open('wb') as dest,gzip.GzipFile(filename='',fileobj=dest,mode='wb',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as tar:
  for name,source in sorted(entries.items()):
   p=Path(source);data=p.read_bytes();info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o755 if p.stat().st_mode&0o111 else 0o644;info.mtime=0
   tar.addfile(info,io.BytesIO(data))
app=ROOT/'MacIMEI/dist/ZTE-IMEI-Studio-1.9.1-arm64.zip'
shutil.copyfile(app,OUT/app.name)
agent=OUT/'zte-agent-2.7.1-aarch64-linux-musl';shutil.copyfile(RES/'Onboarding/zte-agent',agent);agent.chmod(0o755)
entries={'zte-agent':agent,'README.md':ROOT/'docs/AGENT.md','LICENSE':ROOT/'ModemAgent/LICENSE','THIRD_PARTY_NOTICES.md':ROOT/'THIRD_PARTY_NOTICES.md'}
for p in (RES/'AgentDashboard').rglob('*'):
 if p.is_file():entries['dashboard/'+str(p.relative_to(RES/'AgentDashboard'))]=p
for p in (ROOT/'licenses').iterdir():
 if p.is_file():entries['licenses/'+p.name]=p
manifest=OUT/'agent-SHA256SUMS';manifest.write_text(''.join(f'{sha(p)}  {name}\n' for name,p in sorted(entries.items())))
entries['SHA256SUMS']=manifest
tar_gz(OUT/'ZTE-Agent-2.7.1-aarch64-linux-musl.tar.gz',entries)
manifest.unlink()
# Runtime dependency bundle is generated once from verified files. No proprietary SSClash.
paths=['MacIMEI/Resources/'+p for p in ['Onboarding/adb','Onboarding/dropbear','SSHAccounts/dropbear','SSHAccounts/doas','VPN/mihomo','VPN/dashboard-uhttpd']]
deps={p:ROOT/p for p in paths}
for folder in ['Onboarding','SSHAccounts','VPN']:
 for p in (RES/folder).iterdir():
  if p.is_file() and ('LICENSE' in p.name or 'NOTICE' in p.name):deps['licenses/'+folder+'/'+p.name]=p
for p in (ROOT/'licenses').iterdir():
 if p.is_file():deps['licenses/'+p.name]=p
deps['THIRD_PARTY_NOTICES.md']=ROOT/'THIRD_PARTY_NOTICES.md'
for name in ['mihomo-v1.19.31-source.tar.gz','opendoas-6.8.2.tar.xz']:
 p=ROOT/'.cache'/name
 if not p.exists():raise SystemExit('Missing corresponding source archive: '+name)
 deps['sources/'+name]=p
archive=OUT/'Build-dependencies-20260924.tar.gz';tar_gz(archive,deps)
meta={'archive':archive.name,'url':'https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.9.1/'+archive.name,'sha256':sha(archive),'files':{p:sha(ROOT/p) for p in paths}}
(ROOT/'tools/dependencies.json').write_text(json.dumps(meta,indent=2)+'\n')
shutil.copyfile(ROOT/'MacIMEI/dist/build-manifest.json',OUT/'build-manifest.json')
(OUT/'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(OUT.iterdir()) if p.is_file() and p.name!='SHA256SUMS'))
print('Public release artifacts:',', '.join(p.name for p in sorted(OUT.iterdir())))
