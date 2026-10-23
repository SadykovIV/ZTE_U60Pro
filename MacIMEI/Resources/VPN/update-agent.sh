#!/bin/sh
# Native client updates the agent first; this wrapper only updates the dashboard.
set -eu
umask 077
stage=${1:-}; action=${2:-install}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$action" in preflight|install) ;; *) exit 64;; esac
agent_sha=26a685235b521910056fc2a3b6b9a678e000c1f8944a775158af95e03bb4e739
dashboard_sha=894fcde0b8e8e3e8f3ff4f4b4d67ac019305df47ef23b2f8fb02ab46fac9124c
web_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
dashboard_installer_sha=b26af1301f0293e21b3b41f6abf4848e57618e8776085d673444aae8ad6e610c
hash() { sha256sum "$1" | awk '{print $1}'; }
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%a' "$stage")" = 0:700 ] || exit 1
[ -f "$stage/dashboard-install.sh" ] && [ ! -L "$stage/dashboard-install.sh" ] || exit 1
[ "$(stat -c %u "$stage/dashboard-install.sh")" = 0 ]
[ "$(hash "$stage/dashboard-install.sh")" = "$dashboard_installer_sha" ]
cid=$(cat /sys/block/mmcblk0/device/cid)
# Standalone preflight permits a known old agent, but apply verifies current SHA.
reply=$(sh "$stage/dashboard-install.sh" "$stage" "$cid" "$agent_sha" "$action")
if [ "$action" = preflight ]; then
    [ "$reply" = "DASHBOARD_PREFLIGHT ${stage#/tmp/zte-vpn-agent-}" ]
    printf 'VPN_AGENT_PREFLIGHT_OK\n'
else
    [ "$reply" = "DASHBOARD_INSTALLED ${stage#/tmp/zte-vpn-agent-}" ]
    printf 'VPN_AGENT_UPDATED\n'
fi
