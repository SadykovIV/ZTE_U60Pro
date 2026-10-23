"""Real POSIX helper, isolated filesystem and explicit service/UCI substitutes.
No real device, service, radio, configuration or network command is executed.
"""
from pathlib import Path
import hashlib, os, re, shutil, subprocess, tempfile, unittest, sys, shlex
BASE=Path(__file__).resolve().parents[1]
SOURCE=BASE/'Resources/Onboarding/clean-components.sh'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
class CleanupTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='clean-components-');self.root=Path(self.tmp.name).resolve()
  self.bin=self.root/'commands';self.bin.mkdir();self.env={**os.environ,'PATH':str(self.bin)+':/usr/bin:/bin'}
  self.id='12345678-1234-1234-1234-123456789abc';self.boot='23456789-2345-2345-2345-23456789abcd';self.token='34567890-3456-3456-3456-34567890abcd';self.cid='0123456789abcdef0123456789abcdef'
  for p in ['data/zte-imei-studio','etc/init.d','etc/rc.d','etc/config','proc/sys/kernel/random','sys/block/mmcblk0/device','firmware/image','usr/bin','tmp']:(self.root/p).mkdir(parents=True,exist_ok=True,mode=0o700)
  self.write('proc/sys/kernel/random/boot_id',self.boot);self.write('sys/block/mmcblk0/device/cid',self.cid);self.write('firmware/image/modem.b16','firmware');self.write('usr/bin/diag-router','router');self.write('proc/mounts','')
  self.write('etc/rc.local','#!/bin/sh\n# OEM preserved\nsh /data/zte-imei-studio/start_zte_agent.sh\nexit 0\n',0o755)
  self.write('data/zte-imei-studio/start_zte_agent.sh','private credential fixture');self.write('data/OEM','untouched')
  self.command('id','echo 0');self.command('uname','case "$1" in -s) echo Linux;; -m) echo aarch64;; esac')
  # Native stat keeps this process-heavy shell suite fast on both platforms;
  # only the fixture UID is synthetic. Metadata and link counts are real.
  formats=['%u','%h','%a','%u:%h','%u:%a','%u:%a:%h','%d:%i:%u:%a:%h']
  lines=['follow=; if [ "${1:-}" = -L ]; then follow=-L; shift; fi','[ "${1:-}" = -c ] || exit 1','case "$2" in']
  for fmt in formats:
   native=fmt.replace('%u','0')
   if sys.platform=='darwin':native=native.replace('%h','%l').replace('%a','%Lp')
   flag='-f' if sys.platform=='darwin' else '-c'
   lines.append(fmt+') exec /usr/bin/stat $follow '+flag+' '+shlex.quote(native)+' "$3";;')
  lines.append('*) exit 1;; esac');self.command('stat','\n'.join(lines))
  sha_py=self.bin/'sha.py';sha_py.write_text("""import hashlib,os,sys
from pathlib import Path
def digest(name):
 if os.getenv('FAIL_HASH') and os.environ['FAIL_HASH'] in name:raise SystemExit(1)
 return hashlib.sha256(Path(name).read_bytes()).hexdigest()
args=sys.argv[1:]
if args[0]=='-c':
 for line in Path(args[1]).read_text().splitlines():
  expected,name=line.split(None,1);name=name.removeprefix('*')
  if digest(name)!=expected:raise SystemExit(1)
else:
 for name in args:print(digest(name)+'  '+name)
""")
  self.command('sha256sum','exec '+shlex.quote(sys.executable)+' '+shlex.quote(str(sha_py))+' "$@"')
  self.command('mv','[ \"${1:-}\" != -T ] || shift; exec /bin/mv \"$@\"');self.command('sync',':');self.command('sleep',':');self.command('ubus',':');self.command('ip',':')
  self.command('uci','''case "$*" in *changes*) exit 0;; *get*) exit 1;; esac''')
  self.command('lua','''cat >/dev/null; [ "${FAIL_LUA:-0}" = 0 ]''')
  self.command('sh','''case "$1" in */firewall.sh) echo firewall >> "$CALLS";exit 0;; *) exec /bin/sh "$@";; esac''')
  self.calls=self.root/'calls';self.env['CALLS']=str(self.calls)
  self.script=self.root/'cleanup.sh';s=SOURCE.read_text();s=s.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C','export LC_ALL=C')
  s=re.sub(r'(?<![A-Za-z0-9_/])/(?:usr/bin/diag-router|usr/bin/zte_topsw_devui|firmware|sys|proc|data|etc|tmp/zte-imei-app.lock)',lambda m:str(self.root)+m[0],s)
  s=s.replace('${p#/}', '${p#'+str(self.root)+'/}').replace('p=/$rel','p='+str(self.root)+'/$rel').replace('tar -C / ', 'tar -C '+str(self.root)+' ').replace('p="/$rel"', 'p="'+str(self.root)+'/$rel"')
  self.script.write_text(s)
  self.tx=self.root/f'data/zte-imei-studio/cleanup-{self.id}'
 def write(self,rel,data,mode=0o600):
  p=self.root/rel;p.parent.mkdir(parents=True,exist_ok=True,mode=0o700);p.write_text(data);p.chmod(mode);return p
 def command(self,name,text):
  p=self.bin/name;p.write_text('#!/bin/sh\n'+text+'\n');p.chmod(0o700)
 def owned(self,name,owner):
  d=self.root/'data'/name;d.mkdir(mode=0o700);self.write(f'data/{name}/owner',owner);self.write(f'data/{name}/data.txt','important prior data');return d
 def run_helper(self,action,approved=None,**env):
  fw=env.pop('FIRMWARE',None) or (sha(self.root/'firmware/image/modem.b16') if (self.root/'firmware/image/modem.b16').exists() else 'absent')
  args=[action,str(self.tx),self.id,self.cid,self.boot,fw,sha(self.root/'usr/bin/diag-router'),self.token]
  if approved is not None:args.append(approved)
  new_boot=env.pop('NEW_BOOT',None)
  if new_boot is not None:args.append(new_boot)
  return subprocess.run(['/bin/sh',str(self.script),*args],env={**self.env,**env},capture_output=True,timeout=90)
 def ok(self,r):self.assertEqual(r.returncode,0,r.stderr.decode());return r.stdout.decode().strip()
 def prepare(self):
  result=self.ok(self.run_helper('prepare'));self.assertTrue(result.startswith('CLEAN_PREPARED '));return result.split()[1]
 def test_absent_components_keeps_oem_ssh_and_archive(self):
  before=(self.root/'etc/rc.local').read_bytes();digest=self.prepare();self.ok(self.run_helper('clean',digest))
  self.assertEqual((self.root/'etc/rc.local').read_bytes(),before);self.assertEqual((self.root/'data/OEM').read_text(),'untouched');self.assertTrue((self.tx/'components.tar').is_file());self.assertTrue((self.root/'data/zte-imei-studio/start_zte_agent.sh').exists())
 def test_observed_missing_b16_allows_verified_cleanup(self):
  (self.root/'firmware/image/modem.b16').unlink()
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare()
  self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists());self.assertEqual((self.tx/'retained/data_zte-agent-installer/data.txt').read_text(),'important prior data')
 def test_absent_identity_never_accepts_present_or_linked_firmware(self):
  self.assertNotEqual(self.run_helper('prepare',FIRMWARE='absent').returncode,0);self.assertFalse((self.tx/'phase').exists())
  file=self.root/'firmware/image/modem.b16';file.unlink();file.symlink_to(self.root/'missing')
  self.assertNotEqual(self.run_helper('prepare',FIRMWARE='absent').returncode,0);self.assertFalse((self.tx/'phase').exists())
 def test_owned_roots_archived_then_retained_and_repeat(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');digest=self.prepare();self.assertTrue(d.exists());self.assertEqual(sha(self.tx/'components.tar'),digest)
  self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists());self.assertEqual((self.tx/'retained/data_zte-agent-installer/data.txt').read_text(),'important prior data');self.assertEqual(self.ok(self.run_helper('clean',digest)),'CLEAN_COMPLETE')
 def test_wrong_local_archive_digest_never_deletes(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');self.prepare();r=self.run_helper('clean','0'*64);self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists())
 def test_foreign_owner_refuses_before_snapshot(self):
  self.owned('zte-agent-installer','foreign');self.assertNotEqual(self.run_helper('prepare').returncode,0);self.assertFalse((self.tx/'phase').exists())
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
   self.write('etc/init.d/network','# zte-vpn verified hook\n',0o755);self.write('data/zte-vpn/network-init.sha256',sha(self.root/'etc/init.d/network'));self.write('data/zte-vpn/configured','')
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
 function c:commit(pkg)
  if os.getenv('FAIL_RESTORE') then error('restore failed') end
  local f=assert(io.open(os.getenv('RESTORED'),'w'));f:write('1');f:close()
  if path:find('/plan/after') or path:find('/plan/off') then
   local out=assert(io.open(path..'/'..pkg,'w'));out:write(path:find('/off') and 'disabled wireless\n' or ('restored '..pkg..'\n'));out:close()
  end
  return true
 end
 return c end}
