# Native launcher pages (MU5250 B31)

This optional extension runs **inside `/usr/bin/zte_topsw_devui`**. It adds a selectable ordered set of up to three pages to `TUFormMain`: modem
information, VPN controls and physical removable-eUICC profiles. The original LVGL
widgets, palette, fonts, touch pipeline, lock screen and panel orientation are
retained. The VPN row uses the native SwitchButton from Wi-Fi settings, including
its on/off styling. It is disabled during an operation and reconciles its state
with the controller response. Page indicators follow the selected count (two stock pages plus zero to three extras). VPN labels follow the
stock English/Russian language setting. Long profile names are truncated; they
do not scroll horizontally. Three profiles fit per view, with Previous/Next
controls for a list of up to 32.

`launcher.c` hooks five verified pointer slots of the exact B31 executable.
`build.py` checks both supported UI binaries (original and Russian font patch)
against their hashes and the expected slots. The runtime wrapper checks the UI,
firmware, component manifest, directory permissions and device identity before
loading anything. The constructor also checks the ELF entry and program headers
before touching fixed addresses. Do not port this by changing the firmware hash.
A different UI build needs a fresh ABI analysis and device trial.

The backend worker sends bounded JSON requests to the existing `vpnctl`; it
never renders or reads arbitrary profile commands. The LVGL thread remains
nonblocking. Child processes close inherited device descriptors. VPN commands have a bounded
lifetime; an eSIM operation is drained through its own cleanup without UI timeout kills. VPN changes use the controller's lock, validation, transaction
recovery and audit log. Profile activation requires confirmation on the screen.
The info page shows CPU busy percentage sampled from `/proc/stat`, radio signal,
RAT, active component carriers with band labels, and separate CPU/modem
thermal sensors. A separate read worker is requested only while the added pages
are visible; it never waits on long VPN actions. Missing/stale values are explicit.
The radio parser counts serving/active carriers, not configured bands or band locks.
CPU temperature uses named `cpuss-*` sensors; modem temperature uses `mdmq6-0`.
Pure telemetry and formatting fixtures run on the host without a modem.

## Configurable information page

The native app edits `/data/zte-launcher/info-layout.conf`. The strict ASCII v2
format has header `ZTE_INFO_LAYOUT_V2`, followed by `style=list` or `style=tiles`,
and exactly twelve unique `id=0|1` lines:
`cpu`, `signal`, `network`, `carriers`, `cpu_temp`, `modem_temp`, `memory`,
`storage`, `uptime`, `battery`, `rsrq`, `sinr`. Every line ends with LF.
Line order is screen order; 1–12 items may be enabled. The list style with the
first six metrics is the default. Legacy `ZTE_INFO_LAYOUT_V1` with exactly nine
old fields remains readable: its order is preserved, the style is list, and
the three new fields are appended disabled. Unknown/duplicate fields, malformed bytes,
unsafe file metadata or missing files fall back to that default. Files must
be root-owned regular files, mode0600, one link, at most512 bytes. Reading is
bounded and uses nofollow directory/file descriptors. This is data, never code.

Title and status stay fixed. A native vertical viewport at x0/y76, width320,
height346 holds the selected cards. In list mode the default six end at y417
as before; all twelve produce671px of content and325px of vertical travel.
Carriers use a66px card in any position, other rows48px, gaps7px. In tiles mode,
cards are141×106px in two columns with a10px gap, at x14 and165; order is
left-to-right then top-to-bottom. Six tiles produce338px of content and fit the
viewport; twelve produce686px and340px of vertical travel. Grid titles are
compact, while values/units/sources wrap within the card. The carrier title
retains the count; at most four bounded lines show bands, with an ellipsis for
truncation. Horizontal gestures still
chain to the main page carousel; vertical releases retain native momentum.
Order, selection or style changes reset the viewport once; telemetry updates do not reset it.
The scrollbar appears when content exceeds the viewport. Both B31 reference binaries and the
constructor verify the new scroll function addresses before use.

Memory uses `MemTotal - MemAvailable` from `/proc/meminfo`; storage uses used/total
blocks from `statvfs("/data")`; uptime uses `/proc/uptime`. Values are sampled
with the independent telemetry worker, so absent or slow VPN cannot block them.
Hidden metrics do not contribute to the displayed missing/stale status. The
layout reloads on visible, awake refresh and survives a restart or upgrade.

Battery percentage and charging status are read together from the existing
`/sys/class/power_supply/battery/{capacity,status}` files. Accepted statuses
are Charging, Discharging, Not charging, Full and Unknown. Unknown is explicitly
shown as an unavailable status; absent/malformed sources retain only a marked
stale previous sample, never a fabricated percentage.

RSRQ and SINR use the same read-only `ubus call zte_nwinfo_api
nwinfo_get_netinfo '{}'` sampling as the existing radio metrics. The B31 fields
are `lte_rsrq`, `lte_snr`, `nr5g_rsrq` and `nr5g_snr`, in direct dB, displayed to
one decimal place. The agent's signal logger exposes the firmware SNR fields as SINR.
A current serving band, PCI, channel and plausible RSRP must establish the
radio before its quality fields are accepted. The active NR serving cell wins
in NSA; otherwise the LTE anchor is used. Each value identifies LTE or NR.
Missing NR quality does not silently substitute LTE while NR is active. This
avoids treating the stock inactive-NR zero placeholders as measurements, while
preserving valid zero dB readings from an active cell. Nonfinite, malformed and
out-of-range values are unavailable/stale under the existing12-second policy.
The parser tests are self-contained; fixture values are never runtime fallbacks.

