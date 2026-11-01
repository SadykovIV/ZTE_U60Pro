#!/bin/sh
# Native client updates the agent first; this wrapper only updates the dashboard.
set -eu
umask 077
stage=${1:-}; action=${2:-install}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$action" in preflight|install) ;; *) exit 64;; esac
agent_sha=2ec45ff1e10ceed0029de9b77740c95185b19b4d068a9153555ade0686babd3e
dashboard_sha=78ba7ec3999da9a45587205fd14c30e50ed5d7d352553a7ed3bf5e8c331d6bd4
web_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
dashboard_installer_sha=66427db47c9554b7c1630731ec2f0990029d7558f1f5eda092996fea8edc19c6
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
