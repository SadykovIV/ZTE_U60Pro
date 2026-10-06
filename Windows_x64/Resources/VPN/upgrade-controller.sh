#!/bin/sh
# Upgrade only recognized controllers; keep a complete rollback snapshot.
set -eu
umask 077
ROOT=/data/zte-vpn
stage=${1:-}

helper_sha=f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c
manager_sha=f836b522c48a115c75233594207191214459f624180b7f98fabb754517d695b1
configure_sha=a41e5de83268c6963a54760c8b5f5362ea2c5cdac81bede6ac281fea81e28543
network_stock_sha=093e5461be5ea5d23d24522374a27b9a134c4932df3c89b3b756274f123ac508
hash() { sha256sum "$1" | awk '{print $1}'; }
known() {
    case "$1" in 8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827|96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88|48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4|572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5|80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23|3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3|e2ffd02708220d332bf31f7f1f4c3abe369fbc2af1665af885c1f4375a884ff0|c67f5fdc44ee1f90c38dca15fd452c18743def22f776018aaac270863eafb229|bdc6aa07f217ce38e34e113d279e0d983d307fefd0f58027a9c221861f953dbf|9c2e3c21eecace7031c4029c969efdec44241f000716447df805f3020dfce95e|29e98c9301609b4f20ea94c7e8b208c25786690be451bae05145721a35b91179|9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce|cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0|3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca|f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4|1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231|a388d8fa771b3e4bb46d500202ff750df410b4e6608d0f4902288b6aad16d731|7a12d8b869d064229270a264e8de9adf64f620337995fb186854c35cadbee068|7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb|1c0e3e6d308a6c4b161faf896a00437b8e011fe5b7eff7969b9870c85d8d0c5c|"$helper_sha") return 0;; *) return 1;; esac
}

