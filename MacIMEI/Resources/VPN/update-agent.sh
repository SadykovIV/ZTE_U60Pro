#!/bin/sh
# Update agent/dashboard while preserving existing authentication and backups.
set -eu
umask 077
stage=${1:-}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
ROOT=/data/zte-vpn
agent_sha=542072a91b46c9b789c249d195a6dc2cf649416c6b96448855ff710f7b797fda
dashboard_sha=dcac5e1a093f3e277c2985eaa97817d08a1f2cab824c48ffd24589c39b1a7f3a
web_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
hash() { sha256sum "$1" | awk '{print $1}'; }
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%a' "$stage")" = 0:700 ]
"$ROOT/vpnctl" integrity >/dev/null
[ -f /data/local/tmp/start_zte_agent.sh ] && [ ! -L /data/local/tmp/start_zte_agent.sh ]
[ "$(stat -c %u /data/local/tmp/start_zte_agent.sh)" = 0 ]
sh -n /data/local/tmp/start_zte_agent.sh
for file in zte-agent dashboard.tar.gz dashboard-uhttpd agent-transaction.sh start-dashboard.sh dashboard-html.sh preserve-dashboard-assets.sh stop-owned-listener.sh update-rc-local.sh; do
    [ -f "$stage/$file" ] && [ ! -L "$stage/$file" ]
done
[ "$(hash "$stage/zte-agent")" = "$agent_sha" ]
[ "$(hash "$stage/dashboard.tar.gz")" = "$dashboard_sha" ]
[ "$(hash "$stage/dashboard-uhttpd")" = "$web_sha" ]
case "$(hash /data/zte-agent)" in d3fd8a8316eb1f63d6e737ef99f8cf7e3a2946cf80acb8df6c3d8bd16911bce4|0563f12c64311bf1058cd3a4136a0b328d07e1cba7b8e92b962ec5bf3c7e4215|b082c8dfc8238d73dc0bdee7453cd60e0816f7f16b2febbf42d16ac7b6bfd466|07154bffefb022eff87c46deb51b73501110edd6e6bf9248ccbec248b2fbe56e|f2e0404c2c1be4c058c27b0a19c99c1d380e1c91d61503661424d53e799e235b|b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537|5deb5e93ee7d37403b0a931f0e127c64e4d9b4825855653e5b890572b02848aa|ec4c21f70c666d28b016445eb9ab391e05d21b0974d3c6553671aa73acd183da|"$agent_sha") ;; *) echo VPN_AGENT_UNKNOWN_BUILD >&2; exit 1;; esac
if [ -e /data/bin/dashboard-uhttpd ]; then
    [ ! -L /data/bin/dashboard-uhttpd ] && [ "$(hash /data/bin/dashboard-uhttpd)" = "$web_sha" ]
fi
[ ! -e /data/local/tmp/open-u60-transactions/active ]
id=${stage#/tmp/zte-vpn-agent-}
identity=$(hash /sys/block/mmcblk0/device/cid)
cp "$stage/agent-transaction.sh" "$ROOT/agent-transaction.sh"
chmod 700 "$ROOT/agent-transaction.sh"
sh "$ROOT/agent-transaction.sh" begin "$id" "$identity"
committed=0
finish() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$committed" = 0 ]; then sh "$ROOT/agent-transaction.sh" restore "$id" "$identity" > "$ROOT/agent-recovery.log" 2>&1 || true; fi
    exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
if [ "$(hash /data/zte-agent)" != "$agent_sha" ]; then
    cp "$stage/zte-agent" /data/zte-agent.vpn-new
    chmod 700 /data/zte-agent.vpn-new
    for pid in $(pidof zte-agent 2>/dev/null || true); do
        case "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" in /data/zte-agent|'/data/zte-agent (deleted)') kill "$pid";; esac
    done
    sleep 1
    mv /data/zte-agent.vpn-new /data/zte-agent
    sh /data/local/tmp/start_zte_agent.sh
fi
mkdir -p /data/bin /data/open-u60-dashboards
if [ -e /data/bin/dashboard-uhttpd ]; then
    [ ! -L /data/bin/dashboard-uhttpd ] && [ "$(hash /data/bin/dashboard-uhttpd)" = "$web_sha" ]
else
    cp "$stage/dashboard-uhttpd" /data/bin/dashboard-uhttpd
    chmod 755 /data/bin/dashboard-uhttpd
fi
target=/data/open-u60-dashboards/$id
mkdir "$target"
tar -xzf "$stage/dashboard.tar.gz" -C "$target"
test -s "$target/index.html"
cp "$target/index.html" "$target/mobile.html"
previous=/data/www
if [ -L /data/www.current ]; then previous=$(readlink -f /data/www.current); fi
sh "$stage/preserve-dashboard-assets.sh" "$previous" "$target"
chmod -R a+rX "$target"
ln -s "$target" /data/www.current.vpn-new
mv -Tf /data/www.current.vpn-new /data/www.current
cp "$stage/stop-owned-listener.sh" /data/local/tmp/stop_open_u60_listener.sh
cp "$stage/start-dashboard.sh" /data/local/tmp/start_dashboard.sh
cp "$stage/dashboard-html.sh" /data/local/tmp/dashboard-html.sh
cp "$stage/update-rc-local.sh" /data/local/tmp/open-u60-rc-update.sh
chmod 700 /data/local/tmp/dashboard-html.sh /data/local/tmp/stop_open_u60_listener.sh /data/local/tmp/start_dashboard.sh /data/local/tmp/open-u60-rc-update.sh
sh /data/local/tmp/open-u60-rc-update.sh 'sh /data/local/tmp/start_zte_agent.sh' 'sh /data/local/tmp/start_dashboard.sh'
sh /data/local/tmp/start_dashboard.sh
sleep 2
found=0
for pid in $(pidof zte-agent 2>/dev/null || true); do
    [ "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" != /data/zte-agent ] || found=1
done
[ "$found" = 1 ]
curl --fail --silent --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/ | grep -q '<div id="root"></div>'
curl --fail --silent --connect-timeout 3 --max-time 8 -D - -o /dev/null http://127.0.0.1:8080/ | grep -qi '^Cache-Control: no-store'
sh "$ROOT/agent-transaction.sh" complete "$id" "$identity"
committed=1
echo VPN_AGENT_UPDATED
