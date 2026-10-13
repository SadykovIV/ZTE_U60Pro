"""Exercise the production bridge-sysctl writes through boot-time node races."""
from pathlib import Path
import subprocess
import tempfile
import unittest

FIREWALL = Path(__file__).resolve().parents[1] / 'Resources/VPN/firewall.sh'


class BootFirewallTests(unittest.TestCase):
    def test_ipv6_presence_does_not_require_ipv4_node_and_later_pass_sets_both(self):
        source=FIREWALL.read_text()
        region=source[source.index('bridge_sysctl() {'):source.index('\n# IPv4 guard remains')]
        with tempfile.TemporaryDirectory(prefix='vpn-boot-sysctl-') as temporary:
            root=Path(temporary)
            script=region.replace('/proc/sys/net/',str(root)+'/')
            ipv6=root/'ipv6/conf/br-vpn/disable_ipv6';ipv6.parent.mkdir(parents=True);ipv6.write_text('0\n')
            ipv4=root/'ipv4/conf/br-vpn/rp_filter'
            def run():return subprocess.run(['/bin/sh','-ec',script],capture_output=True,text=True)
            first=run();self.assertEqual(first.returncode,0,first.stderr);self.assertEqual(ipv6.read_text(),'1\n')
            self.assertFalse(ipv4.exists())
            ipv4.parent.mkdir(parents=True);ipv4.write_text('1\n')
            second=run();self.assertEqual(second.returncode,0,second.stderr);self.assertEqual(ipv4.read_text(),'0\n')

    def test_existing_unwritable_node_is_not_hidden(self):
        source=FIREWALL.read_text()
        function=source[source.index('bridge_sysctl() {'):source.index('\nbridge_sysctl /proc')]
        with tempfile.TemporaryDirectory(prefix='vpn-boot-sysctl-') as temporary:
            node=Path(temporary)/'rp_filter';node.mkdir()
            result=subprocess.run(['/bin/sh','-ec',function+'\nbridge_sysctl "$1" 0','fixture',str(node)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,'A real error writing an existing node was suppressed')

    def test_node_removed_during_write_is_retryable_next_pass(self):
        source=FIREWALL.read_text()
        function=source[source.index('bridge_sysctl() {'):source.index('\nbridge_sysctl /proc')]
        with tempfile.TemporaryDirectory(prefix='vpn-boot-sysctl-') as temporary:
            node=Path(temporary)/'rp_filter';node.write_text('1\n')
            # Redirection succeeds, then the interface disappears before the write.
            result=subprocess.run(['/bin/sh','-ec','printf() { rm "$NODE"; return 1; }\n'+function+'\nbridge_sysctl "$NODE" 0'],env={'NODE':str(node),'PATH':'/usr/bin:/bin'},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(node.exists())


if __name__ == '__main__': unittest.main()