# Only fixed codes leave this script. Never echo helper output, state or profiles.
phase=INVALID_STAGE
fail() { phase=$1; exit 1; }
plain() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%h "$1")" = 0:1 ] || return 1
    perm=$(stat -c %a "$1") || return 1
    [ "$((0$perm & 022))" = 0 ]
}
private_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a "$1")" = 0:700 ]; }
integrity() {
    if reply=$("$ROOT/vpnctl" integrity); then return 0; fi
    case "$reply" in
      '{"code":"VPN_NOT_INSTALLED","ok":false}') cause=VPN_NOT_INSTALLED;;
      '{"code":"VPN_FILE_UNAVAILABLE","ok":false}') cause=VPN_FILE_UNAVAILABLE;;
      '{"code":"VPN_UNSAFE_FILE","ok":false}') cause=VPN_UNSAFE_FILE;;
      '{"code":"VPN_INTEGRITY","ok":false}') cause=VPN_INTEGRITY;;
      '{"code":"VPN_DEVICE_CHANGED","ok":false}') cause=VPN_DEVICE_CHANGED;;
      '{"code":"VPN_CORE_INTEGRITY","ok":false}') cause=VPN_CORE_INTEGRITY;;
      '{"code":"VPN_UNSUPPORTED_FIRMWARE","ok":false}') cause=VPN_UNSUPPORTED_FIRMWARE;;
      *) cause=VPN_INTEGRITY;;
    esac
    printf 'VPN_UPGRADE_CAUSE %s\n' "$cause" >&2
    return 1
}
same_device() { [ "$(cat "$ROOT/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" ] && [ "$(cat "$ROOT/cid")" = "$cid" ]; }
service=/etc/init.d/zte_vpn
links='S99zte_vpn K01zte_vpn'
state_names='configured network-init.sha256 backup backup-deltas uci'
backup="$ROOT/controller-upgrade"
restore() {
    [ -f "$backup/ready" ] && [ ! -L "$backup/ready" ] || return 0
    known "$(hash "$backup/vpnctl")" || return 1
    (cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || return 1
    if [ -d "$backup/planned" ]; then
        # A failed update does not authorize overwriting another writer. Every
        # present target must still be either its snapshot or our planned bytes.
        for name in vpnctl manager.sh configure.lua network service; do
            case "$name" in network) target=/etc/init.d/network;; service) target=$service;; *) target=$ROOT/$name;; esac
            if [ -e "$target" ] || [ -L "$target" ]; then
                plain "$target" || return 1
                observed=$(hash "$target") || return 1
                previous=; planned=
                [ ! -f "$backup/$name" ] || previous=$(hash "$backup/$name")
                [ ! -f "$backup/planned/$name" ] || planned=$(cat "$backup/planned/$name")
                [ "$observed" = "$previous" ] || [ "$observed" = "$planned" ] || return 1
            elif [ -f "$backup/$name" ]; then return 1
            fi
        done
        for name in $links; do
            link=/etc/rc.d/$name
            if [ -e "$link" ] || [ -L "$link" ]; then
                [ -L "$link" ] && [ "$(stat -c %u "$link")" = 0 ] && [ "$(readlink "$link")" = ../init.d/zte_vpn ] || return 1
            fi
        done
    fi
    # New snapshots include absence and renamed stale configuration. Refuse a
    # concurrent replacement before restoring any of these objects.
    if [ -f "$backup/reset-v1" ]; then
        for name in $state_names; do
            if [ -e "$backup/reset-state/$name" ] || [ -L "$backup/reset-state/$name" ]; then
                [ ! -e "$ROOT/$name" ] && [ ! -L "$ROOT/$name" ] || return 1
            fi
        done
    fi
    for name in vpnctl manager.sh configure.lua; do
        cp -p "$backup/$name" "$ROOT/$name.restore" || return 1
        mv "$ROOT/$name.restore" "$ROOT/$name" || return 1
    done
    cp -p "$backup/network" /etc/init.d/network.vpn-restore && mv /etc/init.d/network.vpn-restore /etc/init.d/network || return 1
    if [ -f "$backup/service-v1" ]; then
        if [ -f "$backup/service" ]; then cp -p "$backup/service" "$service.vpn-restore" && mv "$service.vpn-restore" "$service" || return 1
        else [ ! -e "$service" ] || { cmp -s "$service" "$ROOT/service.sh" && rm "$service"; } || return 1; fi
        for name in $links; do
            link=/etc/rc.d/$name
            if [ -f "$backup/link-$name" ]; then
                if [ -L "$link" ]; then [ "$(readlink "$link")" = ../init.d/zte_vpn ] || return 1
                else [ ! -e "$link" ] && ln -s ../init.d/zte_vpn "$link" || return 1; fi
            elif [ -e "$link" ] || [ -L "$link" ]; then
                [ -L "$link" ] && [ "$(readlink "$link")" = ../init.d/zte_vpn ] && rm "$link" || return 1
            fi
        done
    fi
    if [ -f "$backup/reset-v1" ]; then
        for name in $state_names; do
            if [ -e "$backup/reset-state/$name" ]; then mv "$backup/reset-state/$name" "$ROOT/$name" || return 1; fi
        done
    elif [ -f "$backup/network-init.sha256" ]; then cp -p "$backup/network-init.sha256" "$ROOT/network-init.sha256" || return 1
    elif [ -f "$backup/service-v1" ]; then rm -f "$ROOT/network-init.sha256" || return 1
    fi
    sync
    integrity || return 1
    rm -rf "$backup"
}
committed=0
transaction_started=0
finish() {
    result=$?; trap - EXIT HUP INT TERM
    if [ "$result" != 0 ]; then
        if [ "$transaction_started" = 1 ] && [ "$committed" = 0 ]; then
            if same_device && restore; then printf 'VPN_UPGRADE_ROLLBACK restored\n' >&2
            else phase=ROLLBACK_UNKNOWN; fi
        fi
        printf 'VPN_UPGRADE_ERROR %s\n' "$phase" >&2
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) fail INVALID_STAGE;; esac
private_dir "$ROOT" && private_dir "$stage" || fail UNSAFE_LAYOUT
for name in transaction transaction.preparing transaction.done; do
    [ ! -e "$ROOT/$name" ] && [ ! -L "$ROOT/$name" ] || fail VPN_PENDING
