# Physical eUICC bridge

The complete source of the temporary ARM64 bridge used by the eSIM agent is here.
The QMI/ES10 transport is an adapted component with `license_unspecified` status.
`component.json` records the current file identities and makes no license grant
or claim of sole authorship. Existing copyright/license notices elsewhere are
retained. The wrapper adds ownership, fixed-error, selection, card identity,
bounded protocol and cleanup checks.

Build/test from the repository root with `python3 tools/esim-app/build_runtime.py --tests`.
The bridge modes `snapshot` and `bridge` are internal private-pipe protocols.
They disclose full EID/ICCID/APDU data to the authorized parent process, not to
logs. Use the desktop application or authenticated agent UI for normal operation.
No startup install hook, SIM remap or radio cycle is part of the bridge.
Supported product configuration: removable 9eSIM V0, slot1, MU5250 B31.
