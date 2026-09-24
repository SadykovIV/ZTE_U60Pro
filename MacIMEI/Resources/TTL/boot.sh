#!/bin/sh
# Shared entry for fw3, iface hotplug and the existing S95 rc.local call.
# Never source a mutable settings file or execute an unverified manager.
(
    set -eu
    root=/data/zte-imei-ttl
    test ! -L /data && test -d "$root" && test ! -L "$root"
    test "$(stat -c '%u:%a' "$root")" = 0:700
    for item in owner manager.sh manager.sha256; do
        test -f "$root/$item" && test ! -L "$root/$item"
        test "$(stat -c '%u:%a' "$root/$item")" = 0:600
    done
    test "$(cat "$root/owner")" = zte-imei-ttl-v1
    expected=$(cat "$root/manager.sha256")
    test "${#expected}" = 64
    case "$expected" in *[!a-f0-9]*) exit 1;; esac
    test "$(sha256sum "$root/manager.sh" | awk '{print $1}')" = "$expected"
    sh "$root/manager.sh" reapply
) >&2
