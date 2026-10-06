#!/usr/bin/env python3
"""Production helper control-flow tests in a fake host filesystem, never a modem.
Real ARM64 opkg/usign execution is covered separately by the isolated VM evidence.
"""
import hashlib, io, os, re, subprocess, sys, tarfile, tempfile, unittest, uuid
from pathlib import Path
SHA=lambda b:hashlib.sha256(b).hexdigest()
SOURCE=Path(__file__).resolve().parents[1]/'Resources/ExperimentalOpkg/manager.sh'
DEFAULT_FEEDS=''.join('src/gz official_'+n+' https://downloads.openwrt.org/releases/23.05.4/'+n+'\n' for n in ['base','packages','core'])
BASE_CONFIG='dest root /\nlists_dir ext /var/opkg-lists\narch all 1\narch aarch64_cortex-a53 10\noption check_signature 1\noption verify_program /usr/sbin/opkg-key\n'
CID='a'*32; BOOT='11111111-2222-3333-4444-555555555555'
class HelperTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='opkg-fixture-');self.fs=Path(self.temp.name)
  for p in ['data','tmp','proc/sys/kernel/random','sys/block/mmcblk0/device','etc','firmware/image','bin']:(self.fs/p).mkdir(parents=True,exist_ok=True,mode=0o700)
  (self.fs/'proc/sys/kernel/random/boot_id').write_text(BOOT);(self.fs/'sys/block/mmcblk0/device/cid').write_text(CID)
  (self.fs/'etc/openwrt_release').write_text("DISTRIB_RELEASE='23.05.4'\nDISTRIB_ARCH='aarch64_cortex-a53'\n")
  (self.fs/'proc/mounts').write_text(f'/dev/fake {self.fs}/data ext4 rw 0 0\n');(self.fs/'firmware/image/modem.b16').write_bytes(b'fixture')
  src=re.sub(r'(?<![a-zA-Z0-9_/])/(?:data|proc|sys|tmp|etc/openwrt_release|etc/resolv.conf|firmware)',lambda m:str(self.fs)+m[0],SOURCE.read_text())
  src=src.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C','export LC_ALL=C').replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263',SHA(b'fixture'))
  # macOS cannot create chroot devices without privileges. Stub only these two
  # device predicates/metadata; no guest command executes through this fixture.
  src=src.replace('elif [ -c "$item" ];then','elif [ -c "$item" ];then')
  self.supervisor=self.fs/'zte-timeout';self.supervisor.write_text('#!/bin/sh\nshift; exec "$@"\n');self.supervisor.chmod(0o700)
  self.supervisor_hash=SHA(self.supervisor.read_bytes())
  src=re.sub(r'TIMEOUT_SHA=[^\n]+','TIMEOUT_SHA='+self.supervisor_hash,src)
  self.script=self.fs/'manager.sh';self.script.write_text(src);self.script.chmod(0o600)
  self.root=self.fs/'data/zte-imei-apps/opkg-private';self.env=dict(os.environ,PATH=str(self.fs/'bin')+os.pathsep+os.environ['PATH'],FIXTURE_ROOT=str(self.fs))
  self.shell('id','echo 0');self.shell('uname','case "$1" in -s) echo Linux;;*) echo aarch64;;esac')
  self.shell('df','echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fake 9999999 1 ${FAKE_FREE-9999999} 1% /data"')
  self.shell('timeout','echo NATIVE_TIMEOUT_MUST_NOT_RUN >&2; exit 98');self.shell('sync','exit 0')
  self.python('flock','import fcntl,sys;fcntl.flock(int(sys.argv[-1]),fcntl.LOCK_EX|fcntl.LOCK_NB)')
  self.python('mknod','import os,sys;open(sys.argv[3],"wb").close();os.chmod(sys.argv[3],0o600)')
  self.shell('stat', '''case "$2" in
%u) echo 0;;
%a) exec /usr/bin/stat -f '%Lp' "$3";;
%h) exec /usr/bin/stat -f '%l' "$3";;
%s) exec /usr/bin/stat -f '%z' "$3";;
%u:%h) printf '0:';exec /usr/bin/stat -f '%l' "$3";;
%u:%a) printf '0:';exec /usr/bin/stat -f '%Lp' "$3";;
*) exit 99;;esac''')
  self.python('chroot',r'''import os,sys,pathlib
s=pathlib.Path(sys.argv[1]);args=sys.argv[3:];p=s/'packages';mode=os.environ.get('FAKE_MODE','')
with (pathlib.Path(os.environ['FIXTURE_ROOT'])/'chroot.log').open('a') as log:log.write(' '.join(sys.argv[2:])+'\n')
if mode=='fail' and sys.argv[2]=='/bin/opkg':sys.exit(2)
command=next((x for x in args if x in ['install','remove','update','list','info','status','files','list-installed','--version']),None)
if command=='install':
 (p/'usr/bin').mkdir(exist_ok=True);(p/'usr/bin/demo').write_text('demo');(p/'usr/bin/demo').chmod(0o700)
 with (p/'usr/lib/opkg/status').open('a') as f:f.write('Package: demo\nVersion: 1\nStatus: install ok installed\nDescription: Example utility\n\n')
 if mode=='script':(p/'usr/lib/opkg/info/demo.postinst').write_text('#!/bin/sh\nmalicious\n')
 if mode=='escape':(s/'bin/opkg').write_text('changed runtime')
 if mode=='special':(p/'usr/bin/bad').symlink_to('/etc/passwd')
if command=='remove':
 (p/'usr/bin/demo').unlink();f=p/'usr/lib/opkg/status';f.write_text(f.read_text().split('Package: demo')[0])
if mode=='reboot':(pathlib.Path(os.environ['FIXTURE_ROOT'])/'proc/sys/kernel/random/boot_id').write_text('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
print('fixture opkg '+str(command))
''')
 def shell(self,name,body):
  p=self.fs/'bin'/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o700)
 def python(self,name,body):
  p=self.fs/'bin'/name;p.write_text('#!'+sys.executable+'\n'+body+'\n');p.chmod(0o700)
 def tearDown(self):self.temp.cleanup()
 def runtime(self,version='one'):
  stage=self.fs/'tmp'/('zte-opkg-'+str(uuid.uuid4()));stage.mkdir(mode=0o700)
  files={'bin/opkg':b'fixture '+version.encode(),'lib/libc.so':b'fixture musl','etc/opkg.conf':(BASE_CONFIG+DEFAULT_FEEDS).encode(),'etc/opkg/keys/b5043e70f9a75cde':b'fixture key'}
  for feed in ['base','packages','core']:
   for ext in ['', '.sig']:files['packages/var/opkg-lists/official_'+feed+ext]=b'fixture signed index'
  manifest=''.join(SHA(v)+'  '+k+'\n' for k,v in sorted(files.items())).encode();files['RUNTIME.sha256']=manifest
  archive=stage/'runtime.tar.gz'
  with tarfile.open(archive,'w:gz') as t:
   for k,v in files.items():
    info=tarfile.TarInfo(k);info.size=len(v);info.mode=0o700 if k.startswith(('bin/','lib/')) else 0o600;t.addfile(info,io.BytesIO(v))
  archive.chmod(0o600);return stage,SHA(archive.read_bytes()),SHA(manifest)
 def call(self,action,*args,error=None,capture=False):
  (self.fs/'proc/sys/kernel/random/uuid').write_text(str(uuid.uuid4()))
  r=subprocess.run(['/bin/sh',str(self.script),action,CID,BOOT,*map(str,args)],env=self.env,text=True,capture_output=True,timeout=60)
  if error:self.assertNotEqual(r.returncode,0,r.stdout);self.assertIn('OPKG_ERROR '+error,r.stderr);return r
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  if capture:return r.stdout
  lines=r.stdout.split('__ZTE_PRIVATE_OPKG_V1__\n')[-1].splitlines();return dict(x.split('=',1) for x in lines if '=' in x)
 def install(self):return self.call('install-adapter',*self.runtime())
 def state(self):return (self.root/'state').read_bytes()
 def active(self):return self.root/'generations'/dict(x.split('=',1) for x in self.state().decode().splitlines())['active']
 def test_b28_status_and_feeds_do_not_require_firmware_or_mutation_capabilities(self):
  (self.fs/'firmware/image/modem.b16').write_bytes(b'other firmware')
  (self.fs/'etc/openwrt_release').write_text("DISTRIB_RELEASE='other'\n")
  (self.fs/'proc/mounts').write_text(f'/dev/fake {self.fs}/data ext4 ro,noexec 0 0\n')
  for name in ['chroot','flock','mknod']:(self.fs/'bin'/name).unlink()
  self.assertEqual(self.call('inspect')['installed'],'0');self.assertFalse(self.root.exists())
  self.call('install-adapter',*self.runtime(),error='FIRMWARE');self.assertFalse(self.root.exists())
 def test_read_binding_platform_and_owned_layout_still_required(self):
  self.shell('id','echo 1000');self.call('inspect',error='ROOT_ARCH');self.shell('id','echo 0')
  self.shell('uname','case "$1" in -s) echo OtherOS;;*) echo aarch64;;esac');self.call('inspect',error='ROOT_ARCH')
  self.shell('uname','case "$1" in -s) echo Linux;;*) echo armv7l;;esac');self.call('inspect',error='ROOT_ARCH')
  self.shell('uname','case "$1" in -s) echo Linux;;*) echo aarch64;;esac')
  (self.fs/'sys/block/mmcblk0/device/cid').write_text('b'*32);self.call('inspect',error='DEVICE_CHANGED')
  (self.fs/'sys/block/mmcblk0/device/cid').write_text(CID)
  base=self.fs/'data/zte-imei-apps';base.mkdir();base.chmod(0o777);self.call('inspect',error='OWNER')
  self.assertFalse(self.root.exists())
 def test_b28_owned_feeds_are_read_only_with_seals(self):
  self.install();old=self.state();self.call('execute','install','demo');old=self.state()
  (self.fs/'firmware/image/modem.b16').write_bytes(b'other firmware')
  for name in ['chroot','flock','mknod']:(self.fs/'bin'/name).unlink()
  loaded=self.call('read-feeds',capture=True);self.assertIn('source=src/gz official_base',loaded)
  self.assertEqual(self.state(),old);self.assertEqual(self.call('inspect')['package'].split('\t')[0],'demo')
  (self.active()/'sandbox/bin/opkg').chmod(0o600);self.call('inspect',error='CHANGED_GENERATION')
 def test_inspect_absent_read_only(self):
  self.assertEqual(self.call('inspect')['installed'],'0');self.assertFalse(self.root.exists())
 def cli(self,*args,error=False):
  (self.fs/'proc/sys/kernel/random/uuid').write_text(str(uuid.uuid4()))
  r=subprocess.run(['/bin/sh',str(self.root/'opkg'),*args],env=self.env,text=True,capture_output=True,timeout=60)
  if error:self.assertNotEqual(r.returncode,0,r.stdout)
  else:self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  return r
 def test_inspect_does_not_need_any_supervisor(self):
  self.supervisor.unlink();self.assertEqual(self.call('inspect')['installed'],'0');self.assertFalse(self.root.exists())
 def test_missing_modified_symlink_or_nonexec_supervisor_refused(self):
  original=self.supervisor.read_bytes()
  for mode in ['modified','nonexec','symlink','missing']:
   if self.supervisor.exists() or self.supervisor.is_symlink():self.supervisor.unlink()
   if mode=='modified':self.supervisor.write_bytes(original+b'#changed');self.supervisor.chmod(0o700)
   if mode=='nonexec':self.supervisor.write_bytes(original);self.supervisor.chmod(0o600)
   if mode=='symlink':self.supervisor.symlink_to(self.script)
   self.call('install-adapter',*self.runtime(),error='TIMEOUT_HELPER_HASH' if mode=='modified' else 'TIMEOUT_HELPER_FILE')
   self.assertFalse(self.root.exists())
 def test_permanent_cli_works_after_staged_tool_removed_and_rollback(self):
  self.install();first=self.active();old_seal=(first/'seal').read_bytes()
  self.call('execute','install','demo');self.call('rollback');self.assertEqual((first/'seal').read_bytes(),old_seal)
  self.supervisor.unlink();self.cli('files','demo');self.cli('list')
 def test_legacy_cli_migrates_without_rewriting_old_generation_seals(self):
  first=self.install();old=self.active();seal=(old/'seal').read_bytes()
  template=Path(__file__).with_name('Fixtures').joinpath('experimental-opkg-legacy-cli.sh').read_text()
  template=re.sub(r'(?<![a-zA-Z0-9_/])/(?:data|proc|sys|tmp|etc/openwrt_release|etc/resolv.conf|firmware)',lambda m:str(self.fs)+m[0],template).replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C','export LC_ALL=C')
  (self.root/'opkg').write_text(template);(self.root/'opkg').chmod(0o700)
  self.call('inspect');self.assertEqual((self.root/'opkg').read_text(),template)
  self.env['FAKE_MODE']='fail';self.call('execute','install','demo',error='OPKG_COMMAND_FAILED');self.env.pop('FAKE_MODE');self.assertEqual((self.root/'opkg').read_text(),template)
  self.call('execute','install','demo');self.assertIn('runner v2',(self.root/'opkg').read_text());self.call('rollback');self.assertEqual(self.active(),old);self.assertEqual((old/'seal').read_bytes(),seal)
  self.supervisor.unlink();self.cli('list')
 def test_corrupt_existing_cli_or_runner_refuses_before_opkg(self):
  self.install();old=self.state();cli=self.root/'opkg';original=cli.read_bytes();cli.write_bytes(original+b'# tampered\n')
  self.call('execute','install','demo',error='CLI_CHANGED');self.assertEqual(self.state(),old)
  cli.write_bytes(original);runner=next((self.root/'runners').glob('*/zte-timeout'));runner.write_bytes(b'changed')
  self.call('execute','install','demo',error='RUNNER_TIMEOUT');self.assertEqual(self.state(),old)
 def test_install_remove_noop_remove_and_repeated_rollback(self):
  a=self.install();self.assertEqual(a['installed'],'1');self.call('remove-adapter');old=self.state();self.call('remove-adapter');self.assertEqual(self.state(),old)
  self.assertEqual(self.call('rollback')['generation'],a['generation']);self.assertEqual(self.call('rollback')['installed'],'0')
 def test_transaction_success_and_failure_preserve_active_bytes(self):
  self.install();r=self.call('execute','install','demo');self.assertIn('Example utility',r['package']);old=self.state();active=self.active();blob=(active/'sandbox/packages/usr/bin/demo').read_bytes()
  self.env['FAKE_MODE']='fail';self.call('execute','install','other',error='OPKG_COMMAND_FAILED');self.assertEqual(self.state(),old);self.assertEqual((active/'sandbox/packages/usr/bin/demo').read_bytes(),blob)
 def test_unsupported_candidate_never_published(self):
  for mode,error in [('script','CUSTOM_MAINTAINER_SCRIPT'),('escape','RUNTIME_CHANGED'),('special','UNSAFE_SYMLINK')]:
   if not self.root.exists():self.install()
   old=self.state();self.env['FAKE_MODE']=mode;self.call('execute','install','demo',error=error);self.assertEqual(self.state(),old)
 def test_inventory_rejects_added_file_changed_mode_and_symlink(self):
  self.install();p=self.active()/'sandbox/bin/opkg';original=p.read_bytes();p.chmod(0o600);self.call('inspect',error='CHANGED_GENERATION');p.chmod(0o700)
  extra=p.parent/'extra';extra.write_bytes(b'extra');self.call('inspect',error='CHANGED_GENERATION');extra.unlink();p.unlink();p.symlink_to('other');self.call('inspect',error='CHANGED_GENERATION')
 def test_reinstall_rollback_keeps_runtime_pin_per_generation(self):
  first=self.install();self.call('remove-adapter');old=self.state();self.env['FAKE_MODE']='fail'
  r=subprocess.run(['/bin/sh',str(self.script),'install-adapter',CID,BOOT,*map(str,self.runtime('two'))],env=self.env,text=True,capture_output=True,timeout=60)
  self.assertNotEqual(r.returncode,0);self.assertEqual(self.state(),old);self.env.pop('FAKE_MODE')
  self.assertEqual(self.call('rollback')['generation'],first['generation']);self.call('execute','install','demo')
 def test_bad_signature_or_incomplete_update_exit_zero_never_publishes(self):
  self.install();old=self.state()
  self.python('chroot',"import pathlib,sys;s=pathlib.Path(sys.argv[1]);p=s/'packages/var/opkg-lists/official_base';p.unlink(missing_ok=True)")
  self.call('execute','update',error='FEED_INDEX_UNVERIFIED');self.assertEqual(self.state(),old)
 def test_read_query_uses_disposable_copy_even_on_interruption(self):
  self.install();old=self.state()
  self.python('chroot',"import pathlib,sys;s=pathlib.Path(sys.argv[1]);(s/'tmp/stale').write_text('temporary');sys.exit(2)")
  self.call('execute','list',error='OPKG_COMMAND_FAILED');self.assertEqual(self.state(),old);self.call('inspect')
 def save_feeds(self,text,expected=None,error=None,corrupt=False):
  stage=self.fs/'tmp'/('zte-opkg-'+str(uuid.uuid4()));stage.mkdir(mode=0o700)
  file=stage/'feeds.txt';file.write_text(text);file.chmod(0o600)
  generation=expected or self.active().name
  return self.call('save-feeds',stage,'0'*64 if corrupt else SHA(file.read_bytes()),generation,error=error)
 def test_load_and_save_feeds_are_private_no_network_and_rollbackable(self):
  self.install();before=self.active();seal=(before/'seal').read_bytes();old=(before/'sandbox/etc/opkg.conf').read_bytes()
  self.supervisor.unlink();loaded=self.call('read-feeds',capture=True);self.assertIn('release=23.05.4',loaded);self.assertIn('architecture=aarch64_cortex-a53',loaded);self.assertIn('key=b5043e70f9a75cde',loaded)
  self.supervisor.write_text('#!/bin/sh\nshift; exec "$@"\n');self.supervisor.chmod(0o700)
  chroot_log=(self.fs/'chroot.log').read_bytes();text='src/gz my_mirror https://example.org/openwrt/base\n'
  self.save_feeds('# comment\n\n'+text);self.assertEqual((self.fs/'chroot.log').read_bytes(),chroot_log)
  current=self.active();self.assertNotEqual(current,before);self.assertEqual((current/'sandbox/etc/opkg.conf').read_text(),BASE_CONFIG+text)
  self.assertEqual(list((current/'sandbox/packages/var/opkg-lists').iterdir()),[]);self.assertEqual((before/'seal').read_bytes(),seal)
  self.call('rollback');self.assertEqual((self.active()/'sandbox/etc/opkg.conf').read_bytes(),old);self.assertEqual(self.active(),before)
 def test_feeds_stale_hash_duplicate_injection_bad_url_and_noop(self):
  self.install();old=self.state();generation=self.active().name
  self.save_feeds(DEFAULT_FEEDS);self.assertEqual(self.state(),old)
  self.save_feeds('src/gz mirror https://example.org',expected='g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',error='FEEDS_STALE')
  self.save_feeds('src/gz mirror https://example.org',corrupt=True,error='FEEDS_HASH')
  for text in ['option check_signature 0','src/gz ../bad https://example.org','src/gz a file:///etc','src/gz a https://user:pass@example.org','src/gz a https://example.org;reboot','src/gz a https://example.org\nsrc/gz a https://other.org','src/gz a https://example.org:70000','src/gz a https://example.org/%xx']:
   self.save_feeds(text,error='FEEDS_FORMAT');self.assertEqual(self.state(),old)
 def test_dynamic_verifier_uses_only_current_feed_names(self):
  self.install();self.save_feeds('src/gz custom https://example.org/feed\n')
  # Simulate a successful update downloading only the custom signed feed.
  self.python('chroot',"import os,pathlib,sys;s=pathlib.Path(sys.argv[1]);p=s/'packages/var/opkg-lists';[(p/n).write_text('signed fixture') for n in ['custom','custom.sig']];[(p/n).chmod(0o600) for n in ['custom','custom.sig']];assert '/official_' not in ' '.join(sys.argv)")
  self.call('execute','update');self.assertEqual(sorted(p.name for p in (self.active()/'sandbox/packages/var/opkg-lists').iterdir()),['custom','custom.sig'])
 def test_untrusted_dynamic_feed_cannot_publish_update(self):
  self.install();self.save_feeds('src/gz custom http://[::1]:8080/feed\n');before=self.state()
  self.python('chroot',"import pathlib,sys;s=pathlib.Path(sys.argv[1]);p=s/'packages/var/opkg-lists';[(p/n).write_text('untrusted fixture') for n in ['custom','custom.sig']];[(p/n).chmod(0o600) for n in ['custom','custom.sig']];sys.exit(1 if sys.argv[2]=='/usr/sbin/opkg-key' else 0)")
  self.call('execute','update',error='FEED_SIGNATURE');self.assertEqual(self.state(),before)
 def test_empty_feeds_saved_but_update_requires_source(self):
  self.install();self.save_feeds('# all disabled\n');before=self.state();self.assertEqual((self.active()/'sandbox/etc/opkg.conf').read_text(),BASE_CONFIG)
  self.call('execute','update',error='NO_FEEDS');self.assertEqual(self.state(),before)
 def test_reboot_refuses_publication(self):
  self.install();old=self.state();self.env['FAKE_MODE']='reboot';self.call('execute','install','demo',error='DEVICE_CHANGED');self.assertEqual(self.state(),old)
 def test_flags_paths_system_packages_and_extra_args_refused(self):
  self.install();old=self.state()
  for args in [('install','--force-postinstall'),('install','/tmp/x.ipk'),('install','kmod-usb'),('files','demo','other')]:self.call('execute',*args,error='PACKAGE' if args[1].startswith(('--','/')) else 'UNSUPPORTED_PACKAGE' if args[1]=='kmod-usb' else 'ARGUMENTS')
  self.assertEqual(self.state(),old);self.call('execute','files','demo')
 def test_low_space_nested_mount_and_state_corruption_refuse(self):
  self.install();old=self.state();self.env['FAKE_FREE']='10';self.call('execute','install','demo',error='FREE_SPACE');self.assertEqual(self.state(),old)
  (self.root/'state').write_text('active=none\nprevious=none\n');self.call('inspect',error='STATE')
if __name__=='__main__':unittest.main()
