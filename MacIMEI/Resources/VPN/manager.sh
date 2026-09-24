#!/bin/sh
# Shared, owned VPN runtime. API/desktop changes are serialized by vpnctl.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOT=/data/zte-vpn
CORE="$ROOT/mihomo"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ROOT/actions.log"; }
fail() { log "$1"; echo "$1" >&2; exit 1; }
disable_guest() {
    lua "$ROOT/configure.lua" disable >/dev/null 2>&1 || true
    for dev in wlan1 wlan3; do ip link set "$dev" down 2>/dev/null || true; done
}
reload_wifi() { ubus -t 30 call zwrt_wlan reload '{}' >> "$ROOT/reload.log" 2>&1; }
recover() {
    # Incomplete preparation never changed the live profile; done is committed.
    rm -rf "$ROOT/transaction.preparing" "$ROOT/transaction.done"
    [ -d "$ROOT/transaction" ] || return 0
    if [ -f "$ROOT/transaction/config.json" ]; then
        cp "$ROOT/transaction/config.json" "$ROOT/config.json.new"
        mv "$ROOT/config.json.new" "$ROOT/config.json"
    else
        disable_guest
        rm -f "$ROOT/config.json"
    fi
    if [ -f "$ROOT/transaction/active" ]; then
        cp "$ROOT/transaction/active" "$ROOT/active.new"
        mv "$ROOT/active.new" "$ROOT/active"
    else rm -f "$ROOT/active"; fi
    sync
    mv "$ROOT/transaction" "$ROOT/transaction.done"
    sync
    rm -rf "$ROOT/transaction.done"
    log PROFILE_ROLLED_BACK
}
prepare() {
    [ "$(sha256sum /firmware/image/modem.b16 | awk '{print $1}')" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ] || fail VPN_UNSUPPORTED_FIRMWARE
    [ "$(cat "$ROOT/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" ] || fail VPN_DEVICE_CHANGED
    [ "$(uci -q get wireless.zte_mbb.mesh_onoff)" = 0 ] || fail VPN_MESH_CONFLICT
    [ "$(uci -q get zwrt_router.tmp_router.close_ipa_acce)" = 1 ] || fail VPN_IPA_ENABLED
    if [ ! -f "$ROOT/configured" ]; then
        [ ! -e "$ROOT/backup" ] || fail VPN_CONFIGURATION_PENDING
        [ "$(uci -q get wireless.guest_2g.disabled)" = 1 ] && [ "$(uci -q get wireless.guest_5g.disabled)" = 1 ] || fail VPN_GUEST_IN_USE
        [ -z "$(pidof clash 2>/dev/null || true)" ] || fail VPN_OTHER_PROXY
        ! ip route show table all | grep -q '192.168.50.' || fail VPN_SUBNET_CONFLICT
        [ -z "$(ip route show table 19090)" ] || fail VPN_ROUTE_CONFLICT
        ! ip rule show | grep -q '^19000:' || fail VPN_ROUTE_CONFLICT
        for pkg in network wireless firewall; do [ -z "$(uci -q changes "$pkg")" ] || fail VPN_PENDING_CHANGES; done
        mkdir "$ROOT/backup" "$ROOT/backup-deltas" "$ROOT/uci"
        for pkg in network wireless firewall dhcp; do cp -p "/etc/config/$pkg" "$ROOT/backup/$pkg"; done
        cp -p /etc/init.d/network "$ROOT/backup/network.init"
        (cd "$ROOT/backup" && sha256sum network wireless firewall dhcp network.init > SHA256SUMS)
        # Root-owned pinned hook is installed before the APs can be enabled.
        "$ROOT/vpnctl" hook-network
        touch "$ROOT/configured"
        "$ROOT/firewall.sh"
        lua "$ROOT/configure.lua" apply >> "$ROOT/actions.log"
        ubus -t 15 call network reload '{}' >> "$ROOT/reload.log" 2>&1
    fi
    for n in $(seq 1 20); do
        ip -4 addr show br-vpn 2>/dev/null | grep -q '192.168.50.1/24' && break
        sleep 1
    done
    ip -4 addr show br-vpn | grep -q '192.168.50.1/24' || fail VPN_BRIDGE_NOT_READY
    "$ROOT/firewall.sh"
}
wait_core() {
    n=0
    while [ "$n" -lt 20 ]; do
        if [ -s $ROOT/core.pid ] && kill -0 "$(cat $ROOT/core.pid)" 2>/dev/null && [ -e /sys/class/net/zvpn-tun ]; then
            "$ROOT/firewall.sh"; return 0
        fi
        n=$((n+1)); sleep 1
    done
    return 1
}
wait_wifi() {
    n=0
    while [ "$n" -lt 40 ]; do
        ready=1
        for dev in wlan1 wlan3; do
            readlink "/sys/class/net/$dev/master" 2>/dev/null | grep -q '/br-vpn$' || ready=0
            hostapd_cli -p /data/vendor/wifi/hostapd -i "$dev" status 2>/dev/null | grep -q '^state=ENABLED$' || ready=0
        done
        [ "$ready" = 0 ] || return 0
        n=$((n+1)); sleep 3
    done
    return 1
}
case "${1:-}" in
 prepare) prepare;;
 activate)
    prepare
    /etc/init.d/zte_vpn restart
    wait_core || fail VPN_CORE_NOT_READY
    log PROFILE_ACTIVATED
    ;;
 enable)
    [ -f "$ROOT/config.json" ] || fail VPN_NO_ACTIVE_PROFILE
    prepare
    /etc/init.d/zte_vpn start
    wait_core || fail VPN_CORE_NOT_READY
    lua "$ROOT/configure.lua" enable >> "$ROOT/actions.log"
    reload_wifi
    if ! wait_wifi; then disable_guest; reload_wifi || true; fail VPN_WIFI_NOT_READY; fi
    "$ROOT/firewall.sh"
    log WIFI_ENABLED
    ;;
 disable)
    [ -f "$ROOT/configured" ] || exit 0
    disable_guest; reload_wifi
    log WIFI_DISABLED
    ;;
 early)
    [ -f "$ROOT/configured" ] || exit 0
    recover
    if "$ROOT/vpnctl" integrity >/dev/null 2>&1 && "$ROOT/firewall.sh" >> "$ROOT/firewall.log" 2>&1; then
        /etc/init.d/zte_vpn start
        log BOOT_GUARD_READY
    else
        disable_guest; log BOOT_GUARD_FAILED; exit 1
    fi
    ;;
 recover) recover; /etc/init.d/zte_vpn restart;;
 run-core)
    "$ROOT/vpnctl" integrity >/dev/null
    [ -s "$ROOT/config.json" ] || exit 1
    [ ! -f "$ROOT/core.log" ] || [ "$(wc -c < "$ROOT/core.log")" -lt 1048576 ] || mv "$ROOT/core.log" "$ROOT/core.previous.log"
    echo $$ > $ROOT/core.pid
    exec "$CORE" -d "$ROOT" -f "$ROOT/config.json" >> "$ROOT/core.log" 2>&1
    ;;
 run-dns)
    echo $$ > $ROOT/dns.pid
    exec dnsmasq --keep-in-foreground --conf-file="$ROOT/dnsmasq.conf" >/dev/null 2>&1
    ;;
 run-guard)
    while [ -f "$ROOT/configured" ]; do
        if ! "$ROOT/firewall.sh" >> "$ROOT/firewall.log" 2>&1; then disable_guest; log FIREWALL_FAILED; fi
        for dev in wlan1 wlan3; do
            master=$(readlink "/sys/class/net/$dev/master" 2>/dev/null || true)
            case "$master" in */br-vpn|'') ;; *) disable_guest; log BRIDGE_MISMATCH;; esac
        done
        sleep 5
    done
    ;;
 *) fail VPN_INVALID_COMMAND;;
esac
