"""Execute both desktop collectors' VPN commands against a private filesystem."""
from pathlib import Path
import json, os, re, subprocess, tempfile, unittest

REPO=Path(__file__).resolve().parents[2]

def commands(path):
    text=(REPO/path).read_text();result={}
    for name in ['vpn.log','vpn-runtime.txt']:
        line=next(l for l in text.splitlines() if '("'+name+'",' in l)
        match=re.search(r', ("(?:[^"\\]|\\.)*")(?: \+ "\\n" \+ (?:ipaMetadataCommand|IpaMetadataCommand))?\),$',line)
        result[name]=json.loads(match.group(1))
        if name=='vpn-runtime.txt':
            if path.endswith('.swift'):
                appendix=text.split('static let ipaMetadataCommand = #"""\n',1)[1].split('\n"""#',1)[0]
            else:
                appendix=text.split('IpaMetadataCommand = """\n',1)[1].split('\n        """;',1)[0]
                appendix='\n'.join(l[8:] for l in appendix.splitlines())
            result[name]+='\n'+appendix
    return result

class VpnLogTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='vpn-diagnostic-')
        self.root=Path(self.temp.name);self.bin=self.root/'bin';self.bin.mkdir()
        self.mac=commands('MacIMEI/Sources/ModemInformation.swift')
        self.win=commands('Windows_x64/src/Diagnostics/ModemLogCollector.cs')
        for name in ['cat','tail','sed','readlink']:
            real=Path('/usr/bin')/name
            if not real.exists():real=Path('/bin')/name
            (self.bin/name).symlink_to(real)
        (self.bin/'stat').write_text('#!/bin/sh\nprintf "0\\n"\n');(self.bin/'stat').chmod(0o700)
        for name in ['ip','iptables','nft','ebtables','uci','hostapd_cli']:
            (self.bin/name).write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$CALLS"\ncase "$*" in *PRIVATE*) exit 99;; esac\nexit 0\n');(self.bin/name).chmod(0o700)
    def tearDown(self):self.temp.cleanup()
    def run_command(self,name):
        script=self.mac[name]
        for prefix in ['data','proc','sys']:
            script=script.replace('/'+prefix+'/',str(self.root/prefix)+'/')
        script=script.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin','export PATH='+str(self.bin))
        script=script.replace('safe_dir /data ', 'safe_dir '+str(self.root/'data')+' ')
        return subprocess.run(['/bin/sh','-c',script],env={**os.environ,'PATH':str(self.bin),'CALLS':str(self.root/'calls')},capture_output=True,text=True)
    def test_platforms_collect_the_same_commands(self):self.assertEqual(self.mac,self.win)
    def test_logs_include_newest_runtime_errors_without_profiles_or_linked_files(self):
        root=self.root/'data/zte-vpn';root.mkdir(parents=True)
        (root/'core.log').write_text('first\n'+'x'*66000+'\nlatest tunnel timeout\n')
        (root/'dns.log').write_text('DHCP port is already in use\n')
        (root/'config.json').write_text('PRIVATE_PROFILE')
        secret=self.root/'secret';secret.write_text('PRIVATE_FILE');(root/'firewall.log').symlink_to(secret)
        out=self.run_command('vpn.log');self.assertEqual(out.returncode,0,out.stderr)
        self.assertIn('latest tunnel timeout',out.stdout);self.assertIn('DHCP port',out.stdout)
        self.assertNotIn('first',out.stdout);self.assertNotIn('PRIVATE',out.stdout)
    def test_runtime_reads_rules_without_mutations_or_private_uci_fields(self):
        out=self.run_command('vpn-runtime.txt');self.assertEqual(out.returncode,0,out.stderr)
        calls=(self.root/'calls').read_text();self.assertIn('-nvxL ZVPN_DNS',calls);self.assertIn('table 19090',calls)
        self.assertIn('ipa_metadata=not-assessed',out.stdout)
        for dangerous in ['reload','restart',' add ',' del ',' replace ',' -A ',' -I ',' -D ',' set ',' commit ','.key','.ssid','config.json','profiles/']:
            self.assertNotIn(dangerous,calls)
    def test_absent_installation_is_reported_without_failing_export(self):
        out=self.run_command('vpn.log');self.assertEqual(out.returncode,0);self.assertIn('not present',out.stdout)

if __name__=='__main__':unittest.main()
