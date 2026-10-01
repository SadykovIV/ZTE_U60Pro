# Public Windows checks

These fixtures use synthetic values and fake transports. They neither connect
to a modem nor exercise real profile mutations. The UI suites execute the actual
Avalonia assembly on macOS arm64; they do not verify Windows OS runtime.

From the repository root, with public resources already built and synced:

```sh
python3 Windows_x64/sync_public_resources.py --check
dotnet build Windows_x64/src/ZteImeiStudio.Windows.csproj -c Debug -r osx-arm64 \
  --self-contained false -p:PublishSingleFile=false -p:NuGetAudit=false \
  -p:NuGetLockFilePath="$PWD/Windows_x64/ui-smoke/host.packages.lock.json" \
  -p:RestoreLockedMode=true
dotnet run --project Windows_x64/tests/WindowsCoreTests.csproj
dotnet run --project Windows_x64/research-tests/ResearchTests.csproj
dotnet run --project Windows_x64/card-recovery-tests/CardRecoveryTests.csproj -- "$PWD"
dotnet run --project Windows_x64/esim-tests/EsimTests.csproj
dotnet run --project Windows_x64/card-recovery-pages-tests/PageTests.csproj
dotnet run --project Windows_x64/ui-smoke/UiSmoke.csproj
```

The backup test uses only `test-only-backup-key-suffix`. Launcher tests check
old public VPN status-only recognition, refusal of unknown agents before VPN
writes, exact preserved page order, atomic guards and the masked suffix field's
request/clear behavior. eSIM tests include 51 allowlisted component codes,
framed RPC, manual input, synthetic QR images and confirmation/secret cleanup.

After publishing with `Windows_x64/build.ps1`:

```sh
python3 Windows_x64/public-tests/verify_package.py \
  --output .build/windows/package-verification.json
```

The verifier checks compiled input hashes, exact resource coverage, current
Mac/Windows pins, PE x64, every ZIP entry and CRC. It refuses private-only
payload filenames and workspace paths in the EXE. Generated test results and
preview PNGs are excluded from source tracking.
