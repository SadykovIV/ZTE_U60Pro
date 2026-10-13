from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[2]
stage=root/'.build/radio-host-tests';stage.mkdir(parents=True,exist_ok=True)
project=stage/'Tests.csproj'
files=[root/'Windows_x64/src/Diagnostics/FirmwareRadioSupport.cs',root/'Windows_x64/tests/FirmwareRadioSupportTests.cs']
project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><EnableDefaultCompileItems>false</EnableDefaultCompileItems><TreatWarningsAsErrors>true</TreatWarningsAsErrors></PropertyGroup><ItemGroup>'+''.join('<Compile Include="'+str(p)+'"/>' for p in files)+'</ItemGroup></Project>')
subprocess.run(['dotnet','run','--project',str(project),'--',str(root/'Windows_x64/Resources')],check=True,cwd=root)
