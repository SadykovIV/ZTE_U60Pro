#!/usr/bin/env python3
"""Build public app/modem components from local sources; never contacts a modem."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,subprocess,sys
ROOT=Path(__file__).resolve().parents[1];RES=ROOT/'MacIMEI/Resources'
def run(args,cwd=ROOT,env=None):
 print('+',' '.join(str(x).replace(str(ROOT),'.') for x in args),flush=True)
 subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--modem-only',action='store_true');ap.add_argument('--tests',action='store_true');args=ap.parse_args()
 spec=importlib.util.spec_from_file_location('esim_build',ROOT/'tools/esim-app/build_runtime.py');runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
 env=runtime.environment();logs=ROOT/'.build/esim';logs.mkdir(parents=True,exist_ok=True)
 for name in ['Onboarding/adb','Onboarding/dropbear','SSHAccounts/doas','VPN/mihomo','VPN/dashboard-uhttpd']:
  if not (RES/name).is_file():raise SystemExit('Missing runtime dependency '+name+'; run python3 tools/fetch_dependencies.py')
 run([sys.executable,'ModemAgent/launcher/build.py'])
 run(['cargo','build','--offline','--locked','--release','--target','aarch64-unknown-linux-musl','-p','zte-vpnctl'],ROOT/'ModemAgent',env)
 helper=sha(ROOT/'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-vpnctl')
 p=ROOT/'ModemAgent/agent/src/vpn.rs';s=p.read_text();s,n=re.subn(r'const HELPER_SHA: &str = "[a-f0-9]+";',f'const HELPER_SHA: &str = "{helper}";',s)
 if n!=1:raise SystemExit('Missing agent controller pin')
 p.write_text(s)
 run([sys.executable,'tools/esim-app/build_runtime.py',*(['--tests'] if args.tests else [])],env=env)
 if args.tests:
  run(['cargo','test','--offline','--locked','-p','zte-agent','--features','esim','--bin','zte-agent-esim'],ROOT/'ModemAgent',env)
  run(['cargo','test','--offline','--locked','-p','zte-vpnctl'],ROOT/'ModemAgent',env)
 run(['cargo','build','--offline','--locked','--release','--target','aarch64-unknown-linux-musl','-p','zte-agent','--features','esim','--bin','zte-agent-esim'],ROOT/'ModemAgent',env)
 agent=ROOT/'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-agent-esim';agent_sha=sha(agent)
 for binary in [agent,ROOT/'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-vpnctl',RES/'VPN/launcher.so']:
  if str(ROOT).encode() in binary.read_bytes() or str(Path.home()).encode() in binary.read_bytes():raise SystemExit('Host path leaked into ELF')
 web=ROOT/'ModemAgent/web-app'
 if not (web/'node_modules').is_dir():run(['npm','ci','--ignore-scripts','--no-audit','--no-fund'],web)
 if args.tests:
  run(['npm','test'],web);run(['npm','run','lint'],web)
 run(['npm','run','build'],web)
 run([sys.executable,'tools/esim-app/package_permanent.py','--agent',agent,'--sha256',agent_sha])
 run([sys.executable,'tools/esim-app/package_resources.py','--agent',agent,'--sha256',agent_sha])
 receipt={'agent_version':'2.9.0-esim.2','public_source_rebuild':True,'hardware_tested':False,'agent_sha256':agent_sha,'vpnctl_sha256':helper,'launcher_sha256':sha(RES/'VPN/launcher.so'),'dashboard_installer_sha256':sha(RES/'AgentInstallation/dashboard.sh'),'dashboard_index_sha256':sha(RES/'AgentDashboard/index.html'),'esim_manifest_sha256':sha(RES/'Esim/SHA256.json')}
 (logs/'public-modem-build.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
 if not args.modem_only:
  run([sys.executable,'MacIMEI/DeviceHelpers/build.py'])
  run([sys.executable,'MacIMEI/tools/build_host_tools.py'])
  run(['zsh','MacIMEI/build.sh'])
if __name__=='__main__':main()
