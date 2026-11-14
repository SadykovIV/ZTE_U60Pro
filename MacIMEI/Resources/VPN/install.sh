#!/bin/sh
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
stage=${1:-}
ROOT=/data/zte-vpn
controller_sha=bfce3f936a7fa9303cdcc7b7f2312f009a7d99cc2d4d99ed12adad1326743244
# Report the exact failed phase; never include device data or helper output.
phase=INVALID_STAGE
finish() {
    result=$?; trap - EXIT HUP INT TERM
    [ "$result" = 0 ] || printf 'VPN_INSTALL_ERROR %s\n' "$phase" >&2
    exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
case "$stage" in /tmp/zte-vpn-install-????????-????-????-????-????????????) ;; *) echo VPN_INVALID_STAGE >&2; exit 1;; esac
phase=PLATFORM
[ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] || exit 1
phase=UNSAFE_STAGE
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%a' "$stage")" = 0:700 ] || exit 1
phase=ALREADY_PRESENT
[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || exit 1
[ ! -e /etc/init.d/zte_vpn ] && [ ! -L /etc/init.d/zte_vpn ] || exit 1
phase=RUNTIME_TOOLS
for command in lua nft iptables ip6tables ebtables dnsmasq ip ubus sha256sum flock; do command -v "$command" >/dev/null; done
phase=TUN_UNAVAILABLE
[ -c /dev/net/tun ]
phase=LUA_MODULES
lua -e 'assert(require("uci")); assert(require("luci.jsonc"))'
phase=NO_SPACE
free=$(df -Pk /data | awk 'END {print $4}')
[ "$free" -ge 131072 ] || { echo VPN_NO_SPACE >&2; exit 1; }
phase=PAYLOAD
for name in vpnctl mihomo manager.sh firewall.sh configure.lua nft-guard.nft dnsmasq.conf service.sh ikev2.sh ikev2-updown.sh nft-ikev2-guard.nft; do
    [ -f "$stage/$name" ] && [ ! -L "$stage/$name" ] && [ "$(stat -c %u "$stage/$name")" = 0 ] || exit 1
done
[ "$(sha256sum "$stage/mihomo" | awk '{print $1}')" = 1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3 ]
# Authenticate the candidate before invoking its shared compatibility policy.
[ "$(sha256sum "$stage/vpnctl" | awk '{print $1}')" = "$controller_sha" ]
phase=CONTROLLER_EXECUTION
chmod 700 "$stage/vpnctl"
phase=COMPATIBILITY
if reply=$("$stage/vpnctl" install-preflight); then :; else
    case $? in 126|127) phase=CONTROLLER_EXECUTION; exit 1;; esac
    case "$reply" in
      *'"code":"VPN_UNSUPPORTED_FIRMWARE"'*) phase=UNSUPPORTED_FIRMWARE;;
      *'"code":"VPN_IPA_UNSUPPORTED"'*) phase=IPA_UNSUPPORTED;;
      *'"code":"VPN_NETWORK_INIT_CHANGED"'*) phase=NETWORK_CHANGED;;
      *'"code":"VPN_UNSUPPORTED_PLATFORM"'*) phase=PLATFORM;;
      *'"code":"VPN_INTEGRITY"'*) phase=PAYLOAD;;
    esac
    exit 1
fi
phase=WIFI_LAYOUT
lua "$stage/configure.lua" preflight
phase=RPC_UNSUPPORTED
for object in zwrt_wlan network; do
    rpc=$(ubus -t 5 -v list "$object")
    printf '%s\n' "$rpc" | grep -Eq '^[[:space:]]*"reload":\{\}[[:space:]]*$'
done
phase=WRITE
pending="$ROOT.install-${stage##*-install-}"
[ ! -e "$pending" ] && [ ! -L "$pending" ] || exit 1
mkdir "$pending" "$pending/profiles"
for name in vpnctl mihomo manager.sh firewall.sh configure.lua nft-guard.nft dnsmasq.conf service.sh ikev2.sh ikev2-updown.sh nft-ikev2-guard.nft; do cp "$stage/$name" "$pending/$name"; done
chmod 700 "$pending/vpnctl" "$pending/mihomo" "$pending/manager.sh" "$pending/firewall.sh" "$pending/service.sh" "$pending/ikev2.sh" "$pending/ikev2-updown.sh"
printf '%s' zte-vpn-v1 > "$pending/owner"
cat /sys/block/mmcblk0/device/cid > "$pending/cid"
sync
mv "$pending" "$ROOT"
phase=INTEGRITY
"$ROOT/vpnctl" integrity >/dev/null
phase=SERVICE
cp "$ROOT/service.sh" /etc/init.d/zte_vpn
chmod 755 /etc/init.d/zte_vpn
/etc/init.d/zte_vpn enable
sync
echo VPN_COMPONENTS_INSTALLED
