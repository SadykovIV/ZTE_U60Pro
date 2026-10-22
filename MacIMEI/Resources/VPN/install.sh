#!/bin/sh
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
stage=${1:-}
ROOT=/data/zte-vpn
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
phase=UNSUPPORTED_FIRMWARE
# B04 captures include both an unavailable image and this measured modem.b16.
# Native MDM/router identity remains required; startup needs no vendor RPC.
b04_profile() {
    if [ -e /firmware/image/modem.b16 ] || [ -L /firmware/image/modem.b16 ]; then
        [ -f /firmware/image/modem.b16 ] && [ ! -L /firmware/image/modem.b16 ] || return 1
        [ "$(sha256sum /firmware/image/modem.b16 2>/dev/null | awk '{print $1}')" = c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81 ] || return 1
    fi
    [ -f /usr/bin/zte_topsw_mdm ] && [ ! -L /usr/bin/zte_topsw_mdm ] || return 1
    [ "$(sha256sum /usr/bin/zte_topsw_mdm 2>/dev/null | awk '{print $1}')" = 93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64 ] &&
    [ "$(sha256sum /usr/bin/diag-router 2>/dev/null | awk '{print $1}')" = 55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f ]
}
# Captured B31/B28 modem images, or the B04 userspace profile.
case "$(sha256sum /firmware/image/modem.b16 2>/dev/null | awk '{print $1}')" in
    604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263|5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478) ;;
    *) b04_profile || exit 1
       # Verify the collected stock network hook before creating any files.
       [ "$(sha256sum /etc/init.d/network | awk '{print $1}')" = 093e5461be5ea5d23d24522374a27b9a134c4932df3c89b3b756274f123ac508 ] || exit 1;;
esac
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
