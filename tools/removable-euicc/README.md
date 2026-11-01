# eUICC transport for both SIM positions

The historical directory name is retained. Release 1.29 supports explicitly
selected physical1/logical1 (`removable-euicc-slot1`) and physical2/logical2
(`internal-euicc-slot2`) routes. The internal route requires a real eUICC fitted
in place of the original soldered Chinese eSIM; this does not provision the
original ZTE chip. Ordinary SIMs keep their normal modem functions.

The protocol-2 agent discovers cards and validates the selected target before
operations. The bridge accepts no implicit target or automatic fallback, never
remaps slots and never changes the network subscription. Shared radio changes
are checked independently by the parent agent. Read/download/rename/delete of a
disabled profile do not select a SIM for the network. Concurrent active mobile
connections are not claimed.

The native desktop clients stage the matched agent over SSH and use the
computer's HTTPS connection. The permanent dashboard uses the modem's internet.
See `device/README.md` for the strict private-pipe header and cleanup contract,
and `docs/UNIFIED-SIM.md` at the repository root for normal use.

Historical B31 tests include removable 9eSIM reads and the local 1.28 internal
replacement-card read, physical-SIM data and display trial. They do not validate
this new binary, every profile mutation or all firmware families. QMI/ES10 source
license status remains `license_unspecified`; existing notices are retained.
