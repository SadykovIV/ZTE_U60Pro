#!/bin/sh
# Managed B31 VPN. Never flush a foreign table/chain.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOT=/data/zte-vpn
exec 9> "$ROOT/firewall.lock"
flock -x 9
ipt() { iptables -w 5 "$@"; }
ip6() { ip6tables -w 5 "$@"; }
add4() { table=$1; chain=$2; shift 2; ipt -t "$table" -C "$chain" "$@" 2>/dev/null || ipt -t "$table" -A "$chain" "$@"; }
add6() { chain=$1; shift; ip6 -C "$chain" "$@" 2>/dev/null || ip6 -A "$chain" "$@"; }
hook4() { table=$1; chain=$2; target=$3; ipt -t "$table" -C "$chain" -j "$target" 2>/dev/null || ipt -t "$table" -I "$chain" 1 -j "$target"; }
hook6() { ip6 -C "$1" -j "$2" 2>/dev/null || ip6 -I "$1" 1 -j "$2"; }
remove() {
    [ "${KEEP_GUARD:-0}" = 1 ] || nft delete table inet zte_vpn_guard 2>/dev/null || true
    for spec in 'filter INPUT ZVPN_IN' 'filter FORWARD ZVPN_FW' 'mangle PREROUTING ZVPN_PRE' 'mangle FORWARD ZVPN_PRE' 'nat PREROUTING ZVPN_DNS' 'nat POSTROUTING ZVPN_IKE_NAT'; do
        set -- $spec
        while ipt -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
        ipt -t "$1" -F "$3" 2>/dev/null || true
        ipt -t "$1" -X "$3" 2>/dev/null || true
    done
    ipt -t nat -F ZVPN_IKE_SNAT 2>/dev/null || true
    ipt -t nat -X ZVPN_IKE_SNAT 2>/dev/null || true
    for spec in 'INPUT ZVPN6_IN' 'FORWARD ZVPN6_FW'; do
        set -- $spec
        while ip6 -D "$1" -j "$2" 2>/dev/null; do :; done
        ip6 -F "$2" 2>/dev/null || true
        ip6 -X "$2" 2>/dev/null || true
    done
    for spec in 'INPUT ZVPN_L2IN' 'FORWARD ZVPN_L2FW' 'OUTPUT ZVPN_L2OUT'; do
        set -- $spec
        while ebtables -D "$1" -j "$2" 2>/dev/null; do :; done
        ebtables -F "$2" 2>/dev/null || true
        ebtables -X "$2" 2>/dev/null || true
    done
    ip rule del priority 19000 fwmark 0x40000000/0x40000000 lookup 19090 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 19090 2>/dev/null || true
    ip route del default dev zvpn-tun table 19090 2>/dev/null || true
    rm -f "$ROOT/firewall.backend"
}
if [ "${1:-apply}" = remove ]; then remove; exit; fi
[ -f "$ROOT/configured" ] || exit 0
backend=$("$ROOT/vpnctl" backend)
case "$backend" in mihomo) guard=nft-guard.nft;; ikev2) guard=nft-ikev2-guard.nft;; *) exit 1;; esac
# This separate nftables table survives fw3's legacy iptables reload/flush.
if [ "$(cat "$ROOT/firewall.backend" 2>/dev/null || true)" != "$backend" ]; then
    # Replace the guard in one nft transaction before touching legacy rules.
    { if nft list table inet zte_vpn_guard >/dev/null 2>&1; then printf 'delete table inet zte_vpn_guard\n'; fi; cat "$ROOT/$guard"; } > "$ROOT/firewall-next.nft"
    nft -f "$ROOT/firewall-next.nft"
    KEEP_GUARD=1 remove
    # Existing guest NAT mappings would otherwise retain the previous DNS/proxy.
    if command -v conntrack >/dev/null 2>&1; then
        conntrack -D -s 192.168.50.0/24 >/dev/null 2>&1 || true
        conntrack -D -d 192.168.50.0/24 >/dev/null 2>&1 || true
    fi
elif ! nft list table inet zte_vpn_guard >/dev/null 2>&1; then
    nft -f "$ROOT/$guard"
fi
bridge_sysctl() {
    # netifd can create/remove the two families at different boot stages.
    # Missing nodes need no update; an existing node's write failure is real.
    [ -e "$1" ] || return 0
    printf '%s\n' "$2" > "$1" || [ ! -e "$1" ]
}
bridge_sysctl /proc/sys/net/ipv6/conf/br-vpn/disable_ipv6 1
bridge_sysctl /proc/sys/net/ipv4/conf/br-vpn/rp_filter 0

# IPv4 guard remains while the proxy is stopped. Only UDP into our TUN may forward.
if [ "$backend" = mihomo ]; then
for c in ZVPN_IN ZVPN_FW; do ipt -N "$c" 2>/dev/null || true; done
add4 filter ZVPN_FW -i br-vpn -j DROP
add4 filter ZVPN_FW -o br-vpn -j DROP
for iface in wlan1 wlan3; do
    add4 filter ZVPN_FW -m physdev --physdev-in "$iface" -j DROP
done
ipt -C ZVPN_FW -i br-vpn -o zvpn-tun -p udp -j ACCEPT 2>/dev/null || ipt -I ZVPN_FW 1 -i br-vpn -o zvpn-tun -p udp -j ACCEPT
ipt -C ZVPN_FW -i zvpn-tun -o br-vpn -p udp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || ipt -I ZVPN_FW 1 -i zvpn-tun -o br-vpn -p udp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
hook4 filter FORWARD ZVPN_FW
add4 filter ZVPN_IN -i br-vpn -p udp --dport 67 -j ACCEPT
for proto in tcp udp; do
    add4 filter ZVPN_IN -i br-vpn -p "$proto" --dport 17874 -j ACCEPT
    add4 filter ZVPN_IN -i br-vpn -p "$proto" -m mark --mark 0x40000000/0x40000000 -j ACCEPT