"""
  (module/'uci.lua').write_text(data);self.env['FIXTURE_ROOT']=str(self.root)
  lua=next((shutil.which(name) for name in ['lua','lua5.4','lua5.3'] if shutil.which(name)),None)
  if not lua:raise RuntimeError('Lua interpreter required for cleanup tests (lua, lua5.4 or lua5.3)')
  self.command('lua','exec '+shlex.quote(lua)+' "$@"')
 def test_configured_disabled_vpn_restores_stock_after_verified_archive(self):
  self.vpn();self.lua_fixture();digest=self.prepare();self.assertFalse((self.root/'restored').exists());self.ok(self.run_helper('clean',digest));self.assertTrue((self.root/'restored').exists());self.assertEqual(sha(self.root/'etc/init.d/network'),sha(BASE/'Resources/VPN/network.stock'));self.assertTrue((self.tx/'retained/data_zte-vpn/backup').is_dir())
 def ipa_fixture(self,configured=True):
  d=self.vpn(configured);self.write('etc/config/zwrt_router','ipa=1\nunrelated=keep\n')
  self.write('data/zte-vpn/ipa-backup/original','original policy')
  shutil.copyfile(BASE/'Resources/VPN/manager.sh',d/'manager.sh');(d/'manager.sh').chmod(0o600)
  self.command('sh',r'''case "$1" in
 */manager.sh) case "$2" in
  ipa-check) exit 0;;
  ipa-restore)
   test -f "$ARCHIVE" || exit 88
   test "${FAIL_IPA_RESTORE:-0}" = 0 || exit 89
   echo ipa-restored >> "$CALLS"
   printf 'ipa=0\nunrelated=keep\n' > "$ROUTER_CONFIG";;
  *) exit 87;; esac;;
 */firewall.sh) echo firewall >> "$CALLS";;
 *) exec /bin/sh "$@";; esac''')
  self.env['ARCHIVE']=str(self.tx/'components.tar');self.env['ROUTER_CONFIG']=str(self.root/'etc/config/zwrt_router')
  return d
 def test_cleanup_archives_router_before_conditional_ipa_restore(self):
  import tarfile
  self.ipa_fixture();digest=self.prepare();self.assertFalse(self.calls.exists())
  with tarfile.open(self.tx/'components.tar') as archive:self.assertEqual(archive.extractfile('etc/config/zwrt_router').read(),b'ipa=1\nunrelated=keep\n')
  self.ok(self.run_helper('clean',digest));self.assertIn('ipa-restored',self.calls.read_text())
  self.assertEqual((self.root/'etc/config/zwrt_router').read_text(),'ipa=0\nunrelated=keep\n')
  self.assertTrue((self.tx/'retained/data_zte-vpn/ipa-backup/original').exists())
 def test_ipa_restore_failure_retains_components_and_exact_archive(self):
  d=self.ipa_fixture();digest=self.prepare();r=self.run_helper('clean',digest,FAIL_IPA_RESTORE='1')
  self.assertNotEqual(r.returncode,0);self.assertIn('VPN_RESTORE',r.stderr.decode());self.assertTrue(d.exists())
  self.assertEqual(sha(self.tx/'components.tar'),digest);self.assertEqual((self.tx/'phase').read_text().strip(),'changing')
  self.assertTrue(self.ok(self.run_helper('status')).startswith('CLEAN_PENDING '));self.ok(self.run_helper('clean',digest))
 def test_factory_reset_stock_network_still_restores_owned_ipa(self):
  self.ipa_fixture(configured=False);digest=self.prepare();self.ok(self.run_helper('clean',digest))
  self.assertEqual(self.calls.read_text().strip(),'ipa-restored')
 def network_runtime(self):
  (self.root/'sys/class/net/br-vpn').mkdir(parents=True)
  self.env['RELOADED']=str(self.root/'reloaded')
  self.command('ubus',f'''test "$*" = '-t 30 call network reload {{}}' || exit 1
[ "${{FAIL_RELOAD:-0}}" = 0 ] || exit 1
[ -f "$RESTORED" ] && [ -f '{self.tx}/components.tar' ] || exit 1
[ "$(sha256sum '{self.root}/etc/init.d/network' | cut -d ' ' -f1)" = '{sha(BASE/'Resources/VPN/network.stock')}' ] || exit 1
echo reload >> "$CALLS"; touch "$RELOADED"''')
  self.command('ip','''if [ ! -f "$RELOADED" ] || [ "${KEEP_BRIDGE:-0}" = 1 ];then
 case "$*" in *addr*) echo 'inet 192.168.50.1/24 scope global br-vpn';; *route*) echo '192.168.50.0/24 dev br-vpn proto kernel';; *) exit 1;;esac
fi''')
 def test_configured_inverse_reloads_and_removes_stale_bridge(self):
  self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();self.assertFalse((self.root/'reloaded').exists());self.ok(self.run_helper('clean',digest));self.assertTrue((self.root/'reloaded').exists());self.assertIn('reload',self.calls.read_text())
 def test_reload_failure_retains_components_and_recovery(self):
  d=self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();r=self.run_helper('clean',digest,FAIL_RELOAD='1');self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'changing');self.assertIn('VPN_RESTORE',r.stderr.decode())
  self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists())
 def test_stale_bridge_after_reload_refuses_complete(self):
  d=self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();r=self.run_helper('clean',digest,KEEP_BRIDGE='1');self.assertNotEqual(r.returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'changing');self.assertIn('VPN_RESTORE',r.stderr.decode())
  self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists())
 def test_foreign_uci_section_refuses_before_snapshot(self):
  self.vpn();self.lua_fixture();self.assertNotEqual(self.run_helper('prepare',BAD_SECTION='1').returncode,0);self.assertFalse((self.tx/'phase').exists());self.assertFalse((self.root/'restored').exists())
 def test_active_vpn_is_backed_up_then_disabled_and_removed(self):
  self.vpn();self.lua_fixture();result=self.ok(self.run_helper('prepare',ACTIVE_WIFI='1'));digest=result.split()[1]
  self.assertFalse((self.root/'restored').exists());self.ok(self.run_helper('clean',digest,ACTIVE_WIFI='1'))
  self.assertFalse((self.root/'data/zte-vpn').exists());self.assertTrue((self.tx/'retained/data_zte-vpn/backup').exists())
 def test_interrupted_inverse_planning_can_retry_without_live_changes(self):
  d=self.vpn();self.lua_fixture();digest=self.prepare();before=(self.root/'etc/config/wireless').read_bytes()
  self.assertNotEqual(self.run_helper('clean',digest,FAIL_RESTORE='1').returncode,0);self.assertTrue(d.exists())
  self.assertEqual((self.tx/'phase').read_text().strip(),'prepared');self.assertEqual((self.root/'etc/config/wireless').read_bytes(),before)
  self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists())
 def test_foreign_optional_updater_cid_refuses(self):
  self.owned('zte-agent-installer','zte-agent-installer-v1');self.write('data/zte-agent-installer/cid','f'*32);self.assertNotEqual(self.run_helper('prepare').returncode,0);self.assertFalse((self.tx/'phase').exists())
 def launcher(self):
  d=self.owned('zte-launcher','zte-native-launcher-v1');self.write('data/zte-launcher/cid',self.cid)
  program=self.write('etc/init.d/zte_topsw_devui','#!/bin/sh\necho restart >> "$CALLS"\n',0o700)
  self.script.write_text(self.script.read_text().replace('a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35',sha(program)))
  self.command('ubus','echo synthetic');self.command('jsonfilter',f"""case "$*" in *command*) echo '{self.root}/usr/bin/zte_topsw_devui';; *pid*) echo 123;; esac""")
  (self.root/'proc/123').mkdir(mode=0o700);(self.root/'proc/123/exe').symlink_to(self.root/'usr/bin/zte_topsw_devui');self.write('proc/123/maps','stock map');self.write('proc/123/cmdline','fixture-ui')
  return d
 def test_launcher_returns_stock_runtime_and_preserves_oem_service(self):
  d=self.launcher();before=(self.root/'etc/init.d/zte_topsw_devui').read_bytes();digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists());self.assertIn('restart',self.calls.read_text());self.assertEqual((self.root/'etc/init.d/zte_topsw_devui').read_bytes(),before)
 def test_launcher_mapped_extension_prevents_moves(self):
  d=self.launcher();self.write('proc/123/maps',str(self.root)+'/data/zte-launcher/launcher.so');digest=self.prepare();self.assertNotEqual(self.run_helper('clean',digest).returncode,0);self.assertTrue(d.exists());self.assertEqual((self.tx/'phase').read_text().strip(),'stopping')
  self.write('proc/123/maps','stock map');self.write('proc/123/cmdline','fixture-ui');self.ok(self.run_helper('clean',digest))
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
 def test_registry_accepts_current_and_supported_historical_payloads(self):
  body=SOURCE.read_text();entries=set(re.findall(r'([a-z0-9-]+):([0-9a-f]{64})',body))
  for kind,name in [('vpn-service','service.sh'),('manager','manager.sh'),('firewall','firewall.sh'),('configure','configure.lua'),('ikev2','ikev2.sh'),('launcher-service','launcher-service.sh')]:
   self.assertIn((kind,sha(BASE/'Resources/VPN'/name)),entries,name)
  for kind,value in [('vpn-service','3411d076729a717024d50ae8feb0777acf7ab792bb3878cb16ab7b282cbde63a'),('manager','ef5989252bbcdea112f793234827105e320cb9e8fdfd1fd699e63b33833fa94c'),('manager','f836b522c48a115c75233594207191214459f624180b7f98fabb754517d695b1'),('firewall','7d8ce304153612d4097c78738aa0f23c5cc420060b76a48c26dd668ac2657c99'),('firewall','6fd50b7d16b93a6d0964dfd937c328eb93273fdab42204e2edf5bb72b7ea0da3')]:
   self.assertIn((kind,value),entries)
 def test_root_owned_readable_roots_can_be_cleaned(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');d.chmod(0o755);digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertEqual((self.tx/'retained/data_zte-agent-installer').stat().st_mode&0o777,0o755)
 def test_world_writable_root_still_refused(self):
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');d.chmod(0o777);self.assertNotEqual(self.run_helper('prepare').returncode,0);self.assertTrue(d.exists())
 def test_different_unmodified_oem_network_is_preserved_after_reset(self):
  self.vpn(configured=False);network=self.write('etc/init.d/network','#!/bin/sh\n# Another OEM firmware\nexit 0\n',0o755);before=network.read_bytes();digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertEqual(network.read_bytes(),before)
 def test_inverse_uses_this_devices_verified_oem_backup(self):
  self.vpn();self.lua_fixture();original=self.write('data/zte-vpn/backup/network.init','#!/bin/sh\n# Another verified OEM network\nexit 0\n',0o750)
  backup=original.parent;self.write('data/zte-vpn/backup/SHA256SUMS',''.join(sha(backup/name)+'  '+name+'\n' for name in ['network','wireless','firewall','dhcp','network.init']))
  digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertEqual((self.root/'etc/init.d/network').read_bytes(),(self.tx/'retained/data_zte-vpn/backup/network.init').read_bytes());self.assertEqual((self.root/'etc/init.d/network').stat().st_mode&0o777,0o750)
 def test_mutating_runtime_logs_do_not_invalidate_verified_backup(self):
  self.vpn();self.lua_fixture();self.write('data/zte-vpn/core.log','before');digest=self.prepare();self.write('data/zte-vpn/core.log','after');self.ok(self.run_helper('clean',digest))
  self.assertEqual((self.tx/'retained/data_zte-vpn/core.log').read_text(),'after')
 def test_ike_socket_is_excluded_and_private_profiles_are_archived(self):
  import socket,tarfile
  d=self.vpn();self.lua_fixture();ike=d/'ikev2';ike.mkdir(mode=0o700)
  shutil.copyfile(BASE/'Resources/VPN/ikev2.sh',d/'ikev2.sh');(d/'ikev2.sh').chmod(0o700)
  self.write('data/zte-vpn/profiles/fixture.json','private fixture');self.write('data/zte-vpn/ikev2/swanctl.conf','private generated fixture')
  sock=socket.socket(socket.AF_UNIX);old=os.getcwd()
  try:
   os.chdir(ike);sock.bind('charon.vici');os.chdir(old)
   digest=self.prepare()
   with tarfile.open(self.tx/'components.tar') as archive:
    self.assertNotIn('data/zte-vpn/ikev2/charon.vici',archive.getnames())
    self.assertEqual(archive.extractfile('data/zte-vpn/profiles/fixture.json').read(),b'private fixture')
   self.command('sh',f'''case "$1" in */ikev2.sh) rm '{ike}/charon.vici';; */firewall.sh) :;; *) exec /bin/sh "$@";; esac''')
   self.ok(self.run_helper('clean',digest))
  finally:os.chdir(old);sock.close()
 def test_unknown_socket_still_refuses_snapshot(self):
  import socket
  d=self.owned('zte-agent-installer','zte-agent-installer-v1');sock=socket.socket(socket.AF_UNIX);old=os.getcwd()
  try:
   os.chdir(d);sock.bind('unknown.sock');os.chdir(old);r=self.run_helper('prepare');self.assertNotEqual(r.returncode,0);self.assertIn('OWNER',r.stderr.decode())
  finally:os.chdir(old);sock.close()
 def test_atomic_inverse_write_failure_resumes_each_target(self):
  for name in ['wireless','network','firewall','network.init','rc.local']:
   with self.subTest(name=name):
    t=CleanupTests();t.setUp()
    try:
     t.vpn();t.lua_fixture();t.write('etc/rc.local',f'#!/bin/sh\nsh {t.root}/data/zte-dashboard-runtime/start-dashboard.sh\nsh /data/zte-imei-studio/start_zte_agent.sh\nexit 0\n',0o755);digest=t.prepare()
     # Fail once at the atomic install after a complete inverse has been saved.
     suffix='etc/init.d/network' if name=='network.init' else 'etc/rc.local' if name=='rc.local' else 'etc/config/'+name
     destination=t.root/suffix
     t.command('mv',f'''case "$2" in '{destination}') if [ ! -f '{t.root}/once' ];then touch '{t.root}/once';exit 1;fi;;esac
exec /bin/mv "$@"''')
     r=t.run_helper('clean',digest);self.assertNotEqual(r.returncode,0);self.assertEqual(sha(t.tx/'components.tar'),digest)
     self.assertTrue(t.ok(t.run_helper('status')).startswith('CLEAN_PENDING '));t.ok(t.run_helper('clean',digest));self.assertFalse((t.root/'data/zte-vpn').exists())
    finally:t.tearDown()
 def test_changed_after_partial_restore_is_never_adopted(self):
  self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();self.assertNotEqual(self.run_helper('clean',digest,FAIL_RELOAD='1').returncode,0)
  self.write('etc/config/firewall','unrelated later edit');r=self.run_helper('clean',digest);self.assertNotEqual(r.returncode,0);self.assertIn('CHANGED',r.stderr.decode());self.assertEqual((self.root/'etc/config/firewall').read_text(),'unrelated later edit')
 def test_stale_owned_transaction_markers_are_retained(self):
  d=self.vpn();self.lua_fixture()
  for name in ['transaction','transaction.preparing','transaction.done','controller-upgrade']:(d/name).mkdir(mode=0o700);self.write('data/zte-vpn/'+name+'/old','retained original')
  digest=self.prepare();self.ok(self.run_helper('clean',digest))
  for name in ['transaction','transaction.preparing','transaction.done','controller-upgrade']:self.assertEqual((self.tx/'retained/data_zte-vpn'/name/'old').read_text(),'retained original')
 def test_owned_launcher_update_is_archived_without_recovery_execution(self):
  d=self.owned('zte-launcher-update','zte-launcher-update-v1');self.write('data/zte-launcher-update/cid',self.cid);digest=self.prepare();self.ok(self.run_helper('clean',digest));self.assertFalse(d.exists());self.assertTrue((self.tx/'retained/data_zte-launcher-update/data.txt').exists())
 def test_foreign_pending_journal_and_live_owner_still_block(self):
  self.write('data/local/tmp/open-u60-transactions/active','unknown');r=self.run_helper('prepare');self.assertIn('PENDING_FOREIGN',r.stderr.decode());self.assertFalse((self.tx/'phase').exists())
  (self.root/'data/local/tmp/open-u60-transactions/active').unlink();self.write('proc/234/cmdline','sh\0/tmp/fixture/install-launcher.sh\0arg\0');r=self.run_helper('prepare');self.assertIn('PENDING_LIVE',r.stderr.decode())
 def test_stale_own_cleanup_lock_is_retained_and_reclaimed(self):
  self.prepare();lock=self.root/'tmp/zte-imei-app.lock';lock.mkdir(mode=0o700);self.write('tmp/zte-imei-app.lock/owner',self.token);(lock/'probe').mkdir(mode=0o700)
  old=self.token;self.token='45678901-4567-4567-4567-456789abcdef';self.assertTrue(self.ok(self.run_helper('status')).startswith('CLEAN_PREPARED '));self.assertTrue((self.tx/f'retained-lock-{old}/owner').exists());self.assertFalse(lock.exists())
 def test_live_or_foreign_cleanup_lock_is_not_reclaimed(self):
  self.prepare();lock=self.root/'tmp/zte-imei-app.lock';lock.mkdir(mode=0o700);self.write('tmp/zte-imei-app.lock/owner',self.token);self.write('proc/234/cmdline','sh\0-s\0--\0'+self.token)
  self.token='45678901-4567-4567-4567-456789abcdef';r=self.run_helper('status');self.assertIn('BUSY',r.stderr.decode());self.assertTrue(lock.exists())
 def test_rebind_preserves_original_owner_and_archive_across_two_reboots(self):
  self.vpn();self.lua_fixture();digest=self.prepare();original=(self.tx/'owner').read_bytes()
  for new_boot in ['45678901-4567-4567-4567-456789abcdef','56789012-5678-5678-5678-567890abcdef']:
   self.write('proc/sys/kernel/random/boot_id',new_boot)
   self.assertIn('IDENTITY',self.run_helper('status').stderr.decode())
   self.assertEqual(self.ok(self.run_helper('rebind',digest,NEW_BOOT=new_boot)),f'CLEAN_REBOUND {new_boot} {digest} '+(self.tx/'archive.bytes').read_text().strip())
   self.assertEqual((self.tx/'owner').read_bytes(),original);self.assertEqual(sha(self.tx/'components.tar'),digest)
   self.assertTrue(self.ok(self.run_helper('status')).startswith('CLEAN_PREPARED '))
  self.ok(self.run_helper('clean',digest))
 def test_rebind_before_archive_or_before_download_is_safe(self):
  new_boot='45678901-4567-4567-4567-456789abcdef';self.write('proc/sys/kernel/random/boot_id',new_boot)
  self.assertEqual(self.ok(self.run_helper('rebind','none',NEW_BOOT=new_boot)),f'CLEAN_REBOUND {new_boot} none 0')
  digest=self.prepare();self.assertTrue(self.ok(self.run_helper('rebind','none',NEW_BOOT=new_boot)).startswith(f'CLEAN_REBOUND {new_boot} {digest} '));self.ok(self.run_helper('clean',digest))
 def test_rebind_after_mutation_requires_original_archive_proof(self):
  self.vpn();self.lua_fixture();self.network_runtime();digest=self.prepare();self.assertNotEqual(self.run_helper('clean',digest,FAIL_RELOAD='1').returncode,0)
  new_boot='45678901-4567-4567-4567-456789abcdef';self.write('proc/sys/kernel/random/boot_id',new_boot)
  self.assertIn('BACKUP_NOT_VERIFIED',self.run_helper('rebind','none',NEW_BOOT=new_boot).stderr.decode())
  self.assertIn('BACKUP_NOT_VERIFIED',self.run_helper('rebind','0'*64,NEW_BOOT=new_boot).stderr.decode())
  self.ok(self.run_helper('rebind',digest,NEW_BOOT=new_boot));self.ok(self.run_helper('clean',digest))
 def test_rebind_never_accepts_changed_device(self):
  digest=self.prepare();self.write('sys/block/mmcblk0/device/cid','f'*32);new_boot='45678901-4567-4567-4567-456789abcdef';self.write('proc/sys/kernel/random/boot_id',new_boot)
  self.assertIn('IDENTITY',self.run_helper('rebind',digest,NEW_BOOT=new_boot).stderr.decode());self.assertFalse((self.tx/'accepted-boot').exists())
 def test_source_only_compatibility_check_does_not_need_windows_tree(self):
  import importlib.util
  checker=BASE.parent/'tools/check_cleanup_compatibility.py';spec=importlib.util.spec_from_file_location('cleanup_compat',checker);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  source=self.root/'source';(source/'MacIMEI/Resources/Onboarding').mkdir(parents=True)
  shutil.copyfile(SOURCE,source/'MacIMEI/Resources/Onboarding/clean-components.sh');(source/'MacIMEI/Resources/VPN').mkdir()
  for name in module.PAYLOADS.values():shutil.copyfile(BASE/'Resources/VPN'/name,source/'MacIMEI/Resources/VPN'/name)
  self.assertEqual(module.check(source,source_only=True),[])
 def test_initial_status_does_not_create_shared_lock(self):
  self.assertEqual(self.ok(self.run_helper('status')),'CLEAN_ABSENT');self.assertFalse(self.tx.exists());self.assertFalse((self.root/'tmp/zte-imei-app.lock').exists())
 def test_incomplete_sibling_intent_does_not_block_new_prepare(self):
  stale=self.root/f'data/zte-imei-studio/cleanup-init-{self.id}-old';stale.mkdir(mode=0o700);(stale/'owner').write_text('partial')
  self.prepare();self.assertEqual((stale/'owner').read_text(),'partial')
 def test_unreadable_process_is_not_absence_evidence(self):
  (self.root/'proc/234').mkdir(mode=0o700)
  r=self.run_helper('prepare');self.assertNotEqual(r.returncode,0);self.assertIn('PENDING_LIVE',r.stderr.decode())
 def tearDown(self):self.tmp.cleanup()
if __name__=='__main__':unittest.main()
