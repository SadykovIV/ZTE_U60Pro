#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
unset LD_PRELOAD LD_LIBRARY_PATH ENV BASH_ENV
root=/data/zte-imei-apps/opkg-private
active=$(sed -n '1s/^active=//p' "$root/state")
printf '%s\n' "$active" | grep -Eq '^g-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || { echo 'opkg adapter is disabled' >&2;exit 1; }
dir=$root/generations/$active
expected=$(awk '{print $3}' "$dir/seal")
[ "$(sha256sum "$dir/manager.sh" | cut -d ' ' -f1)" = "$expected" ] || exit 1
exec sh "$dir/manager.sh" execute "$(cat /sys/block/mmcblk0/device/cid)" "$(cat /proc/sys/kernel/random/boot_id)" "$@"
