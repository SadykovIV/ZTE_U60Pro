#!/bin/sh
# Native client updates the agent first; this wrapper only updates the dashboard.
set -eu
umask 077
stage=${1:-}; action=${2:-install}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$action" in preflight|install) ;; *) exit 64;; esac
agent_sha=076824a90eec46702744ae0f383872841d3c4704216ae32de4725f906f86a550
dashboard_sha=f26be68b30fd154e6d37872b1b3ae87cbd2f9417d37afd39c0f3cd5800d36f83
web_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
dashboard_installer_sha=6f88a16d63e9f71bc1fc6caa19eb479f4e8c0c4d613086b62fd70ed47560f90d
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
