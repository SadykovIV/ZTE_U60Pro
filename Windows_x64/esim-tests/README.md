# Windows eSIM tests

Run from the repository root with .NET SDK 10:

```sh
dotnet build Windows_x64/src/ZteImeiStudio.Windows.csproj -r osx-arm64 \
  -p:SelfContained=false -p:PublishSingleFile=false -p:NuGetAudit=false \
  -p:NuGetLockFilePath="$PWD/Windows_x64/ui-smoke/host.packages.lock.json" \
  -p:RestoreLockedMode=true
dotnet restore Windows_x64/esim-tests/EsimTests.csproj -p:NuGetAudit=false
dotnet run --project Windows_x64/esim-tests/EsimTests.csproj --no-restore
```

The harness references the built desktop assembly and uses synthetic card identities only.
It never invokes SSH or a modem. The normal run covers serialized request compatibility,
manual SM-DP+/Matching ID input, framed RPC success/failure and postconditions, HTTP policy,
the pinned certificate, real synthetic PNG decoding, and the actual RU/EN Avalonia eSIM page.
Results and screenshots are written to `results/`.

The optional `--tls-smoke` argument makes one empty HTTPS POST to the public root URL
`https://rsp.invigo.com/`; it records only status and byte count, never response content.
It sends no card identifier, activation code or operator session. This is a network test,
not a modem or profile operation. The normal test run does not invoke it.

These tests run on macOS ARM64. They do not establish a successful Windows OS launch.
