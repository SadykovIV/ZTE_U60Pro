#!/bin/sh
# Native client updates the agent first; this wrapper only updates the dashboard.
set -eu
umask 077
stage=${1:-}; action=${2:-install}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$action" in preflight|install) ;; *) exit 64;; esac
agent_sha=cde0597c9595d6e5d97875976e6cce4ead450fd7771dafe1e4bb2e15441552cf
dashboard_sha=4dead6f6328490fbf7d488e90d51a3d452d9ee2e9af610a39b295b0d7e0d2d27
web_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
dashboard_installer_sha=3950353079050fef378fe6ab0dfb2d2c8423063766c8f5b7f5f3745f23041984
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
