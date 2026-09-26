#!/bin/sh
# ZTE IMEI Studio: preserve existing services, start only absent listeners.
set -eu
if ! pidof zte-agent >/dev/null 2>&1; then
    test -x /data/zte-agent
    test -f /data/local/tmp/start_zte_agent.sh
    sh /data/local/tmp/start_zte_agent.sh
fi
# An existing listener belongs to the previous installation. Never kill it.
tables=/proc/net/tcp
if test -r /proc/net/tcp6; then tables="$tables /proc/net/tcp6"; fi
if ! awk '$2 ~ /:08AE$/ && $4 == "0A" { found=1 } END { exit !found }' $tables; then
    /data/bin/dropbear -s -P /var/run/zte-imei-dropbear.pid -p 2222 \
        -r /etc/dropbear/dropbear_ed25519_host_key \
        -r /etc/dropbear/dropbear_rsa_host_key
fi
