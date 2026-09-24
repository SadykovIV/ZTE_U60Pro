"""Refresh native resources from the already built agent/controller/dashboard."""
from pathlib import Path
import hashlib, json, shutil, tarfile, gzip, io, re
root=Path(__file__).resolve().parents[2]; app=root/'MacIMEI'; resources=app/'Resources'; vpn=resources/'VPN'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for source,target in [('zte-agent',resources/'Onboarding/zte-agent'),('zte-vpnctl',vpn/'vpnctl')]:
 shutil.copyfile(root/'ModemAgent/target/aarch64-unknown-linux-musl/release'/source,target)
agent=sha(resources/'Onboarding/zte-agent');helper=sha(vpn/'vpnctl')
dashboard=resources/'AgentDashboard';dist=root/'ModemAgent/web-app/dist'
if (dashboard/'assets').exists():shutil.rmtree(dashboard/'assets')
shutil.copytree(dist,dashboard,dirs_exist_ok=True)
(dashboard/'release.json').write_text(json.dumps({'version':'2.7.1','agent_sha256':agent,'vpn_helper_sha256':helper},indent=2)+'\n')
(dashboard/'SHA256.json').write_text(json.dumps({str(p.relative_to(dashboard)):sha(p) for p in sorted(dashboard.rglob('*')) if p.is_file() and p.name!='SHA256.json'},indent=2)+'\n')
with gzip.GzipFile(filename='',mode='wb',fileobj=(vpn/'dashboard.tar.gz').open('wb'),mtime=0) as gz:
 with tarfile.open(fileobj=gz,mode='w') as tar:
  for p in sorted(dist.rglob('*')):
   if not p.is_file():continue
   info=tarfile.TarInfo(str(p.relative_to(dist)));data=p.read_bytes();info.size=len(data);info.mode=0o644;info.mtime=0
   tar.addfile(info,io.BytesIO(data))
p=app/'Sources/VPNSettings.swift';s=p.read_text()
for key,value in [('launcherHash',sha(vpn/'launcher.so')),('agentHash',agent),('helperHash',helper),('dashboardIndexHash',sha(dist/'index.html'))]:s=re.sub(r'(static let '+key+r' = )"[a-f0-9]+"',lambda m:m[1]+'"'+value+'"',s)
p.write_text(s)
p=app/'Sources/ModemInformation.swift';s=p.read_text();s=re.sub(r'(let agentVersion = )agentSHA == "[a-f0-9]+" \? "[^\"]+"',lambda m:m[1]+f'agentSHA == "{agent}" ? "2.7.0 · VPN, дисплей, RU/EN и TTL"',s,count=1);p.write_text(s)
p=vpn/'update-agent.sh';s=p.read_text();s=re.sub(r'(?m)^agent_sha=.*',f'agent_sha={agent}',s);s=re.sub(r'(?m)^dashboard_sha=.*',f'dashboard_sha={sha(vpn/"dashboard.tar.gz")}',s);p.write_text(s)
p=resources/'Onboarding/provenance.json';o=json.loads(p.read_text());o['agent_sha256']=agent;o['files']['zte-agent']=agent;o['local_agent_version']='2.7.1';o['local_agent_release']='https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.9.1';p.write_text(json.dumps(o,indent=2,ensure_ascii=False)+'\n')
p=vpn/'upgrade-controller.sh';s=p.read_text();s=re.sub(r'(?m)^helper_sha=.*',f'helper_sha={helper}',s);s=re.sub(r'(?m)^manager_sha=.*',f'manager_sha={sha(vpn/"manager.sh")}',s);s=re.sub(r'(?m)^configure_sha=.*',f'configure_sha={sha(vpn/"configure.lua")}',s);p.write_text(s)
(vpn/'SHA256.json').write_text(json.dumps({p.name:sha(p) for p in sorted(vpn.iterdir()) if p.is_file() and p.name!='SHA256.json'},indent=2)+'\n')
print('AGENT',agent);print('VPNCTL',helper)
