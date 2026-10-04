#!/usr/bin/env python3
"""Bootstrap snapshot guards, including rebuilds outside a Git checkout."""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import package_resources as packaging
import package_permanent as permanent

_SPEC = importlib.util.spec_from_file_location("sync_public_resources", Path(__file__).resolve().parents[2] / "Windows_x64/sync_public_resources.py")
sync = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(sync)


class BootstrapSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'tools').mkdir()
        self.path = self.root / 'tools/dependencies.json'
        self.baseline = b'{"fixture": "pinned bootstrap"}\n'
        self.sha = hashlib.sha256(self.baseline).hexdigest()
        for name, value in [('ROOT', self.root), ('BASELINE_DEPENDENCIES_SHA', self.sha)]:
            context = patch.object(packaging, name, value)
            context.start()
            self.addCleanup(context.stop)

    def test_extracted_snapshot_requires_no_git(self):
        self.path.write_bytes(self.baseline)
        with patch.object(packaging.subprocess, 'run') as run:
            self.assertEqual(packaging.baseline_dependencies(), self.baseline)
            run.assert_not_called()

    def test_changed_current_metadata_uses_exact_pinned_ref(self):
        self.path.write_bytes(b'{"fixture": "new release"}')
        result = subprocess.CompletedProcess([], 0, stdout=self.baseline)
        with patch.object(packaging.subprocess, 'run', return_value=result) as run:
            self.assertEqual(packaging.baseline_dependencies(), self.baseline)
            self.assertEqual(run.call_args.args[0], ['git', 'show', packaging.BASELINE_REF + ':tools/dependencies.json'])
            self.assertTrue(run.call_args.kwargs['check'])

    def test_changed_ref_content_refuses(self):
        self.path.write_bytes(b'new release')
        result = subprocess.CompletedProcess([], 0, stdout=b'not pinned')
        with patch.object(packaging.subprocess, 'run', return_value=result):
            with self.assertRaises(SystemExit):
                packaging.baseline_dependencies()

    def test_missing_ref_never_falls_back_to_new_metadata(self):
        self.path.write_bytes(b'new release')
        with patch.object(packaging.subprocess, 'run', side_effect=subprocess.CalledProcessError(128, ['git'])):
            with self.assertRaises(subprocess.CalledProcessError):
                packaging.baseline_dependencies()


