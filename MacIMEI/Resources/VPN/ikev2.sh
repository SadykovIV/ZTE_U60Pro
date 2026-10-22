#!/bin/sh
# Native strongSwan backend; all mutable state belongs to zte-vpn.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOT=/data/zte-vpn
IKE="$ROOT/ikev2"
CHARON=/usr/lib/ipsec/charon
SWANCTL=/usr/sbin/swanctl
URI=unix:///data/zte-vpn/ikev2/charon.vici
fail() { echo "$1" >&2; exit 1; }
ipt() { iptables -w 5 "$@"; }
add4() { table=$1; chain=$2; shift 2; ipt -t "$table" -C "$chain" "$@" 2>/dev/null || ipt -t "$table" -A "$chain" "$@"; }
hook4() { ipt -t "$1" -C "$2" -j "$3" 2>/dev/null || ipt -t "$1" -I "$2" 1 -j "$3"; }
xfrm_owned() { ip -d link show dev zvpn-ipsec 2>/dev/null | grep -Eq 'xfrm if_id (0x4a92|19090)( |$)'; }
charon_owned() {
    ike_pid=$(cat "$IKE/charon.pid" 2>/dev/null) || return 1
    case "$ike_pid" in ''|*[!0-9]*) return 1;; esac
    [ "$(readlink "/proc/$ike_pid/exe" 2>/dev/null)" = "$CHARON" ] &&
        tr '\000' '\n' < "/proc/$ike_pid/environ" | grep -Fx "STRONGSWAN_CONF=$IKE/strongswan.conf" >/dev/null
}
connected() {
    charon_owned && [ -S "$IKE/charon.vici" ] || return 1
    report="$IKE/connected-check.$$"
    "$SWANCTL" --list-sas --ike zte-ikev2 --raw --uri "$URI" > "$report" 2>/dev/null & query=$!
    (sleep 3; kill -TERM "$query" 2>/dev/null || true) & watchdog=$!
    result=0; wait "$query" || result=1
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    if [ "$result" = 0 ] && grep -q 'zte-private' "$report" && grep -Eq 'state[[:space:]]*=[[:space:]]*INSTALLED' "$report"; then result=0; else result=1; fi
    rm -f "$report"
    return "$result"
}
native_check() {
    [ -x "$CHARON" ] && [ -x "$SWANCTL" ] || fail VPN_IKEV2_UNAVAILABLE
    for tool in jsonfilter iptables ip nft flock; do command -v "$tool" >/dev/null || fail VPN_IKEV2_UNAVAILABLE; done
    for candidate in $(pidof charon 2>/dev/null || true); do
        charon_owned && [ "$candidate" = "$ike_pid" ] || fail VPN_IKEV2_CONFLICT
    done
}
lte_route() {
    # Copy only a numeric rmnet default into our table. Never change host routes.
    # Prefer the main table, then the vendor's policy tables. Ambiguity is an error.
    routes=$(ip -4 route show table main) || return 1
    selected=$(printf '%s\n' "$routes" | awk '$1=="default"{for(i=1;i<NF;i++)if($i=="dev"&&$(i+1)~/^rmnet_data[0-9]+$/)print}')
    if [ -z "$selected" ]; then
        routes=$(ip -4 route show table all) || return 1
        selected=$(printf '%s\n' "$routes" | awk '$1=="default"&&$0!~/(^| )table 1909[01]( |$)/{for(i=1;i<NF;i++)if($i=="dev"&&$(i+1)~/^rmnet_data[0-9]+$/)print}')
    fi
    printf '%s\n' "$selected" | awk '
      function ipv4(s,a,n,i){n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return 1}
      NF{n++;for(i=2;i<=NF;i++){if($i=="dev"){dev=$(++i)}else if($i=="via"){via=$(++i)}else if($i=="src"){src=$(++i)}}}
      END{if(n!=1||dev!~/^rmnet_data[0-9]+$/||(via!=""&&!ipv4(via))||(src!=""&&!ipv4(src)))exit 1;
      printf "default";if(via!="")printf " via %s",via;printf " dev %s",dev;if(via!="")printf " onlink";if(src!="")printf " src %s",src;print ""}'
}
routes() {
    xfrm_owned || return 1
    # If the XFRM device disappears, its routes disappear too. A second table
    # must reject private destinations before considering the public LTE default.
    for subnet in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        ip -4 route replace unreachable "$subnet" metric 32767 table 19091
    done
    ip -4 route replace 10.0.0.0/8 dev zvpn-ipsec table 19090
    ip -4 route replace 172.16.0.0/12 dev zvpn-ipsec table 19090
    ip -4 route replace 192.168.0.0/16 dev zvpn-ipsec table 19090
    # A terminal unreachable prevents LTE outage from falling back to another uplink.
    ip -4 route replace unreachable default metric 32767 table 19091
    if lte=$(lte_route); then
        # lte_route emits only validated fixed keywords, IPv4 literals and rmnet names.
        set -- $lte
        ip -4 route replace "$@" metric 1 table 19091
    else
        ip -4 route del default metric 1 table 19091 2>/dev/null || true
    fi
    ip -4 rule show | grep -q '^19000:.*iif br-vpn.*lookup 19090' || ip -4 rule add priority 19000 iif br-vpn lookup 19090
    ip -4 rule show | grep -q '^19001:.*iif br-vpn.*lookup 19091' || ip -4 rule add priority 19001 iif br-vpn lookup 19091
}
prepare() {
    native_check
    "$ROOT/vpnctl" prepare-ikev2 >/dev/null
    if [ ! -f "$IKE/network-owned" ]; then
        [ -z "$(ip -4 route show table 19091 2>/dev/null || true)" ] || fail VPN_ROUTE_CONFLICT
        ! ip -4 rule show | grep -q '^19001:' || fail VPN_ROUTE_CONFLICT
        ! ip link show dev zvpn-ipsec >/dev/null 2>&1 || fail VPN_IKEV2_CONFLICT
        touch "$IKE/network-owned"
    fi
    if ip link show dev zvpn-ipsec >/dev/null 2>&1; then
        xfrm_owned || fail VPN_IKEV2_CONFLICT
    else
        ip link add zvpn-ipsec type xfrm if_id 19090 || fail VPN_IKEV2_UNAVAILABLE
    fi
    ip link set dev zvpn-ipsec mtu 1400 up
    printf '0\n' > /proc/sys/net/ipv4/conf/zvpn-ipsec/rp_filter
    # Only an explicit lifecycle stop resets attempt-issued. Preparing routes
    # after a daemon failure must not issue another authentication PUSH.
    if ! charon_owned; then
        rm -f "$IKE/connected"
        # Persisted ON may reconnect once after a real device boot. Re-running
        # prepare in the same boot must retain a failed/pending attempt marker.
        boot_id=$(cat /proc/sys/kernel/random/boot_id)
        if [ "$(cat "$IKE/attempt-boot" 2>/dev/null || true)" != "$boot_id" ]; then
            rm -f "$IKE/attempt-issued"
            printf '%s\n' "$boot_id" > "$IKE/attempt-boot"
        fi
    fi
    routes
}
firewall() {
    dns=$(jsonfilter -i "$ROOT/config.json" -e '@.ikev2.dns')
    printf '%s\n' "$dns" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1;if(!($1==10||($1==172&&$2>=16&&$2<=31)||($1==192&&$2==168)))exit 1}END{if(NR!=1)exit 1}' || fail VPN_IKEV2_INVALID_DNS
    for spec in 'filter ZVPN_IN' 'filter ZVPN_FW' 'mangle ZVPN_PRE' 'nat ZVPN_DNS' 'nat ZVPN_IKE_NAT' 'nat ZVPN_IKE_SNAT'; do set -- $spec; ipt -t "$1" -N "$2" 2>/dev/null || true; done
    add4 filter ZVPN_FW -i br-vpn ! -s 192.168.50.0/24 -j DROP
    for subnet in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        add4 filter ZVPN_FW -i br-vpn -d "$subnet" -o zvpn-ipsec -j ACCEPT
        add4 filter ZVPN_FW -i br-vpn -d "$subnet" -j DROP
    done
    add4 filter ZVPN_FW -i zvpn-ipsec -o br-vpn -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    for subnet in 0.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 192.0.0.0/24 192.0.2.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4; do
        add4 filter ZVPN_FW -i br-vpn -d "$subnet" -j DROP
    done
    add4 filter ZVPN_FW -i br-vpn -o rmnet_data+ -j ACCEPT
    add4 filter ZVPN_FW -i rmnet_data+ -o br-vpn -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    add4 filter ZVPN_FW -i br-vpn -j DROP
    add4 filter ZVPN_FW -o br-vpn -j DROP
    for iface in wlan1 wlan3; do add4 filter ZVPN_FW -m physdev --physdev-in "$iface" -j DROP; done
    hook4 filter FORWARD ZVPN_FW
    add4 filter ZVPN_IN -i br-vpn -p udp --dport 67 -j ACCEPT
    add4 filter ZVPN_IN -i br-vpn -j DROP
    hook4 filter INPUT ZVPN_IN
    # Force every guest DNS query to the private DNS server before routing.
    for proto in tcp udp; do add4 nat ZVPN_DNS -i br-vpn -p "$proto" --dport 53 -j DNAT --to-destination "$dns"; done
    hook4 nat PREROUTING ZVPN_DNS
    add4 nat ZVPN_IKE_NAT -s 192.168.50.0/24 -o zvpn-ipsec -j ZVPN_IKE_SNAT
    add4 nat ZVPN_IKE_NAT -s 192.168.50.0/24 -o rmnet_data+ -j MASQUERADE
    hook4 nat POSTROUTING ZVPN_IKE_NAT
    # Clamp only forwarded TCP crossing the owned tunnel.
    add4 mangle ZVPN_PRE -i br-vpn -o zvpn-ipsec -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    hook4 mangle FORWARD ZVPN_PRE
    routes
}
owned_policies() {
    # iproute2 6.3 cannot filter `policy deleteall` by if_id. Delete exact indexes.
    awk '{gsub(/\\/, " ");index_id="";direction="";interface_id="";request_id="";mark="";
      for(i=1;i<=NF;i++){if($i=="index")index_id=$(i+1);if($i=="dir")direction=$(i+1);if($i=="if_id")interface_id=$(i+1);if($i=="reqid")request_id=$(i+1);if($i=="mark")mark=$(i+1)}
      # With -s native ip prints reqid in decimal followed by hexadecimal.
      if(request_id~/^19090\(0x0*4a92\)$/)request_id="19090";
      if((interface_id=="0x4a92"||interface_id=="19090")&&request_id=="19090"&&mark==""){
        if(index_id!~/^[0-9]+$/||direction!~/^(in|out|fwd)$/)exit 1;
        print index_id,direction
      }}'
}
owned_states() {
    # Input is `ip -o xfrm state list nokeys reqid 19090`. No key material is
    # printed or stored. Native iproute2 cannot filter a state delete by if_id;
    # select the owned unmarked SA first, then delete its exact dst/proto/SPI.
    awk '{gsub(/\\/, " ");destination="";protocol="";spi="";interface_id="";request_id="";mark="";
      for(i=1;i<=NF;i++){
        if($i=="dst"&&destination=="")destination=$(i+1);
        if($i=="proto"&&protocol=="")protocol=$(i+1);
        if($i=="spi")spi=$(i+1);
        if($i=="if_id")interface_id=$(i+1);
        if($i=="reqid")request_id=$(i+1);
        if($i=="mark")mark=$(i+1)
      }
      if((interface_id=="0x4a92"||interface_id=="19090")&&request_id=="19090"&&mark==""){
        if(destination!~/^[0-9a-fA-F:.]+$/||protocol!="esp"||spi!~/^0x[0-9a-fA-F]+$/)exit 1;
        print destination,protocol,spi
      }}'
}
cleanup() {
    # Caller stops procd first. Never stop a daemon we cannot identify as ours.
    if charon_owned; then
        kill -TERM "$ike_pid" 2>/dev/null || true
        n=0
        while charon_owned; do
            n=$((n+1))
            [ "$n" -lt 5 ] || kill -KILL "$ike_pid" 2>/dev/null || true
            [ "$n" -lt 7 ] || fail VPN_IKEV2_CONFLICT
            sleep 1
        done
    fi
    if [ -f "$IKE/network-owned" ]; then
        policies=$(ip -s -o xfrm policy) || fail VPN_IKEV2_NOT_READY
        policy_targets=$(printf '%s\n' "$policies" | owned_policies) || fail VPN_IKEV2_NOT_READY
        printf '%s\n' "$policy_targets" | while read -r index_id direction; do
            [ -n "$index_id" ] || continue
            ip xfrm policy delete index "$index_id" dir "$direction" if_id 19090 || exit 1
        done
        states=$(ip -o xfrm state list nokeys reqid 19090) || fail VPN_IKEV2_NOT_READY
        targets=$(printf '%s\n' "$states" | owned_states) || fail VPN_IKEV2_NOT_READY
        printf '%s\n' "$targets" | while read -r destination protocol spi; do
            [ -n "$destination" ] || continue
            ip xfrm state delete dst "$destination" proto "$protocol" spi "$spi" mark 0 mask 0xffffffff || exit 1
        done
        # An externally deleted XFRM link must not leave its SAs/policies behind.
        if xfrm_owned; then ip link del dev zvpn-ipsec; fi
    for priority in 19000 19001; do
        case "$priority" in 19000) table=19090;; *) table=19091;; esac
        ip -4 rule del priority "$priority" iif br-vpn lookup "$table" 2>/dev/null || true
    done
    for subnet in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        ip -4 route del "$subnet" table 19090 2>/dev/null || true
        ip -4 route del unreachable "$subnet" metric 32767 table 19091 2>/dev/null || true
    done
    ip -4 route del default metric 1 table 19091 2>/dev/null || true
    ip -4 route del unreachable default metric 32767 table 19091 2>/dev/null || true
    fi
    rm -f "$IKE/vip" "$IKE/charon.pid" "$IKE/charon.vici" "$IKE/attempt-issued" "$IKE/connected" "$IKE/auth-state" "$IKE/network-owned"
    rm -rf "$IKE/children"
}
run() {
    native_check
    export STRONGSWAN_CONF="$IKE/strongswan.conf"
    adopted=0
    if charon_owned; then
        # A killed shell worker can leave its own daemon alive. Adopt it without
        # overwriting the PID, reloading connections or sending another PUSH.
        daemon=$ike_pid; adopted=1
    else
        "$CHARON" >/dev/null 2>&1 & daemon=$!
        printf '%s\n' "$daemon" > "$IKE/charon.pid"
    fi
    initiator=
    trap 'result=$?; trap - INT TERM EXIT; if [ -n "$initiator" ]; then kill -TERM "$initiator" 2>/dev/null || true; fi; if charon_owned && [ "$ike_pid" = "$daemon" ]; then kill -TERM "$daemon" 2>/dev/null || true; fi; wait "$daemon" 2>/dev/null || true; exit "$result"' INT TERM EXIT
    if [ "$adopted" = 1 ]; then
        while charon_owned && [ "$ike_pid" = "$daemon" ]; do sleep 5; done
        exit 1
    fi
    n=0
    while [ ! -S "$IKE/charon.vici" ]; do
        kill -0 "$daemon" 2>/dev/null || exit 1
        n=$((n+1)); [ "$n" -lt 20 ] || exit 1
        sleep 1
    done
    "$SWANCTL" --load-all --file "$IKE/swanctl.conf" --uri "$URI" >/dev/null 2>&1 || fail VPN_IKEV2_NOT_READY
    if [ ! -f "$IKE/attempt-issued" ]; then
        # One attempt per explicit activation/enable. A procd respawn must not send
        # another authentication PUSH after an interrupted or rejected attempt.
        touch "$IKE/attempt-issued"
        printf 'waiting\n' > "$IKE/auth-state"
        "$SWANCTL" --initiate --child zte-private --timeout 180 --uri "$URI" >/dev/null 2>&1 & initiator=$!
        while kill -0 "$initiator" 2>/dev/null && kill -0 "$daemon" 2>/dev/null; do sleep 1; done
        wait "$initiator" || true
        initiator=
        [ -f "$IKE/connected" ] || printf 'disconnected\n' > "$IKE/auth-state"
    fi
    while kill -0 "$daemon" 2>/dev/null; do
        sleep 5
    done
    exit 1
}
case "${1:-}" in
 check) native_check;;
 prepare) prepare;;
 firewall) firewall;;
 cleanup) cleanup;;
 ready) xfrm_owned && [ -s "$IKE/dnsmasq.conf" ];;
 running) charon_owned && [ -S "$IKE/charon.vici" ];;
 connected) connected;;
 run) run;;
 *) fail VPN_INVALID_COMMAND;;
esac
