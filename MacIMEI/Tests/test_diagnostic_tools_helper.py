#!/usr/bin/env python3
"""Run the production shell helper in a private fake filesystem; never a modem."""
import hashlib
import gzip
import fcntl
import io
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import uuid

SOURCE = Path(__file__).resolve().parents[1] / 'Resources/DiagnosticTools/manager.sh'
CID = 'a' * 32
BOOT = '2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601'

def sha(data):
    return hashlib.sha256(data).hexdigest()

class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise the production POSIX supervisor on the test host. Linux-only
        # prctl adoption/PDEATHSIG are covered by ARM64 VM QA, not this macOS shim.
        cls.native = tempfile.TemporaryDirectory(prefix='zte-timeout-host-')
        build = Path(cls.native.name)
        arguments = ['cc', '-std=c11', '-O2']
        if sys.platform == 'darwin':
            headers = build / 'include/sys'; headers.mkdir(parents=True)
            (headers / 'prctl.h').write_text('#define PR_SET_CHILD_SUBREAPER 36\n#define PR_SET_PDEATHSIG 1\nstatic inline int prctl(int option, ...) { (void)option; return 0; }\n')
            arguments += ['-I' + str(build / 'include')]
        binary = build / 'zte-timeout'
        subprocess.run(arguments + [str(SOURCE.parents[2] / 'Native/zte_timeout.c'), '-o', str(binary)], check=True, capture_output=True)
        cls.supervisor_bytes = binary.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.native.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='zte-diag-tests-')
        self.fs = Path(self.tmp.name)
        for directory in ['data', 'tmp', 'proc/sys/kernel/random', 'sys/block/mmcblk0/device', 'etc', 'bin']:
            (self.fs / directory).mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.fs / 'proc/sys/kernel/random/boot_id').write_text(BOOT)
        (self.fs / 'sys/block/mmcblk0/device/cid').write_text(CID)
        (self.fs / 'etc/openwrt_release').write_text("DISTRIB_RELEASE='23.05.4'\nDISTRIB_ARCH='aarch64_cortex-a53'\n")
        (self.fs / 'proc/mounts').write_text(f'/dev/fake {self.fs}/data ext4 rw,relatime 0 0\n')
        source = SOURCE.read_text()
        source = re.sub(r'(?<![a-zA-Z0-9_/])/(?:data|proc|sys|tmp|etc/openwrt_release)', lambda m: str(self.fs) + m[0], source)
        source = re.sub(r'(?m)^TIMEOUT_SHA=.*$', 'TIMEOUT_SHA=' + sha(self.supervisor_bytes), source)
        self.helper_stage = self.fs / 'tmp' / ('zte-diag-' + str(uuid.uuid4()))
        self.helper_stage.mkdir(mode=0o700)
        self.script = self.helper_stage / 'manager.sh'
        self.script.write_text(source)
        self.script.chmod(0o600)
        self.supervisor = self.helper_stage / 'zte-timeout'
        self.supervisor.write_bytes(self.supervisor_bytes); self.supervisor.chmod(0o700)
        self.root = self.fs / 'data/zte-imei-apps/diagnostics'
        # Deliberately omit a host timeout executable, reproducing MU5250 B31.
        self.env = dict(os.environ, PATH=str(self.fs / 'bin'))
        for utility in ['awk', 'cat', 'chmod', 'cp', 'cut', 'find', 'gzip', 'grep', 'mkdir', 'mv', 'od', 'readlink', 'rm', 'rmdir', 'sed', 'sha256sum', 'sleep', 'sort', 'sync', 'tar', 'tr', 'wc']:
            executable = shutil.which(utility)
            if not executable: raise RuntimeError('Missing fixture utility: ' + utility)
            (self.fs / 'bin' / utility).symlink_to(executable)
        self.helper('stat', '''import os,stat,sys
s=os.lstat(sys.argv[-1]); field=sys.argv[2]
print({'%u':1 if os.environ.get('FAKE_BAD_OWNER')==sys.argv[-1] else 0,'%a':format(stat.S_IMODE(s.st_mode),'o'),'%h':s.st_nlink,'%s':s.st_size}[field])
''')
        self.helper('id', "print('0')\n")
        self.helper('uname', "import os; print(os.environ.get('FAKE_ARCH','aarch64'))\n")
        self.helper('df', "import os; print('Filesystem 1024-blocks Used Available Capacity Mounted on'); print('fake 999999 1 '+os.environ.get('FAKE_FREE','999999')+' 1% /data')\n")
        self.helper('flock', 'import fcntl,sys; fcntl.flock(int(sys.argv[-1]),fcntl.LOCK_EX|fcntl.LOCK_NB)\n')
        if sys.platform == 'darwin':
            # BSD stat uses another CLI. Keep the fake ownership explicit, and
            # avoid hundreds of Python startups for ordinary metadata reads.
            self.shell_helper('stat', '''case "$2" in
%u) if [ "${FAKE_BAD_OWNER-}" = "$3" ]; then echo 1; else echo 0; fi;;
%a) exec /usr/bin/stat -f '%Lp' "$3";;
%h) exec /usr/bin/stat -f '%l' "$3";;
%s) exec /usr/bin/stat -f '%z' "$3";;
*) exit 93;; esac
''')
        self.shell_helper('id', "echo 0\n")
        self.shell_helper('uname', 'echo "${FAKE_ARCH-aarch64}"\n')
        self.shell_helper('df', 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "fake 999999 1 ${FAKE_FREE-999999} 1% /data"\n')

    def tearDown(self):
        self.tmp.cleanup()

    def helper(self, name, body):
        import sys
        p = self.fs / 'bin' / name
        p.write_text('#!' + sys.executable + '\n' + body)
        p.chmod(0o700)

    def shell_helper(self, name, body):
        p = self.fs / 'bin' / name
        p.write_text('#!/bin/sh\n' + body)
        p.chmod(0o700)

    def bundle(self, version='one', bad_version=False, extra=None, tar_mutator=None):
        stage = self.fs / 'tmp' / ('zte-diag-' + str(uuid.uuid4()))
        stage.mkdir(mode=0o700)
        files = {'VERSION': ('fixture-' + version + '\n').encode(), 'lib/fixture': b'private library fixture'}
        for tool in ['htop', 'iperf3', 'mtr', 'tcpdump', 'mtr-packet']:
            files['bin/' + tool] = (f'#!/bin/sh\n[ "$1" = --version ] || exit 88\nprintf "%s\\n" "{tool} {version}"\nexit {7 if bad_version and tool == "htop" else 0}\n').encode()
        if extra:
            files.update(extra)
        manifest = ''.join(sha(data) + '  ' + path + '\n' for path, data in sorted(files.items())).encode()
        bundle_id = sha(manifest)
        files['FILES.sha256'] = manifest
        archive = stage / 'bundle.tar.gz'
        with tarfile.open(archive, 'w:gz', format=tarfile.USTAR_FORMAT) as tar:
            for path, data in sorted(files.items()):
                info = tarfile.TarInfo(path)
                info.uid = info.gid = 0
                info.mode = 0o700 if path.startswith('bin/') else 0o600
                info.size = len(data)
                if tar_mutator:
                    tar_mutator(tar, info, data)
                else:
                    tar.addfile(info, io.BytesIO(data))
        archive.chmod(0o600)
        return stage, bundle_id, sha(archive.read_bytes())

    def run_helper(self, action, *args, error=None):
        result = subprocess.run(['/bin/sh', str(self.script), action, *map(str, args)], env=self.env, capture_output=True, text=True, timeout=45)
        if error:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('DIAG_ERROR ' + error, result.stderr)
            return result
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], 'ZTE_DIAG_TOOLS_V2')
        return dict(line.split('=', 1) for line in lines[1:])

    def install(self, bundle=None, **kwargs):
        return self.run_helper('install', *(bundle or self.bundle()), CID, BOOT, **kwargs)

    def state(self):
        return (self.root / 'state').read_bytes()

    def test_install_remove_and_repeated_rollback_are_reversible(self):
        one = self.bundle()
        initial = self.run_helper('inspect')
        self.assertEqual(initial, {'active':'none', 'previous':'unset', 'selected':'none', 'previous_selected':'unset', 'running':'0', 'free_kib':'999999'})
        self.assertEqual(self.install(one)['active'], one[1])
        removed = self.run_helper('remove', CID, BOOT)
        self.assertEqual(removed['active'], 'none')
        self.assertEqual(removed['previous'], one[1])
        self.assertTrue((self.root / 'releases' / one[1] / 'bin/htop').exists())
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['active'], one[1])
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['active'], 'none')

    def install_tool(self, tool, bundle=None, **kwargs):
        return self.run_helper('install', *(bundle or self.bundle()), tool, CID, BOOT, **kwargs)

    def test_individual_tools_install_remove_and_rollback_without_touching_other_selection(self):
        one = self.bundle()
        self.assertEqual(self.install_tool('htop', one)['selected'], 'htop')
        status = self.install_tool('iperf3')
        self.assertEqual(status['selected'], 'htop,iperf3')
        self.assertEqual(status['previous_selected'], 'htop')
        removed = self.run_helper('remove', 'htop', CID, BOOT)
        self.assertEqual(removed['active'], one[1])
        self.assertEqual(removed['selected'], 'iperf3')
        self.assertEqual(removed['previous_selected'], 'htop,iperf3')
        # Immutable shared payload is retained as a documented rollback cache.
        self.assertTrue((self.root / 'releases' / one[1] / 'bin/htop').is_file())
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['selected'], 'htop,iperf3')
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['selected'], 'iperf3')
        removed_last = self.run_helper('remove', 'iperf3', CID, BOOT)
        self.assertEqual(removed_last['active'], 'none')
        self.assertEqual(removed_last['selected'], 'none')
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['selected'], 'iperf3')

    def test_v1_inspection_is_read_only_and_first_mutation_migrates_full_set_atomically(self):
        one = self.bundle(); self.install(one)
        state = self.root / 'state'
        legacy = f'active={one[1]}\nprevious=none\n'
        state.write_text(legacy)
        status = self.run_helper('inspect')
        self.assertEqual(status['selected'], 'htop,iperf3,mtr,tcpdump')
        self.assertEqual(state.read_text(), legacy)
        removed = self.run_helper('remove', 'mtr', CID, BOOT)
        self.assertEqual(removed['selected'], 'htop,iperf3,tcpdump')
        self.assertEqual(removed['previous_selected'], 'htop,iperf3,mtr,tcpdump')
        self.assertEqual(len(state.read_text().splitlines()), 4)
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['selected'], 'htop,iperf3,mtr,tcpdump')

    def test_v1_removed_set_recovers_all_four_and_noop_migration_preserves_history(self):
        one = self.bundle(); self.install(one)
        state = self.root / 'state'
        state.write_text(f'active=none\nprevious={one[1]}\n')
        self.assertEqual(self.run_helper('inspect')['previous_selected'], 'htop,iperf3,mtr,tcpdump')
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['selected'], 'htop,iperf3,mtr,tcpdump')
        state.write_text(f'active={one[1]}\nprevious=none\n')
        migrated = self.install_tool('htop')
        self.assertEqual(migrated['previous'], 'none')
        self.assertEqual(migrated['previous_selected'], 'none')
        self.assertEqual(len(state.read_text().splitlines()), 4)

    def test_noncanonical_duplicate_unknown_and_inconsistent_selection_are_refused(self):
        one = self.bundle(); self.install_tool('htop', one)
        state = self.root / 'state'
        for selection in ['htop,htop', 'iperf3,htop', 'htop,unknown', 'none', '', ',htop', 'htop,']:
            state.write_text(f'active={one[1]}\nprevious=none\nselected={selection}\nprevious_selected=none\n')
            self.run_helper('inspect', error='STATE_FORMAT')
        state.write_text('active=none\nprevious=unset\nselected=none\nprevious_selected=none\n')
        self.run_helper('inspect', error='STATE_FORMAT')

    def test_unknown_tool_cannot_install_or_remove(self):
        self.install_tool('../unknown', error='UNKNOWN_TOOL')
        self.run_helper('remove', 'unknown', CID, BOOT, error='UNKNOWN_TOOL')
        self.assertFalse(self.root.exists())

    def test_individual_self_test_does_not_execute_an_unselected_tool(self):
        one = self.bundle(bad_version=True)
        status = self.install_tool('iperf3', one)
        self.assertEqual(status['selected'], 'iperf3')
        old = self.state()
        self.install_tool('htop', self.bundle(bad_version=True), error='SELF_TEST')
        self.assertEqual(self.state(), old)

    def test_individual_upgrade_never_changes_another_tools_shared_runtime(self):
        self.install(); old = self.state()
        self.install_tool('htop', self.bundle('two'), error='SHARED_VERSION_CONFLICT')
        self.assertEqual(self.state(), old)
        self.run_helper('remove', 'all', CID, BOOT)
        self.install_tool('htop')
        self.assertEqual(self.install_tool('htop', self.bundle('two'))['selected'], 'htop')

    def test_upgrade_keeps_previous_and_same_version_does_not_erase_history(self):
        one, two = self.bundle(), self.bundle('two')
        self.install(one); installed = self.install(two)
        self.assertEqual(installed['previous'], one[1])
        self.assertEqual(self.install(self.bundle('two'))['previous'], one[1])
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['active'], one[1])
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['active'], two[1])

    def test_archive_hash_mismatch_has_no_installation_side_effect(self):
        stage, bundle_id, _ = self.bundle()
        self.run_helper('install', stage, bundle_id, 'f'*64, CID, BOOT, error='ARCHIVE_HASH')
        self.assertFalse(self.root.exists())

    def test_shipped_archive_passes_raw_header_validation_without_executing_its_tools(self):
        archive = SOURCE.parent / 'bundle.tar.gz'
        raw = self.fs / 'shipped.tar'; raw.write_bytes(gzip.decompress(archive.read_bytes()))
        source = self.script.read_text()
        function = 'tar_inventory() {' + source.split('tar_inventory() {', 1)[1].split('\ncheck_stage()', 1)[0]
        result = subprocess.run(['/bin/sh', '-c', function + '\ntar_inventory "$1"', 'check', str(raw)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(archive) as tar:
            self.assertEqual(result.stdout.splitlines(), tar.getnames())

    def test_failed_self_test_keeps_old_active(self):
        self.install(); old = self.state()
        self.install(self.bundle('bad', bad_version=True), error='SELF_TEST')
        self.assertEqual(self.state(), old)

    def test_missing_host_timeout_does_not_block_inspect_install_or_rollback(self):
        absent = subprocess.run(['/bin/sh', '-c', 'command -v timeout'], env=self.env, capture_output=True)
        self.assertNotEqual(absent.returncode, 0)
        self.assertEqual(self.run_helper('inspect')['active'], 'none')
        one = self.bundle(); self.install(one)
        self.run_helper('remove', CID, BOOT)
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['active'], one[1])

    def test_inspect_and_remove_do_not_require_a_supervisor(self):
        self.install(); self.supervisor.unlink()
        self.assertNotEqual(self.run_helper('inspect')['active'], 'none')
        self.assertEqual(self.run_helper('remove', CID, BOOT)['active'], 'none')
        # Restoring tools executes a self-test and must require the supervisor.
        old = self.state()
        self.run_helper('rollback', CID, BOOT, error='SUPERVISOR_FILE')
        self.assertEqual(self.state(), old)

    def test_actual_missing_capability_is_named_and_never_changes_state(self):
        self.install(); old = self.state()
        (self.fs / 'bin/od').unlink()
        self.run_helper('inspect', error='CAPABILITY_od')
        self.install(self.bundle('two'), error='CAPABILITY_od')
        self.assertEqual(self.state(), old)

    def test_unverified_or_nonexecutable_supervisor_is_never_run(self):
        self.install(); old = self.state()
        marker = self.fs / 'untrusted-supervisor-ran'
        self.supervisor.write_text('#!/bin/sh\nprintf executed > "' + str(marker) + '"\n')
        self.install(self.bundle('two'), error='SUPERVISOR_HASH')
        self.assertFalse(marker.exists()); self.assertEqual(self.state(), old)
        self.supervisor.write_bytes(self.supervisor_bytes); self.supervisor.chmod(0o600)
        self.install(self.bundle('three'), error='SUPERVISOR_FILE')
        self.assertEqual(self.state(), old)

    def test_supervisor_symlink_hardlink_and_unsafe_permissions_are_refused(self):
        self.install(); old = self.state()
        saved = self.helper_stage / 'original-supervisor'
        self.supervisor.rename(saved); self.supervisor.symlink_to(saved)
        self.install(self.bundle('symlink'), error='SUPERVISOR_FILE')
        self.supervisor.unlink(); saved.rename(self.supervisor)
        self.supervisor.chmod(0o777)
        self.install(self.bundle('permissions'), error='UNSAFE_PERMISSIONS')
        self.supervisor.chmod(0o700)
        os.link(self.supervisor, saved)
        self.install(self.bundle('hardlink'), error='UNSAFE_FILE')
        self.assertEqual(self.state(), old)

    def test_real_deadline_kills_self_test_preserves_state_and_releases_lock(self):
        self.install(); old = self.state()
        pidfile = self.fs / 'timed-self-test.pid'
        script = ('#!/bin/sh\ntrap "" TERM\necho $$ > "' + str(pidfile) + '"\nexec sleep 30\n').encode()
        started = time.monotonic()
        self.install(self.bundle('timeout', extra={'bin/htop': script}), error='SELF_TEST')
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(self.state(), old)
        with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)
        # A timed-out child must not retain the installer's flock descriptor.
        self.assertEqual(self.run_helper('remove', CID, BOOT)['active'], 'none')

    def test_unknown_state_and_extra_lines_are_refused(self):
        self.install()
        for state in ['active=none\nprevious=unset\nextra=x\n', 'active=../evil\nprevious=none\n', 'active=none\nprevious=unset']:
            (self.root / 'state').write_text(state)
            self.run_helper('remove', CID, BOOT, error='STATE_FORMAT')
            self.assertEqual((self.root / 'state').read_text(), state)

    def test_tampered_installed_content_blocks_remove_and_rollback(self):
        one = self.bundle(); self.install(one); old = self.state()
        (self.root / 'releases' / one[1] / 'bin/htop').write_text('#!/bin/sh\nexit 0\n')
        self.run_helper('remove', CID, BOOT, error='CONTENT_HASH')
        self.run_helper('rollback', CID, BOOT, error='CONTENT_HASH')
        self.assertEqual(self.state(), old)

    def test_unknown_extra_file_is_not_accepted(self):
        one = self.bundle(); self.install(one)
        extra = self.root / 'releases' / one[1] / 'extra'
        extra.write_text('unknown'); extra.chmod(0o600)
        self.run_helper('inspect', error='INVENTORY')

    def test_symlink_and_hardlink_archive_entries_are_rejected_before_extract(self):
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE]:
            def mutate(tar, info, data):
                if info.name == 'lib/fixture':
                    info.type = kind; info.linkname = '/etc/passwd'; info.size = 0; tar.addfile(info)
                else: tar.addfile(info, io.BytesIO(data))
            self.install(self.bundle(tar_mutator=mutate), error='ARCHIVE_FORMAT')
        self.assertFalse(self.root.exists())

    def test_traversal_and_duplicate_tar_paths_are_rejected(self):
        for path in ['../escaped', '/absolute', 'bin/../escaped', 'bin//escaped', './alias']:
            self.install(self.bundle(extra={path:b'unsafe'}), error='ARCHIVE_FORMAT')
        def duplicate(tar, info, data):
            tar.addfile(info, io.BytesIO(data))
            if info.name == 'VERSION': tar.addfile(info, io.BytesIO(data))
        self.install(self.bundle(tar_mutator=duplicate), error='ARCHIVE_FORMAT')
        self.assertFalse(self.root.exists())

    def test_changed_bundle_id_cannot_activate_extracted_candidate(self):
        self.install(); old = self.state()
        stage, _, archive_hash = self.bundle('two')
        self.run_helper('install', stage, 'b'*64, archive_hash, CID, BOOT, error='MANIFEST_HASH')
        self.assertEqual(self.state(), old)

    def test_foreign_device_and_reboot_are_refused(self):
        for cid, boot in [('b'*32, BOOT), (CID, str(uuid.uuid4()))]:
            self.run_helper('install', *self.bundle(), cid, boot, error='DEVICE_CHANGED')
        self.assertFalse(self.root.exists())

    def test_self_test_reboot_is_detected_before_commit(self):
        self.install(); old = self.state()
        command = f'#!/bin/sh\nprintf changed > "{self.fs}/proc/sys/kernel/random/boot_id"\nexit 0\n'.encode()
        self.install(self.bundle('reboot', extra={'bin/htop':command}), error='DEVICE_CHANGED')
        self.assertEqual(self.state(), old)

    def test_running_executable_and_mapped_library_block_every_mutation(self):
        one = self.bundle(); self.install(one); old = self.state()
        proc = self.fs / 'proc/123'; proc.mkdir()
        (proc / 'exe').symlink_to(self.root / 'releases' / one[1] / 'bin/htop')
        self.assertEqual(self.run_helper('inspect')['running'], '1')
        self.run_helper('remove', CID, BOOT, error='TOOLS_RUNNING')
        (proc / 'exe').unlink()
        (proc / 'maps').write_text(f'000-fff r-xp 0 00:00 0 {self.root}/releases/{one[1]}/lib/fixture\n')
        self.run_helper('rollback', CID, BOOT, error='TOOLS_RUNNING')
        self.install(self.bundle('two'), error='TOOLS_RUNNING')
        self.assertEqual(self.state(), old)

    def test_wrong_platform_low_space_and_noexec_are_refused(self):
        self.env['FAKE_ARCH'] = 'armv7'
        self.run_helper('inspect', error='UNSUPPORTED_PLATFORM')
        self.install(error='UNSUPPORTED_PLATFORM'); del self.env['FAKE_ARCH']
        self.env['FAKE_FREE'] = '32767'
        self.install(error='FREE_SPACE'); del self.env['FAKE_FREE']
        (self.fs / 'proc/mounts').write_text(f'/dev/fake {self.fs}/data ext4 rw,noexec 0 0\n')
        self.install(error='DATA_NOT_EXECUTABLE')
        self.assertFalse(self.root.exists())

    def test_low_free_space_does_not_block_removal_or_rollback(self):
        one = self.bundle(); self.install(one)
        self.env['FAKE_FREE'] = '1024'
        self.assertEqual(self.run_helper('inspect')['free_kib'], '1024')
        self.assertEqual(self.run_helper('remove', CID, BOOT)['active'], 'none')
        self.assertEqual(self.run_helper('rollback', CID, BOOT)['active'], one[1])

    def test_concurrent_mutation_is_refused_without_state_change(self):
        self.install(); old = self.state()
        with (self.root.parent / '.diagnostics.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_helper('remove', CID, BOOT, error='BUSY')
            self.assertEqual(self.state(), old)
        self.assertEqual(self.run_helper('remove', CID, BOOT)['active'], 'none')

    def test_removing_absent_installation_does_not_create_an_application_directory(self):
        self.run_helper('remove', CID, BOOT, error='NOT_INSTALLED')
        self.assertFalse(self.root.parent.exists())

    def test_foreign_owner_is_refused_before_read_or_write(self):
        self.env['FAKE_BAD_OWNER'] = str(self.fs / 'data')
        self.run_helper('inspect', error='UNSAFE_DIRECTORY')
        self.install(error='UNSAFE_DIRECTORY')
        self.assertFalse(self.root.exists())

    def test_unsafe_parent_state_symlink_and_release_hardlink_are_refused(self):
        (self.fs / 'data').chmod(0o777)
        self.install(error='UNSAFE_PERMISSIONS'); (self.fs / 'data').chmod(0o700)
        one = self.bundle(); self.install(one)
        state = self.root / 'state'; saved = self.fs / 'saved-state'; state.rename(saved); state.symlink_to(saved)
        self.run_helper('inspect', error='UNSAFE_FILE'); state.unlink(); saved.rename(state)
        source = self.root / 'releases' / one[1] / 'VERSION'; os.link(source, self.fs / 'hardlink')
        self.run_helper('inspect', error='UNSAFE_RELEASE')

    def test_interrupted_inactive_candidates_are_not_activated_or_deleted(self):
        one = self.bundle(); self.install(one)
        candidate = self.root / 'releases/.candidate-interrupted'; candidate.mkdir(mode=0o700)
        marker = candidate / 'partial'; marker.write_text('incomplete')
        self.assertEqual(self.run_helper('inspect')['active'], one[1])
        self.run_helper('remove', CID, BOOT)
        self.assertTrue(marker.exists())

if __name__ == '__main__':
    unittest.main()
