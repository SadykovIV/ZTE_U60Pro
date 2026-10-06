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
$portableRoot = Join-Path $distRoot "portable$version"
$sourceRoot = Split-Path -Parent $projectRoot
$stageId = [Guid]::NewGuid().ToString("N")
$stageRoot = Join-Path $distRoot "portable-$version-$stageId.stage"
$exePath = Join-Path $portableRoot 'ZTE U60Pro Manager.exe'
$stageExePath = Join-Path $stageRoot 'ZTE U60Pro Manager.exe'
$zipPath = Join-Path $distRoot "ZTE-U60Pro-Manager-$version-Windows-x64-portable.zip"
$stageZipPath = Join-Path $distRoot "ZTE-U60Pro-Manager-$version-$stageId-staging.zip"
$manifestPath = Join-Path $distRoot "windows-$version-build-manifest.json"
if ((Test-Path -LiteralPath $portableRoot) -or (Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $manifestPath)) { throw "Версия $version уже собрана; существующие артефакты не перезаписываются." }

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'Для сборки требуется .NET SDK 10. Установите SDK и повторите build.cmd.'
}
if (-not (Test-Path -LiteralPath $project)) { throw "Не найден проект: $project" }
if (-not (Test-Path -LiteralPath $resourceRoot)) { throw "Не найдены ресурсы: $resourceRoot" }
if ((Test-Path -LiteralPath (Join-Path $resourceRoot 'Applications/ssclash-linux-arm64'))) {
    throw 'Публичная сборка не должна содержать исполняемый файл SSClash.'
}

if (Get-ChildItem -LiteralPath $resourceRoot -Recurse -File | Where-Object { $_.Name -eq 'trusted_known_hosts' }) { throw 'User known_hosts must not enter the public bundle.' }
$requiredResources = @(
    'Tools/adb.exe',
    'Tools/AdbWinApi.dll',
    'Tools/AdbWinUsbApi.dll',
    'Helpers/helpers.json',
    'Onboarding/SHA256.json',
    'FirmwareResearch/probes.json',
    'FirmwareSupport/collect.sh',
    'FirmwareSupport/SHA256.json',
    'Esim/zte-agent-esim',
    'Esim/gsma-rsp-roots.pem',
    'Esim/SHA256.json',
    'AgentDashboardInstall/dashboard.sh',
    'AgentDashboardInstall/payload.sha256',
    'AgentDashboardInstall/SHA256.json',
    'VPN/dashboard-install.sh',
    'VPN/payload.sha256'
)
foreach ($relative in $requiredResources) {
    if (-not (Test-Path -LiteralPath (Join-Path $resourceRoot $relative))) {
        throw "Отсутствует обязательный ресурс: Resources/$relative"
    }
}

# Validate pinned resource inputs before compiling or publishing.
foreach ($pinFile in Get-ChildItem -LiteralPath $resourceRoot -Filter 'SHA256.json' -File -Recurse) {
    $pins = Get-Content -LiteralPath $pinFile.FullName -Raw | ConvertFrom-Json
    foreach ($entry in $pins.PSObject.Properties) {
        if ($entry.Value -isnot [string] -or $entry.Value -notmatch '^[0-9a-f]{64}$' -or $entry.Name -match '(^/|\\|(^|/)\.\.(/|$))') { throw 'Malformed resource manifest.' }
        $pinnedPath = Join-Path $pinFile.DirectoryName $entry.Name
        if (-not (Test-Path -LiteralPath $pinnedPath -PathType Leaf) -or (Get-FileHash -LiteralPath $pinnedPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) { throw "Resource integrity failed: $($entry.Name)" }
    }
}
$sourceHashes = [ordered] @{}
foreach ($source in @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'src') -File -Recurse | Where-Object { $_.FullName -notmatch '[/\\](bin|obj)[/\\]' -and ($_.Extension -in '.cs', '.csproj' -or $_.Name -eq 'packages.lock.json') })) {
    $relative = $source.FullName.Substring($projectRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $sourceHashes[$relative] = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

& dotnet restore $project --runtime win-x64 --locked-mode -p:NuGetAudit=false
if ($LASTEXITCODE -ne 0) { throw "Проверка закреплённых NuGet-зависимостей завершилась с кодом $LASTEXITCODE" }
& dotnet publish $project --configuration Release --runtime win-x64 --self-contained true `
    --no-restore --output $stageRoot -p:NuGetAudit=false -p:RestoreLockedMode=true `
    "-p:PathMap=$((Split-Path -Parent $projectRoot))=/src/ZTE_U60Pro" -p:Deterministic=true -p:ContinuousIntegrationBuild=true
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

$publishedResources = @(Get-ChildItem -LiteralPath (Join-Path $stageRoot 'Resources') -File -Recurse)
if ($publishedResources.Count -ne $resourceFiles.Count) { throw 'Published resource file set differs.' }
$exeHash = (Get-FileHash -LiteralPath $stageExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$exeBytes = (Get-Item -LiteralPath $stageExePath).Length
Move-Item -LiteralPath $stageRoot -Destination $portableRoot
Write-Host "Windows x64 EXE: $exePath"
Write-Host "SHA-256: $exeHash"
Write-Host "Проверено ресурсов: $($resourceFiles.Count)"

$zipManifest = $null
if (-not $NoZip) {
    if (Test-Path -LiteralPath $stageZipPath) { Remove-Item -LiteralPath $stageZipPath -Force }
    Compress-Archive -Path (Join-Path $portableRoot '*') -DestinationPath $stageZipPath -CompressionLevel Optimal
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($stageZipPath)
    try {
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            if (-not $seen.Add($entry.FullName) -or $entry.FullName -match '(^/|\\|(^|/)\.\.(/|$))') { throw 'Invalid ZIP path or duplicate entry.' }
            $disk = Join-Path $portableRoot $entry.FullName
            if (-not (Test-Path -LiteralPath $disk -PathType Leaf)) { throw 'Unexpected ZIP entry.' }
            $stream = $entry.Open(); $digest = [System.Security.Cryptography.SHA256]::Create()
            try { $zipHash = [BitConverter]::ToString($digest.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose(); $digest.Dispose() }
            if ($entry.Length -ne (Get-Item -LiteralPath $disk).Length -or $zipHash -ne (Get-FileHash -LiteralPath $disk -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'ZIP content differs from verified portable files.' }
        }
        if ($seen.Count -ne @(Get-ChildItem -LiteralPath $portableRoot -Recurse -File).Count) { throw 'ZIP omitted portable files.' }
    } finally { $archive.Dispose() }
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
    distribution = 'public'
    windowsOsRuntimeVerified = $false
    exe = [ordered] @{ name = 'ZTE U60Pro Manager.exe'; bytes = $exeBytes; sha256 = $exeHash }
    sourcePathMap = "/src/ZTE_U60Pro"
    sources = $sourceHashes
    resources = $resourceHashes
    resourceBytes = $resourceBytes
    zip = $zipManifest
}
[System.IO.File]::WriteAllText($manifestPath,
    ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
Write-Host "Build manifest: $manifestPath"
