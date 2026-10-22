"""Compile the display-only Unicode fallback with synthetic host fixtures."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class DisplayTextTests(unittest.TestCase):
    def test_utf8_flags_clusters_and_capacity(self):
        with tempfile.TemporaryDirectory(prefix="zte-display-text-") as temporary:
            binary = Path(temporary) / "display-text-test"
            subprocess.run([
                os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                str(HERE.parent / "display-text.c"), str(HERE / "display_text_test.c"),
                "-o", str(binary),
            ], check=True)
            subprocess.run([str(binary)], check=True, env={
                **os.environ,
                "ASAN_OPTIONS": f"detect_leaks={int(sys.platform != 'darwin')}:halt_on_error=1",
                "UBSAN_OPTIONS": "halt_on_error=1",
            })


if __name__ == "__main__":
    unittest.main()
