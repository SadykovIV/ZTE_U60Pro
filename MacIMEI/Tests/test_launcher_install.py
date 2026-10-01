"""Exercise the real installer with isolated files and simulated OpenWrt services."""
from pathlib import Path
import hashlib, os, re, shutil, subprocess, tempfile, unittest, uuid
SRC=Path(__file__).resolve().parents[1]/'Resources/VPN'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
class LauncherInstallTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='launcher-install-');self.base=Path(self.tmp.name)
  self.data=self.base/'data';self.data.mkdir(mode=0o700)
  self.etc=self.base/'etc';(self.etc/'init.d').mkdir(parents=True)
  self.stage=Path('/tmp')/('zte-vpn-agent-'+str(uuid.uuid4()));self.stage.mkdir(mode=0o700)
  self.lock=self.base/'lock';self.lock.mkdir();(self.lock/'owner').write_text('test')
  self.cid=self.base/'cid';self.cid.write_text('test-device\n')
  self.firmware=self.base/'firmware';self.firmware.write_bytes(b'firmware fixture')
  self.rc=self.etc/'rc.local';self.rc.write_text('#!/bin/sh\n# existing services\nexit 0\n');self.before=self.rc.read_bytes();self.rc.chmod(0o755)
  self.stock=self.etc/'init.d/zte_topsw_devui';self.stock.write_text('#!/bin/sh\nexit 0\n');self.stock.chmod(0o755)
  self.root=self.data/'zte-launcher';self.transaction=self.data/'zte-launcher-update'
  self.bin=self.base/'bin';self.bin.mkdir()
  self.command('stat',f'''case "$2" in
 %u) echo {os.getuid()};; %a) /usr/bin/stat -f %Lp "$3";; %u:%a) printf '{os.getuid()}:';/usr/bin/stat -f %Lp "$3";; %u:%a:%h) printf '{os.getuid()}:';/usr/bin/stat -f %Lp:%l "$3";; *) exit 1;; esac\n''')
  self.command('sha256sum','exec /usr/bin/shasum -a 256 "$@"\n')
  self.command('sync',':\n')
  self.command('sh','''case "$1" in */launcher-start.sh) [ "${FAIL_START:-0}" = 0 ];exit $?;; *) exec /bin/sh "$@";; esac\n''')
  for name in ['launcher.so','launcher-run.sh','launcher-watch.sh','launcher-service.sh','launcher-start.sh','launcher.sha256']:
   shutil.copyfile(SRC/name,self.stage/name)
  script=(SRC/'install-launcher.sh').read_text()
  for old,new in [('/data',str(self.data)),('/etc',str(self.etc)),('/sys/block/mmcblk0/device/cid',str(self.cid)),('/firmware/image/modem.b16',str(self.firmware)),('/tmp/zte-imei-app.lock',str(self.lock)),('/tmp/zte-launcher-trial/supervisor',str(self.base/'trial')),('/tmp/zte-vpn-screen',str(self.base/'screen'))]:script=script.replace(old,new)
  script=script.replace('= 0:700',f'= {os.getuid()}:700').replace('= 0:600',f'= {os.getuid()}:600').replace('stat -c %u \"$dir\")\" = 0',f'stat -c %u \"$dir\")\" = {os.getuid()}').replace('stat -c %u '+str(self.rc)+')\" = 0',f'stat -c %u {self.rc})\" = {os.getuid()}')
  script=script.replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263',sha(self.firmware)).replace('a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35',sha(self.stock))
  # Service command execution is stubbed, its installed bytes still match the signed payload.
  script=script.replace(str(self.etc)+'/init.d/zte_launcher stop', 'true')
  self.script=self.base/'install.sh';self.script.write_text(script)
 def command(self,name,body):
  p=self.bin/name;p.write_text('#!/bin/sh\n'+body);p.chmod(0o700)
 def run_install(self,mode=None,**env):
  return subprocess.run(['/bin/sh',str(self.script),str(self.stage)]+([mode] if mode else []),env={**os.environ,'PATH':str(self.bin)+':/usr/bin:/bin',**env},capture_output=True,timeout=15)
 def tearDown(self):shutil.rmtree(self.stage);self.tmp.cleanup()
 def assert_success(self,result):self.assertEqual(result.returncode,0,result.stderr.decode())
 def tree(self):
  return {str(p.relative_to(self.base)):(p.read_bytes(),p.stat().st_mode) for p in self.base.rglob('*') if p.is_file()}
 def test_preflight_is_read_only_for_first_and_existing_install(self):
  before=self.tree();r=self.run_install('preflight');self.assert_success(r)
  self.assertEqual(r.stdout.strip(),b'LAUNCHER_PREFLIGHT_OK');self.assertEqual(self.tree(),before)
  self.assert_success(self.run_install());layout=self.root/'info-layout.conf';layout.write_text('existing layout');layout.chmod(0o600)
  before=self.tree();self.assert_success(self.run_install('preflight'));self.assertEqual(self.tree(),before)
 def test_preflight_never_recovers_pending_transaction(self):
  self.transaction.mkdir(mode=0o700);(self.transaction/'owner').write_text('zte-launcher-update-v1\n');(self.transaction/'cid').write_bytes(self.cid.read_bytes())
  before=self.tree();self.assertNotEqual(self.run_install('preflight').returncode,0);self.assertEqual(self.tree(),before);self.assertTrue(self.transaction.exists())
 def test_unknown_mode_is_read_only(self):
  before=self.tree();self.assertNotEqual(self.run_install('typo').returncode,0);self.assertEqual(self.tree(),before)
 def test_first_install_and_repeat_preserve_original_service_and_rc(self):
  stock=self.stock.read_bytes();self.assert_success(self.run_install());self.assert_success(self.run_install())
  self.assertEqual(self.stock.read_bytes(),stock)
  self.assertEqual(self.rc.read_text().count('/launcher-start.sh'),1)
  self.assertEqual((self.root/'rc.local.backup').read_bytes(),self.before)
  self.assertFalse(self.transaction.exists())
 def test_failed_first_install_restores_rc_and_removes_component(self):
  self.assertNotEqual(self.run_install(FAIL_START='1').returncode,0)
  self.assertEqual(self.rc.read_bytes(),self.before);self.assertFalse(self.root.exists());self.assertFalse((self.etc/'init.d/zte_launcher').exists())
 def test_failed_upgrade_restores_previous_installation(self):
  self.assert_success(self.run_install());before=self.rc.read_bytes();(self.root/'sentinel').write_text('old installation')
  self.assertNotEqual(self.run_install(FAIL_START='1').returncode,0)
  self.assertEqual((self.root/'sentinel').read_text(),'old installation');self.assertEqual(self.rc.read_bytes(),before)
 def test_interrupted_directory_swap_recovers_on_retry(self):
  self.assert_success(self.run_install())
  self.command('mv',f'''if [ "$2" = "{self.transaction}/old" ] && [ ! -f "{self.base}/killed" ]; then
 /bin/mv "$@";touch "{self.base}/killed";kill -KILL "$PPID";exit 1;fi
exec /bin/mv "$@"\n''')
  self.assertNotEqual(self.run_install().returncode,0)
  self.assertTrue((self.transaction/'old').exists())
  self.assert_success(self.run_install());self.assertFalse(self.transaction.exists());self.assertTrue((self.root/'enabled').exists())
 def test_corrupt_payload_rejected_before_any_changes(self):
  (self.stage/'launcher.so').write_bytes(b'bad')
  self.assertNotEqual(self.run_install().returncode,0)
  self.assertEqual(self.rc.read_bytes(),self.before);self.assertFalse(self.root.exists())
 def test_layout_preserved_by_upgrade_and_rollback(self):
  self.assert_success(self.run_install())
  layout=self.root/'info-layout.conf';content=b'ZTE_INFO_LAYOUT_V1\nsignal=1\ncpu=0\nnetwork=1\ncarriers=1\ncpu_temp=0\nmodem_temp=1\nmemory=0\nstorage=0\nuptime=1\n'
  layout.write_bytes(content);layout.chmod(0o600)
  self.assert_success(self.run_install());self.assertEqual(layout.read_bytes(),content)
  self.assertNotEqual(self.run_install(FAIL_START='1').returncode,0)
  self.assertEqual(layout.read_bytes(),content);self.assertEqual(layout.stat().st_mode & 0o777,0o600)
 def test_v2_tile_style_and_new_metrics_survive_upgrade_and_rollback(self):
  self.assert_success(self.run_install())
  layout=self.root/'info-layout.conf'
  content=b'ZTE_INFO_LAYOUT_V2\nstyle=tiles\nbattery=1\nsinr=1\nrsrq=1\nsignal=1\ncpu=0\nnetwork=1\ncarriers=1\ncpu_temp=0\nmodem_temp=1\nmemory=0\nstorage=0\nuptime=1\n'
  layout.write_bytes(content);layout.chmod(0o600)
  self.assert_success(self.run_install());self.assertEqual(layout.read_bytes(),content)
  self.assertNotEqual(self.run_install(FAIL_START='1').returncode,0)
  self.assertEqual(layout.read_bytes(),content);self.assertEqual(layout.stat().st_mode & 0o777,0o600)
 def test_unsafe_layout_rejected_before_swap(self):
  self.assert_success(self.run_install());layout=self.root/'info-layout.conf'
  outside=self.base/'outside';outside.write_text('outside');layout.symlink_to(outside)
  self.assertNotEqual(self.run_install().returncode,0);self.assertTrue(layout.is_symlink())
  self.assertEqual(outside.read_text(),'outside');self.assertFalse(self.transaction.exists())
  layout.unlink();layout.write_bytes(b'x'*513);layout.chmod(0o600)
  self.assertNotEqual(self.run_install().returncode,0);self.assertFalse(self.transaction.exists())
  layout.write_text('invalid but private');layout.chmod(0o644)
  self.assertNotEqual(self.run_install().returncode,0);self.assertFalse(self.transaction.exists())
  layout.chmod(0o600);self.assert_success(self.run_install())
  self.assertEqual(layout.read_text(),'invalid but private')
  os.link(layout,self.base/'hardlink')
  self.assertNotEqual(self.run_install().returncode,0);self.assertFalse(self.transaction.exists())
if __name__=='__main__':unittest.main()
