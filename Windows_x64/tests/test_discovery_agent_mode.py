#!/usr/bin/env python3
"""Exercise the production mode proof with synthetic /proc and no HTTP/device."""
import hashlib
import pathlib
import re
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).parents[1] / "src/Core/OnboardingEngine.cs"
COMMAND = re.search(r'DiscoveryAgentCommand\(\) => """\n(.*?)\n        """', SOURCE.read_text(), re.S).group(1)


class DiscoveryModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name).resolve()
        self.agent = self.root / "agent"; self.agent.write_bytes(b"synthetic-agent")
        self.proc = self.root / "proc"; (self.proc / "1").mkdir(parents=True)
        (self.proc / "1/exe").symlink_to(self.agent)
        self.digest = hashlib.sha256(self.agent.read_bytes()).hexdigest()

    def tearDown(self):
        self.tmp.cleanup()

    def probe(self, mode="discovery", bind="192.168.5.1:9090", pids="1", duplicate_mode=False, wrong_digest=False):
        env = f"ZTE_AGENT_MODE={mode}\0ZTE_AGENT_BIND={bind}\0SYNTHETIC_SECRET=never-output\0"
        if duplicate_mode: env += "ZTE_AGENT_MODE=discovery\0"
        (self.proc / "1/environ").write_bytes(env.encode())
        body = COMMAND.replace("/data/zte-agent", str(self.agent)).replace("/proc/", str(self.proc) + "/")
        body = body.replace("EXPECTED_AGENT", "'" + ("a" * 64 if wrong_digest else self.digest) + "'")
        body = body.replace("EXPECTED_BIND", "'ZTE_AGENT_BIND=192.168.5.1:9090'")
        self.assertNotIn("/api/", body)
        script = "pidof() { printf '%s\\n' '" + pids + "'; }\nsha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\n" + body
        reply = subprocess.run(["/bin/sh", "-c", script], capture_output=True, timeout=3)
        self.assertNotIn(b"never-output", reply.stdout + reply.stderr)
        return reply

    def test_discovery_exact_hash_bind_and_process(self):
        reply = self.probe(); self.assertEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, b"AGENT_DISCOVERY_READY")

    def test_normal_agent_refused(self):
        self.assertNotEqual(self.probe(mode="normal").returncode, 0)

    def test_other_bind_refused(self):
        self.assertNotEqual(self.probe(bind="192.168.6.1:9090").returncode, 0)

    def test_duplicate_process_refused(self):
        self.assertNotEqual(self.probe(pids="1 1").returncode, 0)

    def test_duplicate_mode_refused(self):
        self.assertNotEqual(self.probe(duplicate_mode=True).returncode, 0)

    def test_other_image_hash_refused(self):
        self.assertNotEqual(self.probe(wrong_digest=True).returncode, 0)

    def test_unknown_running_image_refused(self):
        old = self.root / "old-agent"; old.write_bytes(b"old-synthetic-agent")
        (self.proc / "1/exe").unlink(); (self.proc / "1/exe").symlink_to(old)
        self.assertNotEqual(self.probe().returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
