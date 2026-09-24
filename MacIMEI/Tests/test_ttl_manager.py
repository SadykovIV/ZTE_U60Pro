#!/usr/bin/env python3
"""Full-shell, host-only TTL fixtures. No SSH, real firewall or device access.

Device paths and commands are relocated in temporary copies. The production
eligibility/ownership logic is unchanged; vendor IPA signals and UCI are mocked.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
RESOURCE = REPO / "MacIMEI/Resources/TTL"
CID = "0123456789abcdef0123456789abcdef"
TOKEN = "11111111-2222-3333-4444-555555555555"
FW = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263"
ROUTER = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f"

MOCK = r'''
from pathlib import Path
import copy,hashlib,json,os,shlex,signal,stat,sys
r=Path(os.environ['MOCK_ROOT']);name=sys.argv[1];a=sys.argv[2:]
def event(s):
 with (r/'calls').open('a') as f:f.write(s+'\n')
def fail(s):
 if os.environ.get('MOCK_FAIL')==s and not (r/'failed').exists():
  (r/'failed').write_text(s);return True
 return False
if name=='id':print(0)
elif name=='uname':print('aarch64')
elif name=='flock':
 assert a==['-n','9'],a
 event('flock '+ ' '.join(a))
 if os.environ.get('MOCK_BUSY'):sys.exit(1)
elif name=='sleep':pass
elif name=='sync':
 base=r/'data/zte-imei-ttl';settings=(base/'settings').read_text() if (base/'settings').exists() else ''
 event('sync '+settings.replace('\n',' '))
 if os.environ.get('MOCK_CRASH')=='pending' and (base/'.pending').exists():os.kill(os.getppid(),signal.SIGKILL)
elif name=='stat':
 p=Path(a[-1]);s=p.stat();fmt=a[a.index('-c')+1]
 print(fmt.replace('%u','0').replace('%g','0').replace('%a',oct(stat.S_IMODE(s.st_mode))[2:]))
elif name=='sha256sum':
 for path in a:
  p=Path(path)
  if str(p).endswith('/firmware/image/modem.b16'):h=os.environ.get('MOCK_FW',os.environ['FW'])
  elif str(p).endswith('/usr/bin/diag-router'):h=os.environ['ROUTER']
  elif str(p).endswith('/sbin/ipacm_switch.sh'):h='8947eee9c554453dc8eeb77df933cd12899f447c8c03df3505c57c7b526d22b9'
  elif str(p).endswith('/usr/bin/ipacm'):h='95385816da7b2edb9a977cee328c091753463fcd4a70a67fa1676e8b335c11c0'
  else:
   b=p.read_bytes().replace(str(r).encode(),b'')
   b=b.replace(os.environ['MOCK_PATH_LINE'].encode(),b'export PATH=/usr/sbin:/usr/bin:/sbin:/bin')
   h=hashlib.sha256(b).hexdigest()
  print(h+'  '+path)
elif name=='ip':
 assert a==['-4','route','show','default'],a
 print((r/'routes').read_text(),end='')
elif name=='iptables':
 assert a==['--version'],a
 print('iptables v1.8.8 (legacy)')
elif name=='pidof': print((r/'ipa-pid').read_text().strip()+' 7651')
elif name=='pgrep':
 if os.environ.get('MOCK_UJAIL'):
  if a[-1]=='ipacm':print('7651')
  else:sys.exit(1)
 else:print((r/'ipa-pid').read_text().strip())
elif name=='readlink':
 if a[-1].endswith('/proc/'+(r/'ipa-pid').read_text().strip()+'/exe'):print(str(r)+'/usr/bin/ipacm')
 elif a[-1].endswith('/proc/7651/exe'):print('/sbin/ujail')
 else:sys.exit(1)
elif name in ['ipa-switch','mock-kill']:
 flags=json.loads((r/'ipa-flags').read_text())
 if name=='ipa-switch':
  event('ipa-'+a[0]);flags['close']='1' if a[0]=='off' else '0'
  (r/'ipa-flags').write_text(json.dumps(flags))
 else:
  assert a[-1]==(r/'ipa-pid').read_text().strip(),a
  event('signal '+ ' '.join(a))
elif name=='uci':
 a=[x for x in a if x!='-q']
 if '-c' in a:
  a=a[4:]
  assert a[0]=='get' and a[1].startswith('zte_imei_ttl_persisted_'),a
  value=(r/'ipa-persisted').read_text()
  if value=='absent':sys.exit(1)
  print(value);sys.exit(0)
 if len(a)>1 and a[1].startswith('zwrt_router.'):
  flags=json.loads((r/'ipa-flags').read_text());key='close' if 'close_ipa_acce' in a[1] else 'disabled'
  if a[0]=='get':
   if flags[key]=='absent':sys.exit(1)
   print(flags[key])
  elif a[0]=='set':
   flags[key]=a[1].split('=',1)[1];(r/'ipa-flags').write_text(json.dumps(flags))
   if key=='close':(r/'ipa-pending').write_text("zwrt_router.tmp_router.close_ipa_acce='"+flags[key]+"'\n")
  elif a[0]=='delete':flags[key]='absent';(r/'ipa-flags').write_text(json.dumps(flags))
  elif a[0]=='revert':
   assert key=='close';event('uci-revert-target')
   flags[key]=(r/'ipa-persisted').read_text();(r/'ipa-flags').write_text(json.dumps(flags));(r/'ipa-pending').write_text('')
  else:raise RuntimeError('Unexpected IPA UCI operation')
 elif a==['changes','firewall']:print((r/'pending-uci').read_text(),end='')
 elif a==['changes','zwrt_router']:print((r/'ipa-pending').read_text(),end='')
 elif a[0] in ['get','show']:
  text=(r/'etc/config/firewall').read_text()
  if "config include 'zte_imei_ttl'" not in text:sys.exit(1)
  values={'firewall.zte_imei_ttl':'include','firewall.zte_imei_ttl.path':str(r)+'/data/zte-imei-ttl/firewall.sh','firewall.zte_imei_ttl.type':'script','firewall.zte_imei_ttl.family':'ipv4','firewall.zte_imei_ttl.reload':'1','firewall.zte_imei_ttl.enabled':'1'}
  if a[1] not in values:sys.exit(1)
  if a[0]=='get':print(values[a[1]])
  else:
   for k,v in values.items():print(k+'='+ (v if k=='firewall.zte_imei_ttl' else "'"+v+"'"))
 else:raise RuntimeError('Unexpected UCI mutation: '+repr(a))
elif name=='iptables-save':
 assert a==['-t','mangle'],a
 d=json.loads((r/'rules.json').read_text())
 print('*mangle')
 for c in d['chains']:print(':'+c+' '+('ACCEPT' if c in ['PREROUTING','INPUT','FORWARD','OUTPUT','POSTROUTING'] else '-')+' [0:0]')
 for rule in d['rules']:print(rule)
 print('COMMIT')
elif name=='iptables-restore':
 assert a==['--wait','10','--noflush'],a
 data=sys.stdin.read();event('restore '+data.replace('\n',' | '))
 if fail('restore-before'):sys.exit(1)
 d=copy.deepcopy(json.loads((r/'rules.json').read_text()))
 assert data.count('COMMIT')==1,data
 try:
  for line in data.splitlines():
   if line in ['*mangle','COMMIT']:continue
   x=shlex.split(line);op=x[0];chain=x[1]
   assert chain in ['POSTROUTING','FORWARD','ZTE_IMEI_TTL_OUT','ZTE_IMEI_TTL_IN'],line
   if op=='-D':d['rules'].remove('-A '+line[3:])
   elif op=='-F':
    assert chain.startswith('ZTE_IMEI_TTL_'),line
    d['rules']=[q for q in d['rules'] if shlex.split(q)[1]!=chain]
   elif op=='-X':
    assert chain.startswith('ZTE_IMEI_TTL_'),line
    assert not any(shlex.split(q)[-1]==chain for q in d['rules'])
    d['chains'].remove(chain)
   elif op=='-N':
    assert chain not in d['chains'];d['chains'].append(chain)
   elif op=='-A':
    assert chain in d['chains']
    if '--ttl-set' in x or '--ttl-inc' in x:assert 1<=int(x[-1])<=255
    d['rules'].append(line)
   else:raise RuntimeError(line)
 except (ValueError,AssertionError):sys.exit(1)
 (r/'rules.json').write_text(json.dumps(d))
 if fail('restore-after'):sys.exit(1)
else:raise RuntimeError(name)
'''


class Fixture:
    def __init__(self, acceleration=True):
        self.temp = tempfile.TemporaryDirectory(prefix="zte-ttl-fixture-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        for d in ("data", "etc/config", "etc/hotplug.d/iface", "tmp", "proc/self", "proc/net", "proc/sys/kernel/random", "sys/block/mmcblk0/device", "firmware/image", "usr/bin", "sbin"):
            self.path(d).mkdir(parents=True, exist_ok=True)
            self.path(d).chmod(0o755)
        self.path("etc/rc.local").write_text("#!/bin/sh\n# retain me\nsh /data/existing-agent.sh\nexit 0\n")
        self.path("etc/rc.local").chmod(0o755)
        self.path("etc/config/firewall").write_text("config defaults\n option input 'DROP'\n# preserve firewall\n")
        self.path("sys/block/mmcblk0/device/cid").write_text(CID)
        self.path("proc/net/ip_tables_targets").write_text("MARK\nTTL\n")
        self.path("proc/modules").write_text("" if acceleration else "shortcut_fe 100 1 - Live 0x0\n")
        self.path("proc/sys/kernel/random/boot_id").write_text(TOKEN)
        self.path("ipa-pid").write_text('7658')
        self.path("ipa-flags").write_text(json.dumps({'close':'0','disabled':'absent'}))
        self.path("ipa-persisted").write_text('0')
        self.path("ipa-pending").write_text('')
        self.path("etc/config/zwrt_router").write_text("config tmp_router 'tmp_router'\n option close_ipa_acce '0'\n")
        self.path("usr/bin/ipacm").write_text('fixture')
        self.path("sbin/ipacm_switch.sh").write_text('#!/bin/sh\nexec ipa-switch "$@"\n')
        self.path("proc/self/mountinfo").write_text(f"20 1 8:2 / {self.path('data')} rw,relatime - ext4 /dev/userdata rw\n")
        self.path("routes").write_text("default via 10.0.0.1 dev rmnet_data0 proto static\n")
        self.path("pending-uci").write_text("")
        self.path("rules.json").write_text(json.dumps({"chains": ["PREROUTING", "INPUT", "FORWARD", "OUTPUT", "POSTROUTING", "vendor"], "rules": ["-A PREROUTING -j vendor", "-A vendor -j MARK --set-xmark 0x100/0x100"]}))
        self.baseline = self.rules()
        self.path("calls").write_text("")
        self.stage = self.path(f"tmp/zte-imei-ttl-{TOKEN}")
        self.stage.mkdir(mode=0o700)
        self.path_line = "export PATH=" + str(self.bin) + ":/usr/sbin:/usr/bin:/sbin:/bin"
        self.env = dict(os.environ, MOCK_ROOT=str(self.root), FW=FW, ROUTER=ROUTER, MOCK_PATH_LINE=self.path_line)
        self.env["PATH"] = str(self.bin) + ":" + os.environ.get("PATH", "")
        for p in RESOURCE.glob("*.sh"):
            text = p.read_text()
            text = text.replace('kill -USR1 ', 'mock-kill -USR1 ').replace('kill -USR2 ', 'mock-kill -USR2 ')
            text = re.sub(r"(?<![A-Za-z0-9_])/(?:data|etc|tmp|proc|sys|firmware|usr/bin/diag-router|usr/bin/ipacm|sbin/ipacm_switch.sh)(?=[^A-Za-z0-9_.-]|$)", lambda m: str(self.root) + m.group(), text)
            text = text.replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin", self.path_line)
            (self.stage / p.name).write_text(text)
            (self.stage / p.name).chmod(0o600)
        self.path("mock.py").write_text(MOCK)
        for command in ("id", "uname", "flock", "sleep", "sync", "stat", "sha256sum", "ip", "iptables", "uci", "iptables-save", "iptables-restore", "pidof", "pgrep", "readlink", "ipa-switch", "mock-kill"):
            p = self.bin / command
            p.write_text("#!/bin/sh\nexec " + shlex.quote(shutil.which("python3")) + " " + shlex.quote(str(self.path("mock.py"))) + " " + shlex.quote(command) + ' "$@"\n')
            p.chmod(0o755)

    def path(self, p): return self.root / p
    def rules(self): return json.loads(self.path("rules.json").read_text())
    def close(self): self.temp.cleanup()
    def run(self, command, *args, env=None, success=True):
        script = self.stage / "manager.sh" if command == "install" else self.path("data/zte-imei-ttl/manager.sh")
        if not script.exists(): script = self.stage / "manager.sh"
        a = ["sh", str(script), command] + list(args)
        result = subprocess.run(a, env=dict(self.env, **(env or {})), text=True, capture_output=True, timeout=90)
        if success and result.returncode != 0:
            raise AssertionError(f"{command} failed {result.returncode}\n{result.stdout}\n{result.stderr}")
        if not success and result.returncode == 0:
            raise AssertionError(f"{command} unexpectedly succeeded: {result.stdout}")
        return result
    def install(self, out="64", incoming="1", **kw): return self.run("install", str(self.stage), CID, out, incoming, **kw)
    def status(self):
        output = self.run("status", CID).stdout.strip().splitlines()
        assert len(output) == 1, output
        assert output[0].startswith("TTL_STATUS "), output
        pairs = dict(x.split("=", 1) for x in output[0].split()[1:])
        assert set(pairs) == {"state", "outbound", "inbound_inc", "capability", "verification", "persistence"}, pairs
        return pairs


class TTLManagerTests(unittest.TestCase):
    def setUp(self): self.f = Fixture()
    def tearDown(self): self.f.close()
    def assert_vendor_unchanged(self):
        current = self.f.rules()
        self.assertEqual([c for c in current["chains"] if not c.startswith("ZTE_IMEI_TTL_")], self.f.baseline["chains"])
        self.assertEqual([r for r in current["rules"] if "ZTE_IMEI_TTL_" not in r], self.f.baseline["rules"])
    def test_install_apply_and_disable(self):
        self.f.install()
        self.assertEqual(self.f.status(), dict(state="configured", outbound="64", inbound_inc="1", capability="supported", verification="unverified", persistence="boot"))
        self.f.run("apply", CID, "65", "2")
        self.assertEqual(self.f.status()["inbound_inc"], "2")
        self.f.run("disable", CID)
        self.assertEqual(self.f.status()["state"], "disabled")
        self.assertEqual(self.f.rules(), self.f.baseline)
    def test_independent_directions(self):
        self.f.install("off", "255")
        self.assertFalse(any("--ttl-set" in r for r in self.f.rules()["rules"]))
        self.f.run("apply", CID, "1", "off")
        self.assertFalse(any("--ttl-inc" in r for r in self.f.rules()["rules"]))
        self.assert_vendor_unchanged()
    def test_unsupported_acceleration_guard(self):
        other = Fixture(acceleration=False)
        try:
            result = other.install(success=False)
            self.assertIn("ACCELERATION_UNVERIFIED", result.stderr)
            self.assertFalse(other.path("data/zte-imei-ttl").exists())
            self.assertEqual(other.rules(), other.baseline)
        finally: other.close()
    def test_off_off_install_needs_no_acceleration(self):
        other = Fixture(acceleration=False)
        try:
            other.install("off", "off")
            self.assertEqual(other.status()["state"], "disabled")
        finally: other.close()
    def test_preserves_other_boot_and_firewall_entries(self):
        before_rc = self.f.path("etc/rc.local").read_text()
        before_fw = self.f.path("etc/config/firewall").read_text()
        self.f.install()
        rc = self.f.path("etc/rc.local").read_text()
        stripped = re.sub(r"# BEGIN zte-imei-ttl-v1\n.*?# END zte-imei-ttl-v1\n", "", rc, flags=re.S)
        self.assertEqual(stripped, before_rc)
        self.assertTrue(self.f.path("etc/config/firewall").read_text().startswith(before_fw))
        self.assertEqual(self.f.path("etc/rc.local").stat().st_mode & 0o777, 0o755)
        self.assert_vendor_unchanged()
    def test_reapply_idempotent_and_firewall_rebuild(self):
        self.f.install(); expected = self.f.rules()
        self.f.run("reapply"); self.f.run("reapply")
        self.assertEqual(self.f.rules(), expected)
        self.f.path("rules.json").write_text(json.dumps(self.f.baseline))
        self.assertEqual(self.f.status()["state"], "error")
        self.f.run("reapply")
        self.assertEqual(self.f.rules(), expected)
    def test_vendor_uci_reformat_preserves_hook_validity(self):
        self.f.install()
        p = self.f.path("etc/config/firewall")
        p.write_text("\n".join(line for line in p.read_text().splitlines() if not line.startswith("#")) + "\n")
        self.assertEqual(self.f.status()["state"], "configured")
        self.f.run("reapply")
        self.assertEqual(self.f.status()["state"], "configured")
    def test_default_route_change_does_not_touch_other_pdn(self):
        self.f.install()
        self.f.path("routes").write_text("default via 10.0.0.1 dev rmnet_data2\ndefault dev wlan0\ndefault dev rmnet_data2\n")
        self.assertEqual(self.f.status()["state"], "error")
        self.f.run("reapply")
        self.assertIn("-i rmnet_data2 -o br-lan", "\n".join(self.f.rules()["rules"]))
        self.assertNotIn("rmnet_data0", "\n".join(self.f.rules()["rules"]))
        self.assert_vendor_unchanged()
    def test_route_loss_removes_stale_rules_keeps_desired(self):
        self.f.install(); self.f.path("routes").write_text("")
        self.f.run("reapply", success=False)
        self.assertEqual(self.f.rules(), self.f.baseline)
        self.assertEqual(self.f.status()["outbound"], "64")
        self.f.path("routes").write_text("default dev rmnet_data1\n")
        self.f.run("reapply")
        self.assertEqual(self.f.status()["state"], "configured")
    def test_invalid_input_and_cid_do_not_mutate(self):
        for value in ("0", "256", "-1", "01", "1;reboot", ""):
            self.f.install(value, "1", success=False)
        self.f.run("install", str(self.f.stage), "", "64", "1", success=False)
        self.assertFalse(self.f.path("data/zte-imei-ttl").exists())
        self.assertEqual(self.f.rules(), self.f.baseline)
    def test_failed_atomic_apply_restores_previous_rules(self):
        self.f.install(); before = self.f.rules()
        self.f.run("apply", CID, "65", "2", env={"MOCK_FAIL": "restore-before"}, success=False)
        self.assertEqual(self.f.rules(), before)
        self.assertEqual(self.f.status()["outbound"], "64")
        self.assertEqual(self.f.status()["state"], "error")
        self.f.run("reapply")
        self.assertEqual(self.f.status()["state"], "configured")
    def test_failure_after_commit_restores_previous_rules(self):
        self.f.install(); before = self.f.rules()
        self.f.run("apply", CID, "65", "2", env={"MOCK_FAIL": "restore-after"}, success=False)
        self.assertEqual(self.f.rules(), before)
        self.assert_vendor_unchanged()
    def test_interrupted_update_reapplies_last_committed_settings(self):
        self.f.install(); before = self.f.rules()
        self.f.run("apply", CID, "65", "2", env={"MOCK_CRASH": "pending"}, success=False)
        self.assertTrue(self.f.path("data/zte-imei-ttl/.pending").exists())
        self.f.run("reapply")
        self.assertEqual(self.f.rules(), before)
        self.assertEqual(self.f.status()["state"], "configured")
    def test_failed_disable_stays_durably_disabled(self):
        self.f.install()
        self.f.run("disable", CID, env={"MOCK_FAIL": "restore-before"}, success=False)
        self.assertEqual(self.f.status()["outbound"], "off")
        self.f.run("reapply")
        self.assertEqual(self.f.rules(), self.f.baseline)
    def test_foreign_chain_reference_blocks_mutation(self):
        self.f.install(); rules = self.f.rules()
        rules["rules"].append("-A PREROUTING -j ZTE_IMEI_TTL_OUT")
        self.f.path("rules.json").write_text(json.dumps(rules))
        self.f.run("disable", CID, success=False)
        self.assertEqual(self.f.rules(), rules)
    def test_corrupt_hook_never_runs(self):
        self.f.install(); bad = self.f.path("data/zte-imei-ttl/manager.sh")
        bad.write_text("touch " + str(self.f.path("executed-corrupt")) + "\n")
        result = subprocess.run(["sh", str(self.f.path("data/zte-imei-ttl/boot.sh"))], env=self.f.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.f.path("executed-corrupt").exists())
    def test_pending_uci_rejected_without_committing_it(self):
        self.f.path("pending-uci").write_text("firewall.other.enabled='0'\n")
        self.f.install(success=False)
        self.assertEqual(self.f.rules(), self.f.baseline)
        self.assertEqual(self.f.path("pending-uci").read_text(), "firewall.other.enabled='0'\n")
    def test_lock_busy_and_symlink_refused(self):
        self.f.install(env={"MOCK_BUSY": "1"}, success=False)
        self.assertFalse(self.f.path("data/zte-imei-ttl").exists())
        shutil.rmtree(self.f.path("tmp/zte-imei-ttl-lock"))
        self.f.path("tmp/zte-imei-ttl-lock").symlink_to(self.f.path("routes"))
        self.f.install(success=False)
        self.assertEqual(self.f.path("routes").read_text(), "default via 10.0.0.1 dev rmnet_data0 proto static\n")
    def test_private_lock_rejects_existing_symlink_mutex(self):
        d = self.f.path('tmp/zte-imei-ttl-lock'); d.mkdir(mode=0o700)
        (d/'mutex').symlink_to(self.f.path('routes'))
        self.f.install(success=False)
        self.assertEqual(self.f.path("routes").read_text(), "default via 10.0.0.1 dev rmnet_data0 proto static\n")
    def test_firmware_change_cleans_owned_rules_without_reenable(self):
        self.f.install()
        self.f.run("reapply", env={"MOCK_FW": "0" * 64}, success=False)
        self.assertEqual(self.f.rules(), self.f.baseline)
    def test_partial_install_resumes_on_apply(self):
        self.f.path("pending-uci").write_text("firewall.other.enabled='0'\n")
        self.f.install(success=False)
        self.assertTrue(self.f.path("data/zte-imei-ttl/manager.sh").exists())
        self.f.path("pending-uci").write_text("")
        self.f.run("apply", CID, "64", "1")
        self.assertEqual(self.f.status()["state"], "configured")
    def test_disable_with_missing_hook(self):
        self.f.install(); self.f.path("etc/hotplug.d/iface/99-zte-imei-ttl").unlink()
        self.f.run("apply", CID, "off", "off")
        state = self.f.status()
        self.assertEqual((state["state"], state["persistence"]), ("disabled", "none"))
        self.assertEqual(self.f.rules(), self.f.baseline)
    def test_ipacm_restart_detected_until_reapply(self):
        self.f.install(); self.f.path("ipa-pid").write_text("8000")
        self.assertEqual(self.f.status()["state"], "error")
        self.f.run("reapply")
        self.assertEqual(self.f.status()["state"], "configured")
        self.assertIn("signal -USR1 8000", self.f.path("calls").read_text())
        self.assertNotIn("signal -USR1 7651", self.f.path("calls").read_text())
    def test_boot_id_detected_until_reapply(self):
        self.f.install(); self.f.path("proc/sys/kernel/random/boot_id").write_text("new-boot")
        self.assertEqual(self.f.status()["state"], "error")
        self.f.run("reapply")
        self.assertEqual(self.f.status()["state"], "configured")
    def test_original_software_mode_never_reenabled(self):
        self.f.path("ipa-flags").write_text(json.dumps({'close':'1','disabled':'absent'}))
        self.f.path("ipa-persisted").write_text('1')
        self.f.install(); self.f.run("disable", CID)
        self.assertNotIn("signal -USR2", self.f.path("calls").read_text())
        self.assertEqual(json.loads(self.f.path("ipa-flags").read_text())['close'], '1')
    def test_original_absent_flag_restored_without_pending(self):
        self.f.path("ipa-flags").write_text(json.dumps({'close':'absent','disabled':'absent'}))
        self.f.path("ipa-persisted").write_text('absent')
        self.f.install(); self.f.run("disable", CID)
        self.assertEqual(json.loads(self.f.path("ipa-flags").read_text())['close'], 'absent')
        self.assertEqual(self.f.path("ipa-pending").read_text(), '')
    def test_external_disable_flag_prevents_hardware_enable(self):
        self.f.install()
        self.f.path("ipa-flags").write_text(json.dumps({'close':'1','disabled':'1'}))
        self.f.run("disable", CID)
        self.assertNotIn("signal -USR2", self.f.path("calls").read_text())
        self.assertEqual(json.loads(self.f.path("ipa-flags").read_text())['disabled'], '1')
    def test_original_target_pending_not_reverted(self):
        self.f.path("ipa-pending").write_text("zwrt_router.tmp_router.close_ipa_acce='0'\n")
        self.f.install(); self.f.run("disable", CID)
        self.assertNotIn('uci-revert-target', self.f.path('calls').read_text())
        self.assertEqual(json.loads(self.f.path("ipa-flags").read_text())['close'], '0')
    def test_original_clean_target_reverted_only_itself(self):
        self.f.install(); self.f.run("disable", CID)
        self.assertIn('uci-revert-target', self.f.path('calls').read_text())
        self.assertEqual(self.f.path("ipa-pending").read_text(), '')
    def test_same_named_foreign_empty_chain_refused(self):
        value = self.f.rules(); value['chains'].append('ZTE_IMEI_TTL_OUT')
        self.f.path('rules.json').write_text(json.dumps(value))
        self.f.install(success=False)
        self.assertEqual(self.f.rules(), value)


if __name__ == "__main__": unittest.main(verbosity=2)
