#!/usr/bin/env python3
"""Run the production read-only hash function against local synthetic files."""
import pathlib
import re
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).parents[1] / "src/Core/AccessIdentity.cs"
FUNCTION = re.search(r"        observed_hash\(\) \{.*?\n        \}", SOURCE.read_text(), re.S).group(0)


class HashPathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def probe(self, path):
        # A local hash stub proves whether an unsafe input reached the hasher.
        command = "set -eu\nsha256sum() { printf 'HASH_CALLED\\n'; }\n" + FUNCTION + '\nobserved_hash "$1"\n'
        return subprocess.run(["/bin/sh", "-c", command, "test", str(path)], capture_output=True, timeout=3)

    def assert_refused(self, path):
        reply = self.probe(path)
        self.assertEqual(reply.returncode, 71)
        self.assertEqual(reply.stdout, b"")

    def test_regular_file_hashes(self):
        p = self.root / "regular"; p.write_bytes(b"synthetic")
        self.assertEqual(self.probe(p).stdout, b"HASH_CALLED\n")

    def test_missing_leaf_is_absent(self):
        p = self.root / "missing"
        self.assertEqual(self.probe(p).stdout, f"absent  {p}\n".encode())

    def test_missing_ancestors_are_absent(self):
        p = self.root / "missing" / "nested" / "firmware"
        reply = self.probe(p)
        self.assertEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, f"absent  {p}\n".encode())

    def test_directory_never_reaches_hasher(self):
        p = self.root / "directory"; p.mkdir()
        self.assert_refused(p)

    def test_fifo_never_reaches_hasher(self):
        import os
        p = self.root / "fifo"; os.mkfifo(p)
        self.assert_refused(p)

    def test_leaf_symlink_refused(self):
        p = self.root / "link"; p.symlink_to(self.root / "missing")
        self.assert_refused(p)

    def test_ancestor_symlink_refused_even_for_missing_leaf(self):
        target = self.root / "target"; target.mkdir()
        p = self.root / "link"; p.symlink_to(target, target_is_directory=True)
        self.assert_refused(p / "missing" / "leaf")

    def test_non_directory_ancestor_is_not_absence(self):
        p = self.root / "file"; p.write_bytes(b"synthetic")
        self.assert_refused(p / "leaf")


if __name__ == "__main__":
    unittest.main(verbosity=2)
