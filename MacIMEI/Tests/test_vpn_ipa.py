"""Production shell + production IPA Lua with private UCI/procfs substitutes.

No modem, real signal, system UCI state or network interface is used.
"""
from pathlib import Path
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest

VPN = Path(__file__).resolve().parents[1] / 'Resources/VPN'
B31 = '604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263'
B28 = '5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478'
B27 = '4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e'
B27_MDM = '00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d'
B27_ROUTER = '786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f'
B27_IPACM = 'a843789933a0b5747927583021c1480957ea942626cab17cb13ad415d1dfd3ae'
B04 = 'c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81'
IPACM = '95385816da7b2edb9a977cee328c091753463fcd4a70a67fa1676e8b335c11c0'
B28_IPACM = 'a8a90ee631a3e8de3266d1d4231e455c34fd0b0d1ad570e7c4d0dcd09eea1c54'
SWITCH = '8947eee9c554453dc8eeb77df933cd12899f447c8c03df3505c57c7b526d22b9'
MDM = '93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64'
ROUTER = '55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f'

LUA_UCI = r'''
local function read(path)
 local out={};local f=io.open(path,'r');if f then for line in f:lines() do local k,v=line:match('^([^=]+)=(.*)$');if k then out[k]=v end end;f:close() end;return out
end
return {cursor=function(path,delta)
 local file=path..'/zwrt_router';local db=read(file);local c={}
 function c:get(pkg,s,k) assert(pkg=='zwrt_router');return db[s..(k and '.'..k or '')] end
 function c:set(pkg,s,k,v) assert(pkg=='zwrt_router' and s=='other' and k=='ipa_disable');db[s..'.'..k]=v;return true end
 function c:delete(pkg,s,k) assert(pkg=='zwrt_router' and s=='other' and k=='ipa_disable');db[s..'.'..k]=nil;return true end
 function c:save(pkg) assert(delta:find('/ipa%-uci$'));return true end
 function c:commit(pkg)
  if os.getenv('FAIL_COMMIT')=='1' then return false end
  local keys={};for k in pairs(db) do keys[#keys+1]=k end;table.sort(keys)
  local f=assert(io.open(file,'w'));for _,k in ipairs(keys) do f:write(k..'='..db[k]..'\n') end;f:close();return true
 end
 return c
end}
'''

UCI = r'''import os,sys
from pathlib import Path
b=Path(os.environ['FIXTURE']);config=b/'etc/config/zwrt_router';pending=b/'pending'
def read(p):return dict(line.split('=',1) for line in p.read_text().splitlines()) if p.exists() else {}
db=read(config);changes=read(pending)
args=[a for a in sys.argv[1:] if a!='-q'];verb=args[0];key=args[1] if len(args)>1 else ''
if verb=='changes':
 for k,v in sorted(changes.items()):print(('' if v!='__delete__' else '-')+'zwrt_router.'+k+('='+repr(v) if v!='__delete__' else ''))
elif verb=='get':
 if key.startswith('wireless.'):
  selections=read(b/'wireless-selections')
  if key in selections:print(selections[key]);sys.exit(0)
  selected=b/'wireless-disabled'
  print(selected.read_text() if key.endswith('.disabled') and selected.exists() else ('0' if key.endswith('mesh_onoff') else '1'));sys.exit(0)
 key=key.removeprefix('zwrt_router.');v=changes.get(key,db.get(key))
 if v is None or v=='__delete__':sys.exit(1)
 print(v)
elif verb=='set':
 key,v=key.split('=',1);key=key.removeprefix('zwrt_router.');changes[key]=v
elif verb=='revert':changes.pop(key.removeprefix('zwrt_router.'),None)
elif verb=='delete':changes[key.removeprefix('zwrt_router.')]='__delete__'
else:sys.exit(90)
if verb in ('set','revert','delete'):pending.write_text(''.join(k+'='+v+'\n' for k,v in sorted(changes.items())))
'''

