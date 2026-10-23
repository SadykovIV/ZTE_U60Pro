#!/usr/bin/env python3
"""Check that packaged runtime files are accepted by the clean-install helper.

No helper is executed and no device data is read. Historical literals are also
kept in the shell regression tests; this gate catches current payload drift.
"""
import argparse
import hashlib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PAYLOADS = {
    'vpn-service': 'service.sh', 'manager': 'manager.sh',
    'firewall': 'firewall.sh', 'configure': 'configure.lua',
    'ikev2': 'ikev2.sh', 'launcher-service': 'launcher-service.sh',
}

def check(root=ROOT, source_only=False):
    errors=[]
    mac=root/'MacIMEI/Resources'; windows=root/'Windows_x64/Resources'
    helper=mac/'Onboarding/clean-components.sh'
    body=helper.read_bytes()
    registry=set(re.findall(r'([a-z0-9-]+):([a-f0-9]{64})',body.decode()))
    if not source_only and body != (windows/'Onboarding/clean-components.sh').read_bytes():
        errors.append('Mac/Windows clean-components.sh differ')
    for kind,name in PAYLOADS.items():
        payload=(mac/'VPN'/name).read_bytes()
        if not source_only and payload != (windows/'VPN'/name).read_bytes():
            errors.append(f'Mac/Windows VPN/{name} differ')
        if (kind,hashlib.sha256(payload).hexdigest()) not in registry:
            errors.append(f'clean-components.sh does not accept bundled VPN/{name}')
    return errors

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-only',action='store_true',help='Check the source archive Mac payloads without requiring Windows mirrors')
    args=parser.parse_args()
    errors=check(source_only=args.source_only)
    if errors:
        print('\n'.join(errors),file=sys.stderr)
        raise SystemExit(1)
    print('Cleanup payload compatibility: PASS')
