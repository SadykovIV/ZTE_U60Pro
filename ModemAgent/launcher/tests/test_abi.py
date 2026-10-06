"""Host checks; optional captured ELF inputs stay outside the source tree."""
import copy
import hashlib
import os
from pathlib import Path
import re
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import abi


class AbiTests(unittest.TestCase):
    def test_generated_header_and_all_call_sites_match(self):
        self.assertEqual((abi.HERE / 'abi.h').read_text(), abi.header())
        source = (abi.HERE / 'launcher.c').read_text()
        calls = set()
        for expression in re.findall(r'F\(([^,]+),', source):
            calls.update(re.findall(r'0x[0-9a-f]+', expression))
        self.assertEqual(calls, {f['id'] for f in abi.PROFILES[0]['functions']})
        self.assertNotRegex(source, r'\*\([^)]*\*\)0x')
        self.assertIn('launcher_abi_valid(abi,read_pointer,read_word)', source)

    def test_exact_profile_registry_and_script_hashes_agree(self):
        hashes = {h for p in abi.PROFILES for h in p['uiSHA256']}
        self.assertEqual(len(hashes), 4)
        for name in ('launcher-run.sh', 'install-launcher.sh'):
            source = (abi.HERE / 'scripts' / name).read_text()
            self.assertTrue(hashes <= set(re.findall(r'\b[0-9a-f]{64}\b', source)))
            self.assertNotIn('/firmware/image/modem.b16', source)
            self.assertIn('uname -m', source)
        for p in abi.PROFILES:
            self.assertEqual(len(p['functions']), 34)
            self.assertEqual(len({f['address'] for f in p['functions']}), 34)
            self.assertEqual(len(p['hooks']), 5)
            self.assertEqual(p['vtable']['rtti'], '10TUFormMain')

    def test_unknown_or_truncated_input_refused(self):
        for data in (b'', b'\x7fELF', b'unknown', bytes(128)):
            with self.assertRaises(ValueError):
                abi.verify(data)

    def test_captured_reference_elves_and_mutation_refusal(self):
        paths = [os.environ[k] for k in ('ZTE_STOCK_UI', 'ZTE_RUSSIAN_UI', 'ZTE_B28_STOCK_UI', 'ZTE_B28_RUSSIAN_UI') if os.environ.get(k)]
        if not paths:
            self.skipTest('No private captured ELF paths supplied')
        for path in paths:
            original = Path(path).read_bytes()
            profile_id = abi.verify(original)
            p = next(p for p in abi.PROFILES if p['id'] == profile_id)
            header = struct.unpack_from('<16sHHIQQQIHHHHHH', original)
            segments = [struct.unpack_from('<IIQQQQQQ', original, header[5] + i * header[9]) for i in range(header[10])]

            def offset(address):
                for kind, _, off, va, _, size, _, _ in segments:
                    if kind == 1 and va <= address < va + size:
                        return off + address - va
                raise AssertionError('Unmapped test address')

            for target in (24, offset(int(p['hooks'][0]['slot'], 0)), offset(int(p['functions'][0]['address'], 0)), offset(int(p['globals']['palette'], 0))):
                changed = bytearray(original); changed[target] ^= 1
                with self.assertRaises(ValueError):
                    abi.verify(changed)
                # A mistaken future hash registry addition must still fail its
                # independent entry/slot/function/palette ABI checks.
                saved = copy.deepcopy(p['uiSHA256'])
                try:
                    p['uiSHA256'].append(hashlib.sha256(changed).hexdigest())
                    with self.assertRaises(ValueError):
                        abi.verify(changed)
                finally:
                    p['uiSHA256'][:] = saved


if __name__ == '__main__':
    unittest.main()
