#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=01
start_service() {
 root=/data/zte-launcher
 test -d "$root" && test ! -L "$root" && test "$(stat -c %u:%a "$root")" = 0:700 || return 1
 test -f "$root/enabled" && test ! -e "$root/failed" || return 0
 (cd "$root" && sha256sum -c launcher.sha256 >/dev/null 2>&1) || return 1
 procd_open_instance
 procd_set_param command /bin/sh "$root/launcher-watch.sh"
 procd_set_param respawn 3600 5 5
 procd_close_instance
}
