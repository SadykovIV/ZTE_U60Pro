Read-only firmware adaptation tools

The desktop app uploads these ARM64 Linux tools to a private temporary directory
through the selected SSH connection, runs them sequentially, and removes them.
No installed agent is required. NV/config writes are excluded from the C builds.
Only response metadata and validation results are exported, never device records.
QMI queries: DMS GetOperatingMode, UIM GetCardStatus and GetSlotsStatus.
No slot switching, APDU, eSIM download, radio reset or IMEI change is performed.
These queries do not establish support for IMEI writes or eSIM provisioning.

For both SIM variants, collect separate archives with each selected and ready.
QMI reports numerical slot references without guessing physical/built-in routing.
Unsupported requests are recorded as unavailable, not as an empty card/profile.

Sources and build scripts: support-sources.tar.gz.
Build C tools: python3 MacIMEI/DeviceHelpers/build_support.py
Build QMI tool: python3 tools/radio-inspect/build.py
Package: python3 tools/radio-inspect/package_resources.py
Requirements: aarch64-linux-musl-gcc, Rust musl target, pinned Cargo dependencies.
QMI transport notice: NOTICE-QMI.txt; its upstream license is unspecified.
