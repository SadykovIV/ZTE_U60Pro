#!/usr/bin/env python3
"""Bootstrap snapshot guards, including rebuilds outside a Git checkout."""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import package_resources as packaging


class BootstrapSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
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


if __name__ == '__main__':
    unittest.main()