The host tests cover164 telemetry checks,30 formatting groups and98,280
selection/order/style/parser combinations (every nonempty selection in twelve
cyclic orders, for both styles). They verify V1 migration, V2 validation,
nonoverlap, horizontal bounds, last-card scroll reachability and malformed
configuration fallback. AddressSanitizer/UndefinedBehaviorSanitizer are used
for those checks; touch behaviour still requires a real-device trial.

## Installation and recovery

The native application bundles the library and scripts and exposes them in its
«Лаунчер» section. Existing VPN integration is upgraded as a matching
controller/agent/display set so its library pin remains valid. The
installer must hold the common application lock. It stages verified files and
backs up the original startup configuration before replacing the component.
An interrupted directory swap is recovered on the next attempt. The stock UI
binary, its init script, translation dictionary and profile store are not edited.

`launcher-start.sh` is called from `rc.local`; it starts a procd watcher. The
watcher applies a wrapper to the stock procd instance using `ubus`, under the
common lock, with the original respawn policy. It waits through translation
operations and temporary screen trials. The wrapper checks DRM has been released
before starting the original executable with the extension. Failed page creation
or repeated UI restarts write a failure marker and return the service to the
plain stock command. Reinstalling the component clears that marker.

The agent's screen actions now queue a page number in a private runtime directory.
They never stop the original launcher or open DRM. Requests made during sleep
are processed when the display wakes; the stock lock screen remains in force.
The former standalone DRM prototype under `vpnctl/screen` is no longer built.

## Build

1. `python3 ModemAgent/launcher/build.py` (requires local reference UI binaries).
2. Build `zte-vpnctl` for aarch64 musl; update `agent/src/vpn.rs`'s helper digest.
3. Build `zte-agent` and the web dashboard.
4. Run `MacIMEI/tools/package_vpn.py`, then `MacIMEI/build.sh`.

Installer tests cover first install, repeat install, failure rollback, a killed
process during directory replacement, rejected corrupted payloads, preserved layout on upgrades/rollback, and unsafe
layout paths. Device
checks must additionally cover gestures, sleep/wake, original settings, profile
confirmation, network controls, and startup after reboot.


VPN network labels use the controller's actual `ssid`, `ssid_2g` and `ssid_5g` status values. Different guest names are displayed on two lines with 2.4G/5G labels; unavailable status is explicit. The launcher does not substitute a default name and installing it does not rename an existing network.

## Physical eUICC page

The fifth stock-launcher page lists profiles from the physical eUICC in SIM
slot 1. It requires the matching eSIM agent at `/data/zte-agent`. Ordinary SIMs
and ZTE's built-in card are outside this feature. Installation and deletion
remain in the desktop application and authenticated web panel.

`esim-backend.c` runs one independent worker. It sends one protocol-1 NDJSON
request to `--esim-launcher`, retains the full card snapshot only in memory,
and binds confirmation to both ICCID and snapshot generation. Profile names
are bounded and controls removed; only the last four ICCID digits are shown.
A selected active profile requests a reread without a second enable command.
The child is never killed on a launcher timeout or parent death. Output is
bounded per line and drained to EOF before the final exit status is accepted.
A successful enable requires both `modem_verified` and `radio_restored` from
the shared backend. This proves SIM identity and radio mode, not registration
or working mobile Internet. SIGKILL, power loss and unrelated modem services
are outside the cleanup guarantee.

The installer also accepts `STAGE preflight`. It validates the staged files,
current installation, layout and firmware without recovering a transaction or
changing files/services. It returns exactly `LAUNCHER_PREFLIGHT_OK`. A pending
transaction must be resolved by the existing apply/recovery path first.

## Page selection and eSIM reading (1.23.1)

Mac and Windows show page checkboxes and up/down order controls under Install tiles.
See [PAGE-LAYOUT.md](PAGE-LAYOUT.md) for the exact root600 data format. Stock Home
and Settings remain first; an empty set has only those two pages. Changes are
read while the screen is awake. Name-based navigation resolves the current order
when consumed, so a simultaneous reorder cannot open a different extra page.

The eSIM page supports only a physical removable eUICC in the SIM slot. It lists
profiles, asks for confirmation, then enables once and cycles offline/online to
verify the modem's fresh ICCID. Download and deletion are in the desktop/web UI.
The last valid list stays visible after read failure as a saved list; activation
requires a fresh snapshot. Unknown failures stop automatic polling; only the
known pre-operation busy code gets one automatic read retry. A failed activation
is not automatically retried. Refresh is explicit on the screen.

The eSIM transport uses a private broker and complete child exit proof to survive
stock SIGCHLD reaping. Reads/writes resume after EINTR. The broker never kills the
agent on UI exit. Fixed diagnostics (no card IDs or protocol bodies) are written
to `/tmp/zte-launcher/esim-status`; the latest failure is retained separately in
`esim-error` and reported to syslog. These files are private and lost on reboot.
