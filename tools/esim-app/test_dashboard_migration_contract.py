#!/usr/bin/env python3
"""Real shared shell prefixes/selection/rc update, with local paths only."""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VPN = ROOT/'MacIMEI/Resources/VPN'
ID = '12345678-1234-1234-1234-123456789abc'


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-dashboard-contract-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root/'bin').mkdir()
        self.env = dict(os.environ, PATH=str(self.root/'bin')+':'+os.environ['PATH'])
    def script(self, name, body):
        path = self.root/name;path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(body);path.chmod(0o700);return path
    def run_script(self, path, *args):
        return subprocess.run(['/bin/sh',str(path),*map(str,args)],env=self.env,capture_output=True,text=True,timeout=5)
    def test_vpn_wrapper_preflight_apply_and_hash(self):
        stage=self.root/('tmp/zte-vpn-agent-'+ID);stage.mkdir(parents=True,mode=0o700)
        leaf=self.script(str(stage.relative_to(self.root))+'/dashboard-install.sh', '#!/bin/sh\nif [ "$4" = preflight ]; then echo DASHBOARD_PREFLIGHT '+ID+'; else echo DASHBOARD_INSTALLED '+ID+'; fi\n')
        digest=hashlib.sha256(leaf.read_bytes()).hexdigest()
        self.script('bin/stat','#!/bin/sh\ncase "$2" in %u:%a) echo 0:700;; %u) echo 0;; *) exit 1;; esac\n')
        cid=self.root/'sys/block/mmcblk0/device/cid';cid.parent.mkdir(parents=True);cid.write_text('a'*32)
        text=(VPN/'update-agent.sh').read_text()
        import re
        text=re.sub(r'(?m)^dashboard_installer_sha=.*','dashboard_installer_sha='+digest,text)
        for p in ['/tmp/zte-vpn-agent-','/sys']:text=text.replace(p,str(self.root)+p)
        wrapper=self.script('wrapper.sh',text)
        first=self.run_script(wrapper,stage,'preflight');self.assertEqual((first.returncode,first.stdout),(0,'VPN_AGENT_PREFLIGHT_OK\n'))
        second=self.run_script(wrapper,stage);self.assertEqual((second.returncode,second.stdout),(0,'VPN_AGENT_UPDATED\n'))
        leaf.write_text('#!/bin/sh\necho WRONG\n')
        self.assertNotEqual(self.run_script(wrapper,stage,'preflight').returncode,0)
    def listener(self, kind='legacy', valid=True, listening=True):
        legacy=self.root/'data/bin/dashboard-uhttpd'
        private=self.root/'data/zte-dashboard-runtime/dashboard-uhttpd'
        selected=legacy if kind=='legacy' else private
        selected.parent.mkdir(parents=True,exist_ok=True);selected.write_bytes(b'pinned-uhttpd')
        digest=hashlib.sha256(selected.read_bytes()).hexdigest()
        if not valid:selected.write_bytes(b'unknown executable')
        proc=self.root/'proc';(proc/'net').mkdir(parents=True,exist_ok=True);(proc/'123/fd').mkdir(parents=True,exist_ok=True)
        (proc/'123/exe').symlink_to(selected)
        (proc/'123/fd/3').symlink_to('socket:[99]')
        (proc/'net/tcp').write_text('0: 00000000:1F90 00000000:0000 '+('0A' if listening else '01')+' 0 0 0 0 0 99\n')
        (proc/'net/tcp6').write_text('')
        text=(VPN/'stop-owned-listener.sh').read_text().replace('/data',str(self.root)+'/data')
        import re
        text=re.sub(r'(?m)^dashboard_sha=.*','dashboard_sha='+digest,text)
        script=self.script('stop.sh',text);self.env['U60_TEST_PROC_ROOT']=str(proc)
        return self.run_script(script,'dashboard-uhttpd','1F90','--list')
    def test_known_legacy_listener_can_be_selected_without_old_helper(self):
        result=self.listener();self.assertEqual((result.returncode,result.stdout),(0,'123\n'))
    def test_known_private_listener_can_be_selected(self):
        result=self.listener('private');self.assertEqual((result.returncode,result.stdout),(0,'123\n'))
    def test_unknown_legacy_executable_fails_closed(self):
        result=self.listener(valid=False);self.assertNotEqual(result.returncode,0);self.assertEqual(result.stdout,'')
    def test_established_socket_is_not_selected(self):
        result=self.listener(listening=False);self.assertEqual((result.returncode,result.stdout),(0,''))
    def test_boot_entry_moves_to_private_runtime_and_preserves_other_lines(self):
        rc=self.root/'etc/rc.local';rc.parent.mkdir()
        rc.write_text('#!/bin/sh\nsh /data/local/tmp/start_zte_agent.sh\nsh /data/local/tmp/start_dashboard.sh\nexit 0\n')
        text=(VPN/'update-rc-local.sh').read_text().replace('/etc/',str(self.root)+'/etc/')
        # BSD sed adapter accepts the script's GNU in-place spelling.
        self.script('bin/sed',f'#!{sys.executable}\nimport os,sys\na=sys.argv[1:]\nif a[0]=="-i":\n a=["-i", "", *a[1:]]\n if a[2].startswith("/^exit 0/i "):a[2]="/^exit 0/i\\\\\\n"+a[2][11:]+"\\n"\nos.execv("/usr/bin/sed",["sed",*a])\n')
        script=self.script('rc-update.sh',text)
        result=self.run_script(script,'sh /data/zte-dashboard-runtime/start-dashboard.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        body=rc.read_text();self.assertNotIn('sh /data/local/tmp/start_dashboard.sh',body)
        self.assertIn('sh /data/local/tmp/start_zte_agent.sh',body)
        self.assertEqual(body.count('sh /data/zte-dashboard-runtime/start-dashboard.sh'),1)
        self.assertLess(body.index('sh /data/zte-dashboard-runtime'),body.index('exit 0'))
        self.assertEqual(self.run_script(script,'sh /data/zte-dashboard-runtime/start-dashboard.sh').returncode,0)


if __name__=='__main__':unittest.main()
