#!/usr/bin/env python3
"""Real shell scripts, relocated synthetic device filesystem; never contacts a modem."""
import hashlib, os, pathlib, re, shutil, subprocess, unittest
from test_ssh_accounts import Fixture, CID, ROOT
TOKEN='22222222-2222-4222-8222-222222222222'
LOCK='33333333-3333-4333-8333-333333333333'

class Deletion(unittest.TestCase):
    def setUp(self):
        self.f=Fixture()
        result=self.f.run();self.assertEqual(result.returncode,0,result.stderr.decode())
        self.before={x:(self.f.etc/x).read_bytes() for x in ['passwd','group','shadow','zte-imei-admin/doas.conf']}
        (self.f.base/'homes/admin/keep.txt').write_text('user contents\n')
        self.stage=self.f.p/('tmp/zte-ssh-users-'+TOKEN);self.stage.mkdir(mode=0o700)
        lock=self.f.p/'tmp/zte-imei-app.lock';lock.mkdir(mode=0o700);(lock/'owner').write_text(LOCK)
        self.mapping=dict(self.f.mapping)
        self.mapping['/tmp/zte-imei-app.lock']=str(lock)
        source=(ROOT/'Resources/SSHAccounts/delete-ssh-user.sh').read_text()
        source=re.sub('|'.join(re.escape(k) for k in sorted(self.mapping,key=len,reverse=True)),lambda m:self.mapping[m.group(0)],source)
        source=source.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin','export PATH='+str(self.f.bin)+':/usr/bin:/bin')
        for expected,path in [('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263',self.f.p/'firmware/image/modem.b16'),('55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f',self.f.p/'usr/bin/diag-router'),('f162f2d83476d22559fd844203b6af52c6a74250390cdf08c1d6b99e58c9ec97',self.f.base/'bin/doas'),('e3833acdaa8b11e6150f82a35d3dc53d685561d5504ef337ad4af5e530345378',self.f.base/'bin/dropbear'),('35d0e51c65f0ba3499c62d16df1447b91c67e4e0cca26bc9c0e05efb712ef297',self.f.base/'start-ssh-users.sh')]:
            source=source.replace(expected,hashlib.sha256(path.read_bytes()).hexdigest())
        self.script=self.stage/'delete-ssh-user.sh';self.script.write_text(source)
        self.f.write(self.f.bin/'mv',f'''#!{shutil.which('python3')}
import os,sys
src,dst=sys.argv[1:]
if os.environ.get('MOCK_FAIL_MOVE') and dst.endswith('/shadow') and '.zte-{TOKEN}' in src:sys.exit(1)
if os.environ.get('MOCK_CRASH_MOVE') and dst.endswith('/shadow') and '.zte-{TOKEN}' in src:
 import signal;os.kill(os.getppid(),signal.SIGKILL);sys.exit(1)
os.rename(src,dst)
''')
    def tearDown(self):self.f.close()
    def run_delete(self,user='admin',env=None,mode='delete'):
        args=['/bin/sh',str(self.script),mode,str(self.stage),CID]+([user] if mode=='delete' else [])+[LOCK]
        return subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20,env=dict(os.environ,**(env or {})))
    def unchanged(self):
        for name,data in self.before.items():self.assertEqual((self.f.etc/name).read_bytes(),data,name)
    def test_delete_archives_home_and_preserves_other_users_and_shared_group(self):
        r=self.run_delete();self.assertEqual(r.returncode,0,r.stderr.decode())
        self.assertNotIn('admin:',(self.f.etc/'passwd').read_text());self.assertNotIn('admin:',(self.f.etc/'shadow').read_text())
        self.assertEqual((self.f.etc/'group').read_bytes(),self.before['group'])
        self.assertEqual((self.f.base/'archive'/TOKEN/'admin/keep.txt').read_text(),'user contents\n')
        self.assertFalse((self.f.base/'homes/admin').exists());self.assertFalse((self.f.base/'active').exists())
        for name,data in self.before.items():self.assertEqual((self.f.base/'transactions'/TOKEN/'before'/pathlib.Path(name).name).read_bytes(),data)
    def test_system_user_rejected(self):
        r=self.run_delete('root');self.assertNotEqual(r.returncode,0);self.unchanged()
    def test_user_without_creation_proof_rejected(self):
        (self.f.journal/'state').write_text('rolled-back\n')
        r=self.run_delete();self.assertNotEqual(r.returncode,0);self.assertIn(b'CREATION_PROOF_MISSING',r.stderr);self.unchanged()
    def test_active_session_refused(self):
        proc=self.f.p/'proc/999';proc.mkdir();(proc/'status').write_text('Uid:\t50000\t50000\t50000\t50000\n')
        r=self.run_delete();self.assertNotEqual(r.returncode,0);self.assertIn(b'USER_LOGGED_IN',r.stderr);self.unchanged()
    def test_global_lock_mismatch_refused(self):
        (self.f.p/'tmp/zte-imei-app.lock/owner').write_text('other')
        r=self.run_delete();self.assertNotEqual(r.returncode,0);self.assertIn(b'GLOBAL_LOCK',r.stderr);self.unchanged()
    def test_home_symlink_refused(self):
        home=self.f.base/'homes/admin';home.rename(self.f.base/'homes/saved');home.symlink_to('saved')
        r=self.run_delete();self.assertNotEqual(r.returncode,0);self.assertIn(b'HOME_OWNER',r.stderr);self.unchanged()
    def test_partial_commit_failure_rolls_back_exact_bytes(self):
        r=self.run_delete(env={'MOCK_FAIL_MOVE':'1'});self.assertNotEqual(r.returncode,0);self.unchanged()
        self.assertTrue((self.f.base/'homes/admin/keep.txt').exists());self.assertFalse((self.f.base/'active').exists())
        self.assertEqual((self.f.base/'transactions'/TOKEN/'state').read_text(),'rolled-back\n')
    def test_killed_commit_retains_journal_and_explicit_recovery_restores(self):
        r=self.run_delete(env={'MOCK_CRASH_MOVE':'1'});self.assertNotEqual(r.returncode,0);self.assertTrue((self.f.base/'active').exists())
        r=self.run_delete(mode='recover');self.assertEqual(r.returncode,0,r.stderr.decode());self.unchanged();self.assertFalse((self.f.base/'active').exists())
    def test_external_change_during_recovery_preserved(self):
        self.run_delete(env={'MOCK_CRASH_MOVE':'1'})
        p=self.f.etc/'passwd';p.write_text(p.read_text()+'external:x:123:123::/:/bin/false\n')
        r=self.run_delete(mode='recover');self.assertNotEqual(r.returncode,0);self.assertIn('external:x:123:',p.read_text());self.assertTrue((self.f.base/'active').exists())
    def install_listener_fixture(self):
        # A synthetic LISTEN socket and PID tree. No real process is signalled.
        helper=f'''#!{shutil.which('python3')}
import os,sys,pathlib,shutil
root=pathlib.Path({str(self.f.p)!r})
net=root/'proc/net/tcp';p=root/'proc/4242'
if sys.argv[1]=='stop':
 shutil.rmtree(p);net.write_text('');sys.exit()
try:os.fstat(9)
except OSError:pass
else:sys.exit(91)
p.mkdir(exist_ok=True)
(p/'exe').symlink_to(root/'data/zte-imei-admin/bin/dropbear')
(p/'cmdline').write_bytes(b'\\0'.join([b'dropbear',b'-w',b'-G',b'zteimei',b'-p',b'192.168.0.1:2223'])+b'\\0')
(root/'var/run/zte-imei-users.pid').write_text('4242\\n')
net.write_text('0: 010000C0:08AF 00000000:0000 0A 0 0 0 0 0 4242\\n')
with (root/'listener-starts').open('a') as out:out.write('start\\n')
'''
        self.f.write(self.f.bin/'mock-listener',helper)
        launcher=self.f.base/'start-ssh-users.sh';old=hashlib.sha256(launcher.read_bytes()).hexdigest()
        launcher.write_text('#!/bin/sh\nmock-listener start\n')
        source=self.script.read_text().replace('test "$(hash "$base/start-ssh-users.sh")" = '+old, 'test "$(hash "$base/start-ssh-users.sh")" = '+hashlib.sha256(launcher.read_bytes()).hexdigest())
        source=source.replace('kill -TERM "$listener_pid"','mock-listener stop "$listener_pid"')
        self.script.write_text(source)
        subprocess.run([str(self.f.bin/'mock-listener'),'start'],check=True)
    def test_delete_restarts_listener_without_inheriting_account_lock(self):
        self.install_listener_fixture()
        r=self.run_delete();self.assertEqual(r.returncode,0,r.stderr.decode())
        self.assertEqual((self.f.p/'listener-starts').read_text(),'start\nstart\n')
        self.assertTrue((self.f.p/'proc/4242').exists())
    def test_conflicted_recovery_keeps_listener_stopped(self):
        self.install_listener_fixture()
        r=self.run_delete(env={'MOCK_CRASH_MOVE':'1'});self.assertNotEqual(r.returncode,0)
        p=self.f.etc/'passwd';p.write_text(p.read_text()+'external:x:123:123::/:/bin/false\n')
        r=self.run_delete(mode='recover');self.assertNotEqual(r.returncode,0)
        self.assertIn(b'RECOVERY_CONFLICT',r.stderr);self.assertIn('external:x:123:',p.read_text())
        self.assertFalse((self.f.p/'proc/4242').exists())
        self.assertEqual((self.f.p/'listener-starts').read_text(),'start\n')
        self.assertEqual((self.f.base/'transactions'/TOKEN/'state').read_text(),'recovery-required\n')
        self.assertTrue((self.f.base/'active').exists())
    def test_cid_mismatch_before_mutation(self):
        (self.f.p/'sys/block/mmcblk0/device/cid').write_text('f'*32)
        r=self.run_delete();self.assertNotEqual(r.returncode,0);self.assertIn(b'CID_MISMATCH',r.stderr);self.unchanged()
    def test_unrelated_firmware_and_router_absence_allows_owned_deletion(self):
        (self.f.p/'firmware/image/modem.b16').unlink();(self.f.p/'usr/bin/diag-router').unlink()
        r=self.run_delete();self.assertEqual(r.returncode,0,r.stderr.decode());self.assertFalse((self.f.base/'homes/admin').exists())
    def test_secondary_group_membership_not_silently_removed(self):
        p=self.f.etc/'group';p.write_text(p.read_text()+'external:x:123:admin\n')
        r=self.run_delete();self.assertNotEqual(r.returncode,0);self.assertIn(b'SECONDARY_GROUP_MEMBERSHIP',r.stderr)
        self.assertIn('external:x:123:admin',p.read_text());self.assertEqual((self.f.etc/'passwd').read_bytes(),self.before['passwd'])


