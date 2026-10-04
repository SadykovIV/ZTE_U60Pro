#!/bin/sh
# Install a private dashboard runtime without changing firmware directory modes.
set -eu
umask 077
stage=${1:-}; expected_cid=${2:-}; expected_agent=${3:-}; action=${4:-install}
case "$stage" in
 /tmp/zte-dashboard-stage-????????-????-????-????-????????????) id=${stage#/tmp/zte-dashboard-stage-} ;;
 /tmp/zte-vpn-agent-????????-????-????-????-????????????) id=${stage#/tmp/zte-vpn-agent-} ;;
 *) exit 64;;
esac
case "$id:$expected_cid:$expected_agent" in *[!0-9a-f:-]*) exit 64;; esac
case "$action" in install|preflight) ;; *) exit 64;; esac
[ "${#expected_cid}" = 32 ] && [ "${#expected_agent}" = 64 ] || exit 64
hash() { sha256sum "$1" | awk '{print $1}'; }
plain() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ]; }
safe_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 1
    mode=$(stat -c %a "$1") || return 1
    [ "$((0$mode & 022))" = 0 ]
}
private_dir() { safe_dir "$1" && [ "$(stat -c %a "$1")" = 700 ]; }
safe_optional() { [ ! -L "$1" ] && { [ ! -e "$1" ] || private_dir "$1"; }; }
[ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] || exit 1
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%a' "$stage")" = 0:700 ] || exit 1
[ "$(cat /sys/block/mmcblk0/device/cid)" = "$expected_cid" ]
plain /data/zte-agent
[ ! -e /data/local/tmp/open-u60-transactions/active ]
[ ! -e /data/zte-vpn/controller-upgrade ]
[ ! -e /data/zte-agent-installer/pending ]
safe_dir /data || exit 1
safe_dir /etc || exit 1
runtime=/data/zte-dashboard-runtime
base=$runtime/installer
safe_optional "$runtime"
safe_optional "$base"
safe_optional "$runtime/dashboards"
if [ -e "$runtime" ]; then
    plain "$runtime/owner" && [ "$(cat "$runtime/owner")" = zte-dashboard-runtime-v1 ] || exit 1
fi
[ ! -e "$base/lock" ] && [ ! -L "$base/lock" ] || exit 1
for file in dashboard.tar.gz dashboard-uhttpd start-dashboard.sh dashboard-html.sh stop-owned-listener.sh update-rc-local.sh preserve-dashboard-assets.sh payload.sha256; do plain "$stage/$file"; done
# Updated and pinned by the release packager.
payload_sha=96b0f70448f9f7630b0a0273ec403c6b13007d30ba044156d4ba9247a2c717fb
[ "$(hash "$stage/payload.sha256")" = "$payload_sha" ]
(cd "$stage" && sha256sum -c payload.sha256 >/dev/null)
plain /etc/rc.local && sh -n /etc/rc.local || exit 1
for file in start-dashboard.sh dashboard-html.sh stop-owned-listener.sh update-rc-local.sh preserve-dashboard-assets.sh; do sh -n "$stage/$file"; done
runtime_files='dashboard-uhttpd start-dashboard.sh dashboard-html.sh stop-owned-listener.sh update-rc-local.sh'
private_before=0
for file in $runtime_files; do
    if [ -e "$runtime/$file" ] || [ -L "$runtime/$file" ]; then
        plain "$runtime/$file"
        mode=$(stat -c %a "$runtime/$file"); [ "$((0$mode & 022))" = 0 ]
        private_before=1
    fi
done
if [ "$private_before" = 1 ]; then
    for file in $runtime_files; do plain "$runtime/$file"; done
    [ "$(hash "$runtime/dashboard-uhttpd")" = "$(hash "$stage/dashboard-uhttpd")" ]
fi
previous=/data/www
if [ -e "$runtime/current" ] || [ -L "$runtime/current" ]; then
    [ -L "$runtime/current" ]; previous=$(readlink -f "$runtime/current")
elif [ -e /data/www.current ] || [ -L /data/www.current ]; then
    [ -L /data/www.current ]; previous=$(readlink -f /data/www.current)
