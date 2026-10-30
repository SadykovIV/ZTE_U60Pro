#!/usr/bin/env python3
"""Verify every pinned release file and the exact allowed local patches."""
from pathlib import Path
import hashlib
import json
import difflib

ROOT = Path(__file__).resolve().parents[2]
manifest = json.loads((ROOT/'third_party/lpac-build/upstream-source-manifest.json').read_text())
original = ROOT/'third_party/lpac-build/stdio.original.c'
text = original.read_text()
assert text.count('if (json_request(') == 3
expected = text.replace('if (json_request(', 'if (!json_request(')
old = '    free(*data);\n    if (data) {\n        *data = NULL;\n    }\n    if (data_len) {'
new = '    if (data != NULL) {\n        free(*data);\n        *data = NULL;\n    }\n    if (data_len != NULL) {'
assert expected.count(old) == 1
expected = expected.replace(old, new).encode()
nickname_original = ROOT/'third_party/lpac-build/es10c.original.c'
nickname_text = nickname_original.read_text()
nickname_start = nickname_text.index('int es10c_set_nickname(')
nickname_end = nickname_text.index('\nvoid es10c_profile_info_list_free_all(', nickname_start)
nickname_function = nickname_text[nickname_start:nickname_end]
nickname_edits = [
    ('    uint32_t reqlen;', '''    uint32_t reqlen;
    /* UTF8String SIZE(0..64): at most 256 UTF-8 bytes and 21 DER bytes.
     * Keep DER separate from the APDU buffer used to transmit each chunk. */
    uint8_t request[277];
    size_t nickname_len;

    if (!profileNickname || (nickname_len = strlen(profileNickname)) > 256) {
        return -1;
    }'''),
    ('n_profileNickname.length = strlen(profileNickname);', 'n_profileNickname.length = nickname_len;'),
    ('reqlen = sizeof(ctx->apdu._internal.request_buffer.body);', 'reqlen = sizeof(request);'),
    ('euicc_derutil_pack(ctx->apdu._internal.request_buffer.body, &reqlen, &n_request)', 'euicc_derutil_pack(request, &reqlen, &n_request)'),
    ('es10x_command(ctx, &respbuf, &resplen, ctx->apdu._internal.request_buffer.body, reqlen)', 'es10x_command(ctx, &respbuf, &resplen, request, reqlen)'),
]
for old_nickname, new_nickname in nickname_edits:
    assert nickname_function.count(old_nickname) == 1
    nickname_function = nickname_function.replace(old_nickname, new_nickname)
nickname_expected = nickname_text[:nickname_start] + nickname_function + nickname_text[nickname_end:]
nickname_patch = ROOT/'third_party/lpac-build/nickname-buffer.patch'
assert nickname_patch.read_text() == ''.join(difflib.unified_diff(
    nickname_text.splitlines(True), nickname_expected.splitlines(True),
    fromfile='a/euicc/es10c.c', tofile='b/euicc/es10c.c'))
changed = []
for f in manifest['files']:
    data = (ROOT/'third_party/lpac'/f['path']).read_bytes()
    if f['path'] == 'driver/apdu/stdio.c':
        assert hashlib.sha256(original.read_bytes()).hexdigest() == f['sha256']
        assert data == expected
        changed.append({'path':f['path'], 'originalSHA256':f['sha256'],
                        'sha256':hashlib.sha256(data).hexdigest()})
    elif f['path'] == 'euicc/es10c.c':
        assert hashlib.sha256(nickname_original.read_bytes()).hexdigest() == f['sha256']
        assert data == nickname_expected.encode()
        changed.append({'path': f['path'], 'originalSHA256': f['sha256'],
                        'sha256': hashlib.sha256(data).hexdigest(),
                        'reason': 'Independent bounded DER buffer for 64-character UTF-8 nicknames'})
    elif f['path'] == 'cmake/git-version.cmake':
        assert data == b'# Public source export has no nested .git. Pin the actual lpac version.\nset(LPAC_VERSION \"v2.3.0-stdio-backports\")\nconfigure_file(${SRC} ${DST} @ONLY)\n'
        changed.append({'path': f['path'], 'reason':'deterministic public version', 'sha256':hashlib.sha256(data).hexdigest()})
    else:
        assert hashlib.sha256(data).hexdigest() == f['sha256'], f['path']
proof = {'sourceCommit':manifest['commit'], 'releaseFilesChecked':len(manifest['files']),
         'unchangedFiles':len(manifest['files'])-len(changed), 'changedFiles':changed,
         'upstreamFixes':[
             {'commit':'977c32431bac71adbb3aad7d4124e3154f9bdf93',
              'scope':'All three bool-success checks from its complete source patch'},
             {'commit':'a4150b2077fe4f253f1861a75e28cc80197ddcb2',
              'scope':'NULL-check fix; unrelated unistd include removal omitted'}],
         'patchSHA256':hashlib.sha256((ROOT/'third_party/lpac-build/stdio-backport.patch').read_bytes()).hexdigest(),
         'nicknamePatchSHA256':hashlib.sha256(nickname_patch.read_bytes()).hexdigest(),
         'profileAndNotificationSourcesUnchanged':False,
         'profileSourceChangeScope':'Only es10c_set_nickname DER request storage and byte bound; all other profile and notification code unchanged',
         'result':'PASS'}
(ROOT/'.build/esim/source-backport-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof,indent=2))
