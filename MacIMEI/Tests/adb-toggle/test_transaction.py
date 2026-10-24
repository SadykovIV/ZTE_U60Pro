#!/usr/bin/env python3
"""Actual POSIX-shell transaction fixtures on synthetic files; no modem access."""
import hashlib, json, os, pathlib, re, shutil, signal, shlex, subprocess, tempfile, time, uuid
R=pathlib.Path(__file__).resolve().parents[2]
SOURCE=R/'Resources/Onboarding/adb-toggle.sh'
TOKEN='11111111-2222-3333-4444-555555555555'; CID='0123456789abcdef0123456789abcdef'; BOOT='11111111-1111-1111-1111-111111111111'
class Fixture:
 def __init__(self,present=True, firmware="B31"):
  self.root=pathlib.Path(tempfile.mkdtemp(prefix='zte-adb-toggle-fixture-')).resolve(); self.stage=self.root/f'tmp/zte-adb-toggle-{TOKEN}'
  self.stage.mkdir(parents=True,mode=0o700);self.stage.chmod(0o700)
  self.base=self.root/'sys/kernel/config/usb_gadget/g1';self.config=self.base/'configs/c.1';self.config.mkdir(parents=True)
  for name in ['ffs.adb','gsi.rndis','gsi.dpl']:(self.base/'functions'/name).mkdir(parents=True)
  (self.root/'sys/class/udc/a600000.dwc3').mkdir(parents=True)
  (self.base/'UDC').write_text('a600000.dwc3\n')
  for name,target in [('f1','gsi.rndis'),('f7','gsi.dpl')]+([('f6','ffs.adb')] if present else []): (self.config/name).symlink_to('../../../../usb_gadget/g1/functions/'+target)
  for path,value in [('sys/block/mmcblk0/device/cid',CID),('proc/sys/kernel/random/boot_id',BOOT),('firmware/image/modem.b16','fixture'),('usr/bin/diag-router','fixture'),('sbin/adbd','fixture'),('usr/bin/zte_topsw_mdm','fixture')]:
   p=self.root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(value+'\n')
  if firmware=='B04':(self.root/'firmware/image/modem.b16').unlink()
  proc=self.root/'proc/4242';(proc/'fd').mkdir(parents=True);(proc/'exe').symlink_to(self.root/'sbin/adbd')
  (proc/'cmdline').write_bytes(b'/sbin/adbd\0')
  (proc/'stat').write_text(' '.join(['4242','(adbd)','S']+['0']*18+['999'])+'\n')
  for n in range(3):(proc/f'fd/{n+4}').symlink_to(self.root/f'dev/usb-ffs/adb/ep{n}')
  (self.root/'data/zte-imei-studio').mkdir(parents=True,mode=0o700)
  self.rc=self.root/'etc/rc.local';self.rc.parent.mkdir()
  self.bootline='echo 1 > /sys/class/android_usb/android0/usb_op'
  self.rc.write_text('#!/bin/sh\n'+(self.bootline+'\n' if present else '')+'# preserve OEM startup\nsh /data/local/tmp/start_zte_imei_studio.sh\nexit 0\n');self.rc.chmod(0o775)
  self.rc_before=self.rc.read_bytes()
  shim=self.root/'shim';shim.mkdir()
  program='''#!/usr/bin/env python3
import sys,os,time,hashlib,json
n=os.path.basename(sys.argv[0]);a=sys.argv[1:]
if n=='id': print(0)
elif n=='uname': print('Linux' if a==['-s'] else 'aarch64')
elif n=='pidof': print(4242)
elif n=='ubus': print(json.dumps({'integrate_version':'XCBZ_HK_MU5250V1.0.0B04','wa_inner_version':'BD_XCBZHKMU5250V1.0.0B04'}))
elif n=='jsonfilter': print(json.load(sys.stdin)[a[-1][2:]])
elif n=='sleep': time.sleep(.01)
elif n=='stat':
 s=os.stat(a[-1]);f=a[1];print(f.replace('%u','0').replace('%a',format(s.st_mode&0o777,'o')).replace('%h',str(s.st_nlink)).replace('%s',str(s.st_size)).replace('%d',str(s.st_dev)).replace('%i',str(s.st_ino)))
elif n=='sha256sum':
 p=a[0]
 if p.endswith('/adb-toggle.sh'): print(hashlib.sha256(open(p,'rb').read()).hexdigest()+'  '+p);sys.exit(0)
 h='604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263' if p.endswith('/modem.b16') else '55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f' if p.endswith('/diag-router') else '93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64' if p.endswith('/zte_topsw_mdm') else '6d42bf97ae1f761ba3c5a0ee48deb84db0b19e4766b6b538b71741743d5b3f90';print(h+'  '+p)
elif n=='mv':
 if a[0]=='-T': os.rename(a[1],a[2])
 else: os.rename(a[0],a[1])
elif n=='readlink':
 p=a[-1];print(os.path.realpath(p) if '-f' in a else '../../../../usb_gadget/g1/functions/'+os.path.basename(os.path.realpath(p)) if '/configs/c.1/' in p else os.readlink(p))
'''
  if firmware=='B28':program=program.replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263','5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478')
  elif firmware=='B04-image':program=program.replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263','c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81')
  elif firmware!='B31':program=program.replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263','f'*64)
  for name in ['id','uname','pidof','sleep','stat','sha256sum','readlink','ubus','jsonfilter','mv']:
   p=shim/name;p.write_text(program);p.chmod(0o700)
  s=SOURCE.read_text().replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin',f'PATH={shim}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin')
  s=re.sub(r'/sys/|/proc/|/tmp/|/firmware/|/usr/bin/diag-router|/usr/bin/zte_topsw_mdm|/sbin/adbd|/dev/|/data/|/etc/',lambda m:str(self.root)+m.group(),s)
  s=s.replace('test ! -L /tmp && test "$(stat -c %u /tmp)"','test ! -L '+str(self.root/'tmp')+' && test "$(stat -c %u '+str(self.root/'tmp')+')"')
  s=s.replace('in /data ', 'in '+str(self.root/'data')+' ')
  s=s.replace(str(self.root)+'/dev/null','/dev/null')
  s=s.replace('BOOT_LINE=\'echo 1 > '+str(self.root), 'BOOT_LINE=\'echo 1 > ')
  self.script=self.stage/'adb-toggle.sh';self.script.write_text(s);self.script.chmod(0o600)
  self.procs=[]
 def run(self,mode,want='0'):
  return subprocess.run(['/bin/sh',str(self.script),mode,str(self.stage),TOKEN,CID,BOOT,want]+([hashlib.sha256(self.script.read_bytes()).hexdigest()] if mode=='reconcile' else []),capture_output=True,text=True,timeout=30)
 def apply(self,want='0'):
  p=subprocess.Popen(['/bin/sh',str(self.script),'apply',str(self.stage),TOKEN,CID,BOOT,want],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);self.procs.append(p);return p
 def phase(self):
  try:return (self.stage/'phase').read_text().strip()
  except FileNotFoundError:return ''
 def wait(self,state):
  deadline=time.monotonic()+30
  while time.monotonic()<deadline:
   if self.phase()==state:return
   time.sleep(.005)
  raise AssertionError(f'phase wanted {state}, got {self.phase()}')
 def close(self):
  for p in self.procs:
   if p.poll() is None:p.kill();p.wait()
  shutil.rmtree(self.root)

