# eSIM corresponding source

- `lpac/`: lpac v2.3.0, commit c2fcf5e4b21c712d54e35a11da2ad9ad134fb821,
  https://github.com/estkme-group/lpac. Licenses are retained under LICENSES and
  src/euicc/cjson. The stdio adapter includes the exact boolean-success and
  NULL-check fixes from upstream commits 977c32431bac71adbb3aad7d4124e3154f9bdf93
  and a4150b2077fe4f253f1861a75e28cc80197ddcb2. Patch and original source are in
  `lpac-build/`; `verify_source_backport.py` verifies the supplied source.
- Public export additionally pins `cmake/git-version.cmake` to
  `v2.3.0-stdio-backports`, avoiding the enclosing application's Git tag.
  Profile/notification logic is unchanged. Only stdio APDU/HTTP drivers are built.
- QMI/ES10 bridge: `tools/removable-euicc/device/component.json` records current
  source identities. License status: `license_unspecified`; the component notice
  does not grant a license or assert sole authorship.
- Public runtime build: `tools/esim-app/build_runtime.py`; compile from the
  included source, remap host paths, record hashes, then embed both ARM64 ELF
  components in `ModemAgent/agent/resources/esim/`.
- Official production GSMA root certificates and exact source URLs/DER hashes:
  `tools/removable-euicc/certs/gsma-rsp-roots.json`. TLS hostname, expiry and chain
  verification remain enabled; these roots do not alter the eUICC trust store.

The release's eSIM-sources.tar.gz includes these files and the local derived
agent/bridge/launcher/web source, build scripts, lockfiles and licenses. It is
separate from the larger GPL toolchain/system-component source archive.

## Rebuild from the public checkout or eSIM source archive

Use Python 3, CMake, Ninja, Node.js/npm, a stable Rust toolchain with the
`aarch64-unknown-linux-musl` target, and `aarch64-linux-musl-gcc` on PATH.
The verified build used Rust 1.98.1. Run:

```sh
python3 tools/fetch_dependencies.py
cargo fetch --locked --manifest-path ModemAgent/Cargo.toml
cargo fetch --locked --manifest-path tools/removable-euicc/device/Cargo.toml
python3 tools/build.py --modem-only --tests
```

The dependency archive is pinned by SHA-256. The final command uses locked,
offline Cargo resolution, builds lpac and the bridge from source, and then
rebuilds the agent, controller, launcher, web assets and desktop resource pins.
It never contacts a modem. Build receipts are in `.build/esim/`.
An optional reference firmware ELF may be supplied via `ZTE_STOCK_UI` or
`ZTE_RUSSIAN_UI` for the launcher ABI audit; runtime B31 SHA guards remain
mandatory regardless. Rebuilt public binaries have distinct hashes and are
not represented as a repeat of the private hardware-validation run.
