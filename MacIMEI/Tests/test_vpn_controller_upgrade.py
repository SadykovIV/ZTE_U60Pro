from pathlib import Path
import hashlib, os, subprocess, tempfile, unittest, uuid
SOURCE=Path(__file__).resolve().parents[1]/'Resources/VPN/upgrade-controller.sh'
sha=lambda b:hashlib.sha256(b).hexdigest()
class UpgradeTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='vpn-upgrade-');self.base=Path(self.temp.name)
  self.root=self.base/'data/zte-vpn';self.root.mkdir(parents=True,mode=0o700)
  self.stage=Path('/tmp')/('zte-vpn-agent-'+str(uuid.uuid4()));self.stage.mkdir(mode=0o700)
  self.network=self.base/'etc/init.d/network';self.network.parent.mkdir(parents=True)
  self.service=self.network.parent/'zte_vpn';self.rc=self.base/'etc/rc.d';self.rc.mkdir()
  self.bin=self.base/'bin';self.bin.mkdir()
  self.old_helper=b'#!/bin/sh\ntest "$(cat "$(dirname "$0")/manager.sh")" = old && test "$(cat "$(dirname "$0")/configure.lua")" = old-config\n'
  self.new_helper=b'#!/bin/sh\ntest "$(cat "$(dirname "$0")/manager.sh")" = new && test "$(cat "$(dirname "$0")/configure.lua")" = new-config\n'
  self.old_sha=sha(self.old_helper);self.new_sha=sha(self.new_helper)
  for root,helper,manager in [(self.root,self.old_helper,b'old\n'),(self.stage,self.new_helper,b'new\n')]:
   (root/'vpnctl').write_bytes(helper);(root/'vpnctl').chmod(0o700);(root/'manager.sh').write_bytes(manager);(root/'configure.lua').write_bytes(b'old-config\n' if root==self.root else b'new-config\n')
  self.initial=f'#!/bin/sh\n# BEGIN zte-vpn-v1: test\n# {self.old_sha} {sha(b"old"+bytes([10]))}\n'.encode()
  self.network.write_bytes(self.initial);(self.root/'network-init.sha256').write_text(sha(self.initial))
  self.stock=b'#!/bin/sh\n# exact pinned stock network fixture\n'
  self.service_bytes=b'#!/bin/sh /etc/rc.common\nSTART=99\nSTOP=01\n'
  (self.root/'service.sh').write_bytes(self.service_bytes);self.service.write_bytes(self.service_bytes)
  self.service.chmod(0o755)
  for name in ['S99zte_vpn','K01zte_vpn']:(self.rc/name).symlink_to('../init.d/zte_vpn')
  (self.root/'cid').write_text('a'*32+'\n');self.cid=self.base/'sys/block/mmcblk0/device/cid';self.cid.parent.mkdir(parents=True);self.cid.write_text('a'*32+'\n')
  (self.root/'configured').touch()
  script=SOURCE.read_text().replace('/data/zte-vpn',str(self.root)).replace('/etc/init.d/network',str(self.network)).replace('/etc/init.d/zte_vpn',str(self.service)).replace('/etc/rc.d',str(self.rc)).replace('/sys/block/mmcblk0/device/cid',str(self.cid)).replace('= 0:700',f'= {os.getuid()}:700')
  script=script.replace('80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23',self.old_sha)
  import re
  script=re.sub(r'(?m)^helper_sha=.*','helper_sha='+self.new_sha,script);script=re.sub(r'(?m)^manager_sha=.*','manager_sha='+sha(b'new\n'),script);script=re.sub(r'(?m)^configure_sha=.*','configure_sha='+sha(b'new-config\n'),script)
  script=re.sub(r'(?m)^network_stock_sha=.*','network_stock_sha='+sha(self.stock),script)
  self.script=self.base/'upgrade.sh';self.script.write_text(script)
  self.command('sha256sum','exec /usr/bin/shasum -a 256 "$@"\n')
  self.command('stat',f'''case "$2" in
 %u:%a) printf "{os.getuid()}:700\\n";;
 %u:%h) printf '0:1\\n';;
 %u) printf '0\\n';;
 %a) /usr/bin/stat -f '%Lp' "$3";;
 *) exit 89;; esac
''')
  self.command('sync',':\n')
 def tearDown(self):
  import shutil
  shutil.rmtree(self.stage);self.temp.cleanup()
 def command(self,name,body):
  p=self.bin/name;p.write_text('#!/bin/sh\n'+body);p.chmod(0o700)
 def run_upgrade(self):
  return subprocess.run(['sh',str(self.script),str(self.stage)],env={**os.environ,'PATH':str(self.bin)+':/usr/bin:/bin'},capture_output=True,timeout=15)
 def test_complete_upgrade_changes_controller_and_boot_pins_together(self):
  result=self.run_upgrade();self.assertEqual(result.returncode,0,result.stderr.decode())
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.new_helper)
  self.assertEqual((self.root/'configure.lua').read_text(),'new-config\n')
  self.assertIn(self.new_sha.encode(),self.network.read_bytes());self.assertNotIn(self.old_sha.encode(),self.network.read_bytes())
  self.assertFalse((self.root/'controller-upgrade').exists())
  self.assertEqual(self.run_upgrade().returncode,0)
 def test_failure_restores_controller_manager_and_boot_hook(self):
  self.command('mv','case "$1" in */vpnctl.new) exit 73;; esac\nexec /bin/mv "$@"\n')
  self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
  self.assertEqual((self.root/'manager.sh').read_text(),'old\n')
  self.assertEqual((self.root/'configure.lua').read_text(),'old-config\n')
  self.assertEqual(self.network.read_bytes(),self.initial)
  self.assertFalse((self.root/'controller-upgrade').exists())
 def test_corrupt_configure_script_rejected_before_any_replacement(self):
  (self.stage/'configure.lua').write_text('unexpected')
  self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
  self.assertEqual((self.root/'configure.lua').read_text(),'old-config\n')
  self.assertFalse((self.root/'controller-upgrade').exists())
 def test_foreign_network_changes_rejected_before_mutation(self):
  self.network.write_bytes(self.initial+b'# foreign\n')
  self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
  self.assertFalse((self.root/'controller-upgrade').exists())
 def reset_state(self,current=False):
  self.network.write_bytes(self.stock);self.service.unlink()
  for name in ['S99zte_vpn','K01zte_vpn']:(self.rc/name).unlink()
  for name in ['backup','backup-deltas','uci']:
   (self.root/name).mkdir(mode=0o700);(self.root/name/'kept').write_bytes(('original-'+name).encode())
  for name in ['active','config.json','wifi-settings.json']:(self.root/name).write_bytes(('private-fixture-'+name).encode())
  (self.root/'profiles').mkdir();(self.root/'profiles'/'profile.json').write_bytes(b'private-profile-fixture')
  if current:
   (self.root/'vpnctl').write_bytes(self.new_helper);(self.root/'manager.sh').write_bytes(b'new\n');(self.root/'configure.lua').write_bytes(b'new-config\n')
 def assert_preserved_profiles(self):
  for name in ['active','config.json','wifi-settings.json']:self.assertEqual((self.root/name).read_bytes(),('private-fixture-'+name).encode())
  self.assertEqual((self.root/'profiles/profile.json').read_bytes(),b'private-profile-fixture')
 def test_exact_stock_reset_archives_stale_configuration_and_repairs_service(self):
  self.reset_state();result=self.run_upgrade();self.assertEqual(result.returncode,0,result.stderr.decode())
  self.assertEqual(self.network.read_bytes(),self.stock)
  archives=list(self.root.glob('controller-reset-*'));self.assertEqual(len(archives),1)
  for name in ['configured','network-init.sha256','backup','backup-deltas','uci']:
   self.assertFalse((self.root/name).exists());self.assertTrue((archives[0]/'reset-state'/name).exists())
  self.assertEqual(self.service.read_bytes(),self.service_bytes)
  for name in ['S99zte_vpn','K01zte_vpn']:self.assertEqual(os.readlink(self.rc/name),'../init.d/zte_vpn')
  self.assert_preserved_profiles()
 def test_current_controller_still_reconciles_reset_and_idempotent_second_run(self):
  self.reset_state(current=True);self.assertEqual(self.run_upgrade().returncode,0)
  self.assertFalse((self.root/'configured').exists());self.assertTrue(self.service.exists());self.assert_preserved_profiles()
  self.assertEqual(self.run_upgrade().returncode,0);self.assertEqual(len(list(self.root.glob('controller-reset-*'))),1)
 def test_missing_service_without_reset_is_repaired_without_reconfiguration(self):
  self.service.unlink();(self.rc/'S99zte_vpn').unlink()
  self.assertEqual(self.run_upgrade().returncode,0)
  self.assertTrue((self.root/'configured').exists());self.assertEqual(self.service.read_bytes(),self.service_bytes)
  self.assertTrue((self.rc/'S99zte_vpn').is_symlink())
 def test_unknown_service_and_startup_links_refused_before_writes(self):
  for kind in ['service','link']:
   with self.subTest(kind=kind):
    if kind=='service':self.service.write_bytes(b'foreign')
    else:
     self.service.write_bytes(self.service_bytes);(self.rc/'S99zte_vpn').unlink();(self.rc/'S99zte_vpn').symlink_to('../init.d/foreign')
    result=self.run_upgrade();self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ERROR',result.stderr)
    self.assertFalse((self.root/'controller-upgrade').exists());self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
 def test_reset_failure_restores_absence_stale_state_and_profiles(self):
  self.reset_state()
  self.command('mv','case "$1" in */zte_vpn.vpn-new) exit 73;; esac\nexec /bin/mv "$@"\n')
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0)
  self.assertFalse(self.service.exists());self.assertFalse((self.rc/'S99zte_vpn').exists())
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper);self.assertEqual(self.network.read_bytes(),self.stock)
  for name in ['configured','network-init.sha256','backup','backup-deltas','uci']:self.assertTrue((self.root/name).exists())
  self.assert_preserved_profiles();self.assertFalse((self.root/'controller-upgrade').exists())
 def test_reset_changed_cid_refuses_without_writes(self):
  self.reset_state();self.cid.write_text('b'*32+'\n');self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertTrue((self.root/'configured').exists());self.assertFalse(list(self.root.glob('controller-reset-*')))
 def test_reset_rejects_symlinked_state_without_touching_target(self):
  self.reset_state();(self.root/'configured').unlink();outside=self.base/'foreign';outside.write_bytes(b'untouched');(self.root/'configured').symlink_to(outside)
  self.assertNotEqual(self.run_upgrade().returncode,0);self.assertEqual(outside.read_bytes(),b'untouched')
 def test_rollback_does_not_overwrite_foreign_network_change(self):
  self.reset_state()
  self.command('mv',f'case "$1" in */zte_vpn.vpn-new) printf foreign > "{self.network}"; exit 73;; esac\nexec /bin/mv "$@"\n')
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0)
  self.assertIn(b'VPN_UPGRADE_ERROR ROLLBACK_UNKNOWN',result.stderr)
  self.assertEqual(self.network.read_bytes(),b'foreign');self.assertTrue((self.root/'controller-upgrade/ready').exists())
  self.assert_preserved_profiles()
 def test_old_integrity_fixed_cause_is_reported_without_arbitrary_output(self):
  self.old_helper=b'#!/bin/sh\nprintf \'{"code":"VPN_CORE_INTEGRITY","ok":false}\\n\'; exit 1\n'
  old_sha=sha(self.old_helper);(self.root/'vpnctl').write_bytes(self.old_helper)
  self.script.write_text(self.script.read_text().replace(self.old_sha,old_sha))
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0)
  self.assertIn(b'VPN_UPGRADE_ERROR OLD_INTEGRITY',result.stderr);self.assertIn(b'VPN_UPGRADE_CAUSE VPN_CORE_INTEGRITY',result.stderr)
  self.assertFalse((self.root/'controller-upgrade').exists())
if __name__=='__main__':unittest.main()