cases=[]
def test(name,fn,present=True,firmware="B31"):
 if os.environ.get('ADB_FAULT_MATRIX_ONLY') and not name.startswith('B04 fault matrix:'):return
 if os.environ.get('ADB_ENABLE_FAULTS_ONLY') and 'enable from original off' not in name:return
 f=Fixture(present,firmware)
 try:fn(f);cases.append(name);print('PASS '+name,flush=True)
 finally:f.close()
def ok(c,msg='assertion'): assert c,msg
def prepare(f,w='0'):r=f.run('prepare',w);ok(r.returncode==0,(r.stdout,r.stderr));ok(r.stdout=='ADB_PREPARED\n')
def commit(f,w='0'):
 prepare(f,w);p=f.apply(w);f.wait('awaiting-ack');r=f.run('ack',w);ok(r.returncode==0,(r.stdout,r.stderr));out,err=p.communicate(timeout=30);ok(p.returncode==0,(out,err));ok(f.phase()=='committed');ok(not(f.root/'tmp/zte-imei-app.lock').exists())
test('disable commits only exact ADB link, preserves RNDIS and DPL',lambda f:(commit(f),ok(not(f.config/'f6').exists()),ok(os.readlink(f.config/'f1')=='../../../../usb_gadget/g1/functions/gsi.rndis'),ok(os.readlink(f.config/'f7')=='../../../../usb_gadget/g1/functions/gsi.dpl')))
test('enable commits one free ADB link and preserves existing links',lambda f:(commit(f,'1'),ok(any(p.is_symlink() and os.readlink(p).endswith('/ffs.adb') for p in f.config.iterdir()))),False)
def rollback(f):
 before={p.name:os.readlink(p) for p in f.config.iterdir()};prepare(f);p=f.apply();p.communicate(timeout=30);ok(p.returncode==73);ok(f.phase()=='rolled-back');ok(before=={p.name:os.readlink(p) for p in f.config.iterdir()});ok(not(f.root/'tmp/zte-imei-app.lock').exists());ok(f.rc.read_bytes()==f.rc_before);ok(f.rc.stat().st_mode&0o777==0o775)
