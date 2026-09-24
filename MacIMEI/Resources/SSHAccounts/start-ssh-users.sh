#!/bin/sh
# Dedicated password listener. Existing key-only administration is untouched.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
base=/data/zte-imei-admin
config=/etc/zte-imei-admin
fail() { printf 'SSH_USERS_START_ERROR %s\n' "$1" >&2; exit 1; }
for directory in /data "$base" "$base/bin" /etc "$config"; do
    test -d "$directory" && test ! -L "$directory" || fail DIRECTORY_TYPE
    test "$(stat -c %u "$directory")" = 0 || fail DIRECTORY_OWNER
    mode=$(stat -c %a "$directory")
    case "$mode" in 700|750|755|775) ;; *) fail DIRECTORY_MODE;; esac
    # The stock /etc is root:root 755. Writable group is acceptable only root.
    if test "$mode" = 775; then test "$(stat -c %g "$directory")" = 0 || fail DIRECTORY_GROUP; fi
done
for file in "$config/listen-address" "$base/bin/dropbear"; do
    test -f "$file" && test ! -L "$file" && test "$(stat -c %u "$file")" = 0 || fail FILE_TYPE
    case "$(stat -c %a "$file")" in 600|700|755) ;; *) fail FILE_MODE;; esac
done
address=$(cat "$config/listen-address")
printf '%s\n' "$address" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; exit 0} {exit 1}' || fail ADDRESS
ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qFx "$address" || fail ADDRESS_NOT_LOCAL
pidfile=/var/run/zte-imei-users.pid
if awk '$2 ~ /:08AF$/ && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6; then
    test -f "$pidfile" && test ! -L "$pidfile" || fail PORT_IN_USE
    pid=$(cat "$pidfile"); case "$pid" in ''|*[!0-9]*) fail PID;; esac
    test "$(readlink "/proc/$pid/exe")" = "$base/bin/dropbear" || fail PORT_IN_USE
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -qFx "$address:2223" || fail LISTENER_ADDRESS
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -qFx -- -w || fail ROOT_LOGIN_ENABLED
    tr '\000' '\n' < "/proc/$pid/cmdline" | awk 'previous=="-G" && $0=="zteimei" {found=1} {previous=$0} END {exit !found}' || fail GROUP_RESTRICTION_MISSING
    exit 0
fi
"$base/bin/dropbear" -w -G zteimei -j -k -T 3 -I 600 -P "$pidfile" -p "$address:2223" \
    -r /etc/dropbear/dropbear_ed25519_host_key -r /etc/dropbear/dropbear_rsa_host_key
sleep 1
test -f "$pidfile" || fail LISTENER_NOT_RUNNING
pid=$(cat "$pidfile"); case "$pid" in ''|*[!0-9]*) fail PID;; esac
test "$(readlink "/proc/$pid/exe")" = "$base/bin/dropbear" || fail LISTENER_NOT_RUNNING
