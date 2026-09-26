#!/usr/bin/env python3
"""Exercise production editor state with temporary storage; never connect a modem."""
from pathlib import Path
import json, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='display-editor-',dir=root/'.build') as directory:
    work=Path(directory)
    source=(root/'Sources/AppModel.swift').read_text()
    for old,new in [('Library/Application Support/ZTE IMEI Studio',work/'state')]:
        source=source.replace('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("'+old+'")','URL(fileURLWithPath: '+json.dumps(str(new))+')')
    model=work/'AppModel.swift';model.write_text(source)
    sources=[str(p) for p in sorted((root/'Sources').glob('*.swift')) if p.name not in ['AppModel.swift','Main.swift']]
    binary=work/'DisplayEditorTests'
    command=['/usr/bin/swiftc','-module-cache-path',str(root/'.build/module-cache'),'-swift-version','5','-parse-as-library','-target','arm64-apple-macosx13.0',*sources,str(model),str(root/'Tests/DisplayEditorTests.swift'),'-o',str(binary)]
    result=subprocess.run(command,cwd=root,capture_output=True,text=True)
    if result.returncode==0: result=subprocess.run([str(binary)],cwd=root,capture_output=True,text=True)
    log=root/'.build/verification/DisplayEditorTests.log';log.parent.mkdir(parents=True,exist_ok=True);log.write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr,end='');raise SystemExit(result.returncode)