done
for file in vpnctl manager.sh configure.lua; do plain "$stage/$file" || fail PAYLOAD; done
[ "$(hash "$stage/vpnctl")" = "$helper_sha" ] && [ "$(hash "$stage/manager.sh")" = "$manager_sha" ] &&
[ "$(hash "$stage/configure.lua")" = "$configure_sha" ] || fail PAYLOAD
[ ! -e /tmp/zte-vpn-screen ] && [ ! -L /tmp/zte-vpn-screen ] || fail SCREEN_BUSY
plain "$ROOT/cid" || fail DEVICE_CHANGED
cid=$(cat "$ROOT/cid"); same_device || fail DEVICE_CHANGED
if [ -e "$backup" ] || [ -L "$backup" ]; then
    private_dir "$backup" || fail RECOVERY_REQUIRED
    restore || fail RECOVERY_REQUIRED
    [ ! -e "$backup" ] || fail RECOVERY_REQUIRED
fi
plain "$ROOT/vpnctl" && known "$(hash "$ROOT/vpnctl")" || fail CONTROLLER_UNKNOWN
integrity || fail OLD_INTEGRITY
plain /etc/init.d/network || fail NETWORK_CHANGED
network_before=$(hash /etc/init.d/network)
reset=0
if [ -e "$ROOT/configured" ] || [ -L "$ROOT/configured" ]; then
    plain "$ROOT/configured" || fail STATE_UNSAFE
    if [ "$network_before" = "$network_stock_sha" ]; then reset=1
    else
        plain "$ROOT/network-init.sha256" && [ "$network_before" = "$(cat "$ROOT/network-init.sha256")" ] &&
        grep -q 'BEGIN zte-vpn-v1:' /etc/init.d/network || fail NETWORK_CHANGED
    fi
else
    [ "$network_before" = "$network_stock_sha" ] || {
        plain "$ROOT/network-init.sha256" && [ "$network_before" = "$(cat "$ROOT/network-init.sha256")" ] || fail NETWORK_CHANGED
    }
fi
service_missing=0
if [ -e "$service" ] || [ -L "$service" ]; then plain "$service" && cmp -s "$service" "$ROOT/service.sh" || fail SERVICE_CHANGED
else service_missing=1; fi
[ -d /etc/rc.d ] && [ ! -L /etc/rc.d ] && [ "$(stat -c %u /etc/rc.d)" = 0 ] || fail STARTUP_CHANGED
perm=$(stat -c %a /etc/rc.d); [ "$((0$perm & 022))" = 0 ] || fail STARTUP_CHANGED
for name in $links; do
    link=/etc/rc.d/$name
    if [ -e "$link" ] || [ -L "$link" ]; then
        [ -L "$link" ] && [ "$(stat -c %u "$link")" = 0 ] && [ "$(readlink "$link")" = ../init.d/zte_vpn ] || fail STARTUP_CHANGED
    fi
done
if [ "$reset" = 1 ]; then
    for name in $state_names; do
        if [ -e "$ROOT/$name" ] || [ -L "$ROOT/$name" ]; then
            case "$name" in backup|backup-deltas|uci) private_dir "$ROOT/$name" || fail STATE_UNSAFE;;
                *) plain "$ROOT/$name" || fail STATE_UNSAFE;; esac
        fi
    done
