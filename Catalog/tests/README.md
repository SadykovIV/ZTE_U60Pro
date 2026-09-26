# Catalog validation tests

Run `python3 Catalog/tests/run.py` on macOS with Swift, .NET 10 and OpenSSL.
No modem access, catalog downloads or production private key are required.

The runner first verifies the shipped catalog with the production **public** key,
checks that both applications pin the same key, payload and signature, and confirms
that modified data is rejected.

It then creates a temporary P-256 test key and signs the unsigned JSON fixtures
inside a temporary directory. The Swift and C# source files are copied there;
only the pinned public key and baseline signature constants are replaced in those
copies. The baseline payload, validators, cache and update code remain unchanged.
The 19 Swift and 21 .NET checks cover signature tampering, rollback, conflicting
revisions, installer/version/ABI restrictions, cache corruption and failed updates.

The public fixtures intentionally contain **no signatures or private keys**.
They cannot be replayed as release updates. The temporary key, signatures and build
output are deleted after the run. Production sources and the working catalog are
never modified. Re-run this workflow when the validators or catalog format change.
