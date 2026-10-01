#!/bin/sh
# Select by the actual listening socket, not PPid (orphaned SSH sessions can
# also have PPid 1). Never kill a firmware executable or an established session.
set -eu
case "${1:-}:${2:-}" in
    dropbear:08AE|dashboard-uhttpd:1F90) ;;
    *) exit 64 ;;
esac
executable=/data/bin/$1
private_executable=/data/zte-dashboard-runtime/dashboard-uhttpd
dashboard_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
port=$2
proc_root=${U60_TEST_PROC_ROOT:-/proc}
case "${3:-}" in ''|--list) ;; *) exit 64 ;; esac
inodes=$(awk -v port=":$port" '$2 ~ port"$" && $4 == "0A" {print $10}' "$proc_root/net/tcp" "$proc_root/net/tcp6" 2>/dev/null || true)
for process in "$proc_root"/[0-9]*; do
    actual=$(readlink "$process/exe" 2>/dev/null || true)
    case "$actual" in "$executable"|"$executable (deleted)") ;;
        "$private_executable"|"$private_executable (deleted)") [ "$1" = dashboard-uhttpd ] || continue ;;
        *) continue ;; esac
    listening=false
    for fd in "$process"/fd/*; do
        socket=$(readlink "$fd" 2>/dev/null || true)
        for inode in $inodes; do
            if [ "$socket" = "socket:[$inode]" ]; then listening=true; break; fi
        done
        if [ "$listening" = true ]; then break; fi
    done
    if [ "$listening" = true ]; then
        if [ "$1" = dashboard-uhttpd ]; then
            # Read the actual mapped executable, never run a legacy helper
            # from potentially writable /data/bin or /data/local/tmp.
            actual_sha=$(sha256sum "$process/exe" | awk '{print $1}')
            [ "$actual_sha" = "$dashboard_sha" ] || exit 1
        fi
        if [ "${3:-}" = --list ]; then printf '%s\n' "${process##*/}"
        else kill "${process##*/}" 2>/dev/null || true; fi
    fi
done
