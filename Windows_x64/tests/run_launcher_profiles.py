#!/usr/bin/env python3
"""Launcher exact profile fixtures; no device access."""
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
from xml.sax.saxutils import escape

repo = Path(__file__).resolve().parents[2]
stage_root = repo / '.build/windows-launcher-profiles'
stage = stage_root / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
stage.mkdir(parents=True, exist_ok=False)
source = repo / 'Windows_x64/src'
files = sorted({*source.glob('WindowsModemService*.cs'), *(source / 'Core').glob('*.cs'),
    *(source / 'Features').glob('*.cs'), *(source / 'Transport').glob('*.cs'),
    *(source / 'Research').glob('*.cs'), *(source / 'Diagnostics').glob('*.cs'),
    *((source / 'Esim').glob('*.cs'))} - {source / 'Esim/EsimQr.cs'})
files += [source / name for name in ('IModemService.cs', 'TerminalSession.cs', 'VerifiedCatalog.cs')]
files += [Path(__file__).with_name('LauncherProfileTests.cs'), repo/'Windows_x64/card-recovery-pages-tests/PageInstallerTests.cs',source/'Localization.cs',repo/'Windows_x64/ssh-read-tests/ComponentReadTests.cs']
project = stage / 'LauncherProfileTests.csproj'
project.write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>
<Nullable>enable</Nullable><TreatWarningsAsErrors>true</TreatWarningsAsErrors><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
<NuGetAudit>false</NuGetAudit></PropertyGroup><ItemGroup>''' +
    ''.join('<Compile Include="' + escape(str(p), {'"': '&quot;'}) + '" />' for p in files) +
    '<EmbeddedResource Include="'+escape(str(source.parent/'Resources/Localization/en.json'))+'" LogicalName="ZteManager.Localization.en.json" /><PackageReference Include="SSH.NET" Version="2025.0.0" /></ItemGroup></Project>\n')
fixture = stage / 'fixture'
inputs = files + [source.parent/'Resources/Localization/en.json'] + sorted((source.parent/'Resources').glob('*/SHA256.json'))
before = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
dotnet = shutil.which('dotnet')
if not dotnet:
    raise SystemExit('dotnet is unavailable')
env = dict(os.environ, DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1', DOTNET_CLI_TELEMETRY_OPTOUT='1')
commands = [[dotnet, 'restore', str(project), '--source', str(Path.home()/'.nuget/packages'), '--ignore-failed-sources'],
            [dotnet, 'run', '--project', str(project), '--no-restore', '--', str(fixture), *sys.argv[1:]]]
codes = []
with (stage / 'test.log').open('w') as log:
    for command in commands:
        result = subprocess.run(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, check=False)
        codes.append(result.returncode)
        if result.returncode:
            break
after = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
text = (stage/'test.log').read_text()
receipt = {'schemaVersion': 1, 'commands': commands, 'exitCodes': codes,
           'passedAssertions': sum(line.startswith('PASS ') for line in text.splitlines()),
           'sourcesUnchanged': before == after, 'linkedSourceHashes': before,
           'logSha256': hashlib.sha256((stage/'test.log').read_bytes()).hexdigest(),
           'deviceAccess': False, 'fullApplicationBuild': False,
           'success': len(codes) == 2 and not any(codes) and before == after}
(stage/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
(stage_root/'latest.json').write_text(json.dumps({'receipt':str(stage/'receipt.json'),'success':receipt['success']},indent=2)+'\n')
print(json.dumps({**{k: receipt[k] for k in ('success','passedAssertions','sourcesUnchanged','exitCodes')}, 'receipt':str(stage/'receipt.json')}))
if not receipt['success']:
    print(text[-7000:])
sys.exit(0 if receipt['success'] else 1)