test('missing host ACK rolls back exact original links and releases owned lock',rollback)
def hup(f):
 prepare(f);p=f.apply();f.wait('awaiting-ack');os.kill(p.pid,signal.SIGHUP);p.communicate(timeout=30);ok(f.phase()=='rolled-back')
test('detached worker ignores SSH HUP and restores without host',hup)
def duplicate(f):
 prepare(f);p=f.apply();f.wait('awaiting-ack');r=f.run('apply');ok(r.returncode!=0);ok(f.run('ack').returncode==0);p.communicate(timeout=30);ok(f.phase()=='committed')
test('second apply cannot repeat a dispatched mutation',duplicate)
def ownership(f):
 prepare(f);(f.root/'tmp/zte-imei-app.lock/owner').write_text('foreign');r=f.run('apply');ok(r.returncode!=0);ok((f.config/'f6').is_symlink());ok((f.root/'tmp/zte-imei-app.lock/owner').read_text()=='foreign')
test('changed lock owner refuses before any USB change',ownership)
def foreign(f):
 prepare(f);p=f.apply();f.wait('awaiting-ack');(f.config/'f1').unlink();(f.config/'f1').symlink_to('../../../../usb_gadget/g1/functions/gsi.dpl');p.communicate(timeout=30);ok(f.phase()=='rollback-unknown');ok((f.root/'tmp/zte-imei-app.lock').exists());ok(os.readlink(f.config/'f1')=='../../../../usb_gadget/g1/functions/gsi.dpl')
test('foreign function change retains lock and is never overwritten',foreign)
def boot(f):
 prepare(f);(f.root/'proc/sys/kernel/random/boot_id').write_text('changed');r=f.run('apply');ok(r.returncode!=0);ok((f.config/'f6').is_symlink())
test('boot drift refuses before mutation',boot)
def malformed(f):
 (f.config/'arbitrary').symlink_to('../../../../usb_gadget/g1/functions/gsi.rndis');r=f.run('prepare');ok(r.returncode!=0);ok(not(f.root/'tmp/zte-imei-app.lock').exists())
test('unknown configuration entry refuses before lock/mutation',malformed)
def cancel(f):
 prepare(f);ok(f.run('cancel').stdout=='ADB_CANCELLED\n');ok(f.phase()=='cancelled');ok(not(f.root/'tmp/zte-imei-app.lock').exists());ok(f.run('apply').returncode!=0)
test('unlaunched preparation can cancel without USB writes or replay',cancel)
def fd(f):
 (f.root/'proc/4242/fd/5').unlink();r=f.run('prepare');ok(r.returncode!=0);ok(not(f.root/'tmp/zte-imei-app.lock').exists())
