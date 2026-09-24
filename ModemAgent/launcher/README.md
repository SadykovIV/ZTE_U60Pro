# Native launcher pages (MU5250 B31)

This optional extension runs **inside `/usr/bin/zte_topsw_devui`**. It adds two
pages to `TUFormMain`: modem information and VPN controls. The original LVGL
widgets, palette, fonts, touch pipeline, lock screen and panel orientation are
retained. The VPN row uses the native SwitchButton from Wi-Fi settings, including
its on/off styling. It is disabled during an operation and reconciles its state
with the controller response. Four page indicators replace the original two. VPN labels follow the
stock English/Russian language setting. Long profile names are truncated; they
do not scroll horizontally. Three profiles fit per view, with Previous/Next
controls for a list of up to 32.

`launcher.c` hooks five verified pointer slots of the exact B31 executable.
`build.py` can optionally audit both supported UI binaries using ZTE_STOCK_UI
and ZTE_RUSSIAN_UI paths. No stock firmware is bundled. The runtime wrapper checks the UI,
firmware, component manifest, directory permissions and device identity before
loading anything. The constructor also checks the ELF entry and program headers
before touching fixed addresses. Do not port this by changing the firmware hash.
A different UI build needs a fresh ABI analysis and device trial.

The backend worker sends bounded JSON requests to the existing `vpnctl`; it
never renders or reads arbitrary profile commands. The LVGL thread remains
nonblocking. Child processes close inherited device descriptors and have a
bounded lifetime. VPN changes use the controller's lock, validation, transaction
recovery and audit log. Profile activation requires confirmation on the screen.
The info page reads `/proc` and `/data` filesystem statistics on the modem.

## Installation and recovery

The native application bundles the library and scripts as VPN components. The
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

1. `python3 ModemAgent/launcher/build.py` (optional ABI audit: set ZTE_STOCK_UI and ZTE_RUSSIAN_UI).
2. Build `zte-vpnctl` for aarch64 musl; update `agent/src/vpn.rs`'s helper digest.
3. Build `zte-agent` and the web dashboard.
4. Run `MacIMEI/tools/package_vpn.py`, then `MacIMEI/build.sh`.

Installer tests cover first install, repeat install, failure rollback, a killed
process during directory replacement, and rejected corrupted payloads. Device
checks must additionally cover gestures, sleep/wake, original settings, profile
confirmation, network controls, and startup after reboot.
