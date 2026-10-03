#!/usr/bin/env python3
"""Package the pinned eSIM server and web dashboard for both app installers."""
from pathlib import Path
import argparse, gzip, hashlib, io, json, re, shutil, tarfile
ROOT=Path(__file__).resolve().parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def manifest(base):
    (base/'SHA256.json').write_text(json.dumps({str(p.relative_to(base)):sha(p) for p in sorted(base.rglob('*')) if p.is_file() and p.name!='SHA256.json'},indent=2)+'\n')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--agent',type=Path,required=True);ap.add_argument('--sha256',required=True);args=ap.parse_args()
    if sha(args.agent)!=args.sha256:raise SystemExit('Agent SHA mismatch')
    version='2.9.0-esim.1';mac=ROOT/'MacIMEI/Resources';win=ROOT/'Windows_x64/Resources';dist=ROOT/'ModemAgent/web-app/dist'
    if not (dist/'index.html').is_file():raise SystemExit('Build dashboard first')
    helper=ROOT/'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-vpnctl'
    shutil.copy2(helper,mac/'VPN/vpnctl')
    p=mac/'VPN/upgrade-controller.sh';s=p.read_text()
    old=re.search(r'(?m)^helper_sha=([a-f0-9]{64})$',s).group(1)
    if old!=sha(helper) and '|'+old+'|' not in s:s=s.replace('|"$helper_sha")','|'+old+'|"$helper_sha")',1)
    for key,value in [('helper_sha',sha(helper)),('manager_sha',sha(mac/'VPN/manager.sh')),('configure_sha',sha(mac/'VPN/configure.lua'))]:
        s=re.sub(r'(?m)^'+key+r'=.*',key+'='+value,s)
    p.write_text(s)
    license_source=ROOT/'ModemAgent/web-app/node_modules/jsqr/LICENSE'
    shutil.copyfile(license_source,dist/'LICENSE-jsQR-Apache-2.0.txt')
    (dist/'release.json').write_text(json.dumps({'version':version,'agent_sha256':args.sha256,'esim':True,'web_download_requires_modem_internet':True},indent=2)+'\n')
    (dist/'THIRD-PARTY.md').write_text('QR images are decoded locally with jsQR 1.4.0 (Apache-2.0).\nSource: https://github.com/cozmo/jsQR\nExact npm integrity is recorded in the included source package-lock.json.\n')
    if (mac/'AgentDashboard').exists():shutil.rmtree(mac/'AgentDashboard')
    shutil.copytree(dist,mac/'AgentDashboard')
    manifest(mac/'AgentDashboard')
    archive=mac/'VPN/dashboard.tar.gz'
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw,mode='wb',filename='',mtime=0) as gz, tarfile.open(fileobj=gz,mode='w') as tar:
        for file in sorted(dist.rglob('*')):
            if not file.is_file():continue
            data=file.read_bytes();info=tarfile.TarInfo(str(file.relative_to(dist)));info.size=len(data);info.mode=0o644;info.mtime=0
            tar.addfile(info,io.BytesIO(data))
    p=mac/'VPN/update-agent.sh';s=p.read_text()
    previous=re.search(r'(?m)^agent_sha=([a-f0-9]{64})$',s).group(1)
    for old in [previous,'3da0915669ca101fe8b2faef3d683405957a2fbd49000a58257d28868321b3df','7a2d1a517d564a3d66dfe98e6622be6ca2428635aa9cbd83cbf02c179dd7703e']:
        if old!=args.sha256 and '|'+old+'|' not in s:s=s.replace('|"$agent_sha")','|'+old+'|"$agent_sha")')
    s=re.sub(r'(?m)^agent_sha=.*','agent_sha='+args.sha256,s);s=re.sub(r'(?m)^dashboard_sha=.*','dashboard_sha='+sha(archive),s);p.write_text(s)
    p=mac/'VPN/README.md';s=p.read_text();s=s.replace('обновление агента 2.7.0-vpn.1','обновление агента '+version+' с eSIM');p.write_text(s);manifest(mac/'VPN')
    bundle=mac/'AgentDashboardInstall';bundle.mkdir(exist_ok=True)
    names=['dashboard.tar.gz','dashboard-uhttpd','start-dashboard.sh','dashboard-html.sh','stop-owned-listener.sh','update-rc-local.sh','preserve-dashboard-assets.sh']
    for name in names:shutil.copy2(mac/'VPN'/name,bundle/name)
    (bundle/'payload.sha256').write_text(''.join(sha(bundle/name)+'  '+name+'\n' for name in names))
    script=mac/'AgentInstallation/dashboard.sh';s=script.read_text();s=re.sub(r'(?m)^payload_sha=.*','payload_sha='+sha(bundle/'payload.sha256'),s);script.write_text(s)
    manifest(mac/'AgentInstallation')
    shutil.copy2(script,bundle/'dashboard.sh');manifest(bundle)
    shutil.copy2(bundle/'dashboard.sh',mac/'VPN/dashboard-install.sh')
    shutil.copy2(bundle/'payload.sha256',mac/'VPN/payload.sha256')
    p=mac/'VPN/update-agent.sh';s=p.read_text()
    s=re.sub(r'(?m)^dashboard_installer_sha=.*','dashboard_installer_sha='+sha(bundle/'dashboard.sh'),s);p.write_text(s)
    manifest(mac/'VPN')
    for app in [mac,win]:
        shutil.copy2(args.agent,app/'Onboarding/zte-agent')
        p=app/'Onboarding/provenance.json';d=json.loads(p.read_text());d.update(agent_sha256=args.sha256,local_agent_version=version,local_agent_release='ModemAgent/releases/'+version);d['files']['zte-agent']=args.sha256
        change='Physical eUICC profile management over private SSH RPC and authenticated web API; separate eSIM dashboard.'
        if change not in d['local_changes']:d['local_changes'].append(change)
        p.write_text(json.dumps(d,indent=2,ensure_ascii=False)+'\n');manifest(app/'Onboarding')
    for group in ['AgentDashboard','AgentDashboardInstall','AgentInstallation','VPN']:
        if (win/group).exists():shutil.rmtree(win/group)
        shutil.copytree(mac/group,win/group)
    p=ROOT/'MacIMEI/Sources/BundledAgent.swift';s=p.read_text()
    for key,value in [('version',version),('sha256',args.sha256),('dashboardInstallerSHA256',sha(bundle/'dashboard.sh'))]:
        s,n=re.subn(r'(static let '+key+r' = ")[^"]+(")',lambda m:m[1]+value+m[2],s)
        if n!=1:raise SystemExit('Missing Swift pin '+key)
    p.write_text(s)
    p=ROOT/'MacIMEI/Sources/VPNSettings.swift';s=p.read_text()
    for key,value in [('launcherHash',sha(mac/'VPN/launcher.so')),('helperHash',sha(helper)),('dashboardIndexHash',sha(dist/'index.html'))]:
        s,n=re.subn(r'(static let '+key+r' = ")[a-f0-9]+(")',lambda m:m[1]+value+m[2],s)
        if n!=1:raise SystemExit('Missing VPN pin '+key)
    p.write_text(s)
    print(json.dumps({'agent_version':version,'agent_sha256':args.sha256,'vpnctl_sha256':sha(helper),'launcher_sha256':sha(mac/'VPN/launcher.so'),'dashboard_script_sha256':sha(bundle/'dashboard.sh'),'dashboard_index_sha256':sha(dist/'index.html'),'dashboard_archive_sha256':sha(archive),'same_installed_and_rpc_agent_required':True},indent=2))
if __name__=='__main__':main()
