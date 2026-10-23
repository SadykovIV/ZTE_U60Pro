#!/usr/bin/env python3
"""Run both desktop clients' exact absence proof against local /proc fixtures."""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

def bodies():
    swift = (ROOT/'MacIMEI/Sources/AccessAgentReuse.swift').read_text().split('static func absenceCommand(',1)[1]
    windows = (ROOT/'Windows_x64/src/Core/AccessAgentReusePolicy.cs').read_text().split('static string AbsenceCommand(',1)[1]
    swift = swift.split('return #"""\n',1)[1].split('        """#.',1)[0]
    windows = windows.split('return """\n',1)[1].split('        """.',1)[0]
    return ['\n'.join(line[8:] for line in x.rstrip('\n').splitlines())+'\n' for x in (swift,windows)]

class AgentAbsenceProofTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='zte-agent-absence-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.bin=self.root/'bin';self.bin.mkdir()
        self.agent=self.root/'data/zte-agent';self.agent.parent.mkdir();self.agent.write_bytes(b'known installed agent')
        self.digest=hashlib.sha256(self.agent.read_bytes()).hexdigest()
        self.process(1,argv=b'init\0',mapped='/sbin/init')
        self.process(2,argv=b'',state='S',flags=2097152)
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],MOCK_ROOT=str(self.root))
        self.command('stat',f'''#!{sys.executable}
import os,sys
s=os.stat(sys.argv[-1]); d={{'%d':str(s.st_dev),'%i':str(s.st_ino),'%u':os.environ.get('MOCK_OWNER','0'),'%a':format(s.st_mode&0o7777,'o'),'%h':str(s.st_nlink)}}
print(':'.join(d[x] for x in sys.argv[2].split(':')))
''')
        self.command('sha256sum',f'''#!{sys.executable}
from pathlib import Path
import hashlib,sys
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()+'  '+sys.argv[1])
''')
        self.command('pidof',f'''#!{sys.executable}
from pathlib import Path
import os,sys
r=Path(os.environ['MOCK_ROOT']); p=r/'scans'; n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))
if n==2:
 if os.environ.get('MOCK_NEW_AGENT'):
  q=r/'proc/42';q.mkdir();(q/'cmdline').write_bytes(b'other\\0');(q/'exe').symlink_to('/data/zte-agent')
 if os.environ.get('MOCK_REPLACE_FILE'):
  q=r/'data/replacement';q.write_bytes((r/'data/zte-agent').read_bytes());q.replace(r/'data/zte-agent')
 if os.environ.get('MOCK_CHANGE_FILE'):(r/'data/zte-agent').write_bytes(b'changed')
if os.environ.get('MOCK_PIDS'):print(os.environ['MOCK_PIDS'])
sys.exit(int(os.environ.get('MOCK_PID_STATUS','1')))
''')
    def command(self,name,text):
        p=self.bin/name;p.write_text(text);p.chmod(0o700)
    def process(self,pid,argv=None,mapped=None,state='S',flags=0):
        p=self.root/f'proc/{pid}';p.mkdir(parents=True,exist_ok=True)
        if argv is not None:(p/'cmdline').write_bytes(argv)
        if mapped is not None:(p/'exe').symlink_to(mapped)
        values=[state,'0','0','0','0','0',str(flags)]+['0']*13
        (p/'stat').write_text(f'{pid} (fixture) '+' '.join(values)+'\n')
        return p
    def run_proof(self):
        body=bodies()[0].replace('EXPECTED_AGENT_SHA',self.digest)
        body=body.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C','export LC_ALL=C')
        body=re.sub(r'(?<![A-Za-z0-9_/])/(data|proc)(?=/|[ \n\";)])',lambda m:str(self.root)+m.group(0),body)
        return subprocess.run(['/bin/sh','-c',body],env=self.env,capture_output=True,text=True,timeout=10)
    def refused(self):
        result=self.run_proof();self.assertNotEqual(result.returncode,0,result.stdout);self.assertEqual(result.stdout,'')
    def test_both_clients_embed_identical_proof(self):self.assertEqual(*bodies())
    def test_absent_agent_with_kernel_thread_emits_exact_bounded_receipt(self):
        result=self.run_proof();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'AGENT_ACCESS_ABSENT '+self.digest+'\n');self.assertEqual((self.root/'scans').read_text(),'2')
    def test_missing_agent_with_safe_parent_and_no_process_emits_fixed_receipt(self):
        self.agent.unlink()
        result=self.run_proof();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'AGENT_ACCESS_ABSENT '+self.digest+'\n')
    def test_missing_agent_appearing_during_scan_is_not_stable_proof(self):
        self.agent.unlink();self.env['MOCK_CHANGE_FILE']='1';self.refused()
    def test_dangling_agent_link_is_not_missing(self):
        self.agent.unlink();self.agent.symlink_to(self.root/'missing-elsewhere');self.refused()
    def test_agent_directory_is_not_missing(self):
        self.agent.unlink();self.agent.mkdir();self.refused()
    def test_live_mapped_agent_with_cleared_argv_is_not_absence(self):
        self.process(42,argv=b'',mapped='/data/zte-agent');self.refused()
    def test_deleted_mapped_agent_is_not_absence(self):
        self.process(42,argv=b'other\0',mapped='/data/zte-agent (deleted)');self.refused()
    def test_agent_name_at_other_path_is_not_absence(self):
        self.process(42,argv=b'/other/zte-agent\0',mapped='/other/program');self.refused()
    def test_pidof_hit_is_not_absence(self):
        self.env.update(MOCK_PIDS='42',MOCK_PID_STATUS='0');self.refused()
    def test_pidof_tool_error_is_not_absence(self):
        self.env['MOCK_PID_STATUS']='2';self.refused()
    def test_existing_process_without_cmdline_is_not_absence(self):
        self.process(42,mapped='/other/program');self.refused()
    def test_read_failed_cmdline_is_not_absence(self):
        self.command('tr','#!/bin/sh\nexit 1\n');self.refused()
    def test_unreadable_exe_of_userspace_process_is_not_absence(self):
        self.process(42,argv=b'ordinary\0');self.refused()
    def test_empty_argv_does_not_disguise_userspace_process_without_exe(self):
        self.process(42,argv=b'');self.refused()
    def test_zombie_without_exe_is_not_running_agent(self):
        self.process(42,argv=b'',state='Z');self.assertEqual(self.run_proof().returncode,0)
    def test_wrong_or_replaced_file_is_not_absence(self):
        self.agent.write_bytes(b'changed');self.refused()
    def test_linked_file_is_not_absence(self):
        os.link(self.agent,self.root/'data/hardlink');self.refused()
    def test_wrong_owner_is_not_absence(self):
        self.env['MOCK_OWNER']='1000';self.refused()
    def test_agent_appearing_in_second_scan_is_not_absence(self):
        self.env['MOCK_NEW_AGENT']='1';self.refused()
    def test_file_changed_during_scan_is_not_absence(self):
        self.env['MOCK_CHANGE_FILE']='1';self.refused()
    def test_same_bytes_with_new_inode_is_not_stable_proof(self):
        self.env['MOCK_REPLACE_FILE']='1';self.refused()

if __name__=='__main__':unittest.main()
