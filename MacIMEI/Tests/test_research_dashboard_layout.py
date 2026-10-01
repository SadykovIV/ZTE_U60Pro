#!/usr/bin/env python3
"""Exact new-runtime metadata fragment against temporary synthetic paths only."""
import json, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class DashboardLayoutTests(unittest.TestCase):
    def test_isolated_layout(self):
        spec=json.loads((ROOT/'Resources/FirmwareResearch/probes.json').read_text())
        command=next(p['command'] for p in spec['probes'] if p['id']=='permissions')
        fragment='dashboard_safe=1\n'+command.split('dashboard_safe=1\n',1)[1]
        for scenario,expected in [('absent',1),('private',1),('public',0),('link',0),('owner',0),('nested-public',0)]:
            with tempfile.TemporaryDirectory(prefix='research-dashboard-') as name:
                base=pathlib.Path(name);runtime=base/'runtime';bin=base/'bin';bin.mkdir()
                if scenario!='absent':
                    if scenario=='link':(base/'elsewhere').mkdir();runtime.symlink_to(base/'elsewhere')
                    else: runtime.mkdir(mode=0o755 if scenario=='public' else 0o700)
                    if scenario=='nested-public':(runtime/'dashboards').mkdir(mode=0o755)
                stat=bin/'stat';stat.write_text('#!/usr/bin/python3\nimport os,sys\nassert sys.argv[1:3]==["-c","%u:%a"]\nprint("'+('1'if scenario=='owner'else'0')+':"+oct(os.stat(sys.argv[3]).st_mode&0o777)[2:])\n');stat.chmod(0o700)
                body='PATH='+str(bin)+':/usr/bin:/bin\nmeta() { :; }; fact() { printf "%s=%s\\n" "$1" "$2"; }\n'+fragment.replace('/data/zte-dashboard-runtime',str(runtime))
                result=subprocess.run(['/bin/sh','-c',body],capture_output=True,text=True,timeout=3)
                self.assertEqual(result.returncode,0,result.stderr);self.assertIn('dashboard_runtime_safe='+str(expected),result.stdout,scenario)
if __name__=='__main__':unittest.main()
