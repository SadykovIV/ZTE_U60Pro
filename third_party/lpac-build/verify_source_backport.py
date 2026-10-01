#!/usr/bin/env python3
"""Verify every pinned release file and the one allowed source backport."""
from pathlib import Path
import hashlib
import json

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
changed = []
for f in manifest['files']:
    data = (ROOT/'third_party/lpac'/f['path']).read_bytes()
    if f['path'] == 'driver/apdu/stdio.c':
        assert hashlib.sha256(original.read_bytes()).hexdigest() == f['sha256']
        assert data == expected
        changed.append({'path':f['path'], 'originalSHA256':f['sha256'],
                        'sha256':hashlib.sha256(data).hexdigest()})
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
         'profileAndNotificationSourcesUnchanged':True, 'result':'PASS'}
(ROOT/'.build/esim/source-backport-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof,indent=2))
