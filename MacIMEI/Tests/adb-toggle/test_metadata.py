#!/usr/bin/env python3
"""Read-only, sanitized ADB diagnostic probe on private synthetic files."""
import ast, hashlib, json, os, pathlib, re, subprocess
HERE=pathlib.Path(__file__).resolve().parent
source=HERE/'test_transaction.py'
module=ast.parse(source.read_text()); prefix=[]
for node in module.body:
 if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='cases' for t in node.targets): break
 prefix.append(node)
ns={'__file__':str(source)}
exec(compile(ast.Module(body=prefix,type_ignores=[]),str(source),'exec'),ns)
repo=HERE.parents[1]
spec=json.loads((repo/'Resources/FirmwareResearch/probes.json').read_text())
probe=next(p for p in spec['probes'] if p['id']=='adb-transaction-metadata')
command=probe['command']
mac=(repo/'Sources/ModemInformation.swift').read_text()
windows=(repo.parent/'Windows_x64/src/Diagnostics/ModemLogCollector.cs').read_text()
assert command in mac and '\n'.join('        '+l for l in command.splitlines()) in windows
assert 'adb-transaction.txt' in mac and 'adb-transaction.txt' in windows
f=ns['Fixture']()
def snapshot():
 out={}
 for root,ds,fs in os.walk(f.root,followlinks=False):
  for n in ds+fs:
   p=pathlib.Path(root)/n
   out[str(p.relative_to(f.root))]=(oct(p.lstat().st_mode),os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else '')
 return out
try:
 prepared=f.run('prepare');assert prepared.returncode==0,prepared.stderr
 cmd=command.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin',f'PATH={f.root}/shim:/usr/bin:/bin')
 cmd=re.sub(r'/tmp/|/proc/|/etc/',lambda m:str(f.root)+m.group(),cmd)
 before=snapshot()
 result=subprocess.run(['/bin/sh','-c',cmd],text=True,capture_output=True,timeout=30)
 assert result.returncode==0,result.stderr
 assert snapshot()==before,'diagnostic modified device fixture'
 assert 'phase=prepared\n' in result.stdout and 'common_lock=owned\n' in result.stdout and 'startup_snapshot=before\n' in result.stdout
 for forbidden in [ns['CID'],ns['TOKEN'],ns['BOOT'],str(f.root),'start_zte_imei_studio.sh','usb_op','/sbin/adbd']:
  assert forbidden not in result.stdout,forbidden
 (f.stage/'phase').write_text('PRIVATE-PHASE-CANARY')
 (f.root/'proc/4242/cmdline').write_bytes(('PRIVATE-ARGV-CANARY\0'+str(f.script)+'\0').encode())
 before=snapshot()
 result=subprocess.run(['/bin/sh','-c',cmd],text=True,capture_output=True,timeout=30)
 assert result.returncode==0 and 'phase=unknown\n' in result.stdout and 'stage_processes=1\n' in result.stdout
 assert 'PRIVATE' not in result.stdout and str(f.root) not in result.stdout and ns['TOKEN'] not in result.stdout
 assert snapshot()==before
 # Inject the filesystem failure diagnostic a disappearing stat/read can emit.
 # No private basename or token may escape through stderr either.
 shim=f.root/'shim/stat';shim.write_text(shim.read_text().replace("n=os.path.basename", "sys.stderr.write('PRIVATE-STAT-PATH-CANARY\\n')\nn=os.path.basename"))
 result=subprocess.run(['/bin/sh','-c',cmd],text=True,capture_output=True,timeout=30)
 assert result.returncode==0 and result.stderr=='' and 'PRIVATE' not in result.stdout
 print(json.dumps({'passed':7,'parity':True,'boundedMetadata':True,'privateCanariesOmitted':True,'readOnly':True,'deviceAccess':False}))
finally:f.close()
