#!/usr/bin/env python3
"""Execute exact read-only spec probes on a synthetic private filesystem."""
import json, os, pathlib, re, subprocess, sys, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
SPEC=ROOT/'Resources/FirmwareResearch/probes.json'
class AnchorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='research-anchor-');self.root=pathlib.Path(self.temp.name).resolve()
        self.bin=self.root/'bin';self.bin.mkdir();self.env=dict(os.environ)
        for path in ['data','data/local','data/local/tmp','data/bin','data/dropbear','etc','tmp','var/run','proc/self']:
            (self.root/path).mkdir(parents=True,exist_ok=True)
        for path in ['data/local','data/local/tmp','data/bin','data/dropbear']:(self.root/path).chmod(0o777)
        self.anchor=self.root/'data/zte-imei-studio'
        tool=self.bin/'stat';tool.write_text(f'#!{sys.executable}\n'+'''import os,sys,stat
p=sys.argv[-1];x=os.lstat(p);m=oct(stat.S_IMODE(x.st_mode))[2:];u='1' if p==os.environ.get('UNOWNED') else '0'
f=sys.argv[-2]
if f=='%u': print(u)
elif f=='%a': print(m)
elif f=='%u:%a': print(u+':'+m)
else: print('type=directory mode='+m+' uid='+u+' gid=0 bytes=0 links=1')
''');tool.chmod(0o700)
        self.mountinfo='1 0 8:1 / / ro - ext4 /dev/root ro\n2 1 8:2 / '+str(self.root)+'/data rw - ext4 /dev/data rw\n3 1 0:1 / '+str(self.root)+'/etc rw,noexec - overlay overlay rw\n'
        (self.root/'proc/self/mountinfo').write_text(self.mountinfo)
    def tearDown(self):self.temp.cleanup()
    def probe(self,name):
        spec=json.loads(SPEC.read_text());body=next(x['command'] for x in spec['probes'] if x['id']==name)
        body=body.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+str(self.bin)+':/usr/bin:/bin')
        body=re.sub(r'(?<![A-Za-z0-9_/])/(data|etc|proc|tmp|var)(?=/|[\s"\'])',lambda m:str(self.root)+m.group(0),body)
        body=body.replace('"/$name"','"'+str(self.root)+'/$name"')
        r=subprocess.run(['/bin/sh','-c',body],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr)
        return dict(line[8:].split('=',1) for line in r.stdout.splitlines() if line.startswith('FR_FACT '))
    def test_stock_shared_777_with_absent_anchor_is_compatible(self):
        before={str(p):p.stat().st_mode for p in (self.root/'data').rglob('*')}
        self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'1')
        self.assertFalse(self.anchor.exists());self.assertEqual(before,{str(p):p.stat().st_mode for p in (self.root/'data').rglob('*')})
    def test_private_existing_anchor_and_children_accepted(self):
        self.anchor.mkdir(mode=0o700)
        for name in ['bin','installations']:(self.anchor/name).mkdir(mode=0o700)
        self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'1')
    def test_public_or_unowned_or_symlink_anchor_refused(self):
        self.anchor.mkdir(mode=0o755);self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'0')
        self.anchor.chmod(0o700);self.env['UNOWNED']=str(self.anchor);self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'0')
        self.env.pop('UNOWNED');self.anchor.rmdir();self.anchor.symlink_to(self.root/'data/bin')
        self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'0')
    def test_unsafe_child_and_etc_key_parent_refused(self):
        self.anchor.mkdir(mode=0o700);(self.anchor/'bin').mkdir(mode=0o777)
        self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'0')
        (self.anchor/'bin').chmod(0o700);(self.root/'etc/dropbear').mkdir(mode=0o777);(self.root/'etc/dropbear').chmod(0o777)
        self.assertEqual(self.probe('permissions').get('setup_anchor_safe'),'0')
    def test_new_mount_and_etc_noexec_write_semantics(self):
        f=self.probe('mounts');self.assertEqual(f.get('setup_anchor_install_mount'),'1');self.assertEqual(f.get('etc_dropbear_write_mount'),'1')
        (self.root/'proc/self/mountinfo').write_text(self.mountinfo+'4 2 8:3 / '+str(self.anchor)+' rw,noexec - ext4 /dev/private rw\n')
        self.assertEqual(self.probe('mounts').get('setup_anchor_install_mount'),'0')
    def test_new_and_legacy_pending_detected(self):
        self.assertEqual(self.probe('pending-operations').get('no_pending_operations'),'1')
        for name in ['data/zte-imei-studio/installations/active','data/local/tmp/zte-imei-installations/active']:
            p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('synthetic')
            self.assertEqual(self.probe('pending-operations').get('no_pending_operations'),'0');p.unlink()
    def test_preparation_features_use_only_actual_new_install_paths(self):
        s=json.loads(SPEC.read_text());self.assertEqual(s['revision'],10)
        for feature in s['features']:
            if feature['id'] not in ['generic-access','preparation','ssh']:continue
            facts={x['fact'] for x in feature['requirements']}
            self.assertIn('setup_anchor_safe',facts);self.assertIn('setup_anchor_install_mount',facts);self.assertIn('etc_dropbear_write_mount',facts)
            self.assertFalse(facts & {'setup_parents_safe','setup_tmp_install_mount','data_bin_install_mount','data_dropbear_install_mount'})
if __name__=='__main__':unittest.main(verbosity=2)
