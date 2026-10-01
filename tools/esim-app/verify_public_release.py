#!/usr/bin/env python3
"""Final release audit; source bundle keeps the exact public v1.20 dependency snapshot."""
from pathlib import Path
import hashlib, json, re, subprocess, tarfile
ROOT = Path(__file__).resolve().parents[2]
BASELINE_DEPENDENCIES_SHA = '29c00a9cc4bd76f5190141be668230acf00ad008871fad72a200e17f40d4883b'
BASELINE_ARCHIVE_SHA = '90ec14b09f383da82ebab95b7abb2f51fd90de5a39097f99be423a0683d4cd77'
MAC = ROOT / 'MacIMEI/Resources'
WIN = ROOT / 'Windows_x64/Resources'
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def need(value, message):
    if not value: raise SystemExit(message)
def main(receipt_name='public-release-verification.json'):
    groups = ['Esim', 'VPN', 'AgentDashboard', 'AgentDashboardInstall', 'AgentInstallation']
    records = {}
    for group in groups:
        base = MAC / group
        manifest = json.loads((base / 'SHA256.json').read_text())
        actual = {str(p.relative_to(base)) for p in base.rglob('*') if p.is_file() and p.name != 'SHA256.json'}
        need(actual == set(manifest), 'Resource file set mismatch: ' + group)
        for name, sha in manifest.items():
            need(digest(base/name) == sha, 'Resource digest mismatch: '+group+'/'+name)
            need((WIN/group/name).read_bytes() == (base/name).read_bytes(), 'Resource mirror mismatch')
        need((WIN/group/'SHA256.json').read_bytes() == (base/'SHA256.json').read_bytes(), 'Manifest mirror mismatch')
        records[group] = {'files': len(manifest), 'manifest_sha256': digest(base/'SHA256.json')}
    agent = MAC/'Esim/zte-agent-esim'; helper=MAC/'VPN/vpnctl'; launcher=MAC/'VPN/launcher.so'
    for binary in [agent, helper, launcher, ROOT/'ModemAgent/agent/resources/esim/bridge', ROOT/'ModemAgent/agent/resources/esim/lpac']:
        data=binary.read_bytes()
        need(data[:6] == b'\x7fELF\x02\x01' and int.from_bytes(data[18:20],'little') == 183, 'Invalid ARM64 ELF')
        need(str(ROOT).encode() not in data and str(Path.home()).encode() not in data, 'Host path in ELF')
    need((MAC/'Onboarding/zte-agent').read_bytes()==agent.read_bytes()==(WIN/'Onboarding/zte-agent').read_bytes(),'Agent variants differ')
    fields=[('MacIMEI/Sources/BundledAgent.swift','sha256',digest(agent)),('MacIMEI/Sources/BundledAgent.swift','dashboardInstallerSHA256',digest(MAC/'AgentInstallation/dashboard.sh')),('MacIMEI/Sources/VPNSettings.swift','helperHash',digest(helper)),('MacIMEI/Sources/VPNSettings.swift','launcherHash',digest(launcher)),('MacIMEI/Sources/VPNSettings.swift','dashboardIndexHash',digest(MAC/'AgentDashboard/index.html'))]
    for path,key,value in fields:
        need(re.search(r'static let '+key+r' = "'+value+r'"',(ROOT/path).read_text()) is not None,'Compiled pin mismatch '+key)
    sources=MAC/'Esim/eSIM-sources.tar.gz'; count=0; current_matches=0; dependency_snapshot=None
    with tarfile.open(sources,'r:gz') as tar:
        names=set()
        for member in tar:
            need(member.isfile() and not member.name.startswith('/') and '..' not in Path(member.name).parts,'Unsafe source member')
            need(not {'evidence','target','node_modules','.git','.npm-cache'}.intersection(Path(member.name).parts),'Private/cache source path')
            need(member.name not in names, 'Duplicate source member')
            data=tar.extractfile(member).read(); names.add(member.name); count+=1
            if member.name == 'tools/dependencies.json':
                need(hashlib.sha256(data).hexdigest()==BASELINE_DEPENDENCIES_SHA,'Baseline manifest snapshot mismatch')
                baseline=json.loads(data)
                need(baseline['archive']=='Build-dependencies-1.20.0.tar.gz' and baseline['sha256']==BASELINE_ARCHIVE_SHA and baseline['url']=='https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.20.0/Build-dependencies-1.20.0.tar.gz','Baseline archive identity mismatch')
                dependency_snapshot={'path':member.name,'sha256':BASELINE_DEPENDENCIES_SHA,'source_ref':'origin/main at da091fb7e6af804b81d51b913c20eb848303982e','archive_sha256':BASELINE_ARCHIVE_SHA,'current_metadata_may_change':True}
            else:
                need((ROOT/member.name).is_file() and (ROOT/member.name).read_bytes()==data,'Source correspondence mismatch '+member.name)
                current_matches+=1
            need(str(ROOT).encode() not in data and str(Path.home()).encode() not in data,'Host path in source archive')
        for name in ['tools/build.py','tools/esim-app/build_runtime.py','tools/removable-euicc/certs/gsma-rsp-roots.pem','third_party/lpac/src/applet/version.h','ModemAgent/agent/src/esim/radio.rs','MacIMEI/Resources/VPN/manager.sh','LICENSE-SCOPE.md','tools/removable-euicc/device/component.json','tools/removable-euicc/device/COMPONENT-NOTICE.txt']:
            need(name in names,'Missing build input '+name)
    need(dependency_snapshot is not None and current_matches==count-1,'Missing bounded dependency snapshot')
    component_path=ROOT/'tools/removable-euicc/device/component.json'
    component=json.loads(component_path.read_text())
    need(component['license_status']=='license_unspecified','Incorrect QMI/ES10 license status')
    component_files=set()
    for record in component['files']:
        path=record['path']
        need(path not in component_files and path in names,'Invalid component source path')
        component_files.add(path)
        need(digest(ROOT/path)==record['sha256'] and (ROOT/path).stat().st_size==record['size'],'Component source identity mismatch')
    expected_component_files={
        'tools/removable-euicc/device/src/'+p for p in ['qmi/mod.rs','qmi/qrtr.rs','qmi/tlv.rs','qmi/uim.rs','euicc/bertlv.rs','euicc/es10.rs']
    } | {'ModemAgent/agent/src/esim/radio_qmi/'+p for p in ['qrtr.rs','tlv.rs']}
    need(component_files==expected_component_files,'Component scope mismatch')
    provenance=json.loads((MAC/'Esim/PROVENANCE.json').read_text())
    need(provenance['license_status']=={'qmi_es10':'license_unspecified'} and provenance['qmi_component']==component and provenance['qmi_component_manifest_sha256']==digest(component_path),'Component provenance mismatch')
    need(provenance['source_archive_files']==count and provenance['source_archive_sha256']==digest(sources),'Source provenance mismatch')
    for bundled,source in [('NOTICE-QMI-ES10.txt','tools/removable-euicc/device/COMPONENT-NOTICE.txt'),('LICENSE-SCOPE.md','LICENSE-SCOPE.md'),('LICENSE-agent-MIT.txt','ModemAgent/LICENSE'),('LICENSE-lpac-AGPL-3.0.txt','third_party/lpac/src/LICENSE'),('LICENSE-libeuicc-LGPL-2.1.txt','third_party/lpac/euicc/LICENSE'),('LICENSE-cJSON-MIT.txt','third_party/lpac/cjson/LICENSE')]:
        need((MAC/'Esim'/bundled).read_bytes()==(ROOT/source).read_bytes(),'License or notice differs from source')
    script=(MAC/'VPN/upgrade-controller.sh').read_text()
    known=re.search(r'(?ms)^known\(\) \{.*?^\}',script).group(0)
    for sha, expected in [('f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4',0),(digest(helper),0),('0'*64,1)]:
        result=subprocess.run(['/bin/sh','-c','helper_sha='+digest(helper)+'\n'+known+'\nknown "$1"','fixture',sha],capture_output=True)
        need(result.returncode==expected,'Public old-controller compatibility guard mismatch')
    receipt={'result':'PASS','hardware_tested':False,'agent_sha256':digest(agent),'vpnctl_sha256':digest(helper),'launcher_sha256':digest(launcher),'groups':records,'source_archive_sha256':digest(sources),'source_files':count,'source_files_matching_current_checkout':current_matches,'archived_dependency_snapshot':dependency_snapshot,'component_manifest_sha256':digest(component_path),'component_files':len(component_files),'qmi_license_status':'license_unspecified','public_v120_controller_upgrade_allowlist':True}
    out=ROOT/'.build/esim'/receipt_name;out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
if __name__=='__main__': main()
