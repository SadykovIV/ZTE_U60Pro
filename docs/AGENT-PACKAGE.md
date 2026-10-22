# ZTE Agent 2.9.0-esim.13

This agent runs on the **ZTE U60 Pro / MU5250 modem**, on Linux ARM64. Install it with **ZTE U60Pro Manager 1.25**. The desktop application prepares SSH, installs the matching agent and dashboard, and checks the result.

Agent installation and dashboard access were checked on **Firmware `CN_ZTE_MU5250V1.0.0B31`**, **Inner `BD_CNMU5250V1.0.0B31`**. B28 and B04 were compared using supplied firmware captures and local tests; this release has no fresh hardware result for those devices. See the [release notes](RELEASE-1.25.md) for the complete verification limits. The separate agent archive is intended for developers and prepared devices; it is not a modem firmware image or a standalone factory-reset installer.

## Contents

- `zte-agent`: the agent binary, with the eSIM runtime embedded.
- `dashboard/`: the matching Russian/English web dashboard.
- `dashboard-install/` and `agent-install/`: installation resources used by the desktop application.
- `esim/`: runtime, certificates, corresponding sources, provenance and license notices.
- `LICENSE`, `LICENSE-SCOPE.md`, `THIRD_PARTY_NOTICES.md`, `licenses/` and `SHA256SUMS`.

The local agent API uses port **9090** and the installed dashboard uses **8080**. The owner sets the password during installation. VPN/TTL and launcher components are installed separately by the desktop application. Desktop operations use SSH and their own components; they do not require the permanent agent. The desktop, agent and Launcher share the modem's VPN profile catalogue, including AmneziaWG and subscription profiles.

eSIM management requires a **physical removable eUICC in the SIM slot**. Built-in ZTE eSIM is not supported. The web dashboard downloads profiles using the modem's internet connection; the desktop application can use the computer's internet connection.

[Download the desktop application](https://github.com/SadykovIV/ZTE_U60Pro/releases) · [Agent documentation](https://github.com/SadykovIV/ZTE_U60Pro/blob/main/docs/AGENT.md) · [eSIM documentation](https://github.com/SadykovIV/ZTE_U60Pro/blob/main/docs/ESIM-DESKTOP.md) · [Repository](https://github.com/SadykovIV/ZTE_U60Pro)
