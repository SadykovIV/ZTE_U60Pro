#!/usr/bin/env python3
"""Test release input identity without invoking the side-effecting packager CLI."""
import ast
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('package_release.py')
# Load the real helpers only: the CLI intentionally stays unchanged and must not
# create release directories, update dependencies.json or copy production files.
TREE = ast.parse(SCRIPT.read_text(), filename=str(SCRIPT))
NS = {'__file__': str(SCRIPT)}
exec(compile(ast.Module(body=[n for n in TREE.body if isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef))], type_ignores=[]), str(SCRIPT), 'exec'), NS)


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.inputs = {
            'ModemAgent/vpnctl/Cargo.toml': '[package]\nname = "zte-vpnctl"\nversion = "1.4.1"\n',
            'ModemAgent/vpnctl/src/main.rs': 'fn main() {}\n',
            'ModemAgent/vpnctl/build.rs': 'fn main() {}\n',
            'ModemAgent/process-runner/Cargo.toml': '[package]\nname = "process-runner"\nversion = "0.1.0"\n',
            'ModemAgent/process-runner/src/lib.rs': '// fixture\n',
            'ModemAgent/.cargo/config.toml': '[build]\n',
            'ModemAgent/Cargo.toml': '[workspace]\n',
            'ModemAgent/Cargo.lock': 'version = 4\n',
        }
        for path, value in self.inputs.items(): self.put(path, value.encode())
        self.archive = self.make_archive(self.inputs)
        self.binary = b'synthetic ARM64 controller input'
        for app in ['MacIMEI', 'Windows_x64']:
            self.put(app+'/Resources/VPN/vpnctl', self.binary)
            self.put_json(app+'/Resources/VPN/SHA256.json', {'vpnctl': self.digest(self.binary)})
            self.put(app+'/Resources/Esim/eSIM-sources.tar.gz', self.archive)
            self.put_json(app+'/Resources/Esim/PROVENANCE.json', {'source_archive_sha256': self.digest(self.archive)})
        self.put('MacIMEI/Sources/Main.swift', b'// fixture Swift\n')
        self.put('Windows_x64/src/Main.cs', b'// fixture C#\n')
        self.put('MacIMEI/dist/ZTE-U60Pro-Manager-1.25-arm64.zip', b'fixture Mac ZIP')
        self.put('Windows_x64/dist/ZTE-U60Pro-Manager-1.25-Windows-x64-portable.zip', b'fixture Windows ZIP')
        resources = {'VPN/vpnctl': self.digest(self.binary), 'Esim/eSIM-sources.tar.gz': self.digest(self.archive)}
        self.mac = {'version': '1.25', 'source_sha256': {'Sources/Main.swift': self.digest(b'// fixture Swift\n')},
                    'zip_sha256': self.digest(b'fixture Mac ZIP'), 'bundle_resources_sha256': resources}
        self.win = {'version': '1.25', 'sources': {'src/Main.cs': self.digest(b'// fixture C#\n')},
                    'zip': {'sha256': self.digest(b'fixture Windows ZIP')}, 'resources': copy.deepcopy(resources)}
        self.save_manifests()

    def digest(self, data): return hashlib.sha256(data).hexdigest()
    def put(self, relative, data):
        p = self.root/relative; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
    def put_json(self, relative, data): self.put(relative, json.dumps(data).encode())
    def save_manifests(self):
        self.put_json('MacIMEI/dist/build-manifest.json', self.mac)
        self.put_json('Windows_x64/dist/windows-1.25-build-manifest.json', self.win)
    def make_archive(self, values):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            for name, text in values.items():
                data=text.encode(); info=tarfile.TarInfo(name); info.size=len(data); archive.addfile(info,io.BytesIO(data))
        return output.getvalue()
    def controller(self): return NS['vpnctl_metadata'](self.root)
    def identity(self):
        with patch.object(NS['subprocess'], 'check_output', side_effect=['a'*40, b' M dirty-source\n']):
            return NS['desktop_build_identity'](self.root, '1.25', self.controller())

    def test_cargo_version_and_hash_inputs_not_hardcoded(self):
        result=self.controller(); self.assertEqual(result['version'], '1.4.1')
        self.assertEqual(result['sha256'], self.digest(self.binary))
        self.assertEqual(result['versionSourceSha256'], self.digest(self.inputs['ModemAgent/vpnctl/Cargo.toml'].encode()))
        self.assertEqual(set(result['verifiedSourceInputs']), set(self.inputs))

    def test_stale_cargo_version_or_source_is_rejected(self):
        for name in ['ModemAgent/vpnctl/Cargo.toml', 'ModemAgent/vpnctl/src/main.rs', 'ModemAgent/process-runner/src/lib.rs']:
            original=(self.root/name).read_bytes(); self.put(name, original+b'\n# changed\n')
            with self.assertRaises(SystemExit): self.controller()
            self.put(name, original)

    def test_new_unarchived_source_is_rejected(self):
        self.put('ModemAgent/vpnctl/src/added.rs', b'// missing corresponding source\n')
        with self.assertRaises(SystemExit): self.controller()

    def test_wrong_controller_package_is_rejected(self):
        self.put('ModemAgent/vpnctl/Cargo.toml', b'[package]\nname="another"\nversion="1.4.1"\n')
        with self.assertRaises(SystemExit): self.controller()

    def test_binary_or_pin_mismatch_is_rejected(self):
        for app in ['MacIMEI', 'Windows_x64']:
            self.put(app+'/Resources/VPN/vpnctl', b'other controller')
            with self.assertRaises(SystemExit): self.controller()
            self.put(app+'/Resources/VPN/vpnctl', self.binary)
        self.put_json('Windows_x64/Resources/VPN/SHA256.json', {'vpnctl': 'f'*64})
        with self.assertRaises(SystemExit): self.controller()

    def test_archive_provenance_mismatch_is_rejected(self):
        self.put_json('Windows_x64/Resources/Esim/PROVENANCE.json', {'source_archive_sha256': 'f'*64})
        with self.assertRaises(SystemExit): self.controller()

    def test_dirty_head_is_explicitly_informational(self):
        result=self.identity(); self.assertTrue(result['workingTreeDirty'])
        self.assertTrue(result['buildSourceCommitInformationalOnly']); self.assertEqual(result['packagingHead'], 'a'*40)
        self.assertEqual(set(result['desktopBuildManifestSha256']), {'MacIMEI','Windows_x64'})
        self.assertFalse((self.root/'release').exists())

    def test_missing_git_is_unknown_not_clean(self):
        with patch.object(NS['subprocess'], 'check_output', side_effect=subprocess.CalledProcessError(128,['git'])):
            result=NS['desktop_build_identity'](self.root,'1.25',self.controller())
        self.assertIsNone(result['workingTreeDirty']); self.assertIsNone(result['packagingHead'])

    def test_stale_or_added_desktop_sources_are_rejected(self):
        for name in ['MacIMEI/Sources/Main.swift','Windows_x64/src/Main.cs']:
            original=(self.root/name).read_bytes(); self.put(name,b'new source')
            with self.assertRaises(SystemExit): self.identity()
            self.put(name,original)
        self.put('Windows_x64/src/Added.cs',b'new unbuilt source')
        with self.assertRaises(SystemExit): self.identity()

    def test_zip_and_resource_build_bindings_are_checked(self):
        self.put('Windows_x64/dist/ZTE-U60Pro-Manager-1.25-Windows-x64-portable.zip',b'other ZIP')
        with self.assertRaises(SystemExit): self.identity()
        self.put('Windows_x64/dist/ZTE-U60Pro-Manager-1.25-Windows-x64-portable.zip',b'fixture Windows ZIP')
        self.win['resources']['VPN/vpnctl']='f'*64; self.save_manifests()
        with self.assertRaises(SystemExit): self.identity()
        self.win['resources']['VPN/vpnctl']=self.digest(self.binary)
        self.win['resources']['Esim/eSIM-sources.tar.gz']='f'*64; self.save_manifests()
        with self.assertRaises(SystemExit): self.identity()

    def test_manifest_uses_verified_metadata_not_stale_literal(self):
        source=SCRIPT.read_text()
        self.assertIn("'vpnctlVersion': controller_metadata['version']",source)
        self.assertIn("'buildSourceIdentity': build_source_identity",source)
        self.assertNotIn("'vpnctlVersion': '1.3.0'",source)


class SupportDependenciesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.files = {'NOTICE-QMI.txt', 'README.txt', 'collect.sh', 'radio-inspect-build.json',
                      'support-helpers.json', 'support-sources.tar.gz',
                      'zte-support-config', 'zte-support-nv', 'zte-support-qmi'}
        self.manifest = {name: hashlib.sha256(name.encode()).hexdigest() for name in self.files}
        for app in ['MacIMEI', 'Windows_x64']:
            base = self.root / app / 'Resources/FirmwareSupport'; base.mkdir(parents=True)
            for name in self.files: (base / name).write_bytes(name.encode())
            (base / 'SHA256.json').write_text(json.dumps(self.manifest))

    def paths(self): return NS['support_dependency_paths'](self.root)
    def windows(self, name): return self.root / 'Windows_x64/Resources/FirmwareSupport' / name

    def test_archive_contains_both_clients_helpers_sources_and_notices(self):
        paths = self.paths()
        expected = {f'{app}/Resources/FirmwareSupport/{name}'
                    for app in ['MacIMEI', 'Windows_x64'] for name in self.files | {'SHA256.json'}}
        self.assertEqual(set(paths), expected)
        archive = self.root / 'deps.tar.gz'
        NS['tar_gz'](archive, {name: self.root / name for name in paths})
        with tarfile.open(archive, 'r:gz') as tar:
            self.assertEqual(set(tar.getnames()), expected)
            for name in paths: self.assertEqual(tar.extractfile(name).read(), (self.root / name).read_bytes())

    def test_missing_generated_helper_fails_before_release(self):
        self.windows('zte-support-qmi').unlink()
        with self.assertRaises(SystemExit): self.paths()

    def test_stale_helper_and_source_archive_fail(self):
        for name in ['zte-support-nv', 'support-sources.tar.gz']:
            self.windows(name).write_bytes(b'changed')
            with self.assertRaises(SystemExit): self.paths()
            self.windows(name).write_bytes(name.encode())

    def test_differently_pinned_windows_build_is_rejected(self):
        self.windows('zte-support-config').write_bytes(b'other build')
        manifest = dict(self.manifest, **{'zte-support-config': hashlib.sha256(b'other build').hexdigest()})
        self.windows('SHA256.json').write_text(json.dumps(manifest))
        with self.assertRaises(SystemExit): self.paths()

    def test_unknown_private_file_cannot_enter_archive_via_manifest(self):
        self.windows('connection.json').write_bytes(b'private fixture')
        self.windows('SHA256.json').write_text(json.dumps(dict(self.manifest, **{'connection.json': hashlib.sha256(b'private fixture').hexdigest()})))
        with self.assertRaises(SystemExit): self.paths()

    def test_symlink_is_not_a_release_input(self):
        self.windows('zte-support-qmi').unlink()
        self.windows('zte-support-qmi').symlink_to(self.root / 'MacIMEI/Resources/FirmwareSupport/zte-support-qmi')
        with self.assertRaises(SystemExit): self.paths()


if __name__=='__main__': unittest.main(verbosity=2)
