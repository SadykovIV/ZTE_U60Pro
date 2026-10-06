#!/bin/sh
# Native client updates the agent first; this wrapper only updates the dashboard.
set -eu
umask 077
stage=${1:-}; action=${2:-install}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$action" in preflight|install) ;; *) exit 64;; esac
agent_sha=43ecb851c163a0575cdcb0e21561ae5097bb52026daac33cb46c85deba6a278d
dashboard_sha=2b2213fc52b4248d35549751cab404330246804f4b844aaf6efd78e42601bb37
web_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
dashboard_installer_sha=bc3323c05fca8ce574352d97f90b9110eb3dfac0b8025d398a31e94b62c51896
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
