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
safe_optional() { [ ! -L "$1" ] && { [ ! -e "$1" ] || safe_dir "$1"; }; }
fail() { printf '%s\n' "$1" >&2; exit 1; }
[ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] || exit 1
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%a' "$stage")" = 0:700 ] || exit 1
[ "$(cat /sys/block/mmcblk0/device/cid)" = "$expected_cid" ]
plain /data/zte-agent
[ ! -e /data/local/tmp/open-u60-transactions/active ]
[ ! -e /data/zte-agent-installer/pending ]
safe_dir /data || exit 1
safe_dir /etc || exit 1
runtime=/data/zte-dashboard-runtime
base=$runtime/installer
safe_optional "$runtime"
safe_optional "$base"
safe_optional "$runtime/dashboards"
# Old product metadata is evidence to archive, not a prerequisite for replacement.
# Do not run an installed helper while deciding whether an old lock is abandoned.
installer_idle() {
    ancestors=" $$ "
    parent=$$
    depth=0
    while [ "$depth" -lt 64 ] && [ -r "/proc/$parent/status" ]; do
        parent=$(awk '/^PPid:/ {print $2}' "/proc/$parent/status") || return 1
        case "$parent" in ''|*[!0-9]*) return 1;; 0) break;; esac
        case "$ancestors" in *" $parent "*) break;; esac
        ancestors="$ancestors$parent "
        depth=$((depth+1))
    done
    for process in /proc/[0-9]*; do
        case "$ancestors" in *" ${process##*/} "*) continue;; esac
        [ ! -e "$process" ] || [ -r "$process/cmdline" ] || return 1
        command=$(tr '\000' ' ' < "$process/cmdline" 2>/dev/null) || {
            [ ! -e "$process" ] && continue
            return 1
        }
        case "$command" in
            *'/tmp/zte-dashboard-stage-'*'/dashboard.sh '*|*'/tmp/zte-vpn-agent-'*|*'/setup-agent.sh '*|*'/upgrade-controller.sh '*|*'/zte-agent-stage-'*'/manager.sh '*) return 1;;
        esac
    done
}
installer_idle || fail DASHBOARD_BUSY
if [ -e "$base/lock" ] || [ -L "$base/lock" ]; then
    safe_dir "$base/lock" && installer_idle || fail DASHBOARD_BUSY
fi
for file in dashboard.tar.gz dashboard-uhttpd start-dashboard.sh dashboard-html.sh stop-owned-listener.sh update-rc-local.sh preserve-dashboard-assets.sh payload.sha256; do plain "$stage/$file"; done
# Updated and pinned by the release packager.
payload_sha=5d90784d6addb1857042154e8e95db9c9cd242482f655384fa9d72e2f252de9e
[ "$(hash "$stage/payload.sha256")" = "$payload_sha" ]
(cd "$stage" && sha256sum -c payload.sha256 >/dev/null)
plain /etc/rc.local && sh -n /etc/rc.local || exit 1
for file in start-dashboard.sh dashboard-html.sh stop-owned-listener.sh update-rc-local.sh preserve-dashboard-assets.sh; do sh -n "$stage/$file"; done
runtime_files='dashboard-uhttpd start-dashboard.sh dashboard-html.sh stop-owned-listener.sh update-rc-local.sh'
private_before=0
for file in $runtime_files; do
    if [ -e "$runtime/$file" ] || [ -L "$runtime/$file" ]; then
        # Fixed product leaves may contain older or incomplete installs. Archive
        # their bytes (or the link itself), without following or executing them.
        [ -f "$runtime/$file" ] || [ -L "$runtime/$file" ] || [ -d "$runtime/$file" ] || fail DASHBOARD_UNSAFE_PARENT
        private_before=1
    fi
done
previous=/data/www
if [ -e "$runtime/current" ] || [ -L "$runtime/current" ]; then
    if [ -L "$runtime/current" ]; then previous=$(readlink -f "$runtime/current" 2>/dev/null || true); fi
elif [ -e /data/www.current ] || [ -L /data/www.current ]; then
    if [ -L /data/www.current ]; then previous=$(readlink -f /data/www.current 2>/dev/null || true); fi