class Services(unittest.TestCase):
    def setUp(self):
        self.f=Fixture();self.stage=self.f.p/('tmp/zte-access-'+TOKEN);self.stage.mkdir(mode=0o700)
        stat=self.f.bin/'stat';stat.write_text(stat.read_text().replace(".replace('%g','0')", ".replace('%g','0').replace('%h',str(os.stat(p).st_nlink)).replace('%s',str(os.stat(p).st_size))"))
        (self.f.p/'data/local/tmp').mkdir(parents=True);(self.f.p/'data/bin').mkdir();(self.f.p/'data/www').mkdir()
        lock=self.f.p/'tmp/zte-imei-app.lock';lock.mkdir(mode=0o700);(lock/'owner').write_text(LOCK)
        (self.f.p/'data/www/index.html').write_text('dashboard')
        (self.f.p/'data/zte-agent').write_bytes(b'agent');(self.f.p/'data/zte-agent').chmod(0o755)
        (self.f.p/'data/bin/dashboard-uhttpd').write_bytes(b'httpd')
        (self.f.p/'data/local/tmp/start_dashboard.sh').write_text('dashboard-launcher')
        (self.f.p/'data/local/tmp/stop_open_u60_listener.sh').write_text('stop-listener')
        (self.f.p/'data/zte-imei-studio').mkdir(mode=0o700)
        self.launcher=self.f.p/'data/zte-imei-studio/start_zte_agent.sh'
        self.launcher.write_text("#!/bin/sh\nexport ZTE_AGENT_PASSWORD='hidden value'\nunset ZTE_AGENT_PIN\ntrap '' HUP\nnohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &\n".replace('/data/',str(self.f.p/'data')+'/'))
        self.launcher.chmod(0o700)
        source=(ROOT/'Resources/SSHAccounts/access-services.sh').read_text()
        mapping=dict(self.f.mapping);mapping['/tmp/zte-access-']=str(self.f.p/'tmp/zte-access-');mapping['/tmp/zte-imei-app.lock']=str(lock)
        source=re.sub('|'.join(re.escape(k) for k in sorted(mapping,key=len,reverse=True)),lambda m:mapping[m.group(0)],source)
        source=source.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin','export PATH='+str(self.f.bin)+':/usr/bin:/bin').replace('kill -TERM "$pid"','mock-kill -TERM "$pid"')
        for expected,path in [('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263',self.f.p/'firmware/image/modem.b16'),('55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f',self.f.p/'usr/bin/diag-router'),('b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537',self.f.p/'data/zte-agent'),('76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12',self.f.p/'data/bin/dashboard-uhttpd'),('2f4c2b45dd6142fcc5b6b7aeaf5c0fc5923ba647f4cb3b95fe45e6b1f665c301',self.f.p/'data/local/tmp/start_dashboard.sh'),('82474a9f2ee061d105041986efb904c2cb0ee43353a7be94cd2ad18f450d9d08',self.f.p/'data/local/tmp/stop_open_u60_listener.sh')]:source=source.replace(expected,hashlib.sha256(path.read_bytes()).hexdigest())
        self.script=self.stage/'access-services.sh';self.script.write_text(source)
        self.f.write(self.f.bin/'sleep','#!/bin/sh\n/bin/sleep 0.02\n')
        self.f.write(self.f.bin/'readlink',f'''#!{shutil.which('python3')}
import os,sys
if sys.argv[1]=='-f':print(os.path.realpath(sys.argv[2]).replace({str(self.f.p.resolve())!r},{str(self.f.p)!r},1))
else:
 try:print(os.readlink(sys.argv[1]))
 except OSError:sys.exit(1)
''')
        helper=f'''#!{shutil.which('python3')}
import os,sys,pathlib,shutil
root=pathlib.Path({str(self.f.p)!r})
net=root/'proc/net/tcp'
if pathlib.Path(sys.argv[0]).name=='mock-kill':
 pid=sys.argv[-1];shutil.rmtree(root/'proc'/pid);net.write_text(''.join(x+'\\n' for x in net.read_text().splitlines() if not x.endswith(' '+pid)));sys.exit()
if pathlib.Path(sys.argv[0]).name=='nohup':
 pid='701';p=root/'proc'/pid;p.mkdir(exist_ok=True);(p/'fd').mkdir(exist_ok=True)
 (p/'exe').symlink_to(root/'data/bin/dashboard-uhttpd');(p/'fd/3').symlink_to('socket:[701]');(p/'cmdline').write_bytes(b'httpd\\0')
 (root/'dashboard-root-used').write_text(sys.argv[sys.argv.index('-h')+1])
 net.write_text(net.read_text()+'0: 00000000:1F90 00000000:0000 0A 0 0 0 0 0 701\\n');sys.exit()
if len(sys.argv)<2 or 'launcher.private.sh' not in sys.argv[1]:os.execv('/bin/sh',['sh']+sys.argv[1:])
pid='700';p=root/'proc'/pid;p.mkdir(exist_ok=True);(p/'fd').mkdir(exist_ok=True)
(p/'exe').symlink_to(root/'data/zte-agent');(p/'fd/3').symlink_to('socket:[700]');(p/'cmdline').write_bytes(b'agent\\0')
net.write_text(net.read_text()+'0: 00000000:2382 00000000:0000 0A 0 0 0 0 0 700\\n')
'''
        self.f.write(self.f.bin/'sh',helper);self.f.write(self.f.bin/'mock-kill',helper);self.f.write(self.f.bin/'nohup',helper)
        self.listen(600,'08AE','/data/bin/dropbear')
    def tearDown(self):self.f.close()
    def listen(self,pid,port,exe):
        p=self.f.p/'proc'/str(pid);p.mkdir(exist_ok=True);(p/'fd').mkdir(exist_ok=True)
        (p/'exe').symlink_to(str(self.f.p)+exe);(p/'fd/3').symlink_to('socket:['+str(pid)+']');(p/'cmdline').write_bytes(b'test\0')
        n=self.f.p/'proc/net/tcp';n.write_text(n.read_text()+'0: 00000000:'+port+' 00000000:0000 0A 0 0 0 0 0 '+str(pid)+'\n')
    def run_service(self,service=None,action='start'):
        args=['/bin/sh',str(self.script),'status' if service is None else 'action',CID,'192.168.0.1']
        if service is not None:args += [service,action,str(self.stage),LOCK]
        return subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
    def test_status_has_six_services_and_never_starts_agent(self):
        r=self.run_service();self.assertEqual(r.returncode,0,r.stderr.decode());self.assertEqual(r.stdout.count(b'ACCESS_SERVICE '),6)
        self.assertIn(b'ACCESS_SERVICE agent stopped control',r.stdout);self.assertFalse((self.f.p/'proc/700').exists())
    def test_absent_unrelated_firmware_files_keep_status_and_owned_action(self):
        (self.f.p/'firmware/image/modem.b16').unlink();(self.f.p/'usr/bin/diag-router').unlink()
        r=self.run_service();self.assertEqual(r.returncode,0,r.stderr.decode())
        r=self.run_service('agent','start');self.assertEqual(r.returncode,0,r.stderr.decode())
        self.assertIn(b'ACCESS_SERVICE agent running control',r.stdout)
    def test_management_channel_cannot_be_stopped(self):
        r=self.run_service('managementSSH','stop');self.assertNotEqual(r.returncode,0);self.assertIn(b'PROTECTED_SERVICE',r.stderr);self.assertTrue((self.f.p/'proc/600').exists())
    def test_agent_start_stop_and_restart_only_own_process(self):
        for action in ['start','restart','stop']:
            r=self.run_service('agent',action);self.assertEqual(r.returncode,0,r.stderr.decode())
            self.assertIn(('ACCESS_SERVICE agent '+('stopped' if action=='stop' else 'running')+' control').encode(),r.stdout)
            self.assertTrue((self.f.p/'proc/600').exists())
    def test_foreign_process_on_agent_port_is_read_only(self):
        self.listen(700,'2382','/usr/bin/foreign')
        r=self.run_service();self.assertIn(b'ACCESS_SERVICE agent unknown readonly',r.stdout)
        r=self.run_service('agent','stop');self.assertNotEqual(r.returncode,0);self.assertTrue((self.f.p/'proc/700').exists())
    def test_modified_agent_binary_disables_controls(self):
        (self.f.p/'data/zte-agent').write_bytes(b'foreign');r=self.run_service();self.assertIn(b'ACCESS_SERVICE agent stopped readonly',r.stdout)
    def test_arbitrary_launcher_command_not_executed(self):
        self.launcher.write_text(self.launcher.read_text()+'touch /tmp/unsafe\n')
        r=self.run_service('agent');self.assertNotEqual(r.returncode,0);self.assertFalse((self.f.p/'proc/700').exists())
    def test_single_quote_escape_password_is_accepted_without_printing(self):
        self.launcher.write_text(self.launcher.read_text().replace("'hidden value'","'hidden '\\''value'"))
        r=self.run_service();self.assertIn(b'ACCESS_SERVICE agent stopped control',r.stdout);self.assertNotIn(b'hidden',r.stdout+r.stderr)
    def test_current_bundled_hash_is_in_exact_service_registry(self):
        current=re.search(r'static let sha256 = "([a-f0-9]{64})"',(ROOT/'Sources/BundledAgent.swift').read_text())[1]
        prefix=self.script.read_text().split('mode=${1:-}')[0]
        r=subprocess.run(['/bin/sh','-c',prefix+'\nknown_agent_hash '+current],capture_output=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr.decode())
        r=subprocess.run(['/bin/sh','-c',prefix+'\nknown_agent_hash '+('0'*64)],capture_output=True,timeout=5)
        self.assertNotEqual(r.returncode,0)
    def test_discovery_startup_is_controllable_and_its_secret_is_never_output(self):
        self.launcher.write_text(self.launcher.read_text().replace('unset ZTE_AGENT_PIN',"export ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND='192.168.0.1:9090'\nunset ZTE_AGENT_PIN"))
        r=self.run_service();self.assertEqual(r.returncode,0,r.stderr.decode());self.assertIn(b'ACCESS_SERVICE agent stopped control',r.stdout)
        r=self.run_service('agent','start');self.assertEqual(r.returncode,0,r.stderr.decode());self.assertNotIn(b'hidden',r.stdout+r.stderr)
    def test_current_binding_and_legacy_cleared_startups_remain_controllable(self):
        original=self.launcher.read_text()
        for extra in ["export ZTE_AGENT_BIND='192.168.0.1:9090'\n", "unset ZTE_AGENT_MODE\nunset ZTE_AGENT_BIND\n", "unset ZTE_AGENT_MODE\nunset ZTE_AGENT_BIND\nexport ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND='192.168.0.1:9090'\n"]:
            self.launcher.write_text(original.replace('unset ZTE_AGENT_PIN',extra+'unset ZTE_AGENT_PIN'))
            r=self.run_service();self.assertEqual(r.returncode,0,r.stderr.decode());self.assertIn(b'ACCESS_SERVICE agent stopped control',r.stdout)
            self.assertNotIn(b'hidden',r.stdout+r.stderr)

    def test_malformed_discovery_or_unknown_environment_is_not_executed(self):
        original=self.launcher.read_text()
        extra="export ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND='192.168.0.1:9090'\n"
        valid=original.replace('unset ZTE_AGENT_PIN',extra+'unset ZTE_AGENT_PIN')
        for body in [valid.replace("'discovery'","'normal'"),valid.replace('192.168.0.1','192.168.00.1'),valid.replace(':9090',':9091'),
                     valid.replace('unset ZTE_AGENT_PIN',"export ZTE_AGENT_BIND='192.168.0.1:9090'\nunset ZTE_AGENT_PIN"),
                     original.replace('unset ZTE_AGENT_PIN',"export LD_PRELOAD='/tmp/foreign'\nunset ZTE_AGENT_PIN"),
                     original.replace("'hidden value'","''"),original.replace("'hidden value'","'hidden\tvalue'"),original.replace('\n','\r\n'),original+'#\0comment\n']:
            self.launcher.write_text(body);r=self.run_service('agent','start');self.assertNotEqual(r.returncode,0);self.assertFalse((self.f.p/'proc/700').exists());self.assertNotIn(b'hidden',r.stdout+r.stderr)
    def test_agent_startup_requires_private_single_link_and_executable_binary(self):
        self.launcher.chmod(0o644);r=self.run_service('agent');self.assertNotEqual(r.returncode,0)
        self.launcher.chmod(0o700);link=self.launcher.with_name('extra-link');os.link(self.launcher,link)
        r=self.run_service('agent');self.assertNotEqual(r.returncode,0);link.unlink()
        (self.f.p/'data/zte-agent').chmod(0o600);r=self.run_service('agent');self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.f.p/'proc/700').exists())
    def test_password_command_substitution_outside_quotes_refused(self):
        self.launcher.write_text(self.launcher.read_text().replace("'hidden value'","'hidden'$(touch /tmp/unsafe)'value'"))
        r=self.run_service();self.assertIn(b'ACCESS_SERVICE agent stopped readonly',r.stdout)
    def test_world_writable_binary_parent_disables_dashboard_control(self):
        (self.f.p/'data/bin').chmod(0o777);r=self.run_service();self.assertIn(b'ACCESS_SERVICE dashboard stopped readonly',r.stdout)
    def test_current_release_dashboard_is_controllable_and_restart_uses_selected_root(self):
        root=self.f.p/'data/open-u60-agent-releases/2.4.1-ru-ttl.1/dashboard'
        root.mkdir(parents=True);(root/'index.html').write_text('current release')
        (self.f.p/'data/www.current').symlink_to(root)
        self.listen(701,'1F90','/data/bin/dashboard-uhttpd')
        r=self.run_service();self.assertIn(b'ACCESS_SERVICE dashboard running control',r.stdout)
        r=self.run_service('dashboard','restart');self.assertEqual(r.returncode,0,r.stderr.decode())
        self.assertIn(b'ACCESS_SERVICE dashboard running control',r.stdout)
        self.assertEqual((self.f.p/'dashboard-root-used').read_text(),str(root))
        self.assertTrue((self.f.p/'proc/600').exists())
    def test_unknown_dashboard_root_refuses_restart_before_stopping_listener(self):
        root=self.f.p/'data/unverified';root.mkdir();(root/'index.html').write_text('foreign')
        (self.f.p/'data/www.current').symlink_to(root)
        self.listen(701,'1F90','/data/bin/dashboard-uhttpd')
        r=self.run_service();self.assertIn(b'ACCESS_SERVICE dashboard running readonly',r.stdout)
        r=self.run_service('dashboard','restart');self.assertNotEqual(r.returncode,0)
        self.assertIn(b'UNVERIFIED_SERVICE',r.stderr);self.assertTrue((self.f.p/'proc/701').exists())
        self.assertFalse((self.f.p/'dashboard-root-used').exists())
    def test_unsafe_release_parent_and_missing_index_disable_dashboard_control(self):
        root=self.f.p/'data/open-u60-agent-releases/2.4.1-ru-ttl.1/dashboard'
        root.mkdir(parents=True);(root/'index.html').write_text('current release')
        (self.f.p/'data/www.current').symlink_to(root)
        root.parent.chmod(0o777)
        self.assertIn(b'ACCESS_SERVICE dashboard stopped readonly',self.run_service().stdout)
        root.parent.chmod(0o755);(root/'index.html').unlink()
        self.assertIn(b'ACCESS_SERVICE dashboard stopped readonly',self.run_service().stdout)
    def test_missing_management_listener_refuses_mutation(self):
        (self.f.p/'proc/net/tcp').write_text('');r=self.run_service('agent');self.assertNotEqual(r.returncode,0);self.assertIn(b'MANAGEMENT_CHANNEL',r.stderr)
    def test_private_or_legacy_install_transaction_refuses_service_change(self):
        for relative in ('data/zte-imei-studio/installations/active','data/local/tmp/zte-imei-installations/active'):
            with self.subTest(relative=relative):
                marker=self.f.p/relative;marker.parent.mkdir(parents=True,exist_ok=True);marker.write_text(TOKEN)
                result=self.run_service('agent')
                self.assertNotEqual(result.returncode,0);self.assertIn(b'OTHER_TRANSACTION',result.stderr)
                self.assertFalse((self.f.p/'proc/700').exists());marker.unlink()

    def test_unsafe_new_anchor_disables_agent_control(self):
        (self.f.p/'data/zte-imei-studio').chmod(0o777)
        self.assertIn(b'ACCESS_SERVICE agent stopped readonly',self.run_service().stdout)

    def test_active_account_transaction_refuses_service_change(self):
        self.f.base.mkdir();(self.f.base/'active').write_text(TOKEN)
        r=self.run_service('agent');self.assertNotEqual(r.returncode,0);self.assertIn(b'OTHER_TRANSACTION',r.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
