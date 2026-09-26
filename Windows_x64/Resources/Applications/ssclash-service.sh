#!/bin/sh /etc/rc.common
# Managed by ZTE IMEI Studio. The proxy core is configured separately in SSClash.
USE_PROCD=1
START=95
STOP=15
ROOT=/data/zte-imei-apps/ssclash
PROG="$ROOT/bin/ssclash"
start_service() {
    [ -s "$ROOT/.ssclash/password" ] || return 1
    procd_open_instance zte_imei_ssclash
    procd_set_param command "$PROG" serve
    procd_set_param env SSCLASH_ROOT="$ROOT" SSCLASH_PLATFORM=openwrt SSCLASH_ADDR="__ZTE_LAN_IPV4__:9091" SSCLASH_TMP=/tmp/zte-imei-ssclash
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
