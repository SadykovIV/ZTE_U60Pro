#!/usr/bin/env python3
"""Synthetic Windows/macOS archives; no device, vendor binaries or private logs."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

if __package__:
    from .compare_firmware_captures import CaptureError, compare, read_capture
else:
    from compare_firmware_captures import CaptureError, compare, read_capture


def record(path, data, strings=False):
    return {'path': path, 'bytes': str(len(data)) if strings else len(data),
            'sha256': hashlib.sha256(data).hexdigest()}


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.seq = 0

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, *, mac=False, binary=b'\x7fELFsynthetic\0\xff', omitted=False, mutate=None):
        facts = {'firmware': 'TEST_B27', 'inner': 'BD_TEST_B27'}
        observation = {'id': 'ui', ('status' if mac else 'state'): 'missing' if omitted else 'present'}
        if not omitted:
            observation.update(bytes=len(binary), sha256=hashlib.sha256(binary).hexdigest())
        component_path = 'files/ui' if mac else 'files/zte_topsw_devui'
        entries = {} if omitted else {component_path: binary}
        entries['activity.jsonl'] = b'password=PRIVATE_CANARY_SIM_PROFILE\n'
        common = {'complete': True, 'applicationVersion': '1.27.2'}
        if mac:
            metadata = {**common, 'schema': 2, 'before': {'facts': facts, 'files': [observation]},
                        'sources': {'ui': '/usr/bin/zte_topsw_devui'}}
            entries['metadata.json'] = json.dumps(metadata).encode()
            manifest = {'schema': 1, 'files': [record(n, b, True) for n, b in entries.items()]}
        else:
            manifest = {**common, 'schemaVersion': 2, 'factsBefore': facts,
                        'files': [{'id': 'ui', 'path': '/usr/bin/zte_topsw_devui', 'archivePath': component_path,
                                   'observation': observation, 'captureStatus': 'unavailable' if omitted else 'verified'}],
                        'payloads': [record(n, b) for n, b in entries.items()]}
        if mutate:
            mutate(manifest, entries)
        entries['manifest.json'] = json.dumps(manifest).encode()
        self.seq += 1
        path = self.root / f'{self.seq}.zip'
        prefix = 'firmware-support/' if mac else ''
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, data in entries.items():
                archive.writestr(prefix + name, data)
        return path

    def test_cross_platform_same_bytes_by_component_id_without_private_output(self):
        result = compare([self.fixture(), self.fixture(mac=True)])
        self.assertEqual(result['counts'], {'same': 1, 'different': 0, 'not_comparable': 0})
        self.assertNotIn('PRIVATE_CANARY', json.dumps(result))
        self.assertEqual(result['functional_compatibility'], 'not_tested')

    def test_changed_bytes_and_missing_are_distinct(self):
        first = self.fixture()
        self.assertEqual(compare([first, self.fixture(binary=b'changed')])['counts']['different'], 1)
        result = compare([first, self.fixture(omitted=True)])
        self.assertEqual(result['counts']['not_comparable'], 1)
        self.assertEqual(result['components'][0]['observations'][1]['state'], 'missing')

    def test_declared_incomplete_capture_still_valid_evidence(self):
        capture = self.fixture(mutate=lambda m, e: m.update(complete=False))
        self.assertFalse(read_capture(capture)['complete'])

    def test_payload_corruption_and_remote_observation_mismatch(self):
        mutations = [lambda m, e: e.update({'files/zte_topsw_devui': b'corrupt'}),
                     lambda m, e: m['files'][0]['observation'].update(sha256='0' * 64),
                     lambda m, e: m['payloads'][0].update(bytes=999),
                     lambda m, e: e.pop('files/zte_topsw_devui')]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(CaptureError):
                read_capture(self.fixture(mutate=mutation))

    def test_unlisted_payload_and_traversal_rejected_without_extraction(self):
        for name in ['unexpected.txt', '../escape', '/absolute', 'a\\b']:
            with self.subTest(name=name), self.assertRaises(CaptureError):
                read_capture(self.fixture(mutate=lambda m, e: e.update({name: b'bad'})))
        self.assertFalse((self.root / 'escape').exists())

    def test_duplicate_zip_entry_and_symlink_rejected(self):
        path = self.fixture()
        with zipfile.ZipFile(path, 'a') as z:
            info = zipfile.ZipInfo('link')
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            z.writestr(info, '/data/private')
        with self.assertRaises(CaptureError):
            read_capture(path)
        path = self.fixture()
        with zipfile.ZipFile(path, 'a') as z:
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                z.writestr('manifest.json', '{}')
        with self.assertRaises(CaptureError):
            read_capture(path)

    def test_private_source_and_duplicate_component_rejected(self):
        for mutation in [lambda m, e: m['files'][0].update(path='/data/private-key'),
                         lambda m, e: m['files'].append(m['files'][0])]:
            with self.subTest(mutation=mutation), self.assertRaises(CaptureError):
                read_capture(self.fixture(mutate=mutation))

    def test_backup_is_distinct_from_current(self):
        def backup(m, e):
            m['files'][0].update(id='original_ui', path='/data/zte-imei-screen-ru/backup/zte_topsw_devui')
            m['files'][0]['observation']['id'] = 'original_ui'
        result = compare([self.fixture(), self.fixture(mutate=backup)])
        self.assertEqual(result['counts']['not_comparable'], 2)
        self.assertEqual(result['components'][0]['observations'][1]['kind'], 'backup')

    def test_truncated_zip_is_error(self):
        path = self.fixture()
        path.write_bytes(path.read_bytes()[:-30])
        with self.assertRaises(CaptureError):
            read_capture(path)


if __name__ == '__main__':
    unittest.main()
