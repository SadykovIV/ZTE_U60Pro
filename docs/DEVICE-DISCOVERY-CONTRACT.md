# Read-only device discovery

Specification revision 7 contains 46 bounded probes. The original 38 IDs remain;
8 new groups add portable technical observations. Both applications use identical
`Resources/FirmwareResearch/probes.json` bytes. The specification SHA is pinned
by each application separately.

## Separate observations from permission to act

Discovery does not require a B31/B02 firmware match, root, an installed agent,
or a successful IMEI query. It reports what the selected channel can read.
The optional firmware profile is an annotation about known component hashes.
It is not a condition for running the survey.

The `generic-access`, `preparation`, and `ssh` prerequisite cards have no profile
list or vendor Web API requirement. They observe root/Linux ARM64, procd startup,
tools, filesystem and transaction prerequisites. The existing `agent` card still
describes the profile-scoped agent/dashboard updater. This does **not** bypass installer checks,
grant write permission, or certify an installer on an unknown system. IMEI,
radio/SIM changes, screen/launcher patches, VPN integration and restore adapters
retain their operation-specific requirements. Discovery never activates ADB,
enrolls an SSH key, uploads a helper, remounts a filesystem, or starts a service.

Firmware research runs in the desktop application over SSH. It does not require
an agent diagnostic mode. The agent handles information and control requests
with authentication and operation-specific checks. The collector still records
legacy `agent_mode` metadata to interpret reports from older installations.

## Facts and observations

Commands retain the `FR_FACT key=value` protocol. Keys use lower-case letters,
digits and underscores. Values are printable, single-line, at most 512 bytes.
A fact is accepted only from an untruncated command with confirmed remote exit 0.
A duplicate/conflicting fact must not become authoritative.

The additive top-level `observations` array contains:

```json
{"id":"identity-root","title":{"ru":"Права root текущего канала","en":"Current channel root privileges"},"probe":"identity","fact":"root"}
```

There are 45 entries. The complete mapping lives in the specification, so clients
must not hardcode its count. Each report observation should retain `probe`, `fact`,
source outcome/exit status, and one of:

| Status | Meaning |
| --- | --- |
| `known` | A valid fact value was read; values such as `0`, `n`, and `present` remain known values. |
| `absent` | The source explicitly reports `missing` or `absent` after checking presence. |
| `not-assessed` | The command failed, timed out, was truncated, did not emit the fact, or emitted `not-assessed`, `unknown`, `not-performed`, or `conflicting`. |

In particular, permission denial and an unavailable tool are not evidence that
hardware, a service, or a file is absent. `_present=0` and similar booleans are
known negative observations, not missing results. Kernel config `y`/`m` describes
a build setting; a process name or device node does not prove usable service ABI.
A filesystem's `rw`/`exec` flags do not prove a write or launch would succeed.

## Fingerprints and transport continuity

The `fingerprint` probe completes with exit 0 when identifiers or hash tools are
unavailable. Its fields are:

- `cid_sha256`: 64 lower-case hexadecimal characters, `missing`, or `not-assessed`;
- `boot_sha256`: the same format;
- `hasher`: `sha256sum`, `busybox-sha256sum`, or `not-assessed`.

The fallback checks the BusyBox SHA-256 applet using empty stdin. Raw CID and boot
identifiers are never emitted. An unreadable identifier or failed hash command
produces `not-assessed`; an absent file is reported only if its containing
directory is searchable and readable. No hash tool leaves existing files
`not-assessed`.

Platform collectors manage continuity independently of the spec:

1. Compare every available initial device/boot fingerprint before and after probes.
2. If only one is available, state that the binding is partial.
3. If neither is available, a survey may be tied only to the explicitly selected
   USB ADB transport or a strictly verified SSH endpoint. Mark it `transport-only`.
   It does not establish physical-device identity or an unchanged boot session.
4. Stop on an observed mismatch, ambiguous device selection, lost transport, or
   failed SSH trust. Never select another device or silently switch transports
   midway through a report. An absent fingerprint is not permission for writes.

These are collector requirements, not additional shell mutation commands.
Existing write operations keep their own stronger identity requirements.

## Added coverage

