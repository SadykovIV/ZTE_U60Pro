# Verified applications catalog

Signed application metadata for ZTE U60Pro Manager 1.20.0 and later.
The desktop application checks this catalog independently of application releases.
If the endpoint is unavailable, it keeps its last verified catalog or the bundled baseline.

The catalog approves specific **existing, compiled installers and exact versions**.
It never contains install commands, scripts, executable download URLs or signing
keys for package feeds. A new installer or payload version requires an application
update. Approval of a supported existing payload, descriptions, evidence summaries,
and removal of an approval can be updated independently from the application.
Manual Terminal commands remain the user's responsibility and are not catalog operations.

## Initial reviewed entries

Only htop 3.3.0-1 and the experimental opkg adapter 2022-02-24-d038e5b6-2 are
included. Their installation and startup on a physical MU5250 B31 have evidence;
the UI also shows what has **not** been tested. See
[evidence/B31-apps-20260925.md](evidence/B31-apps-20260925.md).
The catalog's approval concerns the modem payload. It does not claim execution
of the Windows client on a physical Windows machine has been verified.

iperf3, mtr and tcpdump have only VM version checks and remain excluded until
physical functional tests pass. SSClash remains excluded pending documented
physical verification. Apps already installed remain inspectable/removable even
when they are absent from the approved catalog. Rollback remains available.

## Update format and checks

- Source: `https://raw.githubusercontent.com/SadykovIV/ZTE_U60Pro/main/Catalog/verified-apps.json`.
- Detached signature: the same path with `.sig` instead of `.json`.
- JSON UTF-8 bytes are signed exactly as stored, including the final newline.
- Algorithm: ECDSA on NIST P-256 with SHA-256. The `.sig` contains Base64 of a
  64-byte IEEE-P1363 `r || s` signature. The application embeds the 65-byte
  uncompressed X9.63 public point. Public PEM is `catalog-public-key.pem`.
- Schema 1 includes a monotonic revision, UTC publication time, minimum manager
  version, Russian/English text, firmware/architecture/OpenWrt package ABI,
  tested version, evidence checksum and explicit verification scope.
- HTTPS only, fixed endpoints, redirects disabled, timeouts, 128 KiB manifest
  limit and 256-byte detached-signature limit. Downloads are streamed with a size cap.
- A signature, schema, metadata, revision and compatibility check runs before
  changing the displayed list or cache. Older revisions and same-revision changes
  are rejected. Unknown installer IDs, versions and incompatible modem profiles
  do not become installable, even with a valid signature.
- The manifest and signature are cached together in one atomically replaced
  envelope. A partial update, 404, network error or invalid signature leaves the
  last approved list intact. On startup a damaged cache falls back to the signed
  baseline embedded in the app.
- Installed-package data is always read from the modem, independently of this list.
  Firmware/identity/resource validation in each existing installer still runs.

The local cache is per user. Revision protection survives restarts while that
cache is retained; deliberate deletion of app data resets it to the bundled
baseline. This is not a defense against an attacker who controls the user's
computer. The public verification key is pinned in the application; key rotation
requires a new application release.

## Maintainer workflow — local first, no automatic publishing

1. Complete physical modem install/start/use/remove/rollback tests appropriate to
   the app. Record firmware hash/profile, ABI, exact package version and limits.
   Add an identifier-free evidence summary in `Catalog/evidence/`. Compute its
   SHA-256 and put it in the entry. Never include device IDs, passwords or backups.
2. Edit `verified-apps.json`. Increment `revision`, use the real UTC `issuedAt`,
   and retain the exact compiled installer ID/version. Both translations are required.
   Confirm the file against `verified-apps.schema.json` and the application validators.
3. Sign locally:

   ```sh
   python3 Catalog/tools/catalog.py sign Catalog/verified-apps.json
   python3 Catalog/tools/catalog.py verify Catalog/verified-apps.json
   python3 Catalog/tests/run.py
   ```

   The private key is `Catalog/private/catalog-signing-key.pem`, directory mode
   0700 / file mode 0600 and excluded by `Catalog/.gitignore`. Keep an offline
   backup. Never copy `private/` into an app, public source checkout or release asset.
   `keygen` refuses to overwrite existing keys. Do not generate a replacement for
   a catalog update: deployed applications would reject it.
4. Review exact JSON, signature, evidence and test results. Publish changes only
   with the project owner's authorization. None of these tools pushes files.
5. After authorization, publish only the JSON, `.sig`, schema, public key and
   sanitized evidence together in one commit to the public repository's `main`.
   Never publish the entire private workspace. A client encountering a mixed CDN
   revision/signature safely keeps its old catalog and can retry later.
6. A new app build may embed the new baseline using
   `python3 Catalog/tools/embed.py`; copy only public catalog assets into each
   platform's `Resources/Catalog`. This is not needed for already-shipped clients
   to receive a metadata-only update.

## Tests

`python3 Catalog/tests/run.py` builds isolated Swift/CryptoKit and .NET tests.
Tests include cross-runtime signatures, tampering, revision rollback/equivocation,
unknown installer IDs, unpinned versions, incompatible ABI, cache corruption,
offline fallback and atomic refresh behavior. A fresh temporary signing key is
used for fixtures on each run; production signatures are not distributed as test
updates. The published baseline signature is checked separately. Tests perform
no modem operations.
