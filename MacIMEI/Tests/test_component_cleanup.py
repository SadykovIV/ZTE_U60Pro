"""Real POSIX helper, isolated filesystem and explicit service/UCI substitutes.
No real device, service, radio, configuration or network command is executed.
"""
from pathlib import Path
import hashlib, os, re, shutil, subprocess, tempfile, unittest
BASE=Path(__file__).resolve().parents[1]
SOURCE=BASE/'Resources/Onboarding/clean-components.sh'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
class CleanupTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='clean-components-');self.root=Path(self.tmp.name)
  self.bin=self.root/'commands';self.bin.mkdir();self.env={**os.environ,'PATH':str(self.bin)+':/usr/bin:/bin'}
  self.id='12345678-1234-1234-1234-123456789abc';self.boot='23456789-2345-2345-2345-23456789abcd';self.token='34567890-3456-3456-3456-34567890abcd';self.cid='0123456789abcdef0123456789abcdef'
  for p in ['data/zte-imei-studio','etc/init.d','etc/rc.d','etc/config','proc/sys/kernel/random','sys/block/mmcblk0/device','firmware/image','usr/bin','tmp']:(self.root/p).mkdir(parents=True,exist_ok=True,mode=0o700)
  self.write('proc/sys/kernel/random/boot_id',self.boot);self.write('sys/block/mmcblk0/device/cid',self.cid);self.write('firmware/image/modem.b16','firmware');self.write('usr/bin/diag-router','router');self.write('proc/mounts','')
  self.write('etc/rc.local','#!/bin/sh\n# OEM preserved\nsh /data/zte-imei-studio/start_zte_agent.sh\nexit 0\n',0o755)
  self.write('data/zte-imei-studio/start_zte_agent.sh','private credential fixture');self.write('data/OEM','untouched')
  self.command('id','echo 0');self.command('uname','case "$1" in -s) echo Linux;; -m) echo aarch64;; esac')
  self.command('stat','''case "$2" in %u) echo 0;; %u:%h) printf '0:';/usr/bin/stat -f %l "$3";; %a) /usr/bin/stat -f %Lp "$3";; %u:%a) printf '0:';/usr/bin/stat -f %Lp "$3";; %u:%a:%h) printf '0:';/usr/bin/stat -f %Lp:%l "$3";; *) exit 1;; esac''')
  self.command('sha256sum','''case "$1" in *"$FAIL_HASH"*) [ -z "${FAIL_HASH:-}" ] || exit 1;; esac
exec /usr/bin/shasum -a 256 "$@"''')
  self.command('sync',':');self.command('sleep',':');self.command('ubus',':');self.command('ip',':')
  self.command('uci','''case "$*" in *changes*) exit 0;; *get*) exit 1;; esac''')
  self.command('lua','''cat >/dev/null; [ "${FAIL_LUA:-0}" = 0 ]''')
  self.command('sh','''case "$1" in */firewall.sh) echo firewall >> "$CALLS";exit 0;; *) exec /bin/sh "$@";; esac''')
  self.calls=self.root/'calls';self.env['CALLS']=str(self.calls)
  self.script=self.root/'cleanup.sh';s=SOURCE.read_text();s=s.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C','export LC_ALL=C')
  s=re.sub(r'(?<![A-Za-z0-9_/])/(?:usr/bin/diag-router|usr/bin/zte_topsw_devui|firmware|sys|proc|data|etc|tmp/zte-imei-app.lock)',lambda m:str(self.root)+m[0],s)
  s=s.replace('${p#/}', '${p#'+str(self.root)+'/}').replace('p=/$rel','p='+str(self.root)+'/$rel').replace('tar -C / ', 'tar -C '+str(self.root)+' ')
  self.script.write_text(s)
  self.tx=self.root/f'data/zte-imei-studio/cleanup-{self.id}'
 def write(self,rel,data,mode=0o600):
  p=self.root/rel;p.parent.mkdir(parents=True,exist_ok=True,mode=0o700);p.write_text(data);p.chmod(mode);return p
 def command(self,name,text):
  p=self.bin/name;p.write_text('#!/bin/sh\n'+text+'\n');p.chmod(0o700)
 def owned(self,name,owner):
  d=self.root/'data'/name;d.mkdir(mode=0o700);self.write(f'data/{name}/owner',owner);self.write(f'data/{name}/data.txt','important prior data');return d
 def run_helper(self,action,approved=None,**env):
  args=[action,str(self.tx),self.id,self.cid,self.boot,sha(self.root/'firmware/image/modem.b16'),sha(self.root/'usr/bin/diag-router'),self.token]
  if approved is not None:args.append(approved)
  return subprocess.run(['/bin/sh',str(self.script),*args],env={**self.env,**env},capture_output=True,timeout=20)
 def ok(self,r):self.assertEqual(r.returncode,0,r.stderr.decode());return r.stdout.decode().strip()
 def prepare(self):
  result=self.ok(self.run_helper('prepare'));self.assertTrue(result.startswith('CLEAN_PREPARED '));return result.split()[1]
 def test_absent_components_keeps_oem_ssh_and_archive(self):
  before=(self.root/'etc/rc.local').read_bytes();digest=self.prepare();self.ok(self.run_helper('clean',digest))
  self.assertEqual((self.root/'etc/rc.local').read_bytes(),before);self.assertEqual((self.root/'data/OEM').read_text(),'untouched');self.assertTrue((self.tx/'components.tar').is_file());self.assertTrue((self.root/'data/zte-imei-studio/start_zte_agent.sh').exists())
 def test_owned_roots_archived_then_retained_and_repeat(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare();self.assertTrue(d.exists());self.assertEqual(sha(self.tx/'components.tar'),digest)
  self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists());self.assertEqual((self.tx/'retained/data_zte-agent-installer/data.txt').read_text(),'important prior data');self.assertEqual(self.ok(self.run_helper('clean',digest)),'CLEAN_COMPLETE')
 def test_wrong_local_archive_digest_never_deletes(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');self.prepare();r=self.run_helper('clean','0'*64);self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists())
 def test_foreign_owner_refuses_before_snapshot(self):
  self.owned('zte-agent-installer','foreign');self.assertNotEqual(self.run_helper('prepare').returncode,0);self.assertFalse(self.tx.exists())
 def test_external_symlink_refuses(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');(d/'escape').symlink_to(self.root/'data/OEM');self.assertNotEqual(self.run_helper('prepare').returncode,0);self.assertTrue(d.exists())
 def test_changed_after_backup_never_deletes(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare();(d/'data.txt').write_text('changed');self.assertNotEqual(self.run_helper('clean',digest).returncode,0);self.assertTrue(d.exists())
 def test_hash_failure_is_not_swallowed_by_pipeline(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');r=self.run_helper('prepare',FAIL_HASH='data.txt');self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists());self.assertNotEqual((self.tx/'phase').read_text().strip(),'prepared')
 def test_partial_archive_preparation_can_resume(self):
  self.owned('zte-agent-installer','zte-agent-installer-v1');self.assertNotEqual(self.run_helper('prepare',FAIL_HASH='data.txt').returncode,0);self.prepare()
 def test_changed_identity_blocks(self):
  self.prepare();self.write('proc/sys/kernel/random/boot_id','bad');self.assertNotEqual(self.run_helper('status').returncode,0)
 def test_archive_corruption_blocks_clean(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare();(self.tx/'components.tar').write_bytes(b'corrupt');self.assertNotEqual(self.run_helper('clean',digest).returncode,0);self.assertTrue(d.exists())
 def test_move_failure_can_resume_without_repeating_restore(self):
  self.owned('zte-agent-installer','zte-agent-installer-v1');self.owned('zte-dashboard-runtime','zte-dashboard-runtime-v1');digest=self.prepare()
  self.command('mv',f'''case "$1" in */zte-agent-installer) if [ ! -f '{self.root}/once' ];then touch '{self.root}/once';exit 1;fi;;esac
exec /bin/mv "$@"''')
  self.assertNotEqual(self.run_helper('clean',digest).returncode,0);self.assertEqual((self.tx/'phase').read_text().strip(),'moving');self.ok(self.run_helper('clean',digest));self.assertEqual((self.tx/'phase').read_text().strip(),'complete')
 def test_no_archive_stream_before_preparation(self):self.assertNotEqual(self.run_helper('stream').returncode,0)
 def dashboard(self):
  d=self.owned('zte-dashboard-runtime','zte-dashboard-runtime-v1');(d/'dashboards').mkdir(mode=0o700);(d/'dashboards/current-id').mkdir(mode=0o700)
  self.write('data/zte-dashboard-runtime/dashboards/current-id/index.html','page');return d
 def test_current_absolute_owned_dashboard_link_archived_without_following(self):
  d=self.dashboard();(d/'current').symlink_to(d/'dashboards/current-id');digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertTrue((self.tx/'retained/data_zte-dashboard-runtime/current').is_symlink())
 def test_legacy_dashboard_link_preserves_target(self):
  d=self.dashboard();self.write('data/www/index.html','legacy target');(d/'current').symlink_to(self.root/'data/www');digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertEqual((self.root/'data/www/index.html').read_text(),'legacy target')
 def vpn(self,configured=True):
  d=self.owned('zte-vpn','zte-vpn-v1');self.write('data/zte-vpn/cid',self.cid)
  for name in ['configure.lua','firewall.sh']:shutil.copyfile(BASE/'Resources/VPN'/name,d/name);(d/name).chmod(0o600)
  for name in ['network','wireless','firewall','dhcp']:self.write('etc/config/'+name,'original '+name)
  stock=BASE/'Resources/VPN/network.stock';shutil.copyfile(stock,self.root/'etc/init.d/network');(self.root/'etc/init.d/network').chmod(0o755)
  if configured:
   backup=d/'backup';backup.mkdir(mode=0o700)
   for name in ['network','wireless','firewall','dhcp']:shutil.copyfile(self.root/'etc/config'/name,backup/name);(backup/name).chmod(0o600)
   shutil.copyfile(stock,backup/'network.init');(backup/'network.init').chmod(0o600)
   self.write('data/zte-vpn/backup/SHA256SUMS',''.join(sha(backup/name)+'  '+name+'\n' for name in ['network','wireless','firewall','dhcp','network.init']))
   self.write('etc/init.d/network','verified hook',0o755);self.write('data/zte-vpn/network-init.sha256',sha(self.root/'etc/init.d/network'));self.write('data/zte-vpn/configured','')
  return d
 def lua_fixture(self):
  module=self.root/'lua';module.mkdir();self.env['LUA_PATH']=str(module/'?.lua')+';;';self.env['RESTORED']=str(self.root/'restored')
  data=r"""
local base=os.getenv('FIXTURE_ROOT')
local configs={network={br_vpn={['.type']='device',name='br-vpn',type='bridge',ports={'wlan1','wlan3'},bridge_empty='1',ipv6='0'},vpn={['.type']='interface',device='br-vpn',type='bridge',ifname='wlan1 wlan3',bridge_empty='1',force_link='1',proto='static',ipaddr='192.168.50.1',netmask='255.255.255.0',delegate='0'}},firewall={zte_vpn_zone={['.type']='zone',name='vpn',network={'vpn'},input='REJECT',output='ACCEPT',forward='REJECT'},zte_vpn_rules={['.type']='include',type='script',path=base..'/data/zte-vpn/firewall.sh',reload='1',enabled='1'}},wireless={guest_2g={['.type']='wifi-iface',disabled='1',network='vpn',bridge='br-vpn'},guest_5g={['.type']='wifi-iface',disabled='1',network='vpn',bridge='br-vpn'}}}
if os.getenv('BAD_SECTION') then configs.network.vpn.foreign='1' end
if os.getenv('ACTIVE_WIFI') then configs.wireless.guest_2g.disabled='0' end
return {cursor=function(path)
 local backup=path:find('/backup')~=nil
 local c={}
 function c:load(pkg) return true end
 function c:get_all(pkg,s) return configs[pkg] and configs[pkg][s] end
 function c:get(pkg,s,k) if backup then if k=='disabled' then return '1' end;if not k then return 'wifi-iface' end;return nil end
 local section=self:get_all(pkg,s);return section and section[k or '.type'] end
 function c:set(pkg,s,k,v) assert(pkg=='wireless' and (s=='guest_2g' or s=='guest_5g'));configs[pkg][s][k]=v;return true end
 function c:delete(pkg,s,k) if k then configs[pkg][s][k]=nil else configs[pkg][s]=nil end;return true end
 function c:save(pkg) return true end
 function c:commit(pkg) if os.getenv('FAIL_RESTORE') then error('restore failed') end;local f=assert(io.open(os.getenv('RESTORED'),'w'));f:write('1');f:close();return true end
 return c end}
"""
  (module/'uci.lua').write_text(data);self.env['FIXTURE_ROOT']=str(self.root)
  self.command('lua','exec /opt/homebrew/bin/lua "$@"')
 def test_configured_disabled_vpn_restores_stock_after_verified_archive(self):
  self.vpn();self.lua_fixture();digest=self.prepare();self.assertFalse((self.root/'restored').exists());self.ok(self.run_helper('clean',digest));self.assertTrue((self.root/'restored').exists());self.assertEqual(sha(self.root/'etc/init.d/network'),sha(BASE/'Resources/VPN/network.stock'));self.assertTrue((self.tx/'retained/data_zte-vpn/backup').is_dir())
 def network_runtime(self):
  (self.root/'sys/class/net/br-vpn').mkdir(parents=True)
  self.env['RELOADED']=str(self.root/'reloaded')
  self.command('ubus',f'''test "$*" = '-t 30 call network reload {{}}' || exit 1
[ "${{FAIL_RELOAD:-0}}" = 0 ] || exit 1
[ -f "$RESTORED" ] && [ -f '{self.tx}/components.tar' ] || exit 1
[ "$(/usr/bin/shasum -a 256 '{self.root}/etc/init.d/network' | cut -d ' ' -f1)" = '{sha(BASE/'Resources/VPN/network.stock')}' ] || exit 1
echo reload >> "$CALLS"; touch "$RELOADED"''')
  self.command('ip','''if [ ! -f "$RELOADED" ] || [ "${KEEP_BRIDGE:-0}" = 1 ];then
 case "$*" in *addr*) echo 'inet 192.168.50.1/24 scope global br-vpn';; *route*) echo '192.168.50.0/24 dev br-vpn proto kernel';; *) exit 1;;esac
fi''')
 def test_configured_inverse_reloads_and_removes_stale_bridge(self):
  self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();self.assertFalse((self.root/'reloaded').exists());self.ok(self.run_helper('clean',digest));self.assertTrue((self.root/'reloaded').exists());self.assertIn('reload',self.calls.read_text())
 def test_reload_failure_retains_components_and_recovery(self):
  d=self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();r=self.run_helper('clean',digest,FAIL_RELOAD='1');self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'changing');self.assertIn('VPN_RESTORE',r.stderr.decode())
 def test_stale_bridge_after_reload_refuses_complete(self):
  d=self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();r=self.run_helper('clean',digest,KEEP_BRIDGE='1');self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'changing');self.assertIn('VPN_RESTORE',r.stderr.decode())
 def test_foreign_uci_section_refuses_before_snapshot(self):
  self.vpn();self.lua_fixture();self.assertNotEqual(self.run_helper('prepare',BAD_SECTION='1').returncode,0);self.assertFalse(self.tx.exists());self.assertFalse((self.root/'restored').exists())
 def test_active_vpn_refuses_before_snapshot(self):
  self.vpn();self.lua_fixture();self.assertNotEqual(self.run_helper('prepare',ACTIVE_WIFI='1').returncode,0);self.assertFalse(self.tx.exists())
 def test_interrupted_uci_restore_retains_sources_and_requires_recovery(self):
  d=self.vpn();self.lua_fixture();digest=self.prepare();self.assertNotEqual(self.run_helper('clean',digest,FAIL_RESTORE='1').returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'changing');self.assertIn('RECOVERY_REQUIRED',self.run_helper('clean',digest).stderr.decode())
 def test_foreign_optional_updater_cid_refuses(self):
  self.owned('zte-agent-installer','zte-agent-installer-v1');self.write('data/zte-agent-installer/cid','f'*32);self.assertNotEqual(self.run_helper('prepare').returncode,0);self.assertFalse(self.tx.exists())
 def launcher(self):
  d=self.owned('zte-launcher','zte-native-launcher-v1');self.write('data/zte-launcher/cid',self.cid)
  program=self.write('etc/init.d/zte_topsw_devui','#!/bin/sh\necho restart >> "$CALLS"\n',0o700)
  self.script.write_text(self.script.read_text().replace('a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35',sha(program)))
  self.command('ubus','echo synthetic');self.command('jsonfilter',f"""case "$*" in *command*) echo '{self.root}/usr/bin/zte_topsw_devui';; *pid*) echo 123;; esac""")
  (self.root/'proc/123').mkdir(mode=0o700);(self.root/'proc/123/exe').symlink_to(self.root/'usr/bin/zte_topsw_devui');self.write('proc/123/maps','stock map')
  return d
 def test_launcher_returns_stock_runtime_and_preserves_oem_service(self):
  d=self.launcher();before=(self.root/'etc/init.d/zte_topsw_devui').read_bytes();digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists());self.assertIn('restart',self.calls.read_text());self.assertEqual((self.root/'etc/init.d/zte_topsw_devui').read_bytes(),before)
 def test_launcher_mapped_extension_prevents_moves(self):
  d=self.launcher();self.write('proc/123/maps',str(self.root)+'/data/zte-launcher/launcher.so');digest=self.prepare();self.assertNotEqual(self.run_helper('clean',digest).returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'stopping')
 def test_stock_oem_group_writable_rc_mode_preserved(self):
  rc=self.root/'etc/rc.local';rc.chmod(0o775);digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertEqual(rc.stat().st_mode&0o777,0o775)
 def test_complete_recreated_component_refused(self):
  self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare();self.ok(self.run_helper('clean',digest));self.owned('zte-agent-installer','zte-agent-installer-v1');self.assertNotEqual(self.run_helper('status').returncode,0)
 def test_complete_retained_tamper_refused(self):
  self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare();self.ok(self.run_helper('clean',digest));(self.tx/'retained/data_zte-agent-installer/data.txt').write_text('changed');self.assertNotEqual(self.run_helper('status').returncode,0)
 def test_oem_and_private_backup_original_modes_preserved(self):
  self.vpn();self.lua_fixture()
  for name,mode in [('network',0o606),('wireless',0o666),('firewall',0o606),('dhcp',0o606)]:
   (self.root/'etc/config'/name).chmod(mode);(self.root/'data/zte-vpn/backup'/name).chmod(mode)
  digest=self.prepare();self.ok(self.run_helper('clean',digest))
  for name,mode in [('network',0o606),('wireless',0o666),('firewall',0o606),('dhcp',0o606)]:
   self.assertEqual((self.root/'etc/config'/name).stat().st_mode&0o777,mode);self.assertEqual((self.tx/'retained/data_zte-vpn/backup'/name).stat().st_mode&0o777,mode)
 def test_oem_startup_missing_final_lf_preserved(self):
  rc=self.root/'etc/rc.local';before=rc.read_bytes().rstrip(b'\n');rc.write_bytes(before);digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertEqual(rc.read_bytes(),before)
 def tearDown(self):self.tmp.cleanup()
if __name__=='__main__':unittest.main()
