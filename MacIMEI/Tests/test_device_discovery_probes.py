#!/usr/bin/env python3
"""Offline fixtures for exact spec8 shell commands; no device or network."""
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / 'MacIMEI/Resources/FirmwareResearch/probes.json'
CANARY = 'PRIVATE_PASSWORD_IMEI_TOKEN_MUST_NOT_APPEAR'

class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='discovery-fixture-')
        self.root = Path(self.tmp.name).resolve()
        self.tools = self.root / 'tools'; self.tools.mkdir()
        self.fs = self.root / 'fs'; self.fs.mkdir()
    def close(self): self.tmp.cleanup()
    def file(self, path, content=b''):
        p=self.fs/path.lstrip('/');p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(content if isinstance(content,bytes) else content.encode());return p
    def directory(self,path):
        p=self.fs/path.lstrip('/');p.mkdir(parents=True,exist_ok=True);return p
    def tool(self,name,body):
        p=self.tools/name
        if p.is_symlink():p.unlink()
        p.write_text('#!'+sys.executable+'\n'+body+'\n');p.chmod(0o700)
    def standard(self,*names):
        for name in names:
            source=next((Path(p)/name for p in ('/usr/bin','/bin') if (Path(p)/name).exists()),None)
            assert source,name
            (self.tools/name).symlink_to(source)
    def cap_tools(self): self.standard('head','tr','awk','cat')
    def sha(self, *, busybox=False, fail=False):
        self.tool('busybox' if busybox else 'sha256sum',
            'import hashlib,sys,pathlib\n'+
            ('assert sys.argv[1]=="sha256sum"\nsys.argv.pop(1)\n' if busybox else '')+
            ('sys.exit(1)\n' if fail else '')+
            'data=pathlib.Path(sys.argv[1]).read_bytes() if len(sys.argv)>1 else sys.stdin.buffer.read()\n'
            'print(hashlib.sha256(data).hexdigest()+"  "+(sys.argv[1] if len(sys.argv)>1 else "-"))')
    def run(self,name):
        spec=json.loads(SPEC.read_text());probe=next(x for x in spec['probes'] if x['id']==name)
        command=probe['command']
        command=re.sub(r'(?<![A-Za-z0-9_.-])/(proc|sys|dev|lib64|lib|usr|bin|sbin|data|etc|overlay|tmp|var)(?=[/\s\"\'\);:]|$)',
            lambda m: m.group(0) if m.group(1)=='dev' and command[m.end():].startswith('/null') else str(self.fs)+'/'+m.group(1),command)
        command=re.sub(r'(?m)^export PATH=.*? LC_ALL=C$', 'export PATH='+str(self.tools)+' LC_ALL=C', command)
        if name=='mounts':
            command=re.sub(r'([A-Za-z_]+):'+re.escape(str(self.fs))+r'/', r'\1:/', command)
        before={str(p.relative_to(self.root)):p.read_bytes() for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}
        result=subprocess.run(['/bin/sh','-c',command],capture_output=True,timeout=10,env={**os.environ,'LC_ALL':'C'})
        after={str(p.relative_to(self.root)):p.read_bytes() for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}
        assert before==after,'Probe wrote fixture files'
        assert CANARY.encode() not in result.stdout+result.stderr, 'Private fixture escaped output'
        assert len(result.stdout)+len(result.stderr)<=probe['maxBytes'], 'Probe exceeded output budget'
        text=result.stdout.decode()
        facts={}
        for line in text.splitlines():
            if line.startswith('FR_FACT '):
                key,value=line[8:].split('=',1);assert key not in facts,(name,key);facts[key]=value
        return result,text,facts

