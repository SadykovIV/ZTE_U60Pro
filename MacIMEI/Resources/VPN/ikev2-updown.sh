#!/bin/sh
# The daemon supplies a negotiated virtual IP; never infer it from WAN addresses.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOT=/data/zte-vpn
[ "${PLUTO_CONNECTION:-}" = zte-private ] || exit 1
[ "${PLUTO_REQID:-}" = 19090 ] || exit 1
case "${PLUTO_UNIQUEID:-}" in ''|*[!0-9]*) exit 1;; esac
selector=$(printf '%s' "${PLUTO_MY_CLIENT:-}/${PLUTO_PEER_CLIENT:-}" | sha256sum | awk '{print $1}')
exec 9> "$ROOT/ikev2/updown.lock"; flock -x 9
umask 077
mkdir -p "$ROOT/ikev2/children"
case "${PLUTO_VERB:-}" in
 up-host|up-client)
    vip=${PLUTO_MY_SOURCEIP4_1:-${PLUTO_MY_SOURCEIP:-}}
    printf '%s\n' "$vip" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1} END{if(NR!=1)exit 1}' || exit 1
    # A callback is repeated for each selector; replace our one SNAT rule only.
    printf '%s\n' "$vip" > "$ROOT/ikev2/vip.new"
    mv "$ROOT/ikev2/vip.new" "$ROOT/ikev2/vip"
    iptables -w 5 -t nat -N ZVPN_IKE_SNAT 2>/dev/null || true
    iptables -w 5 -t nat -F ZVPN_IKE_SNAT
    iptables -w 5 -t nat -A ZVPN_IKE_SNAT -s 192.168.50.0/24 -o zvpn-ipsec -j SNAT --to-source "$vip"
    touch "$ROOT/ikev2/children/$PLUTO_UNIQUEID-$selector" "$ROOT/ikev2/connected"
    printf 'connected\n' > "$ROOT/ikev2/auth-state"
    ;;
 down-host|down-client)
    rm -f "$ROOT/ikev2/children/$PLUTO_UNIQUEID-$selector"
    if [ -z "$(ls -A "$ROOT/ikev2/children")" ]; then
        rm -f "$ROOT/ikev2/connected"
        printf 'disconnected\n' > "$ROOT/ikev2/auth-state"
    fi
    # Keep VIP SNAT through selector callbacks/rekey races. XFRM drops when the
    # SA disappears; final cleanup removes only the owned chain.
    ;;
 *) exit 1;;
esac
