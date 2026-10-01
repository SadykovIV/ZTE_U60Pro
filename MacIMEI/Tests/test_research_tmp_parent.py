#!/usr/bin/env python3
"""Exercise the reviewed probe's exact function on synthetic directory modes."""
import json, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class TmpParentTests(unittest.TestCase):
    def test_directory_modes_owner_and_links(self):
        spec=json.loads((ROOT/'Resources/FirmwareResearch/probes.json').read_text())
        command=next(p['command'] for p in spec['probes'] if p['id']=='permissions')
        function=command.split('tmp_stage_parent_safe() {',1)[1].split('\n}\n',1)[0]
        function='tmp_stage_parent_safe() {'+function+'\n}\n'
        with tempfile.TemporaryDirectory(prefix='research-tmp-parent-') as name:
            root=pathlib.Path(name); folder=root/'directory';folder.mkdir();link=root/'link';link.symlink_to(folder)
            for mode,owner,target,expected in [('1777','0',folder,0),('755','0',folder,0),('777','0',folder,1),('1777','1',folder,1),('1777','0',link,1),('1777','0',root/'missing',1),('invalid','0',folder,1)]:
                mock='stat() { case "$2" in %u) printf "%s\\n" '+owner+';; %a) printf "%s\\n" '+mode+';; *) return 9;; esac; }\n'
                result=subprocess.run(['/bin/sh','-c',mock+function+'tmp_stage_parent_safe "$1"','fixture',str(target)],capture_output=True,text=True,timeout=3)
                self.assertEqual(result.returncode,expected,(mode,owner,target,result.stderr))
        self.assertIn('if tmp_stage_parent_safe /tmp; then fact tmp_private_stage_parent 1;',command)
if __name__=='__main__':unittest.main()
