#!/bin/sh
# ZTE IMEI Studio: preserve existing services, start only absent listeners.
set -eu
if ! pidof zte-agent >/dev/null 2>&1; then
    test -x /data/zte-agent
    test -f /data/zte-imei-studio/start_zte_agent.sh
    sh /data/zte-imei-studio/start_zte_agent.sh
fi
# Verify our listener without stopping stock SSH or any other process.
ssh_failure() { printf 'INSTALL_ERROR %s\n' "$1" >&2; exit 1; }
tables=/proc/net/tcp
test -r /proc/net/tcp || ssh_failure SSH_LISTENER_UNREADABLE_2222
if test -r /proc/net/tcp6; then tables="$tables /proc/net/tcp6"; fi
listener_present() {
    awk '$2 ~ /:08AE$/ && $4 == "0A" { found=1 } END { exit !found }' $tables
}
owned_listener() {
    inodes=$(awk '$2 ~ /:08AE$/ && $4 == "0A" {
        if ($10 !~ /^[0-9]+$/ || $10 == "0") { invalid=1; next }
        if (!seen[$10]++) print $10
    } END { if (invalid) exit 1 }' $tables) || return 1
    test -n "$inodes" || return 1
    for inode in $inodes; do
        owned=0
        for process in $(pidof dropbear 2>/dev/null || true); do
            case "$process" in ''|*[!0-9]*) continue;; esac
            test "$(readlink "/proc/$process/exe" 2>/dev/null || true)" = /data/zte-imei-studio/bin/dropbear || continue
            for descriptor in /proc/"$process"/fd/*; do
                socket=$(readlink "$descriptor" 2>/dev/null || true)
                if test "$socket" = "socket:[$inode]"; then owned=1; break; fi
            done
            test "$owned" = 0 || break
        done
        test "$owned" = 1 || return 1
    done
    return 0
}
if listener_present; then
    owned_listener || ssh_failure SSH_LISTENER_UNVERIFIED_2222
else
    /data/zte-imei-studio/bin/dropbear -s -P /var/run/zte-imei-dropbear.pid -p 2222 \
        -r /etc/dropbear/dropbear_ed25519_host_key \
        -r /etc/dropbear/dropbear_rsa_host_key || ssh_failure SSH_START_FAILED_2222
fi
tries=0
until owned_listener; do
    tries=$((tries + 1))
    test "$tries" -lt 10 || ssh_failure SSH_NOT_LISTENING_2222
    sleep 1
done
