"""Run VPN readiness shell against fake procfs, including DHCP failure and stale PIDs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'Resources/VPN/manager.sh'

class ReadinessTests(unittest.TestCase):
    def invoke(self, core=True, dns=True, tun=True, wrong_dns=False):
        with tempfile.TemporaryDirectory(prefix='vpn-ready-') as temp:
            root = Path(temp)
            (root/'core.pid').write_text('10\n')
            (root/'dns.pid').write_text('20\n')
            for pid, args in [('10', [str(root/'mihomo')]), ('20', ['dnsmasq', '--conf-file='+str(root/'dnsmasq.conf')])]:
                (root/'proc'/pid).mkdir(parents=True)
                alive = core if pid=='10' else dns
                if alive:
                    if pid=='20' and wrong_dns:args=['foreign-service']
                    (root/'proc'/pid/'cmdline').write_bytes(b'\0'.join(a.encode() for a in args)+b'\0')
            if tun:(root/'tun').touch()
            (root/'firewall.sh').write_text('#!/bin/sh\nprintf firewall-ready\n')
            (root/'firewall.sh').chmod(0o700)
            body=SOURCE.read_text().split('runtime_process() {',1)[1].split('\nwait_wifi()',1)[0]
            body=('runtime_process() {'+body).replace('/proc/',str(root/'proc')+'/').replace('/sys/class/net/zvpn-tun',str(root/'tun'))
            script='set -eu\nROOT="$1"\nCORE="$ROOT/mihomo"\nsleep() { :; }\nfail() { echo "$1" >&2; exit 41; }\n'+body+'\nwait_core\n'
            return subprocess.run(['/bin/sh','-c',script,'test',temp],capture_output=True,text=True)
    def test_ready_requires_core_tun_and_our_dhcp(self):
        r=self.invoke();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('firewall-ready',r.stdout)
    def test_missing_dhcp_is_distinct_from_core_failure(self):
        r=self.invoke(dns=False);self.assertEqual(r.returncode,41);self.assertIn('VPN_DHCP_NOT_READY',r.stderr);self.assertNotIn('firewall-ready',r.stdout)
    def test_reused_dhcp_pid_does_not_count_as_running(self):
        r=self.invoke(wrong_dns=True);self.assertEqual(r.returncode,41);self.assertIn('VPN_DHCP_NOT_READY',r.stderr)
    def test_core_or_tun_failure_not_misreported_as_dhcp(self):
        for kwargs in [dict(core=False),dict(tun=False)]:
            r=self.invoke(**kwargs);self.assertEqual(r.returncode,1);self.assertNotIn('VPN_DHCP_NOT_READY',r.stderr)

if __name__=='__main__':unittest.main()
