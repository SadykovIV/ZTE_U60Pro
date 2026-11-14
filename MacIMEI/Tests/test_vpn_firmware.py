"""Actual installer integration with a pinned controller boundary; no modem.
The controller policy matrix itself is exercised by Rust compatibility tests.
"""
from pathlib import Path
import hashlib, os, re, shutil, subprocess, tempfile, unittest, uuid
ROOT=Path(__file__).resolve().parents[2]
VPN=ROOT/'MacIMEI/Resources/VPN'
FILES=['vpnctl','mihomo','manager.sh','firewall.sh','configure.lua','nft-guard.nft','dnsmasq.conf','service.sh','ikev2.sh','ikev2-updown.sh','nft-ikev2-guard.nft']

class FirmwareTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='vpn-install-policy-');self.base=Path(self.temp.name)
        self.root=self.base/'data/zte-vpn';self.root.parent.mkdir()
        self.stage=Path('/tmp')/('zte-vpn-install-'+str(uuid.uuid4()));self.stage.mkdir(mode=0o700)
        self.init=self.base/'etc/init.d/zte_vpn';self.init.parent.mkdir(parents=True)
        self.bin=self.base/'bin';self.bin.mkdir();self.cid=self.base/'cid';self.cid.write_text('a'*32+'\n')
        for name in FILES:(self.stage/name).write_text('#!/bin/sh\nexit 0\n')
        self.helper=b'''#!/bin/sh
printf '%s\n' "$1" >> "$FIXTURE/controller-calls"
case "$1" in
 install-preflight)
  if [ -n "${COMPATIBILITY_CODE:-}" ]; then printf '{"ok":false,"code":"%s"}\n' "$COMPATIBILITY_CODE"; exit 1; fi;;
 integrity) :;;
 *) exit 90;;
esac
printf '{"ok":true}\n'
'''
        (self.stage/'vpnctl').write_bytes(self.helper)
        self.command('id','echo 0');self.command('uname','echo aarch64')
        self.command('stat','''case "$2" in %u:%a) echo 0:700;; %u) echo 0;; *) exit 89;; esac''')
        self.command('sha256sum','''case "$1" in */mihomo) printf '%s  %s\n' 1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3 "$1";; *) exec /usr/bin/shasum -a 256 "$@";; esac''')
        self.command('df','echo "filesystem 1048576 0 ${TEST_FREE:-200000} 0% /data"');self.command('sync',':')
        for tool in ['nft','iptables','ip6tables','ebtables','dnsmasq','ip','flock']:self.command(tool,':')
        self.command('lua','''case "$1:$2" in -e:*) [ "${FAIL_LUA_MODULES:-0}" = 0 ];; *:preflight) [ "${FAIL_LAYOUT:-0}" = 0 ];; *) exit 90;; esac''')
        self.command('ubus','''[ "${FAIL_RPC:-0}" = 0 ] || exit 1; printf '  "reload":{}\n';''')
        source=(VPN/'install.sh').read_text().replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+str(self.bin)+':/usr/bin:/bin')
        source=source.replace('/data/zte-vpn',str(self.root)).replace('/etc/init.d/zte_vpn',str(self.init)).replace('/sys/block/mmcblk0/device/cid',str(self.cid)).replace('/dev/net/tun','/dev/null')
        source=re.sub(r'(?m)^controller_sha=[a-f0-9]{64}$','controller_sha='+hashlib.sha256(self.helper).hexdigest(),source)
        self.script=self.base/'install.sh';self.script.write_text(source)
    def tearDown(self):shutil.rmtree(self.stage);self.temp.cleanup()
    def command(self,name,body):
        p=self.bin/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o700)
    def install(self,**env):
        return subprocess.run(['/bin/sh',str(self.script),str(self.stage)],env={**os.environ,'FIXTURE':str(self.base),**env},capture_output=True,text=True,timeout=15)
    def refused(self,result,phase):
        self.assertNotEqual(result.returncode,0);self.assertIn('VPN_INSTALL_ERROR '+phase,result.stderr)
        self.assertFalse(self.root.exists());self.assertFalse(self.init.exists())
    def test_install_requires_preflight_then_postwrite_integrity(self):
        r=self.install();self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.base/'controller-calls').read_text().splitlines(),['install-preflight','integrity'])
        self.assertEqual((self.root/'cid').read_bytes(),self.cid.read_bytes())
        self.assertEqual(self.init.read_bytes(),(self.stage/'service.sh').read_bytes())
        for name in FILES:self.assertEqual((self.root/name).read_bytes(),(self.stage/name).read_bytes())
    def test_unknown_firmware_ipa_and_changed_network_refuse_before_install(self):
        for cause,phase in [('VPN_UNSUPPORTED_FIRMWARE','UNSUPPORTED_FIRMWARE'),('VPN_IPA_UNSUPPORTED','IPA_UNSUPPORTED'),('VPN_NETWORK_INIT_CHANGED','NETWORK_CHANGED'),('VPN_UNSAFE_FILE','COMPATIBILITY')]:
            with self.subTest(cause=cause):self.refused(self.install(COMPATIBILITY_CODE=cause),phase)
    def test_unpinned_controller_never_executes(self):
        (self.stage/'vpnctl').write_bytes(self.helper+b'# changed\n')
        self.refused(self.install(),'PAYLOAD');self.assertFalse((self.base/'controller-calls').exists())
    def test_missing_payload_does_not_create_partial_install(self):
        (self.stage/'manager.sh').unlink();self.refused(self.install(),'PAYLOAD')
    def test_layout_and_rpc_contract_fail_before_files_are_written(self):
        for variable,phase in [('FAIL_LAYOUT','WIFI_LAYOUT'),('FAIL_RPC','RPC_UNSUPPORTED')]:
            self.refused(self.install(**{variable:'1'}),phase)
    def test_rpc_wrong_signature_is_not_accepted_as_reload(self):
        self.command('ubus','''printf '  "reload":{"mode":"String"}\n';''');self.refused(self.install(),'RPC_UNSUPPORTED')
    def test_rpc_failure_with_partial_valid_output_is_rejected(self):
        self.command('ubus','''printf '  "reload":{}\n'; exit 1''');self.refused(self.install(),'RPC_UNSUPPORTED')
    def test_existing_install_is_preserved(self):
        self.root.mkdir();(self.root/'owner').write_text('existing')
        r=self.install();self.assertIn('VPN_INSTALL_ERROR ALREADY_PRESENT',r.stderr)
        self.assertEqual((self.root/'owner').read_text(),'existing');self.assertFalse(self.init.exists())
    def test_lua_and_space_failures_report_exact_phase(self):
        self.refused(self.install(FAIL_LUA_MODULES='1'),'LUA_MODULES')
        self.refused(self.install(TEST_FREE='1'),'NO_SPACE')

if __name__=='__main__':unittest.main()