fi
case "$previous" in /data/www|/data/open-u60-dashboards/*|/data/zte-dashboard-runtime/dashboards/*) ;; *) exit 1;; esac
# The pinned stop helper validates a legacy listener's actual mapped executable.
# No helper from /data/bin or /data/local/tmp is executed.
previous_pids=$(sh "$stage/stop-owned-listener.sh" dashboard-uhttpd 1F90 --list)
if [ -n "$previous_pids" ]; then plain "$previous/index.html" && test -s "$previous/index.html" || exit 1; fi
if [ "$action" = preflight ]; then printf 'DASHBOARD_PREFLIGHT %s\n' "$id"; exit 0; fi
[ "$(hash /data/zte-agent)" = "$expected_agent" ]
if [ ! -e "$runtime" ]; then
    mkdir -m 700 "$runtime"
    printf 'zte-dashboard-runtime-v1\n' > "$runtime/owner"
fi
for dir in "$base" "$runtime/dashboards"; do if [ ! -e "$dir" ]; then mkdir -m 700 "$dir"; fi; done
mkdir "$base/lock" || { echo DASHBOARD_BUSY >&2; exit 1; }
backup=$base/$id
target=$runtime/dashboards/$id
committed=0; snapshot=0
install_runtime() {
    for file in $runtime_files; do
        # The private parent excludes replacement races by other users.
        [ ! -L "$runtime/$file" ] || return 1
        fresh=$runtime/$file.new-$id
        [ ! -e "$fresh" ] && [ ! -L "$fresh" ] || return 1
        cp "$stage/$file" "$fresh" || return 1
        chmod 700 "$fresh" || return 1
        # Renaming avoids truncating the executable of a running old listener.
        mv -f "$fresh" "$runtime/$file" || return 1
    done
}
stop_dashboard() {
    sh "$stage/stop-owned-listener.sh" dashboard-uhttpd 1F90 || return 1
    n=0
    while [ "$n" -lt 4 ]; do
        listeners=$(sh "$stage/stop-owned-listener.sh" dashboard-uhttpd 1F90 --list) || return 1
        [ -n "$listeners" ] || return 0
        sleep 1; n=$((n+1))
    done
    return 1
}
point_to() {
    [ ! -e "$runtime/current.new" ] && [ ! -L "$runtime/current.new" ] || return 1
    ln -s "$1" "$runtime/current.new" || return 1
    mv -Tf "$runtime/current.new" "$runtime/current"
}
verify_listener() {
    n=0
    while [ "$n" -lt 4 ]; do
        listeners=$(sh "$stage/stop-owned-listener.sh" dashboard-uhttpd 1F90 --list) || return 1
        if [ -n "$listeners" ]; then
            served_sha=$(curl --fail --silent --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/ | sha256sum | awk '{print $1}')
            [ "$served_sha" != "$1" ] || return 0
        fi
        sleep 1; n=$((n+1))
    done
    return 1
}
restore() {
    if [ "$snapshot" = 1 ]; then
        stop_dashboard || return 1
        cp -p "$backup/rc.local" /etc/rc.local || return 1
        if [ "$private_before" = 1 ]; then
            for file in $runtime_files; do cp -p "$backup/$file" "$runtime/$file" || return 1; done
        fi
        if [ -f "$backup/was-running" ]; then
            # A first migration restores service using pinned private helpers,
            # never by executing the previous writable-parent startup script.
            if [ "$private_before" != 1 ]; then install_runtime || return 1; fi
            point_to "$previous" || return 1
            sh "$runtime/start-dashboard.sh" || return 1
            verify_listener "$(cat "$backup/previous-index-sha")" || return 1
        elif [ "$private_before" = 1 ]; then
            point_to "$previous" || return 1
        else
            rm -f "$runtime/current" || return 1
            for file in $runtime_files dashboard.log dashboard.pid; do rm -f "$runtime/$file" || return 1; done
        fi
    fi
}
finish() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$committed" != 1 ]; then
        if restore; then echo DASHBOARD_ROLLBACK_OK >&2
        else echo DASHBOARD_RECOVERY_REQUIRED >&2; exit 1; fi
    fi
    rmdir "$base/lock" || true
    exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
mkdir "$backup"
mkdir "$target"
cp -p /etc/rc.local "$backup/rc.local"
if [ "$private_before" = 1 ]; then for file in $runtime_files; do cp -p "$runtime/$file" "$backup/$file"; done; fi
printf '%s\n' "$previous" > "$backup/previous"
if [ -n "$previous_pids" ]; then
    hash "$previous/index.html" > "$backup/previous-index-sha"
    : > "$backup/was-running"
fi
printf '%s\n' "$expected_cid" > "$backup/cid"
sync; snapshot=1
tar -xzf "$stage/dashboard.tar.gz" -C "$target"
test -s "$target/index.html"; test -s "$target/release.json"
cp "$target/index.html" "$target/mobile.html"
if [ -d "$previous" ]; then sh "$stage/preserve-dashboard-assets.sh" "$previous" "$target"; fi
chmod -R a+rX "$target"
install_runtime
point_to "$target"
sh "$runtime/update-rc-local.sh" 'sh /data/zte-dashboard-runtime/start-dashboard.sh'
stop_dashboard
sh "$runtime/start-dashboard.sh"
verify_listener "$(hash "$target/index.html")"
curl --fail --silent --connect-timeout 3 --max-time 8 -D - -o /dev/null http://127.0.0.1:8080/ | grep -qi '^Cache-Control: no-store'
[ "$(readlink -f "$runtime/current")" = "$target" ]
[ "$(cat /sys/block/mmcblk0/device/cid)" = "$expected_cid" ]
[ "$(hash /data/zte-agent)" = "$expected_agent" ]
printf 'complete\n' > "$backup/state"; sync; committed=1
printf 'DASHBOARD_INSTALLED %s\n' "$id"
