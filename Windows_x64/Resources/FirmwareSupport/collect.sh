#!/bin/sh
# Read-only support capture. Fixed firmware files only; no config, NV or credentials.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
action=${1:-}
fail() { printf 'CAPTURE_ERROR %s\n' "$1" >&2; exit 1; }
for tool in stat sha256sum cat base64 tr awk; do command -v "$tool" >/dev/null 2>&1 || fail REQUIRED_TOOL; done

originals_allowed() {
    base=/data/zte-imei-screen-ru
    for dir in /data "$base" "$base/backup"; do
        test -d "$dir" && test ! -L "$dir" && test -r "$dir" && test -x "$dir" && test "$(stat -c %u "$dir")" = 0 || return 1
    done
    for dir in "$base" "$base/backup"; do
        mode=$(stat -c %a "$dir"); test "$((0$mode & 022))" = 0 || return 1
    done
    test -f "$base/owner" && test ! -L "$base/owner" && test "$(stat -c '%u:%h' "$base/owner")" = 0:1 && test "$(stat -c %s "$base/owner")" -le 64 && test "$(cat "$base/owner")" = zte-imei-screen-ru-v1
}
path_for() {
    case "$1" in
      ui) file=/usr/bin/zte_topsw_devui;;
      english) file=/usr/ui/language/English.ini;;
      chinese) file=/usr/ui/language/Chinese.ini;;
      init) file=/etc/init.d/zte_topsw_devui;;
      original_ui) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/zte_topsw_devui;;
      original_english) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/English.ini;;
      original_chinese) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/Chinese.ini;;
      original_init) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/zte_topsw_devui.init;;
      *) return 1;;
    esac
}
file_state() {
    state=present
    cursor=; rest=${file#/}
    while :; do
        case "$rest" in */*) part=${rest%%/*}; rest=${rest#*/};; *) break;; esac
        cursor=$cursor/$part
        if test -L "$cursor"; then state=symlink; return; fi
        if test ! -d "$cursor" || test ! -r "$cursor" || test ! -x "$cursor"; then state=not_assessed; return; fi
    done
    if test -L "$file"; then state=symlink
    elif test ! -e "$file"; then state=missing
    elif test ! -f "$file"; then state=not_regular
    elif test ! -r "$file"; then state=unreadable
    fi
}
fact() { printf 'FACT\t%s\t' "$1"; printf '%s' "$2" | base64 | tr -d '\r\n'; printf '\n'; }
public_text() {
    text=$1
    test "${#text}" -le 256 || { printf not_assessed; return; }
    case "$text" in ''|*[!A-Za-z0-9._/\ -]*) printf not_assessed;; *) printf '%s' "$text";; esac
}
version_field() {
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        value=$(ubus -t 5 call zwrt_web device_info '{}' 2>/dev/null | jsonfilter -e "@.$1" 2>/dev/null) || value=
        public_text "$value"
    else printf not_assessed; fi
}
http_status() {
    if command -v curl >/dev/null 2>&1; then
        value=$(curl -q --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 2 --max-time 4 "http://$host:9090/api/$1" 2>/dev/null) || value=000
        case "$value" in [0-9][0-9][0-9]) printf '%s' "$value";; *) printf 000;; esac
    else printf not_assessed; fi
}
file_row() {
    id=$1
    if ! path_for "$id"; then printf 'FILE\t%s\tmissing\t-\t-\t-\t-\t-\n' "$id"; return; fi
    file_state
    if test "$state" != present; then printf 'FILE\t%s\t%s\t-\t-\t-\t-\t-\n' "$id" "$state"; return; fi
    info=$(stat -c '%s %u %a %h' "$file") || fail FILE_METADATA
    hash=$(sha256sum "$file") || fail FILE_HASH; hash=${hash%% *}
    set -- $info
    test "$#" = 4 || fail FILE_METADATA
    if test "$1" = 0; then printf 'FILE\t%s\tempty\t-\t-\t-\t-\t-\n' "$id"; return; fi
    printf 'FILE\t%s\tpresent\t%s\t%s\t%s\t%s\t%s\n' "$id" "$1" "$hash" "$2" "$3" "$4"
}