class DiscoveryTests(unittest.TestCase):
    def setUp(self): self.f=Fixture()
    def tearDown(self): self.f.close()
    def run_probe(self,name):
        result,text,facts=self.f.run(name);self.assertEqual(result.returncode,0,result.stderr.decode());return text,facts
    def test_mirror_shape_and_shell_syntax(self):
        s=json.loads(SPEC.read_text());self.assertEqual(s['revision'],8);self.assertEqual(len(s['probes']),46)
        self.assertEqual(SPEC.read_bytes(),(ROOT/'Windows_x64/Resources/FirmwareResearch/probes.json').read_bytes())
        self.assertEqual(len({p['id'] for p in s['probes']}),46)
        self.assertEqual(len({o['id'] for o in s['observations']}),len(s['observations']))
        for o in s['observations']: self.assertIn(o['probe'],[p['id'] for p in s['probes']])
        for p in s['probes']:
            r=subprocess.run(['/bin/sh','-n'],input=p['command'],text=True,capture_output=True);self.assertEqual(r.returncode,0,(p['id'],r.stderr))
        for feature in s['features']:
            if feature['id'] in ('preparation','ssh','generic-access'):self.assertEqual(feature['profiles'],[])
            elif feature['id']!='native-esim':self.assertTrue(feature['profiles'])
    def test_fingerprint_no_tools_preserves_survey(self):
        self.f.file('/sys/block/mmcblk0/device/cid','fixture-cid\n');self.f.file('/proc/sys/kernel/random/boot_id','fixture-boot\n')
        _,facts=self.run_probe('fingerprint');self.assertEqual(facts['hasher'],'not-assessed')
        self.assertEqual(facts['cid_sha256'],'not-assessed');self.assertEqual(facts['boot_sha256'],'not-assessed')
    def test_fingerprint_absent_vs_inaccessible_parent(self):
        self.f.directory('/proc/sys/kernel/random')
        _,facts=self.run_probe('fingerprint');self.assertEqual(facts['boot_sha256'],'missing');self.assertEqual(facts['cid_sha256'],'not-assessed')
    def test_fingerprint_busybox_fallback_and_read_failure(self):
        self.f.sha(busybox=True);self.f.file('/proc/sys/kernel/random/boot_id','fixture-boot\n')
        _,facts=self.run_probe('fingerprint');self.assertEqual(facts['hasher'],'busybox-sha256sum')
        self.assertEqual(facts['boot_sha256'],hashlib.sha256(b'fixture-boot\n').hexdigest())
        self.f.sha(fail=True);_,facts=self.run_probe('fingerprint');self.assertEqual(facts['boot_sha256'],'not-assessed')
    def test_nonroot_unknown_arch_and_uid_proc_fallback(self):
        self.f.file('/proc/self/status','Name:\tsh\nUid:\t1000\t2000\t1000\t2000\nSeccomp:\t2\n')
        _,facts=self.run_probe('identity');self.assertEqual(facts['uid'],'2000');self.assertEqual(facts['root'],'0');self.assertEqual(facts['architecture'],'not-assessed')
    def test_optional_hash_does_not_hide_runtime_paths(self):
        self.f.file('/usr/lib/libubus.so',b'fixture');self.f.directory('/lib')
        _,facts=self.run_probe('runtime-libraries');self.assertEqual(facts['runtime_libubus'],'present');self.assertEqual(facts['runtime_libc'],'missing')
        self.assertEqual(facts['libdiag_sha256'],'missing')
    def test_unknown_elf32_64_both_endian(self):
        self.f.cap_tools();self.f.standard('od')
        for cls,endian,machine in [(1,1,40),(2,1,183),(1,2,8),(2,2,62)]:
            header=bytearray(64);header[:7]=b'\x7fELF'+bytes([cls,endian,1]);struct.pack_into('<HH' if endian==1 else '>HH',header,16,3,machine)
            self.f.file('/bin/sh',bytes(header));_,facts=self.run_probe('elf-abi')
            self.assertEqual(facts['elf_shell_class'],str(32 if cls==1 else 64));self.assertEqual(facts['elf_shell_machine'],str(machine))
            self.assertEqual(facts['elf_shell_endian'],'little' if endian==1 else 'big')
            self.assertEqual(facts['elf_shell_interpreter'],'not-assessed')
    def test_malformed_elf_is_not_inferred_from_uname(self):
        self.f.cap_tools();self.f.standard('od');self.f.file('/bin/sh',b'not elf')
        _,facts=self.run_probe('elf-abi');self.assertEqual(facts['elf_shell_class'],'not-assessed')
    def test_mounts_never_export_credentials_or_source(self):
        self.f.cap_tools();self.f.file('/proc/self/mountinfo',
            '1 0 0:1 / / rw,relatime - overlay overlay rw,password='+CANARY+'\n'
            '2 1 0:2 / /data rw,noexec - ext4 /dev/'+CANARY+' rw,token='+CANARY+'\n')
        text,facts=self.run_probe('mounts');self.assertEqual(facts['data_fs'],'ext4');self.assertEqual(facts['data_rw'],'1');self.assertEqual(facts['data_exec'],'0')
        self.assertNotIn('password',text);self.assertNotIn('/dev/',text)
    def test_mount_limit_is_not_assessed(self):
        self.f.cap_tools();self.f.file('/proc/self/mountinfo','X'*140000)
        _,facts=self.run_probe('mounts');self.assertEqual(facts['mount_inventory'],'not-assessed')
    def test_generic_block_inventory_not_mmc0_only(self):
        for name in ('mmcblk1','nvme0n1','dm-0'):
            self.f.file('/sys/class/block/'+name+'/size','1024\n');self.f.file('/sys/class/block/'+name+'/ro','0\n')
        text,facts=self.run_probe('partitions');self.assertEqual(facts['block_count'],'3');self.assertIn('BLOCK nvme0n1',text)
        self.assertEqual(facts['modem_partition_layout_b31'],'not-assessed')
    def test_generic_inventory_limits_do_not_claim_complete_counts(self):
        for i in range(129):self.f.directory('/sys/class/block/test'+str(i))
        _,facts=self.run_probe('partitions');self.assertEqual(facts['block_count'],'not-assessed')
        for i in range(17):self.f.directory('/sys/class/remoteproc/remoteproc'+str(i))
        _,facts=self.run_probe('hardware-metadata');self.assertEqual(facts['hardware_remoteproc_count'],'not-assessed')
    def test_unknown_init_and_no_service_tools(self):
        self.f.file('/proc/1/comm','custom_init\n');self.f.directory('/etc/init.d')
        _,facts=self.run_probe('init-runtime');self.assertEqual(facts['init_comm'],'custom_init');self.assertEqual(facts['init_sysv'],'present')
        _,facts=self.run_probe('services');self.assertEqual(facts['running_dropbear'],'not-assessed')
    def test_log_counts_only_and_failure_not_zero(self):
        self.f.cap_tools();self.f.tool('dmesg','print('+repr('mmc timeout '+CANARY+'\nnormal '+CANARY)+')')
        text,facts=self.run_probe('kernel-health');self.assertEqual(facts['health_sample'],'known');self.assertEqual(facts['mmc_error_lines'],'1')
        self.assertNotIn('normal',text)
        self.f.tool('dmesg','import sys\nprint('+repr(CANARY)+')\nsys.exit(1)')
        _,facts=self.run_probe('kernel-health');self.assertEqual(facts,{'health_sample':'not-assessed'})
    def test_log_limit_and_missing_tools_are_not_absent(self):
        self.f.cap_tools();self.f.tool('dmesg','print("X"*140000)')
        _,facts=self.run_probe('kernel-health');self.assertEqual(facts,{'health_sample':'not-assessed'})
        _,facts=self.run_probe('kernel-features');self.assertEqual(facts['ttl_target'],'not-assessed');self.assertEqual(facts['ext4'],'not-assessed')
    def test_api_only_method_names_no_response_values(self):
        self.f.cap_tools();self.f.tool('ubus',
            'import sys\n'
            'if sys.argv[1:]==["-t","5","list"]:print("system")\n'
            'elif sys.argv[1:]==["-t","5","-v","list","system"]:print('+repr('"system" @0001\n\t"info": {"password":"'+CANARY+'"}')+')\n'
            'else:sys.exit(1)')
        text,facts=self.run_probe('api-surface');self.assertIn('API_METHOD info',text);self.assertNotIn('password',text);self.assertEqual(facts['api_methods_invoked'],'0')
    def test_hardware_properties_metadata_only(self):
        self.f.standard('tr','head');self.f.file('/sys/firmware/devicetree/base/compatible',b'qcom,sdxfoo\0zte,board\0')
        self.f.file('/sys/class/remoteproc/remoteproc3/state','running\n')
        text,facts=self.run_probe('hardware-metadata');self.assertEqual(facts['hardware_compatible'],'qcom,sdxfoo,zte,board,');self.assertEqual(facts['hardware_remoteproc_count'],'1')
        self.assertEqual(facts['hardware_character_devices_opened'],'0')
    def test_kernel_config_selective_and_error_proof(self):
        self.f.cap_tools();self.f.tool('gzip','print('+repr('CONFIG_TUN=y\n# CONFIG_NET_NS is not set\nCONFIG_PRIVATE="'+CANARY+'"')+')')
        self.f.file('/proc/config.gz',b'stub');_,facts=self.run_probe('kernel-config');self.assertEqual(facts['kernel_config_tun'],'y');self.assertEqual(facts['kernel_config_net_ns'],'n')
        self.f.tool('gzip','import sys\nprint("CONFIG_TUN=y")\nsys.exit(1)')
        _,facts=self.run_probe('kernel-config');self.assertEqual(facts['kernel_config_source'],'not-assessed');self.assertNotIn('kernel_config_tun',facts)
    def test_readonly_command_surface(self):
        s=json.loads(SPEC.read_text())
        for p in s['probes']:
            command=p['command'];self.assertNotRegex(command,r'(?m)^\s*(?:rm|mv|cp|mkdir|chmod|chown|mount|reboot|insmod|modprobe|dd|tee)\s',p['id'])
            self.assertNotRegex(command,r'(?m)^\s*ldd\s');self.assertNotIn('/proc/self/environ',command)
            if 'ubus' in command:self.assertNotRegex(command,r'ubus\s+(?:-t\s+\d+\s+)?call\s+(?!zwrt_web device_info)',p['id'])

    def test_old_hash_probes_do_not_follow_links_or_report_read_failure_absent(self):
        self.f.tool('stat','print("0")'); self.f.sha()
        self.f.file('/data/private-target',CANARY)
        (self.f.fs/'data/zte-agent').symlink_to(self.f.fs/'data/private-target')
        _,facts=self.run_probe('agent-layout');self.assertEqual(facts['agent_sha256'],'not-assessed')
        (self.f.fs/'data/zte-agent').unlink();self.f.file('/data/zte-agent','fixture')
        self.f.sha(fail=True)
        _,facts=self.run_probe('agent-layout');self.assertEqual(facts['agent_sha256'],'not-assessed')
        (self.f.fs/'data/zte-agent').unlink()
        _,facts=self.run_probe('agent-layout');self.assertEqual(facts['agent_sha256'],'missing')

    def test_read_denied_hash_is_not_absent(self):
        self.f.tool('stat','print("0")'); self.f.sha()
        target=self.f.file('/data/zte-agent',CANARY);target.chmod(0)
        if os.access(target,os.R_OK):self.skipTest('Host can override file read permissions')
        try:
            # run() snapshots fixture files, so run the permission-sensitive
            # production hash function separately without opening the secret.
            command=next(p['command'] for p in json.loads(SPEC.read_text())['probes'] if p['id']=='agent-layout')
            command=command[:command.index('for path in /data/zte-agent')]+ '\nhash_fact agent_sha256 '+str(target)+'\n'
            command=re.sub(r'(?m)^export PATH=.*? LC_ALL=C$', 'export PATH='+str(self.f.tools)+' LC_ALL=C', command)
            result=subprocess.run(['/bin/sh','-c',command],capture_output=True,timeout=5)
            self.assertEqual(result.returncode,0);self.assertIn(b'agent_sha256=not-assessed',result.stdout)
            self.assertNotIn(CANARY.encode(),result.stdout+result.stderr)
        finally:target.chmod(0o600)

    def test_failed_uci_and_missing_ttl_are_not_negative_capabilities(self):
        self.f.tool('uci','import sys\nsys.exit(1)')
        _,facts=self.run_probe('wifi-structure')
        self.assertEqual(set(facts.values()),{'not-assessed'})
        self.f.cap_tools();self.f.tool('iptables','print("iptables v1.8.8 (legacy)")')
        _,facts=self.run_probe('ttl-runtime');self.assertEqual(facts['iptables_b31'],'1');self.assertEqual(facts['ttl_target'],'not-assessed')
        self.f.file('/proc/net/ip_tables_targets','TTL\n')
        _,facts=self.run_probe('ttl-runtime');self.assertEqual(facts['ttl_target'],'1')
        self.f.tool('cat','import sys\nprint("TTL")\nsys.exit(1)')
        _,facts=self.run_probe('ttl-runtime');self.assertEqual(facts['ttl_target'],'not-assessed')

    def test_network_missing_or_malformed_sources_are_not_zero(self):
        self.f.cap_tools()
        _,facts=self.run_probe('network-structure')
        for key in ('interface_count','ipv4_route_count','ipv4_default_route_count','ipv6_route_count'):
            self.assertEqual(facts[key],'not-assessed')
        self.f.directory('/sys/class/net');self.f.file('/proc/net/route',CANARY);self.f.file('/proc/net/ipv6_route',CANARY)
        _,facts=self.run_probe('network-structure');self.assertEqual(facts['interface_count'],'0');self.assertEqual(facts['ipv4_route_count'],'not-assessed');self.assertEqual(facts['ipv6_route_count'],'not-assessed')
        self.f.file('/proc/net/route','Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n')
        self.f.file('/proc/net/ipv6_route','')
        _,facts=self.run_probe('network-structure');self.assertEqual(facts['ipv4_default_route_count'],'0');self.assertEqual(facts['ipv6_route_count'],'0')

    def test_old_esim_schema_prints_names_only_and_rejects_symlink_hash(self):
        self.f.cap_tools();self.f.tool('stat','print("1")');self.f.sha()
        self.f.tool('ubus','print('+repr('\t"get_sim_info": {"password":"'+CANARY+'"}')+')')
        self.f.file('/usr/bin/secret-target',CANARY)
        (self.f.fs/'usr/bin/zte_topsw_mdm').symlink_to(self.f.fs/'usr/bin/secret-target')
        text,facts=self.run_probe('esim-components')
        self.assertIn('METHOD get_sim_info',text);self.assertNotIn('password',text)
        self.assertEqual(facts['esim_mdm_sha256'],'not-assessed');self.assertEqual(facts['esim_method_get_sim_info'],'1')
        self.f.tool('ubus','print("X"*140000)')
        _,facts=self.run_probe('esim-components');self.assertEqual(facts['esim_method_inventory'],'not-assessed')

    def test_vpn_inventory_does_not_execute_lua_or_vendor_programs(self):
        for tool in ('lua','nft','iptables','ip6tables','ebtables','dnsmasq'):
            self.f.tool(tool,'print('+repr(CANARY)+')')
        _,facts=self.run_probe('vpn-runtime')
        self.assertEqual(facts['lua_uci'],'not-assessed');self.assertEqual(facts['lua_luci_jsonc'],'not-assessed')
        self.assertEqual(facts['lua_module_execution_performed'],'0')
        for name in ('lua','nft','iptables','ip6tables','ebtables','dnsmasq'):self.assertEqual(facts['vpn_tool_'+name],'1')

    def test_nested_missing_directories_are_proven_absent_under_readable_parent(self):
        self.f.tool('stat', 'import os,stat,sys\nv=os.stat(sys.argv[-1]);fmt=sys.argv[2]\nprint("0" if fmt=="%u" else oct(stat.S_IMODE(v.st_mode))[2:] if fmt=="%a" else "0:700" if fmt=="%u:%a" else "metadata")')
        self.f.directory('/data');self.f.directory('/etc');self.f.directory('/tmp').chmod(0o1777)
        self.f.directory('/var/run')
        _,facts=self.run_probe('permissions')
        self.assertEqual(facts['setup_parents_safe'],'1')
        self.assertEqual(facts['local_tmp_exists'],'0')
        self.assertEqual(facts['dashboard_runtime_safe'],'1')
        self.assertEqual(facts['tmp_safe'],'0')
        self.assertEqual(facts['tmp_private_stage_parent'],'1')
        _,facts=self.run_probe('pending-operations');self.assertEqual(facts['no_pending_operations'],'1')
        self.f.directory('/tmp/zte-imei-app.lock')
        _,facts=self.run_probe('pending-operations');self.assertEqual(facts['no_pending_operations'],'0')

    def test_symlink_ancestor_never_certifies_missing_pending_or_safe_install(self):
        self.f.tool('stat','print("0")')
        self.f.directory('/data');self.f.directory('/etc');self.f.directory('/tmp')
        target=self.f.directory('/foreign')
        (self.f.fs/'data/local').symlink_to(target)
        _,facts=self.run_probe('permissions');self.assertNotEqual(facts['setup_parents_safe'],'1')
        _,facts=self.run_probe('pending-operations');self.assertEqual(facts['no_pending_operations'],'not-assessed')

    def test_unreadable_ancestor_remains_unknown_and_storage_not_guessed(self):
        self.f.tool('stat','print("0")')
        parent=self.f.directory('/data');parent.chmod(0)
        try:
            if os.access(parent,os.R_OK):self.skipTest('Host bypasses read permissions')
            _,facts=self.run_probe('pending-operations');self.assertEqual(facts['no_pending_operations'],'not-assessed')
        finally:parent.chmod(0o700)
        _,facts=self.run_probe('storage')
        self.assertEqual(facts['data_free_kib'],'not-assessed');self.assertEqual(facts['data_free_16384'],'not-assessed')

    def test_generic_access_cards_do_not_grant_the_old_agent_updater(self):
        s=json.loads(SPEC.read_text());features={f['id']:f for f in s['features']}
        self.assertTrue(features['agent']['profiles'])
        for name in ('generic-access','preparation','ssh'):
            f=features[name];self.assertEqual(f['profiles'],[])
            facts={x['fact'] for x in f['requirements']}
            self.assertFalse({'tool_ubus','object_zwrt_web','firmware_sha256','router_sha256'}&facts)
            self.assertTrue({'root','architecture','operating_system','init_comm','startup_procd_rc_local'}<=facts)
        self.assertEqual(len(s['observations']),45)

    def test_procd_startup_is_observed_without_running_its_body(self):
        self.f.cap_tools();self.f.standard('sh')
        self.f.file('/etc/init.d/done','#!/bin/sh\nsh /etc/rc.local\nprintf '+CANARY+'\n')
        # The fixture path rewrite must preserve this source-level literal;
        # it is data inspected in the file, not a path to open from the probe.
        spec=json.loads(SPEC.read_text());probe=next(p for p in spec['probes'] if p['id']=='startup-structure')
        self.assertIn('rc\\.local',probe['command'])
        _,facts=self.run_probe('startup-structure');self.assertEqual(facts['startup_procd_rc_local'],'1')
        self.f.file('/etc/init.d/done','#!/bin/sh\nprintf '+CANARY+'\n')
        _,facts=self.run_probe('startup-structure');self.assertEqual(facts['startup_procd_rc_local'],'0')
        self.f.tool('cat','import sys\nprint("sh /etc/rc.local")\nsys.exit(1)')
        _,facts=self.run_probe('startup-structure');self.assertEqual(facts['startup_procd_rc_local'],'not-assessed')

if __name__=='__main__': unittest.main()
