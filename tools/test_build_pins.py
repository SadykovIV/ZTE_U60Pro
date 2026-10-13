"""Agent-only updates must keep previously reviewed VPN controllers usable."""
from pathlib import Path
import importlib.util
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('public_build', ROOT/'tools/build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class ControllerPinTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT/'ModemAgent/agent/src/vpn.rs').read_text()
        self.old = re.search(r'^const HELPER_SHA: &str = "([a-f0-9]{64})";', self.source, re.M).group(1)

    def pins(self, source):
        current = re.search(r'^const HELPER_SHA: &str = "([a-f0-9]{64})";', source, re.M).group(1)
        body = re.search(r'^const PREVIOUS_HELPER_SHAS: &\[&str\] = &\[(.*?)^\];', source, re.M | re.S).group(1)
        return current, re.findall(r'"([a-f0-9]{64})"', body)

    def test_two_successive_builds_preserve_existing_and_both_previous_pins(self):
        first = build.update_agent_helper_pin(self.source, 'a'*64)
        second = build.update_agent_helper_pin(first, 'b'*64)
        current, previous = self.pins(second)
        self.assertEqual(current, 'b'*64)
        self.assertEqual(set(previous), set(self.pins(self.source)[1]) | {self.old, 'a'*64})
        self.assertEqual(len(previous), len(set(previous)))
        self.assertIn('b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a', previous)
        self.assertIn('e00749ed2a6273c95a4b0563212313c81e54928f6564fdbd8f9616d12a4df6ba', previous)

    def test_same_build_is_byte_identical(self):
        self.assertEqual(build.update_agent_helper_pin(self.source, self.old), self.source)
        generated = build.update_agent_helper_pin(self.source, 'a'*64)
        self.assertEqual(build.update_agent_helper_pin(generated, 'a'*64), generated)

    def test_untrusted_hash_and_dynamic_source_history_are_rejected(self):
        for value in ['', 'abc', 'A'*64, 'a'*64+'; execute']:
            with self.subTest(hash=value), self.assertRaises(ValueError):
                build.update_agent_helper_pin(self.source, value)
        dynamic = self.source.replace('const PREVIOUS_HELPER_SHAS: &[&str] = &[', 'const PREVIOUS_HELPER_SHAS: &[&str] = &[\n    env!("DEVICE_HASH"),')
        with self.assertRaises(ValueError):
            build.update_agent_helper_pin(dynamic, 'a'*64)

    def test_missing_and_duplicate_declarations_are_rejected(self):
        pin = f'const HELPER_SHA: &str = "{self.old}";'
        for source in [self.source.replace(pin, ''), self.source+'\n'+pin, self.source.replace('const PREVIOUS_HELPER_SHAS:', 'const UNUSED_HASHES:')]:
            with self.subTest(source=source[:80]), self.assertRaises(ValueError):
                build.update_agent_helper_pin(source, 'a'*64)


if __name__ == '__main__':
    unittest.main()