done
# TCP uses REDIRECT because this vendor kernel accepts TPROXY SYNs without replying.
ipt -C ZVPN_IN -i br-vpn -p tcp --dport 17893 -j ACCEPT 2>/dev/null || ipt -I ZVPN_IN 1 -i br-vpn -p tcp --dport 17893 -j ACCEPT
ipt -C ZVPN_IN ! -i lo -p tcp --dport 17893 -j DROP 2>/dev/null || ipt -A ZVPN_IN ! -i lo -p tcp --dport 17893 -j DROP
add4 filter ZVPN_IN -i br-vpn -j DROP
for proto in tcp udp; do
    add4 filter ZVPN_IN ! -i lo -p "$proto" -m multiport --dports 17874,17890,17894 -j DROP
done
hook4 filter INPUT ZVPN_IN
fi
for c in ZVPN6_IN ZVPN6_FW; do ip6 -N "$c" 2>/dev/null || true; done
add6 ZVPN6_IN -i br-vpn -j DROP
add6 ZVPN6_FW -i br-vpn -j DROP
add6 ZVPN6_FW -o br-vpn -j DROP
hook6 INPUT ZVPN6_IN
hook6 FORWARD ZVPN6_FW

# Protect guest ports even if vendor Wi-Fi code unexpectedly bridges them into LAN.
if ! ebtables -L ZVPN_L2IN >/dev/null 2>&1; then
    ebtables -N ZVPN_L2IN
    for iface in wlan1 wlan3; do
        ebtables -A ZVPN_L2IN -i "$iface" -p IPv6 -j DROP
        ebtables -A ZVPN_L2IN -i "$iface" --logical-in br-vpn -j RETURN
        ebtables -A ZVPN_L2IN -i "$iface" -j DROP
    done
fi
if ! ebtables -L ZVPN_L2FW >/dev/null 2>&1; then
    ebtables -N ZVPN_L2FW
    for iface in wlan1 wlan3; do
        ebtables -A ZVPN_L2FW -i "$iface" -j DROP
        ebtables -A ZVPN_L2FW -o "$iface" -j DROP
    done
fi
if ! ebtables -L ZVPN_L2OUT >/dev/null 2>&1; then
    ebtables -N ZVPN_L2OUT
    for iface in wlan1 wlan3; do ebtables -A ZVPN_L2OUT -o "$iface" -p IPv6 -j DROP; done
fi
for spec in 'INPUT ZVPN_L2IN' 'FORWARD ZVPN_L2FW' 'OUTPUT ZVPN_L2OUT'; do
    set -- $spec
    ebtables -L "$1" | grep -Fqx -- "-j $2" || ebtables -I "$1" 1 -j "$2"
done

if [ "$backend" = ikev2 ]; then
    "$ROOT/ikev2.sh" firewall
    printf '%s\n' "$backend" > "$ROOT/firewall.backend"
    exit 0
fi

ipt -t mangle -N ZVPN_PRE 2>/dev/null || true
add4 mangle ZVPN_PRE -i br-vpn -p udp --dport 67 -j ACCEPT
# DNS always goes to our resolver, including manually specified client DNS.
for proto in tcp udp; do add4 mangle ZVPN_PRE -i br-vpn -p "$proto" --dport 53 -j ACCEPT; done
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    add4 mangle ZVPN_PRE -i br-vpn -d "$cidr" -j DROP
done
tcp_line=$(ipt -t mangle -nL ZVPN_PRE --line-numbers | awk '$2=="TPROXY" && $3=="tcp" {print $1; exit}')
if [ -n "$tcp_line" ]; then ipt -t mangle -R ZVPN_PRE "$tcp_line" -i br-vpn -p tcp -j ACCEPT; fi
add4 mangle ZVPN_PRE -i br-vpn -p tcp -j ACCEPT
udp_line=$(ipt -t mangle -nL ZVPN_PRE --line-numbers | awk '$2=="TPROXY" && $3=="udp" {print $1; exit}')
if [ -n "$udp_line" ]; then
    ipt -t mangle -R ZVPN_PRE "$udp_line" -i br-vpn -p udp -j MARK --set-xmark 0x40000000/0x40000000
    ipt -t mangle -I ZVPN_PRE "$((udp_line+1))" -i br-vpn -p udp -j ACCEPT
fi
add4 mangle ZVPN_PRE -i br-vpn -p udp -j MARK --set-xmark 0x40000000/0x40000000
add4 mangle ZVPN_PRE -i br-vpn -p udp -j ACCEPT
add4 mangle ZVPN_PRE -i br-vpn -j DROP
hook4 mangle PREROUTING ZVPN_PRE
ipt -t nat -N ZVPN_DNS 2>/dev/null || true
for proto in tcp udp; do add4 nat ZVPN_DNS -i br-vpn -p "$proto" --dport 53 -j REDIRECT --to-ports 17874; done
add4 nat ZVPN_DNS -i br-vpn -p tcp -j REDIRECT --to-ports 17893
hook4 nat PREROUTING ZVPN_DNS
ip route del local 0.0.0.0/0 dev lo table 19090 2>/dev/null || true
if ip link show zvpn-tun >/dev/null 2>&1; then
    ip route replace default dev zvpn-tun table 19090
fi
ip rule show | grep -q '^19000:.*fwmark 0x40000000/0x40000000.*lookup 19090' ||
    ip rule add priority 19000 fwmark 0x40000000/0x40000000 lookup 19090
printf '%s\n' "$backend" > "$ROOT/firewall.backend"
