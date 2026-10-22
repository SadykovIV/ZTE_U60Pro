from pathlib import Path
import hashlib, os, subprocess, tempfile, unittest, uuid
SOURCE=Path(__file__).resolve().parents[1]/'Resources/VPN/upgrade-controller.sh'
sha=lambda b:hashlib.sha256(b).hexdigest()
NEW_RUNTIME=['ikev2.sh','ikev2-updown.sh','nft-ikev2-guard.nft']
RUNTIME=['manager.sh','firewall.sh','configure.lua','nft-guard.nft','dnsmasq.conf','service.sh']
class UpgradeTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='vpn-upgrade-');self.base=Path(self.temp.name)
  self.root=self.base/'data/zte-vpn';self.root.mkdir(parents=True,mode=0o700)
  self.stage=Path('/tmp')/('zte-vpn-agent-'+str(uuid.uuid4()));self.stage.mkdir(mode=0o700)
  self.network=self.base/'etc/init.d/network';self.network.parent.mkdir(parents=True)
  self.service=self.network.parent/'zte_vpn';self.rc=self.base/'etc/rc.d';self.rc.mkdir()
  self.bin=self.base/'bin';self.bin.mkdir()
  self.service_bytes=b'#!/bin/sh /etc/rc.common\nSTART=99\nSTOP=01\n'
  self.new_service_bytes=self.service_bytes+b'# changed service implementation\n'
  self.old_files={name:('old-'+name+'\n').encode() for name in RUNTIME}
  self.new_files={name:('new-'+name+'\n').encode() for name in RUNTIME+NEW_RUNTIME}
  self.old_files.update({'manager.sh':b'old\n','configure.lua':b'old-config\n','service.sh':self.service_bytes})
  self.new_files.update({'manager.sh':b'new\n','configure.lua':b'new-config\n','service.sh':self.new_service_bytes})
  def helper(files):
   return ('#!/bin/sh\n'+ ' &&\n'.join('test "$(sha256sum "$(dirname "$0")/'+name+'" | cut -d " " -f1)" = '+sha(files[name]) for name in files)+'\n').encode()
  self.old_helper=helper(self.old_files);self.new_helper=helper(self.new_files)
  self.old_sha=sha(self.old_helper);self.new_sha=sha(self.new_helper)
  for root,helper,files in [(self.root,self.old_helper,self.old_files),(self.stage,self.new_helper,self.new_files)]:
   (root/'vpnctl').write_bytes(helper);(root/'vpnctl').chmod(0o700)
   for name,contents in files.items():(root/name).write_bytes(contents)
  self.initial=f'#!/bin/sh\n# BEGIN zte-vpn-v1: test\n# {self.old_sha} {sha(b"old"+bytes([10]))}\n'.encode()
  self.network.write_bytes(self.initial);(self.root/'network-init.sha256').write_text(sha(self.initial))
  self.stock=b'#!/bin/sh\n# exact pinned stock network fixture\n'
  self.service.write_bytes(self.service_bytes)
  self.service.chmod(0o755)
  for name in ['S99zte_vpn','K01zte_vpn']:(self.rc/name).symlink_to('../init.d/zte_vpn')
  (self.root/'cid').write_text('a'*32+'\n');self.cid=self.base/'sys/block/mmcblk0/device/cid';self.cid.parent.mkdir(parents=True);self.cid.write_text('a'*32+'\n')
  (self.root/'configured').touch()
  script=SOURCE.read_text().replace('/data/zte-vpn',str(self.root)).replace('/etc/init.d/network',str(self.network)).replace('/etc/init.d/zte_vpn',str(self.service)).replace('/etc/rc.d',str(self.rc)).replace('/sys/block/mmcblk0/device/cid',str(self.cid)).replace('= 0:700',f'= {os.getuid()}:700')
  script=script.replace('80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23',self.old_sha)
  import re
  script=re.sub(r'(?m)^helper_sha=.*','helper_sha='+self.new_sha,script);script=re.sub(r'(?m)^manager_sha=.*','manager_sha='+sha(b'new\n'),script);script=re.sub(r'(?m)^configure_sha=.*','configure_sha='+sha(b'new-config\n'),script)
  for variable,name in [('firewall_sha','firewall.sh'),('nft_guard_sha','nft-guard.nft'),('dnsmasq_sha','dnsmasq.conf'),('service_sha','service.sh'),('ikev2_sha','ikev2.sh'),('ikev2_updown_sha','ikev2-updown.sh'),('nft_ikev2_sha','nft-ikev2-guard.nft')]:
   script=re.sub(r'(?m)^'+variable+'=.*',variable+'='+sha(self.new_files[name]),script)
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
  (self.root/'runtime-disabled').touch()
  result=self.run_upgrade();self.assertEqual(result.returncode,0,result.stderr.decode())
  self.assertEqual((self.root/'runtime-disabled').read_bytes(),b'')
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.new_helper)
  self.assertEqual((self.root/'configure.lua').read_text(),'new-config\n')
  for name,contents in self.new_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
  self.assertEqual(self.service.read_bytes(),self.new_service_bytes)
  self.assertIn(self.new_sha.encode(),self.network.read_bytes());self.assertNotIn(self.old_sha.encode(),self.network.read_bytes())
  self.assertFalse((self.root/'controller-upgrade').exists())
  self.assertEqual(self.run_upgrade().returncode,0)
 def test_unknown_controller_rejected_before_execution_or_replacement(self):
  marker=self.base/'executed'
  unknown=('#!/bin/sh\ntouch "'+str(marker)+'"\nexit 0\n').encode()
  (self.root/'vpnctl').write_bytes(unknown)
  result=self.run_upgrade()
  self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ERROR CONTROLLER_UNKNOWN',result.stderr)
  self.assertFalse(marker.exists());self.assertEqual((self.root/'vpnctl').read_bytes(),unknown)
  self.assertEqual(self.network.read_bytes(),self.initial);self.assertFalse((self.root/'controller-upgrade').exists())
 def test_symlinked_controller_rejected_without_touching_target(self):
  outside=self.base/'foreign-controller';outside.write_bytes(self.old_helper)
  (self.root/'vpnctl').unlink();(self.root/'vpnctl').symlink_to(outside)
  result=self.run_upgrade()
  self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ERROR CONTROLLER_UNKNOWN',result.stderr)
  self.assertEqual(outside.read_bytes(),self.old_helper);self.assertTrue((self.root/'vpnctl').is_symlink())
  self.assertEqual(self.network.read_bytes(),self.initial);self.assertFalse((self.root/'controller-upgrade').exists())
 def test_symlinked_root_refused_before_controller_execution(self):
  outside=self.base/'foreign-root';self.root.rename(outside);self.root.symlink_to(outside,target_is_directory=True)
  result=self.run_upgrade()
  self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ERROR UNSAFE_LAYOUT',result.stderr)
  self.assertEqual((outside/'vpnctl').read_bytes(),self.old_helper)
  self.assertFalse((outside/'controller-upgrade').exists());self.assertEqual(self.network.read_bytes(),self.initial)
 def test_failure_restores_controller_manager_and_boot_hook(self):
  self.command('mv','case "$1" in */vpnctl.new) exit 73;; esac\nexec /bin/mv "$@"\n')
  self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
  self.assertEqual((self.root/'manager.sh').read_text(),'old\n')
  self.assertEqual((self.root/'configure.lua').read_text(),'old-config\n')
  self.assertEqual(self.network.read_bytes(),self.initial)
  self.assertFalse((self.root/'controller-upgrade').exists())
 def test_failure_at_each_runtime_replace_restores_entire_set(self):
  for failed in RUNTIME+NEW_RUNTIME+['vpnctl']:
   with self.subTest(file=failed):
    self.command('mv','case "$1" in */'+failed+'.new) exit 73;; esac\nexec /bin/mv "$@"\n')
    result=self.run_upgrade();self.assertNotEqual(result.returncode,0,result.stderr.decode())
    self.assertIn(b'VPN_UPGRADE_ROLLBACK restored',result.stderr)
    self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
    for name,contents in self.old_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
    self.assertEqual(self.service.read_bytes(),self.service_bytes);self.assertEqual(self.network.read_bytes(),self.initial)
    self.assertFalse((self.root/'controller-upgrade').exists())
    for name in NEW_RUNTIME:self.assertFalse((self.root/name).exists(), name)
 def test_new_integrity_failure_restores_all_files_and_profiles(self):
  for name in ['active','config.json','wifi-settings.json','catalog.json']:(self.root/name).write_bytes(('private-fixture-'+name).encode())
  (self.root/'profiles').mkdir();(self.root/'profiles/profile.json').write_bytes(b'private-profile-fixture')
  helper=self.new_helper+b'exit 1\n';(self.stage/'vpnctl').write_bytes(helper)
  self.script.write_text(self.script.read_text().replace('helper_sha='+self.new_sha,'helper_sha='+sha(helper)))
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0)
  self.assertIn(b'VPN_UPGRADE_ERROR NEW_INTEGRITY',result.stderr);self.assertIn(b'VPN_UPGRADE_ROLLBACK restored',result.stderr)
  for name,contents in self.old_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper);self.assert_preserved_profiles()
 def test_all_runtime_payloads_are_verified_before_writes(self):
  for name in RUNTIME+NEW_RUNTIME+['vpnctl']:
   with self.subTest(file=name):
    original=(self.stage/name).read_bytes();(self.stage/name).write_bytes(b'corrupted')
    result=self.run_upgrade();self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ERROR PAYLOAD',result.stderr)
    self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper);self.assertFalse((self.root/'controller-upgrade').exists())
    (self.stage/name).write_bytes(original)
 def test_service_install_rollback_restores_previous_changed_service(self):
  (self.rc/'S99zte_vpn').unlink()
  self.command('ln','exit 73\n')
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ROLLBACK restored',result.stderr)
  self.assertEqual(self.service.read_bytes(),self.service_bytes)
  for name,contents in self.old_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
  self.assertFalse((self.rc/'S99zte_vpn').exists())
 def test_service_install_rollback_restores_original_absence(self):
  self.service.unlink();(self.rc/'S99zte_vpn').unlink();(self.rc/'K01zte_vpn').unlink()
  self.command('ln','exit 73\n')
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ROLLBACK restored',result.stderr)
  self.assertFalse(self.service.exists())
  for name,contents in self.old_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
 def pending_snapshot(self,full):
  import shutil
  backup=self.root/'controller-upgrade';backup.mkdir(mode=0o700);(backup/'planned').mkdir(mode=0o700)
  names=RUNTIME+['vpnctl'] if full else ['manager.sh','configure.lua','vpnctl']
  for name in names:
   shutil.copy2(self.root/name,backup/name)
   (backup/'planned'/name).write_text(sha((self.stage/name).read_bytes()))
   shutil.copy2(self.stage/name,self.root/name)
  shutil.copy2(self.network,backup/'network');shutil.copy2(self.service,backup/'service');shutil.copy2(self.root/'network-init.sha256',backup/'network-init.sha256')
  (backup/'planned/network').write_text(sha(self.network.read_bytes()));(backup/'planned/service').write_text(sha(self.new_service_bytes if full else self.service_bytes))
  for name in ['S99zte_vpn','K01zte_vpn']:(backup/('link-'+name)).touch()
  (backup/'service-v1').touch();(backup/'ready').touch()
  hash_names=names+['network','service','network-init.sha256']
  if full:(backup/'runtime-v2').write_text('2\n');hash_names.append('runtime-v2')
  (backup/'SHA256SUMS').write_text(''.join(sha((backup/name).read_bytes())+'  '+name+'\n' for name in hash_names))
 def test_interrupted_legacy_three_file_snapshot_is_recovered(self):
  self.pending_snapshot(full=False)
  result=self.run_upgrade();self.assertEqual(result.returncode,0,result.stderr.decode())
  for name,contents in self.new_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
  self.assertFalse((self.root/'controller-upgrade').exists())
 def test_interrupted_full_runtime_snapshot_is_recovered(self):
  self.pending_snapshot(full=True)
  result=self.run_upgrade();self.assertEqual(result.returncode,0,result.stderr.decode())
  for name,contents in self.new_files.items():self.assertEqual((self.root/name).read_bytes(),contents)
  self.assertFalse((self.root/'controller-upgrade').exists())
 def test_rollback_does_not_overwrite_foreign_firewall_change(self):
  self.command('mv',f'case "$1" in */vpnctl.new) printf foreign > "{self.root}/firewall.sh"; exit 73;; esac\nexec /bin/mv "$@"\n')
  result=self.run_upgrade();self.assertNotEqual(result.returncode,0);self.assertIn(b'VPN_UPGRADE_ERROR ROLLBACK_UNKNOWN',result.stderr)
  self.assertEqual((self.root/'firewall.sh').read_bytes(),b'foreign');self.assertTrue((self.root/'controller-upgrade/ready').exists())
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
  for name in ['backup','backup-deltas','uci','ipa-backup','ipa-restored','ipa-uci']:
   (self.root/name).mkdir(mode=0o700);(self.root/name/'kept').write_bytes(('original-'+name).encode())
  (self.root/'ipa-runtime').write_text('boot pid')
  (self.root/'runtime-disabled').touch()
  for name in ['active','config.json','wifi-settings.json','catalog.json']:(self.root/name).write_bytes(('private-fixture-'+name).encode())
  (self.root/'profiles').mkdir();(self.root/'profiles'/'profile.json').write_bytes(b'private-profile-fixture')
  if current:
   (self.root/'vpnctl').write_bytes(self.new_helper)
   for name,contents in self.new_files.items():(self.root/name).write_bytes(contents)
 def assert_preserved_profiles(self):
  for name in ['active','config.json','wifi-settings.json','catalog.json']:self.assertEqual((self.root/name).read_bytes(),('private-fixture-'+name).encode())
  self.assertEqual((self.root/'profiles/profile.json').read_bytes(),b'private-profile-fixture')
 def test_exact_stock_reset_archives_stale_configuration_and_repairs_service(self):
  self.reset_state();result=self.run_upgrade();self.assertEqual(result.returncode,0,result.stderr.decode())
  self.assertEqual(self.network.read_bytes(),self.stock)
  archives=list(self.root.glob('controller-reset-*'));self.assertEqual(len(archives),1)
  for name in ['configured','network-init.sha256','backup','backup-deltas','uci','ipa-backup','ipa-restored','ipa-uci','ipa-runtime','runtime-disabled']:
   self.assertFalse((self.root/name).exists());self.assertTrue((archives[0]/'reset-state'/name).exists())
  self.assertEqual(self.service.read_bytes(),self.new_service_bytes)
  for name in ['S99zte_vpn','K01zte_vpn']:self.assertEqual(os.readlink(self.rc/name),'../init.d/zte_vpn')
  self.assert_preserved_profiles()
 def test_current_controller_still_reconciles_reset_and_idempotent_second_run(self):
  self.reset_state(current=True);self.assertEqual(self.run_upgrade().returncode,0)
  self.assertFalse((self.root/'configured').exists());self.assertTrue(self.service.exists());self.assert_preserved_profiles()
  self.assertEqual(self.run_upgrade().returncode,0);self.assertEqual(len(list(self.root.glob('controller-reset-*'))),1)
 def test_missing_service_without_reset_is_repaired_without_reconfiguration(self):
  self.service.unlink();(self.rc/'S99zte_vpn').unlink()
  self.assertEqual(self.run_upgrade().returncode,0)
  self.assertTrue((self.root/'configured').exists());self.assertEqual(self.service.read_bytes(),self.new_service_bytes)
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
  for name in ['configured','network-init.sha256','backup','backup-deltas','uci','ipa-backup','ipa-restored','ipa-uci','ipa-runtime','runtime-disabled']:self.assertTrue((self.root/name).exists())
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
