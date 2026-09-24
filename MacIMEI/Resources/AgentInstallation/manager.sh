#!/bin/sh
# Only /data/zte-agent is replaced. SSH, credentials and startup remain intact.
set -eu
umask 077
root=$(printenv ZTE_AGENT_TEST_ROOT || true)
base="$root/data/zte-agent-installer"
binary="$root/data/zte-agent"
startup="$root/data/local/tmp/start_zte_agent.sh"
action=$1
hash() { sha256sum "$1" | awk '{print $1}'; }
plain() { test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0; }
owned_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c '%u:%a' "$1")" = 0:700; }
fail() { printf 'AGENT_ERROR %s\n' "$1" >&2; exit 1; }
cid=$(cat "$root/sys/block/mmcblk0/device/cid")
case "$cid" in ''|*[!0-9a-f]*) fail CID;; esac
test "$(printf %s "$cid" | wc -c)" -eq 32 || fail CID
if test -e "$base" || test -L "$base"; then
    owned_dir "$base" && plain "$base/owner" && test "$(cat "$base/owner")" = zte-agent-installer-v1 || fail OWNER
fi
pids() {
    for proc in "$root"/proc/[0-9]*/exe; do
        case "$(readlink "$proc" 2>/dev/null || true)" in "$binary"|"$binary (deleted)") basename "$(dirname "$proc")";; esac
    done
}
stop_agent() {
    if test -n "$root"; then rm -f "$root/running"; return; fi
    for pid in $(pids); do kill "$pid" 2>/dev/null || true; done
    n=0
    while test -n "$(pids)" && test "$n" -lt 5; do sleep 1; n=$((n+1)); done
    for pid in $(pids); do kill -KILL "$pid" 2>/dev/null || true; done
    sleep 1
    test -z "$(pids)" || return 1
}
start_agent() {
    if test -n "$root"; then
        test ! -e "$root/fail-start" || return 1
        : > "$root/running"; return
    fi
    sh "$startup" || return 1
    sleep 3
    test -n "$(pids)"
}
valid_snapshot() {
    owned_dir "$base" && plain "$base/previous.bin" && plain "$base/previous.sha256" && plain "$base/cid" || return 1
    test "$(cat "$base/cid")" = "$cid" && test "$(hash "$base/previous.bin")" = "$(cat "$base/previous.sha256")"
}
restore_previous() {
    valid_snapshot || return 1
    cp "$base/previous.bin" "$base/restore.bin" || return 1
    chmod 700 "$base/restore.bin" || return 1
    test "$(hash "$base/restore.bin")" = "$(cat "$base/previous.sha256")" || return 1
    stop_agent || return 1
    mv -f "$base/restore.bin" "$binary" || return 1
    start_agent || return 1
    rm -f "$base/pending"
    sync
}
case "$action" in
status)
    if plain "$binary"; then printf 'AGENT_SHA %s\n' "$(hash "$binary")"; else printf 'AGENT_SHA absent\n'; fi
    if test -n "$root"; then test ! -e "$root/running" || printf 'AGENT_RUNNING yes\n'
    elif test -n "$(pids)"; then printf 'AGENT_RUNNING yes\n'; fi
    if plain "$startup" && sh -n "$startup"; then printf 'AGENT_STARTUP yes\n'; fi
    test ! -e "$base/pending" || printf 'AGENT_PENDING yes\n'
    if test -e "$base"; then
        if valid_snapshot; then printf 'AGENT_BACKUP %s\n' "$(cat "$base/previous.sha256")"; fi
    fi
    ;;
install)
    source=$2; expected=$3
    case "$source" in "$root"/tmp/zte-agent-stage-*/agent.bin) ;; *) fail SOURCE;; esac
    case "$expected" in ''|*[!0-9a-f]*) fail HASH;; esac
    test "$(printf %s "$expected" | wc -c)" -eq 64 || fail HASH
    owned_dir "$(dirname "$source")" && plain "$source" && test "$(hash "$source")" = "$expected" || fail SOURCE_HASH
    plain "$binary" && test -x "$binary" && plain "$startup" && sh -n "$startup" || fail PREPARE_FIRST
    test ! -e "$root/data/local/tmp/open-u60-transactions/active" || fail OTHER_DEPLOYMENT
    test ! -e "$root/data/zte-vpn/controller-upgrade" || fail VPN_UPGRADE
    if test ! -e "$base"; then
        mkdir "$base"; chmod 700 "$base"; printf 'zte-agent-installer-v1\n' > "$base/owner"
    fi
    test ! -e "$base/pending" || fail RECOVERY_REQUIRED
    cp "$source" "$base/candidate.bin"; chmod 700 "$base/candidate.bin"
    test "$(hash "$base/candidate.bin")" = "$expected" || fail CANDIDATE_HASH
    cp "$binary" "$base/previous.new"; chmod 700 "$base/previous.new"
    old=$(hash "$binary")
    test "$(hash "$base/previous.new")" = "$old" || fail BACKUP_HASH
    mv -f "$base/previous.new" "$base/previous.bin"
    printf '%s\n' "$old" > "$base/previous.sha256"
    printf '%s\n' "$cid" > "$base/cid"
    printf '%s\n' "$expected" > "$base/pending"
    sync
    committed=0
    finish() {
        code=$?
        trap - EXIT HUP INT TERM
        if test "$committed" = 0; then
            if restore_previous; then printf 'AGENT_ROLLBACK restored\n' >&2
            else printf 'AGENT_ROLLBACK recovery-required\n' >&2; fi
        fi
        exit "$code"
    }
    trap finish EXIT
    trap 'exit 1' HUP INT TERM
    stop_agent || fail STOP
    mv -f "$base/candidate.bin" "$binary"
    test "$(hash "$binary")" = "$expected" || fail INSTALLED_HASH
    start_agent || fail START
    test -z "$root" || test ! -e "$root/fail-after-start" || fail POST_START
    rm -f "$base/pending"; sync
    committed=1
    printf 'AGENT_INSTALLED %s\n' "$expected"
    printf 'AGENT_BACKUP %s\n' "$old"
    ;;
restore)
    test ! -e "$root/data/local/tmp/open-u60-transactions/active" || fail OTHER_DEPLOYMENT
    test ! -e "$root/data/zte-vpn/controller-upgrade" || fail VPN_UPGRADE
    plain "$startup" && sh -n "$startup" || fail STARTUP
    valid_snapshot || fail BACKUP_INVALID
    printf 'restore\n' > "$base/pending"; sync
    restore_previous || fail RESTORE
    printf 'AGENT_RESTORED %s\n' "$(hash "$binary")"
    ;;
*) fail ACTION;;
esac