| Probe | Bounded source and result |
| --- | --- |
| `discovery-tools` | Presence of a fixed set of shell, parsing, ELF and system tools. No installation. |
| `elf-abi` | First 64 bytes of seven fixed regular executables: class, endianness, machine, type. Optional `readelf -l -d /bin/sh` reports an allowlisted interpreter path and NEEDED basenames. No `ldd` or executable launch. |
| `init-runtime` | PID 1 comm, standard init and loader paths. Unknown init names are valid observations. |
| `startup-structure` | Presence/metadata of fixed startup locations; `sh -n` for a regular readable rc.local; bounded observation of the procd `done` script's rc.local invocation. No source/execution or script body output. |
| `kernel-config` | A fixed set of config flags from readable `/proc/config.gz`, bounded decompression with exit proof. Runtime namespace/cgroup/SELinux path presence separately. |
| `hardware-metadata` | Standard DT compatible, remoteproc state/count, QRTR/RPMsg/USB/display path presence. At most 16 remoteproc entries. No character devices opened. |
| `api-surface` | `ubus list` and schemas of ten fixed objects; only method names are emitted, not method argument values. No discovered method is called. |
| `runtime-security` | Selected process/seccomp and standard kernel-security numeric fields. No process argv, environment, or memory. |

The existing probes also change:

- `identity` uses the effective UID in `/proc/self/status` if `id` is unavailable;
  kernel architecture/version do not imply a supported application ABI.
- `release` keeps the two confirmed ZTE public version fields from revision 6;
  lack of awk does not suppress the independent bounded ubus/jsonfilter branch.
- `runtime-libraries` reports fixed-path presence even without hashing/stat tools.
- `partitions` enumerates `/sys/class/block/*`, including non-mmc0 names, up to
  128 entries; only numeric sysfs metadata and constrained partition names.
  No partition content is opened. The old B31 layout fact remains adapter-only.
- `mounts` emits selected filesystem types and flags, never raw sources or
  arbitrary mount/superblock options that could contain credentials.
- `kernel-health` and `service-health` capture at most 128 KiB privately, verify
  producer exit, and emit only counts. Raw log lines are not exported.
- Missing optional tool groups return `probe_tools=not-assessed`; unrelated
  probes continue. A missing kernel metadata source is not reported as `0`.
- The older hash probes reject symlink targets and distinguish read failure from
  confirmed absence. Failed UCI lookups, unreadable route/TTL sources and unknown
  pending-operation ancestry remain `not-assessed`.
- Both API schema probes export only fixed method names. VPN library discovery
  reports file/tool presence and leaves Lua loadability unassessed: it does not
  execute vendor Lua modules or vendor programs to infer compatibility.

## Bounds and privacy

Each command has its own timeout/output limit. Most limits are 12 seconds and
32 KiB; API schema discovery is capped at 60 seconds. The collector must also
apply its global deadline and total-byte cap. Internal capture helpers accept at
most 128 KiB including their producer-status trailer. Truncation loses the exit
proof and therefore cannot produce a complete assessment.

No raw NV/EFS, SIM/APDU traffic, partition contents, credentials, configuration
backups, startup bodies, process arguments/environment, private keys, or personal
network traffic are collected. The standard `zwrt_web device_info` call remains
read-only and exports only the two selected version fields; its full reply and
stderr stay private. Device-tree model/serial fields and arbitrary vendor proc
nodes are not read. In particular, sensor_id/codec_id retain metadata-only handling.

This is a finite survey of known read interfaces, not exhaustive hardware
verification. Unknown service layouts and absent inspection utilities remain
explicitly unassessed. No result alone certifies eSIM, DIAG, backup restoration,
network registration, or a successful future installation.

## Offline verification

Run from the repository root:

```sh
python3 MacIMEI/Tests/test_device_discovery_probes.py
```

The fixtures execute the exact spec commands with rewritten fixed filesystem
roots and fake utilities. They verify mirrors/schema, shell syntax, no fixture
writes, missing tools/identifiers, BusyBox hashing, hash read failure, non-root
UID fallback, unknown init, ELF32/64 in both byte orders, malformed ELF, generic
block inventory and limits, selective kernel config, bounded log/mount/API
privacy, and metadata-only hardware coverage. They do not contact a modem or
establish runtime compatibility on a new firmware.
