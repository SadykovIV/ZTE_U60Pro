#!/usr/bin/env python3
"""Build public app and modem components; never connects to a modem."""
from pathlib import Path
import os,subprocess,hashlib,json,re,sys
ROOT=Path(__file__).resolve().parents[1]
RES=ROOT/'MacIMEI/Resources'
def run(args,cwd=ROOT,env=None):
 print('+',' '.join(map(str,args)),flush=True)
 subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for name in ['Onboarding/adb','Onboarding/dropbear','SSHAccounts/doas','VPN/mihomo','VPN/dashboard-uhttpd']:
 if not (RES/name).is_file():sys.exit('Missing runtime dependency '+name+'; run python3 tools/fetch_dependencies.py')
run([sys.executable,'ModemAgent/launcher/build.py'])
env=os.environ.copy()
rustup_bin=Path.home()/'.cargo/bin'
if (rustup_bin/'rustup').exists(): env['PATH']=str(rustup_bin)+os.pathsep+env['PATH']
# Remap panic/debug paths as well as the source checkout. No local user name in ELF.
env['RUSTFLAGS']='--remap-path-prefix='+str(ROOT)+'=. --remap-path-prefix='+str(Path.home())+'=/build'
env['CARGO_INCREMENTAL']='0'
run(['cargo','build','--release','--target','aarch64-unknown-linux-musl','-p','zte-vpnctl'],ROOT/'ModemAgent',env)
helper=sha(ROOT/'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-vpnctl')
p=ROOT/'ModemAgent/agent/src/vpn.rs';s=p.read_text();s=re.sub(r'const HELPER_SHA: &str = "[a-f0-9]+";',f'const HELPER_SHA: &str = "{helper}";',s);p.write_text(s)
run(['cargo','build','--release','--target','aarch64-unknown-linux-musl','-p','zte-agent'],ROOT/'ModemAgent',env)
if not (ROOT/'ModemAgent/web-app/node_modules').is_dir():run(['npm','ci'],ROOT/'ModemAgent/web-app')
run(['npm','run','build'],ROOT/'ModemAgent/web-app')
run([sys.executable,'MacIMEI/DeviceHelpers/build.py'])
run([sys.executable,'MacIMEI/tools/package_vpn.py'])
# Refresh every resource manifest after all generated resources and notices settle.
for folder in RES.iterdir():
 if not folder.is_dir() or not (folder/'SHA256.json').exists():continue
 manifest={str(p.relative_to(folder)):sha(p) for p in sorted(folder.rglob('*')) if p.is_file() and p.name!='SHA256.json'}
 (folder/'SHA256.json').write_text(json.dumps(manifest,indent=2)+'\n')
run(['zsh','MacIMEI/build.sh'])
