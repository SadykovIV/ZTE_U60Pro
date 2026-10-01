#!/usr/bin/env python3
"""Build the public physical-eUICC runtime from included sources; no device access."""
from pathlib import Path
import argparse,hashlib,json,os,re,shlex,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'.build/esim'
COMPONENT_FILES = [
 'tools/removable-euicc/device/src/qmi/mod.rs',
 'tools/removable-euicc/device/src/qmi/qrtr.rs',
 'tools/removable-euicc/device/src/qmi/tlv.rs',
 'tools/removable-euicc/device/src/qmi/uim.rs',
 'tools/removable-euicc/device/src/euicc/bertlv.rs',
 'tools/removable-euicc/device/src/euicc/es10.rs',
 'ModemAgent/agent/src/esim/radio_qmi/qrtr.rs',
 'ModemAgent/agent/src/esim/radio_qmi/tlv.rs',
]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def component_manifest():
 report={'component':'QMI/ES10 transport','license_status':'license_unspecified',
  'notice':'COMPONENT-NOTICE.txt',
  'scope':'Current adapted source identities; no license grant or claim of sole authorship.',
  'files':[{'path':name,'sha256':sha(ROOT/name),'size':(ROOT/name).stat().st_size} for name in COMPONENT_FILES]}
 path=ROOT/'tools/removable-euicc/device/component.json'
 path.write_text(json.dumps(report,indent=2)+'\n')
 return sha(path)
def run(args,cwd=ROOT,env=None):
 print('+',' '.join(str(x).replace(str(ROOT),'.').replace(str(Path.home()),'/build') for x in args),flush=True)
 subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
def environment():
 env=os.environ.copy();bindir=Path.home()/'.cargo/bin'
 if (bindir/'rustup').is_file():
  env['PATH']=str(bindir)+os.pathsep+env['PATH'];env['RUSTC']=str(bindir/'rustc')
 env['RUSTFLAGS']=f'--remap-path-prefix={ROOT}=. --remap-path-prefix={Path.home()}=/build'
 env['CARGO_INCREMENTAL']='0';env['SOURCE_DATE_EPOCH']='1790678400'
 return env
def lpac(host=False):
 src=ROOT/'third_party/lpac';build=ROOT/('.build/lpac-host' if host else '.build/lpac-arm64')
 flags=['-G','Ninja','-DCMAKE_BUILD_TYPE=MinSizeRel','-DCMAKE_POLICY_VERSION_MINIMUM=3.5']
 for name in ['DYNAMIC_LIBEUICC','DYNAMIC_DRIVERS','WITH_APDU_PCSC','WITH_APDU_AT','WITH_APDU_AT_WIN32','WITH_APDU_GBINDER','WITH_APDU_QMI','WITH_APDU_QMI_QRTR','WITH_APDU_MBIM','WITH_HTTP_CURL']:
  flags.append('-DLPAC_'+name+'=OFF')
 run(['cmake','-DSRC='+str(src/'src/version.h.in'),'-DDST='+str(src/'src/version.h'),'-P',src/'cmake/git-version.cmake'])
 cflags='-include '+shlex.quote(str(src/'src/version.h'))+' -ffunction-sections -fdata-sections -ffile-prefix-map='+shlex.quote(str(ROOT))+'=. -ffile-prefix-map='+shlex.quote(str(Path.home()))+'=/build'
 flags.append('-DCMAKE_C_FLAGS='+cflags)
 if not host:
  compiler=os.environ.get('ZTE_CROSS_CC') or shutil.which('aarch64-linux-musl-gcc')
  if not compiler:raise SystemExit('aarch64-linux-musl-gcc required')
  flags+=['-DCMAKE_SYSTEM_NAME=Linux','-DCMAKE_SYSTEM_PROCESSOR=aarch64','-DCMAKE_C_COMPILER='+compiler,'-DCMAKE_EXE_LINKER_FLAGS=-static -Wl,--gc-sections']
 run(['cmake','-S',src,'-B',build,*flags]);run(['cmake','--build',build,'-j','4'])
 result=build/'output/lpac'
 if not host:
  strip=shutil.which('aarch64-linux-musl-strip')
  if not strip:raise SystemExit('aarch64-linux-musl-strip required')
  run([strip,result])
 return result

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--tests',action='store_true');args=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
 env=environment();bridge=ROOT/'tools/removable-euicc/device'
 if args.tests:run(['cargo','test','--offline','--locked'],bridge,env)
 run(['cargo','build','--offline','--locked','--release','--target','aarch64-unknown-linux-musl'],bridge,env)
 runtime=ROOT/'ModemAgent/agent/resources/esim';runtime.mkdir(parents=True,exist_ok=True)
 files={'bridge':bridge/'target/aarch64-unknown-linux-musl/release/zte-removable-euicc','lpac':lpac(),'gsma-rsp-roots.pem':ROOT/'tools/removable-euicc/certs/gsma-rsp-roots.pem'}
 hashes={}
 for name,source in files.items():
  data=source.read_bytes()
  if name!='gsma-rsp-roots.pem':
   if data[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(data[18:20],'little')!=183:raise SystemExit('Not ARM64 ELF: '+name)
   if str(ROOT).encode() in data or str(Path.home()).encode() in data:raise SystemExit('Private build prefix in '+name)
  shutil.copy2(source,runtime/name);hashes[name]=sha(runtime/name)
 source=ROOT/'ModemAgent/agent/src/esim/resources.rs';text=source.read_text()
 for key,name in [('BRIDGE_HASH','bridge'),('LPAC_HASH','lpac'),('GSMA_HASH','gsma-rsp-roots.pem')]:
  text,n=re.subn(r'(const '+key+r': &str = ")[a-f0-9]{64}(";)',lambda m:m[1]+hashes[name]+m[2],text)
  if n!=1:raise SystemExit('Missing resource pin '+key)
 source.write_text(text)
 if args.tests:
  lpac(host=True);run([sys.executable,'third_party/lpac-build/test_stdio.py']);run([sys.executable,'third_party/lpac-build/verify_source_backport.py'])
 report={'source_only_build':True,'no_device':True,'lpac_commit':'c2fcf5e4b21c712d54e35a11da2ad9ad134fb821','qmi_license_status':'license_unspecified','qmi_component_manifest_sha256':component_manifest(),'sha256':hashes}
 (OUT/'runtime-build.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
