#!/usr/bin/env python3
"""Host-only CLI fixtures. Refuses ELF/Linux so no card can be reached."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import shlex

binary = Path(sys.argv[1]).resolve()
assert sys.platform == "darwin" and binary.read_bytes()[:4] == b"\xcf\xfa\xed\xfe"
count = 0
for mode in ["--esim-launcher-v2", "--esim-rpc"]:
    child = subprocess.Popen([str(binary), mode], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.15)
        child.send_signal(signal.SIGHUP)
        time.sleep(0.05)
        assert child.poll() is None, "SIGHUP terminated private RPC before EOF cleanup"
        out, err = child.communicate(b'{"protocol":2,"target":"internal-euicc-slot2","operation":"list"}\n', timeout=5)
        rows = [json.loads(row) for row in out.splitlines()]
        final = [row for row in rows if row.get("type") == "result"]
        assert child.returncode == 1 and len(final) == 1 and final[0]["error"] == "unsupported_device"
        assert err == b""
        count += 1
    finally:
        if child.poll() is None:
            child.kill()  # Host fixture only; never an SSH/QMI child.
            child.communicate()
for request in [
    {"protocol":2,"target":"internal-euicc-slot2","operation":"list","token":"SYNTHETIC_PRIVATE"},
    {"protocol":2,"target":"internal-euicc-slot2","operation":"enable","iccid":"SYNTHETIC_PRIVATE"},
]:
    result=subprocess.run([str(binary),"--esim-launcher-v2"],
        input=(json.dumps(request)+"\n").encode(),capture_output=True,timeout=5)
    assert result.returncode==1 and b"SYNTHETIC_PRIVATE" not in result.stdout+result.stderr
    rows=[json.loads(row) for row in result.stdout.splitlines()]
    assert len(rows)==1 and rows[0]["type"]=="result" and rows[0]["ok"] is False
    count+=1
# Mixed installations fail closed in the reverse direction too: a standard
# Launcher may not use the internal-slot agent through its old entry point.
for flag in ["--esim-launcher", "--esim-launcher-internal"]:
    legacy = subprocess.run([str(binary), flag],
        input=b'{"protocol":2,"target":"internal-euicc-slot2","operation":"list"}\n', capture_output=True, timeout=5)
    assert legacy.returncode == 1 and legacy.stderr == b""
    rows = [json.loads(row) for row in legacy.stdout.splitlines()]
    assert len(rows) == 1 and rows[0]["error"] == "invalid_arguments"
    count += 1
check = subprocess.run([str(binary), "--esim-check"], capture_output=True, timeout=5)
assert check.returncode == 0 and check.stderr == b""
capabilities = json.loads(check.stdout)
assert capabilities["ok"] is True and capabilities["offline"] is True
assert capabilities["target_mode"] == "explicit" and capabilities["protocol"] == 2
assert set(capabilities["operations"]) == {"discover", "list", "download", "enable", "delete", "rename"}
count += 1
assert not Path('/data').exists(), 'Host startup fixtures require no modem /data state'
with tempfile.TemporaryDirectory(prefix='zte-agent-cli-') as directory:
    root = Path(directory)
    marker = root / 'unexpected-device-command'
    for command in ['ubus', 'uci', 'ip', 'pidof', 'logger', 'sh', 'iw', 'bridge', 'ethtool']:
        stub = root / command
        stub.write_text("#!/bin/sh\nprintf '%s\\n' unexpected >> " + shlex.quote(str(marker)) + "\nexit 99\n")
        stub.chmod(0o700)
    env = dict(os.environ, PATH=str(root), ZTE_AGENT_BIND='127.0.0.1:0')
    version = subprocess.run([str(binary), '--version'], capture_output=True, env=env, timeout=5)
    assert version.returncode == 0 and version.stderr == b''
    assert version.stdout == (capabilities['version'] + '\n').encode()
    count += 1
    for arguments in [['--unknown'], ['unexpected'], ['--version', 'extra'], ['--version', '--version']]:
        invalid = subprocess.run([str(binary), *arguments], capture_output=True, env=env, timeout=5)
        assert invalid.returncode == 2 and invalid.stdout == b'' and invalid.stderr == b'invalid_arguments\n'
        count += 1
    for flag in ['--esim-launcher', '--esim-launcher-internal']:
        legacy = subprocess.run([str(binary), flag], input=b'', capture_output=True, env=env, timeout=5)
        assert legacy.returncode == 1 and legacy.stderr == b''
        assert json.loads(legacy.stdout)['error'] == 'invalid_arguments'
        count += 1
    assert not marker.exists(), 'Early CLI path reached a device command'
print(json.dumps({"ok":True,"host_only":True,"tests":count,"device_calls":0}))
