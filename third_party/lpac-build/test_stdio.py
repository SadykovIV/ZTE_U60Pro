#!/usr/bin/env python3
"""Real macOS ARM64 lpac, synthetic stdio only; no card, SSH or HTTP sockets."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / '.build/lpac-host/output/lpac'
TRANSCRIPTS = []

def response(ecode=0, data=None):
    p = {'ecode': ecode}
    if data is not None:
        p['data'] = data
    return {'type': 'apdu', 'payload': p}

def run(name, replies, argv=None):
    env = {'PATH': '/usr/bin:/bin', 'LPAC_APDU': 'stdio', 'LPAC_HTTP': 'stdio'}
    r = subprocess.run([str(BINARY)] + (argv or ['profile', 'list']),
                       input=''.join(json.dumps(x)+'\n' for x in replies),
                       text=True, capture_output=True, env=env, timeout=5)
    messages = [json.loads(x) for x in r.stdout.splitlines()]
    TRANSCRIPTS.append({'name': name, 'exitCode': r.returncode,
                        'requestsAndResults': messages, 'stderr': r.stderr})
    return r, messages

class StdioTests(unittest.TestCase):
    def check_nickname(self, name, channel=1, failure_at=None, card_reply=None):
        # Independent DER oracle, with a synthetic 19-digit ICCID. Nickname is
        # a positional argument; punctuation must be preserved as card data.
        iccid = '8900000000000000001'
        digits = iccid + 'F'
        bcd = bytes(int(digits[i + 1] + digits[i], 16)
                    for i in range(0, len(digits), 2))

        def tlv(tag, data):
            n = len(data)
            if n < 128:
                size = bytes([n])
            else:
                raw = n.to_bytes((n.bit_length() + 7) // 8, 'big')
                size = bytes([0x80 | len(raw)]) + raw
            return tag + size + data

        der = tlv(b'\xbf\x29', tlv(b'\x5a', bcd) + tlv(b'\x90', name.encode('utf-8')))
        chunks = [der[i:i + 120] for i in range(0, len(der), 120)]
        commands = [bytes([0x80 | channel, 0xe2,
                           0x91 if i == len(chunks) - 1 else 0x11,
                           i, len(chunk)]) + chunk for i, chunk in enumerate(chunks)]
        if failure_at is not None:
            commands = commands[:failure_at + 1]
        responses = ['9000'] * (len(commands) - 1)
        responses.append(card_reply or 'BF29038001009000')
        replies = [response(), response(channel)]
        replies += [response(data=value) for value in responses]
        replies += [response(), response()]
        success = failure_at is None and card_reply is None
        r, ms = run('nickname-' + str(len(name.encode('utf-8'))) +
                    ('-failure' if not success else ''), replies,
                    ['profile', 'nickname', iccid, name])
        self.assertEqual(r.stderr, '')
        self.assertEqual(r.returncode == 0, success)
        self.assertFalse(any(m['type'] == 'http' for m in ms))
        apdu = [m['payload'] for m in ms if m['type'] == 'apdu']
        self.assertEqual([p['func'] for p in apdu],
                         ['connect', 'logic_channel_open'] +
                         ['transmit'] * len(commands) +
                         ['logic_channel_close', 'disconnect'])
        self.assertEqual(apdu[1]['param'], 'a0000005591010ffffffff8900000100')
        # Exact BF29 command sequence excludes enable/disable/delete/REFRESH,
        # verifies DER long lengths and every Unicode byte across fragments.
        self.assertEqual([p['param'] for p in apdu if p['func'] == 'transmit'],
                         [command.hex() for command in commands])
        self.assertEqual(apdu[-2]['param'], f'{channel:02x}')
        self.assertIsNone(apdu[-1]['param'])
        final = [m['payload'] for m in ms if m['type'] == 'lpa']
        self.assertEqual(len(final), 1)
        self.assertIs(type(final[0]['code']), int)
        self.assertEqual(final[0]['code'] == 0, success)

    def test_nickname_positional_text_is_preserved(self):
        for name in ('Рабочая SIM', '-dash', "-\"quote\" ' ; $(printf ignored) `echo literal`"):
            with self.subTest(name=name):
                self.check_nickname(name)

    def test_nickname_unicode_limits_and_fragmentation(self):
        for name, channel in [('a' * 64, 1), ('Я' * 64, 2), ('😀' * 59, 3), ('😀' * 64, 1)]:
            with self.subTest(utf8_bytes=len(name.encode('utf-8')), channel=channel):
                self.check_nickname(name, channel)

    def test_nickname_card_rejection_closes_owned_channel(self):
        for reply in ('6A82', '6F00', 'BF29038001019000'):
            with self.subTest(reply=reply):
                self.check_nickname('Synthetic name', 2, card_reply=reply)

    def test_nickname_fragment_failure_stops_and_closes(self):
        # A failed first STORE DATA fragment must prevent the final write.
        self.check_nickname('Я' * 64, 3, failure_at=0, card_reply='6F00')

    def test_nickname_oversized_utf8_never_transmits(self):
        r, ms = run('nickname-over-byte-bound',
                    [response(), response(1), response(), response()],
                    ['profile', 'nickname', '8900000000000000001', '😀' * 64 + 'x'])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stderr, '')
        self.assertFalse(any(m['type'] == 'http' for m in ms))
        apdu = [m['payload'] for m in ms if m['type'] == 'apdu']
        self.assertEqual([p['func'] for p in apdu],
                         ['connect', 'logic_channel_open', 'logic_channel_close', 'disconnect'])
        self.assertEqual(apdu[-2]['param'], '01')
        final = [m['payload'] for m in ms if m['type'] == 'lpa']
        self.assertEqual(len(final), 1)
        self.assertIs(type(final[0]['code']), int)
        self.assertNotEqual(final[0]['code'], 0)

    def check_session(self, name, channel=1, card_replies=None, success=True):
        replies = [response(), response(channel)]
        replies += [response(data=x) for x in (card_replies or ['BF2D02A0009000'])]
        replies += [response(), response()]
        r, ms = run(name, replies)
        self.assertEqual(r.stderr, '')
        self.assertEqual(r.returncode == 0, success)
        apdu = [m['payload'] for m in ms if m['type'] == 'apdu']
        funcs = [p['func'] for p in apdu]
        self.assertEqual(funcs, ['connect', 'logic_channel_open'] +
                         ['transmit'] * len(card_replies or [1]) +
                         ['logic_channel_close', 'disconnect'])
        self.assertIsNone(apdu[0]['param'])
        self.assertEqual(apdu[1]['param'], 'a0000005591010ffffffff8900000100')
        self.assertEqual(apdu[2]['param'], f'{0x80|channel:02x}e2910003bf2d00')
        self.assertEqual(apdu[-2]['param'], f'{channel:02x}')
        self.assertIsNone(apdu[-1]['param'])
        final = [m['payload'] for m in ms if m['type'] == 'lpa']
        self.assertEqual(len(final), 1)
        self.assertIs(type(final[0]['code']), int)
        self.assertEqual(final[0]['code'] == 0, success)
        if success:
            self.assertEqual(final[0]['data'], [])
        return apdu

    def test_version(self):
        r, ms = run('version', [], ['version'])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(ms, [{'type':'lpa','payload':{'code':0,'message':'success','data':'v2.3.0-stdio-backports'}}])

    def test_only_stdio_drivers(self):
        r, ms = run('driver-list', [], ['driver', 'list'])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(ms, [{'type':'driver','payload':{'LPAC_APDU':['stdio'],'LPAC_HTTP':['stdio']}}])

    def test_empty_profiles_channels_1_2_3(self):
        for channel in (1, 2, 3):
            with self.subTest(channel=channel):
                self.check_session(f'empty-profiles-channel-{channel}', channel)

    def test_61xx_continuation_same_channel(self):
        apdu = self.check_session('continuation', 2, ['BF2D026102', 'A0009000'])
        self.assertEqual(apdu[3]['param'], '82c0000002')

    def test_terminal_card_errors_close(self):
        for sw in ('6A82', '6F00'):
            with self.subTest(sw=sw):
                self.check_session('terminal-'+sw, 1, [sw], False)

    def test_open_failure_disconnect_no_close(self):
        r, ms = run('open-failure', [response(), response(-1), response()])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual([m['payload']['func'] for m in ms if m['type']=='apdu'],
                         ['connect', 'logic_channel_open', 'disconnect'])
        self.assertEqual(r.stderr, '')

    def test_connect_failure_stops(self):
        r, ms = run('connect-failure', [response(-1)])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual([m['payload']['func'] for m in ms if m['type']=='apdu'], ['connect'])
        self.assertEqual(r.stderr, '')

    def test_malformed_connect_envelope_no_null_deref(self):
        for bad in ({'type':'http','payload':{'ecode':0}}, {'type':'apdu','payload':{}},
                    {'type':'apdu','payload':{'ecode':'0'}}):
            r, ms = run('malformed-connect', [bad])
            self.assertEqual(r.returncode, 255)
            self.assertEqual([m['payload']['func'] for m in ms if m['type']=='apdu'], ['connect'])
            self.assertEqual(r.stderr, '')

    def test_malformed_open_disconnect(self):
        r, ms = run('malformed-open', [response(), {'type':'http'}, response()])
        self.assertEqual(r.returncode, 255)
        self.assertEqual([m['payload']['func'] for m in ms if m['type']=='apdu'],
                         ['connect','logic_channel_open','disconnect'])
        self.assertEqual(r.stderr, '')

    def test_notification_list_and_process_all_empty(self):
        # An empty synthetic queue causes no HTTP and no notification removal.
        for argv in (['notification', 'list'], ['notification', 'process', '-a', '-r']):
            with self.subTest(argv=argv):
                r, ms = run('-'.join(argv), [response(), response(1),
                            response(data='BF2802A0009000'), response(), response()], argv)
                self.assertEqual(r.returncode, 0)
                self.assertEqual(r.stderr, '')
                apdu = [m['payload'] for m in ms if m['type']=='apdu']
                self.assertEqual([p['func'] for p in apdu], ['connect', 'logic_channel_open',
                                 'transmit', 'logic_channel_close', 'disconnect'])
                self.assertEqual(apdu[2]['param'], '81e2910003bf2800')
                self.assertEqual(apdu[3]['param'], '01')
                self.assertFalse(any(m['type']=='http' for m in ms))
                final = [m['payload'] for m in ms if m['type']=='lpa']
                self.assertEqual(len(final), 1)
                self.assertIs(type(final[0]['code']), int)
                self.assertEqual(final[0]['code'], 0)
                if argv[1]=='list':
                    self.assertEqual(final[0]['data'], [])

if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(StdioTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    proof = {'binary':str(BINARY.relative_to(ROOT)),
             'sha256':hashlib.sha256(BINARY.read_bytes()).hexdigest(),
             'testsRun':result.testsRun, 'failures':len(result.failures), 'errors':len(result.errors),
             'noDevice':True, 'noNetwork':True, 'syntheticDataOnly':True,
             'transcripts':TRANSCRIPTS}
    (ROOT/'.build/esim/stdio-test-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)