test('missing daemon descriptor blocks capability',fd)
test('already desired is no-op without device lock',lambda f:(ok(f.run('prepare','1').stdout=='ADB_UNCHANGED\n'),ok(not(f.root/'tmp/zte-imei-app.lock').exists())))
test('interrupted preparation cancels without USB writes or unrelated lock removal',lambda f:(ok(f.run('cancel').stdout=='ADB_CANCELLED\n'),ok(f.run('result').stdout=='ADB_PHASE=cancelled\n'),ok((f.config/'f6').is_symlink())))
def active_prepare(f):
 (f.stage/'prepare-active').mkdir(mode=0o700)
 before={p.name:os.readlink(p) for p in f.config.iterdir()}
 ok(f.run('cancel').returncode!=0)
 ok(f.run('prepare').returncode!=0)
 ok((f.stage/'prepare-active').is_dir())
 ok(not (f.stage/'decision').exists())
 ok(not (f.root/'tmp/zte-imei-app.lock').exists())
 ok(before=={p.name:os.readlink(p) for p in f.config.iterdir()})
test('active preparation prevents concurrent prepare/cancel without writes',active_prepare)
def detached_parent(f):
 prepare(f)
 args=['/bin/sh',str(f.script),'apply',str(f.stage),TOKEN,CID,BOOT,'0']
 launch='nohup '+shlex.join(args)+' </dev/null >'+shlex.quote(str(f.stage/'worker.log'))+' 2>&1 & printf "%s\\n" "$!"'
 parent=subprocess.Popen(['/bin/sh','-c',launch],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 f.procs.append(parent)
 out,err=parent.communicate(timeout=5)
 ok(parent.returncode==0 and out.strip().isdigit(),(out,err))
 worker=int(out.strip());ok(worker>1)
 f.wait('awaiting-ack');os.kill(worker,signal.SIGHUP)
 f.wait('rolled-back')
 ok((f.config/'f6').is_symlink())
 ok(not (f.root/'tmp/zte-imei-app.lock').exists())
test('nohup worker survives exited launch shell and HUP without setsid command',detached_parent)
def persistent_off(f):
 commit(f)
 ok(f.bootline not in f.rc.read_text())
 ok('sh /data/local/tmp/start_zte_imei_studio.sh' in f.rc.read_text())
 ok(f.rc.stat().st_mode&0o777==0o775)
 backups=list((f.root/'data/zte-imei-studio/adb-control').glob('*.before'))
 ok(len(backups)==1 and backups[0].read_bytes()==f.rc_before)
 ok(backups[0].stat().st_mode&0o777==0o600)
 test_rc=f.rc.read_text().replace('sh /data/local/tmp/start_zte_imei_studio.sh','true')
 ok(subprocess.run(['/bin/sh','-n'],input=test_rc,text=True).returncode==0)
test('B31 disable persists boot-off with private original and unchanged unrelated startup',persistent_off)
test('measured B28 disable validates actual descriptor capability and persists off',persistent_off,firmware='B28')
test('measured B04 without modem.b16 preserves USB functions and clears boot enable',persistent_off,firmware='B04')
test('measured B04 image preserves USB functions and clears boot enable',persistent_off,firmware='B04-image')
def invalid_b04(f):
 p=f.root/'shim/ubus';p.write_text(p.read_text().replace('BD_XCBZHKMU5250V1.0.0B04','BD_UNKNOWN_B04'))
 ok(f.run('prepare').returncode!=0);ok(f.rc.read_bytes()==f.rc_before);ok((f.config/'f6').is_symlink())
test('absent modem image with different native B04 identity refuses writes',invalid_b04,firmware='B04')
def invalid_b04_hash(f):
 p=f.root/'shim/sha256sum';p.write_text(p.read_text().replace('93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64','f'*64))
 ok(f.run('prepare').returncode!=0);ok(f.rc.read_bytes()==f.rc_before);ok((f.config/'f6').is_symlink())
test('B04 label with unmeasured native component refuses writes',invalid_b04_hash,firmware='B04')
test('B04 measured image with different native build refuses writes',invalid_b04_hash,firmware='B04-image')
test('B04 measured image with different public version refuses writes',invalid_b04,firmware='B04-image')
def persistent_enable(f):
 commit(f,'1')
 ok(f.rc.read_text().count(f.bootline)==1)
 ok(f.rc.read_text().startswith('#!/bin/sh\n'+f.bootline+'\n'))
test('enable restores only the known boot activation line',persistent_enable,False)
def runtime_already_off(f):
 f.rc.write_text('#!/bin/sh\n'+f.bootline+'\nexit 0\n')
 original={p.name:os.readlink(p) for p in f.config.iterdir()}
 source=f.script.read_text().replace("printf '\\n' > \"$BASE/UDC\"",'exit 99')
 f.script.write_text(source)
 commit(f)
 ok(f.bootline not in f.rc.read_text())
 ok(original=={p.name:os.readlink(p) for p in f.config.iterdir()})
test('already runtime-off still removes persisted enable without USB change',runtime_already_off,False)
def no_ffs_off(f):
 (f.root/'proc/4242/fd/5').unlink()
 (f.base/'functions/ffs.adb').rmdir()
 runtime_already_off(f)
test('already off without FunctionFS descriptors still clears persisted boot enable',no_ffs_off,False)

def foreign_rc(f):
 prepare(f);p=f.apply();f.wait('awaiting-ack');f.rc.write_text('#!/bin/sh\n# independent change\nexit 0\n');p.communicate(timeout=30)
 ok(f.phase()=='rollback-unknown');ok('independent change' in f.rc.read_text())
test('concurrent startup edit is not overwritten during rollback',foreign_rc)
test('unknown firmware refuses before boot or USB changes',lambda f:(ok(f.run('prepare').returncode!=0),ok(f.rc.read_bytes()==f.rc_before),ok((f.config/'f6').is_symlink())),firmware='unknown')

def stopped(f,w='0',after=False):
 prepare(f,w)
 for name in ['decision','apply-once']:(f.stage/name).mkdir(mode=0o700)
 (f.stage/'phase').write_text('rollback-unknown\n')
 if after:
  name=(f.stage/'name').read_text().strip()
  if w=='0':(f.config/name).unlink()
  else:(f.config/name).symlink_to('../../functions/ffs.adb')
  f.rc.write_bytes((f.stage/'rc.after').read_bytes())
def snapshot(f):
 return (f.rc.read_bytes(),(f.base/'UDC').read_bytes(),{p.name:os.readlink(p) for p in f.config.iterdir()})
def settled(f,after=False,w='0'):
 stopped(f,w,after);before=snapshot(f)
 r=f.run('reconcile',w);ok(r.returncode==0,(r.stdout,r.stderr));ok(r.stdout=='ADB_RECOVERED=settled-'+('after' if after else 'before')+'\n')
 ok(snapshot(f)==before,'recovery must not change USB or startup');ok(not(f.root/'tmp/zte-imei-app.lock').exists())
 ok(f.run('apply',w).returncode!=0,'late dispatch must remain fenced')
 ok(f.run('reconcile',w).returncode==0,'lost recovery reply must be replayable')
test('lost SSH known original state settles without USB or startup writes',settled)
test('lost SSH known desired state settles without USB or startup writes',lambda f:settled(f,True))
test('fresh native daemon after enable allows known desired state',lambda f:settled(f,True,'1'),False)
def recovery_prepared(f):
 prepare(f);before=snapshot(f);r=f.run('reconcile');ok(r.returncode==0,(r.stdout,r.stderr));ok(r.stdout=='ADB_RECOVERED=cancelled\n');ok(snapshot(f)==before);ok(f.run('apply').returncode!=0)
test('dispatched but unstarted preparation can be safely fenced and cancelled',recovery_prepared)
def refuse_recovery(f,change):
 stopped(f);change(f);before=snapshot(f);r=f.run('reconcile');ok(r.returncode!=0,(r.stdout,r.stderr));ok(snapshot(f)==before);ok((f.root/'tmp/zte-imei-app.lock/owner').exists());ok(not(f.stage/'settle-active').exists() or (f.stage/'settle-active/foreign').exists())
test('recovery refuses active worker even with ordinary process name',lambda f:refuse_recovery(f,lambda f:(f.root/'proc/4242/cmdline').write_bytes(('/bin/sh\0'+str(f.script)+'\0apply\0').encode())))
test('recovery refuses missing cmdline on existing process',lambda f:refuse_recovery(f,lambda f:(f.root/'proc/4242/cmdline').unlink()))
test('recovery refuses foreign common lock owner',lambda f:refuse_recovery(f,lambda f:(f.root/'tmp/zte-imei-app.lock/owner').write_text('foreign')))
test('recovery refuses unexpected common lock contents without removing owner',lambda f:refuse_recovery(f,lambda f:(f.root/'tmp/zte-imei-app.lock/extra').write_text('foreign')))
test('recovery refuses partial USB state against exact saved before and after',lambda f:refuse_recovery(f,lambda f:(f.config/'f1').unlink()))
test('recovery refuses unrelated startup edit',lambda f:refuse_recovery(f,lambda f:f.rc.write_text('#!/bin/sh\n# other edit\nexit 0\n')))
test('recovery refuses malformed saved expected USB state',lambda f:refuse_recovery(f,lambda f:(f.stage/'after').write_text('f1=gsi.dpl\n')))
test('recovery refuses symlink saved startup snapshot',lambda f:refuse_recovery(f,lambda f:((f.stage/'rc.before').unlink(),(f.stage/'rc.before').symlink_to(f.rc))))
def reused(f):
 stopped(f)
 p=f.root/'shim/od';p.write_text('#!/usr/bin/env python3\nimport os,subprocess,sys\np=sys.argv[-1]\nif p.endswith("/cmdline"):\n s=p[:-7]+"stat"\n t=open(s).read();open(s,"w").write(t.replace("999", "1000"))\nr=subprocess.run(["/usr/bin/od"]+sys.argv[1:]);sys.exit(r.returncode)\n');p.chmod(0o700)
 before=snapshot(f);r=f.run('reconcile');ok(r.returncode!=0);ok(snapshot(f)==before);ok((f.root/'tmp/zte-imei-app.lock/owner').exists())
test('same-name reused PID cannot satisfy absence proof',reused)
def unapproved_script(f):
 stopped(f);before=snapshot(f)
 r=subprocess.run(['/bin/sh',str(f.script),'reconcile',str(f.stage),TOKEN,CID,BOOT,'0','f'*64],capture_output=True,text=True)
 ok(r.returncode!=0);ok(snapshot(f)==before);ok((f.root/'tmp/zte-imei-app.lock/owner').exists())
test('staged script must match the host-approved exact hash',unapproved_script)

def stale_markers(f):
 prepare(f)
 for n in ['prepare-active','settle-active']:(f.stage/n).mkdir(mode=0o700)
 before=snapshot(f);r=f.run('reconcile');ok(r.returncode==0,(r.stdout,r.stderr));ok(snapshot(f)==before);ok(f.phase()=='cancelled');ok(not(f.stage/'prepare-active').exists());ok(not(f.stage/'settle-active').exists())
test('crashed own empty prepare and recovery fences can reconcile after worker absence',stale_markers)
test('unknown recovery fence content is retained',lambda f:refuse_recovery(f,lambda f:((f.stage/'settle-active').mkdir(mode=0o700),(f.stage/'settle-active/foreign').write_text('x'))))

def fault_stop(f,needle,w='0',mode='prepare',expected='cancelled'):
 original=f.script.read_text()
 if mode=='apply': prepare(f,w)
 # Kill at a real shell statement boundary, then recover using the unchanged
 # verified helper. Only the synthetic worker contains the fault injection.
 injected=original.replace(needle,needle+'\nkill -KILL $$',1)
 ok(injected!=original,'fault point absent');f.script.write_text(injected)
 result=f.run(mode,w);ok(result.returncode<0,(result.returncode,result.stderr))
 f.script.write_text(original)
 before=snapshot(f)
 recovered=f.run('reconcile',w)
 if expected=='refused':
  ok(recovered.returncode!=0,(recovered.stdout,recovered.stderr));ok((f.root/'tmp/zte-imei-app.lock').exists())
 else:
  ok(recovered.returncode==0,(recovered.stdout,recovered.stderr));ok(recovered.stdout=='ADB_RECOVERED='+expected+'\n');ok(not(f.root/'tmp/zte-imei-app.lock').exists())
  ok(f.run('apply',w).returncode!=0,'delayed apply not fenced')
 ok(snapshot(f)==before,'recovery changed USB/rc')
for firmware in ['B04-image','B04']:
 test('B04 fault matrix: prepare killed after ownership '+firmware,lambda f:fault_stop(f,'  phase preparing'),firmware=firmware)
 test('B04 fault matrix: dispatch killed after decision '+firmware,lambda f:fault_stop(f,'validate_current before\nmkdir "$STAGE/decision" || fail',mode='apply'),firmware=firmware)
 test('B04 fault matrix: dispatch killed after apply-once '+firmware,lambda f:fault_stop(f,'mkdir "$STAGE/apply-once" || fail',mode='apply',expected='settled-before'),firmware=firmware)
 test('B04 fault matrix: apply killed after startup write leaves mixed state '+firmware,lambda f:fault_stop(f,'rc_install after before',mode='apply',expected='refused'),firmware=firmware)
 test('B04 fault matrix: ACK lost after completed USB change '+firmware,lambda f:fault_stop(f,'phase awaiting-ack',mode='apply',expected='settled-after'),firmware=firmware)
 test('B04 fault matrix: unchanged original state after worker exit '+firmware,settled,firmware=firmware)
 test('B04 fault matrix: foreign owner retained '+firmware,lambda f:refuse_recovery(f,lambda f:(f.root/'tmp/zte-imei-app.lock/owner').write_text('foreign')),firmware=firmware)
def temporary_metadata(f):
 prepare(f)
 for n in ['phase.new','before.new']:
  p=f.stage/n;p.write_text('PRIVATE-INCOMPLETE-CANARY');p.chmod(0o600)
 before=snapshot(f);r=f.run('reconcile');ok(r.returncode==0,(r.stdout,r.stderr));ok(snapshot(f)==before);ok(f.phase()=='cancelled');ok((f.stage/'before.new').read_text()=='PRIVATE-INCOMPLETE-CANARY')
test('B04 fault matrix: incomplete metadata is never trusted',temporary_metadata,firmware='B04-image')
def ownerless(f):
 stopped(f);(f.root/'tmp/zte-imei-app.lock/owner').unlink();before=snapshot(f);r=f.run('reconcile');ok(r.returncode!=0);ok(snapshot(f)==before);ok((f.root/'tmp/zte-imei-app.lock').is_dir())
test('B04 fault matrix: legacy ownerless shared lock is not blindly claimed',ownerless,firmware='B04-image')
def restarted_daemon(f):
 stopped(f,'1',True)
 proc=f.root/'proc/4242';new=f.root/'proc/4343';proc.rename(new)
 p=new/'stat';p.write_text(p.read_text().replace('999','1000'))
 p=f.root/'shim/pidof';p.write_text(p.read_text().replace('print(4242)','print(4343)'))
 before=snapshot(f);r=f.run('reconcile','1');ok(r.returncode==0,(r.stdout,r.stderr));ok(r.stdout=='ADB_RECOVERED=settled-after\n');ok(snapshot(f)==before)
test('B04 fault matrix: restarted native adbd is measured afresh',restarted_daemon,False,'B04-image')

for firmware in ['B04-image','B04']:
 for label,point,mode,expected in [
  ('prepare','  phase preparing','prepare','cancelled'),
  ('decision','validate_current before\nmkdir "$STAGE/decision" || fail','apply','cancelled'),
  ('apply-once','mkdir "$STAGE/apply-once" || fail','apply','settled-before'),
  ('startup-only','rc_install after before','apply','refused'),
  ('USB-complete','phase awaiting-ack','apply','settled-after')]:
  test('B04 fault matrix: enable from original off '+label+' '+firmware,lambda f,p=point,m=mode,e=expected:fault_stop(f,p,w='1',mode=m,expected=e),False,firmware)
print(json.dumps({'sourceSha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'passed':len(cases),'cases':cases,'deviceAccess':False,'kernelConfigfsEmulation':False}))
