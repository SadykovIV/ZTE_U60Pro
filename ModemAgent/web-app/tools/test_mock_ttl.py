"""TTL mock contract checks without opening sockets or changing a modem."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("mock_agent", Path(__file__).with_name("mock_agent.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class TtlMockTests(unittest.TestCase):
    def setUp(self):
        self.original = copy.deepcopy(mock.STATE)
        mock.put_ttl_set({"schema_version": 2, "outbound": 64, "inbound_inc": 1})

    def tearDown(self):
        mock.STATE.clear()
        mock.STATE.update(self.original)

    def request(self, method, path, body=None):
        handler = mock.Handler.__new__(mock.Handler)
        encoded = json.dumps(body).encode() if body is not None else b""
        handler.path = path
        handler.headers = {"Content-Length": str(len(encoded))}
        handler.rfile = io.BytesIO(encoded)
        responses = []
        handler._send = lambda payload, status=200: responses.append((status, copy.deepcopy(payload)))
        getattr(handler, "do_" + method)()
        self.assertEqual(len(responses), 1)
        return responses[0]

    def test_exact_and_increment_values_and_null_are_independent(self):
        for out, inc in [(64, 1), (1, 255), (255, 1), (None, 1), (64, None), (None, None)]:
            with self.subTest(out=out, inc=inc):
                result = mock.put_ttl_set({"schema_version": 2, "outbound": out, "inbound_inc": inc})
                self.assertEqual((result["outbound"], result["inbound_inc"]), (out, inc))
                disabled = out is None and inc is None
                self.assertEqual(result["state"], "disabled" if disabled else "configured")
                self.assertEqual(result["verification"], "not-applicable" if disabled else "unverified")
                self.assertEqual(result["persistence"], "boot")
                self.assertNotIn("ipv6_active", result)
                self.assertNotIn("ttl_value", result)

    def test_invalid_values_never_modify_either_direction(self):
        before = copy.deepcopy(mock.STATE["ttl"])
        for value in [0, -1, 256, 1.5, True, False, "64", "", [], {}]:
            for direction in ["outbound", "inbound_inc"]:
                with self.subTest(value=value, direction=direction):
                    body = {"schema_version": 2, "outbound": 64, "inbound_inc": 1, direction: value}
                    with self.assertRaisesRegex(ValueError, "^TTL_INVALID_CONFIGURATION$"):
                        mock.put_ttl_set(body)
                    self.assertEqual(mock.STATE["ttl"], before)

    def test_missing_unknown_and_non_object_payloads_are_rejected(self):
        before = copy.deepcopy(mock.STATE["ttl"])
        for body in [{"schema_version": 2, "outbound": 64}, {"schema_version": 2, "inbound_inc": 1},
                     {"schema_version": 2, "outbound": 64, "inbound_inc": 1, "ttl": 65}, [], None, 1, "value"]:
            with self.subTest(body=body):
                with self.assertRaisesRegex(ValueError, "^TTL_INVALID_CONFIGURATION$"):
                    mock.put_ttl_set(body)
                self.assertEqual(mock.STATE["ttl"], before)

    def test_stale_and_non_integer_schema_requires_upgrade(self):
        before = copy.deepcopy(mock.STATE["ttl"])
        for body in [{"ttl": 65}, {}, *[{"schema_version": version, "outbound": 64, "inbound_inc": 1}
                                      for version in [1, 3, 2.0, "2", True, None]]]:
            with self.subTest(body=body):
                with self.assertRaisesRegex(ValueError, "^TTL_SCHEMA_UPGRADE_REQUIRED$"):
                    mock.put_ttl_set(body)
                self.assertEqual(mock.STATE["ttl"], before)

    def test_http_set_and_status_share_the_same_configuration(self):
        code, result = self.request("PUT", "/api/ttl/set", {"schema_version": 2, "outbound": 128, "inbound_inc": 2})
        self.assertEqual(code, 200)
        self.assertTrue(result["ok"])
        before = copy.deepcopy(mock.STATE)
        code, read = self.request("GET", "/api/ttl/status?cache=off")
        self.assertEqual(code, 200)
        self.assertEqual(read, result)
        self.assertEqual(mock.STATE, before)

    def test_http_errors_have_stable_status_and_codes_without_mutation(self):
        before = copy.deepcopy(mock.STATE["ttl"])
        for body, status, code in [({"ttl": 65}, 409, "TTL_SCHEMA_UPGRADE_REQUIRED"),
                                   ({"schema_version": 2, "outbound": True, "inbound_inc": 1}, 400, "TTL_INVALID_CONFIGURATION"),
                                   ([], 400, "TTL_INVALID_CONFIGURATION")]:
            with self.subTest(body=body):
                actual, result = self.request("PUT", "/api/ttl/set", body)
                self.assertEqual(actual, status)
                self.assertFalse(result["ok"])
                self.assertEqual(result["code"], code)
                self.assertEqual(mock.STATE["ttl"], before)

    def test_http_delete_disables_both_directions_and_returns_current_status(self):
        code, result = self.request("DELETE", "/api/ttl/clear")
        self.assertEqual(code, 200)
        self.assertEqual(result["data"]["state"], "disabled")
        self.assertIsNone(result["data"]["outbound"])
        self.assertIsNone(result["data"]["inbound_inc"])
        self.assertEqual(result["data"]["verification"], "not-applicable")
        self.assertEqual(self.request("GET", "/api/ttl/status")[1], result)


if __name__ == "__main__":
    unittest.main()
