"""Exercise production shell routing, filters and callbacks without a modem."""
from pathlib import Path
import ipaddress
import os
import shlex
import subprocess
import tempfile
import unittest

RES = Path(__file__).resolve().parents[1] / 'Resources/VPN'
SOURCE = (RES/'ikev2.sh').read_text()


def function(start, end):
    return SOURCE[SOURCE.index(start+'() {'):SOURCE.index(end+'() {')]


class IkeRoutingTests(unittest.TestCase):
    def test_cleanup_selects_only_owned_policy_indexes(self):
        policies='''src 10.3.2.1/32 dst 10.0.0.0/8 \\ dir out priority 10 index 113 \\ if_id 0x4a92 reqid 19090
src 10.3.2.1/32 dst 10.0.0.0/8 \\ dir in priority 10 index 114 \\ if_id 0x99 reqid 19090
src 10.3.2.1/32 dst 10.0.0.0/8 \\ dir fwd priority 10 index 115 \\ if_id 19090 reqid 19090
src 10.3.2.1/32 dst 10.0.0.0/8 \\ dir out priority 10 index 116 reqid 19090
src 10.3.2.1/32 dst 10.0.0.0/8 \\ dir out priority 10 index 117 if_id 19090 reqid 77
src 10.3.2.1/32 dst 10.0.0.0/8 \\ dir out priority 10 index 118 if_id 19090 reqid 19090 mark 0x1/0xffffffff
'''
        out=subprocess.run(['/bin/sh','-ec',function('owned_policies','cleanup')+'\nowned_policies'],input=policies,text=True,capture_output=True)
        self.assertEqual(out.returncode,0,out.stderr)
        self.assertEqual(out.stdout,'113 out\n115 fwd\n')

    def test_state_cleanup_filters_ifid_reqid_mark_and_deletes_exact_spi(self):
        states='''src 192.0.2.1 dst 192.0.2.2 \\ proto esp spi 0x00000101 reqid 19090 mode tunnel \\ if_id 0x4a92
src 192.0.2.1 dst 192.0.2.3 \\ proto esp spi 0x00000102 reqid 19090 mode tunnel \\ if_id 0x77
src 192.0.2.1 dst 192.0.2.4 \\ proto esp spi 0x00000103 reqid 19090 mode tunnel \\ mark 0x1/0xffffffff if_id 0x4a92
src 192.0.2.1 dst 192.0.2.5 \\ proto esp spi 0x00000104 reqid 123 mode tunnel \\ if_id 0x4a92
'''
        with tempfile.TemporaryDirectory(prefix='ike-owned-sa-') as temp:
            root=Path(temp);(root/'network-owned').touch();(root/'states').write_text(states)
            shell='''set -eu
IKE="$1"
charon_owned() { return 1; }
xfrm_owned() { return 1; }
fail() { exit 91; }
ip() {
 case "$*" in
  '-s -o xfrm policy') :;;
  '-o xfrm state list nokeys reqid 19090') cat "$IKE/states";;
  *) printf '%s\\n' "$*";;
 esac
}
'''+function('owned_policies','cleanup')+function('cleanup','run')+'\ncleanup\n'
            result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            deletes=[line for line in result.stdout.splitlines() if line.startswith('xfrm state')]
            self.assertEqual(deletes,['xfrm state delete dst 192.0.2.2 proto esp spi 0x00000101 mark 0 mask 0xffffffff'])
            self.assertNotIn('deleteall',result.stdout)
            self.assertNotIn('link del',result.stdout, 'A missing/foreign XFRM link must not be deleted')

    def test_native_oneline_separator_may_touch_numeric_fields(self):
        state='src 192.0.2.1 dst 192.0.2.2\\\tproto esp spi 0x00000101 reqid 19090 mode tunnel\\\tif_id 0x4a92\\\n'
        result=subprocess.run(['/bin/sh','-ec',function('owned_states','cleanup')+'\nowned_states'],input=state,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'192.0.2.2 esp 0x00000101\n')
        policy='src 198.18.0.1 dst 10.0.1.0/24\\\tdir out index 113\\\tif_id 0x4a92\\\ttmpl src 192.0.2.1 dst 192.0.2.2 proto esp reqid 19090\\\n'
        result=subprocess.run(['/bin/sh','-ec',function('owned_policies','owned_states')+'\nowned_policies'],input=policy,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'113 out\n')

    def test_actual_native_synthetic_nokeys_records(self):
        fixtures=Path(__file__).resolve().parent/'fixtures/ikev2'
        states=(fixtures/'native-state-nokeys.txt').read_text()
        result=subprocess.run(['/bin/sh','-ec',function('owned_states','cleanup')+'\nowned_states'],input=states,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'192.0.2.2 esp 0x00000101\n')
        # Plain native `ip -o xfrm policy` omits indexes. Cleanup must request
        # statistics (-s) instead of guessing an index or deleting by broad filter.
        policies=(fixtures/'native-policy-nokeys.txt').read_text()
        result=subprocess.run(['/bin/sh','-ec',function('owned_policies','owned_states')+'\nowned_policies'],input=policies,text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0, 'An owned policy without an index must fail cleanup explicitly')
        self.assertEqual(result.stdout,'')
        policies=(fixtures/'native-policy-statistics.txt').read_text()
        result=subprocess.run(['/bin/sh','-ec',function('owned_policies','owned_states')+'\nowned_policies'],input=policies,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'265 out\n')

    def test_missing_owned_policy_index_fails_before_any_state_deletion(self):
        with tempfile.TemporaryDirectory(prefix='ike-bad-policy-') as temp:
            root=Path(temp);(root/'network-owned').touch()
            shell='''set -eu
IKE="$1"
charon_owned() { return 1; }
fail() { printf '%s\\n' "$1" >&2; exit 91; }
ip() {
 case "$*" in
  '-s -o xfrm policy') printf 'src 192.0.2.1 dst 192.0.2.2 dir out reqid 19090 if_id 19090\\n';;
  *) printf 'unexpected deletion/query: %s\\n' "$*"; exit 99;;
 esac
}
'''+function('owned_policies','cleanup')+function('cleanup','run')+'\ncleanup\n'
            result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True)
            self.assertEqual(result.returncode,91,result.stderr)
            self.assertIn('VPN_IKEV2_NOT_READY',result.stderr)
            self.assertEqual(result.stdout,'')
            self.assertTrue((root/'network-owned').exists())

    def route(self, main, all_routes=''):
        env = dict(os.environ, MAIN=main, ALL=all_routes)
        shell = 'ip() { if [ "$5" = main ]; then printf "%s\\n" "$MAIN"; else printf "%s\\n" "$ALL"; fi; }\n'
        return subprocess.run(['/bin/sh', '-ec', shell+function('lte_route','routes')+'\nlte_route'], env=env, text=True, capture_output=True)

    def test_copies_only_validated_lte_fields(self):
        out = self.route('default via 10.7.162.133 dev rmnet_data0 proto static src 10.7.162.132 metric 256 mtu 1500')
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout, 'default via 10.7.162.133 dev rmnet_data0 onlink src 10.7.162.132\n')

    def test_non_lte_default_never_becomes_guest_uplink(self):
        self.assertNotEqual(self.route('default via 192.168.1.1 dev wlan0').returncode, 0)
        out = self.route('default dev wlan0', 'default dev rmnet_data2 table 3')
        self.assertEqual(out.stdout, 'default dev rmnet_data2\n')
        self.assertNotEqual(self.route('', 'default dev rmnet_data0 table 19091').returncode,0)

    def test_ambiguous_or_invalid_lte_routes_are_rejected(self):
        for route in ['default dev rmnet_data0\ndefault dev rmnet_data1',
                      'default via 999.0.0.1 dev rmnet_data0',
                      'default dev rmnet_data0 src 1.2.3.4;touch']:
            self.assertNotEqual(self.route(route).returncode, 0, route)

    def test_private_routes_remain_when_ike_or_lte_is_down(self):
        shell = '''
ip() { case "$*" in '-d link show dev zvpn-ipsec') printf 'xfrm if_id 0x4a92\\n';; '-4 rule show') :;; *) printf '%s\\n' "$*";; esac; }
lte_route() { return 1; }
'''+function('xfrm_owned','charon_owned')+function('routes','prepare')+'\nroutes\n'
        out = subprocess.run(['/bin/sh','-ec',shell],text=True,capture_output=True)
        self.assertEqual(out.returncode,0,out.stderr)
        for subnet in ['10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']:
            self.assertIn(f'-4 route replace {subnet} dev zvpn-ipsec table 19090',out.stdout)
            self.assertIn(f'-4 route replace unreachable {subnet} metric 32767 table 19091',out.stdout)
            self.assertLess(out.stdout.index(f'route replace unreachable {subnet}'),out.stdout.index('rule add priority 19001'))
        self.assertIn('route replace unreachable default metric 32767 table 19091',out.stdout)
        self.assertIn('rule add priority 19000 iif br-vpn lookup 19090',out.stdout)
        self.assertIn('rule add priority 19001 iif br-vpn lookup 19091',out.stdout)
        self.assertNotIn('table main',out.stdout)
        self.assertNotIn('flush',out.stdout)

    def test_cleanup_removes_only_owned_private_fallback_routes(self):
        with tempfile.TemporaryDirectory(prefix='ike-cleanup-') as temp:
            root=Path(temp);(root/'network-owned').touch()
            shell='''set -eu
IKE="$1"
charon_owned() { return 1; }
xfrm_owned() { return 1; }
fail() { exit 1; }
ip() { case "$*" in '-s -o xfrm policy') :;; *) printf '%s\\n' "$*";; esac; }
'''+function('owned_policies','cleanup')+function('cleanup','run')+'\ncleanup\n'
            out=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True)
            self.assertEqual(out.returncode,0,out.stderr)
            for subnet in ['10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']:
                self.assertIn(f'-4 route del unreachable {subnet} metric 32767 table 19091',out.stdout)
            self.assertNotIn('flush',out.stdout)
            self.assertNotIn('table main',out.stdout)
            self.assertFalse((root/'network-owned').exists())

    def firewall_rules(self):
        shell = '''
ROOT=/fixture
jsonfilter() { printf '10.0.2.1'; }
fail() { exit 1; }
ipt() { case " $* " in *' -C '*) return 1;; esac; printf '%s\\n' "$*"; }
routes() { :; }
'''+function('add4','xfrm_owned')+function('firewall','cleanup')+'\nfirewall\n'
        out=subprocess.run(['/bin/sh','-ec',shell],text=True,capture_output=True)
        self.assertEqual(out.returncode,0,out.stderr)
        return out.stdout

    def test_filters_keep_public_lte_and_drop_private_leaks(self):
        output=self.firewall_rules()
        rules=[shlex.split(line)[4:] for line in output.splitlines() if line.startswith('-t filter -A ZVPN_FW ')]
        def verdict(destination, incoming, outgoing, established=False, source='192.168.50.20'):
            for rule in rules:
                if '-i' in rule and rule[rule.index('-i')+1]!=incoming: continue
                if '-s' in rule:
                    member=ipaddress.ip_address(source) in ipaddress.ip_network(rule[rule.index('-s')+1])
                    inverted=rule[rule.index('-s')-1]=='!'
                    if member==inverted:continue
                if '-o' in rule:
                    match=rule[rule.index('-o')+1]
                    if not (outgoing.startswith(match[:-1]) if match.endswith('+') else outgoing==match):continue
                if '-d' in rule and ipaddress.ip_address(destination) not in ipaddress.ip_network(rule[rule.index('-d')+1]):continue
                if '--ctstate' in rule and not established:continue
                return rule[rule.index('-j')+1]
            return 'NO_MATCH'
        for destination in ['10.0.2.1','172.16.8.8','192.168.1.12']:
            self.assertEqual(verdict(destination,'br-vpn','rmnet_data0'),'DROP')
            self.assertEqual(verdict(destination,'br-vpn','zvpn-ipsec'),'ACCEPT')
        self.assertEqual(verdict('1.1.1.1','br-vpn','rmnet_data0'),'ACCEPT')
        self.assertEqual(verdict('1.1.1.1','br-vpn','wlan0'),'DROP')
        self.assertEqual(verdict('1.1.1.1','br-vpn','rmnet_data0',source='192.168.0.20'),'DROP')
        for destination in ['0.1.1.1','100.64.1.1','127.0.0.1','169.254.1.1','198.18.0.1','224.0.0.1','255.255.255.255']:
            self.assertEqual(verdict(destination,'br-vpn','rmnet_data0'),'DROP')
        self.assertIn('-j DNAT --to-destination 10.0.2.1',output)
        self.assertNotIn('REDIRECT',output)
        self.assertNotIn(' -F ',output)


