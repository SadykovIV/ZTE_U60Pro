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
COMPONENTS = {'ipacm': '/usr/bin/ipacm', 'ipa_switch': '/sbin/ipacm_switch.sh', 'network_init': '/etc/init.d/network', 'netifd': '/sbin/netifd', 'procd': '/sbin/procd', 'ubusd': '/sbin/ubusd', 'ubus_cli': '/bin/ubus', 'uci_cli': '/sbin/uci', 'lua_cli': '/usr/bin/lua', 'mdm': '/usr/bin/zte_topsw_mdm', 'qcril': '/usr/bin/qcrilNrd', 'diag_router': '/usr/bin/diag-router', 'libdiag': '/usr/lib/libdiag.so.1', 'libzte_sdk': '/usr/lib/libzte_SDKowrt.so', 'libzte_gesture': '/usr/lib/libzte_gesture.so', 'libzte_log': '/usr/lib/libztelog.so', 'libfreetype': '/usr/lib/libfreetype.so.6', 'libpng': '/usr/lib/libpng16.so.16', 'libdrm': '/usr/lib/libdrm.so.2', 'libgcc': '/lib/libgcc_s.so.1', 'libc': '/lib/libc.so', 'libuci': '/lib/libuci.so', 'libubus': '/lib/libubus.so', 'libubox': '/lib/libubox.so', 'libblobmsg_json': '/lib/libblobmsg_json.so', 'libjson_c': '/usr/lib/libjson-c.so.5', 'liblua': '/usr/lib/liblua.so.5.1', 'lua_uci': '/usr/lib/lua/uci.so', 'lua_jsonc': '/usr/lib/lua/luci/jsonc.so'}
RADIO_COMPONENTS = {'firmware_mdt': '/firmware/image/modem.mdt', 'firmware_b16': '/firmware/image/modem.b16', 'libqcril_nr': '/usr/lib/libqcrilNr.so', 'libqcril_nrril': '/usr/lib/libqcrilNrril.so.1', 'libzte_qmi': '/usr/lib/libzteqmi.so', 'libqmiservices': '/usr/lib/libqmiservices.so', 'libqmi_cci': '/usr/lib/libqmi_cci.so.1', 'libqmi_csi': '/usr/lib/libqmi_csi.so.1', 'libqmi_common': '/usr/lib/libqmi_common_so.so.1', 'libqmi_encdec': '/usr/lib/libqmi_encdec.so.1', 'libqmi_sap': '/usr/lib/libqmi_sap.so.1', 'libqrtr': '/usr/lib/libqrtr.so.1', 'libqsocket': '/usr/lib/libqsocket.so.1', 'libglib': '/usr/lib/libglib-2.0.so.0', 'libgthread': '/usr/lib/libgthread-2.0.so.0', 'liblog': '/usr/lib/liblog.so.0', 'libtime_genoff': '/usr/lib/libtime_genoff.so.1', 'libsqlite3': '/usr/lib/libsqlite3.so'}
COMPONENTS.update(RADIO_COMPONENTS)
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
 if 'zwrt_zte_mdm.api' in args:
  method=args[args.index('zwrt_zte_mdm.api')+1]
  if method not in ['get_sim_info','zte_get_current_slot_info']:sys.exit(91)
  print(json.dumps({'current_sim_slot':settings.get(method,0),'iccid':'PRIVATE_PASSWORD_CANARY_NEVER_EXPORT','eid':'PRIVATE_PASSWORD_CANARY_NEVER_EXPORT'}))
  sys.exit(settings.get('slot_exit',0))
 print(json.dumps({'integrate_version':'FLY_CN_MU5250V1.0.0B13','wa_inner_version':'BD_FLYMODEMMU5250V1.0.0B28','password':'PRIVATE_PASSWORD_CANARY_NEVER_EXPORT'}))
 sys.exit(settings.get('ubus_exit',0))
elif tool=='jsonfilter':
 try:
  data=json.load(sys.stdin);value=data.get(args[1].removeprefix('@.'))
  if value is not None:print(value)
 except Exception:sys.exit(1)
