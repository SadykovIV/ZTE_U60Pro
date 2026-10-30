#!/bin/sh
# Shared, owned VPN runtime. API/desktop changes are serialized by vpnctl.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOT=/data/zte-vpn
CORE="$ROOT/mihomo"
MODE=${1:-}
backend() { "$ROOT/vpnctl" backend; }
runtime_wanted() {
    [ -f "$ROOT/configured" ] && [ -s "$ROOT/config.json" ] || return 1
    [ ! -f "$ROOT/runtime-disabled" ] || return 1
    # Use the persisted guest selection, not AP link state: the guard may hold
    # selected APs DOWN while their backend is starting or being repaired.
    for section in guest_2g guest_5g; do
        [ "$(uci -q get wireless.$section.disabled 2>/dev/null || true)" != 0 ] || return 0
    done
    return 1
}
dns_config() {
    kind=$(backend) || return 1
    case "$kind" in ikev2) printf '%s' "$ROOT/ikev2/dnsmasq.conf";; mihomo) printf '%s' "$ROOT/dnsmasq.conf";; *) return 1;; esac
}
prepare_backend() {
    kind=$(backend) || return 1
    case "$kind" in ikev2) "$ROOT/ikev2.sh" prepare;; mihomo) return 0;; *) return 1;; esac
}
stop_backend() {
    suspend_guest
    stop_failed=0
    /etc/init.d/zte_vpn stop || stop_failed=1
    if [ -d "$ROOT/ikev2" ]; then "$ROOT/ikev2.sh" cleanup || stop_failed=1; fi
    # Reconcile DNS/NAT even when the next profile uses the same backend.
    rm -f "$ROOT/firewall.backend"
    [ "$stop_failed" = 0 ]
}
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ROOT/actions.log"; }
fail() {
    log "$1"
    case "$1" in VPN_IPA_*)
        if [ -f "$ROOT/configured" ]; then
            case "$MODE" in activate|run-core|run-guard) suspend_guest;; *) disable_guest;; esac
        fi;;
    esac
    echo "$1" >&2; exit 1
}
suspend_guest() {
    # Runtime failures must not overwrite the user's saved enabled state.
    for dev in wlan1 wlan3; do ip link set "$dev" down 2>/dev/null || true; done
}
disable_guest() {
    # A durable stop fence also covers a failed/interrupted UCI commit. Only a
    # successful explicit enable removes it; recovery never does.
    : > "$ROOT/runtime-disabled"
    lua "$ROOT/configure.lua" disable >/dev/null 2>&1 || true
    suspend_guest
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
# FLY public B11 / modem B27: measured native components, not the display version.
b27_profile() {
    for component in /firmware/image/modem.b16 /usr/bin/zte_topsw_mdm /usr/bin/diag-router; do
        [ -f "$component" ] && [ ! -L "$component" ] && [ "$(stat -c %u "$component")" = 0 ] || return 1
    done
    [ "$(sha256sum /firmware/image/modem.b16 | awk '{print $1}')" = 4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e ] &&
    [ "$(sha256sum /usr/bin/zte_topsw_mdm | awk '{print $1}')" = 00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d ] &&
    [ "$(sha256sum /usr/bin/diag-router | awk '{print $1}')" = 786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f ]
}
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
ipa_hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
ipa_plain() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ]; }
ipa_private() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a "$1")" = 0:700 ]; }
ipa_tools() {
    ipa_plain /sbin/ipacm_switch.sh && ipa_plain /usr/bin/ipacm || return 1
    [ "$(ipa_hash /sbin/ipacm_switch.sh)" = 8947eee9c554453dc8eeb77df933cd12899f447c8c03df3505c57c7b526d22b9 ] || return 1
    case "$(ipa_hash /firmware/image/modem.b16):$(ipa_hash /usr/bin/ipacm)" in
        604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263:95385816da7b2edb9a977cee328c091753463fcd4a70a67fa1676e8b335c11c0|5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478:a8a90ee631a3e8de3266d1d4231e455c34fd0b0d1ad570e7c4d0dcd09eea1c54) return 0;;
        4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e:a843789933a0b5747927583021c1480957ea942626cab17cb13ad415d1dfd3ae) b27_profile;;
        *) b04_profile && [ "$(ipa_hash /usr/bin/ipacm)" = 95385816da7b2edb9a977cee328c091753463fcd4a70a67fa1676e8b335c11c0 ];;
    esac
}
ipa_flags() {
    ipa_close=$(uci -q get zwrt_router.tmp_router.close_ipa_acce 2>/dev/null || printf absent)
    ipa_disabled=$(uci -q get zwrt_router.other.ipa_disable 2>/dev/null || printf absent)
    case "$ipa_close:$ipa_disabled" in 0:0|0:1|0:absent|1:0|1:1|1:absent|absent:0|absent:1|absent:absent) ;; *) return 1;; esac
}
ipa_pid() {
    ipa_candidates=$(pidof ipacm 2>/dev/null) || return 1
    ipacm_pid=
    for candidate in $ipa_candidates; do
        case "$candidate" in ''|*[!0-9]*) return 1;; esac
        if [ "$(readlink "/proc/$candidate/exe" 2>/dev/null || true)" = /usr/bin/ipacm ]; then
            [ -z "$ipacm_pid" ] || return 1
            ipacm_pid=$candidate
        fi
    done
    [ -n "$ipacm_pid" ]
}
ipa_snapshot_valid() {
    ipa_private "$ROOT/ipa-backup" && ipa_private "$ROOT/ipa-backup/deltas" || return 1
    for f in state zwrt_router SHA256SUMS; do ipa_plain "$ROOT/ipa-backup/$f" || return 1; done
    awk 'NF!=2 || $2!~/^(state|zwrt_router)$/ || length($1)!=64 || $1~/[^0-9a-f]/ || seen[$2]++ {bad=1} END{exit bad||NR!=2}' "$ROOT/ipa-backup/SHA256SUMS" || return 1
    (cd "$ROOT/ipa-backup" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || return 1
    awk 'NR==1 && /^close=(0|1|absent)$/ {next} NR==2 && /^disabled=(0|1|absent)$/ {next} NR==3 && /^close_pending=[01]$/ {next} NR==4 && /^disabled_pending=[01]$/ {next} {bad=1} END{exit bad||NR!=4}' "$ROOT/ipa-backup/state" || return 1
    ipa_original_close=$(sed -n '1s/^close=//p' "$ROOT/ipa-backup/state")
    ipa_original_disabled=$(sed -n '2s/^disabled=//p' "$ROOT/ipa-backup/state")
    ipa_close_pending=$(sed -n '3s/^close_pending=//p' "$ROOT/ipa-backup/state")
    ipa_disabled_pending=$(sed -n '4s/^disabled_pending=//p' "$ROOT/ipa-backup/state")
}
ipa_pending_restore() {
    # Revert only the named option, preserving every unrelated UCI delta.
    if [ "$3" = 0 ]; then uci -q revert "$1"
    elif [ "$2" = absent ]; then uci -q delete "$1"
    else uci -q set "$1=$2"; fi
}
ipa_other_policy() {
    # TTL remains optional. Reading its owned two-line setting prevents VPN
    # removal from re-enabling acceleration under an independently enabled TTL.
    ttl=/data/zte-imei-ttl
    [ -e "$ttl" ] || [ -L "$ttl" ] || return 1
    if ipa_private "$ttl" && ipa_plain "$ttl/owner" && [ "$(cat "$ttl/owner")" = zte-imei-ttl-v1 ] &&
        ipa_plain "$ttl/cid" && cmp -s "$ttl/cid" "$ROOT/cid" && ipa_plain "$ttl/settings" &&
        [ ! -e "$ttl/.pending" ] && [ ! -L "$ttl/.pending" ] &&
        awk 'NR==1 && /^outbound=(off|[1-9][0-9]*)$/ {next} NR==2 && /^inbound_inc=(off|[1-9][0-9]*)$/ {next} {bad=1} END{exit bad||NR!=2}' "$ttl/settings"; then
        grep -qE '^(outbound|inbound_inc)=[1-9][0-9]*$' "$ttl/settings"
    else
        log IPA_RESTORE_PRESERVED_UNVERIFIED_TTL
        return 0
    fi
}
ipa_restore() {
    [ -e "$ROOT/ipa-backup" ] || [ -L "$ROOT/ipa-backup" ] || return 0
    ipa_tools && ipa_snapshot_valid && ipa_flags && ipa_pid || return 1
    ipa_owned_close=$ipa_close
    ipa_plain /etc/config/zwrt_router || return 1
    mkdir -p "$ROOT/ipa-uci" && ipa_private "$ROOT/ipa-uci" || return 1
    rm -f "$ROOT/ipa-uci/zwrt_router" || return 1
    lua "$ROOT/configure.lua" ipa-restore >> "$ROOT/actions.log" || return 1
    if [ "$ipa_disabled" = 1 ]; then
        ipa_pending_restore zwrt_router.other.ipa_disable "$ipa_original_disabled" "$ipa_disabled_pending" || return 1
    fi
    ipa_flags || return 1
    if ipa_other_policy; then
        uci -q set zwrt_router.tmp_router.close_ipa_acce=1 || return 1
        log IPA_RESTORE_PRESERVED_SOFTWARE_POLICY
    elif [ "$ipa_close" = 1 ] && [ "$ipa_original_close" != 1 ]; then
        ipa_pending_restore zwrt_router.tmp_router.close_ipa_acce "$ipa_original_close" "$ipa_close_pending" || return 1
    fi
    ipa_flags && ipa_pid || return 1
    # Stock USR2 is forbidden if any remaining policy still requires software.
    if [ "$ipa_close" = 1 ] || [ "$ipa_disabled" = 1 ]; then kill -USR1 "$ipacm_pid" || return 1
    elif [ "$ipa_owned_close" = 1 ]; then kill -USR2 "$ipacm_pid" || return 1; fi
    # Keep the latest verified original for diagnostics, without accumulating
    # new configuration backups on every unsuccessful activation attempt.
    if [ -e "$ROOT/ipa-restored" ] || [ -L "$ROOT/ipa-restored" ]; then
        ipa_private "$ROOT/ipa-restored" || return 1
        rm -rf "$ROOT/ipa-restored" || return 1
    fi
    mv "$ROOT/ipa-backup" "$ROOT/ipa-restored" || return 1
    rm -f "$ROOT/ipa-runtime" || return 1
    sync
    log IPA_RESTORED
}
ipa_prepare() {
    ipa_tools || fail VPN_IPA_UNSUPPORTED
    ipa_flags || fail VPN_IPA_STATE_INVALID
    ipa_pid || fail VPN_IPA_NOT_RUNNING
    ipa_plain /etc/config/zwrt_router || fail VPN_IPA_STATE_INVALID
    if [ ! -e "$ROOT/ipa-backup" ] && [ ! -L "$ROOT/ipa-backup" ]; then
        # This staging directory never contains live changes.
        if [ -e "$ROOT/ipa-backup.preparing" ]; then
            ipa_private "$ROOT/ipa-backup.preparing" || fail VPN_IPA_STATE_INVALID
            rm -rf "$ROOT/ipa-backup.preparing"
        fi
        mkdir "$ROOT/ipa-backup.preparing" "$ROOT/ipa-backup.preparing/deltas"
        cp -p /etc/config/zwrt_router "$ROOT/ipa-backup.preparing/zwrt_router"
        ipa_changes=$(uci -q changes zwrt_router) || fail VPN_IPA_STATE_INVALID
        close_pending=0; disabled_pending=0
        printf '%s\n' "$ipa_changes" | grep -Eq '^[+-]?zwrt_router\.tmp_router(\.close_ipa_acce)?(=|$)' && close_pending=1
        printf '%s\n' "$ipa_changes" | grep -Eq '^[+-]?zwrt_router\.other(\.ipa_disable)?(=|$)' && disabled_pending=1
        printf 'close=%s\ndisabled=%s\nclose_pending=%s\ndisabled_pending=%s\n' "$ipa_close" "$ipa_disabled" "$close_pending" "$disabled_pending" > "$ROOT/ipa-backup.preparing/state"
        (cd "$ROOT/ipa-backup.preparing" && sha256sum state zwrt_router > SHA256SUMS)
        cmp -s /etc/config/zwrt_router "$ROOT/ipa-backup.preparing/zwrt_router" || fail VPN_IPA_STATE_INVALID
        mv "$ROOT/ipa-backup.preparing" "$ROOT/ipa-backup"
        sync
    fi
    ipa_snapshot_valid || fail VPN_IPA_STATE_INVALID
    mkdir -p "$ROOT/ipa-uci"; ipa_private "$ROOT/ipa-uci" || fail VPN_IPA_STATE_INVALID
    rm -f "$ROOT/ipa-uci/zwrt_router"
    lua "$ROOT/configure.lua" ipa-prepare >> "$ROOT/actions.log" || fail VPN_IPA_PREPARE_FAILED
    uci -q set zwrt_router.other.ipa_disable=1 || fail VPN_IPA_PREPARE_FAILED
    uci -q set zwrt_router.tmp_router.close_ipa_acce=1 || fail VPN_IPA_PREPARE_FAILED
    before_pid=$ipacm_pid
    kill -USR1 "$ipacm_pid" || fail VPN_IPA_PREPARE_FAILED
    ipa_flags && ipa_pid && [ "$ipa_close:$ipa_disabled" = 1:1 ] && [ "$ipacm_pid" = "$before_pid" ] || fail VPN_IPA_PREPARE_FAILED
    printf '%s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$ipacm_pid" > "$ROOT/ipa-runtime"
    log IPA_PREPARED
}
ipa_active() {
    # The pinned stock 'on' path can set close=0, but cannot send USR2 while
    # our persistent ipa_disable=1 policy is present (for example TTL disable).
    ipa_flags && ipa_pid && [ "$ipa_disabled" = 1 ] &&
    [ "$(cat "$ROOT/ipa-runtime" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id) $ipacm_pid" ]
}
configuration_restore() {
    [ -e "$ROOT/backup" ] || [ -L "$ROOT/backup" ] || return 0
    [ ! -e "$ROOT/configured" ] && ipa_private "$ROOT/backup" || return 1
    if [ -e "$ROOT/configuring" ] || [ -L "$ROOT/configuring" ]; then ipa_plain "$ROOT/configuring" || return 1; fi
    ipa_plain "$ROOT/backup/SHA256SUMS" &&
    awk 'NF!=2 || $2!~/^(network|wireless|firewall|dhcp|network.init)$/ || length($1)!=64 || $1~/[^0-9a-f]/ || seen[$2]++ {bad=1} END{exit bad||NR!=5}' "$ROOT/backup/SHA256SUMS" || return 1
    (cd "$ROOT/backup" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || return 1
    ipa_plain /etc/init.d/network || return 1
    if ! cmp -s /etc/init.d/network "$ROOT/backup/network.init"; then
        ipa_plain "$ROOT/network-init.sha256" && [ "$(ipa_hash /etc/init.d/network)" = "$(cat "$ROOT/network-init.sha256")" ] || return 1
    fi
    lua "$ROOT/configure.lua" restore >> "$ROOT/actions.log" || return 1
    "$ROOT/firewall.sh" remove || return 1
    cp -p "$ROOT/backup/network.init" /etc/init.d/network.vpn-restore && mv /etc/init.d/network.vpn-restore /etc/init.d/network || return 1
    ubus -t 15 call network reload '{}' >> "$ROOT/reload.log" 2>&1 || return 1
    if [ -e "$ROOT/backup.failed" ] || [ -L "$ROOT/backup.failed" ]; then
        ipa_private "$ROOT/backup.failed" && rm -rf "$ROOT/backup.failed" || return 1
    fi
    mv "$ROOT/backup" "$ROOT/backup.failed" || return 1
    rm -f "$ROOT/configuring" "$ROOT/network-init.sha256" || return 1
    log CONFIGURATION_ROLLED_BACK
}
ipa_failure_restore() {
    result=$?; trap - EXIT HUP INT TERM
    if [ "$result" != 0 ] && [ "$MODE" = enable ]; then
        # Failed enable must not leave a hidden tunnel or respawning workers.
        disable_guest
        stop_backend || true
        reload_wifi || true
    fi
    if [ "$result" != 0 ] && [ ! -f "$ROOT/configured" ] && [ -d "$ROOT/ipa-backup" ]; then
        if configuration_restore; then
            if ! ipa_restore; then log VPN_IPA_RESTORE_FAILED; echo VPN_IPA_RESTORE_FAILED >&2; fi
        else log VPN_CONFIGURATION_PENDING; echo VPN_CONFIGURATION_PENDING >&2; fi
    fi
    exit "$result"
}
prepare() {
    case "$(sha256sum /firmware/image/modem.b16 2>/dev/null | awk '{print $1}')" in
        604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263|5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478) ;;
        *) b04_profile || b27_profile || fail VPN_UNSUPPORTED_FIRMWARE;;
    esac
    [ "$(cat "$ROOT/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" ] || fail VPN_DEVICE_CHANGED
    [ "$(uci -q get wireless.zte_mbb.mesh_onoff)" = 0 ] || fail VPN_MESH_CONFLICT
    if [ ! -f "$ROOT/configured" ]; then configuration_restore || fail VPN_CONFIGURATION_PENDING; fi
    if [ ! -f "$ROOT/configured" ]; then
        [ ! -e "$ROOT/backup" ] || fail VPN_CONFIGURATION_PENDING
        [ "$(uci -q get wireless.guest_2g.disabled)" = 1 ] && [ "$(uci -q get wireless.guest_5g.disabled)" = 1 ] || fail VPN_GUEST_IN_USE
        [ -z "$(pidof clash 2>/dev/null || true)" ] || fail VPN_OTHER_PROXY
        ! ip route show table all | grep -q '192.168.50.' || fail VPN_SUBNET_CONFLICT
        [ -z "$(ip route show table 19090)" ] || fail VPN_ROUTE_CONFLICT
        ! ip rule show | grep -q '^19000:' || fail VPN_ROUTE_CONFLICT
        for pkg in network wireless firewall; do [ -z "$(uci -q changes "$pkg")" ] || fail VPN_PENDING_CHANGES; done
        ipa_prepare
        if [ -e "$ROOT/backup.preparing" ]; then ipa_private "$ROOT/backup.preparing" || fail VPN_CONFIGURATION_PENDING; rm -rf "$ROOT/backup.preparing"; fi
        mkdir "$ROOT/backup.preparing"
        mkdir -p "$ROOT/backup-deltas" "$ROOT/uci"
        ipa_private "$ROOT/backup-deltas" && ipa_private "$ROOT/uci" || fail VPN_CONFIGURATION_PENDING
        for pkg in network wireless firewall dhcp; do cp -p "/etc/config/$pkg" "$ROOT/backup.preparing/$pkg"; done
        cp -p /etc/init.d/network "$ROOT/backup.preparing/network.init"
        (cd "$ROOT/backup.preparing" && sha256sum network wireless firewall dhcp network.init > SHA256SUMS)
        touch "$ROOT/configuring"
        mv "$ROOT/backup.preparing" "$ROOT/backup"
        sync
        # Root-owned pinned hook is installed before the APs can be enabled.
        "$ROOT/vpnctl" hook-network
        prepare_backend
        "$ROOT/firewall.sh"
        lua "$ROOT/configure.lua" apply >> "$ROOT/actions.log"
        ubus -t 15 call network reload '{}' >> "$ROOT/reload.log" 2>&1
    else
        prepare_backend
        ipa_prepare
    fi
    for n in $(seq 1 20); do
        ip -4 addr show br-vpn 2>/dev/null | grep -q '192.168.50.1/24' && break
        sleep 1
    done
    ip -4 addr show br-vpn | grep -q '192.168.50.1/24' || fail VPN_BRIDGE_NOT_READY
    "$ROOT/firewall.sh"
    if [ ! -f "$ROOT/configured" ]; then
        mv "$ROOT/configuring" "$ROOT/configured"
        sync
    fi
}
runtime_process() {
    runtime_pid=$(cat "$ROOT/$1.pid" 2>/dev/null) || return 1
    case "$runtime_pid" in ''|*[!0-9]*) return 1;; esac
    test -r "/proc/$runtime_pid/cmdline" || return 1
    tr '\000' '\n' < "/proc/$runtime_pid/cmdline" | grep -Fx -- "$2" >/dev/null
}
wait_core() {
    kind=$(backend) || return 1
    if [ "$kind" = ikev2 ]; then
        n=0
        while [ "$n" -lt 20 ]; do
            if "$ROOT/ikev2.sh" ready && runtime_process dns "--conf-file=$ROOT/ikev2/dnsmasq.conf"; then
                "$ROOT/firewall.sh"; return 0
            fi
            n=$((n+1)); sleep 1
        done
        fail VPN_DHCP_NOT_READY
    fi
    n=0
    while [ "$n" -lt 20 ]; do
        if runtime_process core "$CORE" && [ -e /sys/class/net/zvpn-tun ]; then
            if ! runtime_process dns "--conf-file=$ROOT/dnsmasq.conf"; then
                n=$((n+1)); sleep 1; continue
            fi
            "$ROOT/firewall.sh"; return 0
        fi
        n=$((n+1)); sleep 1
    done
    if runtime_process core "$CORE" && [ -e /sys/class/net/zvpn-tun ]; then fail VPN_DHCP_NOT_READY; fi
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
guest_selection() {
    case "$1" in
        wlan1) selection_section=guest_2g; selection_radio=wifi0;;
        wlan3) selection_section=guest_5g; selection_radio=wifi1;;
        *) return 1;;
    esac
    case "$(uci -q get wireless.$selection_section.disabled 2>/dev/null)" in
        1) printf disabled; return 0;;
        0) ;;
        *) return 1;;
    esac
    # An omitted radio disabled option means enabled in UCI. Respect a band
    # explicitly switched off even when its guest section remains enabled.
    case "$(uci -q get wireless.$selection_radio.disabled 2>/dev/null || true)" in
        1) printf disabled;;
        0|'') printf enabled;;
        *) return 1;;
    esac
}
guest_selection_ready() {
    for dev in wlan1 wlan3; do
        selection=$(guest_selection "$dev") || return 1
        [ "$selection" != disabled ] || continue
        # The administrative UP flag does not require a connected client.
        ip link show dev "$dev" 2>/dev/null | head -1 | grep -Eq '<([^>]*,)?UP(,|>)' || return 1
        readlink "/sys/class/net/$dev/master" 2>/dev/null | grep -q '/br-vpn$' || return 1
        hostapd_cli -p /data/vendor/wifi/hostapd -i "$dev" status 2>/dev/null | grep -q '^state=ENABLED$' || return 1
    done
}
resume_guest() {
    # Called only after the guard verified IPA, firewall and backend/DHCP.
    # A vendor reload with unchanged UCI may leave our suspended ports DOWN.
    # Restore just these existing APs; never enable a guest, band or hostapd.
    for dev in wlan1 wlan3; do
        selection=$(guest_selection "$dev") || return 1
        [ "$selection" != disabled ] || continue
        readlink "/sys/class/net/$dev/master" 2>/dev/null | grep -q '/br-vpn$' || return 1
        hostapd_cli -p /data/vendor/wifi/hostapd -i "$dev" status 2>/dev/null | grep -q '^state=ENABLED$' || return 1
        if ! ip link show dev "$dev" 2>/dev/null | head -1 | grep -Eq '<([^>]*,)?UP(,|>)'; then
            selection=$(guest_selection "$dev") || return 1
            [ "$selection" != disabled ] || continue
            ip link set "$dev" up || return 1
            # If the user disabled the guest/band during the link operation,
            # put this port back down instead of retaining a stale selection.
            selection=$(guest_selection "$dev") || { ip link set "$dev" down; return 1; }
            [ "$selection" != disabled ] || ip link set "$dev" down || return 1
        fi
    done
    guest_selection_ready
}
case "${1:-}" in prepare|activate|enable)
    trap ipa_failure_restore EXIT
    trap 'exit 1' HUP INT TERM
    ;;
