#!/usr/bin/env python3
"""Host-only CLI fixtures. Refuses ELF/Linux so no card can be reached."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

binary = Path(sys.argv[1]).resolve()
assert sys.platform == "darwin" and binary.read_bytes()[:4] == b"\xcf\xfa\xed\xfe"
count = 0
for mode in ["--esim-launcher", "--esim-rpc"]:
    child = subprocess.Popen([str(binary), mode], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.15)
        child.send_signal(signal.SIGHUP)
        time.sleep(0.05)
        assert child.poll() is None, "SIGHUP terminated private RPC before EOF cleanup"
        out, err = child.communicate(b'{"protocol":1,"operation":"list"}\n', timeout=5)
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
    {"protocol":1,"operation":"list","token":"SYNTHETIC_PRIVATE"},
    {"protocol":1,"operation":"enable","iccid":"SYNTHETIC_PRIVATE"},
]:
    result=subprocess.run([str(binary),"--esim-launcher"],
        input=(json.dumps(request)+"\n").encode(),capture_output=True,timeout=5)
    assert result.returncode==1 and b"SYNTHETIC_PRIVATE" not in result.stdout+result.stderr
    rows=[json.loads(row) for row in result.stdout.splitlines()]
    assert len(rows)==1 and rows[0]["type"]=="result" and rows[0]["ok"] is False
    count+=1
print(json.dumps({"ok":True,"host_only":True,"tests":count,"device_calls":0}))
