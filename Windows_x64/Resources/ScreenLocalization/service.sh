#!/bin/sh /etc/rc.common
# Recovery entry point for S47 and the managed stock S48 pre-start block.
# rc.local is never modified.
START=47

boot() {
    local root=/data/zte-imei-screen-ru
    local expected actual pending
    test -d "$root" && test ! -L /data && test ! -L "$root" || return 1
    test "$(stat -c '%u:%a' "$root")" = 0:700 || return 1
    test -f "$root/owner" && test ! -L "$root/owner" || return 1
    test "$(cat "$root/owner")" = zte-imei-screen-ru-v1 || return 1
    if test -f "$root/manager.sh" && test ! -L "$root/manager.sh" && test -f "$root/manager.sha256" && test ! -L "$root/manager.sha256"; then
        expected=$(cat "$root/manager.sha256")
        actual=$(sha256sum "$root/manager.sh" | awk '{print $1}')
        if test "${#expected}" = 64 && test "$actual" = "$expected"; then
            sh "$root/manager.sh" boot
            return $?
        fi
    fi
    # A damaged manager must not execute. On an interrupted/enabled installation
    # a cold boot has no binds yet; leave the stock S48 UI an English setting.
    echo 'SCREEN_RU_ERROR MANAGER_INTEGRITY' >&2
    if test -e "$root/.enabled" || test -e "$root/.transaction"; then
        test ! -L "$root/.enabled" && test ! -L "$root/.transaction" || return 1
        test -f /cache/language.txt && test ! -L /cache && test ! -L /cache/language.txt || return 1
        test ! -L /usr && test ! -L /usr/bin && test ! -L /usr/ui && test ! -L /usr/ui/language || return 1
        pidof zte_topsw_devui >/dev/null 2>&1 && return 1
        awk '$5 == "/usr" || $5 == "/usr/bin" || $5 == "/usr/ui" || $5 == "/usr/ui/language" || $5 == "/usr/bin/zte_topsw_devui" || $5 == "/usr/ui/language/English.ini" || $5 == "/usr/ui/language/Chinese.ini" {bad=1} END {exit bad}' /proc/self/mountinfo || return 1
        pending=$(uci -q changes zwrt_deviceui) || return 1
        if test -n "$pending"; then
            printf '%s\n' "$pending" | awk 'index($0,"zwrt_deviceui.Device.device_language=") != 1 {bad=1} END {exit bad}' || return 1
        fi
        if test ! -e "$root/.transaction"; then printf '%s\n' recovery > "$root/.transaction" || return 1; fi
        test -f "$root/.transaction" || return 1
        sync
        rm -f "$root/.enabled" || return 1
        sync
        uci -q set zwrt_deviceui.Device.device_language=en && uci -q commit zwrt_deviceui || return 1
        printf '%s' english > /cache/language.txt || return 1
        test "$(uci -q get zwrt_deviceui.Device.device_language)" = en && test "$(cat /cache/language.txt)" = english || return 1
        sync
    fi
    return 1
}

start() { boot; }
