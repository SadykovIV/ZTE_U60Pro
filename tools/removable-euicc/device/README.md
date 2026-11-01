# Explicit-target eUICC bridge

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
Both modes require a first JSON line before the card lock or QRTR is opened:

- `snapshot`: exactly `{"protocol":2,"target":"removable-euicc-slot1"}` or the
  same header with `"internal-euicc-slot2"`.
- `bridge`: the same fields plus `"expected_eid"`, a 32-digit string taken from
  the preceding snapshot. No implicit target, older protocol or extra field is accepted.

The first target binds physical1/logical1; the second binds physical2/logical2.
The immutable session target is used for open, APDU, close and card readiness;
responses include that target even for an ordinary SIM. The exact mapped pair
must be present and active, with no competing physical card on that logical slot.
A missing target is never replaced by another card. The bridge checks the route
again before returning a snapshot and checks EID on every channel reopen.
It never changes the network subscription. Profile enable and a shared radio
cycle have additional guards in the parent agent.

The internal target supports a real eUICC fitted in place of the original
soldered Chinese eSIM; it does not provision the original ZTE chip. Previous B31
hardware checks covered removable 9eSIM in slot1 and, in local 1.28, reading the
replacement card in slot2. Those checks do not validate this new bridge build or
all profile mutations. The physical SIM remains independently selectable through
the stock modem controls; concurrent mobile connections are not claimed.

A ready ordinary SIM with SELECT ISD-R status 6A82 and a
confirmed channel close returns an ordinary_sim result without a snapshot.
An exchange failure remains unknown. A process-owned card flock is released
by the kernel on exit; the bridge does not retain a global modem lock.

Snapshot mode emits the fixed stderr event `{"event":"cleanup_confirmed"}` only
after its owned channel and connection are closed without uncertain cleanup.
A normal card-read error can carry that receipt; an unknown Open/Close outcome
or a process crash cannot. The parent requires it before continuing discovery
on another target after a read failure. It contains no identifiers.
