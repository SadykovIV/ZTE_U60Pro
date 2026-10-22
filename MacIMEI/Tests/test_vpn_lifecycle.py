"""Execute production lifecycle decisions using isolated services and UCI.

No real process, modem, network interface or VPN credential is accessed.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

VPN = Path(__file__).resolve().parents[1] / 'Resources/VPN'


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vpn-lifecycle-')
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, ROOT_FIXTURE=str(self.root), BACKEND='ikev2')
        (self.root/'configured').touch()
        (self.root/'config.json').write_text('saved-profile')
        (self.root/'active').write_text('saved-profile-id')
        (self.root/'selection').write_text('1')
        (self.root/'ikev2').mkdir()
        self.executable('ikev2.sh', '''
echo "ike-$1" >> "$ROOT_FIXTURE/events"
case "$1" in
 cleanup) rm -f "$ROOT_FIXTURE/ikev2/attempt-issued" "$ROOT_FIXTURE/xfrm";;
 prepare) touch "$ROOT_FIXTURE/xfrm";;
esac
''')
        self.executable('firewall.sh', 'echo firewall >> "$ROOT_FIXTURE/events"; [ "${FAIL:-}" != firewall ]')
        self.executable('vpnctl', 'if [ "$1" = backend ]; then echo "$BACKEND"; fi')
        self.executable('service', '''
echo "service-$1" >> "$ROOT_FIXTURE/events"
if [ "$1" = stop ]; then rm -f "$ROOT_FIXTURE/running"; exit 0; fi
[ "${FAIL:-}" != service ] || exit 1
if /bin/sh "$ROOT_FIXTURE/manager.sh" runtime-wanted; then
 touch "$ROOT_FIXTURE/running"
 if [ "$BACKEND" = ikev2 ] && [ ! -e "$ROOT_FIXTURE/ikev2/attempt-issued" ]; then
  touch "$ROOT_FIXTURE/ikev2/attempt-issued"
  echo push >> "$ROOT_FIXTURE/events"
 fi
fi
''')
        source = (VPN/'manager.sh').read_text().replace('ROOT=/data/zte-vpn', 'ROOT='+shlex.quote(str(self.root)))
        source = source.replace('/etc/init.d/zte_vpn', shlex.quote(str(self.root/'service')))
        overrides = r'''
uci() {
    value=$(cat "$ROOT/selection")
    case "$value:$*" in *:*guest_2g*) printf '%s' "${value%%:*}";; *) printf '%s' "${value##*:}";; esac
}
suspend_guest() { echo aps-down >> "$ROOT/events"; }
lua() {
    echo "uci-$2" >> "$ROOT/events"
    [ "${FAIL:-}" != "uci-$2" ] || return 1
    case "$2" in enable) printf 0 > "$ROOT/selection";; disable) printf 1 > "$ROOT/selection";; esac
}
prepare() {
    echo prepare >> "$ROOT/events"
    [ "${FAIL:-}" != prepare ] || return 1
    touch "$ROOT/configured"
    prepare_backend
}
reload_wifi() { echo reload >> "$ROOT/events"; [ "${FAIL:-}" != reload ]; }
wait_core() { echo wait-core >> "$ROOT/events"; [ "${FAIL:-}" != core ]; }
wait_wifi() { echo wait-wifi >> "$ROOT/events"; [ "${FAIL:-}" != wifi ]; }
sync() { :; }
'''
        source = source.replace('case "${1:-}" in prepare|activate|enable)', overrides+'\ncase "${1:-}" in prepare|activate|enable)')
        self.executable('manager.sh', source, shebang=False)

    def tearDown(self):
        self.temp.cleanup()

    def executable(self, name, body, shebang=True):
        file = self.root/name
        file.write_text(('#!/bin/sh\n' if shebang else '')+body)
        file.chmod(0o700)

    def call(self, action, **env):
        return subprocess.run(['/bin/sh', str(self.root/'manager.sh'), action], env=dict(self.env, **env), capture_output=True, text=True, timeout=5)

    def ok(self, action, **env):
        result = self.call(action, **env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def events(self):
        path = self.root/'events'
        return path.read_text().splitlines() if path.exists() else []

    def assert_stopped(self):
        self.assertFalse((self.root/'running').exists())
        self.assertFalse((self.root/'xfrm').exists())
        self.assertFalse((self.root/'ikev2/attempt-issued').exists())
        self.assertEqual((self.root/'active').read_text(), 'saved-profile-id')
        self.assertEqual((self.root/'config.json').read_text(), 'saved-profile')

    def test_off_on_one_attempt_and_repeat_enable_is_idempotent(self):
        for backend in ['mihomo', 'ikev2']:
            with self.subTest(backend=backend):
                self.ok('disable', BACKEND=backend)
                self.ok('enable', BACKEND=backend)
                first = self.events()
                self.assertTrue((self.root/'running').exists())
                self.ok('enable', BACKEND=backend)
                self.assertEqual(self.events(), first)
                self.ok('disable', BACKEND=backend)
                self.assert_stopped()
                before = self.events().count('push')
                self.ok('enable', BACKEND=backend)
                self.assertEqual(self.events().count('push')-before, int(backend == 'ikev2'))
                self.ok('disable', BACKEND=backend)

    def test_disable_stops_before_failed_reload_and_is_repeatable(self):
        self.ok('enable')
        result = self.call('disable', FAIL='reload')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'selection').read_text(), '1')
        self.assert_stopped()

    def test_enabling_one_disabled_band_keeps_current_attempt(self):
        self.ok('enable')
        before = self.events().count('push')
        (self.root/'selection').write_text('0:1')
        self.ok('enable')
        self.assertEqual((self.root/'selection').read_text(), '0')
        self.assertEqual(self.events().count('push'), before)
        self.assertTrue((self.root/'running').exists())
        self.ok('disable')
        self.assert_stopped()

    def test_failed_off_commit_fences_boot_and_recovery_without_reauthentication(self):
        self.ok('enable')
        result = self.call('disable', FAIL='uci-disable')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'selection').read_text(), '0')
        self.assertTrue((self.root/'runtime-disabled').exists())
        self.assert_stopped()
        starts = self.events().count('service-start')
        self.ok('early')
        self.ok('recover')
        self.assertEqual(self.events().count('service-start'), starts)
        self.assert_stopped()

    def test_every_failed_enable_stage_stops_and_persists_off(self):
        for failure in ['prepare', 'uci-enable', 'service', 'core', 'reload', 'wifi', 'firewall']:
            with self.subTest(failure=failure):
                self.ok('disable')
                result = self.call('enable', FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.root/'selection').read_text(), '1')
                self.assertTrue((self.root/'runtime-disabled').exists())
                self.assert_stopped()

    def test_off_profile_preparation_then_explicit_enable_starts_once(self):
        self.ok('activate')
        self.assert_stopped()
        self.assertNotIn('service-start', self.events())
        self.ok('enable')
        self.assertEqual(self.events().count('push'), 1)

    def test_active_profile_change_reconnects_once_and_followup_enable_does_not(self):
        self.ok('enable')
        self.ok('activate')
        self.ok('enable')
        self.assertEqual(self.events().count('push'), 2)

    def test_off_boot_recovery_and_each_worker_never_start(self):
        for action in ['early', 'recover', 'run-core', 'run-dns', 'run-guard']:
            with self.subTest(action=action):
                self.ok(action)
                self.assertNotIn('prepare', self.events())
                self.assertNotIn('service-start', self.events())
                self.assert_stopped()

    def test_saved_off_profile_rollback_does_not_start(self):
        (self.root/'transaction').mkdir()
        (self.root/'transaction/config.json').write_text('saved-profile')
        (self.root/'transaction/active').write_text('saved-profile-id')
        (self.root/'config.json').write_text('failed-new-profile')
        self.ok('recover')
        self.assert_stopped()
        self.assertFalse((self.root/'transaction').exists())
        self.assertNotIn('service-start', self.events())

    def test_failed_boot_cleans_prepared_backend_and_persists_off(self):
        for failure in ['firewall', 'service']:
            with self.subTest(failure=failure):
                (self.root/'selection').write_text('0')
                (self.root/'runtime-disabled').unlink(missing_ok=True)
                result = self.call('early', FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root/'runtime-disabled').exists())
                self.assertEqual((self.root/'selection').read_text(), '1')
                self.assert_stopped()

    def test_unknown_selection_never_starts_service_instances(self):
        body = (VPN/'service.sh').read_text().replace('ROOT=/data/zte-vpn', 'ROOT='+shlex.quote(str(self.root)))
        shell = body + '\nprocd_open_instance() { echo "$1"; }; procd_set_param() { :; }; procd_close_instance() { :; }; start_service\n'
        for selection, expected in [('1', ''), ('', ''), ('invalid', ''), ('0', 'core\ndns\nguard\n')]:
            (self.root/'selection').write_text(selection)
            result = subprocess.run(['/bin/sh', '-c', shell], env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)


if __name__ == '__main__':
    unittest.main()
