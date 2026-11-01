# ZTE Agent 2.10.0-internal.1

This local alternative runs on the **ZTE U60 Pro / MU5250 modem**, Linux ARM64,
and matches **ZTE U60Pro Internal eUICC 1.28**. It manages a real eUICC wired in
place of the original soldered ZTE eSIM: QMI physical slot **2**, logical slot
**2**. The stock ZTE eSIM is not unlocked. This modified hardware has not been
tested; earlier removable-card checks on slot 1 do not validate this route.

Install the permanent agent and matching dashboard using the desktop app's
existing installation action. This **replaces the same `/data/zte-agent`
service installation**; it does not add a second permanent agent beside the
standard version. Existing installation checks, previous-file preservation and
user-setting retention remain in place. The separate archive is intended for
prepared devices and developers; it is not a firmware image or a factory-reset
installer.

## Contents

- `zte-agent`: the Internal eUICC agent with its matching embedded runtime.
- `dashboard/`: the corresponding Russian/English web dashboard.
- `dashboard-install/` and `agent-install/`: desktop installation resources.
- `esim/`: runtime, certificates, corresponding sources and component notices.
- `LICENSE`, `LICENSE-SCOPE.md`, `THIRD_PARTY_NOTICES.md`, `licenses/` and `SHA256SUMS`.

The agent API uses port **9090**; the installed dashboard uses **8080**.
The owner sets the password during installation. VPN/TTL and Launcher components
remain separate desktop installation actions. Do not mix this dashboard with
an older standard agent: the eSIM page requires target `internal-euicc-slot2`.

For the modem-screen eSIM menu, first install/update the bundled **Internal
agent** on the **Agent** page of the alternative app. Then open **eSIM** and
choose **Install/update the eSIM page**. This second action updates **Launcher**
and checks the already installed agent; it does not update the agent itself.
Updating the permanent agent alone does not update Launcher either. Launcher
uses `--esim-launcher-internal`; new Launcher/old agent and old Launcher/new
agent combinations are rejected so they cannot silently operate on another slot.

## Desktop and SIM selection

The desktop app stages and runs its bundled agent over SSH for eSIM operations;
it does **not** require the permanent agent to be installed. The alternative
desktop app keeps separate local settings. For an already prepared modem,
manually choose the existing SSH key in the app's connection settings; the key
is not automatically copied from the standard app.

Read, download, rename and disabled-profile deletion target the replacement
eUICC without changing the selected network SIM. Before enabling or rereading
an active profile, choose **eSIM** in the existing **SIM** selection menu.
The agent verifies both stock selection getters before ES10c and again before
the shared radio transition. A valid different selection yields
`esim_slot_not_selected`; unreadable or malformed state yields
`radio_read_failed`. No automatic selection, slot remap or slot-1 fallback is
performed. The physical SIM remains available through stock selection; two
simultaneously active mobile connections are not claimed.

Web profile downloads use the modem's internet connection. Desktop downloads
use the computer's internet connection. Card identity, complete profile reads,
session cleanup and post-operation checks remain required.

The local unpublished bundle is kept in `Releases/Local/1.28-internal-euicc`.
Authenticated read-only B31 network/screen diagnostics were performed, but
the new build and display fix were not deployed. There are no screenshots of
the corrected physical screen. This candidate has no replacement-card APDU
operation, corrected-screen runtime check or native Windows execution claim. See its `VERIFICATION.json` for recorded local
build/test results; historical standard-release results are separate.

[Included 1.28 release notes](RELEASE-1.28.md).
In the source tree, see `docs/INTERNAL-EUICC.md` and `docs/ESIM-APP-CONTRACT.md`.
