#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=01
ROOT=/data/zte-vpn
start_service() {
    [ -f "$ROOT/configured" ] && [ -f "$ROOT/config.json" ] || return 0
    for kind in core dns guard; do
        procd_open_instance "$kind"
        procd_set_param command /bin/sh "$ROOT/manager.sh" "run-$kind"
        procd_set_param respawn 3600 5 0
        procd_set_param stdout 0
        procd_set_param stderr 0
        procd_close_instance
    done
}
