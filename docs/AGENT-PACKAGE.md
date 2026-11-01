# ZTE Agent 2.11.0

This package runs on the **ZTE U60 Pro / MU5250 modem**, Linux ARM64, and matches
**ZTE U60Pro Manager 1.29**. It includes the agent, web dashboard, eUICC runtime,
installation resources, licenses and SHA-256 checksums.

It supports the existing modem controls with a single SIM, the stock dual-SIM
configuration, or a real eUICC soldered in place of the original Chinese eSIM.
Confirmed eUICCs are addressed explicitly as `removable-euicc-slot1`
(physical1/logical1) or `internal-euicc-slot2` (physical2/logical2).
There is no automatic SIM remapping, network-SIM switching or fallback to a
different card. Custom profile provisioning on the original ZTE chip is not
implemented; an ordinary SIM does not store downloadable eSIM profiles.

Use the matching desktop app's **Agent** page to install/update the permanent
agent and dashboard. The existing service location `/data/zte-agent` is updated;
this is not a second parallel service. Previous files and validated interrupted
installation state are handled by the standard installer.

For the modem-screen eSIM page, first update the bundled agent, then use
**eSIM → Install/update eSIM page**. The second action updates Launcher and checks
the installed agent; it does not install the agent itself. Launcher uses
`--esim-launcher-v2`. Do not mix an old Launcher or dashboard with this agent.

Desktop card operations stage the bundled agent over SSH and do not require a
permanent installation. Desktop downloads use the computer's internet; web
operations use the modem's connection. Fresh card/route checks and explicit
protocol-2 targets bind operations to the intended card. Enabling a profile
also requires compatible firmware and an independently verified network-SIM
selection before the shared radio cycle.

Verify the included `SHA256SUMS` before deployment. Build and prior hardware
checks are separate: see the release `VERIFICATION.json`. Historical B31 tests
include external and replacement-internal card reads; they do not validate all
profile mutations, a new binary, other firmware families or native Windows.
The local 1.28 trial confirmed physical-SIM HTTPS, but internal-eUICC internet
requests failed and that connectivity remains unverified.

[Included 1.29 release notes](RELEASE-1.29.md).
In the source tree, see `docs/UNIFIED-SIM.md` and `docs/ESIM-APP-CONTRACT.md`.
