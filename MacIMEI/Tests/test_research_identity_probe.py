#!/usr/bin/env python3
"""Run the exact identity probe against synthetic files and tool outputs."""
import json, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class IdentityTests(unittest.TestCase):
    def run_probe(self, content):
        spec=json.loads((ROOT/'Resources/FirmwareResearch/probes.json').read_text())
        command=next(p['command'] for p in spec['probes'] if p['id']=='identity')
        with tempfile.TemporaryDirectory(prefix='research-identity-') as directory:
            base=pathlib.Path(directory); (base/'bin').mkdir()
            for name,body in [('id',"printf '0\\n'"),('uname',"printf 'aarch64\\n'")]:
                p=base/'bin'/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o700)
            (base/'status').write_text('CapEff:\t0000000000000000\n')
            if content is not None:(base/'enforce').write_bytes(content)
            command=command.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+str(base/'bin')+':/usr/bin:/bin').replace('/proc/self/status',str(base/'status')).replace('/sys/fs/selinux/enforce',str(base/'enforce'))
            r=subprocess.run(['/bin/sh','-c',command],capture_output=True,text=True,timeout=3)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('FR_FACT architecture=aarch64',r.stdout)
            self.assertIn('FR_FACT root=1',r.stdout)
            return r.stdout
    def test_no_newline_zero(self):self.assertIn('FR_FACT selinux_enforcing=0',self.run_probe(b'0'))
    def test_no_newline_one(self):self.assertIn('FR_FACT selinux_enforcing=1',self.run_probe(b'1'))
    def test_optional_missing_empty_invalid(self):
        for data,wanted in [(None,'missing'),(b'','unknown'),(b'private-synthetic','unknown'),(b'0\n','0')]:
            out=self.run_probe(data);self.assertIn('FR_FACT selinux_enforcing='+wanted,out);self.assertNotIn('private-synthetic',out)
if __name__=='__main__':unittest.main()
