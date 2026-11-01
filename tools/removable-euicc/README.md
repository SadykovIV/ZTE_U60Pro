# Internal eUICC transport variant

This directory retains its historical `removable-euicc` path, but the **1.28
Internal eUICC** variant targets a real eUICC fitted in place of the original
soldered ZTE eSIM: QMI physical slot **2**, logical slot **2**. It does not
unlock the original card and does not fall back to the physical SIM slot.

The bridge performs fresh card and route checks, owns its logical channel,
and confirms cleanup. EID and the complete profile list establish an eUICC;
a QMI flag alone does not. Only initial SELECT ISD-R `6A82` with confirmed
channel cleanup identifies an ordinary SIM. Read errors leave the type unknown.

Card-only operations are independent of the modem's stock network SIM selection.
Profile enable also requires the stock selection to be eSIM before ES10c and
again before the shared radio transition. Those checks belong to the agent;
the bridge never changes SIM mapping or network selection. The ordinary SIM
slot remains usable through the stock controls. This is not dual-active support.

Build/test from the repository root:

```sh
python3 tools/esim-app/build_runtime.py --tests
```

The `snapshot` and `bridge` protocols are private pipes for the parent agent.
Use the existing authenticated eSIM menu for normal operations. Card identifiers,
APDUs and activation secrets must not enter diagnostic logs.

The historical hardware reference is removable 9eSIM V0 in slot 1 on MU5250 B31.
The replacement eUICC in slot 2 has not been tested on hardware. QMI/ES10 source
attribution and `license_unspecified` status remain documented in
`device/component.json` and existing component notices.

[Variant guide](../../docs/INTERNAL-EUICC.md) ·
[Operation contract](../../docs/ESIM-APP-CONTRACT.md)
