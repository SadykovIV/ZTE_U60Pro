#!/bin/sh
# ZTE IMEI Studio: remove only its verified SSClash installation.
# prepare creates a private archive; commit requires its SHA-256 after the Mac saved it.
set -eu
umask 077
export LC_ALL=C
ROOT=/data/zte-imei-apps/ssclash
BASE=/data/zte-imei-apps
SERVICE=/etc/init.d/zte_imei_ssclash
RECOVERY=/data/zte-imei-apps/.removals
fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" = 4 ] || [ "$#" = 5 ] || fail 'Invalid removal arguments'
ACTION=$1 TOKEN=$2 BINARY_HASH=$3 SERVICE_HASH=$4
printf '%s\n' "$TOKEN" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail 'Invalid removal identifier'
for hash in "$BINARY_HASH" "$SERVICE_HASH"; do
    printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{64}$' || fail 'Invalid expected hash'
done
TXN=$RECOVERY/$TOKEN
safe_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u' "$1")" = 0 ] || fail "Unsafe directory: $1"
    mode=$(stat -c '%a' "$1")
    [ "$((0$mode & 022))" = 0 ] || fail "Writable directory: $1"
}
safe_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u' "$1")" = 0 ] || fail "Unsafe file: $1"
    mode=$(stat -c '%a' "$1")
    [ "$((0$mode & 022))" = 0 ] || fail "Writable file: $1"
}
file_hash() { sha256sum "$1" | awk '{print $1}'; }
base_guards() {
    for dir in /data "$BASE" /etc/init.d /etc/rc.d; do safe_dir "$dir"; done
    safe_file "$BASE/.zte-imei-owner"
    [ "$(cat "$BASE/.zte-imei-owner")" = zte-imei-apps-v1 ] || fail 'Unknown application directory'
    [ ! -e /tmp/fota_install_processing ] || fail 'Firmware update is in progress'
    [ ! -e /data/zte-imei-studio/installations/active ] && [ ! -L /data/zte-imei-studio/installations/active ] && [ ! -e /data/local/tmp/zte-imei-installations/active ] || fail 'Another installation is pending'
    [ ! -e /data/local/tmp/open-u60-transactions/active ] || fail 'Another modem transaction is pending'
}
installation_guards() {
    for dir in "$ROOT" "$ROOT/bin" "$ROOT/.ssclash"; do safe_dir "$dir"; done
    for file in "$ROOT/.zte-imei-owner" "$ROOT/bin/ssclash" "$SERVICE"; do safe_file "$file"; done
    [ "$(cat "$ROOT/.zte-imei-owner")" = zte-imei-ssclash-v1 ] || fail 'Unknown SSClash owner'
    [ "$(file_hash "$ROOT/bin/ssclash")" = "$BINARY_HASH" ] || fail 'SSClash binary has changed'
    [ "$(file_hash "$SERVICE")" = "$SERVICE_HASH" ] || fail 'SSClash service has changed'
    if awk -v root="$ROOT" '$2 == root || index($2, root "/") == 1 { found=1 } END {exit !found}' /proc/mounts; then fail 'Nested application mount cannot be removed'; fi
    if [ -f /etc/rc.local ] && grep -F -e "$ROOT" -e "$SERVICE" /etc/rc.local >/dev/null; then fail 'Custom SSClash startup requires manual review'; fi
    for link in /etc/rc.d/*zte_imei_ssclash; do
        [ -e "$link" ] || [ -L "$link" ] || continue
        case "$link" in /etc/rc.d/S95zte_imei_ssclash|/etc/rc.d/K15zte_imei_ssclash) ;; *) fail 'Unknown SSClash startup link';; esac
        [ -L "$link" ] && [ "$(readlink "$link")" = ../init.d/zte_imei_ssclash ] || fail 'Changed SSClash startup link'
    done
}
proxy_stopped() {
    for proc in /proc/[0-9]*/exe; do
        executable=$(readlink "$proc" 2>/dev/null || true)
        case "$executable" in "$ROOT"/bin/clash|"$ROOT"/bin/clash\ \(deleted\)|"$ROOT"/bin/mihomo|"$ROOT"/bin/mihomo\ \(deleted\)) fail 'Stop the proxy in SSClash before removing the application';; esac
    done
    # Never guess how to remove proxy routes, firewall rules or somebody else's core.
    for command in iptables-save ip6tables-save; do
        command -v "$command" >/dev/null 2>&1 || continue
        rules=$("$command") || fail 'Could not inspect proxy firewall state'
        if printf '%s\n' "$rules" | grep -Eiq '(^:|^-A ).*clash'; then fail 'Proxy firewall rules remain; stop the proxy in its web panel first'; fi
    done
}
web_stopped() {
    for proc in /proc/[0-9]*/exe; do
        executable=$(readlink "$proc" 2>/dev/null || true)
        case "$executable" in "$ROOT"/bin/ssclash|"$ROOT"/bin/ssclash\ \(deleted\)) return 1;; esac
    done
    return 0
}
archive_guard() {
    safe_dir "$RECOVERY"; safe_file "$RECOVERY/.zte-imei-owner"
    [ "$(cat "$RECOVERY/.zte-imei-owner")" = zte-imei-app-removals-v1 ] || fail 'Unknown recovery directory'
    safe_dir "$TXN"; safe_file "$TXN/archive.tar.gz"; safe_file "$TXN/phase"
    [ "$(cat "$TXN/phase")" = prepared ] || fail 'Removal is not prepared'
    [ "$(file_hash "$TXN/archive.tar.gz")" = "$5" ] || fail 'Recovery archive has changed'
}
base_guards
case "$ACTION" in
prepare)
    [ "$#" = 4 ] || fail 'Invalid prepare arguments'
    installation_guards; proxy_stopped
    need=$(du -sk "$ROOT" | awk '{print $1}')
    free=$(df -Pk "$BASE" | awk 'NR == 2 {print $4}')
    [ "$free" -ge "$((need + 1024))" ] || fail 'Not enough free space for a recovery archive'
    if [ -e "$RECOVERY" ] || [ -L "$RECOVERY" ]; then
        safe_dir "$RECOVERY"; safe_file "$RECOVERY/.zte-imei-owner"
        [ "$(cat "$RECOVERY/.zte-imei-owner")" = zte-imei-app-removals-v1 ] || fail 'Unknown recovery directory'
    else
        mkdir "$RECOVERY"; printf '%s\n' zte-imei-app-removals-v1 > "$RECOVERY/.zte-imei-owner"
    fi
    [ ! -e "$TXN" ] && [ ! -L "$TXN" ] || fail 'Removal identifier already exists'
    mkdir "$TXN"; printf '%s\n' preparing > "$TXN/phase"
    "$SERVICE" stop
    count=0
    while ! web_stopped; do
        count=$((count + 1)); [ "$count" -lt 20 ] || fail 'SSClash did not stop; no files were removed'
        sleep 1
    done
    proxy_stopped; installation_guards
    set -- data/zte-imei-apps/ssclash etc/init.d/zte_imei_ssclash
    for link in /etc/rc.d/S95zte_imei_ssclash /etc/rc.d/K15zte_imei_ssclash; do
        [ ! -L "$link" ] || set -- "$@" "${link#/}"
    done
    tar -czf "$TXN/archive.tar.gz" -C / "$@"
    gzip -t "$TXN/archive.tar.gz"
    chmod 600 "$TXN/archive.tar.gz"
    printf '%s\n' prepared > "$TXN/phase"
    printf 'SSCLASH_ARCHIVE sha256=%s bytes=%s\n' "$(file_hash "$TXN/archive.tar.gz")" "$(stat -c '%s' "$TXN/archive.tar.gz")"
    ;;
