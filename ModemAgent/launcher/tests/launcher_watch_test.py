"""Real /bin/sh watcher fixtures with isolated files and fake local ubus; no device."""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "scripts/launcher-watch.sh"
INIT_SHA = "a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35"


class LauncherWatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="launcher-watch-test-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.root = self.base / "data/zte-launcher"
        self.proc = self.base / "proc"
        self.state = self.base / "tmp/zte-launcher"
        self.stock = self.base / "usr/bin/zte_topsw_devui"
        for directory in [self.bin, self.root, self.proc, self.state, self.stock.parent]:
            directory.mkdir(parents=True, exist_ok=True)
        self.stock.write_text("fixture executable identity\n")
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        FIXTURE=str(self.base), STOCK=str(self.stock), SERVICE_PID="29419")
        self.write_tool("ubus", """#!/usr/bin/env python3
import json, os, pathlib, sys
b=pathlib.Path(os.environ['FIXTURE']); args=sys.argv[1:]
if args[:3]==['call','service','list'] and len(args)==4:
 assert json.loads(args[3])=={'name':'zte_topsw_devui'}
 if os.environ.get('UBUS_FAIL')=='1': sys.exit(1)
 pid=os.environ['SERVICE_PID']; instance={'command':[os.environ['STOCK']]}
 if pid!='MISSING': instance['pid']=int(pid) if pid.isdecimal() else pid
 print(json.dumps({'zte_topsw_devui':{'instances':{'instance1':instance}}}))
elif args[:3]==['call','service','set'] and len(args)==4:
 command=json.loads(args[3])['instances']['instance1']['command']
 with (b/'sets').open('a') as f: f.write(json.dumps(command)+'\\n')
 if command[0]=='/bin/sh':
  pid=os.environ['SERVICE_PID']; (b/'proc'/pid/'maps').write_text(str(b/'data/zte-launcher/launcher.so')+'\\n')
  (b/'tmp/zte-launcher/ready').write_text(pid+'\\n')
else: sys.exit(91)
""")
        self.write_tool("jsonfilter", """#!/usr/bin/env python3
import json, os, sys
if os.environ.get('FILTER_FAIL')=='1': sys.exit(1)
assert len(sys.argv)==3 and sys.argv[1]=='-e'
value=json.load(sys.stdin)['zte_topsw_devui']['instances']['instance1']
key=sys.argv[2]
if key=='@.zte_topsw_devui.instances.instance1.pid':
 if 'pid' in value: print(value['pid'])
elif key=='@.zte_topsw_devui.instances.instance1.command[0]': print(value['command'][0])
elif key=='@.zte_topsw_devui.instances.instance1.command[1]': print(value['command'][1])
else: sys.exit(92)
""")
        self.write_tool("pidof", """#!/usr/bin/env python3
import os, pathlib
b=pathlib.Path(os.environ['FIXTURE']); p=b/'pidof_calls'; count=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(count))
print(os.environ['SERVICE_PID'] if count==1 else '29421 29420 29419')
""")
        self.write_tool("sleep", """#!/usr/bin/env python3
import os, pathlib
b=pathlib.Path(os.environ['FIXTURE']); p=b/'sleeps'; n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n))
if n==6: (b/'data/zte-launcher/enabled').unlink()
if n>7: raise SystemExit(93)
""")
        self.write_tool("sha256sum", "#!/bin/sh\nprintf '%s  %s\\n' '" + INIT_SHA + "' \"$1\"\n")
        original = SOURCE.read_text()
        replacements = {"/data/zte-launcher": str(self.root), "/tmp/": str(self.base / "tmp") + "/",
                        "/proc/": str(self.proc) + "/", "/usr/bin/zte_topsw_devui": str(self.stock),
                        "/etc/init.d/zte_topsw_devui": str(self.base / "init")}
        # Only filesystem roots change; the actual selector and loop body run in sh.
        self.script = re.sub("|".join(re.escape(k) for k in replacements),
                             lambda match: replacements[match.group()], original)
        self.function = self.script.split("stock_ui_pid() {", 1)[1].split("\nset_ui() {", 1)[0]
        self.function = "stock_ui_pid() {" + self.function + "\nstock_ui_pid\n"

    def tearDown(self):
        self.tmp.cleanup()

    def write_tool(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o700)

    def process(self, pid="29419", target=None):
        directory = self.proc / pid
        directory.mkdir(exist_ok=True)
        (directory / "exe").symlink_to(self.stock if target is None else target)

    def select(self, **env):
        return subprocess.run(["/bin/sh", "-c", self.function], env=dict(self.env, **env),
                              capture_output=True, text=True, timeout=5)

    def test_service_pid_selected_even_when_child_names_collide(self):
        for pid in ["29419", "29420", "29421"]:
            self.process(pid)
        result = self.select()
        self.assertEqual((result.returncode, result.stdout), (0, "29419\n"))
        self.assertFalse((self.base / "pidof_calls").exists())

    def test_missing_malformed_and_zero_pid_rejected_without_fallback(self):
        self.process()
        for pid in ["MISSING", "", "0", "29419 29420", "-1", "29419\n29420", "../29419"]:
            with self.subTest(pid=pid):
                result = self.select(SERVICE_PID=pid)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertFalse((self.base / "pidof_calls").exists())

    def test_stale_service_pid_with_no_process_rejected(self):
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_reused_pid_with_wrong_executable_rejected(self):
        self.process(target="/bin/sh")
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_ubus_and_jsonfilter_errors_do_not_fall_back(self):
        self.process()
        for overrides in [{"UBUS_FAIL": "1"}, {"FILTER_FAIL": "1"}]:
            with self.subTest(overrides=overrides):
                result = self.select(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertFalse((self.base / "pidof_calls").exists())

    def test_actual_loop_does_not_count_live_brokers_as_start_failures(self):
        for pid in ["29419", "29420", "29421"]:
            self.process(pid)
        (self.root / "enabled").touch()
        (self.proc / "29419/maps").write_text("")
        result = subprocess.run(["/bin/sh", "-c", self.script], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "sleeps").read_text(), "6")
        self.assertFalse((self.root / "failed").exists())
        self.assertFalse((self.base / "pidof_calls").exists())
        commands = [json.loads(line) for line in (self.base / "sets").read_text().splitlines()]
        self.assertEqual(commands, [["/bin/sh", str(self.root / "launcher-run.sh")], [str(self.stock)]])
        self.assertFalse((self.base / "tmp/zte-imei-app.lock").exists())

    def test_old_pidof_negative_control_reproduces_false_start_failure(self):
        for pid in ["29419", "29420", "29421"]:
            self.process(pid)
        (self.root / "enabled").touch()
        (self.proc / "29419/maps").write_text("")
        current = "pid=$(stock_ui_pid || true)"
        self.assertEqual(self.script.count(current), 1)
        previous = self.script.replace(current, "pid=$(pidof zte_topsw_devui 2>/dev/null || true)")
        result = subprocess.run(["/bin/sh", "-c", previous], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "failed").read_text(), "START_FAILED\n")
        self.assertEqual((self.base / "pidof_calls").read_text(), "5")

    def test_shell_syntax(self):
        subprocess.run(["/bin/sh", "-n", str(SOURCE)], check=True)


if __name__ == "__main__":
    unittest.main()
