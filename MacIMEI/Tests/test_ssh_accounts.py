#!/usr/bin/env python3
"""Run the real account transaction in isolated synthetic filesystem fixtures.
Every absolute device path and privileged utility is replaced before execution;
no device connection, account creation, or host system database access occurs.
"""
import hashlib, os, pathlib, re, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'Resources/SSHAccounts/create-ssh-user.sh').read_text()
TOKEN='11111111-1111-4111-8111-111111111111'
CID='0123456789abcdef0123456789abcdef'
OPENSSL=pathlib.Path('/opt/homebrew/opt/openssl@3/bin/openssl')

class Fixture:
    def __init__(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='zte-account-fixture-');self.p=pathlib.Path(self.tmp.name)
        self.bin=self.p/'mockbin';self.bin.mkdir()
        self.etc=self.p/'etc';self.etc.mkdir()
        for d in ['data','proc/net','sys/block/mmcblk0/device','firmware/image','usr/bin','var/run','tmp']:(self.p/d).mkdir(parents=True,exist_ok=True)
        self.stage=self.p/('tmp/zte-ssh-users-'+TOKEN);self.stage.mkdir(mode=0o700)
        for name,data in {'passwd':'root:x:0:0:root:/root:/bin/ash\ndaemon:x:1:1::/:/bin/false\n','shadow':'root:!:19000:0:99999:7:::\n','group':'root:x:0:\ndaemon:x:1:\n','rc.local':'#!/bin/sh\necho existing-hook\nexit 0\n'}.items():
            (self.etc/name).write_text(data)
        (self.p/'sys/block/mmcblk0/device/cid').write_text(CID+'\n')
        (self.p/'firmware/image/modem.b16').write_bytes(b'firmware')
        (self.p/'usr/bin/diag-router').write_bytes(b'router')
        (self.p/'proc/mounts').write_text('/dev/fake '+str(self.p/'data')+' ext4 rw,relatime 0 0\n')
        (self.p/'proc/net/tcp').write_text('')
        (self.p/'proc/net/tcp6').write_text('')
        self.script=SOURCE
        mapping=dict([('/tmp/zte-ssh-users-',str(self.p/'tmp/zte-ssh-users-')),('/etc',str(self.etc)),('/data',str(self.p/'data')),('/proc',str(self.p/'proc')),('/sys',str(self.p/'sys')),('/firmware',str(self.p/'firmware')),('/var',str(self.p/'var')),('/usr/bin/diag-router',str(self.p/'usr/bin/diag-router')),('/usr/bin/openssl',str(OPENSSL))])
        self.mapping=mapping
        self.script=re.sub("|".join(re.escape(k) for k in sorted(mapping,key=len,reverse=True)),lambda m:mapping[m.group(0)],self.script)
        self.script=self.script.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin','export PATH='+str(self.bin)+':/usr/bin:/bin')
        self.script=self.script.replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263',hashlib.sha256(b'firmware').hexdigest()).replace('55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f',hashlib.sha256(b'router').hexdigest())
        (self.stage/'create-ssh-user.sh').write_text(self.script)
        self.start('exit 0')
        self.write(self.stage/'doas','#!/bin/sh\nexit 0\n')
        self.write(self.stage/'dropbear','#!/bin/sh\nexit 0\n')
        self.write(self.bin/'uname','#!/bin/sh\necho aarch64\n')
        self.write(self.bin/'flock','#!/bin/sh\nexit 0\n')
        self.write(self.bin/'sync','#!/bin/sh\nexit 0\n')
        self.write(self.bin/'chmod',f'''#!{shutil.which("python3")}
import os,sys
mode=int(sys.argv[1],8)
for p in sys.argv[2:]:
 if mode & 0o4000:open(p+'.requested-mode','w').write(oct(mode)[2:])
 os.chmod(p,mode & 0o0777)
''')
        self.write(self.bin/'chown' ,'#!/bin/sh\nexit 0\n')
        self.write(self.bin/'sha256sum',f'#!{shutil.which("python3")}\nimport hashlib,sys\nprint(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()+"  "+sys.argv[1])\n')
        self.write(self.bin/'stat',f'''#!{shutil.which("python3")}
import os,sys
p=sys.argv[-1];fmt=sys.argv[2];mode=oct(os.stat(p).st_mode&0o7777)[2:]
if os.path.exists(p+'.requested-mode'):mode=open(p+'.requested-mode').read()
uid='50000' if '/homes/' in p and p.endswith('/admin') else '0'
print(fmt.replace('%a',mode).replace('%u',uid).replace('%g','0'))
''')
        self.write(self.bin/'id',f'''#!{shutil.which("python3")}
import sys
if len(sys.argv)==2:print(0);sys.exit()
lines=open({str(self.etc/'passwd')!r}).read().splitlines()
for line in lines:
 p=line.split(':')
 if p[0]==sys.argv[2]:print(p[2] if sys.argv[1]=='-u' else p[3]);sys.exit()
sys.exit(1)
''')
        self.original={n:(self.etc/n).read_bytes() for n in ['passwd','shadow','group','rc.local']}
    def write(self,path,text):path.write_text(text);path.chmod(0o755)
    def start(self,body):self.write(self.stage/'start-ssh-users.sh','#!/bin/sh\n'+body+'\n')
    @property
    def base(self):return self.p/'data/zte-imei-admin'
    @property
    def journal(self):return self.base/'transactions'/TOKEN
    def run(self,password="safe 'password;123\n",user='admin'):
        sha=lambda n:hashlib.sha256((self.stage/n).read_bytes()).hexdigest()
        return subprocess.run(['/bin/sh',str(self.stage/'create-ssh-user.sh'),str(self.stage),CID,'192.168.0.1',user,sha('doas'),sha('dropbear')],input=password.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    def close(self):self.tmp.cleanup()

class Accounts(unittest.TestCase):
    def setUp(self):self.f=Fixture()
    def tearDown(self):self.f.close()
    def unchanged(self):
        for name,data in self.f.original.items():self.assertEqual((self.f.etc/name).read_bytes(),data,name)
    def test_complete_account_uses_nonzero_uid_sha512_and_preserves_stock_records(self):
        r=self.f.run();self.assertEqual(r.returncode,0,r.stderr.decode())
        self.assertIn('admin:x:50000:50000:',(self.f.etc/'passwd').read_text())
        shadow=(self.f.etc/'shadow').read_text();self.assertIn('admin:$6$',shadow)
        self.assertNotIn("safe 'password",shadow)
        self.assertNotIn('admin:$6$'+'0:0:',shadow)
        self.assertEqual((self.f.etc/'zte-imei-admin/doas.conf').read_text(),'\npermit admin as root\n')
        self.assertIn('echo existing-hook\n',(self.f.etc/'rc.local').read_text())
        self.assertTrue((self.f.etc/'rc.local').read_text().endswith('exit 0\n'))
        self.assertFalse((self.f.base/'active').exists())
        self.assertEqual((self.f.journal/'state').read_text(),'complete\n')
        self.assertEqual((self.f.base/'bin/doas.requested-mode').read_text(),'4755')
        for name,data in self.f.original.items():self.assertEqual((self.f.journal/'before'/name).read_bytes(),data)
    def test_account_lock_descriptor_is_not_inherited_by_listener(self):
        self.f.start(f"{shutil.which('python3')} -c 'import os; os.fstat(9)' 2>/dev/null && exit 91; exit 0")
        r=self.f.run();self.assertEqual(r.returncode,0,r.stderr.decode())
        # Exercise both the existing-listener validation and the final launch.
        other=self.f.p/'tmp/zte-ssh-users-22222222-2222-4222-8222-222222222222'
        shutil.copytree(self.f.stage,other);self.f.stage=other
        (self.f.p/'proc/net/tcp').write_text('0: 010000C0:08AF 00000000:0000 0A\n')
        r=self.f.run(user='secondadmin');self.assertEqual(r.returncode,0,r.stderr.decode())
    def test_listener_failure_rolls_back_all_existing_bytes(self):
        self.f.start('exit 1');r=self.f.run();self.assertNotEqual(r.returncode,0);self.unchanged()
        self.assertEqual((self.f.journal/'state').read_text(),'rolled-back\n')
        self.assertFalse((self.f.base/'active').exists())
        self.assertFalse((self.f.base/'homes/admin').exists())
    def test_multiline_username_is_rejected_as_one_value(self):
        for username in ['admin\n', 'admin\nforged:x:0:0::/:/bin/ash']:
            r=self.f.run(user=username);self.assertNotEqual(r.returncode,0);self.assertIn(b'USER_NAME',r.stderr);self.unchanged()
    def test_existing_username_is_never_replaced(self):
        r=self.f.run(user='daemon');self.assertNotEqual(r.returncode,0);self.unchanged()
    def test_duplicate_login_is_never_replaced(self):
        (self.f.etc/'passwd').write_text(self.f.original['passwd'].decode()+'admin:x:123:123::/:/bin/ash\n')
        r=self.f.run();self.assertNotEqual(r.returncode,0);self.assertIn(b'USER_EXISTS',r.stderr)
        self.assertFalse((self.f.base/'active').exists())
    def test_second_admin_retains_first_user_and_assigns_distinct_uid(self):
        r=self.f.run();self.assertEqual(r.returncode,0,r.stderr.decode())
        other=self.f.p/'tmp/zte-ssh-users-22222222-2222-4222-8222-222222222222'
        shutil.copytree(self.f.stage,other);self.f.stage=other
        r=self.f.run(user='secondadmin');self.assertEqual(r.returncode,0,r.stderr.decode())
        passwd=(self.f.etc/'passwd').read_text()
        self.assertIn('admin:x:50000:50000:',passwd)
        self.assertIn('secondadmin:x:50001:50000:',passwd)
        self.assertEqual((self.f.etc/'group').read_text().count('zteimei:'),1)
        self.assertIn('permit secondadmin as root',(self.f.etc/'zte-imei-admin/doas.conf').read_text())
    def test_foreign_group_is_not_adopted(self):
        p=self.f.etc/'group';p.write_text(p.read_text()+'zteimei:x:50000:\n')
        r=self.f.run();self.assertNotEqual(r.returncode,0);self.assertIn(b'GROUP_UNMANAGED',r.stderr)
        self.assertEqual((self.f.etc/'passwd').read_bytes(),self.f.original['passwd'])
    def test_unmanaged_nopass_policy_is_not_inherited(self):
        p=self.f.etc/'zte-imei-admin';p.mkdir(mode=0o755)
        (p/'doas.conf').write_text('permit nopass nobody as root\n');(p/'doas.conf').chmod(0o600)
        r=self.f.run();self.assertNotEqual(r.returncode,0);self.assertIn(b'DOAS_CONFIG_UNMANAGED',r.stderr)
        self.unchanged()
    def test_short_password_has_no_side_effects(self):
        r=self.f.run('short\n');self.assertNotEqual(r.returncode,0);self.unchanged();self.assertFalse(self.f.base.exists())
    def test_multiline_password_has_no_side_effects(self):
        r=self.f.run('validpass\nextra\n');self.assertNotEqual(r.returncode,0);self.unchanged()
    def test_symlink_database_is_rejected(self):
        p=self.f.etc/'shadow';p.rename(self.f.etc/'shadow-real');p.symlink_to('shadow-real')
        r=self.f.run();self.assertNotEqual(r.returncode,0);self.assertIn(b'DATABASE_TYPE',r.stderr)
    def test_concurrent_database_writer_is_preserved(self):
        self.f.write(self.f.stage/'doas',f'#!/bin/sh\necho "external:x:123:" >> {self.f.etc}/group\nexit 0\n')
        r=self.f.run();self.assertNotEqual(r.returncode,0);self.assertIn(b'CONCURRENT_CHANGE',r.stderr)
        self.assertEqual((self.f.etc/'shadow').read_bytes(),self.f.original['shadow'])
        self.assertIn('external:x:123:',(self.f.etc/'group').read_text())
        self.assertTrue((self.f.base/'active').exists())
        self.assertEqual((self.f.journal/'state').read_text(),'recovery-required\n')
    def test_external_change_during_rollback_is_not_overwritten(self):
        self.f.start(f'echo "external-change" >> {self.f.etc}/passwd\nexit 1')
        r=self.f.run();self.assertNotEqual(r.returncode,0)
        self.assertIn('external-change',(self.f.etc/'passwd').read_text())
        self.assertTrue((self.f.base/'active').exists())
    def test_nosuid_mount_refused_before_account_transaction(self):
        p=self.f.p/'proc/mounts';p.write_text(p.read_text().replace('rw,relatime','rw,nosuid,relatime'))
        r=self.f.run();self.assertNotEqual(r.returncode,0);self.assertIn(b'DATA_MOUNT',r.stderr);self.unchanged()
    def test_password_never_written_to_device_journal(self):
        r=self.f.run();self.assertEqual(r.returncode,0,r.stderr.decode())
        for p in self.f.base.rglob('*'):
            if p.is_file():self.assertNotIn(b"safe 'password;123",p.read_bytes(),str(p))
        self.assertNotIn(b"safe 'password;123",r.stdout+r.stderr)

class Listener(unittest.TestCase):
    def setUp(self):
        self.f=Fixture();self.base=self.f.base;self.conf=self.f.etc/'zte-imei-admin'
        (self.base/'bin').mkdir(parents=True);self.conf.mkdir()
        (self.conf/'listen-address').write_text('192.168.0.1\n');(self.conf/'listen-address').chmod(0o600)
        self.f.write(self.base/'bin/dropbear','#!/bin/sh\nexit 0\n')
        proc=self.f.p/'proc/4242';proc.mkdir()
        (proc/'exe').symlink_to(self.base/'bin/dropbear')
        (self.f.p/'var/run/zte-imei-users.pid').write_text('4242\n')
        (self.f.p/'proc/net/tcp').write_text('0: 010000C0:08AF 00000000:0000 0A\n')
        self.f.write(self.f.bin/'ip','#!/bin/sh\necho "3: br-lan inet 192.168.0.1/24"\n')
        source=(ROOT/'Resources/SSHAccounts/start-ssh-users.sh').read_text()
        source=re.sub("|".join(re.escape(k) for k in sorted(self.f.mapping,key=len,reverse=True)),lambda m:self.f.mapping[m.group(0)],source)
        source=source.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin','export PATH='+str(self.f.bin)+':/usr/bin:/bin')
        self.script=self.f.p/'listener.sh';self.script.write_text(source)
    def tearDown(self):self.f.close()
    def run_listener(self,args):
        (self.f.p/'proc/4242/cmdline').write_bytes(b'\0'.join(x.encode() for x in [str(self.base/'bin/dropbear')]+args)+b'\0')
        return subprocess.run(['/bin/sh',str(self.script)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
    def test_existing_scoped_listener_is_preserved(self):
        r=self.run_listener(['-w','-G','zteimei','-p','192.168.0.1:2223']);self.assertEqual(r.returncode,0,r.stderr.decode())
    def test_existing_root_enabled_listener_is_rejected(self):
        r=self.run_listener(['-G','zteimei','-p','192.168.0.1:2223']);self.assertNotEqual(r.returncode,0);self.assertIn(b'ROOT_LOGIN_ENABLED',r.stderr)
    def test_existing_unrestricted_group_listener_is_rejected(self):
        r=self.run_listener(['-w','-G','root','-p','192.168.0.1:2223']);self.assertNotEqual(r.returncode,0);self.assertIn(b'GROUP_RESTRICTION_MISSING',r.stderr)
    def test_existing_wildcard_listener_is_rejected(self):
        r=self.run_listener(['-w','-G','zteimei','-p','0.0.0.0:2223']);self.assertNotEqual(r.returncode,0);self.assertIn(b'LISTENER_ADDRESS',r.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
