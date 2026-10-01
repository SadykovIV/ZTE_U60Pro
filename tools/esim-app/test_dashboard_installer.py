"""Execute the real dashboard installer against a private filesystem fixture.

Only absolute fixture paths and system adapters are substituted. No modem or
real /data, /etc, /sys paths are accessed, and no production test hook is added.
"""
from pathlib import Path
import hashlib, io, json, os, subprocess, tarfile, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'MacIMEI/Resources/AgentInstallation/dashboard.sh'
CID = '0123456789abcdef0123456789abcdef'
ID = '12345678-1234-1234-1234-123456789abc'
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='zte-dashboard-test-')
        self.root = Path(self.tmp.name).resolve()
        self.runtime = self.root/'data/zte-dashboard-runtime'
        self.id = ID
        for name in ['data/local/tmp', 'data/bin', 'data/www', 'etc', 'sys/block/mmcblk0/device', 'bin']:
            (self.root/name).mkdir(parents=True, exist_ok=True)
        (self.root/'etc/rc.local').write_text('#!/bin/sh\necho original\n')
        (self.root/'data/zte-agent').write_bytes(b'esim-agent')
        (self.root/'sys/block/mmcblk0/device/cid').write_text(CID)
        (self.root/'data/www/index.html').write_text('old-index')
        self.stage = self.root / ('tmp/zte-dashboard-stage-' + ID)
        self.stage.mkdir(parents=True, mode=0o700)
        self.payload = ['dashboard.tar.gz', 'dashboard-uhttpd', 'start-dashboard.sh', 'dashboard-html.sh', 'stop-owned-listener.sh', 'update-rc-local.sh', 'preserve-dashboard-assets.sh']
        for name in self.payload:
            (self.stage/name).write_text('#!/bin/sh\nexit 0\n')
        (self.stage/'start-dashboard.sh').write_text(f'''#!/bin/sh
current=$(readlink "{self.runtime}/current")
case "$current" in "{self.runtime}/dashboards/"*) test ! -e "{self.root}/fail-start" || exit 1;; esac
if [ "$current" = "{self.root}/data/www" ] && [ -e "{self.root}/fail-restored-listener" ]; then exit 0; fi
touch "{self.root}/current-listener"
''')
        (self.stage/'update-rc-local.sh').write_text(f'#!/bin/sh\nprintf updated > "{self.root}/etc/rc.local"\n')
        (self.root/'data/local/tmp/start_dashboard.sh').write_text(f'#!/bin/sh\ntouch "{self.root}/UNSAFE_OLD_HELPER_CALLED"\nexit 90\n')
        (self.stage/'stop-owned-listener.sh').write_text(f'#!/bin/sh\nif [ "${{3:-}}" = --list ]; then\n if [ -e "{self.root}/unstoppable" ] || [ -e "{self.root}/current-listener" ]; then echo 123; fi\nelse\n if [ ! -e "{self.root}/unstoppable" ]; then rm -f "{self.root}/current-listener"; fi\nfi\nexit 0\n')
        with tarfile.open(self.stage/'dashboard.tar.gz', 'w:gz') as tar:
            for name, data in [('index.html', b'<div id="root"></div>new-esim'), ('release.json', b'{"version":"esim"}')]:
                info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o644; tar.addfile(info, io.BytesIO(data))
        self.rehash()
        bindir = self.root/'bin'
        adapters = {
            'id': '#!/bin/sh\necho 0\n', 'uname': '#!/bin/sh\necho aarch64\n', 'sleep': '#!/bin/sh\nexit 0\n',
            'stat': '#!/bin/sh\ncase "$2" in %u) echo 0;; %u:%a) printf "0:"; /usr/bin/stat -f %OLp "$3";; %a) /usr/bin/stat -f %OLp "$3";; *) exit 1;; esac\n',
            'readlink': '#!/usr/bin/env python3\nimport os,sys\np=sys.argv[-1]; print(os.path.realpath(p) if "-f" in sys.argv else os.readlink(p))\n',
            'mv': '#!/usr/bin/env python3\nimport os,sys\na=[v for v in sys.argv[1:] if not v.startswith("-")]; os.replace(*a)\n',
            'curl': f'#!/usr/bin/env python3\nimport pathlib,sys\nr=pathlib.Path({str(self.root)!r})\nif (r/"fail-http").exists():sys.exit(22)\nif "-D" in sys.argv:print("Cache-Control: no-store\\r\\n")\nelse:\n p=r/"data/zte-dashboard-runtime/current" if (r/"data/zte-dashboard-runtime/current").is_symlink() else r/"data/www"\n sys.stdout.buffer.write((p/"index.html").read_bytes())\n',
        }
        for name, text in adapters.items():
            p=bindir/name; p.write_text(text); p.chmod(0o700)
        self.env = {**os.environ, 'PATH': str(bindir)+':'+os.environ['PATH']}
    def rehash(self):
        m=self.stage/'payload.sha256';m.write_text(''.join(digest(self.stage/p)+'  '+p+'\n' for p in self.payload))
        text=SCRIPT.read_text()
        import re
        text=re.sub(r'payload_sha=.*', 'payload_sha='+digest(m), text)
        for prefix in ['/data', '/etc', '/sys', '/tmp/zte-dashboard-stage-']:
            text=text.replace(prefix, str(self.root)+prefix)
        text=text.replace('-C / ', '-C '+str(self.root)+' ').replace('-C /\n', '-C '+str(self.root)+'\n').replace('-C / ||', '-C '+str(self.root)+' ||')
        text=text.replace('"/$file"', '"'+str(self.root)+'/$file"')
        self.script=self.root/'installer.sh';self.script.write_text(text)
    def run_install(self, action="install", expected=None):
        return subprocess.run(['/bin/sh', str(self.script), str(self.stage), CID, expected or digest(self.root/'data/zte-agent'), action], env=self.env, capture_output=True, text=True, timeout=15)
    def tearDown(self):self.tmp.cleanup()
    def test_install_and_preserve_previous_files(self):
        r=self.run_install();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(r.stdout.strip(),'DASHBOARD_INSTALLED '+ID)
        self.assertIn('new-esim',(self.runtime/'current/index.html').read_text())
        self.assertEqual((self.root/'data/www/index.html').read_text(),'old-index')
        self.assertTrue((self.runtime/'installer'/ID/'rc.local').is_file())
        self.assertFalse((self.runtime/'installer/lock').exists())
    def test_shared_tmp1777_accepts_private_stage(self):
        (self.root/'tmp').chmod(0o1777)
        r=self.run_install();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual((self.root/'tmp').stat().st_mode & 0o7777,0o1777)
    def test_writable_data_parent_refuses_before_mutation(self):
        parent=self.root/'data';parent.chmod(0o777)
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.runtime/'installer').exists())
        self.assertEqual(parent.stat().st_mode & 0o777,0o777)
        self.assertIn('original',(self.root/'etc/rc.local').read_text())
    def test_legacy_writable_directories_are_preserved_and_not_executed(self):
        legacy=[self.root/p for p in ['data/local','data/local/tmp','data/bin']]
        for path in legacy:path.chmod(0o777)
        (self.root/'current-listener').touch()
        r=self.run_install();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertTrue(all(path.stat().st_mode & 0o777==0o777 for path in legacy))
        self.assertFalse((self.root/'UNSAFE_OLD_HELPER_CALLED').exists())
        self.assertEqual(self.runtime.stat().st_mode & 0o777,0o700)
    def test_preflight_old_agent_is_read_only_but_apply_requires_current(self):
        expected='a'*64
        r=self.run_install('preflight',expected);self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout.strip(),'DASHBOARD_PREFLIGHT '+ID)
        self.assertFalse(self.runtime.exists())
        r=self.run_install('install',expected);self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.runtime.exists())
        self.assertIn('original',(self.root/'etc/rc.local').read_text())
    def test_unknown_private_runtime_is_refused(self):
        self.runtime.mkdir(mode=0o700)
        r=self.run_install('preflight');self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.runtime/'owner').exists())
        self.assertFalse((self.runtime/'installer').exists())
    def test_symlink_private_runtime_is_refused(self):
        other=self.root/'other';other.mkdir()
        self.runtime.symlink_to(other)
        r=self.run_install('preflight');self.assertNotEqual(r.returncode,0)
        self.assertEqual(list(other.iterdir()),[])
    def next_stage(self):
        next_id='abcdefab-1234-1234-1234-123456789abc'
        moved=self.stage.with_name('zte-dashboard-stage-'+next_id)
        self.stage.rename(moved);self.stage=moved;self.rehash()
        return next_id
    def test_existing_private_runtime_updates_without_legacy_helpers(self):
        self.assertEqual(self.run_install().returncode,0)
        previous=(self.runtime/'current').resolve();next_id=self.next_stage()
        r=self.run_install();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual((self.runtime/'current').resolve(),self.runtime/'dashboards'/next_id)
        self.assertTrue(previous.is_dir())
        self.assertFalse((self.root/'UNSAFE_OLD_HELPER_CALLED').exists())
    def test_existing_private_runtime_rolls_back_original_helpers(self):
        self.assertEqual(self.run_install().returncode,0)
        old_start=f'#!/bin/sh\ntouch "{self.root}/current-listener"\n'
        (self.runtime/'start-dashboard.sh').write_text(old_start)
        previous=(self.runtime/'current').resolve();self.next_stage()
        (self.root/'fail-start').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertIn('DASHBOARD_ROLLBACK_OK',r.stderr)
        self.assertEqual((self.runtime/'current').resolve(),previous)
        self.assertEqual((self.runtime/'start-dashboard.sh').read_text(),old_start)
        self.assertFalse((self.runtime/'installer/lock').exists())
    def test_corrupt_payload_prevents_any_device_write(self):
        (self.stage/'dashboard.tar.gz').write_bytes(b'changed')
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.runtime/'installer').exists())
        self.assertIn('original',(self.root/'etc/rc.local').read_text())
    def test_failed_health_rolls_back_files_and_symlink(self):
        (self.root/'fail-http').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('DASHBOARD_ROLLBACK_OK',r.stderr)
        self.assertFalse((self.runtime/'current').is_symlink())
        self.assertFalse((self.root/'data/bin/dashboard-uhttpd').exists())
        self.assertIn('original',(self.root/'etc/rc.local').read_text())
    def test_failed_start_restores_previous_pointer(self):
        (self.root/'data/www.current').symlink_to(self.root/'data/www')
        (self.root/'fail-start').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual((self.root/'data/www.current').resolve(),self.root/'data/www')
        self.assertIn('original',(self.root/'etc/rc.local').read_text())
    def test_unstoppable_listener_retains_recovery_lock(self):
        (self.root/'unstoppable').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertIn('DASHBOARD_RECOVERY_REQUIRED',r.stderr)
        self.assertTrue((self.runtime/'installer/lock').exists())
    def test_previously_running_listener_is_verified_after_rollback(self):
        (self.root/'current-listener').touch()
        (self.root/'fail-start').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertIn('DASHBOARD_ROLLBACK_OK',r.stderr)
        self.assertFalse((self.root/'UNSAFE_OLD_HELPER_CALLED').exists())
        self.assertEqual((self.runtime/'current').resolve(),self.root/'data/www')
        self.assertTrue((self.root/'current-listener').exists())
        self.assertFalse((self.runtime/'installer/lock').exists())
        self.assertEqual((self.root/'data/www/index.html').read_text(),'old-index')
    def test_async_restored_start_failure_retains_recovery_lock(self):
        (self.root/'current-listener').touch()
        (self.root/'fail-start').touch()
        (self.root/'fail-restored-listener').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertIn('DASHBOARD_RECOVERY_REQUIRED',r.stderr)
        self.assertNotIn('DASHBOARD_ROLLBACK_OK',r.stderr)
        self.assertTrue((self.runtime/'installer/lock').exists())
    def test_restored_listener_http_failure_retains_recovery_lock(self):
        (self.root/'current-listener').touch()
        (self.root/'fail-start').touch()
        (self.root/'fail-http').touch()
        r=self.run_install();self.assertNotEqual(r.returncode,0)
        self.assertIn('DASHBOARD_RECOVERY_REQUIRED',r.stderr)
        self.assertTrue((self.runtime/'installer/lock').exists())

if __name__ == '__main__': unittest.main()
