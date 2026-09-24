from pathlib import Path
import tempfile, subprocess, unittest
SCRIPT=Path(__file__).resolve().parents[2]/'ModemAgent/scripts/device/preserve-dashboard-assets.sh'
class DashboardUpdateTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
  self.old=self.root/'old';self.new=self.root/'new'
  for root in [self.old,self.new]:(root/'assets').mkdir(parents=True)
 def tearDown(self):self.temp.cleanup()
 def run_copy(self):return subprocess.run(['sh',str(SCRIPT),str(self.old),str(self.new)],capture_output=True)
 def test_keeps_complete_old_import_graph_and_new_entry(self):
  (self.old/'index.html').write_text('old entry')
  (self.new/'index.html').write_text('new entry')
  for name,content in [('index-old.js','import("./NetworkGroup-old.js")'),('NetworkGroup-old.js','import "./vendor-shared.js"'),('vendor-shared.js','shared'),('style-old.css','old css')]:
   (self.old/'assets'/name).write_text(content)
  (self.new/'assets/vendor-shared.js').write_text('shared')
  (self.new/'assets/index-new.js').write_text('new app')
  self.assertEqual(self.run_copy().returncode,0)
  self.assertEqual((self.new/'index.html').read_text(),'new entry')
  for path in (self.old/'assets').iterdir():self.assertEqual(path.read_bytes(),(self.new/'assets'/path.name).read_bytes())
  self.assertEqual(self.run_copy().returncode,0)
 def test_conflicting_hash_name_stops_before_replacing_new_file(self):
  (self.old/'assets/chunk-shared.js').write_text('old')
  (self.new/'assets/chunk-shared.js').write_text('different')
  self.assertNotEqual(self.run_copy().returncode,0)
  self.assertEqual((self.new/'assets/chunk-shared.js').read_text(),'different')
 def test_symlink_cannot_publish_private_content(self):
  secret=self.root/'secret';secret.write_text('private')
  (self.old/'assets/chunk-secret.js').symlink_to(secret)
  self.assertNotEqual(self.run_copy().returncode,0)
  self.assertFalse((self.new/'assets/chunk-secret.js').exists())
 def test_empty_previous_installation_is_supported(self):self.assertEqual(self.run_copy().returncode,0)
if __name__=='__main__':unittest.main()
