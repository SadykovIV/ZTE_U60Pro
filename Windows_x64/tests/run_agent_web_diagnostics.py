from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
stage = root / '.build/agent-web-tests'
stage.mkdir(parents=True, exist_ok=True)
files = [root / 'Windows_x64/src/Diagnostics/AgentWebDiagnostics.cs', root / 'Windows_x64/tests/AgentWebDiagnosticsTests.cs', root / 'Windows_x64/src/Localization.cs']
project = stage / 'Tests.csproj'
project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NuGetAudit>false</NuGetAudit><EnableDefaultCompileItems>false</EnableDefaultCompileItems><TreatWarningsAsErrors>true</TreatWarningsAsErrors></PropertyGroup><ItemGroup>' + ''.join('<Compile Include="' + str(p) + '"/>' for p in files) + '<EmbeddedResource Include="' + str(root / 'Windows_x64/Resources/Localization/en.json') + '" LogicalName="ZteManager.Localization.en.json" /></ItemGroup></Project>')
subprocess.run(['dotnet', 'run', '--project', str(project)], check=True, cwd=root)
