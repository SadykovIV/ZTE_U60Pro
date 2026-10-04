#!/usr/bin/env python3
"""Build only the new status model and synthetic fixtures; never use a modem."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
MODEL = ROOT / "ModemAgent/launcher/vpn-model.c"


def main():
    # A changed producer error set requires a deliberate display-policy review.
    errors = set()
    for source in (ROOT / "ModemAgent/vpnctl/src").glob("*.rs"):
        errors.update(re.findall(r'"(VPN_[A-Z0-9_]+)"', source.read_text()))
    errors -= {"VPN_PROFILE_FIXTURE", "VPN_SECOND_PROFILE_FIXTURE", "VPN_SPX_PRESERVED"}
    table = MODEL.read_text().split("static const struct error_text errors[] = {", 1)[1].split("\n};", 1)[0]
    entries = re.findall(r'\{"(VPN_[A-Z0-9_]+)",', table)
    assert len(entries) == len(set(entries)), "Duplicate error codes"
    assert set(entries) == errors, "Controller error literal coverage changed"
    assert "cJSON_GetNumberValue" not in MODEL.read_text(), "Unsupported stock ABI symbol"
    with tempfile.TemporaryDirectory(prefix="zte-vpn-model-") as temporary:
        binary = Path(temporary) / "vpn-model-test"
        flags = [os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-g",
                 "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        vendor = Path(temporary) / "cJSON.o"
        # The unchanged vendor code uses sprintf, deprecated by the macOS SDK.
        # Keep warnings fatal for the production model and its fixtures.
        subprocess.run([*flags, "-Wno-deprecated-declarations", "-c",
                        str(ROOT / "third_party/lpac/cjson/cJSON.c"), "-o", str(vendor)], check=True)
        command = [*flags, str(MODEL), str(Path(__file__).with_name("vpn_model_test.c")),
                   str(vendor), "-lm", "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True,
                       env={**os.environ, "ASAN_OPTIONS": f"detect_leaks={int(sys.platform != 'darwin')}:halt_on_error=1",
                            "UBSAN_OPTIONS": "halt_on_error=1"})
    print(f"VPN error table: {len(entries)} exact producer codes; synthetic tests only")


if __name__ == "__main__":
    main()
