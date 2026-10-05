"""Exercise the actual FIFO/tee producer locally, without SSH or device paths.
The platform/CID/partition checks before the streaming region are not bypassed
in the shipped script; this harness maps only the streaming region to fixtures.
"""
import hashlib
import io
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import uuid

READER = Path(__file__).resolve().parents[1] / "Resources/DeviceBackups/reader.sh"


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.stage = Path('/tmp') / ('zte-device-backup-' + str(uuid.uuid4()))
        self.stage.mkdir(mode=0o700)
        self.fixture = self.stage / 'fixture'
        self.fixture.mkdir()
        self.bin = self.stage / 'bin'
        self.bin.mkdir()
        self.command('stat', 'case "$2" in %u) printf 0;; %a) printf 700;; *) exit 1;; esac\n')
        self.command('sha256sum', '/usr/bin/shasum -a 256 "$@"\n')
        self.raw = self.fixture / 'raw'
        self.raw.write_bytes(b'x' * 4194304)
        source = READER.read_text()
        config = source[source.index('config_paths() {'):source.index('case "$mode" in\n  estimate)')]
        config = config.replace('"/$path"', '"' + str(self.fixture) + '/$path"')
        config = config.replace('-C / "$@"', '-C "' + str(self.fixture) + '" "$@"')
        region = source[source.index('stage=${0%/*}'):]
        region = region.replace('"/dev/$dev"', '"' + str(self.raw) + '"')
        region = region.replace('-C / data', '-C "' + str(self.fixture) + '" data')
        region = region.replace('$(cat /sys/block/mmcblk0/device/cid)', 'test-cid')
        self.script = self.stage / 'reader.sh'
        self.script.write_text('''#!/bin/sh
set -eu
umask 077
export PATH="''' + str(self.bin) + ''':/usr/bin:/bin:/usr/sbin:/sbin"
mode=$1; cid=test-cid; dev=fixture; expected=4194304
fail() { printf 'BACKUP_ERROR %s\\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
''' + config + region)

    def tearDown(self):
        shutil.rmtree(self.stage)

    def command(self, name, body):
        file = self.bin / name
        file.write_text('#!/bin/sh\n' + body)
        file.chmod(0o700)

    def run_mode(self, mode):
        return subprocess.run(['/bin/sh', str(self.script), mode], capture_output=True, timeout=20)

    def receipt(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        matches = re.findall(rb'^BACKUP_RESULT sha256=([a-f0-9]{64}) bytes=([0-9]+)$', result.stderr, re.M)
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0][0].decode(), hashlib.sha256(result.stdout).hexdigest())
        self.assertEqual(int(matches[0][1]), len(result.stdout))
        self.assertFalse(list(self.stage.glob('stream-*')), 'Temporary FIFOs/results not cleaned')

    def test_user_archive_excludes_recursive_and_runtime_data_without_following_symlinks(self):
        data = self.fixture / 'data'
        for directory in ['local/tmp', 'zte-imei-studio/installations', 'zte-imei-studio/stage-fixture', 'cache', 'log', 'logs', 'open-u60-agent-backups', 'zte-imei-ttl/backup', 'documents']:
            path = data / directory
            path.mkdir(parents=True, exist_ok=True)
            (path / 'file').write_text('content')
        (data / 'documents' / 'reference').symlink_to('/etc/passwd')
        result = self.run_mode('userData')
        self.receipt(result)
        with tarfile.open(fileobj=io.BytesIO(result.stdout), mode='r:') as archive:
            names = archive.getnames()
            self.assertIn('data/documents/file', names)
            self.assertTrue(archive.getmember('data/documents/reference').issym())
            for excluded in ['data/local/tmp', 'data/zte-imei-studio/installations', 'data/zte-imei-studio/stage-fixture', 'data/cache', 'data/log', 'data/logs', 'data/open-u60-agent-backups', 'data/zte-imei-ttl/backup']:
                self.assertFalse(any(name == excluded or name.startswith(excluded + '/') for name in names), excluded)

    def test_user_archive_uses_busybox_compatible_exclusion_file(self):
        self.command('tar', 'for argument in "$@"; do case "$argument" in --*) echo "tar: unrecognized option" >&2; exit 1;; esac; done; exec /usr/bin/tar "$@"\n')
        data = self.fixture / 'data'
        (data / 'cache').mkdir(parents=True)
        (data / 'cache' / 'secret').write_text('excluded')
        (data / 'keep').write_text('keep')
        result = self.run_mode('userData')
        self.receipt(result)
        with tarfile.open(fileobj=io.BytesIO(result.stdout), mode='r:') as archive:
            self.assertIn('data/keep', archive.getnames())
            self.assertNotIn('data/cache/secret', archive.getnames())

    def test_configuration_includes_accounts_services_ssclash_and_boot_links(self):
        for name in ['etc/config/network', 'etc/rc.local', 'etc/zte-imei-admin/doas.conf',
                     'etc/init.d/zte_imei_ssclash', 'etc/init.d/zte_imei_screen_ru',
                     'data/zte-imei-apps/ssclash/.ssclash/config.json',
                     'data/local/tmp/start_zte_agent.sh', 'data/zte-imei-studio/start_zte_agent.sh', 'data/zte-imei-studio/start_zte_imei_studio.sh', 'data/zte-imei-studio/bin/dropbear', 'data/zte-vpn/profiles/test.json', 'data/zte-vpn/config.json', 'data/zte-vpn/mihomo', 'data/unrelated/private.txt']:
            path = self.fixture / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        links = self.fixture / 'etc/rc.d'
        links.mkdir()
        (links / 'S95zte_imei_ssclash').symlink_to('../init.d/zte_imei_ssclash')
        result = self.run_mode('configuration')
        self.receipt(result)
        with tarfile.open(fileobj=io.BytesIO(result.stdout), mode='r:') as archive:
            for name in ['etc/config/network', 'etc/rc.local', 'etc/zte-imei-admin/doas.conf',
                         'etc/init.d/zte_imei_ssclash', 'etc/init.d/zte_imei_screen_ru',
                         'data/zte-imei-apps/ssclash/.ssclash/config.json', 'data/local/tmp/start_zte_agent.sh', 'data/zte-imei-studio/start_zte_agent.sh', 'data/zte-imei-studio/start_zte_imei_studio.sh', 'data/zte-imei-studio/bin/dropbear', 'data/zte-vpn/profiles/test.json', 'data/zte-vpn/config.json']:
                self.assertIn(name, archive.getnames())
            self.assertTrue(archive.getmember('etc/rc.d/S95zte_imei_ssclash').issym())
            self.assertNotIn('data/unrelated/private.txt', archive.getnames())
            self.assertNotIn('data/zte-vpn/mihomo', archive.getnames())

    def test_tar_failure_cannot_be_hidden_by_successful_tee_and_hash(self):
        self.command('tar', 'printf incomplete; exit 7\n')
        result = self.run_mode('userData')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'BACKUP_ERROR READ', result.stderr)
        self.assertNotIn(b'BACKUP_RESULT', result.stderr)
        self.assertFalse(list(self.stage.glob('stream-*')))

    def test_raw_copy_has_matching_before_stream_after_hashes_and_size(self):
        result = self.run_mode('partition')
        self.receipt(result)
        self.assertEqual(result.stdout, self.raw.read_bytes())

    def test_raw_partition_changes_during_copy_are_rejected(self):
        self.command('dd', 'cat "' + str(self.raw) + '"; printf change >> "' + str(self.raw) + '"\n')
        result = self.run_mode('partition')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'BACKUP_ERROR CHANGED_PARTITION', result.stderr)
        self.assertNotIn(b'BACKUP_RESULT', result.stderr)


if __name__ == '__main__':
    unittest.main()
