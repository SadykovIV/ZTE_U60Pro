"""Run the production shell against private files and simulated Linux interfaces.

No test connects to a modem or opens a real block device. Only the block-file
predicate and absolute platform paths are relocated; guard/control logic is real.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
import uuid

SOURCE = Path(__file__).resolve().parents[1] / 'Resources/SystemBackups/device.sh'
CID = '0123456789abcdef0123456789abcdef'
BOOT = '12345678-1234-1234-1234-123456789abc'
TOKEN = 'abcdef12-1234-1234-1234-123456789abc'


class SystemBackupHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='system-backup-helper-')
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.stage = self.base / 'tmp' / ('zte-system-backup-' + str(uuid.uuid4()))
        self.stage.mkdir(parents=True, mode=0o700)
        self.stage.chmod(0o700)
        self.lock = self.base / 'tmp/zte-imei-app.lock'
        self.lock.mkdir(mode=0o700)
        self.put('tmp/zte-imei-app.lock/owner', TOKEN)
        self.put('sys/block/mmcblk0/device/cid', CID)
        self.put('proc/sys/kernel/random/boot_id', BOOT)
        self.put('proc/self/mountinfo', '1 0 0:1 / / rw - tmpfs tmpfs rw\n')
        self.put('proc/swaps', 'Filename Type Size Used Priority\n')
        self.put('proc/meminfo', 'MemAvailable: 262144 kB\n')
        self.put('sys/class/remoteproc/remoteproc0/name', '4080000.remoteproc-modem')
        self.put('sys/class/remoteproc/remoteproc0/state', 'offline')
        self.put('proc/driver/sensor_id', '0\n')
        self.put('proc/driver/codec_id', '0\n')
        self.put('flash-state', 'on')
        for name, sectors, ident in [('mmcblk0', 64, '179:0'), ('mmcblk0boot0', 16, '179:8'), ('mmcblk0boot1', 16, '179:16')]:
            self.put('dev/' + name, b'\0' * (sectors * 512))
            for field, value in [('size', sectors), ('dev', ident), ('queue/logical_block_size', 512), ('queue/physical_block_size', 512)]:
                self.put(f'sys/class/block/{name}/{field}', str(value))
            (self.base / f'sys/class/block/{name}/holders').mkdir()
            if name != 'mmcblk0':
                self.put(f'sys/class/block/{name}/force_ro', '1\n')
        for field, value in [('partition', '1'), ('start', '8'), ('size', '48'), ('dev', '179:1'), ('uevent', 'PARTNAME=fixture\n')]:
            self.put('sys/class/block/mmcblk0p1/' + field, value)
        (self.base / 'sys/class/block/mmcblk0p1/holders').mkdir()
        self.put('firmware/image/modem.b16', b'fixture-firmware')
        self.put('dev/null', '')
        self.command('id', "print('0')")
        self.command('uname', "print('aarch64')")
        self.command('flock', 'pass')
        self.command('sync', 'pass')
        self.command('df', "print('Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 1048576 0 1048576 0% /tmp')")
        self.command('stat', '''
import stat
args=sys.argv[1:]; fmt=args[1]; path=args[2]; s=os.stat(path)
if fmt=='%u:%a': print('0:'+oct(stat.S_IMODE(s.st_mode))[2:])
elif fmt=='%u': print(0)
elif fmt=='%h': print(s.st_nlink)
elif fmt=='%s': print(s.st_size)
elif fmt=='%a': print(oct(stat.S_IMODE(s.st_mode))[2:])
elif fmt=='%t %T':
 name=Path(os.path.realpath(path)).name
 value={'mmcblk0':(179,0),'mmcblk0boot0':(179,8),'mmcblk0boot1':(179,16),'mmcblk0p1':(179,1)}[name]
 if os.environ.get('BAD_DEVICE_NODE'):value=(8,0)
 print('%x %x'%value)
else:sys.exit(1)
''')
        self.command('sha256sum', '''
h=hashlib.sha256()
source=open(sys.argv[1],'rb') if len(sys.argv)>1 else sys.stdin.buffer
while True:
 b=source.read(65536)
 if not b:break
 h.update(b)
print(h.hexdigest()+'  '+(sys.argv[1] if len(sys.argv)>1 else '-'))
''')
        self.command('cat', f'''
p=sys.argv[1] if len(sys.argv)>1 else ''
if p.endswith('/proc/driver/sensor_id'):
 Path({str(self.base / 'flash-state')!r}).write_text('off')
 with open({str(self.base / 'flash-events')!r},'a') as f:f.write('off\\n')
 if os.environ.get('FAIL_UNLOCK'):sys.exit(1)
if p.endswith('/proc/driver/codec_id'):
 with open({str(self.base / 'flash-events')!r},'a') as f:f.write('on\\n')
 if os.environ.get('FAIL_RELOCK'):sys.exit(1)
 Path({str(self.base / 'flash-state')!r}).write_text('on')
os.execv('/bin/cat',['cat',*sys.argv[1:]])
''')
        self.command('dd', f'''
args=dict(arg.split('=',1) for arg in sys.argv[1:] if '=' in arg)
destination=args.get('of','')
if not destination and os.environ.get('FAIL_CAPTURE_READ'):
 sys.stdout.buffer.write(b'partial read')
 sys.exit(3)
if destination.startswith({str(self.base / 'dev')!r}+'/'):
 if Path({str(self.base / 'proc/driver/sensor_id')!r}).exists() and Path({str(self.base / 'flash-state')!r}).read_text()!='off':sys.exit(9)
 if os.environ.get('FAIL_WRITE'):
  with open(destination,'r+b') as f:f.seek(int(args.get('seek','0'))*int(args.get('bs','512')));f.write(b'broken')
  sys.exit(3)
os.execv('/bin/dd',['dd',*sys.argv[1:]])
''')
        script = SOURCE.read_text()
        script = script.replace('[ -b "$node" ]', '[ -f "$node" ]').replace('[ -b "/dev/$1" ]', '[ -f "/dev/$1" ]').replace('[ -b "$fd" ]', '[ -f "$fd" ]')
        script = re.sub(r'(?<![A-Za-z0-9_/])/(tmp|sys|proc|dev|firmware)(?=/|[\s\"\'])', lambda m: str(self.base) + m.group(0), script)
        script = script.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C', 'export PATH=' + shlex.quote(str(self.bin) + ':/usr/bin:/bin') + ' LC_ALL=C')
        script = script.replace('604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263', hashlib.sha256(b'fixture-firmware').hexdigest())
        self.script = self.stage / 'device.sh'
        self.script.write_text(script)
        self.script.chmod(0o600)

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, data):
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode() if isinstance(data, str) else data)
        path.chmod(0o600)
        return path

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\nimport os,sys,hashlib\nfrom pathlib import Path\n' + body + '\n')
        path.chmod(0o700)

    def call(self, mode, *args, cid=CID, **env):
        return subprocess.run(['/bin/sh', str(self.script), mode, cid, TOKEN, *map(str, args)], env={**os.environ, **env}, capture_output=True, timeout=25)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    def inventory(self):
        return json.loads(self.ok(self.call('inventory')))

    def chunk(self, data=b'x' * 1024, target='mmcblk0', offset=0, **env):
        info = self.inventory()
        path = self.put(str(self.stage.relative_to(self.base)) + '/chunk.bin', data)
        digest = hashlib.sha256(data).hexdigest()
        return self.call('restore-chunk', BOOT, info['layoutHash'], target, offset, len(data), digest, path, **env)

    def test_inventory_has_complete_geometry_and_bootstrap(self):
        info = json.loads(self.ok(self.call('inventory', cid='-')))
        self.assertTrue(info['offline'])
        self.assertEqual(info['cid'], CID)
        self.assertEqual(info['diskBytes'], 32768)
        self.assertEqual([d['name'] for d in info['devices']], ['mmcblk0', 'mmcblk0boot0', 'mmcblk0boot1'])
        self.assertEqual(info['partitions'][0]['startSector'], 8)

    def test_capture_stream_receipt_and_full_hash(self):
        data = self.ok(self.call('capture', 'mmcblk0'))
        self.assertEqual(data, (self.base / 'dev/mmcblk0').read_bytes())
        result = self.call('capture', 'mmcblk0boot0')
        self.ok(result)
        self.assertIn(b'BACKUP_RESULT sha256=', result.stderr)
        info = self.inventory()
        result = self.call('hash-device', BOOT, info['layoutHash'], 'mmcblk0')
        self.assertIn(hashlib.sha256(data).hexdigest().encode(), self.ok(result))

    def test_capture_does_not_depend_on_embedded_wc_byte_counter(self):
        # Some embedded wc configurations have narrow counters. The host has
        # the authoritative 64-bit file length and must verify the declared
        # geometry plus this stream hash before publishing anything.
        marker = self.base / 'wc-called'
        self.command('wc', f"Path({str(marker)!r}).write_text('called'); sys.stdin.buffer.read(); print('7')")
        result = self.call('capture', 'mmcblk0')
        data = self.ok(result)
        self.assertFalse(marker.exists())
        self.assertEqual(data, (self.base / 'dev/mmcblk0').read_bytes())
        expected = f'BACKUP_RESULT sha256={hashlib.sha256(data).hexdigest()} bytes={len(data)}\n'
        self.assertIn(expected.encode(), result.stderr)

    def test_capture_read_failure_never_returns_success_receipt(self):
        result = self.call('capture', 'mmcblk0', FAIL_CAPTURE_READ='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'BACKUP_ERROR READ', result.stderr)
        self.assertNotIn(b'BACKUP_RESULT', result.stderr)
        self.assertFalse((self.base / 'flash-events').exists())

    def test_restore_writes_bounded_chunk_relocks_and_reads_back(self):
        self.ok(self.chunk(offset=1024))
        data = (self.base / 'dev/mmcblk0').read_bytes()
        self.assertEqual(data[:1024], b'\0' * 1024)
        self.assertEqual(data[1024:2048], b'x' * 1024)
        self.assertEqual(data[2048:], b'\0' * (32768 - 2048))
        self.assertEqual((self.base / 'flash-state').read_text(), 'on')
        self.assertTrue((self.stage / 'restore-journal.tsv').read_text().endswith('complete\n'))
        self.assertFalse((self.stage / 'work/readback.bin').exists())

    def test_boot_force_ro_restored_after_success_and_failure(self):
        self.ok(self.chunk(target='mmcblk0boot0'))
        force = self.base / 'sys/class/block/mmcblk0boot0/force_ro'
        self.assertEqual(force.read_text().strip(), '1')
        result = self.chunk(target='mmcblk0boot0', FAIL_WRITE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(force.read_text().strip(), '1')
        self.assertEqual((self.base / 'flash-state').read_text(), 'on')

    def test_mount_alias_root_and_remoteproc_guards_refuse(self):
        info = self.inventory()
        checks = [('proc/self/mountinfo', '1 0 179:0 / / rw - ext4 /dev/root rw\n', 'ROOT_NOT_RAM'),
                  ('proc/self/mountinfo', '1 0 0:1 / / rw - tmpfs tmpfs rw\n2 1 179:1 / /alias ro - ext4 /dev/root ro\n', 'EMMC_MOUNTED'),
                  ('sys/class/remoteproc/remoteproc0/state', 'running', 'BASEBAND_ONLINE')]
        for path, content, reason in checks:
            with self.subTest(reason=reason):
                original = (self.base / path).read_bytes()
                self.put(path, content)
                result = self.call('preflight', BOOT, info['layoutHash'])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason.encode(), result.stderr)
                self.put(path, original)
        self.assertFalse((self.base / 'flash-events').exists())

    def test_unproven_baseband_writer_and_node_identity_refuse(self):
        state = self.base / 'sys/class/remoteproc/remoteproc0/name'
        state.write_text('unknown')
        self.assertEqual(self.inventory()['offlineReason'], 'BASEBAND_UNKNOWN')
        state.write_text('modem')
        self.put('proc/123/comm', 'rmt_storage\n')
        self.assertEqual(self.inventory()['offlineReason'], 'STORAGE_WRITER_ACTIVE')
        result = self.call('inventory', BAD_DEVICE_NODE='1')
        self.assertIn(b'BLOCK_IDENTITY', result.stderr)

    def test_invalid_chunk_hash_truncation_alignment_and_range_before_unlock(self):
        info = self.inventory()
        path = self.put(str(self.stage.relative_to(self.base)) + '/chunk.bin', b'a' * 1024)
        digest = hashlib.sha256(b'a' * 1024).hexdigest()
        for offset, length, sha in [(0, 1024, '0' * 64), (0, 2048, digest), (1, 1024, digest), (32768, 1024, digest), (0, 8389120, digest)]:
            result = self.call('restore-chunk', BOOT, info['layoutHash'], 'mmcblk0', offset, length, sha, path)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'flash-events').exists())
        self.assertEqual((self.base / 'dev/mmcblk0').read_bytes(), b'\0' * 32768)

    def test_unlock_partial_failure_still_relocks(self):
        result = self.chunk(FAIL_UNLOCK='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.base / 'flash-events').read_text().splitlines(), ['off', 'on'])
        self.assertEqual((self.base / 'flash-state').read_text(), 'on')

    def test_relock_failure_is_failure_even_when_bytes_match(self):
        result = self.chunk(FAIL_RELOCK='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'RESTORE_RESULT', result.stdout)
        self.assertIn(b'RELOCK_FAILED', result.stderr)
        self.assertTrue((self.stage / 'restore-journal.tsv').read_text().endswith('relock-failed\n'))
        self.ok(self.call('relock'))
        self.assertEqual((self.base / 'flash-state').read_text(), 'on')

    def test_ambiguous_journal_only_retries_exact_chunk_and_hash_reconciles(self):
        result = self.chunk(FAIL_WRITE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'JOURNAL_PENDING', self.chunk(offset=1024).stderr)
        self.ok(self.chunk())
        journal = self.stage / 'restore-journal.tsv'
        journal.write_text(journal.read_text().replace('complete\n', 'writing\n'))
        info = self.inventory()
        self.ok(self.call('hash-chunk', BOOT, info['layoutHash'], 'mmcblk0', 0, 1024))
        self.assertTrue(journal.read_text().endswith('verified\n'))
        self.ok(self.chunk(offset=1024))

    def test_generic_recovery_without_vendor_pair_is_supported(self):
        (self.base / 'proc/driver/sensor_id').unlink()
        (self.base / 'proc/driver/codec_id').unlink()
        self.ok(self.chunk())
        self.assertFalse((self.base / 'flash-events').exists())

    def test_incomplete_vendor_pair_memory_and_lock_refuse(self):
        (self.base / 'proc/driver/codec_id').unlink()
        self.assertEqual(self.inventory()['offlineReason'], 'FLASH_INTERFACE_INCOMPLETE')
        self.put('proc/driver/codec_id', '0')
        self.put('proc/meminfo', 'MemAvailable: 1000 kB\n')
        self.assertIn(b'RAM_INSUFFICIENT', self.chunk().stderr)
        (self.lock / 'owner').write_text('different')
        self.assertIn(b'GLOBAL_LOCK', self.call('inventory').stderr)

    def test_holders_swap_raw_fds_and_mounted_restore_refuse(self):
        holder = self.base / 'sys/class/block/mmcblk0p1/holders/mapper'
        holder.symlink_to('missing')
        self.assertEqual(self.inventory()['offlineReason'], 'BLOCK_HOLDER')
        holder.unlink()
        self.put('proc/swaps', 'Filename Type Size Used Priority\n/dev/alias partition 10 0 -1\n')
        self.assertEqual(self.inventory()['offlineReason'], 'SWAP_ACTIVE')
        self.put('proc/swaps', 'Filename Type Size Used Priority\n')
        fd = self.base / 'proc/123/fd/4'
        fd.parent.mkdir(parents=True)
        fd.symlink_to(self.base / 'dev/mmcblk0')
        self.assertEqual(self.inventory()['offlineReason'], 'RAW_DEVICE_OPEN')
        fd.unlink()
        self.put('proc/self/mountinfo', '1 0 0:1 / / rw - tmpfs tmpfs rw\n2 1 179:1 / /data rw - ext4 /dev/by-name/alias rw\n')
        result = self.chunk()
        self.assertIn(b'EMMC_MOUNTED', result.stderr)
        self.assertFalse((self.base / 'flash-events').exists())

    def test_linked_chunk_refused_and_zero_force_ro_preserved(self):
        info = self.inventory()
        path = self.put(str(self.stage.relative_to(self.base)) + '/chunk.bin', b'z' * 512)
        linked = self.stage / 'another.bin'
        os.link(path, linked)
        result = self.call('restore-chunk', BOOT, info['layoutHash'], 'mmcblk0', 0, 512, hashlib.sha256(b'z' * 512).hexdigest(), path)
        self.assertIn(b'CHUNK_FILE', result.stderr)
        linked.unlink()
        self.put('sys/class/block/mmcblk0boot1/force_ro', '0\n')
        self.ok(self.chunk(target='mmcblk0boot1'))
        self.assertEqual((self.base / 'sys/class/block/mmcblk0boot1/force_ro').read_text().strip(), '0')


if __name__ == '__main__':
    unittest.main()
