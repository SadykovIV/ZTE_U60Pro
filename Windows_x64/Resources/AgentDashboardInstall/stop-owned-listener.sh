#!/bin/sh
# Select by the actual listening socket, not PPid (orphaned SSH sessions can
# also have PPid 1). Never kill a firmware executable or an established session.
set -eu
case "${1:-}:${2:-}" in
    dropbear:08AE|dashboard-uhttpd:1F90) ;;
    *) exit 64 ;;
esac
executable=/data/bin/$1
case "$1" in
    dropbear) private_executable=/data/zte-imei-studio/bin/dropbear;;
    dashboard-uhttpd) private_executable=/data/zte-dashboard-runtime/dashboard-uhttpd;;
esac
port=$2
proc_root=${U60_TEST_PROC_ROOT:-/proc}
case "${3:-}" in ''|--list) ;; *) exit 64 ;; esac
inodes=$(awk -v port=":$port" '$2 ~ port"$" && $4 == "0A" {print $10}' "$proc_root/net/tcp" "$proc_root/net/tcp6" 2>/dev/null || true)
for process in "$proc_root"/[0-9]*; do
    started=$(awk '{sub(/^.*\) /, ""); print $20}' "$process/stat" 2>/dev/null || true)
    actual=$(readlink "$process/exe" 2>/dev/null || true)
    case "$actual" in "$executable"|"$executable (deleted)") ;;
        "$private_executable"|"$private_executable (deleted)") ;;
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
        # A different installed version is still replaceable. Prove the mapped
        # product path, the listening socket and the same process incarnation;
        # never execute the old binary or require its release hash.
        case "$started" in ''|*[!0-9]*) exit 1;; esac
        [ "$(readlink "$process/exe")" = "$actual" ] || exit 1
        [ "$(awk '{sub(/^.*\) /, ""); print $20}' "$process/stat")" = "$started" ] || exit 1
        if [ "${3:-}" = --list ]; then printf '%s\n' "${process##*/}"
        else kill "${process##*/}" 2>/dev/null || true; fi
    fi
done