class IPATests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='vpn-ipa-')
        self.base=Path(self.temp.name).resolve();self.root=self.base/'data/zte-vpn'
        for rel in ['data/zte-vpn','etc/config','etc/init.d','proc/10','proc/20','proc/sys/kernel/random','usr/bin','sbin','firmware/image','sys/block/mmcblk0/device','bin','lua']:
            (self.base/rel).mkdir(parents=True,exist_ok=True,mode=0o700)
        self.env={**os.environ,'FIXTURE':str(self.base),'TEST_FIRMWARE':B31,'TEST_IPACM':IPACM,'TEST_SWITCH':SWITCH,'TEST_MDM':MDM,'TEST_ROUTER':ROUTER,'LUA_PATH':str(self.base/'lua/?.lua')+';;'}
        for rel in ['usr/bin/ipacm','sbin/ipacm_switch.sh','firmware/image/modem.b16','usr/bin/zte_topsw_mdm','usr/bin/diag-router']:self.write(rel,'fixture')
        (self.base/'proc/10/exe').symlink_to(self.base/'usr/bin/ipacm')
        (self.base/'proc/20/exe').symlink_to(self.base/'usr/bin/ujail')
        self.write('proc/sys/kernel/random/boot_id','test-boot')
        self.write('sys/block/mmcblk0/device/cid','a'*32+'\n');self.write('data/zte-vpn/cid','a'*32+'\n')
        self.write('data/zte-vpn/configured','');self.write('data/zte-vpn/config.json','private-profile')
        self.router={'other':'other','tmp_router':'tmp_router','other.ipa_disable':'0','tmp_router.close_ipa_acce':'0','other.unrelated':'original'}
        self.save_router();self.original=(self.base/'etc/config/zwrt_router').read_bytes()
        for pkg in ['network','firewall','wireless','dhcp']:self.write('etc/config/'+pkg,'original-'+pkg)
        self.write('etc/init.d/network','original-network-init')
        self.write('lua/uci.lua',LUA_UCI)
        self.write('data/zte-vpn/configure.lua',self.remap((VPN/'configure.lua').read_text()))
        self.script=self.write('manager.sh',self.remap((VPN/'manager.sh').read_text()).replace('kill -USR','ipa_signal -USR').replace('kill -TERM','core_signal -TERM'))
        self.command('uci',UCI,python=True)
        self.command('stat',r'''case "$2" in %u) echo 0;; %u:%a) printf '0:'; /usr/bin/stat -f %Lp "$3";; *) exit 90;; esac''')
        self.command('sha256sum',r'''case "$1" in
 */firmware/image/modem.b16) printf '%s  %s\n' "$TEST_FIRMWARE" "$1";;
 */usr/bin/ipacm) printf '%s  %s\n' "$TEST_IPACM" "$1";;
 */sbin/ipacm_switch.sh) printf '%s  %s\n' "$TEST_SWITCH" "$1";;
 */usr/bin/zte_topsw_mdm) printf '%s  %s\n' "$TEST_MDM" "$1";;
 */usr/bin/diag-router) printf '%s  %s\n' "$TEST_ROUTER" "$1";;
 *) exec /usr/bin/shasum -a 256 "$@";; esac''')
        self.command('pidof','[ "$1" = ipacm ] || exit 1; [ "${NO_PID:-0}" = 0 ] || exit 1; echo "20 10"')
        self.command('ipa_signal','''printf '%s\n' "$*" >> "$FIXTURE/signals"
if [ "${FAIL_SIGNAL:-0}" = 1 ] && [ ! -f "$FIXTURE/signal-failed" ];then touch "$FIXTURE/signal-failed";exit 1;fi''')
        self.command('core_signal','echo "$*" >> "$FIXTURE/core-signals"; rm -f "$FIXTURE/proc/$2/cmdline"')
        self.command('lua',r'''case "$2" in
 ipa-*) exec /opt/homebrew/bin/lua "$@";;
 apply) echo partial-network > "$FIXTURE/etc/config/network"; [ "${FAIL_APPLY:-0}" = 0 ] || { echo VPN_OPERATION_FAILED >&2;exit 1; };;
 restore) cp "$FIXTURE/data/zte-vpn/backup/network" "$FIXTURE/etc/config/network";;
 disable) echo disabled >> "$FIXTURE/wifi";;
 *) exit 90;; esac''')
        self.command('ip','''case "$*" in *addr*) [ "${NO_BRIDGE:-0}" = 0 ] && echo 'inet 192.168.50.1/24';; esac; exit 0''')
        self.command('ubus','''echo "$*" >> "$FIXTURE/reload"; [ "${FAIL_RELOAD:-0}" = 0 ]''')
        self.command('sync',':');self.command('sleep',':')
        self.write('data/zte-vpn/firewall.sh','#!/bin/sh\necho "$*" >> "$FIXTURE/firewall"\n',0o700)
        self.write('data/zte-vpn/vpnctl','''#!/bin/sh
if [ "$1" = backend ]; then echo mihomo; exit 0; fi
[ "$1" = hook-network ] || exit 0
echo hooked-network-init > "$FIXTURE/etc/init.d/network"
/usr/bin/shasum -a 256 "$FIXTURE/etc/init.d/network" | awk '{print $1}' > "$FIXTURE/data/zte-vpn/network-init.sha256"
''',0o700)
        self.write('etc/init.d/zte_vpn','#!/bin/sh\necho "$*" >> "$FIXTURE/service"\n',0o700)

    def tearDown(self):self.temp.cleanup()
    def write(self,rel,text,mode=0o600):
        p=self.base/rel;p.parent.mkdir(parents=True,exist_ok=True,mode=0o700);p.write_text(text);p.chmod(mode);return p
    def command(self,name,body,python=False):
        self.write('bin/'+name,('#!'+shutil.which('python3')+'\n' if python else '#!/bin/sh\n')+body+'\n',0o700)
    def remap(self,s):
        s=s.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH=__TEST_PATH__')
        return re.sub(r'(?<![A-Za-z0-9_/])/(?:data|etc|proc|sys|usr/bin|sbin|firmware)',lambda m:str(self.base)+m[0],s).replace('__TEST_PATH__',str(self.base/'bin')+':/usr/bin:/bin')
    def save_router(self):self.write('etc/config/zwrt_router',''.join(k+'='+v+'\n' for k,v in sorted(self.router.items())))
    def state(self,pending=False):
        p=self.base/('pending' if pending else 'etc/config/zwrt_router')
        return dict(line.split('=',1) for line in p.read_text().splitlines()) if p.exists() else {}
    def invoke(self,mode='prepare',**env):
        if env.get('TEST_FIRMWARE',self.env['TEST_FIRMWARE']) == B27:
            env = {'TEST_MDM': B27_MDM, 'TEST_ROUTER': B27_ROUTER, **env}
        return subprocess.run(['/bin/sh',str(self.script),mode],env={**self.env,**env},capture_output=True,text=True,timeout=20)
    def ok(self,r):self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    def signals(self):return (self.base/'signals').read_text().splitlines() if (self.base/'signals').exists() else []
    def clean_start(self):(self.root/'configured').unlink()
    def test_prepare_b31_b28_b04_and_missing_b04_image(self):
        for firmware,daemon in [(B31,IPACM),(B28,B28_IPACM),(B27,B27_IPACM),(B04,IPACM),('',IPACM)]:
            with self.subTest(firmware=firmware[:8]):
                if firmware:self.write('firmware/image/modem.b16','fixture')
                else:(self.base/'firmware/image/modem.b16').unlink(missing_ok=True)
                self.ok(self.invoke(TEST_FIRMWARE=firmware,TEST_IPACM=daemon))
                self.assertEqual(self.state()['other.ipa_disable'],'1')
                self.assertEqual(self.state(True)['tmp_router.close_ipa_acce'],'1')
                self.assertEqual(self.signals()[-1],'-USR1 10')
                self.ok(self.invoke('ipa-restore',TEST_FIRMWARE=firmware,TEST_IPACM=daemon))
                self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(),self.original)
                self.assertEqual(self.state(True),{})
    def test_b27_rejects_mixed_native_components_before_any_signal(self):
        for key, value in [('TEST_MDM', MDM), ('TEST_ROUTER', ROUTER), ('TEST_IPACM', IPACM)]:
            with self.subTest(component=key):
                r = self.invoke(TEST_FIRMWARE=B27, **{'TEST_IPACM': B27_IPACM, key: value})
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(), self.original)
                self.assertFalse((self.root/'ipa-backup').exists())
                self.assertEqual(self.signals(), [])

    def test_unknown_daemon_switch_and_missing_pid_never_mutate(self):
        for extra,code in [({'TEST_IPACM':'f'*64},'VPN_IPA_UNSUPPORTED'),({'TEST_SWITCH':'f'*64},'VPN_IPA_UNSUPPORTED'),({'NO_PID':'1'},'VPN_IPA_NOT_RUNNING')]:
            with self.subTest(code=code):
                r=self.invoke(**extra);self.assertNotEqual(r.returncode,0);self.assertIn(code,r.stderr)
                self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(),self.original)
                self.assertFalse((self.root/'ipa-backup').exists());self.assertEqual(self.signals(),[])
    def test_unrelated_live_and_pending_edits_survive_restore(self):
        self.write('pending','other.unrelated=pending-before\n')
        self.ok(self.invoke());self.router=self.state();self.router['other.later']='keep-after';self.save_router()
        self.write('pending','other.ipa_disable=1\nother.unrelated=pending-after\ntmp_router.close_ipa_acce=1\n')
        self.ok(self.invoke('ipa-restore'))
        self.assertEqual(self.state()['other.later'],'keep-after');self.assertEqual(self.state(True),{'other.unrelated':'pending-after'})
        self.assertEqual(self.state()['other.ipa_disable'],'0');self.assertEqual(self.signals()[-1],'-USR2 10')
        self.assertEqual((self.root/'ipa-restored/zwrt_router').read_bytes(),self.original)
    def test_original_software_mode_and_pending_absence_restored(self):
        self.write('pending','tmp_router.close_ipa_acce=1\nother.ipa_disable=__delete__\n')
        self.ok(self.invoke());self.ok(self.invoke('ipa-restore'))
        self.assertEqual(self.state(True),{'tmp_router.close_ipa_acce':'1','other.ipa_disable':'__delete__'})
        self.assertNotIn('-USR2 10',self.signals())
    def test_first_signal_failure_rolls_back_before_configured(self):
        self.clean_start();r=self.invoke(FAIL_SIGNAL='1');self.assertNotEqual(r.returncode,0);self.assertIn('VPN_IPA_PREPARE_FAILED',r.stderr)
        self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(),self.original);self.assertEqual(self.state(True),{})
        self.assertFalse((self.root/'configured').exists());self.assertFalse((self.root/'ipa-backup').exists());self.assertTrue((self.root/'ipa-restored').exists())
        self.ok(self.invoke());self.assertTrue((self.root/'configured').exists())
    def test_first_persistent_commit_failure_restores_without_signalling_on(self):
        self.clean_start();r=self.invoke(FAIL_COMMIT='1');self.assertNotEqual(r.returncode,0)
        self.assertIn('VPN_IPA_PREPARE_FAILED',r.stderr)
        self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(),self.original)
        self.assertEqual(self.state(True),{});self.assertEqual(self.signals(),[])
        self.assertTrue((self.root/'ipa-restored').exists())
    def test_boot_reestablishes_off_policy_before_starting_core(self):
        self.ok(self.invoke());self.write('proc/sys/kernel/random/boot_id','next-boot')
        self.write('wireless-disabled','0')
        self.write('data/zte-vpn/mihomo','#!/bin/sh\necho started > "$FIXTURE/core-started"\n',0o700)
        count=len(self.signals());self.ok(self.invoke('run-core'))
        self.assertEqual(len(self.signals()),count+1);self.assertTrue((self.base/'core-started').exists())
        self.assertEqual((self.root/'ipa-runtime').read_text(),'next-boot 10\n')
    def test_early_boot_registers_supervisor_before_ipacm_is_available(self):
        self.write('wireless-disabled','0')
        for firmware,daemon in [(B31,IPACM),(B28,B28_IPACM),(B27,B27_IPACM),(B04,IPACM)]:
            with self.subTest(firmware=firmware[:8]):
                self.ok(self.invoke('early',NO_PID='1',TEST_FIRMWARE=firmware,TEST_IPACM=daemon))
                self.assertEqual((self.base/'service').read_text().splitlines()[-1],'start')
                self.assertFalse((self.base/'wifi').exists(),'Boot must not commit a disabled Wi-Fi selection')
                self.assertEqual(self.signals(),[],'Early boot must not signal an unstable IPA daemon')
                self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(),self.original)
    def test_boot_signal_failure_respawns_without_erasing_enabled_selection(self):
        self.write('wireless-disabled','0')
        self.write('data/zte-vpn/mihomo','#!/bin/sh\necho started > "$FIXTURE/core-started"\n',0o700)
        for firmware,daemon in [(B31,IPACM),(B28,B28_IPACM),(B27,B27_IPACM),(B04,IPACM)]:
            with self.subTest(firmware=firmware[:8]):
                for rel in ['core-started','signal-failed','data/zte-vpn/ipa-runtime']:(self.base/rel).unlink(missing_ok=True)
                first=self.invoke('run-core',FAIL_SIGNAL='1',TEST_FIRMWARE=firmware,TEST_IPACM=daemon)
                self.assertNotEqual(first.returncode,0);self.assertIn('VPN_IPA_PREPARE_FAILED',first.stderr)
                self.assertFalse((self.base/'core-started').exists(),'Core started without IPA proof')
                self.assertFalse((self.base/'wifi').exists(),'Transient worker failure committed disabled Wi-Fi')
                self.ok(self.invoke('run-core',TEST_FIRMWARE=firmware,TEST_IPACM=daemon))
                self.assertTrue((self.base/'core-started').exists())
                self.assertFalse((self.base/'wifi').exists())
    def test_guard_waits_for_ipa_core_dns_and_retries_reload_using_current_user_selection(self):
        self.ok(self.invoke())
        self.write('proc/sys/kernel/random/boot_id','next-boot')
        self.write('wireless-disabled','0')
        self.command('ip','''echo "$*" >> "$FIXTURE/ip-calls"
case "$*" in 'link show dev '*) [ -f "$FIXTURE/ap-ready" ] && echo "2: $4: <BROADCAST,MULTICAST,UP> state DOWN";; esac
exit 0''')
        self.command('hostapd_cli','[ -f "$FIXTURE/ap-ready" ] && echo state=ENABLED')
        self.command('ubus',r'''import os,sys
from pathlib import Path
b=Path(os.environ['FIXTURE']);p=b/'guard-reloads'
before=p.read_text() if p.exists() else ''
p.write_text(before+(b/'wireless-disabled').read_text()+'\n')
# The first successful RPC still has no ready AP; the guard must read back.
if len(before.splitlines())>=2:
 (b/'ap-ready').touch()
 for name in ['wlan1','wlan3']:
  d=b/'sys/class/net'/name;d.mkdir(parents=True,exist_ok=True);(d/'master').symlink_to(b/'sys/class/net/br-vpn')
sys.exit(1 if not before else 0)
''',python=True)
        self.command('sleep',r'''import os
from pathlib import Path
b=Path(os.environ['FIXTURE']);p=b/'tick';tick=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(tick))
if tick==1:
 (b/'data/zte-vpn/ipa-runtime').write_text('next-boot 10\n')
 (b/'data/zte-vpn/core.pid').write_text('30')
 (b/'proc/30').mkdir();(b/'proc/30/cmdline').write_bytes(str(b/'data/zte-vpn/mihomo').encode()+b'\0')
 (b/'sys/class/net/zvpn-tun').mkdir(parents=True)
elif tick==2:
 assert not (b/'guard-reloads').exists(),'Reload occurred before DNS readiness'
 (b/'data/zte-vpn/dns.pid').write_text('40')
 (b/'proc/40').mkdir();(b/'proc/40/cmdline').write_bytes(('--conf-file='+str(b/'data/zte-vpn/dnsmasq.conf')).encode()+b'\0')
elif tick==3:
 assert (b/'guard-reloads').read_text()=='0\n','First reload must use the current enabled selection'
elif tick==4:
 assert (b/'guard-reloads').read_text()=='0\n0\n','Failed reload must be retried'
elif tick==5:
 assert (b/'guard-reloads').read_text()=='0\n0\n0\n','RPC success without ready APs must be retried'
 (b/'data/zte-vpn/configured').unlink()
''',python=True)
        self.ok(self.invoke('run-guard'))
        self.assertFalse((self.base/'wifi').exists(),'Guard must not commit Wi-Fi selection')
        self.assertIn('link set wlan1 down',(self.base/'ip-calls').read_text())
        self.assertEqual((self.base/'guard-reloads').read_text(),'0\n0\n0\n')
    def ready_runtime(self):
        self.write('data/zte-vpn/core.pid','30');self.write('proc/30/cmdline',str(self.root/'mihomo')+'\0')
        (self.base/'proc/30/exe').symlink_to(self.root/'mihomo')
        self.write('data/zte-vpn/dns.pid','40');self.write('proc/40/cmdline','--conf-file='+str(self.root/'dnsmasq.conf')+'\0')
        (self.base/'sys/class/net/zvpn-tun').mkdir(parents=True)
    def test_restarted_guard_keeps_current_user_disabled_selection(self):
        self.ok(self.invoke());self.ready_runtime();self.write('wireless-disabled','1')
        self.command('sleep','rm "$FIXTURE/data/zte-vpn/configured"')
        self.ok(self.invoke('run-guard'))
        self.assertFalse((self.base/'reload').exists(),'A disabled selection must not be enabled by guard restart')
        self.assertFalse((self.base/'wifi').exists())
        self.assertEqual((self.base/'wireless-disabled').read_text(),'1')
    def test_restarted_guard_reloads_requested_enabled_aps_that_are_still_down(self):
        self.ok(self.invoke());self.ready_runtime();self.write('wireless-disabled','0')
        for name in ['wlan1','wlan3']:
            d=self.base/'sys/class/net'/name;d.mkdir();(d/'master').symlink_to(self.base/'sys/class/net/br-vpn')
        self.command('ip','[ -f "$FIXTURE/ap-ready" ] && echo "2: wlan: <BROADCAST,MULTICAST,UP> state DOWN"; exit 0')
        self.command('hostapd_cli','[ -f "$FIXTURE/ap-ready" ] && echo state=ENABLED')
        self.command('ubus','echo reload >> "$FIXTURE/reload"; touch "$FIXTURE/ap-ready"')
        self.command('sleep','rm "$FIXTURE/data/zte-vpn/configured"')
        self.ok(self.invoke('run-guard'))
        self.assertEqual((self.base/'reload').read_text(),'reload\n')
        self.assertFalse((self.base/'wifi').exists())
        self.assertEqual((self.base/'wireless-disabled').read_text(),'0')
    def suspended_ikev2_runtime(self):
        self.ok(self.invoke());self.ready_runtime();self.write('wireless-disabled','0')
        self.write('proc/40/cmdline','--conf-file='+str(self.root/'ikev2/dnsmasq.conf')+'\0')
        self.write('data/zte-vpn/vpnctl','#!/bin/sh\n[ "$1" != backend ] || echo ikev2\n',0o700)
        self.write('data/zte-vpn/ikev2.sh','#!/bin/sh\necho "$*" >> "$FIXTURE/ike-calls"\n[ "$1" = ready ]\n',0o700)
        for name in ['wlan1','wlan3']:
            d=self.base/'sys/class/net'/name;d.mkdir();(d/'master').symlink_to(self.base/'sys/class/net/br-vpn')
        self.command('hostapd_cli','[ "${DISABLED_HOSTAPD:-}" != "$4" ] && echo state=ENABLED')
        self.command('ip',r'''import os,sys
from pathlib import Path
b=Path(os.environ['FIXTURE']);args=sys.argv[1:]
with (b/'ip-calls').open('a') as f:f.write(' '.join(args)+'\n')
if args[:3]==['link','show','dev']:
 name=args[3];flags='BROADCAST,MULTICAST'+(',UP' if (b/('ap-up-'+name)).exists() else '')
 print('2: '+name+': <'+flags+'> state DOWN')
elif args[:2]==['link','set']:
 marker=b/('ap-up-'+args[2])
 if args[3]=='up':
  marker.touch()
  if os.environ.get('DISABLE_DURING_RESUME')=='1':(b/'wireless-disabled').write_text('1')
 elif args[3]=='down':marker.unlink(missing_ok=True)
''',python=True)
        # A real vendor reload can return success without changing link flags.
        self.command('ubus','echo reload >> "$FIXTURE/reload"')
        self.command('sleep','rm "$FIXTURE/data/zte-vpn/configured"')
    def test_guard_resumes_suspended_ikev2_ports_without_radio_reload_or_auth_restart(self):
        self.suspended_ikev2_runtime()
        self.ok(self.invoke('run-guard'))
        for name in ['wlan1','wlan3']:self.assertTrue((self.base/('ap-up-'+name)).exists())
        self.assertFalse((self.base/'reload').exists(),'No full radio reload for administratively suspended APs')
        self.assertFalse((self.base/'wifi').exists(),'Do not write the saved guest selection')
        self.assertFalse((self.base/'service').exists(),'Do not restart IKE or issue another PUSH')
        self.assertEqual((self.base/'ike-calls').read_text(),'ready\n')
    def test_guard_resumes_only_selected_guest_and_radio_bands(self):
        self.suspended_ikev2_runtime()
        for selections,expected in [
            ({'wireless.guest_2g.disabled':'1'},['wlan3']),
            ({'wireless.wifi1.disabled':'1'},['wlan1']),
            ({'wireless.guest_2g.disabled':'1','wireless.wifi1.disabled':'1'},[]),
        ]:
            with self.subTest(selections=selections):
                self.write('data/zte-vpn/configured','')
                for name in ['wlan1','wlan3']:(self.base/('ap-up-'+name)).unlink(missing_ok=True)
                self.write('wireless-selections',''.join(k+'='+v+'\n' for k,v in selections.items()))
                self.ok(self.invoke('run-guard'))
                self.assertEqual([name for name in ['wlan1','wlan3'] if (self.base/('ap-up-'+name)).exists()],expected)
                self.assertFalse((self.base/'reload').exists())
                self.assertFalse((self.base/'wifi').exists())
    def test_user_disabling_during_direct_resume_puts_the_port_back_down(self):
        self.suspended_ikev2_runtime()
        self.ok(self.invoke('run-guard',DISABLE_DURING_RESUME='1'))
        self.assertFalse(any((self.base/('ap-up-'+name)).exists() for name in ['wlan1','wlan3']))
        self.assertEqual((self.base/'wireless-disabled').read_text(),'1')
        self.assertFalse((self.base/'reload').exists())
    def test_guard_never_resumes_ports_before_security_dns_bridge_and_hostapd_readiness(self):
        self.suspended_ikev2_runtime()
        for missing in ['dns','firewall','bridge','hostapd','ipa']:
            with self.subTest(missing=missing):
                self.write('data/zte-vpn/configured','')
                for name in ['wlan1','wlan3']:(self.base/('ap-up-'+name)).unlink(missing_ok=True)
                self.write('proc/40/cmdline','--conf-file='+str(self.root/'ikev2/dnsmasq.conf')+'\0')
                self.write('data/zte-vpn/firewall.sh','#!/bin/sh\nexit '+('1' if missing=='firewall' else '0')+'\n',0o700)
                master=self.base/'sys/class/net/wlan1/master';master.unlink();master.symlink_to(self.base/'sys/class/net'/('br-lan' if missing=='bridge' else 'br-vpn'))
                if missing=='dns':(self.base/'proc/40/cmdline').unlink()
                if missing=='ipa':self.write('proc/sys/kernel/random/boot_id','changed-boot')
                self.ok(self.invoke('run-guard',DISABLED_HOSTAPD='wlan1' if missing=='hostapd' else ''))
                self.assertFalse(any((self.base/('ap-up-'+name)).exists() for name in ['wlan1','wlan3']))
    def test_user_disabling_while_guard_waits_is_not_overridden(self):
        self.ok(self.invoke());self.ready_runtime();self.write('wireless-disabled','0')
        (self.base/'proc/40/cmdline').unlink()
        self.command('sleep',r'''import os
from pathlib import Path
b=Path(os.environ['FIXTURE'])
if not (b/'changed').exists():
 (b/'changed').touch();(b/'wireless-disabled').write_text('1')
 (b/'proc/40/cmdline').write_bytes(('--conf-file='+str(b/'data/zte-vpn/dnsmasq.conf')).encode()+b'\0')
else:(b/'data/zte-vpn/configured').unlink()
''',python=True)
        self.ok(self.invoke('run-guard'))
        self.assertFalse((self.base/'reload').exists())
        self.assertFalse((self.base/'wifi').exists())
        self.assertEqual((self.base/'wireless-disabled').read_text(),'1')
    def test_ipacm_restart_restarts_verified_core_through_one_ipa_worker(self):
        self.ok(self.invoke());self.ready_runtime();self.write('wireless-disabled','0')
        self.write('data/zte-vpn/mihomo','#!/bin/sh\necho started > "$FIXTURE/core-started"\n',0o700)
        (self.base/'proc/11').mkdir();(self.base/'proc/11/exe').symlink_to(self.base/'usr/bin/ipacm')
        self.command('pidof','echo "20 11"')
        self.command('sleep',r'''import os,subprocess
from pathlib import Path
b=Path(os.environ['FIXTURE'])
if not (b/'respawned').exists():
 assert (b/'core-signals').read_text()=='-TERM 30\n'
 assert not (b/'proc/30/cmdline').exists()
 # Simulate procd respawning the real production run-core path.
 subprocess.run(['/bin/sh',str(b/'manager.sh'),'run-core'],check=True,env=os.environ)
 (b/'respawned').touch();(b/'data/zte-vpn/core.pid').write_text('31')
 (b/'proc/31').mkdir();(b/'proc/31/cmdline').write_bytes(str(b/'data/zte-vpn/mihomo').encode()+b'\0')
 (b/'proc/31/exe').symlink_to(b/'data/zte-vpn/mihomo')
else:(b/'data/zte-vpn/configured').unlink()
''',python=True)
        self.ok(self.invoke('run-guard'))
        self.assertEqual((self.base/'core-signals').read_text(),'-TERM 30\n')
        self.assertEqual(self.signals()[-1],'-USR1 11')
        self.assertTrue((self.base/'core-started').exists())
        self.assertFalse((self.base/'wifi').exists())
    def test_ttl_disable_close_zero_keeps_runtime_proof_without_extra_signal(self):
        self.write('wireless-disabled','0')
        self.ok(self.invoke());self.write('pending','other.ipa_disable=1\ntmp_router.close_ipa_acce=0\n')
        self.write('data/zte-vpn/mihomo','#!/bin/sh\nexit 0\n',0o700)
        count=len(self.signals());self.ok(self.invoke('run-core'));self.assertEqual(len(self.signals()),count)
        self.ok(self.invoke('disable'));self.assertEqual(self.state()['other.ipa_disable'],'1')
        self.assertTrue((self.root/'ipa-backup').exists())
    def test_first_partial_network_apply_restores_and_retry_succeeds(self):
        self.clean_start();r=self.invoke(FAIL_APPLY='1');self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.base/'etc/init.d/network').read_text(),'original-network-init')
        self.assertEqual((self.base/'etc/config/network').read_text(),'original-network')
        self.assertFalse((self.root/'configured').exists());self.assertFalse((self.root/'backup').exists())
        self.assertEqual(self.state()['other.ipa_disable'],'0');self.assertTrue((self.root/'backup.failed').exists())
        self.ok(self.invoke());self.assertTrue((self.root/'configured').exists())
    def test_first_bridge_failure_rolls_back_network_and_ipa(self):
        self.clean_start();r=self.invoke(NO_BRIDGE='1');self.assertNotEqual(r.returncode,0);self.assertIn('VPN_BRIDGE_NOT_READY',r.stderr)
        self.assertFalse((self.root/'configured').exists());self.assertEqual(self.state()['other.ipa_disable'],'0')
        self.assertEqual((self.base/'etc/init.d/network').read_text(),'original-network-init')
    def test_existing_configured_failure_keeps_software_policy(self):
        r=self.invoke(FAIL_SIGNAL='1');self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.state()['other.ipa_disable'],'1');self.assertTrue((self.root/'ipa-backup').exists())
        self.assertNotIn('-USR2 10',self.signals());self.assertTrue((self.base/'wifi').exists())
    def test_ttl_is_optional_but_active_or_unknown_policy_stays_software(self):
        for settings in ['outbound=64\ninbound_inc=off\n','unrecognized\n']:
            with self.subTest(settings=settings):
                self.ok(self.invoke())
                self.write('data/zte-imei-ttl/owner','zte-imei-ttl-v1');self.write('data/zte-imei-ttl/cid','a'*32+'\n');self.write('data/zte-imei-ttl/settings',settings)
                self.ok(self.invoke('ipa-restore'));self.assertEqual(self.state()['other.ipa_disable'],'0')
                self.assertEqual(self.state(True)['tmp_router.close_ipa_acce'],'1');self.assertEqual(self.signals()[-1],'-USR1 10')
    def test_external_changed_policy_is_not_overwritten_or_enabled(self):
        self.ok(self.invoke());self.router=self.state();self.router['other.ipa_disable']='0';self.router['other.later']='keep';self.save_router()
        self.write('pending','tmp_router.close_ipa_acce=0\n');before=len(self.signals())
        self.ok(self.invoke('ipa-restore'));self.assertEqual(self.state()['other.later'],'keep')
        self.assertEqual(self.state(True),{'tmp_router.close_ipa_acce':'0'});self.assertEqual(len(self.signals()),before)
    def test_corrupt_snapshot_prevents_restore(self):
        self.ok(self.invoke());(self.root/'ipa-backup/state').write_text('private-untrusted-state')
        before=(self.base/'etc/config/zwrt_router').read_bytes();r=self.invoke('ipa-restore')
        self.assertNotEqual(r.returncode,0);self.assertIn('VPN_IPA_RESTORE_FAILED',r.stderr);self.assertNotIn('private-untrusted-state',r.stdout+r.stderr)
        self.assertEqual((self.base/'etc/config/zwrt_router').read_bytes(),before)
    def test_interrupted_first_prepare_recovery_uses_snapshot(self):
        self.clean_start();self.ok(self.invoke())
        # Simulate loss before the atomic configured publish.
        (self.root/'configured').rename(self.root/'configuring')
        self.ok(self.invoke('recover'));self.assertEqual(self.state()['other.ipa_disable'],'0')
        self.assertEqual((self.base/'etc/init.d/network').read_text(),'original-network-init')

if __name__=='__main__':unittest.main()