case "$action" in
inspect)
    test "$#" = 2 || fail ARGUMENTS
    host=$2
    case "$host" in ''|*[!0-9.]*|.*|*.) fail HOST;; esac
    printf '%s' "$host" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i==""||$i+0>255||$i+0<0)exit 1}' || fail HOST
    printf 'FIRMWARE_SUPPORT_V1\n'
    fact uid "$(id -u)"
    fact os "$(public_text "$(uname -s)")"
    fact architecture "$(public_text "$(uname -m)")"
    fact firmware "$(version_field integrate_version)"
    fact inner "$(version_field wa_inner_version)"
    version=$(awk -F= '$1=="DISTRIB_RELEASE" {gsub(/\047|\042/,"",$2);print $2}' /etc/openwrt_release 2>/dev/null || true)
    fact openwrt_version "$(public_text "$version")"
    target=$(awk -F= '$1=="DISTRIB_TARGET" {gsub(/\047|\042/,"",$2);print $2}' /etc/openwrt_release 2>/dev/null || true)
    fact target "$(public_text "$target")"
    agent_present=0; agent_hash=not_assessed; count=0; mode=not_assessed; mapped=not_assessed
    if test -f /data/zte-agent && test ! -L /data/zte-agent && test -r /data/zte-agent; then
        agent_present=1; agent_hash=$(sha256sum /data/zte-agent); agent_hash=${agent_hash%% *}
    fi
    if command -v pidof >/dev/null 2>&1 && command -v readlink >/dev/null 2>&1; then
        for pid in $(pidof zte-agent 2>/dev/null || true); do
            case "$pid" in ''|*[!0-9]*) continue;; esac
            if test "$(readlink /proc/$pid/exe 2>/dev/null || true)" = /data/zte-agent; then
                count=$((count+1))
                if test "$count" != 1; then mode=ambiguous; mapped=not_assessed; continue; fi
                process_hash=$(sha256sum /proc/$pid/exe 2>/dev/null || true); process_hash=${process_hash%% *}
                if test -n "$process_hash" && test "$agent_present" = 1; then
                    if test "$process_hash" = "$agent_hash"; then mapped=yes; else mapped=no; fi
                fi
                if test -r /proc/$pid/environ; then
                    projected=$(tr '\000' '\n' < /proc/$pid/environ | awk 'index($0,"ZTE_AGENT_MODE=")==1 {n++;v=substr($0,16)} END {if(n==0)print "default";else if(n!=1)print "ambiguous";else if(v=="normal"||v=="discovery")print v;else print "unknown"}')
                    mode=$projected
                fi
            fi
        done
    fi
    fact agent_present "$agent_present"
    fact agent_sha256 "$agent_hash"
    fact agent_running_count "$count"
    fact agent_mode "$mode"
    fact agent_mapped_matches_disk "$mapped"
    fact http_health_status "$(http_status health)"
    fact http_capabilities_status "$(http_status capabilities)"
    fact http_dashboard_status "$(http_status dashboard)"
    mounts=$(awk '$5=="/usr/ui/language/English.ini" || $5=="/usr/ui/language/Chinese.ini" || $5=="/usr/bin/zte_topsw_devui" {n++} END {print n+0}' /proc/self/mountinfo 2>/dev/null || printf not_assessed)
    fact ui_mounts "$mounts"
    for id in ui english chinese init original_ui original_english original_chinese original_init; do file_row "$id"; done
    printf 'FIRMWARE_SUPPORT_END\n'
    ;;
file)
    test "$#" = 4 || fail ARGUMENTS
    id=$2; expected_size=$3; expected_hash=$4
    case "$expected_size" in ''|*[!0-9]*) fail ARGUMENTS;; esac
    case "$expected_hash" in ''|*[!0-9a-f]*) fail ARGUMENTS;; esac
    test "${#expected_hash}" = 64 && test "$expected_size" -gt 0 || fail ARGUMENTS
    path_for "$id" || fail FILE_ID
    file_state; test "$state" = present || fail FILE_UNAVAILABLE
    before=$(stat -c '%d:%i:%s:%u:%a:%h' "$file") || fail FILE_METADATA
    test "$(stat -c %s "$file")" = "$expected_size" || fail FILE_CHANGED
    exec 9< "$file"
    opened=$(stat -Lc '%d:%i:%s:%u:%a:%h' /proc/self/fd/9) || fail FILE_METADATA
    test "$opened" = "$before" || fail FILE_CHANGED
    cat <&9 || fail FILE_READ
    after=$(stat -Lc '%d:%i:%s:%u:%a:%h' /proc/self/fd/9) || fail FILE_METADATA
    disk=$(stat -c '%d:%i:%s:%u:%a:%h' "$file") || fail FILE_METADATA
    hash=$(sha256sum "$file") || fail FILE_HASH; hash=${hash%% *}
    test "$before" = "$after" && test "$before" = "$disk" && test "$hash" = "$expected_hash" || fail FILE_CHANGED
    printf 'BACKUP_RESULT sha256=%s bytes=%s\n' "$hash" "$expected_size" >&2
    ;;
*) fail ACTION;;
esac
