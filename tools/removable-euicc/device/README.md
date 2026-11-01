# Internal replacement eUICC bridge

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
This alternative fixes all card operations to physical2/logical2, the route of
ZTE's embedded-SIM contacts in the saved B31 evidence. The user replaced the
original chip with a consumer eUICC; this is not support for provisioning the
original ZTE chip. The replacement wiring and full profile workflow require
hardware validation. The external physical1/logical1 SIM remains independently
usable; it is never selected as an automatic fallback by this bridge.
The bridge checks the exact physical/logical route through QMI and does not
require a firmware hash. It never chooses the network subscription; the parent
agent requires both stock selectors to report eSIM before profile enable and
again before the global radio cycle. A ready ordinary SIM with SELECT ISD-R status 6A82 and a
confirmed channel close returns an ordinary_sim result without a snapshot.
An exchange failure remains unknown. A process-owned card flock is released
by the kernel on exit; the bridge does not retain a global modem lock.
