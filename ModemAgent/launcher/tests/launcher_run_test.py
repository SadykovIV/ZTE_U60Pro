"""Execute the boot wrapper against local fake files; never preload vendor code."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/launcher-run.sh'
HASHES = ['e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9',
          '16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4',
          '8d2ebbde880934f52195ad9595815d728f7aa4671bb0633d5a5149b09467ae90',
          'd6c3cd409705d5aa9c12185c84074513b159088025f005da7dbf01c51e3c3715']


class WrapperTests(unittest.TestCase):
    def test_profiles_unknown_and_platform_fail_to_plain(self):
        with tempfile.TemporaryDirectory(prefix='launcher-wrapper-') as temp:
            base = Path(temp); root = base / 'root'; root.mkdir(mode=0o700)
            bindir = base / 'bin'; bindir.mkdir()
            stock = base / 'stock'; stock.write_text('#!/bin/sh\nprintf "%s\\n" "${ZTE_LAUNCHER:-plain}"\n'); stock.chmod(0o700)
            cid = base / 'cid'; cid.write_text('fixture-cid\n')
            (root / 'owner').write_text('zte-native-launcher-v1\n')
            (root / 'cid').write_bytes(cid.read_bytes()); (root / 'enabled').touch()
            (root / 'payload').write_text('fixture bytes')
            digest = hashlib.sha256((root / 'payload').read_bytes()).hexdigest()
            (root / 'launcher.sha256').write_text(digest + '  payload\n')
            def tool(name, body):
                path = bindir / name; path.write_text('#!/bin/sh\n' + body); path.chmod(0o700)
            tool('stat', 'echo 0:700\n')
            tool('id', 'echo 0\n')
            tool('uname', 'case "$1" in -s) echo Linux;; -m) echo "${TEST_ARCH:-aarch64}";; *) exit 1;; esac\n')
            tool('sha256sum', f'if [ "$1" = "{stock}" ]; then printf "%s  %s\\n" "$TEST_UI_HASH" "$1";else exec /usr/bin/shasum -a 256 "$@";fi\n')
            source = SOURCE.read_text()
            for old, new in [('/data/zte-launcher', str(root)), ('/usr/bin/zte_topsw_devui', str(stock)),
                             ('/sys/block/mmcblk0/device/cid', str(cid)), ('/tmp/zte-launcher', str(base / 'state')),
                             ('/tmp/zte-vpn-screen', str(base / 'screen')), ('/sys/kernel/debug/dri/0/clients', str(base / 'clients'))]:
                source = source.replace(old, new)
            # Do not load any extension into the host fixture's shell.
            source = source.replace('export LD_PRELOAD="$root/launcher.so" ZTE_LAUNCHER=1', 'export ZTE_LAUNCHER=1')
            script = base / 'run.sh'; script.write_text(source)
            env = dict(os.environ, PATH=str(bindir) + ':/usr/bin:/bin')
            for digest in HASHES:
                result = subprocess.run(['/bin/sh', str(script)], env=dict(env, TEST_UI_HASH=digest), capture_output=True, timeout=5)
                self.assertEqual((result.returncode, result.stdout), (0, b'1\n'))
            for digest, arch in [('0' * 64, 'aarch64'), (HASHES[2], 'armv7l')]:
                result = subprocess.run(['/bin/sh', str(script)], env=dict(env, TEST_UI_HASH=digest, TEST_ARCH=arch), capture_output=True, timeout=5)
                self.assertEqual((result.returncode, result.stdout), (0, b'plain\n'))


if __name__ == '__main__':
    unittest.main()