fi
old_helper=$(hash "$ROOT/vpnctl"); old_manager=$(hash "$ROOT/manager.sh")
archive="$ROOT/controller-reset-${stage##*/zte-vpn-agent-}"
[ "$reset" = 0 ] || { [ ! -e "$archive" ] && [ ! -L "$archive" ]; } || fail SNAPSHOT
phase=SNAPSHOT
mkdir "$backup"
for file in vpnctl manager.sh configure.lua; do cp -p "$ROOT/$file" "$backup/$file"; done
cp -p /etc/init.d/network "$backup/network"
if [ -e "$ROOT/network-init.sha256" ]; then plain "$ROOT/network-init.sha256" || fail STATE_UNSAFE; cp -p "$ROOT/network-init.sha256" "$backup/network-init.sha256"; fi
if [ "$service_missing" = 0 ]; then cp -p "$service" "$backup/service"; fi
for name in $links; do [ ! -L /etc/rc.d/$name ] || : > "$backup/link-$name"; done
: > "$backup/service-v1"
if [ "$reset" = 1 ]; then mkdir "$backup/reset-state"; : > "$backup/reset-v1"; fi
(cd "$backup" && sha256sum vpnctl manager.sh configure.lua network > SHA256SUMS
 for file in service network-init.sha256; do [ ! -f "$file" ] || sha256sum "$file" >> SHA256SUMS; done)
mkdir "$backup/planned"
for name in vpnctl manager.sh configure.lua; do hash "$stage/$name" > "$backup/planned/$name"; done
hash "$ROOT/service.sh" > "$backup/planned/service"
if [ "$reset" = 0 ]; then
    sed -e "s/$old_helper/$helper_sha/g" -e "s/$old_manager/$manager_sha/g" "$backup/network" > "$backup/network.planned"
else cp -p "$backup/network" "$backup/network.planned"; fi
sh -n "$backup/network.planned"
hash "$backup/network.planned" > "$backup/planned/network"
sync
: > "$backup/ready"; sync
transaction_started=1
same_device || fail DEVICE_CHANGED
[ "$(hash /etc/init.d/network)" = "$network_before" ] || fail NETWORK_CHANGED
phase=WRITE
if [ "$reset" = 1 ]; then
    for name in $state_names; do [ ! -e "$ROOT/$name" ] || mv "$ROOT/$name" "$backup/reset-state/$name"; done
fi
for file in vpnctl manager.sh configure.lua; do cp "$stage/$file" "$ROOT/$file.new"; chmod 700 "$ROOT/$file.new"; done
if [ "$reset" = 0 ]; then
    cp "$backup/network.planned" /etc/init.d/network.vpn-new
    chmod 755 /etc/init.d/network.vpn-new; sh -n /etc/init.d/network.vpn-new
fi
for file in manager.sh configure.lua vpnctl; do mv "$ROOT/$file.new" "$ROOT/$file"; done
integrity || fail NEW_INTEGRITY
if [ "$reset" = 0 ]; then
    mv /etc/init.d/network.vpn-new /etc/init.d/network
    hash /etc/init.d/network > "$ROOT/network-init.sha256"
fi
if [ "$service_missing" = 1 ]; then
    cp "$ROOT/service.sh" "$service.vpn-new"; chmod 755 "$service.vpn-new"; mv "$service.vpn-new" "$service"
fi
for name in $links; do
    link=/etc/rc.d/$name
    [ -L "$link" ] || ln -s ../init.d/zte_vpn "$link"
done
phase=VERIFY
same_device && cmp -s "$service" "$ROOT/service.sh" || fail VERIFY
for name in $links; do [ -L /etc/rc.d/$name ] && [ "$(readlink /etc/rc.d/$name)" = ../init.d/zte_vpn ] || fail VERIFY; done
if [ "$reset" = 1 ]; then
    [ "$(hash /etc/init.d/network)" = "$network_stock_sha" ] && [ ! -e "$ROOT/configured" ] || fail VERIFY
    # Preserve reset-era configuration and backups. A later explicit VPN action
    # backs up the current UCI settings before configuring; this update never does.
    printf 'complete\n' > "$backup/state"; sync
    mv "$backup" "$archive"; sync
else
    [ ! -e "$ROOT/controller-upgrade.done" ] || rm -rf "$ROOT/controller-upgrade.done"
    mv "$backup" "$ROOT/controller-upgrade.done"; sync
fi
committed=1
[ "$reset" = 1 ] || rm -rf "$ROOT/controller-upgrade.done"
printf 'VPN_CONTROLLER_UPDATED\n'
