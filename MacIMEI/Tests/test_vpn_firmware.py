"""Run the VPN installer and runtime gate against the measured B04/B28/B31 identities."""
from pathlib import Path
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
VPN = ROOT / 'MacIMEI/Resources/VPN'
B31 = '604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263'
# SashaRIP adaptation capture, 2026-10-07: FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28.
B28 = '5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478'

B04 = 'c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81'
B04_MDM = '93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64'
ROUTER = '55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f'
NETWORK = '093e5461be5ea5d23d24522374a27b9a134c4932df3c89b3b756274f123ac508'

class FirmwareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vpn-firmware-')
        self.base = Path(self.temp.name)
        self.root = self.base / 'data/zte-vpn'
        self.root.parent.mkdir()
        self.stage = Path('/tmp') / ('zte-vpn-install-' + str(uuid.uuid4()))
        self.stage.mkdir(mode=0o700)
        self.init = self.base / 'etc/init.d/zte_vpn'
        self.init.parent.mkdir(parents=True)
        self.firmware = self.base / 'firmware/image/modem.b16'
        self.firmware.parent.mkdir(parents=True)
        self.mdm = self.base / 'usr/bin/zte_topsw_mdm'
        self.mdm.parent.mkdir(parents=True)
        self.mdm.write_text('fixture')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.cid = self.base / 'cid'
        self.cid.write_text('a' * 32 + '\n')
        self.command('id', 'echo 0')
        self.command('uname', 'echo aarch64')
        self.command('stat', '''case "$2" in %u:%a) echo 0:700;; %u) echo 0;; *) exit 89;; esac''')
        self.command('sha256sum', '''case "$1" in
 */firmware/image/modem.b16) printf '%s  %s\\n' "$VPN_TEST_FIRMWARE" "$1";;
 */usr/bin/zte_topsw_mdm) printf '%s  %s\\n' "$VPN_TEST_MDM" "$1";;
 */usr/bin/diag-router) printf '%s  %s\\n' "$VPN_TEST_ROUTER" "$1";;
 */etc/init.d/network) printf '%s  %s\\n' "$VPN_TEST_NETWORK" "$1";;
 */mihomo) printf '%s  %s\\n' 1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3 "$1";;
 *) exec /usr/bin/shasum -a 256 "$@";; esac''')
        self.command('df', 'echo "filesystem 1048576 0 ${VPN_TEST_FREE:-200000} 0% /data"')
        self.command('sync', ':')
        for tool in ['lua', 'nft', 'iptables', 'ip6tables', 'ebtables', 'dnsmasq', 'ip', 'ubus', 'flock']:
            self.command(tool, ':')
        for name in ['vpnctl', 'mihomo', 'manager.sh', 'firewall.sh', 'configure.lua', 'nft-guard.nft', 'dnsmasq.conf', 'service.sh']:
            (self.stage / name).write_text('#!/bin/sh\nexit 0\n')
        self.script = self.base / 'install.sh'
        self.script.write_text(self.remap((VPN / 'install.sh').read_text()).replace('/dev/net/tun', '/dev/null'))

    def tearDown(self):
        shutil.rmtree(self.stage)
        self.temp.cleanup()

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o700)

    def remap(self, source):
        return source.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'PATH=' + str(self.bin) + ':/usr/bin:/bin').replace('/data/zte-vpn', str(self.root)).replace('/etc/init.d/zte_vpn', str(self.init)).replace('/sys/block/mmcblk0/device/cid', str(self.cid)).replace('/firmware/image/modem.b16', str(self.firmware)).replace('/usr/bin/zte_topsw_mdm', str(self.mdm)).replace('/usr/bin/diag-router', str(self.mdm.with_name('diag-router'))).replace('/etc/init.d/network', str(self.init.with_name('network')))

    def install(self, firmware, **env):
        if firmware: self.firmware.write_text('fixture')
        else: self.firmware.unlink(missing_ok=True)
        return subprocess.run(['/bin/sh', str(self.script), str(self.stage)], env={**os.environ, 'VPN_TEST_FIRMWARE': firmware, 'VPN_TEST_MDM': B04_MDM, 'VPN_TEST_ROUTER': ROUTER, 'VPN_TEST_NETWORK': NETWORK, **env}, capture_output=True, text=True, timeout=10)

    def test_clean_install_accepts_b04_b28_and_b31(self):
        for firmware in [B28, B31, "", B04]:
            with self.subTest(firmware=firmware[:8]):
                result = self.install(firmware)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('VPN_COMPONENTS_INSTALLED', result.stdout)
                self.assertEqual((self.root / 'owner').read_text(), 'zte-vpn-v1')
                self.assertEqual((self.root / 'cid').read_bytes(), self.cid.read_bytes())
                self.assertEqual(self.init.read_bytes(), (self.stage / 'service.sh').read_bytes())
                self.assertEqual((self.root / 'manager.sh').read_bytes(), (self.stage / 'manager.sh').read_bytes())
                shutil.rmtree(self.root)
                self.init.unlink()

    def test_b04_requires_captured_mdm_router_and_stock_network(self):
        for firmware in ['', B04]:
          for key in ['VPN_TEST_MDM', 'VPN_TEST_ROUTER', 'VPN_TEST_NETWORK']:
            with self.subTest(dependency=key, firmware=firmware[:8]):
                result = self.install(firmware, **{key: '0' * 64})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('VPN_INSTALL_ERROR UNSUPPORTED_FIRMWARE', result.stderr)
                self.assertFalse(self.root.exists())
                self.assertFalse(self.init.exists())

    def test_b04_startup_profile_needs_no_vendor_rpc(self):
        # Early network startup must remain independent of zwrt_web readiness.
        for name in ['install.sh', 'manager.sh']:
            source = (VPN / name).read_text().split('b04_profile() {', 1)[1].split('\n}', 1)[0]
            self.assertNotIn('ubus', source)
            self.assertIn(B04_MDM, source)
            self.assertIn(ROUTER, source)

    def test_unknown_firmware_refused_before_files_are_written(self):
        result = self.install('f' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VPN_INSTALL_ERROR UNSUPPORTED_FIRMWARE', result.stderr)
        self.assertFalse(self.root.exists())
        self.assertFalse(self.init.exists())

    def test_missing_payload_does_not_create_partial_install(self):
        (self.stage / 'manager.sh').unlink()
        result = self.install(B28)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VPN_INSTALL_ERROR PAYLOAD', result.stderr)
        self.assertFalse(self.root.exists())

    def test_existing_install_is_preserved(self):
        self.root.mkdir()
        original = self.root / 'owner'
        original.write_text('existing installation')
        result = self.install(B31)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VPN_INSTALL_ERROR ALREADY_PRESENT', result.stderr)
        self.assertEqual(original.read_text(), 'existing installation')
        self.assertFalse(self.init.exists())

    def test_lua_and_space_failures_report_the_exact_phase(self):
        self.command('lua', 'exit 1')
        result = self.install(B28)
        self.assertIn('VPN_INSTALL_ERROR LUA_MODULES', result.stderr)
        self.assertFalse(self.root.exists())
        self.command('lua', ':')
        result = self.install(B28, VPN_TEST_FREE='1')
        self.assertIn('VPN_INSTALL_ERROR NO_SPACE', result.stderr)
        self.assertFalse(self.root.exists())

    def test_runtime_prepare_accepts_both_identities_and_rejects_unknown(self):
        self.root.mkdir()
        (self.root / 'cid').write_bytes(self.cid.read_bytes())
        (self.root / 'configured').touch()
        (self.root / 'firewall.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.root / 'firewall.sh').chmod(0o700)
        self.command('uci', '''case "$*" in *mesh_onoff) echo 0;; *close_ipa_acce) echo 1;; *) exit 90;; esac''')
        self.command('ip', 'echo "inet 192.168.50.1/24"')
        script = self.base / 'manager.sh'
        # This suite isolates the firmware gate; test_vpn_ipa exercises the real
        # measured daemon preparation for all four supported image variants.
        script.write_text(self.remap((VPN / 'manager.sh').read_text()).replace('ipa_prepare\n', ': # IPA preparation covered by test_vpn_ipa\n'))
        for firmware, status in [(B28, 0), (B31, 0), ('', 0), (B04, 0), ('f' * 64, 1)]:
            if firmware: self.firmware.write_text('fixture')
            else: self.firmware.unlink(missing_ok=True)
            with self.subTest(firmware=firmware[:8]):
                result = subprocess.run(['/bin/sh', str(script), 'prepare'], env={**os.environ, 'VPN_TEST_FIRMWARE': firmware, 'VPN_TEST_MDM': B04_MDM, 'VPN_TEST_ROUTER': ROUTER}, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, status, result.stderr)
                if status: self.assertIn('VPN_UNSUPPORTED_FIRMWARE', result.stderr)
        self.assertFalse((self.root / 'backup').exists())

    def test_rust_shell_and_windows_firmware_identities_agree(self):
        source = (ROOT / 'ModemAgent/vpnctl/src/main.rs').read_text()
        hashes = set(re.findall(r'"([0-9a-f]{64})"', source.split('const FW_SHAS:', 1)[1].split('];', 1)[0]))
        self.assertEqual(hashes, {B28, B31})
        for name in ['install.sh', 'manager.sh']:
            self.assertEqual((VPN / name).read_bytes(), (ROOT / 'Windows_x64/Resources/VPN' / name).read_bytes())
            for firmware in hashes: self.assertIn(firmware, (VPN / name).read_text())


if __name__ == '__main__':
    unittest.main()