commit)
    [ "$#" = 5 ] || fail 'Invalid commit arguments'
    printf '%s\n' "$5" | grep -Eq '^[0-9a-f]{64}$' || fail 'Invalid archive hash'
    archive_guard "$@"
    installation_guards; proxy_stopped; web_stopped || fail 'SSClash restarted; removal stopped'
    printf '%s\n' committing > "$TXN/phase"
    for link in /etc/rc.d/S95zte_imei_ssclash /etc/rc.d/K15zte_imei_ssclash; do
        [ ! -L "$link" ] || mv "$link" "$TXN/$(basename "$link")"
    done
    mv "$SERVICE" "$TXN/service.disabled"
    mv "$ROOT" "$TXN/application"
    # Files are now detached from their executable/startup paths. The verified archive
    # was already saved on the Mac before this command was authorized by the caller.
    safe_dir "$TXN/application"; safe_file "$TXN/application/.zte-imei-owner"
    [ "$(cat "$TXN/application/.zte-imei-owner")" = zte-imei-ssclash-v1 ] || fail 'Quarantine ownership changed'
    [ "$(file_hash "$TXN/application/bin/ssclash")" = "$BINARY_HASH" ] || fail 'Quarantined binary changed'
    rm -rf "$TXN/application"
    printf '%s\n' removed > "$TXN/phase"
    printf 'SSCLASH_REMOVED archive=%s/archive.tar.gz\n' "$TXN"
    ;;
*) fail 'Unknown removal action';;
esac
