#!/usr/bin/env python3
"""Build public app/modem components from local sources; never contacts a modem."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,subprocess,sys
ROOT=Path(__file__).resolve().parents[1];RES=ROOT/'MacIMEI/Resources'
def run(args,cwd=ROOT,env=None):
 print('+',' '.join(str(x).replace(str(ROOT),'.') for x in args),flush=True)
 subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def update_agent_helper_pin(source,helper):
 if not re.fullmatch(r'[a-f0-9]{64}',helper):raise ValueError('Invalid compiled controller hash')
 pin_pattern=r'(?m)^const HELPER_SHA: &str = "([a-f0-9]{64})";'
 pins=list(re.finditer(pin_pattern,source))
 history_pattern=r'(?ms)^const PREVIOUS_HELPER_SHAS: &\[&str\] = &\[(.*?)^\];'
 histories=list(re.finditer(history_pattern,source))
 if len(pins)!=1 or len(histories)!=1:raise ValueError('Missing or ambiguous agent controller pins')
 body=histories[0].group(1)
 if not re.fullmatch(r'\s*(?:"[a-f0-9]{64}",\s*)*',body):raise ValueError('Agent controller history must contain literal hashes')
 previous=re.findall(r'"([a-f0-9]{64})"',body)
 if len(previous)!=len(set(previous)):raise ValueError('Duplicate agent controller history')
 old=pins[0].group(1)
 if old!=helper and old not in previous:previous.append(old)
 history='const PREVIOUS_HELPER_SHAS: &[&str] = &[\n'+''.join('    "'+value+'",\n' for value in previous)+'];'
 source=re.sub(history_pattern,lambda _:history,source)
 return re.sub(pin_pattern,lambda _:f'const HELPER_SHA: &str = "{helper}";',source)
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--modem-only',action='store_true');ap.add_argument('--tests',action='store_true');args=ap.parse_args()
 if args.tests:run([sys.executable,ROOT/'tools/test_build_pins.py'])
 spec=importlib.util.spec_from_file_location('esim_build',ROOT/'tools/esim-app/build_runtime.py');runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
 env=runtime.environment();logs=ROOT/'.build/esim';logs.mkdir(parents=True,exist_ok=True)
 for name in ['Onboarding/adb','Onboarding/dropbear','SSHAccounts/doas','VPN/mihomo','VPN/dashboard-uhttpd']:
  if not (RES/name).is_file():raise SystemExit('Missing runtime dependency '+name+'; run python3 tools/fetch_dependencies.py')
 run([sys.executable,'ModemAgent/launcher/build.py'])
 run(['cargo','build','--offline','--locked','--release','--target','aarch64-unknown-linux-musl','-p','zte-vpnctl'],ROOT/'ModemAgent',env)
 helper=sha(ROOT/'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-vpnctl')
 p=ROOT/'ModemAgent/agent/src/vpn.rs';p.write_text(update_agent_helper_pin(p.read_text(),helper))
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
 run([sys.executable,'MacIMEI/DeviceHelpers/build_support.py'])
 run([sys.executable,'tools/radio-inspect/build.py'])
 run([sys.executable,'tools/radio-inspect/package_resources.py'])
 run([sys.executable,'tools/esim-app/package_resources.py','--agent',agent,'--sha256',agent_sha])
 # The corresponding modem-source archive has no desktop application sources.
 if (ROOT/'Windows_x64/src/Core/AgentPackage.cs').is_file():
  run([sys.executable,'Windows_x64/sync_public_resources.py'])
 receipt={'agent_version':'2.9.0-esim.13','public_source_rebuild':True,'hardware_tested':False,'agent_sha256':agent_sha,'vpnctl_sha256':helper,'launcher_sha256':sha(RES/'VPN/launcher.so'),'dashboard_installer_sha256':sha(RES/'AgentInstallation/dashboard.sh'),'dashboard_index_sha256':sha(RES/'AgentDashboard/index.html'),'esim_manifest_sha256':sha(RES/'Esim/SHA256.json')}
 (logs/'public-modem-build.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
 if not args.modem_only:
  run([sys.executable,'MacIMEI/DeviceHelpers/build.py'])
  run([sys.executable,'MacIMEI/tools/build_host_tools.py'])
  run(['zsh','MacIMEI/build.sh'])
if __name__=='__main__':main()
