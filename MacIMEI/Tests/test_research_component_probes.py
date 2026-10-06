#!/usr/bin/env python3
"""Execute the actual revision-10 shell with a private, mechanical namespace map.

No device, service, network, APDU or installed component is invoked. Fake tools
record all requests and return synthetic private fields to check projection.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SPEC = REPO / 'MacIMEI/Resources/FirmwareResearch/probes.json'
IDS = ['component-rpc-schemas', 'agent-runtime-mode', 'wifi-runtime-shape',
       'vpn-installation-state', 'vpn-kernel-routing', 'launcher-runtime-state',
       'ttl-apn-state', 'esim-passive-dependencies', 'component-install-dependencies']
CANARY = 'PRIVATE_SENTINEL_PASSWORD_7391'

FAKE = r'''
import hashlib,json,os,stat,sys
from pathlib import Path
cmd=Path(sys.argv[0]).name;args=sys.argv[1:]
cfg=json.loads(Path(os.environ['FIXTURE_CONFIG']).read_text())
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write(json.dumps([cmd,*args])+'\n')
if cmd in cfg.get('fail',[]):
 print('PRIVATE_SENTINEL_PASSWORD_7391');print('PRIVATE_SENTINEL_PASSWORD_7391',file=sys.stderr);sys.exit(2)
root=Path(os.environ['FIXTURE_ROOT'])
if cmd=='ubus':
 if 'list' in args and '-v' in args:
  obj=args[-1]
  if obj not in cfg.get('schemas',{}):sys.exit(4)
  print(cfg['schemas'][obj]);sys.exit()
 if 'call' not in args:sys.exit(7)
 i=args.index('call');obj,method=args[i+1:i+3]
 allowed={('service','list'),('zwrt_apn_object','get_apn_mode')}
 if (obj,method) not in allowed:print('FORBIDDEN_METHOD',file=sys.stderr);sys.exit(9)
 print(json.dumps(cfg.get('responses',{}).get(obj,{})));sys.exit()
if cmd=='jsonfilter':
 try:
  data=json.loads(args[args.index('-s')+1]);key=args[args.index('-e')+1][2:]
  for part in key.split('.'):data=data[part]
  if isinstance(data,(dict,list)):print(json.dumps(data))
  elif isinstance(data,bool):print(str(data).lower())
  else:print(data)
 except (KeyError,ValueError,IndexError,TypeError):sys.exit(1)
elif cmd=='uci':
 if args[:2]!=['-q','get']:sys.exit(9)
 key=args[-1]
 if key not in cfg.get('uci',{}):sys.exit(1)
 print(cfg['uci'][key])
elif cmd=='hostapd_cli':
 if args[-1]!='status':sys.exit(9)
 print(cfg.get('hostapd','state=ENABLED\nssid=PRIVATE_SENTINEL_PASSWORD_7391\nbssid=12:34:56:78:9a:bc'))
elif cmd=='curl':
 assert args[0]=='-q' and args[args.index('--output')+1]=='/dev/null'
 assert args[-1] in ['http://127.0.0.1:9090/api/health','http://127.0.0.1:9090/api/capabilities']
 print(cfg.get('http','401'),end='')
elif cmd=='pidof':
 if not cfg.get('pids'):sys.exit(1)
 print(' '.join(map(str,cfg['pids'])))
elif cmd=='stat':
 p=args[-1]
 try:m=os.lstat(p)
 except OSError:sys.exit(1)
 fmt=args[args.index('-c')+1]
 values={'%s':str(m.st_size),'%u':'0','%a':oct(stat.S_IMODE(m.st_mode))[2:],'%h':str(m.st_nlink)}
 if fmt not in values:sys.exit(3)
 print(values[fmt])
elif cmd=='readlink':
 try:print(os.readlink(args[-1]))
 except OSError:sys.exit(1)
elif cmd=='sha256sum':
 try:b=Path(args[-1]).read_bytes()
 except OSError:sys.exit(1)
 print(hashlib.sha256(b).hexdigest()+'  '+args[-1])
elif cmd=='ip':
 key=' '.join(args)
 allowed={'-4 route show table 19090','-4 rule show','-4 route show'}
 if key not in allowed:sys.exit(9)
 print(cfg.get('ip',{}).get(key,''))
else:sys.exit(11)
'''


class ComponentProbes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='research-components-', dir='/private/tmp')
        self.root = Path(self.temp.name)/'root'
        self.bin = Path(self.temp.name)/'bin';self.bin.mkdir()
        for p in ['data','etc','proc','proc/net','sys/module','sys/class/net','tmp','dev','usr','usr/bin','etc/init.d','etc/hotplug.d/iface']:
            (self.root/p).mkdir(parents=True,exist_ok=True)
        for name in ['sh','awk','tr','head','cat','cmp']:
            real = '/bin/'+name if Path('/bin/'+name).exists() else '/usr/bin/'+name
            (self.bin/name).symlink_to(real)
        for name in ['ubus','jsonfilter','uci','hostapd_cli','curl','pidof','stat','readlink','sha256sum','ip']:
            (self.bin/name).write_text('#!'+sys.executable+'\n'+FAKE)
            (self.bin/name).chmod(0o700)
        self.config = Path(self.temp.name)/'config.json'
        self.calls = Path(self.temp.name)/'calls.jsonl'
        self.cfg = {'schemas': {'zwrt_wlan': '\'zwrt_wlan\' @12345678\n "report":{}\n "reload":{"enable":"Boolean","password":"String","evil_secret_name":"String"}\n "PRIVATE_SENTINEL_PASSWORD_7391":{}'},
                    'responses':{'zwrt_apn_object':{'apn_mode':1,'password':CANARY},'service':{'zte_topsw_devui':{'instances':{'instance1':{'pid':41,'env':{'PASSWORD':CANARY}}}}}},
                    'uci':{'wireless.guest_2g.disabled':'1','wireless.guest_5g.disabled':'0','wireless.guest_2g.network':'vpn','wireless.guest_2g.bridge':'br-vpn','wireless.guest_2g.guest_active_time':'240','wireless.guest_5g.guest_active_time':'0'},
                    'pids':[42], 'http':'401'}
        self.env={**os.environ,'FIXTURE_ROOT':str(self.root),'FIXTURE_CONFIG':str(self.config),'FIXTURE_CALLS':str(self.calls)}

    def tearDown(self):self.temp.cleanup()

    def file(self, name, content=b'', mode=0o600):
        p=self.root/name.lstrip('/');p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(content.encode() if isinstance(content,str) else content);p.chmod(mode);return p

    def link(self,name,target):
        p=self.root/name.lstrip('/');p.parent.mkdir(parents=True,exist_ok=True)
        p.symlink_to(str(self.root/target.lstrip('/')));return p

    def execute(self,id):
        self.config.write_text(json.dumps(self.cfg))
        spec=json.loads(SPEC.read_text());body=next(p['command'] for p in spec['probes'] if p['id']==id)
        body=body.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+str(self.bin))
        body=re.sub(r'(?<![A-Za-z0-9_/])/(data|etc|proc|sys|tmp)(?=/|[\s"\'])',lambda m:str(self.root)+m.group(0),body)
        body=body.replace('/usr/bin/zte_topsw_devui',str(self.root)+'/usr/bin/zte_topsw_devui')
        body=body.replace('/dev/diag',str(self.root)+'/dev/diag')
        before=self.snapshot()
        result=subprocess.run(['/bin/sh','-c',body],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn(CANARY,result.stdout+result.stderr)
        self.assertEqual(before,self.snapshot(),'probe changed its filesystem')
        facts=dict(l[8:].split('=',1) for l in result.stdout.splitlines() if l.startswith('FR_FACT '))
        return facts,result.stdout

    def snapshot(self):
        result={}
        for p in self.root.rglob('*'):
            if p.is_symlink():result[str(p)]=('link',os.readlink(p))
            elif p.is_file():result[str(p)]=(p.stat().st_mode,p.read_bytes())
            else:result[str(p)]=('dir',p.stat().st_mode)
        return result

    def agent(self,env=b'ZTE_AGENT_MODE=discovery\0PASSWORD=PRIVATE_SENTINEL_PASSWORD_7391\0'):
        self.file('/data/zte-agent',b'ELFsynthetic')
        self.link('/proc/42/exe','/data/zte-agent')
        self.file('/proc/42/environ',env)

    def test_schema_types_only_no_invoke_or_arbitrary_names(self):
        f,out=self.execute(IDS[0]);self.assertEqual(f['rpc_zwrt_wlan_methods'],'2')
        self.assertIn('FIELD<password> TYPE<String>',out)
        self.assertNotIn('evil_secret_name',out)
        self.assertEqual(f['rpc_zwrt_wlan_unlisted_arguments'],'1')
        calls=[json.loads(x) for x in self.calls.read_text().splitlines()]
        self.assertFalse(any('call' in x for x in calls))
        # Schema formatting survives the production credential-label patterns:
        for line in out.splitlines():
            self.assertFalse(re.search(r'(?i)(?:password|token|secret)["\']?\s*(?:[:=]|[ \t]+[^\s])',line))

    def test_schema_malformed_value_and_duplicate_are_unassessed(self):
        self.cfg['schemas']['zwrt_wlan']=' "report":{"password":"'+CANARY+'"}\n "report":{}'
        f,_=self.execute(IDS[0]);self.assertEqual(f['rpc_zwrt_wlan_schema'],'not-assessed')

    def test_schema_command_failure_is_not_empty_inventory(self):
        self.cfg['fail']=['ubus'];f,_=self.execute(IDS[0]);self.assertEqual(f['rpc_zwrt_wlan_schema'],'not-assessed')

    def test_exact_application_method_names_and_parameter_types(self):
        self.cfg['schemas']['zte_nwinfo_api']='\'zte_nwinfo_api\' @1\n "nwinfo_lock_lte_cell":{"pci":"Integer"}\n "nwinfo_reset_band_cell_setting":{}'
        self.cfg['schemas']['zwrt_apn_object']='\'zwrt_apn_object\' @2\n "enable_manu_apn_id":{"profileId":"String"}\n "add_manu_apn":{"wanapn":"String","pdpType":"Integer","pppAuthMode":"Integer"}'
        self.cfg['schemas']['zwrt_zte_mdm.api']='\'zwrt_zte_mdm.api\' @3\n "get_imei":{}\n "get_imei2":{}'
        f,out=self.execute(IDS[0])
        for name in ['nwinfo_lock_lte_cell','nwinfo_reset_band_cell_setting','enable_manu_apn_id','get_imei','get_imei2']:
            self.assertRegex(out,r'RPC_METHOD [^\n]+\.'+name+r'\n')
        self.assertIn('FIELD<profileId> TYPE<String>',out)
        self.assertIn('FIELD<wanapn> TYPE<String>',out)
        self.assertEqual(f['rpc_zte_nwinfo_api_schema'],'known')
        self.assertFalse(any('call' in json.loads(x) for x in self.calls.read_text().splitlines()))

    def test_successful_but_unrecognized_schema_is_not_assessed(self):
        for text in ['',CANARY,' "report":{}']:
            self.cfg['schemas']['zwrt_wlan']=text
            f,_=self.execute(IDS[0]);self.assertEqual(f['rpc_zwrt_wlan_schema'],'not-assessed')

    def test_observed_router_charger_battery_argument_names(self):
        self.cfg['schemas']['zwrt_router.api']='\'zwrt_router.api\' @1\n "router_set_lan_para":{"ignore":"Integer","zte_start":"String","leasetime":"String"}\n "router_set_wan_dns":{"dns_mode":"String","prefer_dns_manual":"String"}'
        self.cfg['schemas']['zwrt_bsp.charger']='\'zwrt_bsp.charger\' @2\n "set":{"direct_power_supply_mode":"String","ship_mode":"String","(unknown)"}'
        self.cfg['schemas']['zwrt_bsp.battery']='\'zwrt_bsp.battery\' @3\n "list":{"battery_capacity":"Integer"}'
        f,out=self.execute(IDS[0])
        for arg in ['ignore','zte_start','leasetime','dns_mode','prefer_dns_manual','direct_power_supply_mode','ship_mode','battery_capacity']:
            self.assertIn('FIELD<'+arg+'> TYPE<',out)
        self.assertEqual(f['rpc_zwrt_bsp_charger_schema'],'not-assessed')
        self.assertEqual(f['rpc_zwrt_bsp_charger_unnamed_arguments'],'1')

    def test_observed_unknown_ubus_types_kept_without_values(self):
        self.cfg['schemas']['zwrt_data']='\'zwrt_data\' @1\n "get_wwandst":{"source_module":"String","real_tx_bytes":"(unknown)","real_his_index%d":"String"}'
        f,out=self.execute(IDS[0]);self.assertIn('FIELD<real_tx_bytes> TYPE<unknown>',out)
        self.assertIn('FIELD<real_his_index%d> TYPE<String>',out)
        self.assertEqual(f['rpc_zwrt_data_unknown_types'],'1')
        self.assertEqual(f['rpc_zwrt_data_schema'],'not-assessed')

    def test_discovery_mode_http_401_not_broken(self):
        self.agent();f,_=self.execute(IDS[1]);self.assertEqual(f['agent_runtime_mode'],'discovery')
        self.assertEqual(f['agent_runtime_mapped_matches'],'1');self.assertEqual(f['agent_loopback_health_http'],'401')
        self.assertEqual(f['agent_auth_attempted'],'0')

    def test_duplicate_and_unknown_environment_do_not_leak(self):
        for env,want in [(b'ZTE_AGENT_MODE=normal\0ZTE_AGENT_MODE=discovery\0','ambiguous'),(b'ZTE_AGENT_MODE=PRIVATE_SENTINEL_PASSWORD_7391\0','unknown'),(b'PASSWORD=PRIVATE_SENTINEL_PASSWORD_7391\0','default')]:
            self.agent(env);f,_=self.execute(IDS[1]);self.assertEqual(f['agent_runtime_mode'],want)
            (self.root/'proc/42/exe').unlink()

    def test_multiple_owned_processes_ambiguous(self):
        self.agent();self.link('/proc/43/exe','/data/zte-agent');self.cfg['pids']=[42,43]
        f,_=self.execute(IDS[1]);self.assertEqual(f['agent_runtime_mode'],'ambiguous')

    def test_agent_commands_fail_closed(self):
        self.cfg['fail']=['pidof','curl'];f,_=self.execute(IDS[1])
        self.assertEqual(f['agent_owned_process_count'],'not-assessed');self.assertEqual(f['agent_loopback_health_http'],'not-assessed')

    def test_wifi_timers_and_projection(self):
        f,out=self.execute(IDS[2]);self.assertEqual(f['wifi_guest_2g_guest_active_time'],'240')
        self.assertEqual(f['wifi_guest_5g_guest_active_time'],'0');self.assertEqual(f['wifi_wlan1_hostapd_state'],'ENABLED')
        self.assertNotIn('12:34:56:78:9a:bc',out)
        calls=[json.loads(x) for x in self.calls.read_text().splitlines()]
        self.assertTrue(all(x[1:3]==['-q','get'] for x in calls if x[0]=='uci'))

    def test_wifi_private_scalar_and_failure_unassessed(self):
        self.cfg['uci']['wireless.guest_2g.guest_active_time']=CANARY
        self.cfg['hostapd']='state='+CANARY+'\nstate=ENABLED'
        f,_=self.execute(IDS[2]);self.assertEqual(f['wifi_guest_2g_guest_active_time'],'not-assessed')
        self.assertEqual(f['wifi_wlan1_hostapd_state'],'not-assessed')
        self.cfg['fail']=['uci','hostapd_cli'];f,_=self.execute(IDS[2]);self.assertEqual(f['wifi_guest_2g_disabled'],'not-assessed')

    def test_vpn_missing_service_reset_and_hash_match(self):
        self.file('/data/zte-vpn/owner','zte-vpn-v1')
        network=self.file('/etc/init.d/network','synthetic stock',0o775)
        self.file('/data/zte-vpn/network-init',hashlib.sha256(network.read_bytes()).hexdigest()+'\n')
        f,_=self.execute(IDS[3]);self.assertEqual(f['vpn_owner_matches'],'1')
        self.assertEqual(f['vpn_service_matches'],'missing');self.assertEqual(f['vpn_network_matches_saved'],'1')

    def test_vpn_unsafe_hash_path_and_private_marker_not_exported(self):
        self.file('/data/private',CANARY);self.link('/data/zte-vpn/vpnctl','/data/private')
        self.file('/data/zte-vpn/network-init',CANARY)
        f,_=self.execute(IDS[3]);self.assertEqual(f['vpn_vpnctl_sha256'],'symlink')
        self.assertEqual(f['vpn_network_matches_saved'],'not-assessed')

    def test_vpn_routing_counts_not_addresses(self):
        self.file('/proc/modules','tun 0 0 - Live 0x0\nnf_tables 0 0 - Live 0x0\n')
        self.cfg['ip']={'-4 route show table 19090':'default dev zvpn-tun','-4 rule show':'19000: from all fwmark 0x40000000 lookup 19090','-4 route show':'192.168.50.0/24 dev br-vpn\n10.22.33.0/24 dev secret'}
        f,out=self.execute(IDS[4]);self.assertEqual(f['vpn_table19090_rows'],'1')
        self.assertEqual(f['vpn_reserved_subnet_rows'],'1');self.assertNotIn('10.22.33',out)
        self.cfg['fail']=['ip'];f,_=self.execute(IDS[4]);self.assertEqual(f['vpn_table19090_rows'],'not-assessed')

    def test_launcher_pid_mapped_ready_and_fixed_failure(self):
        self.file('/usr/bin/zte_topsw_devui','ELF')
        self.link('/proc/41/exe','/usr/bin/zte_topsw_devui')
        self.file('/proc/41/maps','1 2 3 4 5 '+str(self.root)+'/data/zte-launcher/launcher.so\n')
        self.file('/tmp/zte-launcher/ready','41\n')
        self.file('/data/zte-launcher/failed','NO_PAGES\n')
        f,_=self.execute(IDS[5]);self.assertEqual(f['launcher_extension_mapped'],'1')
        self.assertEqual(f['launcher_ready_matches'],'1');self.assertEqual(f['launcher_failure_reason'],'NO_PAGES')

    def test_launcher_unknown_failure_is_fixed_unknown(self):
        self.file('/data/zte-launcher/failed',CANARY);f,_=self.execute(IDS[5]);self.assertEqual(f['launcher_failure_reason'],'unknown')

    def test_launcher_vpn_error_fixed_fields_and_private_code(self):
        line='operation=change ok=0 code=VPN_BUSY status_valid=1 exit=1 proof_valid=1 timed_out=0 cleanup_complete=1 read_errno=0 write_errno=0 wait_errno=0\n'
        self.file('/tmp/zte-launcher/vpn-error',line)
        f,_=self.execute(IDS[5]);self.assertEqual(f['launcher_vpn_error_code'],'VPN_BUSY')
        self.assertEqual(f['launcher_vpn_error_proof_valid'],'1')
        self.file('/tmp/zte-launcher/vpn-error',line.replace('VPN_BUSY',CANARY))
        f,_=self.execute(IDS[5]);self.assertEqual(f['launcher_vpn_error_code'],'unknown')

    def test_launcher_vpn_error_malformed_or_symlink_not_exported(self):
        p=self.file('/tmp/zte-launcher/vpn-error','operation=change code='+CANARY+'\n')
        f,_=self.execute(IDS[5]);self.assertEqual(f['launcher_vpn_error_metadata'],'not-assessed')
        p.unlink();self.file('/data/private',CANARY);self.link('/tmp/zte-launcher/vpn-error','/data/private')
        f,_=self.execute(IDS[5]);self.assertEqual(f['launcher_vpn_error_metadata'],'not-assessed')

    def test_ttl_and_apn_whitelist(self):
        self.file('/data/zte-imei-ttl/settings','outbound=64\ninbound_inc=1\n')
        f,_=self.execute(IDS[6]);self.assertEqual(f['ttl_saved_outbound'],'64');self.assertEqual(f['apn_mode'],'1')
        self.file('/data/zte-imei-ttl/settings','outbound=64\ninbound_inc=1\npassword='+CANARY)
        self.cfg['responses']['zwrt_apn_object']['apn_mode']=CANARY
        f,_=self.execute(IDS[6]);self.assertEqual(f['ttl_settings_valid'],'0');self.assertEqual(f['apn_mode'],'not-assessed')

    def test_esim_remains_unknown_without_card_commands(self):
        self.file('/tmp/zte-euicc-card.lock','',0o600)
        f,_=self.execute(IDS[7]);self.assertEqual(f['esim_physical_card_kind'],'unknown')
        self.assertEqual(f['esim_apdu_performed'],'0');self.assertEqual(f['esim_card_flock_bytes'],'0')
        self.assertFalse(any(json.loads(x)[0]=='ubus' for x in self.calls.read_text().splitlines()))

    def test_install_metadata_does_not_require_private_mode_for_oem(self):
        self.file('/etc/rc.local',CANARY,0o775)
        f,out=self.execute(IDS[8]);self.assertEqual(f['component_rc_local_mode'],'775')
        self.assertEqual(f['component_startup_contents_read'],'0');self.assertNotIn('0:0:775',out)

    def test_all_groups_missing_tools_no_writes_or_secret(self):
        for name in ['ubus','pidof','stat','uci','awk']:(self.bin/name).unlink()
        for id in IDS:
            f,_=self.execute(id);self.assertEqual(f['probe_tools'],'not-assessed')

    def test_spec_mirror_unique_and_prior_groups_unchanged(self):
        blob=SPEC.read_bytes();s=json.loads(blob)
        self.assertEqual(blob,(REPO/'Windows_x64/Resources/FirmwareResearch/probes.json').read_bytes())
        baseline=json.loads(subprocess.check_output(['git','show','814a5a1:MacIMEI/Resources/FirmwareResearch/probes.json'],cwd=REPO))
        self.assertEqual(s['probes'][:46],baseline['probes']);self.assertEqual(s['features'],baseline['features'])
        self.assertEqual(s['revision'],10);self.assertEqual(len(s['probes']),55)
        self.assertLessEqual(len(s['probes']),64);self.assertEqual(len({p['id'] for p in s['probes']}),55)
        self.assertEqual(len({o['id'] for o in s['observations']}),len(s['observations']))
        for p in s['probes']:
            r=subprocess.run(['/bin/sh','-n'],input=p['command'],text=True,capture_output=True)
            self.assertEqual(r.returncode,0,(p['id'],r.stderr))


if __name__=='__main__':unittest.main(verbosity=2)
