# Test fixtures

Ordinary regression suites use synthetic IMEI, CID, EFS and credentials and do
not access a modem. Run them using the commands in [BUILD](../../docs/BUILD.md).

The optional screen-localization tests need firmware fixtures supplied by the
developer. These files must remain outside the public repository and release.
For `ScreenLocalizationTests.swift`, set `ZTE_STOCK_UI` to the original B31
`zte_topsw_devui`. Existing SHA-256 checks remain mandatory.

For `test_screen_localization.py`, set `ZTE_SCREEN_TEST_FIXTURES` to a directory
with `stock/English.ini`, `stock/Chinese.ini`, `stock/zte_topsw_devui`,
`stock/ui-init.sh`, `patched/zte_topsw_devui`, `legacy/pre-vpn-install.sh`, and
the prior localization payload directories `legacy/compact` and
`legacy/vpn-profiles`. The Python suite additionally exercises upgrades from
those historical layouts. Missing fixtures are reported explicitly.

Tests requiring OpenSSL use `openssl` from PATH; set `ZTE_OPENSSL` to choose an
OpenSSL 3 executable explicitly.