fi
case "$previous" in /data/www|/data/open-u60-dashboards/*|/data/zte-dashboard-runtime/dashboards/*) ;; *) previous=/data/www;; esac
# The pinned stop helper proves the mapped product path and listening socket.
# No helper from /data/bin or /data/local/tmp is executed.
previous_pids=$(sh "$stage/stop-owned-listener.sh" dashboard-uhttpd 1F90 --list)
previous_ready=0
if plain "$previous/index.html" && test -s "$previous/index.html"; then previous_ready=1; fi
if [ "$action" = preflight ]; then printf 'DASHBOARD_PREFLIGHT %s\n' "$id"; exit 0; fi
[ "$(hash /data/zte-agent)" = "$expected_agent" ]
if [ ! -e "$runtime" ]; then
    mkdir -m 700 "$runtime"
fi
for dir in "$base" "$runtime/dashboards"; do if [ ! -e "$dir" ]; then mkdir -m 700 "$dir"; fi; done
if [ -e "$base/lock" ] || [ -L "$base/lock" ]; then
    safe_dir "$base/lock" && installer_idle || fail DASHBOARD_BUSY
    [ ! -e "$base/retired-lock-$id" ] && [ ! -L "$base/retired-lock-$id" ] || fail DASHBOARD_RECOVERY_REQUIRED
    mv "$base/lock" "$base/retired-lock-$id"
fi
mkdir "$base/lock" || { echo DASHBOARD_BUSY >&2; exit 1; }
backup=$base/$id
target=$runtime/dashboards/$id
committed=0; snapshot=0
install_runtime() {
    for file in $runtime_files; do
        # The private parent excludes replacement races by other users.
        fresh=$runtime/$file.new-$id
        [ ! -e "$fresh" ] && [ ! -L "$fresh" ] || return 1
        cp "$stage/$file" "$fresh" || return 1
        chmod 700 "$fresh" || return 1
        # Renaming avoids truncating the executable of a running old listener.
        mv -Tf "$fresh" "$runtime/$file" || return 1
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
has_dashboard_boot_entry() {
    grep -qFx 'sh /data/local/tmp/start_dashboard.sh' /etc/rc.local ||
    grep -qFx 'sh /data/zte-dashboard-runtime/start-dashboard.sh' /etc/rc.local
}
restore_boot_entry() {
    if has_dashboard_boot_entry; then
        sh "$stage/update-rc-local.sh" 'sh /data/zte-dashboard-runtime/start-dashboard.sh'
    fi
}
restore() {
    if [ "$snapshot" = 1 ]; then
        stop_dashboard || return 1
        cp -p "$backup/rc.local" /etc/rc.local || return 1
        if [ -f "$backup/was-running" ]; then
            # Restore the previous web content using this release's helpers.
            # An unknown previous startup is backup data, never executable input.
            install_runtime || return 1
            point_to "$previous" || return 1
            restore_boot_entry || return 1
            sh "$runtime/start-dashboard.sh" || return 1
            verify_listener "$(cat "$backup/previous-index-sha")" || return 1
        elif [ "$private_before" = 1 ] || has_dashboard_boot_entry; then
            install_runtime || return 1
            point_to "$previous" || return 1
            restore_boot_entry || return 1
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
stat -c %a "$runtime" > "$backup/runtime.mode"
if [ -e "$runtime/current" ] && [ ! -L "$runtime/current" ]; then
    [ -f "$runtime/current" ] || [ -d "$runtime/current" ] || fail DASHBOARD_UNSAFE_PARENT
    mv "$runtime/current" "$backup/current"
elif [ -L "$runtime/current" ]; then
    cp -Pp "$runtime/current" "$backup/current"
fi
for residual in "$runtime/current.new" "$runtime"/*.new-*; do
    if [ -e "$residual" ] || [ -L "$residual" ]; then
        [ -f "$residual" ] || [ -L "$residual" ] || fail DASHBOARD_UNSAFE_PARENT
        mv "$residual" "$backup/${residual##*/}"
    fi
done
for file in $runtime_files owner; do
    if [ -e "$runtime/$file" ] || [ -L "$runtime/$file" ]; then
        if [ -d "$runtime/$file" ] && [ ! -L "$runtime/$file" ]; then
            # A malformed product leaf can itself be a directory. Retain it
            # opaquely instead of traversing or treating it as executable code.
            mv "$runtime/$file" "$backup/$file"
        elif [ -L "$runtime/$file" ]; then
            cp -Pp "$runtime/$file" "$backup/$file"
            [ "$(readlink "$runtime/$file")" = "$(readlink "$backup/$file")" ] || fail DASHBOARD_RECOVERY_REQUIRED
        else
            [ -f "$runtime/$file" ] || fail DASHBOARD_UNSAFE_PARENT
            cp -p "$runtime/$file" "$backup/$file"
            [ "$(hash "$runtime/$file")" = "$(hash "$backup/$file")" ] || fail DASHBOARD_RECOVERY_REQUIRED
        fi
    fi
done
printf '%s\n' "$previous" > "$backup/previous"
if [ -n "$previous_pids" ] && [ "$previous_ready" = 1 ]; then
    hash "$previous/index.html" > "$backup/previous-index-sha"
    : > "$backup/was-running"
fi
printf '%s\n' "$expected_cid" > "$backup/cid"
sync; snapshot=1
chmod 700 "$runtime" "$base" "$runtime/dashboards"
[ ! -e "$runtime/owner.new-$id" ] && [ ! -L "$runtime/owner.new-$id" ] || fail DASHBOARD_RECOVERY_REQUIRED
printf 'zte-dashboard-runtime-v1\n' > "$runtime/owner.new-$id"
mv -Tf "$runtime/owner.new-$id" "$runtime/owner"
for file in dashboard.log dashboard.pid; do
    if [ -e "$runtime/$file" ] || [ -L "$runtime/$file" ]; then
        [ -f "$runtime/$file" ] || [ -L "$runtime/$file" ] || fail DASHBOARD_UNSAFE_PARENT
        mv "$runtime/$file" "$backup/$file"
    fi
done
tar -xzf "$stage/dashboard.tar.gz" -C "$target"
test -s "$target/index.html"; test -s "$target/release.json"
cp "$target/index.html" "$target/mobile.html"
# The new web root contains only the verified current bundle. The previous root
# remains available in history, but stale/foreign assets cannot block replacement.
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