elif tool=='uci':
 if len(args)!=3 or args[:2]!=['-q','get']:sys.exit(91)
 print(settings.get(args[2],1))
 sys.exit(settings.get('uci_exit',0))
elif tool=='timeout':
 if args!=['6','qrtr-lookup']:sys.exit(91)
 os.execv(str(Path(__file__).parent/'qrtr-lookup'),['qrtr-lookup'])
elif tool=='qrtr-lookup':
 print(settings.get('qrtr','Service Version Instance Node Port\n11 1 0 3 42 UIM\n'))
 sys.exit(settings.get('qrtr_exit',0))
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
        for name in ["stat", "sha256sum", "id", "uname", "pidof", "ubus", "jsonfilter", "curl", "uci", "timeout", "qrtr-lookup"]:
            path = self.bin / name
            path.write_text(shim)
            path.chmod(0o755)
        for name, path in REQUIRED.items():
            self.put(path, b"\x7fELF\x00fixture\r\n\xff\x00\n" if name == "ui" else (name + "=fixture\r\n").encode())
        self.put("/etc/openwrt_release", b"DISTRIB_RELEASE='23.05.4'\nDISTRIB_TARGET='qualcommax/ipq807x'\n")
        self.put("/proc/self/mountinfo", b"1 2 3:4 / /none rw - tmpfs tmpfs rw\n")
        self.put("/data/zte-agent", b"synthetic agent")
        text = SOURCE.read_text()
        prefixes = r"(?<![A-Za-z0-9_])/(?:usr|lib|etc|data|proc|sbin|firmware|sys)|/bin/ubus|/dev/(?:diag|at_mdm|ffs-diag|socket)"
        old = "export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C"
        assert text.count(old) == 1
        text = text.replace(old, "export PATH='" + str(self.bin) + ":/usr/bin:/bin' LC_ALL=C")
        text = re.sub(prefixes, lambda m: str(self.root) + m.group(0), text)
        # The private fixture PATH is already absolute and must not be remapped.
        text = text.replace("export PATH='" + str(self.bin) + ":" + str(self.root) + "/usr/bin:/bin'", "export PATH='" + str(self.bin) + ":/usr/bin:/bin'")
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
        assert set(facts) == FACTS and set(files) == REQUIRED.keys() | OPTIONAL.keys() | FONTS.keys() | COMPONENTS.keys()
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
        data = self.path((REQUIRED | OPTIONAL | FONTS | COMPONENTS)[name]).read_bytes()
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

    def test_components_stream_exact_bytes(self):
        data = b"\x7fELF\x02\x01\x01component\x00\xff\r\n"
        for name, path in COMPONENTS.items():
            self.fx.put(path, data)
        files = self.fx.inspect()[1]
        for name in COMPONENTS:
            with self.subTest(component=name):
                self.assertEqual(files[name][0], "present")
                result = self.fx.stream(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, data)

    def test_versioned_system_library_alias_is_captured(self):
        data = b"\x7fELF\x02\x01versioned library\x00\xff"
        target = self.fx.put("/usr/lib/libfreetype.so.6.18.0", data)
        self.fx.path(COMPONENTS["libfreetype"]).symlink_to(target.name)
        self.assertEqual(self.fx.inspect()[1]["libfreetype"][0], "present")
        result = self.fx.stream("libfreetype")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, data)

    def test_library_alias_never_exports_user_data(self):
        target = self.fx.put("/data/private-library", b"\x7fELF" + CANARY.encode())
        alias = self.fx.path(COMPONENTS["libzte_sdk"])
        alias.parent.mkdir(parents=True, exist_ok=True); alias.symlink_to(target)
        self.assertEqual(self.fx.inspect()[1]["libzte_sdk"][0], "unsafe_target")
        result = self.fx.stream("libzte_sdk")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_library_path_rejects_non_elf_file(self):
        self.fx.put(COMPONENTS["libzte_sdk"], CANARY.encode())
        self.assertEqual(self.fx.inspect()[1]["libzte_sdk"][0], "not_elf")
        result = self.fx.stream("libzte_sdk")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_library_fallback_under_lib_is_captured(self):
        data = b"\x7fELF\x02\x01\x01uci"
        self.fx.put("/usr/lib/libuci.so", data)
        self.assertEqual(self.fx.inspect()[1]["libuci"][0], "present")
        result = self.fx.run("file", "libuci", str(len(data)), hashlib.sha256(data).hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, data)

    def test_soname_without_development_alias_is_captured(self):
        data = b"\x7fELF\x02\x01\x01ubus"
        self.fx.put("/lib/libubus.so.20230605", data)
        self.assertEqual(self.fx.inspect()[1]["libubus"][0], "present")
        result = self.fx.run("file", "libubus", str(len(data)), hashlib.sha256(data).hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, data)

    def test_multiple_sonames_have_explicit_ambiguity(self):
        data = b"\x7fELF\x02\x01\x01ubus"
        for name in ["20220601", "20230605"]:
            self.fx.put("/lib/libubus.so." + name, data)
        self.assertEqual(self.fx.inspect()[1]["libubus"][0], "ambiguous")
        result = self.fx.run("file", "libubus", str(len(data)), hashlib.sha256(data).hexdigest())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_lua_executable_alias_is_captured(self):
        data = b"\x7fELF\x02\x01\x01lua"
        target = self.fx.put("/usr/bin/lua5.1", data)
        self.fx.path(COMPONENTS["lua_cli"]).symlink_to(target.name)
        self.assertEqual(self.fx.inspect()[1]["lua_cli"][0], "present")
        result = self.fx.stream("lua_cli")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, data)

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

    def radio(self):
        result=self.fx.run("radio")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stderr,b"")
        text=result.stdout.decode()
        self.assertTrue(text.startswith("FIRMWARE_RADIO_V1\n"))
        self.assertTrue(text.endswith("FIRMWARE_RADIO_END\n"))
        self.assertNotIn(CANARY,text)
        return text

    def test_radio_numeric_slot_sources_remain_separate_and_private_values_stay_local(self):
        self.fx.settings.update(get_sim_info=0,zte_get_current_slot_info=2)
        self.fx.settings["zwrt_zte_mdm.sim_info.sim_active_card_id"]=1
        self.fx.settings["zwrt_zte_mdm.sim_info.simcard_active_slot_temp"]=3
        text=self.radio()
        for row in ["mdm_get_sim_info value=0","mdm_get_current_slot_info value=2","uci_active_card_id value=1","uci_active_slot_temp value=3"]:
            self.assertIn("SLOT "+row+"\n",text)
        self.assertNotIn("physical",text)
        self.assertNotIn("builtin",text)
        self.assertIn("POLICY nv_read=0 apdu_sent=0 radio_changed=0 profile_changed=0 private_identifiers_exported=0",text)

    def test_radio_invalid_and_failed_slot_getters_are_not_exported(self):
        self.fx.settings.update(get_sim_info=CANARY,zte_get_current_slot_info="1\n2")
        self.fx.settings["zwrt_zte_mdm.sim_info.sim_active_card_id"]=CANARY
        self.fx.settings["zwrt_zte_mdm.sim_info.simcard_active_slot_temp"]="89123456789012345678"
        self.assertEqual(sum(x.startswith("SLOT ") and x.endswith("value=not_assessed") for x in self.radio().splitlines()),4)
        self.fx.settings.update(get_sim_info=0,zte_get_current_slot_info=1,slot_exit=1,uci_exit=1)
        self.assertEqual(sum(x.startswith("SLOT ") and x.endswith("value=not_assessed") for x in self.radio().splitlines()),4)

    def test_radio_hashes_static_firmware_and_binaries_without_exporting_contents(self):
        self.fx.put("/firmware/image/modem.b16",CANARY.encode())
        self.fx.put("/firmware/image/modem.b03",b"static modem code")
        self.fx.put("/usr/bin/zte_topsw_mdm",b"mdm")
        self.fx.put("/usr/bin/diag-router",b"router")
        text=self.radio()
        self.assertIn("PATH firmware_mdt state=missing",text)
        self.assertIn("PATH firmware_b16 state=present type=regular uid=0 mode=644 bytes="+str(len(CANARY))+" sha256="+hashlib.sha256(CANARY.encode()).hexdigest(),text)
        self.assertIn("PATH modem_segment_b03 state=present",text)
        self.assertNotIn("PATH modem_segment_b16 ",text)
        self.assertIn("PATH mdm state=present",text)

    def test_radio_firmware_symlink_does_not_hash_private_target(self):
        target=self.fx.put("/data/private-firmware",CANARY.encode())
        alias=self.fx.path("/firmware/image/modem.b16");alias.parent.mkdir(parents=True);alias.symlink_to(target)
        text=self.radio()
        self.assertIn("PATH firmware_b16 state=symlink",text)
        self.assertNotIn(hashlib.sha256(CANARY.encode()).hexdigest(),text)

    def test_radio_qrtr_projects_five_numeric_columns_only(self):
        self.fx.settings['qrtr']="Service Version Instance Node Port\n11 1 0 3 42 "+CANARY+"\n1 PRIVATE 3 4 5\n999999999999999 0 0 0 0\n"
        text=self.radio()
        self.assertIn("QRTR service=11 version=1 instance=0 node=3 port=42\n",text)
        self.assertIn("QRTR_INVENTORY state=observed count=1",text)
        self.fx.settings['qrtr_exit']=1
        text=self.radio()
        self.assertIn("QRTR_INVENTORY state=not_assessed count=0",text)
        self.assertNotIn("QRTR service=",text)

    def test_radio_missing_optional_tools_remains_useful(self):
        for name in ['ubus','jsonfilter','uci','qrtr-lookup']:
            (self.fx.bin/name).unlink()
        text=self.radio()
        self.assertIn("QRTR_INVENTORY state=not_assessed count=0",text)
        self.assertIn("SLOT mdm_get_sim_info value=not_assessed",text)
        self.assertIn("PATH mdm state=",text)

    def test_radio_diag_socket_and_partition_metadata_exclude_identifiers(self):
        self.fx.put("/proc/net/unix",("Num RefCount Protocol Flags Type St Inode Path\n0001: 1 0 00010000 0001 01 123 @diag\n0002: 1 0 00010000 0001 01 456 @"+CANARY+"\n").encode())
        self.fx.put("/sys/class/block/mmcblk0p68/uevent",("PARTNAME=userdata\nPARTUUID="+CANARY+"\n").encode())
        self.fx.put("/sys/class/block/mmcblk0p68/size",b"1024\n")
        self.fx.put("/sys/class/block/mmcblk0p68/start",b"4096\n")
        self.fx.put("/sys/class/block/mmcblk0p68/ro",b"0\n")
        self.fx.put("/sys/class/block/mmcblk0p69/uevent",("PARTNAME="+CANARY+"\n").encode())
        self.fx.put("/proc/self/mountinfo",("1 2 3:4 / "+str(self.fx.path("/data"))+" rw - ext4 /dev/"+CANARY+" rw\n").encode())
        text=self.radio()
        self.assertIn("DIAG_SOCKET abstract_diag flags=00010000 type=0001 state=01",text)
        self.assertIn("DIAG_SOCKETS state=observed count=1",text)
        self.assertIn("PARTITION name=userdata block=mmcblk0p68 sectors=1024 start=4096 ro=0",text)
        self.assertIn("MOUNT data mode=rw type=ext4",text)

    def test_new_qmi_library_alias_cannot_export_configuration(self):
        target=self.fx.put("/data/secret-ril",b"\x7fELF"+CANARY.encode())
        alias=self.fx.path(COMPONENTS['libqcril_nr']);alias.parent.mkdir(parents=True,exist_ok=True);alias.symlink_to(target)
        self.assertEqual(self.fx.inspect()[1]['libqcril_nr'][0],'unsafe_target')
        result=self.fx.run('file','libqcril_nr',str(target.stat().st_size),hashlib.sha256(target.read_bytes()).hexdigest())
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,b'')

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
