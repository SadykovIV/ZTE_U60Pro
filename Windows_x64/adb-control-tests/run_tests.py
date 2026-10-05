#!/usr/bin/env python3
"""Focused ADB status/control refusal fixture; links backend sources, never starts the app or a modem transport."""
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
stage_root = repo / '.build/windows-adb-control'
stage = stage_root / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
stage.mkdir(parents=True, exist_ok=False)
source = repo / 'Windows_x64/src'
files = sorted({*source.glob('WindowsModemService*.cs'), *(source / 'Core').glob('*.cs'),
    *(source / 'Features').glob('*.cs'), *(source / 'Transport').glob('*.cs'),
    *(source / 'Research').glob('*.cs'), *(source / 'Diagnostics').glob('*.cs'),
    *((source / 'Esim').glob('*.cs'))} - {source / 'Esim/EsimQr.cs'})
files += [source / name for name in ('IModemService.cs', 'TerminalSession.cs', 'VerifiedCatalog.cs')]
files += sorted(Path(__file__).parent.glob('*.cs'))
project = stage / 'AdbControlTests.csproj'
project.write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>
<Nullable>enable</Nullable><TreatWarningsAsErrors>true</TreatWarningsAsErrors><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
<NuGetAudit>false</NuGetAudit></PropertyGroup><ItemGroup>''' +
    ''.join('<Compile Include="' + escape(str(p), {'"': '&quot;'}) + '" />' for p in files) +
    '<PackageReference Include="SSH.NET" Version="2025.0.0" /></ItemGroup></Project>\n')
fixture = stage / 'fixture'
resource_dir = fixture / 'transaction-resources/Onboarding'
resource_dir.mkdir(parents=True)
script = repo / 'MacIMEI/Resources/Onboarding/adb-toggle.sh'
shutil.copyfile(script, resource_dir/'adb-toggle.sh')
(fixture/'timeout-resources/HostTools').mkdir(parents=True)
shutil.copyfile(repo/'Windows_x64/Resources/HostTools/zte-timeout', fixture/'timeout-resources/HostTools/zte-timeout')
(resource_dir/'SHA256.json').write_text(json.dumps({'adb-toggle.sh':hashlib.sha256(script.read_bytes()).hexdigest()}))
before = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
dotnet = shutil.which('dotnet')
if not dotnet:
    raise SystemExit('dotnet is unavailable')
env = dict(os.environ, DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1', DOTNET_CLI_TELEMETRY_OPTOUT='1')
commands = [[dotnet, 'restore', str(project), '--source', str(Path.home()/'.nuget/packages'), '--ignore-failed-sources'],
            [dotnet, 'run', '--project', str(project), '--no-restore', '--', str(fixture)]]
codes = []
with (stage / 'test.log').open('w') as log:
    for command in commands:
        result = subprocess.run(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, check=False)
        codes.append(result.returncode)
        if result.returncode:
            break
after = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
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