class AgentUpgradeRetentionTests(unittest.TestCase):
    """Run real generator entrypoints against tiny isolated fixture resources."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mac = self.root / 'MacIMEI/Resources'
        self.win = self.root / 'Windows_x64'
        self.first = '1' * 64
        self.historical = '2' * 64
        self.custom = 'f' * 64
        self.swift = self.root / 'MacIMEI/Sources/BundledAgent.swift'
        self.cs = self.win / 'src/Core/AgentPackage.cs'
        self.put(self.swift, 'enum BundledAgent {\n    static let version = "1.0.0"\n    static let sha256 = "' + self.first + '"\n    static let dashboardInstallerSHA256 = "' + self.historical + '"\n    static let supportedUpgradeHashes: Set<String> = [sha256,\n        "' + self.historical + '" // reviewed fixture release\n    ]\n}\n')
        self.put(self.cs, 'public static class AgentPackage {\n    public const string Version = "1.0.0";\n    public const string Sha256 = "' + self.first + '";\n    public static readonly IReadOnlySet<string> SupportedUpgradeHashes = new[] { Sha256,\n        "' + self.historical + '",\n    }.ToFrozenSet(StringComparer.Ordinal);\n}\n')
        self.put(self.root / 'MacIMEI/Sources/VPNSettings.swift', '\n'.join('static let '+key+' = "'+self.historical+'"' for key in ['launcherHash','helperHash','dashboardIndexHash']))
        for relative, fields in sync.PINS.items():
            if relative == 'src/Core/AgentPackage.cs': continue
            self.put(self.win / relative, '\n'.join('const string '+key+' = "'+self.historical+'";' for key in fields))
        self.put(self.root / 'ModemAgent/target/aarch64-unknown-linux-musl/release/zte-vpnctl', 'synthetic controller')
        self.put(self.root / 'ModemAgent/web-app/dist/index.html', 'synthetic dashboard')
        self.put(self.root / 'ModemAgent/web-app/node_modules/jsqr/LICENSE', 'synthetic license')
        for name in ['manager.sh','configure.lua','launcher.so','launcher.sha256','dashboard-uhttpd','start-dashboard.sh','dashboard-html.sh','stop-owned-listener.sh','update-rc-local.sh','preserve-dashboard-assets.sh']:
            self.put(self.mac / 'VPN' / name, 'synthetic '+name)
        self.put(self.mac / 'VPN/README.md', 'обновление агента 2.7.0-vpn.1')
        self.put(self.mac / 'VPN/upgrade-controller.sh', 'helper_sha='+self.first+'\ncase "$old" in '+self.historical+'|"$helper_sha") :;; esac\nmanager_sha='+self.first+'\nconfigure_sha='+self.first+'\n')
        self.put(self.mac / 'VPN/update-agent.sh', 'agent_sha='+self.first+'\ncase "$old" in '+self.historical+'|"$agent_sha") :;; esac\ndashboard_sha='+self.first+'\ndashboard_installer_sha='+self.first+'\n')
        self.put(self.mac / 'AgentInstallation/dashboard.sh', 'payload_sha='+self.first+'\n')
        self.put(self.mac / 'AgentInstallation/manager.sh', 'synthetic installer')
        for app in [self.mac, self.win / 'Resources']:
            self.put(app / 'Onboarding/provenance.json', json.dumps({'files':{}, 'local_changes':[]}))
        self.put(self.mac / 'FirmwareResearch/probes.json', '{}')
        for name in ['zte_nv','zte_config','zte_config_read']:
            self.put(self.root / 'MacIMEI/DeviceHelpers/bin' / name, 'synthetic '+name)
        for module, name, value in [(permanent,'ROOT',self.root),(sync,'ROOT',self.root),(sync,'WINDOWS',self.win),(sync,'SOURCE',self.mac),(sync,'DEST',self.win/'Resources')]:
            context=patch.object(module,name,value);context.start();self.addCleanup(context.stop)

    def put(self, path, text):
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(text)

    def generate(self, contents):
        agent=self.root/'candidate-agent';agent.write_bytes(contents)
        digest=hashlib.sha256(contents).hexdigest()
        with patch.object(sys,'argv',['package_permanent.py','--agent',str(agent),'--sha256',digest]):
            permanent.main()
        # The separate eSIM packager supplies the identical RPC payload.
        self.put(self.mac/'Esim/zte-agent-esim',contents.decode())
        permanent.manifest(self.mac/'Esim')
        return digest

    def synchronize(self, check=False):
        with patch.object(sys,'argv',['sync_public_resources.py']+(['--check'] if check else [])):
            sync.main()

    def swift_set(self):
        text=self.swift.read_text()
        current=re.search(r'static let sha256 = "([0-9a-f]{64})"',text)[1]
        body=re.search(r'supportedUpgradeHashes: Set<String> = \[(.*?)\]',text,re.S)[1]
        return {current,*re.findall(r'"([0-9a-f]{64})"',body)}

    def windows_set(self):
        text=self.cs.read_text()
        current=re.search(r'const string Sha256 = "([0-9a-f]{64})"',text)[1]
        body=re.search(r'SupportedUpgradeHashes = new\[\] \{(.*?)\}\.ToFrozenSet',text,re.S)[1]
        return {current,*re.findall(r'"([0-9a-f]{64})"',body)}

    def test_two_generations_retain_source_pins_and_sync_exactly(self):
        second=self.generate(b'synthetic generation two')
        self.assertEqual(self.swift_set(),{self.first,self.historical,second})
        self.synchronize();self.assertEqual(self.windows_set(),self.swift_set())
        third=self.generate(b'synthetic generation three')
        self.assertEqual(self.swift_set(),{self.first,self.historical,second,third})
        self.synchronize();self.assertEqual(self.windows_set(),self.swift_set())
        before=self.swift.read_bytes();self.generate(b'synthetic generation three')
        self.assertEqual(self.swift.read_bytes(),before,'same generation must not duplicate history')
        self.synchronize(check=True)

    def test_dynamic_registry_refuses_before_packaging_mutates_resources(self):
        before=(self.mac/'Onboarding/provenance.json').read_bytes()
        source=self.swift.read_text().replace('Set<String> = [sha256,','Set<String> = [deviceHash, sha256,')
        self.swift.write_text(source)
        with self.assertRaises(ValueError):self.generate(b'synthetic refused generation')
        self.assertEqual(self.swift.read_text(),source)
        self.assertEqual((self.mac/'Onboarding/provenance.json').read_bytes(),before)
        self.assertFalse((self.mac/'AgentDashboard').exists())
        with self.assertRaises(ValueError):sync.swift_agent_upgrade_hashes(source)

    def test_duplicate_source_pin_and_registry_are_rejected(self):
        source=self.swift.read_text()
        for altered in [source+'\nstatic let sha256 = "'+self.first+'"\n', source+'\nstatic let supportedUpgradeHashes: Set<String> = [sha256]\n']:
            with self.assertRaises(ValueError):permanent.retain_previous_agent_hash(altered,'3'*64)
            with self.assertRaises(ValueError):sync.swift_agent_upgrade_hashes(altered)

    def test_sync_removes_windows_only_hash_and_check_detects_registry_drift(self):
        self.generate(b'synthetic generation two')
        text=self.cs.read_text().replace('new[] { Sha256,','new[] { Sha256, "'+self.custom+'",')
        self.cs.write_text(text)
        self.synchronize()
        self.assertNotIn(self.custom,self.windows_set(),'Windows cannot independently expand trusted hashes')
        self.assertEqual(self.windows_set(),self.swift_set())
        self.cs.write_text(self.cs.read_text().replace('"'+self.historical+'",',''))
        with self.assertRaises(ValueError):self.synchronize(check=True)


if __name__ == '__main__':
    unittest.main()
