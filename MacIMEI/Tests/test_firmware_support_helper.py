#!/usr/bin/env python3
"""Execute the actual support helper in an isolated, mechanically remapped namespace.

Only fixed path prefixes and PATH change; shell control flow is the product's.
The stat shim projects Linux ownership and uses fstat(9) for /proc/self/fd/9:
Darwin's /dev/fd stat describes its fdesc mount, unlike Linux procfs. No modem,
host /data, real process environment or HTTP is used.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "MacIMEI/Resources/FirmwareSupport/collect.sh"
REQUIRED = {
    "ui": "/usr/bin/zte_topsw_devui", "english": "/usr/ui/language/English.ini",
    "chinese": "/usr/ui/language/Chinese.ini", "init": "/etc/init.d/zte_topsw_devui",
}
OPTIONAL = {
    "original_ui": "/data/zte-imei-screen-ru/backup/zte_topsw_devui",
    "original_english": "/data/zte-imei-screen-ru/backup/English.ini",
    "original_chinese": "/data/zte-imei-screen-ru/backup/Chinese.ini",
    "original_init": "/data/zte-imei-screen-ru/backup/zte_topsw_devui.init",
}
FONTS = {
    "font_zhengyuan": "/usr/ui/fonts/ZTEZhengYuan.ttf",
    "font_roboto": "/usr/ui/fonts/Roboto.ttf",
    "font_oswald": "/usr/ui/fonts/Zoswald-Medium-24.ttf",
}
FACTS = set("uid os architecture firmware inner openwrt_version target agent_present agent_sha256 agent_running_count agent_mode agent_mapped_matches_disk http_health_status http_capabilities_status http_dashboard_status ui_mounts".split())
CANARY = "PRIVATE_PASSWORD_CANARY_NEVER_EXPORT"
SHIM = r'''#!__PYTHON__
import hashlib,json,os,stat,sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
settings=json.loads((root/'settings.json').read_text())
tool=Path(sys.argv[0]).name; args=sys.argv[1:]
if tool=='stat':
 fmt=args[1]; raw=args[2]; p=Path(raw)
 if raw==str(root/'proc/self/fd/9'):
  p=Path('/dev/fd/9')
  marker=root/'mutated'
  if settings.get('replace_after_open') and not marker.exists():
   target=root/settings['replace_after_open'].lstrip('/')
   old=target.read_bytes(); target.rename(target.with_name(target.name+'.old'))
   target.write_bytes(old);marker.touch()
 st=os.fstat(9) if raw==str(root/'proc/self/fd/9') else (p.stat() if args[0].startswith('-L') else p.lstat())
 uid=settings.get('uids',{}).get(raw.removeprefix(str(root)),0)
 values={'u':uid,'g':0,'a':format(stat.S_IMODE(st.st_mode),'o'),'h':st.st_nlink,'s':st.st_size,'d':st.st_dev,'i':st.st_ino}
 for k,v in values.items():fmt=fmt.replace('%'+k,str(v))
 print(fmt)
elif tool=='sha256sum':
 raw=args[-1]
 if settings.get('hash_failure')==raw.removeprefix(str(root)):sys.exit(1)
 print(hashlib.sha256(Path(raw).read_bytes()).hexdigest()+'  '+raw)
elif tool=='id':print(settings.get('uid','0'))
elif tool=='uname':print('Linux' if args==['-s'] else 'aarch64')
elif tool=='pidof':
 print(' '.join(str(x) for x in settings.get('pids',[])))
elif tool=='ubus':
 print(json.dumps({'integrate_version':'FLY_CN_MU5250V1.0.0B13','wa_inner_version':'BD_FLYMODEMMU5250V1.0.0B28','password':'PRIVATE_PASSWORD_CANARY_NEVER_EXPORT'}))
 sys.exit(settings.get('ubus_exit',0))
elif tool=='jsonfilter':
 try:
  data=json.load(sys.stdin);value=data.get(args[1].removeprefix('@.'))
  if value is not None:print(value)
 except Exception:sys.exit(1)
elif tool=='curl':
 if not args or args[0]!='-q':(root/'unexpected-curl-config-effect').touch()
 print(settings.get('http_status','401'),end='')
 sys.exit(settings.get('curl_exit',0))
else:sys.exit(127)
'''


class Fixture:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="support-shell-", dir=RUN_ROOT)).resolve()
        self.settings = {}
        self.bin = self.root / "fixture-bin"
        self.bin.mkdir()
        shim = SHIM.replace("__PYTHON__", sys.executable)
        for name in ["stat", "sha256sum", "id", "uname", "pidof", "ubus", "jsonfilter", "curl"]:
            path = self.bin / name
            path.write_text(shim)
            path.chmod(0o755)
        for name, path in REQUIRED.items():
            self.put(path, b"\x7fELF\x00fixture\r\n\xff\x00\n" if name == "ui" else (name + "=fixture\r\n").encode())
        self.put("/etc/openwrt_release", b"DISTRIB_RELEASE='23.05.4'\nDISTRIB_TARGET='qualcommax/ipq807x'\n")
        self.put("/proc/self/mountinfo", b"1 2 3:4 / /none rw - tmpfs tmpfs rw\n")
        self.put("/data/zte-agent", b"synthetic agent")
        text = SOURCE.read_text()
        prefixes = r"/usr/bin/zte_topsw_devui|/usr/ui|/etc|/data|/proc"
        text = re.sub(prefixes, lambda m: str(self.root) + m.group(0), text)
        old = "export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C"
        assert text.count(old) == 1
        text = text.replace(old, "export PATH='" + str(self.bin) + ":/usr/bin:/bin' LC_ALL=C")
        self.helper = self.root / "collect.sh"
        self.helper.write_text(text)
        self.save()

    def path(self, path):
        return self.root / path.lstrip("/")

    def put(self, path, data, mode=0o644):
        p = self.path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        p.chmod(mode)
        return p

    def save(self):
        (self.root / "settings.json").write_text(json.dumps(self.settings))

    def run(self, *args):
        self.save()
        return subprocess.run(["/bin/sh", str(self.helper), *args], capture_output=True, timeout=15,
                              env={"PATH": "/usr/bin:/bin", "HOME": str(self.root), "LC_ALL": "C"})

    def inspect(self):
        result = self.run("inspect", "192.0.2.1")
        if result.returncode:
            raise AssertionError((result.returncode, result.stderr.decode(errors="replace")))
        lines = result.stdout.decode().splitlines()
        assert lines[0] == "FIRMWARE_SUPPORT_V1" and lines[-1] == "FIRMWARE_SUPPORT_END"
        facts, files = {}, {}
        for line in lines[1:-1]:
            parts = line.split("\t")
            if parts[0] == "FACT":
                assert len(parts) == 3 and parts[1] not in facts
                facts[parts[1]] = base64.b64decode(parts[2], validate=True).decode()
            else:
                assert len(parts) == 8 and parts[0] == "FILE" and parts[1] not in files
                files[parts[1]] = parts[2:]
        assert set(facts) == FACTS and set(files) == REQUIRED.keys() | OPTIONAL.keys() | FONTS.keys()
        assert result.stderr == b""
        return facts, files

    def originals(self):
        for path in OPTIONAL.values():
            self.put(path, b"original fixture\x00\r\n", 0o666)
        self.path("/data/zte-imei-screen-ru").chmod(0o700)
        self.path("/data/zte-imei-screen-ru/backup").chmod(0o700)
        self.put("/data/zte-imei-screen-ru/owner", b"zte-imei-screen-ru-v1", 0o600)

    def process(self, modes, pid=101):
        self.settings.setdefault("pids", []).append(pid)
        self.put(f"/proc/{pid}/environ", ("ZTE_AGENT_PASSWORD=" + CANARY + "\0OTHER_PRIVATE=" + CANARY + "\0" + "".join("ZTE_AGENT_MODE="+x+"\0" for x in modes)).encode())
        (self.path(f"/proc/{pid}") / "exe").symlink_to(self.path("/data/zte-agent"))

    def stream(self, name="ui", size=None, digest=None):
        data = self.path((REQUIRED | OPTIONAL | FONTS)[name]).read_bytes()
        return self.run("file", name, str(len(data) if size is None else size), digest or hashlib.sha256(data).hexdigest())


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()

    def test_protocol_exact_fixed_inventory(self):
        facts, files = self.fx.inspect()
        self.assertEqual(len(facts), 16)
        self.assertTrue(all(files[x][0] == "present" for x in REQUIRED))
        self.assertTrue(all(files[x][0] == "missing" for x in OPTIONAL))

    def test_full_firmware_inner_and_openwrt(self):
        facts, _ = self.fx.inspect()
        self.assertEqual(facts["firmware"], "FLY_CN_MU5250V1.0.0B13")
        self.assertEqual(facts["inner"], "BD_FLYMODEMMU5250V1.0.0B28")
        self.assertEqual(facts["openwrt_version"], "23.05.4")

    def test_optional_font_bytes_and_receipt(self):
        for name, path in FONTS.items():
            with self.subTest(font=name):
                data = b"\x00\x01\x00\x00font\r\n\xff"
                self.fx.put(path, data)
                self.assertEqual(self.fx.inspect()[1][name][0], "present")
                result = self.fx.stream(name)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, data)
                self.assertIn(hashlib.sha256(data).hexdigest().encode(), result.stderr)

    def test_missing_font_is_explicit(self):
        self.fx.path("/usr/ui/fonts").mkdir()
        self.assertTrue(all(self.fx.inspect()[1][name][0] == "missing" for name in FONTS))

    def test_font_symlink_does_not_capture_private_target(self):
        path = self.fx.put(FONTS["font_roboto"], b"font"); path.unlink()
        path.symlink_to(self.fx.put("/data/private-font-target", CANARY.encode()))
        self.assertEqual(self.fx.inspect()[1]["font_roboto"][0], "symlink")
        result = self.fx.run("file", "font_roboto", str(len(CANARY)), hashlib.sha256(CANARY.encode()).hexdigest())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(CANARY.encode(), result.stdout + result.stderr)

    def test_byte_preservation_nul_crlf_binary(self):
        result = self.fx.stream()
        data = self.fx.path(REQUIRED["ui"]).read_bytes()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, data)
        self.assertEqual(result.stderr, f"BACKUP_RESULT sha256={hashlib.sha256(data).hexdigest()} bytes={len(data)}\n".encode())

    def test_wrong_expected_size_no_stream(self):
        result = self.fx.stream(size=123)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"BACKUP_RESULT", result.stderr)

    def test_wrong_expected_hash_never_receipt(self):
        result = self.fx.stream(digest="0"*64)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"BACKUP_RESULT", result.stderr)

    def test_replaced_path_after_open_never_receipt(self):
        self.fx.settings["replace_after_open"] = REQUIRED["ui"]
        result = self.fx.stream()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"CAPTURE_ERROR FILE_CHANGED", result.stderr)
        self.assertNotIn(b"BACKUP_RESULT", result.stderr)

    def test_empty_is_not_present(self):
        self.fx.put(REQUIRED["english"], b"")
        self.assertEqual(self.fx.inspect()[1]["english"][0], "empty")

    def test_missing_required_is_partial_metadata(self):
        self.fx.path(REQUIRED["chinese"]).unlink()
        self.assertEqual(self.fx.inspect()[1]["chinese"][0], "missing")

    def test_file_symlink_not_read(self):
        p = self.fx.path(REQUIRED["ui"]); p.unlink()
        p.symlink_to(self.fx.put("/data/private", CANARY.encode()))
        self.assertEqual(self.fx.inspect()[1]["ui"][0], "symlink")
        result = self.fx.run("file", "ui", str(len(CANARY)), hashlib.sha256(CANARY.encode()).hexdigest())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(CANARY.encode(), result.stdout + result.stderr)

    def test_parent_symlink_not_followed(self):
        parent = self.fx.path("/usr/ui/language")
        parent.rename(parent.with_name("actual")); parent.symlink_to(parent.with_name("actual"))
        self.assertEqual(self.fx.inspect()[1]["english"][0], "symlink")

    def test_nonregular_not_read(self):
        p=self.fx.path(REQUIRED["ui"]);p.unlink();p.mkdir()
        self.assertEqual(self.fx.inspect()[1]["ui"][0], "not_regular")

    def test_oem_775_666_readable_and_preserved(self):
        self.fx.path(REQUIRED["init"]).chmod(0o775)
        self.fx.path(REQUIRED["english"]).chmod(0o666)
        _, files = self.fx.inspect()
        self.assertEqual(files["init"][4], "775")
        self.assertEqual(files["english"][4], "666")
        for name in ["init", "english"]:
            self.assertEqual(self.fx.stream(name).returncode, 0)

    def test_owned_originals_666_inside_private_directory(self):
        self.fx.originals()
        self.assertTrue(all(self.fx.inspect()[1][x][0] == "present" for x in OPTIONAL))
        self.assertEqual(self.fx.stream("original_ui").returncode, 0)

    def test_wrong_original_owner_marker(self):
        self.fx.originals(); self.fx.put("/data/zte-imei-screen-ru/owner", b"foreign")
        self.assertTrue(all(self.fx.inspect()[1][x][0] == "missing" for x in OPTIONAL))

    def test_original_parent_nonroot(self):
        self.fx.originals();self.fx.settings["uids"]={"/data/zte-imei-screen-ru":1234}
        self.assertEqual(self.fx.inspect()[1]["original_ui"][0], "missing")

    def test_original_backup_777_refused(self):
        self.fx.originals();self.fx.path("/data/zte-imei-screen-ru/backup").chmod(0o777)
        self.assertEqual(self.fx.inspect()[1]["original_ui"][0], "missing")

    def test_original_owner_hardlink_refused(self):
        self.fx.originals();os.link(self.fx.path("/data/zte-imei-screen-ru/owner"),self.fx.root/"owner-copy")
        self.assertEqual(self.fx.inspect()[1]["original_ui"][0], "missing")

    def test_mode_projection_no_password_or_unknown_values(self):
        for modes, expected in [(["normal"],"normal"),(["discovery"],"discovery"),([],"default"),([CANARY],"unknown"),(["normal","discovery"],"ambiguous")]:
            with self.subTest(expected=expected):
                fx=Fixture();fx.process(modes)
                facts,_=fx.inspect()
                self.assertEqual(facts["agent_mode"],expected)
                self.assertNotIn(CANARY,json.dumps(facts))
                self.assertEqual(facts["agent_mapped_matches_disk"],"yes")

    def test_multiple_owned_processes_ambiguous(self):
        self.fx.process(["normal"],101);self.fx.process(["discovery"],102)
        facts,_=self.fx.inspect()
        self.assertEqual(facts["agent_running_count"],"2")
        self.assertEqual(facts["agent_mode"],"ambiguous")

    def test_http401_is_status_only(self):
        facts,_=self.fx.inspect()
        for name in ["health","capabilities","dashboard"]:
            self.assertEqual(facts["http_"+name+"_status"],"401")
        self.assertNotIn(CANARY,json.dumps(facts))

    def test_curl_ignores_user_config(self):
        self.fx.inspect()
        self.assertFalse((self.fx.root/"unexpected-curl-config-effect").exists())

    def test_http_failure_has_fixed_state(self):
        self.fx.settings.update(curl_exit=7,http_status=CANARY)
        facts,_=self.fx.inspect()
        self.assertEqual(facts["http_health_status"],"000")
        self.assertNotIn(CANARY,json.dumps(facts))

    def test_http_invalid_reply_not_exported(self):
        self.fx.settings["http_status"] = CANARY
        facts,_=self.fx.inspect()
        self.assertEqual(facts["http_health_status"],"000")

    def test_unknown_file_id_never_path_argument(self):
        result=self.fx.run("file","../../etc/shadow","1","0"*64)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,b"")

    def test_invalid_host_never_http(self):
        for host in ["example.com","192.0.2.1;true","256.0.0.1"]:
            with self.subTest(host=host):
                result=self.fx.run("inspect",host)
                self.assertNotEqual(result.returncode,0)
                self.assertNotIn(b"FIRMWARE_SUPPORT_END",result.stdout)

    def test_hash_failure_fails_instead_of_present(self):
        self.fx.settings["hash_failure"]=REQUIRED["ui"]
        result=self.fx.run("inspect","192.0.2.1")
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b"CAPTURE_ERROR FILE_HASH",result.stderr)


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--output",type=Path)
    args=parser.parse_args()
    parent=args.output or REPO/".build/firmware-support-shell"
    parent.mkdir(parents=True,exist_ok=True)
    RUN_ROOT=Path(tempfile.mkdtemp(prefix="run-",dir=parent)).resolve()
    before=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(HelperTests))
    after=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    receipt={"source":str(SOURCE),"sourceSha256":before,"sourceUnchanged":before==after,"tests":result.testsRun,"failures":len(result.failures),"errors":len(result.errors),"passed":result.wasSuccessful() and before==after,"fixtureRoot":str(RUN_ROOT),"scope":"Actual /bin/sh control flow, mechanical fixed-path/PATH translation and synthetic Linux metadata; no device or native-kernel compatibility claim."}
    (RUN_ROOT/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps(receipt))
    sys.exit(0 if receipt["passed"] else 1)
