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
  self.bin=self.base/'bin';self.bin.mkdir()
  self.old_helper=b'#!/bin/sh\ntest "$(cat "$(dirname "$0")/manager.sh")" = old\n'
  self.new_helper=b'#!/bin/sh\ntest "$(cat "$(dirname "$0")/manager.sh")" = new\n'
  self.old_sha=sha(self.old_helper);self.new_sha=sha(self.new_helper)
  for root,helper,manager in [(self.root,self.old_helper,b'old\n'),(self.stage,self.new_helper,b'new\n')]:
   (root/'vpnctl').write_bytes(helper);(root/'vpnctl').chmod(0o700);(root/'manager.sh').write_bytes(manager);(root/'configure.lua').write_bytes(manager)
  self.initial=f'#!/bin/sh\n# BEGIN zte-vpn-v1: test\n# {self.old_sha} {sha(b"old"+bytes([10]))}\n'.encode()
  self.network.write_bytes(self.initial);(self.root/'network-init.sha256').write_text(sha(self.initial))
  (self.root/'configured').touch()
  script=SOURCE.read_text().replace('/data/zte-vpn',str(self.root)).replace('/etc/init.d/network',str(self.network)).replace('= 0:700',f'= {os.getuid()}:700')
  script=script.replace('80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23',self.old_sha)
  import re
  script=re.sub(r'(?m)^helper_sha=.*','helper_sha='+self.new_sha,script);script=re.sub(r'(?m)^manager_sha=.*','manager_sha='+sha(b'new\n'),script)
  script=re.sub(r'(?m)^configure_sha=.*','configure_sha='+sha(b'new\n'),script)
  self.script=self.base/'upgrade.sh';self.script.write_text(script)
  self.command('sha256sum','exec /usr/bin/shasum -a 256 "$@"\n')
  self.command('stat',f'printf "{os.getuid()}:700\\n"\n')
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
  self.assertEqual((self.root/'configure.lua').read_text(),'new\n')
  self.assertIn(self.new_sha.encode(),self.network.read_bytes());self.assertNotIn(self.old_sha.encode(),self.network.read_bytes())
  self.assertFalse((self.root/'controller-upgrade').exists())
  self.assertEqual(self.run_upgrade().returncode,0)
 def test_failure_restores_controller_manager_and_boot_hook(self):
  self.command('mv','case "$1" in */vpnctl.new) exit 73;; esac\nexec /bin/mv "$@"\n')
  self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
  self.assertEqual((self.root/'manager.sh').read_text(),'old\n')
  self.assertEqual((self.root/'configure.lua').read_text(),'old\n')
  self.assertEqual(self.network.read_bytes(),self.initial)
  self.assertFalse((self.root/'controller-upgrade').exists())
 def test_foreign_network_changes_rejected_before_mutation(self):
  self.network.write_bytes(self.initial+b'# foreign\n')
  self.assertNotEqual(self.run_upgrade().returncode,0)
  self.assertEqual((self.root/'vpnctl').read_bytes(),self.old_helper)
  self.assertFalse((self.root/'controller-upgrade').exists())
if __name__=='__main__':unittest.main()