esac
case "${1:-}" in
 runtime-wanted) runtime_wanted;;
 ipa-check) ipa_snapshot_valid && ipa_tools && ipa_flags || fail VPN_IPA_STATE_INVALID;;
 ipa-restore) ipa_restore || fail VPN_IPA_RESTORE_FAILED;;
 prepare) prepare;;
 activate)
    stop_backend
    prepare
    if runtime_wanted; then
        /etc/init.d/zte_vpn start
        wait_core || fail VPN_CORE_NOT_READY
    else
        # Selecting/updating a profile while Wi-Fi is off saves it without
        # leaving a tunnel, authentication attempt or owned XFRM device behind.
        stop_backend
    fi
    log PROFILE_ACTIVATED
    ;;
 enable)
    [ -f "$ROOT/config.json" ] || fail VPN_NO_ACTIVE_PROFILE
    # Repeated enable is idempotent, including a pending or rejected MFA PUSH.
    if runtime_wanted; then
        if [ "$(uci -q get wireless.guest_2g.disabled 2>/dev/null || true)" = 0 ] &&
           [ "$(uci -q get wireless.guest_5g.disabled 2>/dev/null || true)" = 0 ]; then
            log WIFI_ALREADY_ENABLED; exit 0
        fi
        # Re-enable a guest section that was changed independently, retaining
        # the existing tunnel and authentication attempt on the other band.
        lua "$ROOT/configure.lua" enable >> "$ROOT/actions.log"
        reload_wifi
        wait_wifi || fail VPN_WIFI_NOT_READY
        "$ROOT/firewall.sh"
        log WIFI_ENABLED
        exit 0
    fi
    stop_backend
    prepare
    # Persist ON before service registration. APs remain suspended until the
    # backend/DHCP guard is ready and the explicit reload below succeeds.
    lua "$ROOT/configure.lua" enable >> "$ROOT/actions.log"
    rm -f "$ROOT/runtime-disabled"
    /etc/init.d/zte_vpn start
    wait_core || fail VPN_CORE_NOT_READY
    reload_wifi
    if ! wait_wifi; then disable_guest; reload_wifi || true; fail VPN_WIFI_NOT_READY; fi
    "$ROOT/firewall.sh"
    log WIFI_ENABLED
    ;;
 disable)
    # Persist OFF before stopping procd so a racing respawn cannot connect.
    : > "$ROOT/runtime-disabled"
    if [ -f "$ROOT/configured" ]; then
        lua "$ROOT/configure.lua" disable >> "$ROOT/actions.log" || { stop_backend; fail VPN_OPERATION_FAILED; }
    fi
    stop_backend
    [ ! -f "$ROOT/configured" ] || reload_wifi
    log WIFI_DISABLED
    ;;
 early)
    [ -f "$ROOT/configured" ] || exit 0
    recover
    if ! runtime_wanted; then stop_backend; log BOOT_WIFI_DISABLED; exit 0; fi
    if prepare_backend && "$ROOT/vpnctl" integrity >/dev/null 2>&1 && "$ROOT/firewall.sh" >> "$ROOT/firewall.log" 2>&1 && /etc/init.d/zte_vpn start; then
        # Register respawning workers before netifd. The vendor boot sequence
        # does not reliably run S99, and ipacm may still be restarting here.
        # run-core verifies IPA before starting the core; guard holds the APs.
        log BOOT_GUARD_READY
    else
        disable_guest; stop_backend || true; log BOOT_GUARD_FAILED; exit 1
    fi
    ;;
 recover)
    stop_backend
    recover
    if [ ! -f "$ROOT/configured" ]; then
        configuration_restore || fail VPN_CONFIGURATION_PENDING
        ipa_restore || fail VPN_IPA_RESTORE_FAILED
    fi
    if runtime_wanted; then
        prepare_backend
        "$ROOT/firewall.sh"
        /etc/init.d/zte_vpn start
    fi
    ;;
 run-core)
    runtime_wanted || exit 0
    "$ROOT/vpnctl" integrity >/dev/null
    [ -s "$ROOT/config.json" ] || exit 1
    ipa_active || ipa_prepare
    [ ! -f "$ROOT/core.log" ] || [ "$(wc -c < "$ROOT/core.log")" -lt 1048576 ] || mv "$ROOT/core.log" "$ROOT/core.previous.log"
    echo $$ > $ROOT/core.pid
    kind=$(backend)
    runtime_wanted || exit 0
    if [ "$kind" = ikev2 ]; then
        exec "$ROOT/ikev2.sh" run >> "$ROOT/core.log" 2>&1
    fi
    exec "$CORE" -d "$ROOT" -f "$ROOT/config.json" >> "$ROOT/core.log" 2>&1
    ;;
 run-dns)
    runtime_wanted || exit 0
    [ ! -f "$ROOT/dns.log" ] || [ "$(wc -c < "$ROOT/dns.log")" -lt 1048576 ] || mv "$ROOT/dns.log" "$ROOT/dns.previous.log"
    echo $$ > $ROOT/dns.pid
    config=$(dns_config)
    runtime_wanted || exit 0
    exec dnsmasq --keep-in-foreground --conf-file="$config" >> "$ROOT/dns.log" 2>&1
    ;;
 run-guard)
    # A previous core/guard process may have held APs down before this worker
    # started. Reconcile against current UCI and actual interfaces immediately.
    suspended=1; restart_pid=
    while runtime_wanted; do
        current_backend=$(backend) || { suspend_guest; exit 1; }
        ready=1
        if ! ipa_active; then
            ready=0; [ "$suspended" = 1 ] || log VPN_IPA_PREPARE_FAILED
            suspend_guest
            if [ "$current_backend" = ikev2 ]; then
                # Repair acceleration policy without restarting authentication
                # or issuing another MFA PUSH. APs remain down until verified.
                ipa_prepare
            elif runtime_process core "$CORE" && [ "$runtime_pid" != "$restart_pid" ] &&
                [ "$(readlink "/proc/$runtime_pid/exe" 2>/dev/null)" = "$CORE" ]; then
                if kill -TERM "$runtime_pid"; then restart_pid=$runtime_pid; log IPA_CORE_RESTART; fi
            fi
        else restart_pid=; fi
        if ! "$ROOT/firewall.sh" >> "$ROOT/firewall.log" 2>&1; then ready=0; [ "$suspended" = 1 ] || log FIREWALL_FAILED; fi
        if [ "$current_backend" = ikev2 ]; then
            # Preserve public LTE during IKE reconnect or daemon failure.
            "$ROOT/ikev2.sh" ready && runtime_process dns "--conf-file=$ROOT/ikev2/dnsmasq.conf" || ready=0
        else
            runtime_process core "$CORE" && [ -e /sys/class/net/zvpn-tun ] &&
                runtime_process dns "--conf-file=$ROOT/dnsmasq.conf" || ready=0
        fi
        for dev in wlan1 wlan3; do
            master=$(readlink "/sys/class/net/$dev/master" 2>/dev/null || true)
            case "$master" in */br-vpn|'') ;; *) ready=0; [ "$suspended" = 1 ] || log BRIDGE_MISMATCH;; esac
        done
        if [ "$ready" = 0 ]; then
            suspend_guest; suspended=1
        elif [ "$suspended" = 1 ] || ! guest_selection_ready; then
            # Reload uses the current UCI selection, including a user disable
            # made while we were waiting. A failed reload is retried next pass.
            if guest_selection_ready || resume_guest || { reload_wifi && resume_guest; }; then
                suspended=0; log RUNTIME_WIFI_RESTORED
            else suspended=1; fi
        fi
        sleep 5
    done
    ;;
 *) fail VPN_INVALID_COMMAND;;
esac