class UpdownTests(unittest.TestCase):
    def test_respawn_adopts_orphaned_daemon_without_reloading_or_push(self):
        body=SOURCE[SOURCE.index('run() {'):SOURCE.index('\ncase "${1:-}"')]
        with tempfile.TemporaryDirectory(prefix='ike-orphan-') as temp:
            root=Path(temp);(root/'charon.pid').write_text('4242\n');(root/'attempt-issued').touch()
            shell='''set -eu
IKE="$1";CHARON=/do-not-start-charon;SWANCTL=/do-not-start-swanctl;URI=fixture
native_check() { :; }
charon_owned() { [ ! -e "$IKE/finished" ] || return 1; ike_pid=4242; }
sleep() { touch "$IKE/finished"; }
kill() { printf '%s\\n' "$*" >> "$IKE/signals"; }
'''+body+'\nrun\n'
            result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True,timeout=2)
            self.assertEqual((root/'charon.pid').read_text(),'4242\n')
            self.assertTrue((root/'attempt-issued').exists())
            self.assertFalse((root/'signals').exists(), 'Do not signal a stale or reused daemon PID')
            self.assertNotIn('not found',result.stderr)
            self.assertNotIn('do-not-start',result.stderr)

    def test_adopted_daemon_is_stopped_only_while_still_owned(self):
        body=SOURCE[SOURCE.index('run() {'):SOURCE.index('\ncase "${1:-}"')]
        with tempfile.TemporaryDirectory(prefix='ike-adopt-stop-') as temp:
            root=Path(temp);(root/'charon.pid').write_text('4242\n')
            shell='''set -eu
IKE="$1";CHARON=/do-not-start-charon;SWANCTL=/do-not-start-swanctl;URI=fixture
native_check() { :; }
charon_owned() { ike_pid=4242; }
sleep() { exit 0; }
kill() { printf '%s\\n' "$*" >> "$IKE/signals"; }
'''+body+'\nrun\n'
            result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True,timeout=2)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((root/'signals').read_text(),'-TERM 4242\n')

    def test_prepare_retains_attempt_in_same_boot_and_resets_only_after_reboot(self):
        body=function('prepare','firewall').replace('/proc/sys/net/ipv4/conf/zvpn-ipsec/rp_filter', '"$IKE/rp_filter"').replace('/proc/sys/kernel/random/boot_id', '"$IKE/boot_id"')
        with tempfile.TemporaryDirectory(prefix='ike-boot-') as temp:
            root=Path(temp)
            (root/'network-owned').touch()
            (root/'attempt-issued').touch()
            (root/'attempt-boot').write_text('boot-one\n')
            (root/'boot_id').write_text('boot-one\n')
            helper=root/'vpnctl';helper.write_text('#!/bin/sh\nexit 0\n');helper.chmod(0o700)
            shell='''set -eu
ROOT="$1";IKE="$1"
native_check() { :; }
ip() { :; }
xfrm_owned() { :; }
charon_owned() { return 1; }
routes() { :; }
'''+body+'\nprepare\n'
            for boot, retained in [('boot-one',True),('boot-two',False)]:
                (root/'boot_id').write_text(boot+'\n')
                result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((root/'attempt-issued').exists(),retained)
                self.assertEqual((root/'attempt-boot').read_text(),boot+'\n')

    def test_cleanup_clears_attempt_even_if_xfrm_marker_is_already_absent(self):
        with tempfile.TemporaryDirectory(prefix='ike-stop-') as temp:
            root=Path(temp);(root/'attempt-issued').touch();(root/'auth-state').write_text('waiting\n')
            shell='set -eu\nIKE="$1"\ncharon_owned() { return 1; }\nip() { exit 99; }\n'+function('cleanup','run')+'\ncleanup\n'
            result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertFalse((root/'attempt-issued').exists())
            self.assertFalse((root/'auth-state').exists())

    def test_multiple_selectors_and_assigned_virtual_ip(self):
        with tempfile.TemporaryDirectory(prefix='ike-callback-') as temp:
            root=Path(temp); (root/'ikev2').mkdir(); bindir=root/'bin';bindir.mkdir()
            for name,text in {
                'iptables':'#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n',
                'flock':'#!/bin/sh\nexit 0\n',
                'sha256sum':'#!/bin/sh\nexec shasum -a 256 "$@"\n',
            }.items():
                p=bindir/name;p.write_text(text);p.chmod(0o700)
            source=(RES/'ikev2-updown.sh').read_text().replace('ROOT=/data/zte-vpn','ROOT='+shlex.quote(temp)).replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+shlex.quote(str(bindir))+':/usr/bin:/bin')
            env=dict(os.environ,CALL_LOG=str(root/'calls'),PLUTO_CONNECTION='zte-private',PLUTO_REQID='19090',PLUTO_UNIQUEID='7',PLUTO_MY_SOURCEIP4_1='10.30.0.12',PLUTO_MY_CLIENT='10.30.0.12/32')
            def call(verb,peer,vip='10.30.0.12'):
                return subprocess.run(['/bin/sh','-ec',source],env=dict(env,PLUTO_VERB=verb,PLUTO_PEER_CLIENT=peer,PLUTO_MY_SOURCEIP4_1=vip),text=True,capture_output=True)
            for subnet in ['10.0.0.0/8','172.16.0.0/12']:
                result=call('up-host',subnet);self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((root/'ikev2/vip').read_text(),'10.30.0.12\n')
            self.assertEqual(call('down-host','10.0.0.0/8').returncode,0)
            self.assertTrue((root/'ikev2/connected').exists())
            self.assertEqual(call('down-host','172.16.0.0/12').returncode,0)
            self.assertFalse((root/'ikev2/connected').exists())
            before=(root/'calls').read_text()
            self.assertIn('-F ZVPN_IKE_SNAT',before)
            self.assertIn('--to-source 10.30.0.12',before)
            self.assertNotIn('-t nat -F\n',before)
            self.assertNotEqual(call('up-host','10.0.0.0/8','10.1.1.1;touch').returncode,0)
            self.assertEqual((root/'calls').read_text(),before)

    def test_push_authentication_has_no_automatic_retry(self):
        body=SOURCE[SOURCE.index('run() {'):SOURCE.index('\ncase "${1:-}"')]
        # The sandbox forbids creating sockets. Represent daemon socket presence
        # with a file while executing the actual initiation/respawn control flow.
        body=body.replace('[ ! -S "$IKE/charon.vici" ]','[ ! -f "$IKE/charon.vici" ]')
        with tempfile.TemporaryDirectory(prefix='ike-push-') as temp:
            root=Path(temp)
            daemon=root/'charon';daemon.write_text('#!/bin/sh\nexec /bin/sleep 30\n');daemon.chmod(0o700)
            cli=root/'swanctl';cli.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n');cli.chmod(0o700)
            (root/'charon.vici').touch()
            shell='''set -eu
IKE="$1";CHARON="$IKE/charon";SWANCTL="$IKE/swanctl";URI=fixture
native_check() { :; }
charon_owned() { return 1; }
fail() { exit 1; }
sleep() { kill -TERM "$daemon" 2>/dev/null || true; command sleep 0.05; }
'''+body+'\nrun\n'
            for attempt in range(2):
                subprocess.run(['/bin/sh','-c',shell,'fixture',temp],env=dict(os.environ,CALL_LOG=str(root/'calls')),text=True,capture_output=True,timeout=3)
                calls=(root/'calls').read_text()
                self.assertEqual(calls.count('--initiate --child zte-private --timeout 180'),1,calls)

    def test_same_backend_activation_invalidates_dns_rules(self):
        manager=(RES/'manager.sh').read_text()
        body=manager[manager.index('stop_backend() {'):manager.index('\nlog() {')]
        body=body.replace('/etc/init.d/zte_vpn stop','stop_service')
        with tempfile.TemporaryDirectory(prefix='ike-dns-switch-') as temp:
            root=Path(temp);(root/'firewall.backend').write_text('ikev2\n')
            shell='set -eu\nROOT="$1"\nsuspend_guest() { :; }\nstop_service() { :; }\n'+body+'\nstop_backend\n'
            result=subprocess.run(['/bin/sh','-c',shell,'fixture',temp],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertFalse((root/'firewall.backend').exists(), 'Old DNS chain would remain on same-backend activation')


if __name__=='__main__':unittest.main()
