#!/usr/bin/env python3
"""Host-only mock filesystem tests; never invokes adb, SSH, or a modem.

Production scripts contain no environment bypass. For this test only, absolute
device paths are replaced in an in-memory copy and system commands are mocked.
"""
from pathlib import Path
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest

RES = Path(__file__).resolve().parents[1] / 'Resources/Onboarding'
BOOT = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
CID = '0123456789abcdef0123456789abcdef'
TOKEN = '11111111-2222-3333-4444-555555555555'
FIRMWARE = '604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263'
B02_FIRMWARE = '7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e'
TIMEOUT_SHA = '6e81024c273080294a251ae38572f1ef0cb496fbd16c7009c6a4ae1c07fb55ff'
ROUTER = '55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zte-onboarding-test-')
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / 'mock-bin'
        self.bin.mkdir()
        self.stage = self.root / f'data/zte-imei-studio/stage-{TOKEN}'
        self.stage.mkdir(parents=True)
        self.stage.chmod(0o700); self.stage.parent.chmod(0o700)
        self.journal = self.root / f'data/zte-imei-studio/installations/{TOKEN}'
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin', MOCK_ROOT=str(self.root))
        self.write('/etc/rc.local', '#!/bin/sh\necho 1 > /sys/class/android_usb/android0/usb_op\n# preserved\nexit 0\n', 0o751)
        self.write('/sys/block/mmcblk0/device/cid', CID + '\n')
        self.write('/proc/net/tcp', '  0: 00000000:08AE 00000000:0000 0A 0 0 0 0 0 4242\n')
        self.write('/proc/net/tcp6', '')
        fd=self.root/'proc/5678/fd';fd.mkdir(parents=True)
        (fd/'3').symlink_to('socket:[4242]')
        self.write('/proc/self/mountinfo', f'1 0 8:1 / / ro - ext4 /dev/root ro\n2 1 8:2 / {self.root}/data rw - ext4 /dev/userdata rw\n3 1 0:1 / {self.root}/etc rw - overlay overlay rw\n')
        self.write('/firmware/image/modem.b16', 'firmware')
        self.write('/usr/bin/diag-router', 'router')
        self.write('/usr/bin/curl', '#!/bin/sh\nexit 0\n',0o700)
        (self.root/'var/run').mkdir(parents=True)
        self.command('id', '#!/bin/sh\necho 0\n')
        self.command('uname', '#!/bin/sh\nif [ \"$1\" = -s ]; then echo Linux; else echo aarch64; fi\n')
        self.command('sync', '#!/bin/sh\nexit 0\n')
        self.command('ubus', '#!/bin/sh\nexit 0\n')
        self.command('sleep', '#!/bin/sh\nexit 0\n')
        self.command('mock-kill', '#!/bin/sh\nprintf "%s %s\\n" "$1" "$2" >> "$MOCK_ROOT/signals"\n[ "$2" = 1234 ] || exit 7\nrm -f "$MOCK_ROOT/running"\n')
        self.command('df', '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 200000 0 200000 0 /\\n"\n')
        self.command('pidof', '#!/bin/sh\nif [ "$1" = dropbear ]; then [ -f "$MOCK_ROOT/data/zte-imei-studio/bin/dropbear" ] || exit 1; echo 5678; else [ -f "$MOCK_ROOT/running" ] || exit 1; echo 1234; fi\n')
        self.command('readlink', '#!/bin/sh\ncase "$1" in */proc/1234/exe) printf "%s/data/zte-agent\\n" "$MOCK_ROOT";; */proc/5678/exe) printf "%s/data/zte-imei-studio/bin/dropbear\\n" "$MOCK_ROOT";; *) exec /usr/bin/readlink "$@";; esac\n')
        self.command('stat', f'''#!{shutil.which('python3')}
import os,stat,sys
args=[a for a in sys.argv[1:] if a != '-L'];field=args[1];path=args[2]
if path.endswith('/proc/1234/exe'):path=os.environ['MOCK_ROOT']+'/data/zte-agent'
if path.endswith('/proc/5678/exe'):path=os.environ['MOCK_ROOT']+'/data/zte-imei-studio/bin/dropbear'
value=os.fstat(9) if path.endswith('/proc/self/fd/9') else os.stat(path); mode=oct(stat.S_IMODE(value.st_mode))[2:]
if field=='%u': print(0)
elif field=='%a': print(mode)
elif field=='%s': print(value.st_size)
elif field=='%u:%a': print('0:'+mode)
elif field=='%u:%h': print('0:'+str(value.st_nlink))
elif field=='%d:%i:%u:%a:%h': print(str(value.st_dev)+':'+str(value.st_ino)+':0:'+mode+':'+str(value.st_nlink))
else: sys.exit(1)
''')
        self.command('sha256sum', f'''#!{shutil.which('python3')}
from pathlib import Path
import hashlib,sys,os
def h(p):
 if p.endswith('/proc/1234/exe'):
  saved=Path(os.environ['MOCK_ROOT'])/'running-hash'
  return saved.read_text().strip() if saved.exists() else h(os.environ['MOCK_ROOT']+'/data/zte-agent')
 if p.endswith('/proc/5678/exe'): return h(os.environ['MOCK_ROOT']+'/data/zte-imei-studio/bin/dropbear')
 if p.endswith('/before/data_zte-agent') and os.environ.get('MOCK_AGENT_START_ON_SNAPSHOT'):
  (Path(os.environ['MOCK_ROOT'])/'running').touch()
 if p.endswith('/firmware/image/modem.b16'):
  if os.environ.get('MOCK_FIRMWARE_CHANGE_AFTER'):
   count=Path(os.environ['MOCK_ROOT'])/'firmware-read-count'
   reads=int(count.read_text())+1 if count.exists() else 1
   count.write_text(str(reads))
   if reads>int(os.environ['MOCK_FIRMWARE_CHANGE_AFTER']):return 'e'*64
  return os.environ.get('MOCK_FIRMWARE','{FIRMWARE}')
 if p.endswith('/usr/bin/diag-router'): return os.environ.get('MOCK_ROUTER','{ROUTER}')
 if p.endswith('/zte-timeout'): return os.environ.get('MOCK_TIMEOUT_SHA','{TIMEOUT_SHA}')
 return hashlib.sha256(Path(p).read_bytes()).hexdigest()
if sys.argv[1]=='-c':
 for line in Path(sys.argv[2]).read_text().splitlines():
  expected,path=line.split(None,1)
  if h(path)!=expected: sys.exit(1)
else:
 for path in sys.argv[1:]: print(h(path)+'  '+path)
''')
        for name in ['setup-agent.sh', 'start_zte_imei_studio.sh']:
            text = (RES / name).read_text()
            text = re.sub(r'(?<![A-Za-z0-9_/])/(data|etc|proc|sys|firmware|tmp)(?=/|[\s\"\'])', lambda m: str(self.root) + m.group(0), text)
            for prefix in ['/usr/bin/diag-router','/usr/bin/curl','/var/run']:
                text = text.replace(prefix, str(self.root) + prefix)
            text = text.replace('"/$target"', '"' + str(self.root) + '/$target"')
            text = text.replace('restore_temporary=/$target.', 'restore_temporary='+str(self.root)+'/$target.')
            text = text.replace('kill -TERM "$process"', 'mock-kill TERM "$process"').replace('kill -KILL "$process"', 'mock-kill KILL "$process"')
            (self.stage / name).write_text(text)
            if name == 'setup-agent.sh': self.script_text = text
        (self.stage / 'zte-agent').write_text('#!/bin/sh\nexit 0\n')
        (self.stage / 'dropbear').write_text('''#!/bin/sh
case "$1" in
 -t) printf 'mock host key\n' > "$4";;
 -y) grep -q 'mock host key' "$3" || exit 1; printf 'ssh-ed25519 AAAA mock\n';;
 *) exit 0;;
esac
''')
        (self.stage / 'id_ed25519.pub').write_text('ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAAIGenericTestKey test\n')
        (self.stage / 'start-agent.sh').write_text('#!/bin/sh\ntouch "$MOCK_ROOT/running"\n')

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, text, mode=0o600):
        p = self.root / path.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        anchor=self.root/'data/zte-imei-studio'
        if p.is_relative_to(anchor):
            parent=p.parent
            while parent != anchor.parent:
                parent.chmod(0o700);parent=parent.parent
        p.write_text(text)
        p.chmod(mode)
        return p

    def command(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o700)

    def run_setup(self, cid=CID, agent_hash=None, profile=None, firmware=None, router=ROUTER, boot=None, force=False):
        args = [str(self.stage), cid, agent_hash or digest(self.stage/'zte-agent'), digest(self.stage/'dropbear'), digest(self.stage/'id_ed25519.pub')]
        if profile is not None: args.extend([profile, firmware or FIRMWARE, router])
        if boot is not None: args.append(boot)
        if force: args.insert(0,'--reinstall')
        return subprocess.run(['/bin/sh', str(self.stage/'setup-agent.sh'), *args], env=self.env, capture_output=True, text=True)

    def commit(self, profile=None, firmware=None, router=ROUTER, boot=None):
        args=['--commit', str(self.journal), CID]
        if profile is not None: args.extend([profile,firmware or FIRMWARE,router])
        if boot is not None: args.append(boot)
        return subprocess.run(['/bin/sh', str(self.stage/'setup-agent.sh'), *args], env=self.env, capture_output=True, text=True)

    def preflight(self, cid=CID, profile='b31', firmware=FIRMWARE, router=ROUTER, boot=None, force=False):
        args=['/bin/sh','-c',self.script_text,'--','--preflight',cid,profile,firmware,router]
        if boot is not None: args.append(boot)
        if force:args.insert(4,'--reinstall')
        return subprocess.run(args,env=self.env,capture_output=True,text=True)

    def forced_existing(self, running=True):
        self.owner()
        marker=self.stage/'.install-requested';marker.write_bytes((self.stage/'.owner').read_bytes());marker.chmod(0o600)
        old=self.write('/data/zte-agent','#!/bin/sh\n# old running binary\n',0o700)
        oldhash=digest(old);newhash=digest(self.stage/'zte-agent')
        self.write('/data/zte-imei-studio/start_zte_agent.sh',f'#!/bin/sh\nprintf "{oldhash}\\n" > "$MOCK_ROOT/running-hash"\ntouch "$MOCK_ROOT/running"\n',0o700)
        (self.stage/'start-agent.sh').write_text(f'#!/bin/sh\n# supplied new credentials\nprintf "{newhash}\\n" > "$MOCK_ROOT/running-hash"\ntouch "$MOCK_ROOT/running"\n')
        for name in ('dropbear','dropbearkey'):
            self.write('/data/zte-imei-studio/bin/'+name,(self.stage/'dropbear').read_text(),0o700)
        self.write('/etc/dropbear/dropbear_ed25519_host_key','mock host key\n')
        self.write('/etc/dropbear/dropbear_rsa_host_key','mock host key\n')
        self.write('/etc/dropbear/authorized_keys','ssh-ed25519 AAAA preserved\n')
        self.write('/proc/1234/stat','1234 (zte-agent) '+' '.join(['S']+['0']*18+['777'])+'\n')
        self.write('/running-hash',oldhash+'\n')
        for p in self.stage.iterdir():p.chmod(0o600)
        if running:self.write('/running','yes')
        return oldhash,newhash

    def verify_rollback(self):
        return subprocess.run(['/bin/sh','-c',self.script_text,'--','--verify-rollback',str(self.journal),CID,'b31',FIRMWARE,ROUTER],env=self.env,capture_output=True,text=True)

    def test_force_replaces_agent_password_but_reuses_ssh_inode_and_keys(self):
        oldhash,newhash=self.forced_existing()
        helper=self.root/'data/zte-imei-studio/bin/dropbear';inode=helper.stat().st_ino
        keys={p:p.read_bytes() for p in (self.root/'etc/dropbear').iterdir()}
        startup=self.root/'data/zte-imei-studio/start_zte_agent.sh';oldstartup=startup.read_bytes()
        result=self.run_setup(profile='b31',force=True);self.assert_success(result)
        self.assertIn('INSTALL_AGENT new',result.stdout);self.assertEqual(digest(self.root/'data/zte-agent'),newhash)
        self.assertEqual(startup.read_bytes(),(self.stage/'start-agent.sh').read_bytes())
        self.assertEqual((self.journal/'before/data_zte-imei-studio_start_zte_agent.sh').read_bytes(),oldstartup)
        self.assertEqual(helper.stat().st_ino,inode)
        for p,b in keys.items():
            if p.name!='authorized_keys':self.assertEqual(p.read_bytes(),b)
        self.assertEqual((self.root/'signals').read_text(),'TERM 1234\n');self.assert_success(self.commit(profile='b31'))

    def test_force_foreign_mapped_agent_refuses_before_snapshot_and_signal(self):
        self.forced_existing();self.write('/running-hash','f'*64+'\n')
        result=self.run_setup(profile='b31',force=True)
        self.assertIn('EXISTING_AGENT_PROCESS',result.stderr);self.assertFalse(self.journal.exists());self.assertFalse((self.root/'signals').exists())

    def test_force_start_failure_rolls_back_all_targets_and_verifies_for_retry(self):
        oldhash,_=self.forced_existing()
        helper=self.root/'data/zte-imei-studio/bin/dropbear';inode=helper.stat().st_ino
        (self.stage/'start-agent.sh').write_text('#!/bin/sh\nexit 9\n')
        result=self.run_setup(profile='b31',force=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('INSTALL_ROLLED_BACK',result.stderr)
        self.assertEqual(digest(self.root/'data/zte-agent'),oldhash);self.assertEqual(helper.stat().st_ino,inode)
        self.assertEqual((self.journal/'state').read_text(),'rolled-back\n');self.assertFalse((self.journal.parent/'active').exists())
        self.assertFalse(self.stage.exists(),'Confirmed rollback must remove its private staged password')
        verified=self.verify_rollback();self.assert_success(verified);self.assertEqual(verified.stdout.strip(),'INSTALL_ROLLBACK_VERIFIED '+str(self.journal))
        self.write('/etc/rc.local','#!/bin/sh\n# foreign change\n')
        self.assertIn('ROLLBACK_UNVERIFIED',self.verify_rollback().stderr)

    def test_force_unknown_new_process_preserves_pending_and_never_kills_foreign(self):
        self.forced_existing()
        (self.stage/'start-agent.sh').write_text('#!/bin/sh\nprintf "'+('f'*64)+'\\n" > "$MOCK_ROOT/running-hash"\ntouch "$MOCK_ROOT/running"\n')
        result=self.run_setup(profile='b31',force=True)
        self.assertIn('INSTALL_ROLLBACK_UNKNOWN',result.stderr);self.assertTrue((self.journal.parent/'active').exists())
        self.assertEqual((self.root/'signals').read_text(),'TERM 1234\n');self.assertNotEqual(self.verify_rollback().returncode,0)

    def test_force_pending_transaction_is_never_replayed(self):
        self.forced_existing();self.write('/data/zte-imei-studio/installations/active','another\n')
        result=self.run_setup(profile='b31',force=True)
        self.assertIn('RECOVERY_PENDING',result.stderr);self.assertFalse((self.root/'signals').exists())

    def old_stage(self,suffix='66666666-2222-3333-4444-555555555555',completed=False):
        stage=self.root/('data/zte-imei-studio/stage-'+suffix);stage.mkdir(mode=0o700)
        owner=f'{suffix} {CID} b31 {FIRMWARE} {ROUTER}\n'
        for name,text in [('.owner',owner),('start-agent.sh','#!/bin/sh\n# private temporary\n')]:
            p=stage/name;p.write_text(text);p.chmod(0o600)
        if completed:
            p=stage/'.install-requested';p.write_text(owner);p.chmod(0o600)
            for name,text in [('cid',CID+'\n'),('state','complete\n')]:self.write('/data/zte-imei-studio/installations/'+suffix+'/'+name,text)
        return stage

    def test_force_cleanup_only_completed_retains_possibly_uploading_stage(self):
        self.forced_existing();old=self.old_stage();completed=self.old_stage('77777777-2222-3333-4444-555555555555',True)
        self.assert_success(self.preflight());self.assertTrue(old.exists());self.assertTrue(completed.exists())
        self.assert_success(self.run_setup(profile='b31',force=True));self.assertTrue(old.exists());self.assertTrue(completed.exists())
        result=self.commit(profile='b31');self.assert_success(result);self.assertIn('INSTALL_CLEANUP removed=1 retained=1',result.stdout)
        self.assertTrue(old.exists());self.assertFalse(completed.exists());self.assertTrue(self.stage.exists())
        self.assertTrue((self.journal.parent/'77777777-2222-3333-4444-555555555555/state').exists())

    def test_force_cleanup_completed_incoming_uuid_only(self):
        self.forced_existing()
        safe=self.old_stage(completed=True)
        p=safe/'incoming-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';p.write_text('private staged upload');p.chmod(0o600)
        invalid=self.old_stage('77777777-2222-3333-4444-555555555555',True)
        p=invalid/'incoming-not-a-uuid';p.write_text('must retain');p.chmod(0o600)
        self.assert_success(self.run_setup(profile='b31',force=True));result=self.commit(profile='b31');self.assert_success(result)
        self.assertIn('INSTALL_CLEANUP removed=1 retained=1',result.stdout)
        self.assertFalse(safe.exists());self.assertTrue(invalid.exists())

    def test_force_cleanup_retains_unknown_files_foreign_owner_and_pending(self):
        self.forced_existing();unknown=self.old_stage();(unknown/'user-data').write_text('must retain')
        foreign=self.old_stage('77777777-2222-3333-4444-555555555555');(foreign/'.owner').write_text((foreign/'.owner').read_text().replace(CID,'f'*32))
        pending=self.old_stage('88888888-2222-3333-4444-555555555555',True)
        (self.journal.parent/'88888888-2222-3333-4444-555555555555/state').write_text('ready\n')
        self.assert_success(self.run_setup(profile='b31',force=True));result=self.commit(profile='b31');self.assert_success(result)
        self.assertIn('INSTALL_CLEANUP removed=0 retained=3',result.stdout)
        self.assertTrue((unknown/'start-agent.sh').exists());self.assertTrue(foreign.exists());self.assertTrue(pending.exists())

    def test_force_corrupt_prior_running_enum_cannot_verify_rollback(self):
        self.forced_existing(running=False);(self.stage/'start-agent.sh').write_text('#!/bin/sh\nexit 9\n')
        result=self.run_setup(profile='b31',force=True);self.assertIn('INSTALL_ROLLED_BACK',result.stderr)
        self.assert_success(self.verify_rollback())
        (self.journal/'agent-was-running').write_text('unknown\n')
        self.assertIn('ROLLBACK_UNVERIFIED',self.verify_rollback().stderr)

    def test_completed_commit_releases_only_matching_stale_owner(self):
        self.assert_success(self.run_setup());(self.journal/'state').write_text('complete\n')
        self.assert_success(self.commit());self.assertFalse((self.journal.parent/'active').exists());self.assertFalse((self.journal.parent/'lock').exists())
        self.assert_success(self.commit())

    def test_completed_commit_refuses_foreign_lock_without_removing_it(self):
        self.assert_success(self.run_setup());(self.journal/'state').write_text('complete\n')
        (self.journal.parent/'lock/owner').write_text('foreign\n')
        result=self.commit();self.assertIn('JOURNAL_OWNER',result.stderr)
        self.assertTrue((self.journal.parent/'active').exists());self.assertEqual((self.journal.parent/'lock/owner').read_text(),'foreign\n')

    def test_only_forced_preflight_reconciles_complete_owned_transaction(self):
        self.forced_existing();self.assert_success(self.run_setup(profile='b31',force=True));(self.journal/'state').write_text('complete\n')
        self.assertIn('RECOVERY_PENDING',self.preflight().stderr);self.assertTrue((self.journal.parent/'active').exists())
        result=self.preflight(force=True);self.assert_success(result)
        self.assertEqual(result.stdout.strip(),'INSTALL_PREFLIGHT b31 imei_config=unknown');self.assertIn('INSTALL_COMPLETED_OWNER_CLEARED',result.stderr)
        self.assertFalse((self.journal.parent/'active').exists());self.assertFalse((self.journal.parent/'lock').exists())

    def test_forced_preflight_keeps_changed_completed_transaction(self):
        self.forced_existing();self.assert_success(self.run_setup(profile='b31',force=True));(self.journal/'state').write_text('complete\n')
        self.write('/etc/rc.local','#!/bin/sh\n# changed outside installer\n')
        self.assertIn('RECOVERY_PENDING',self.preflight(force=True).stderr);self.assertTrue((self.journal.parent/'active').exists())

    def owner(self, profile='b31', firmware=FIRMWARE, router=ROUTER, boot=None):
        p=self.stage/'.owner';p.write_text(f'{TOKEN} {CID} {profile} {firmware} {router}'+(' '+boot if boot else '')+'\n');p.chmod(0o600)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def generic(self, absent=False):
        self.env['MOCK_FIRMWARE']='a'*64
        self.env['MOCK_ROUTER']='b'*64
        self.write('/proc/sys/kernel/random/boot_id',BOOT+'\n')
        self.write('/proc/1/comm','procd\n')
        self.write('/proc/1234/environ','ZTE_AGENT_MODE=discovery\0')
        self.write('/etc/init.d/done',f'#!/bin/sh\nsh {self.root}/etc/rc.local\n',0o700)
        # Mock only the ELF header inspection and pinned Dropbear's -V entry.
        self.command('od','#!/bin/sh\necho 7f454c460201010000000000000000000200b700\n')
        (self.stage/'zte-timeout').write_text('#!/bin/sh\nshift; exec "$@"\n')
        (self.stage/'zte-timeout').chmod(0o600)
        # Host staging keeps payloads private/non-executable until the installer
        # validates their type, identity and ELF header.
        (self.stage/'dropbear').chmod(0o600)
        (self.stage/'zte-agent').chmod(0o600)
        (self.stage/'start-agent.sh').write_text("#!/bin/sh\nexport ZTE_AGENT_MODE='discovery'\ntouch \"$MOCK_ROOT/running\"\n")
        if absent:
            (self.root/'usr/bin/diag-router').unlink()
        router='absent' if absent else 'b'*64
        self.owner('linux-arm64-access','a'*64,router,BOOT)
        return dict(profile='linux-arm64-access',firmware='a'*64,router=router,boot=BOOT)

    def test_generic_fresh_layout_without_local_dirs_and_sticky_tmp_preflights(self):
        args=self.generic()
        self.write('/etc/rc.local','#!/bin/sh\nexit 0\n',0o775)
        (self.root/'tmp').mkdir(exist_ok=True);(self.root/'tmp').chmod(0o1777)
        # Observed shape only: all identities and file contents are synthetic.
        shutil.rmtree(self.root/'data/local',ignore_errors=True)
        for name in ('bin','dropbear'):
            self.assertFalse((self.root/'data'/name).exists())
        result=self.preflight(**args)
        self.assert_success(result)
        self.assertEqual(result.stdout.strip(),'INSTALL_PREFLIGHT linux-arm64-access imei_config=unknown')
        self.assertFalse((self.root/'data/local').exists(),'Read-only preflight created directories')

    def test_generic_missing_native_timeout_uses_pinned_stage_supervisor(self):
        args=self.generic()
        # /bin/sh is a real native shell; no command named timeout is installed.
        self.assertNotIn('timeout', [p.name for p in self.bin.iterdir()])
        self.assert_success(self.preflight(**args))
        self.assert_success(self.run_setup(**args))
        self.assertEqual((self.stage/'zte-timeout').stat().st_mode & 0o777,0o700)

    def test_generic_private_payload_modes_allow_bounded_runtime_checks(self):
        args=self.generic()
        for name in ('dropbear','zte-agent','zte-timeout'):
            self.assertEqual((self.stage/name).stat().st_mode & 0o777,0o600)
        self.assert_success(self.run_setup(**args))
        for name in ('dropbear','zte-agent','zte-timeout'):
            self.assertEqual((self.stage/name).stat().st_mode & 0o777,0o700)
        self.assertEqual((self.stage/'id_ed25519.pub').stat().st_mode & 0o111,0)

    def test_generic_payload_hash_failure_precedes_execute_permission(self):
        args=self.generic()
        result=self.run_setup(agent_hash='f'*64,**args)
        self.assertIn('AGENT_HASH',result.stderr)
        for name in ('dropbear','zte-agent'):
            self.assertEqual((self.stage/name).stat().st_mode & 0o777,0o600)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_hardlinked_runtime_payload_never_changes_alias_mode(self):
        for name in ('dropbear','zte-agent'):
            with self.subTest(name=name):
                args=self.generic(); alias=self.stage/'payload-alias'
                os.link(self.stage/name,alias)
                try:
                    result=self.run_setup(**args)
                    self.assertIn('PAYLOAD_TYPE',result.stderr)
                    self.assertEqual(alias.stat().st_mode & 0o777,0o600)
                    self.assertFalse(self.journal.parent.exists())
                finally: alias.unlink()

    def test_generic_unverified_timeout_refused_before_journal_or_install(self):
        for kind in ('missing','hash','symlink','hardlink'):
            with self.subTest(kind=kind):
                args=self.generic(); helper=self.stage/'zte-timeout'
                self.env.pop('MOCK_TIMEOUT_SHA',None)
                if kind=='missing': helper.unlink()
                elif kind=='hash':self.env['MOCK_TIMEOUT_SHA']='f'*64
                elif kind=='symlink':helper.unlink();helper.symlink_to(self.stage/'dropbear')
                elif kind=='hardlink':os.link(helper,self.stage/'linked-timeout')
                result=self.run_setup(**args)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('TIMEOUT_',result.stderr)
                self.assertFalse(self.journal.parent.exists())
                self.assertFalse((self.root/'data/zte-agent').exists())
                if helper.exists() or helper.is_symlink():helper.unlink()
                (self.stage/'linked-timeout').unlink(missing_ok=True)

    def test_generic_unknown_firmware_installs_discovery_transaction(self):
        args=self.generic()
        self.assert_success(self.preflight(**args))
        self.assertFalse(self.journal.parent.exists())
        self.assert_success(self.run_setup(**args))
        self.assertEqual((self.journal/'profile.identity').read_text(),f"linux-arm64-access {'a'*64} {'b'*64} {BOOT}\n")
        self.assertIn("export ZTE_AGENT_MODE='discovery'",(self.root/'data/zte-imei-studio/start_zte_agent.sh').read_text())
        self.assert_success(self.commit(**args))

    def test_generic_no_diag_router_can_install_access_only(self):
        args=self.generic(absent=True)
        self.assert_success(self.preflight(**args))
        self.assert_success(self.run_setup(**args))
        self.assert_success(self.commit(**args))

    def test_generic_cannot_certify_existing_object_as_absent(self):
        args=self.generic();args['router']='absent'
        self.assertIn('ROUTER_MISMATCH',self.preflight(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_boot_change_blocks_install_and_commit(self):
        args=self.generic()
        self.write('/proc/sys/kernel/random/boot_id','ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.assertIn('BOOT_MISMATCH',self.run_setup(**args).stderr)
        self.assertFalse(self.journal.parent.exists())
        self.write('/proc/sys/kernel/random/boot_id',BOOT+'\n')
        self.assert_success(self.run_setup(**args))
        self.write('/proc/sys/kernel/random/boot_id','ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.assertIn('BOOT_MISMATCH',self.commit(**args).stderr)
        self.assertEqual((self.journal/'state').read_text().strip(),'ready')

    def test_generic_unassessed_boot_hook_blocks_before_mutation(self):
        args=self.generic();self.write('/proc/1/comm','systemd\n')
        self.assertIn('STARTUP_NOT_ASSESSED',self.preflight(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_existing_normal_agent_requires_review(self):
        args=self.generic()
        agent=self.write('/data/zte-agent','original',0o700)
        self.write('/data/zte-imei-studio/start_zte_agent.sh','#!/bin/sh\n# normal\n',0o700)
        result=self.run_setup(**args)
        self.assertIn('DISCOVERY_STARTUP_REQUIRED',result.stderr)
        self.assertEqual(agent.read_text(),'original')
        self.assertFalse(self.journal.parent.exists())

    def test_generic_running_normal_agent_is_not_started_or_replaced(self):
        args=self.generic()
        self.write('/data/zte-agent',(self.stage/'zte-agent').read_text(),0o700)
        self.write('/data/zte-imei-studio/start_zte_agent.sh',(self.stage/'start-agent.sh').read_text(),0o700)
        self.write('/running','yes')
        self.write('/proc/1234/environ','ZTE_AGENT_MODE=normal\0')
        self.assertIn('EXISTING_AGENT_REVIEW_REQUIRED',self.run_setup(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_unpinned_preserved_helper_blocks_before_mutation(self):
        args=self.generic()
        original=self.write('/data/zte-imei-studio/bin/dropbearkey','#!/bin/sh\n# arbitrary existing helper\n',0o700)
        self.assertIn('EXISTING_DROPBEAR_REVIEW_REQUIRED',self.run_setup(**args).stderr)
        self.assertEqual(original.read_text(),'#!/bin/sh\n# arbitrary existing helper\n')
        self.assertFalse(self.journal.parent.exists())

    def test_generic_pinned_agent_runtime_failure_blocks_before_mutation(self):
        args=self.generic();(self.stage/'zte-agent').write_text('#!/bin/sh\nexit 1\n')
        self.assertIn('AGENT_ABI',self.run_setup(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_elf_mismatch_blocks_before_mutation(self):
        args=self.generic();self.command('od','#!/bin/sh\necho 7f454c4601010100000000000000000002002800\n')
        self.assertIn('PAYLOAD_ABI',self.run_setup(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_profile_cannot_override_mode_guards_with_colon(self):
        args=self.generic();args['profile']='linux-arm64-access:extra'
        self.assertIn('UNSUPPORTED_PROFILE',self.preflight(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_unknown_boot_and_symlink_never_authorise(self):
        args=self.generic();args['boot']='not-assessed'
        self.assertIn('BOOT_FORMAT',self.preflight(**args).stderr)
        args['boot']=BOOT
        p=self.root/'usr/bin/diag-router';p.unlink();p.symlink_to(self.root/'firmware/image/modem.b16')
        self.assertIn('IDENTITY_UNREADABLE',self.preflight(**args).stderr)
        args['router']='absent'
        self.assertIn('ROUTER_MISMATCH',self.preflight(**args).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_fresh_setup_snapshot_commit_preserves_rc(self):
        original = (self.root/'etc/rc.local').read_bytes()
        self.assert_success(self.run_setup())
        self.assertEqual((self.journal/'before/etc_rc.local').read_bytes(), original)
        rc = (self.root/'etc/rc.local').read_text()
        self.assertIn('echo 1 > /sys/', rc)
        self.assertEqual((self.root/'etc/rc.local').stat().st_mode & 0o777, 0o751)
        self.assertEqual(rc.count('start_zte_imei_studio.sh'), 1)
        self.assertLess(rc.index('start_zte_imei_studio.sh'), rc.index('exit 0'))
        self.assertEqual((self.journal/'state').read_text().strip(), 'ready')
        self.assert_success(self.commit())
        self.assertEqual((self.journal/'state').read_text().strip(), 'complete')
        self.assertFalse((self.journal.parent/'active').exists())
        self.assert_success(self.commit())

    def test_wrong_identity_before_install_mutations(self):
        result = self.run_setup(cid='f'*32)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CID_MISMATCH', result.stderr)
        self.assertFalse(self.journal.parent.exists())
        self.assertFalse((self.root/'data/zte-agent').exists())

    def test_wrong_payload_hash_before_install_mutations(self):
        result = self.run_setup(agent_hash='0'*64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AGENT_HASH', result.stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_pending_recovery_blocks(self):
        self.write('/data/zte-imei-studio/installations/active', 'earlier\n')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RECOVERY_PENDING', result.stderr)
        self.assertFalse((self.root/'data/zte-agent').exists())

    def test_inactive_old_agent_updated_with_credentials_and_keys_preserved(self):
        agent = self.write('/data/zte-agent', '#!/bin/sh\n# old agent\n', 0o700)
        startup = self.write('/data/zte-imei-studio/start_zte_agent.sh', '#!/bin/sh\n# old private credentials\ntouch "$MOCK_ROOT/running"\n', 0o700)
        keys = self.write('/etc/dropbear/authorized_keys', 'ssh-ed25519 AAAA old\n')
        old_agent, old_startup = agent.read_bytes(), startup.read_bytes()
        self.assert_success(self.run_setup())
        self.assertEqual(agent.read_bytes(), (self.stage/'zte-agent').read_bytes())
        self.assertEqual((self.journal/'before/data_zte-agent').read_bytes(), old_agent)
        self.assertEqual(startup.read_bytes(), old_startup)
        self.assertIn('ssh-ed25519 AAAA old\n', keys.read_text())
        self.assert_success(self.commit())

    def test_running_old_agent_with_valid_startup_refuses_before_transaction(self):
        agent=self.write('/data/zte-agent','#!/bin/sh\n# earlier running agent\n',0o700)
        self.write('/data/zte-imei-studio/start_zte_agent.sh','#!/bin/sh\ntouch "$MOCK_ROOT/running"\n',0o700)
        original=agent.read_bytes();self.write('/running','yes')
        result=self.run_setup()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('EXISTING_AGENT_RUNNING_REQUIRES_UPDATE',result.stderr)
        self.assertEqual(agent.read_bytes(),original)
        self.assertFalse(self.journal.parent.exists())

    def test_old_agent_with_startup_started_after_snapshot_never_replaced(self):
        agent=self.write('/data/zte-agent','#!/bin/sh\n# earlier inactive agent\n',0o700)
        startup=self.write('/data/zte-imei-studio/start_zte_agent.sh','#!/bin/sh\ntouch "$MOCK_ROOT/running"\n',0o700)
        original=agent.read_bytes();before_startup=startup.read_bytes()
        self.env['MOCK_AGENT_START_ON_SNAPSHOT']='1'
        result=self.run_setup()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('EXISTING_AGENT_STARTED',result.stderr)
        self.assertEqual(agent.read_bytes(),original)
        self.assertEqual(startup.read_bytes(),before_startup)
        self.assertEqual((self.journal/'before/data_zte-agent').read_bytes(),original)
        self.assertTrue((self.journal.parent/'active').exists())

    def test_inactive_orphan_agent_is_snapshotted_and_replaced_by_pinned_payload(self):
        old=self.write('/data/zte-agent','#!/bin/sh\ntouch "$MOCK_ROOT/forbidden"\n',0o700)
        original=old.read_bytes()
        self.assert_success(self.run_setup())
        self.assertEqual((self.journal/'before/data_zte-agent').read_bytes(),original)
        self.assertIn(hashlib.sha256(original).hexdigest(),(self.journal/'before.sha256').read_text())
        self.assertEqual(old.read_bytes(),(self.stage/'zte-agent').read_bytes())
        self.assertFalse((self.root/'forbidden').exists())
        self.assert_success(self.commit())

    def test_orphan_started_after_snapshot_is_never_replaced(self):
        old=self.write('/data/zte-agent','#!/bin/sh\n# original inactive\n',0o700)
        original=old.read_bytes();self.env['MOCK_AGENT_START_ON_SNAPSHOT']='1'
        result=self.run_setup()
        self.assertIn('EXISTING_AGENT_STARTED',result.stderr)
        self.assertEqual(old.read_bytes(),original)
        self.assertEqual((self.journal/'before/data_zte-agent').read_bytes(),original)
        self.assertTrue((self.journal.parent/'active').exists())

    def test_safe_executable_orphan_0755_is_snapshotted_without_source_chmod(self):
        old=self.write('/data/zte-agent','#!/bin/sh\n# root-owned executable\n',0o755)
        original=old.read_bytes()
        self.assert_success(self.run_setup())
        backup=self.journal/'before/data_zte-agent'
        self.assertEqual(backup.read_bytes(),original)
        self.assertEqual(backup.stat().st_mode & 0o777,0o755)
        self.assertEqual(old.stat().st_mode & 0o777,0o700)
        self.assert_success(self.commit())

    def test_safe_executable_orphan_0750_is_supported(self):
        old=self.write('/data/zte-agent','#!/bin/sh\n# root-owned executable\n',0o750)
        self.assert_success(self.run_setup())
        self.assertEqual((self.journal/'before/data_zte-agent').stat().st_mode & 0o777,0o750)

    def test_writable_executable_orphan_is_not_replaced(self):
        old=self.write('/data/zte-agent','#!/bin/sh\n# writable executable\n',0o777)
        original=old.read_bytes()
        result=self.run_setup()
        self.assertIn('EXISTING_AGENT_TYPE',result.stderr)
        self.assertEqual(old.read_bytes(),original)
        self.assertFalse(self.journal.parent.exists())

    def test_generic_inactive_orphan_is_replaced_without_executing_old_binary(self):
        args=self.generic()
        old=self.write('/data/zte-agent','#!/bin/sh\ntouch "$MOCK_ROOT/forbidden"\n',0o700)
        original=old.read_bytes()
        self.assert_success(self.run_setup(**args))
        self.assertEqual((self.journal/'before/data_zte-agent').read_bytes(),original)
        self.assertFalse((self.root/'forbidden').exists())
        self.assert_success(self.commit(**args))

    def legacy_startup(self):
        text = "#!/bin/sh\nexport ZTE_AGENT_PASSWORD='synthetic-private-test'\nunset ZTE_AGENT_PIN\ntrap '' HUP\nnohup sh -c '"+str(self.root)+"/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &\n"
        self.command('nohup','#!/bin/sh\ntouch "$MOCK_ROOT/running"\n')
        return self.write('/data/local/tmp/start_zte_agent.sh',text,0o700)

    def test_legacy_startup_migrates_as_private_validated_data(self):
        agent=self.write('/data/zte-agent','#!/bin/sh\n# preserved agent\n',0o700)
        legacy=self.legacy_startup();original=legacy.read_bytes();old_agent=agent.read_bytes()
        for path in ('data/local','data/local/tmp'):(self.root/path).chmod(0o777)
        self.write('/etc/rc.local','#!/bin/sh\nsh '+str(self.root)+'/data/local/tmp/start_zte_imei_studio.sh\nexit 0\n',0o751)
        self.assert_success(self.run_setup())
        self.assertEqual(legacy.read_bytes(),original)
        migrated=self.root/'data/zte-imei-studio/start_zte_agent.sh'
        self.assertEqual(migrated.read_bytes(),original)
        self.assertEqual(migrated.stat().st_mode & 0o777,0o700)
        self.assertEqual(agent.read_bytes(),(self.stage/'zte-agent').read_bytes())
        self.assertEqual((self.journal/'before/data_zte-agent').read_bytes(),old_agent)
        rc=(self.root/'etc/rc.local').read_text()
        self.assertNotIn('/data/local/tmp/start_zte_imei_studio.sh',rc)
        self.assertEqual(rc.count('start_zte_imei_studio.sh'),1)
        self.assert_success(self.commit())

    def test_legacy_startup_unknown_grammar_cannot_execute(self):
        self.write('/data/zte-agent','#!/bin/sh\n# preserved agent\n',0o700)
        legacy=self.legacy_startup();legacy.write_text(legacy.read_text()+'touch "$MOCK_ROOT/forbidden"\n')
        result=self.run_setup()
        self.assertIn('LEGACY_STARTUP_GRAMMAR',result.stderr)
        self.assertFalse((self.root/'forbidden').exists())
        self.assertFalse(self.journal.parent.exists())

    def test_legacy_startup_hardlink_symlink_and_writable_rejected(self):
        for kind in ('hardlink','symlink','writable'):
            with self.subTest(kind=kind):
                self.write('/data/zte-agent','#!/bin/sh\n# preserved agent\n',0o700)
                legacy=self.legacy_startup();alias=self.root/'alias'
                if kind=='hardlink':os.link(legacy,alias)
                elif kind=='symlink':legacy.rename(alias);legacy.symlink_to(alias)
                else:legacy.chmod(0o777)
                self.assertIn('EXISTING_AGENT_STARTUP_TYPE',self.run_setup().stderr)
                self.assertFalse(self.journal.parent.exists())
                legacy.unlink();alias.unlink(missing_ok=True)

    def test_running_orphan_agent_never_gets_new_credentials(self):
        self.write('/data/zte-agent',(self.stage/'zte-agent').read_text(),0o700)
        self.write('/running','yes')
        self.assertIn('EXISTING_AGENT_STARTUP_MISSING',self.run_setup().stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_legacy_pending_blocks_new_anchor_transaction(self):
        self.write('/data/local/tmp/zte-imei-installations/active','old-pending\n')
        self.assertIn('RECOVERY_PENDING',self.run_setup().stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_symlink_authorized_keys_rejected(self):
        target = self.write('/elsewhere', 'untouched')
        (self.root/'etc/dropbear').mkdir()
        (self.root/'etc/dropbear/authorized_keys').symlink_to(target)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('EXISTING_FILE_TYPE', result.stderr)
        self.assertEqual(target.read_text(), 'untouched')

    def test_commit_rejects_changed_deployment(self):
        self.assert_success(self.run_setup())
        self.write('/data/zte-agent', '# changed after ready\n', 0o700)
        result = self.commit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DEPLOYMENT_CHANGED', result.stderr)
        self.assertTrue((self.journal.parent/'active').exists())

    def test_repeat_completed_commit_preserves_another_owner(self):
        self.assert_success(self.run_setup())
        self.assert_success(self.commit())
        other = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'
        self.write('/data/zte-imei-studio/installations/active', other)
        self.write('/data/zte-imei-studio/installations/lock/owner', other)
        result = self.commit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('JOURNAL_OWNER', result.stderr)
        self.assertEqual((self.journal.parent/'active').read_text(), other)
        self.assertEqual((self.journal.parent/'lock/owner').read_text(), other)

    def test_incomplete_setup_retains_snapshot_and_active(self):
        self.write('/etc/dropbear/dropbear_ed25519_host_key', 'invalid existing key')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HOST_KEY_INVALID', result.stderr)
        self.assertIn('INSTALL_INCOMPLETE', result.stderr)
        self.assertTrue((self.journal/'before/etc_rc.local').exists())
        self.assertTrue((self.journal.parent/'active').exists())

    def test_b02_preflight_install_and_commit_bound_identity(self):
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        result=self.preflight(profile='b02-experimental',firmware=B02_FIRMWARE)
        self.assert_success(result)
        self.assertEqual(result.stdout,'INSTALL_PREFLIGHT b02-experimental imei_config=unknown\n')
        self.assertFalse(self.journal.parent.exists())
        self.owner('b02-experimental',B02_FIRMWARE)
        self.assert_success(self.run_setup(profile='b02-experimental',firmware=B02_FIRMWARE))
        self.assertEqual((self.journal/'profile.identity').read_text(),f'b02-experimental {B02_FIRMWARE} {ROUTER}\n')
        self.assert_success(self.commit(profile='b02-experimental',firmware=B02_FIRMWARE))

    def test_b02_is_not_accepted_by_legacy_b31_or_unknown_profile(self):
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        self.assertIn('FIRMWARE_MISMATCH',self.run_setup().stderr)
        self.assertIn('UNSUPPORTED_PROFILE',self.preflight(profile='anything',firmware=B02_FIRMWARE).stderr)
        self.assertIn('UNSUPPORTED_PROFILE',self.preflight(profile='b02-experimental',firmware='a'*64).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_b02_changed_hash_or_cid_rejected_before_mutation(self):
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        self.owner('b02-experimental',B02_FIRMWARE)
        self.env['MOCK_ROUTER']='a'*64
        self.assertIn('ROUTER_MISMATCH',self.run_setup(profile='b02-experimental',firmware=B02_FIRMWARE).stderr)
        self.env['MOCK_ROUTER']=ROUTER
        self.write('/sys/block/mmcblk0/device/cid','f'*32)
        self.assertIn('CID_MISMATCH',self.run_setup(profile='b02-experimental',firmware=B02_FIRMWARE).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_commit_rechecks_saved_b02_identity_and_rejects_profile_substitution(self):
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        self.owner('b02-experimental',B02_FIRMWARE)
        self.assert_success(self.run_setup(profile='b02-experimental',firmware=B02_FIRMWARE))
        self.assertIn('JOURNAL_PROFILE_MISMATCH',self.commit(profile='b31').stderr)
        self.env['MOCK_FIRMWARE']=FIRMWARE
        self.assertIn('FIRMWARE_MISMATCH',self.commit().stderr)
        self.assertEqual((self.journal/'state').read_text().strip(),'ready')

    def test_old_b31_journal_without_profile_remains_committable(self):
        self.assert_success(self.run_setup())
        (self.journal/'profile.identity').unlink()
        # Legacy after.sha256 did not include newly introduced identity files.
        after=self.journal/'after.sha256';after.write_text(''.join(line for line in after.read_text().splitlines(True) if not line.rstrip().endswith('/profile.identity') and not line.rstrip().endswith('/cid')))
        self.assert_success(self.commit())

    def test_preflight_accepts_missing_parents_without_creating_them(self):
        shutil.rmtree(self.root/'data/local',ignore_errors=True)
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        self.assert_success(self.preflight(profile='b02-experimental',firmware=B02_FIRMWARE))
        self.assertFalse((self.root/'data/local').exists())
        self.assertFalse((self.root/'data/zte-agent').exists())

    def test_preflight_refuses_anchor_symlink_and_nonprivate_mode(self):
        shutil.rmtree(self.stage.parent)
        self.stage.parent.symlink_to(self.root/'missing')
        self.assertIn('DIRECTORY_LINK',self.preflight().stderr)
        self.stage.parent.unlink()
        self.stage.parent.mkdir(mode=0o755)
        self.assertIn('PRIVATE_DIRECTORY_MODE',self.preflight().stderr)
        self.stage.parent.chmod(0o777)
        self.assertIn('DIRECTORY_MODE',self.preflight().stderr)

    def test_preflight_refuses_shared_data_writable(self):
        (self.root/'data').chmod(0o777)
        self.assertIn('DIRECTORY_MODE',self.preflight().stderr)

    def test_stock_shared_writable_directories_are_not_installation_ancestors(self):
        for path in ('/data/local','/data/local/tmp','/data/bin','/data/dropbear'):
            directory=self.root/path.lstrip('/');directory.mkdir(parents=True,exist_ok=True);directory.chmod(0o777)
        self.assert_success(self.preflight())
        self.assert_success(self.run_setup())
        for path in ('/data/local','/data/local/tmp','/data/bin','/data/dropbear'):
            self.assertEqual((self.root/path.lstrip('/')).stat().st_mode & 0o777,0o777)

    def test_exact_payload_orphan_agent_is_repaired_without_replacing_binary(self):
        agent=self.write('/data/zte-agent',(self.stage/'zte-agent').read_text(),0o700)
        original=agent.read_bytes()
        self.assert_success(self.run_setup())
        self.assertEqual(agent.read_bytes(),original)
        self.assertTrue((self.root/'data/zte-imei-studio/start_zte_agent.sh').exists())

    def test_preflight_refuses_readonly_or_noexec_ancestor(self):
        path=self.root/'proc/self/mountinfo'
        original=path.read_text()
        path.write_text(original.replace(f'{self.root}/data rw ',f'{self.root}/data ro '))
        self.assertIn('MOUNT_LAYOUT',self.preflight().stderr)
        path.write_text(original+f'4 2 8:3 / {self.root}/data/zte-imei-studio rw,noexec - ext4 /dev/alias rw\n')
        self.assertIn('MOUNT_LAYOUT',self.preflight().stderr)

    def test_stage_owner_cannot_be_rebound_to_another_profile(self):
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        self.owner('b31',FIRMWARE)
        self.assertIn('STAGE_OWNER',self.run_setup(profile='b02-experimental',firmware=B02_FIRMWARE).stderr)
        self.assertFalse(self.journal.parent.exists())

    def test_preflight_does_not_treat_linux_config_as_efs_format(self):
        self.write('/config','arbitrary Linux file, not DIAG EFS')
        self.assert_success(self.preflight())

    def test_identity_changed_between_validation_and_first_mutation_refused(self):
        self.env['MOCK_FIRMWARE']=B02_FIRMWARE
        self.env['MOCK_FIRMWARE_CHANGE_AFTER']='1'
        self.owner('b02-experimental',B02_FIRMWARE)
        result=self.run_setup(profile='b02-experimental',firmware=B02_FIRMWARE)
        self.assertIn('FIRMWARE_MISMATCH',result.stderr)
        self.assertFalse(self.journal.parent.exists())
        self.assertFalse((self.root/'data/zte-agent').exists())

    def test_preflight_reports_missing_commit_runtime_dependency(self):
        (self.root/'usr/bin/curl').unlink()
        self.assertIn('CURL_REQUIRED',self.preflight().stderr)

    def test_new_journal_profile_cannot_be_removed_to_downgrade_to_legacy(self):
        self.assert_success(self.run_setup())
        self.assertIn(str(self.journal/'profile.identity'),(self.journal/'after.sha256').read_text())
        (self.journal/'profile.identity').unlink()
        self.assertIn('DEPLOYMENT_CHANGED',self.commit().stderr)
        self.assertEqual((self.journal/'state').read_text().strip(),'ready')


if __name__ == '__main__':
    unittest.main(verbosity=2)
