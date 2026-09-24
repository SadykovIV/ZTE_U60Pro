#!/bin/sh
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
stage=${1:-}
ROOT=/data/zte-vpn
case "$stage" in /tmp/zte-vpn-install-????????-????-????-????-????????????) ;; *) echo VPN_INVALID_STAGE >&2; exit 1;; esac
[ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ]
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%a' "$stage")" = 0:700 ]
[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ]
[ ! -e /etc/init.d/zte_vpn ] && [ ! -L /etc/init.d/zte_vpn ]
[ "$(sha256sum /firmware/image/modem.b16 | awk '{print $1}')" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ]
for command in lua nft iptables ip6tables ebtables dnsmasq ip ubus sha256sum flock; do command -v "$command" >/dev/null; done
[ -c /dev/net/tun ]
lua -e 'assert(require("uci")); assert(require("luci.jsonc"))'
free=$(df -Pk /data | awk 'END {print $4}')
[ "$free" -ge 131072 ] || { echo VPN_NO_SPACE >&2; exit 1; }
for name in vpnctl mihomo manager.sh firewall.sh configure.lua nft-guard.nft dnsmasq.conf service.sh; do
    [ -f "$stage/$name" ] && [ ! -L "$stage/$name" ] && [ "$(stat -c %u "$stage/$name")" = 0 ]
done
[ "$(sha256sum "$stage/mihomo" | awk '{print $1}')" = 1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3 ]
pending="$ROOT.install-${stage##*-install-}"
[ ! -e "$pending" ] && [ ! -L "$pending" ]
mkdir "$pending" "$pending/profiles"
for name in vpnctl mihomo manager.sh firewall.sh configure.lua nft-guard.nft dnsmasq.conf service.sh; do cp "$stage/$name" "$pending/$name"; done
chmod 700 "$pending/vpnctl" "$pending/mihomo" "$pending/manager.sh" "$pending/firewall.sh" "$pending/service.sh"
printf '%s' zte-vpn-v1 > "$pending/owner"
cat /sys/block/mmcblk0/device/cid > "$pending/cid"
sync
mv "$pending" "$ROOT"
"$ROOT/vpnctl" integrity >/dev/null
cp "$ROOT/service.sh" /etc/init.d/zte_vpn
chmod 755 /etc/init.d/zte_vpn
/etc/init.d/zte_vpn enable
sync
echo VPN_COMPONENTS_INSTALLED
