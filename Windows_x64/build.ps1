param(
    [switch] $NoZip
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $projectRoot 'src/ZteImeiStudio.Windows.csproj'
[xml] $projectXml = Get-Content -LiteralPath $project -Raw
$version = [string] $projectXml.Project.PropertyGroup.Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'В проекте не задана корректная версия релиза.' }
$resourceRoot = Join-Path $projectRoot 'Resources'
$distRoot = Join-Path $projectRoot 'dist'
$portableRoot = Join-Path $distRoot 'portable'
$stageRoot = Join-Path $distRoot 'portable.stage'
$exePath = Join-Path $portableRoot 'ZTE IMEI Studio.exe'
$stageExePath = Join-Path $stageRoot 'ZTE IMEI Studio.exe'
$zipPath = Join-Path $distRoot "ZTE-IMEI-Studio-$version-Windows-x64-portable.zip"
$stageZipPath = Join-Path $distRoot 'ZTE-IMEI-Studio-Windows-x64-staging.zip'
$manifestPath = Join-Path $distRoot 'windows-build-manifest.json'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'Для сборки требуется .NET SDK 10. Установите SDK и повторите build.cmd.'
}
if (-not (Test-Path -LiteralPath $project)) { throw "Не найден проект: $project" }
if (-not (Test-Path -LiteralPath $resourceRoot)) { throw "Не найдены ресурсы: $resourceRoot" }
if (Test-Path -LiteralPath (Join-Path $resourceRoot 'Applications/ssclash-linux-arm64')) {
    throw 'Публичная сборка не должна содержать проприетарный исполняемый файл SSClash.'
}

$requiredResources = @(
    'Tools/adb.exe',
    'Tools/AdbWinApi.dll',
    'Tools/AdbWinUsbApi.dll',
    'Helpers/helpers.json',
    'Onboarding/SHA256.json'
)
foreach ($relative in $requiredResources) {
    if (-not (Test-Path -LiteralPath (Join-Path $resourceRoot $relative))) {
        throw "Отсутствует обязательный ресурс: Resources/$relative"
    }
}

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

& dotnet restore $project --runtime win-x64 --locked-mode -p:NuGetAudit=false
if ($LASTEXITCODE -ne 0) { throw "Проверка закреплённых NuGet-зависимостей завершилась с кодом $LASTEXITCODE" }
& dotnet publish $project --configuration Release --runtime win-x64 --self-contained true `
    --no-restore --output $stageRoot -p:NuGetAudit=false -p:RestoreLockedMode=true
if ($LASTEXITCODE -ne 0) { throw "dotnet publish завершился с кодом $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $stageExePath)) { throw "Не создан EXE: $stageExePath" }

# Read the COFF machine field directly to catch an accidental ARM64/x86 package.
$reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($stageExePath))
try {
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'EXE не содержит заголовок MZ.' }
    $reader.BaseStream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0x40 -or $peOffset -gt $reader.BaseStream.Length - 6) {
        throw 'Некорректное смещение заголовка PE.'
    }
    $reader.BaseStream.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'EXE не содержит заголовок PE.' }
    if ($reader.ReadUInt16() -ne 0x8664) { throw 'EXE собран не для Windows x64.' }
}
finally { $reader.Dispose() }

# Resources stay beside the single-file application and must be byte-for-byte identical.
$sourcePrefix = (Resolve-Path -LiteralPath $resourceRoot).Path.TrimEnd('\', '/')
$resourceFiles = @(Get-ChildItem -LiteralPath $resourceRoot -File -Recurse)
if ($resourceFiles.Count -eq 0) { throw 'Папка Resources пуста.' }
$resourceHashes = [ordered] @{}
$resourceBytes = [ordered] @{}
foreach ($source in $resourceFiles) {
    $relative = $source.FullName.Substring($sourcePrefix.Length).TrimStart('\', '/')
    $published = Join-Path (Join-Path $stageRoot 'Resources') $relative
    if (-not (Test-Path -LiteralPath $published)) {
        throw "Ресурс отсутствует в portable комплекте: $relative"
    }
    $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
    if ($sourceHash -ne (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash) {
        throw "Контрольная сумма ресурса не совпала: $relative"
    }
    $portableRelative = $relative.Replace('\', '/')
    $resourceHashes[$portableRelative] = $sourceHash.ToLowerInvariant()
    $resourceBytes[$portableRelative] = $source.Length
}

$exeHash = (Get-FileHash -LiteralPath $stageExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$exeBytes = (Get-Item -LiteralPath $stageExePath).Length
if (Test-Path -LiteralPath $portableRoot) {
    Remove-Item -LiteralPath $portableRoot -Recurse -Force
}
Move-Item -LiteralPath $stageRoot -Destination $portableRoot
Write-Host "Windows x64 EXE: $exePath"
Write-Host "SHA-256: $exeHash"
Write-Host "Проверено ресурсов: $($resourceFiles.Count)"

$zipManifest = $null
if (-not $NoZip) {
    if (Test-Path -LiteralPath $stageZipPath) { Remove-Item -LiteralPath $stageZipPath -Force }
    Compress-Archive -Path (Join-Path $portableRoot '*') -DestinationPath $stageZipPath -CompressionLevel Optimal
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Move-Item -LiteralPath $stageZipPath -Destination $zipPath
    $zipManifest = [ordered] @{
        name = [System.IO.Path]::GetFileName($zipPath)
        bytes = (Get-Item -LiteralPath $zipPath).Length
        sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-Host "Portable ZIP: $zipPath"
}

$manifest = [ordered] @{
    schema = 1
    version = $version
    platform = 'win-x64'
    selfContained = $true
    exe = [ordered] @{ name = 'ZTE IMEI Studio.exe'; bytes = $exeBytes; sha256 = $exeHash }
    resources = $resourceHashes
    resourceBytes = $resourceBytes
    zip = $zipManifest
}
[System.IO.File]::WriteAllText($manifestPath,
    ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
Write-Host "Build manifest: $manifestPath"
