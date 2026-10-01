"""Run source installer with the existing isolated OpenWrt fixture; no device."""
from pathlib import Path
import importlib.util, os, shutil, tempfile, unittest
ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('launcher_fixture',ROOT/'MacIMEI/Tests/test_launcher_install.py')
legacy=importlib.util.module_from_spec(spec);spec.loader.exec_module(legacy)
HEADER=b'ZTE_LAUNCHER_PAGES_V1\n'

class PageLayoutInstallerTests(legacy.LauncherInstallTests):
 def setUp(self):
  self.payload=tempfile.TemporaryDirectory(prefix='launcher-page-payload-')
  self.saved_source=legacy.SRC;target=Path(self.payload.name)
  for name in ['launcher.so','launcher-run.sh','launcher-watch.sh','launcher-service.sh','launcher-start.sh','launcher.sha256']:
   shutil.copyfile(self.saved_source/name,target/name)
  shutil.copyfile(ROOT/'ModemAgent/launcher/scripts/install-launcher.sh',target/'install-launcher.sh')
  legacy.SRC=target
  try:super().setUp()
  finally:legacy.SRC=self.saved_source
 def tearDown(self):
  try:super().tearDown()
  finally:self.payload.cleanup()
 def config(self,path,data):path.write_bytes(data);path.chmod(0o600)
 def test_page_order_preserved_upgrade_and_rollback(self):
  self.assert_success(self.run_install());p=self.root/'page-layout.conf';old=HEADER+b'esim\ninfo\n';self.config(p,old)
  self.assert_success(self.run_install());self.assertEqual(p.read_bytes(),old)
  self.assertNotEqual(self.run_install(FAIL_START='1').returncode,0);self.assertEqual(p.read_bytes(),old)
 def test_staged_selection_replaces_atomically_and_rolls_back(self):
  self.assert_success(self.run_install());p=self.root/'page-layout.conf';old=HEADER+b'vpn\n';self.config(p,old)
  desired=HEADER+b'esim\ninfo\n';self.config(self.stage/'page-layout.conf',desired)
  before=self.tree();self.assert_success(self.run_install('preflight'));self.assertEqual(self.tree(),before)
  self.assertNotEqual(self.run_install(FAIL_START='1').returncode,0);self.assertEqual(p.read_bytes(),old)
  self.assert_success(self.run_install());self.assertEqual(p.read_bytes(),desired);self.assertEqual(p.stat().st_mode&0o777,0o600)
 def test_header_only_disables_all_extra_pages(self):
  self.config(self.stage/'page-layout.conf',HEADER);self.assert_success(self.run_install());self.assertEqual((self.root/'page-layout.conf').read_bytes(),HEADER)
 def test_malformed_or_unsafe_existing_config_refuses_without_changes(self):
  self.assert_success(self.run_install());p=self.root/'page-layout.conf'
  for bad in [b'',HEADER+b'info',HEADER+b'info\ninfo\n',HEADER+b'vpn\n\n',HEADER+b'esim\0\n',b'x'*129]:
   with self.subTest(bad=bad):
    self.config(p,bad);before=self.tree()
    for mode in ['preflight','apply']:self.assertNotEqual(self.run_install(mode).returncode,0);self.assertEqual(self.tree(),before)
  self.config(p,HEADER);p.chmod(0o644);before=self.tree();self.assertNotEqual(self.run_install().returncode,0);self.assertEqual(self.tree(),before)
  p.chmod(0o600);os.link(p,self.base/'page-hardlink');before=self.tree();self.assertNotEqual(self.run_install().returncode,0);self.assertEqual(self.tree(),before)
 def test_invalid_stage_does_not_recover_or_touch_existing_transaction(self):
  self.config(self.stage/'page-layout.conf',HEADER+b'unknown\n')
  self.transaction.mkdir(mode=0o700);(self.transaction/'owner').write_text('zte-launcher-update-v1\n');(self.transaction/'cid').write_bytes(self.cid.read_bytes())
  before=self.tree();self.assertNotEqual(self.run_install().returncode,0);self.assertEqual(self.tree(),before);self.assertTrue(self.transaction.exists())
 def test_old_layout_validated_before_recovery(self):
  self.assert_success(self.run_install());self.transaction.mkdir(mode=0o700);(self.transaction/'owner').write_text('zte-launcher-update-v1\n');(self.transaction/'cid').write_bytes(self.cid.read_bytes())
  self.root.rename(self.transaction/'old');self.config(self.transaction/'old/page-layout.conf',HEADER+b'info\ninfo\n')
  before=self.tree();self.assertNotEqual(self.run_install().returncode,0);self.assertEqual(self.tree(),before);self.assertTrue((self.transaction/'old').exists())
 def test_missing_config_remains_missing(self):
  self.assert_success(self.run_install());self.assertFalse((self.root/'page-layout.conf').exists());self.assert_success(self.run_install());self.assertFalse((self.root/'page-layout.conf').exists())

if __name__=='__main__':unittest.main()
