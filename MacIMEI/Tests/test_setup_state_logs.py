#!/usr/bin/env python3
"""Read-only preparation-state collector with private synthetic fixtures."""
from pathlib import Path
import os, re, subprocess, tempfile
repo = Path(__file__).resolve().parents[2]
swift = (repo/'MacIMEI/Sources/ModemInformation.swift').read_text()
source = swift.split('static let setupStateCommand = #"""\n',1)[1].split('\n"""#',1)[0]
cs = (repo/'Windows_x64/src/Diagnostics/ModemLogCollector.cs').read_text().split('const string SetupStateCommand = """\n',1)[1].split('        """;',1)[0]
assert source == '\n'.join(line[8:] for line in cs.rstrip('\n').splitlines())
with tempfile.TemporaryDirectory(prefix='zte-setup-log-') as temp:
 root=Path(temp).resolve();base=root/'data/zte-imei-studio/installations';base.mkdir(parents=True)
 token='11111111-2222-3333-4444-555555555555';journal=base/token;journal.mkdir();(base/'lock').mkdir();(base/'active').write_text(token+'\n')
 for name,data in {'state':'ready','mode':'reinstall','before.sha256':'PRIVATE_HASH','after.sha256':'PRIVATE_HASH','cid':'PRIVATE_CID','profile.identity':'PRIVATE_IDENTITY','targets':'PRIVATE_TARGETS'}.items():(journal/name).write_text(data+'\n')
 shim=root/'shim';shim.mkdir();stat=shim/'stat';stat.write_text('#!/usr/bin/env python3\nimport os,sys\nst=os.stat(sys.argv[-1]);print(\"0:700\" if sys.argv[2]==\"%u:%a\" else st.st_size)\n');stat.chmod(0o700)
 script=source.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin',f'PATH={shim}:/usr/bin:/bin').replace('/data/',str(root)+'/data/')
 def read():
  r=subprocess.run(['/bin/sh'],input=script,text=True,capture_output=True,timeout=5);assert r.returncode==0,r.stderr
  assert token not in r.stdout and 'PRIVATE_' not in r.stdout
  return r.stdout
 out=read();assert 'active=present\nlock=present' in out and 'state=ready' in out and 'current=yes' in out
 print('PASS active preparation has safe state and metadata, no device identifiers or secrets')
 (journal/'state').write_text('PRIVATE_STATE\n');assert 'state=unknown' in read();print('PASS arbitrary journal text is not exported')
 (journal/'state').unlink();(journal/'state').symlink_to(journal/'cid');assert 'state=unavailable' in read();print('PASS symlink state is not followed')
 (base/'active').write_text('../../PRIVATE_PATH\n');out=read();assert 'active=invalid' in out and 'current=yes' not in out;print('PASS invalid active owner never becomes a path')
 recovery=base.parent/('reset-recovery-'+token+'-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');recovery.mkdir(mode=0o700)
 (recovery/'journal').mkdir();(recovery/'current').mkdir()
 for name in ['snapshot.sha256','cid','boot']:(recovery/name).write_text('PRIVATE_ARCHIVE_DATA')
 out=read();assert 'archive_count=1' in out and 'archive_metadata_present=1' in out and 'archive_contents_verified=not-performed' in out
 print('PASS recovery archive metadata counted without implying content verification')
 (recovery/'boot').unlink();out=read();assert 'archive_metadata_incomplete=1' in out
 print('PASS incomplete recovery snapshot remains visible')
 other=base.parent/('reset-recovery-'+token+'-bbbbbbbb-cccc-dddd-eeee-ffffffffffff');other.symlink_to(recovery)
 out=read();assert 'archive_count=2' in out and 'archive_layout_unsafe=1' in out
 print('PASS recovery symlinks counted as unsafe without traversal')
print('RESULT 7 preparation log checks; no modem access')
