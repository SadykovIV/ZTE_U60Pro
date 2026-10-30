#!/bin/sh
# Read-only support capture. Fixed firmware files only; no config, NV or credentials.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
action=${1:-}
fail() { printf 'CAPTURE_ERROR %s\n' "$1" >&2; exit 1; }
if test "$action" != radio; then
    for tool in stat sha256sum cat base64 tr awk; do command -v "$tool" >/dev/null 2>&1 || fail REQUIRED_TOOL; done
fi

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
library() {
    # Resolve a requested library alias only inside system library directories.
    # Versioned symlinks are normal here; links into user configuration are not.
    file=$1
    for candidate in "$@"; do
        if test -e "$candidate" || test -L "$candidate"; then file=$candidate; break; fi
    done
    if test ! -e "$file" && test ! -L "$file"; then
        # OpenWrt can omit the unversioned development alias. A unique SONAME
        # file is sufficient; multiple installed versions need explicit review.
        for prefix in "$@"; do
            found=
            for candidate in "$prefix".*; do
                test -e "$candidate" || test -L "$candidate" || continue
                if test -n "$found"; then source_state=ambiguous; return; fi
                found=$candidate
            done
            if test -n "$found"; then file=$found; break; fi
        done
    fi
    if test ! -e "$file" && test ! -L "$file"; then return; fi
    command -v readlink >/dev/null 2>&1 || { source_state=not_assessed; return; }
    resolved=$(readlink -f "$file" 2>/dev/null) || { source_state=not_assessed; return; }
    case "${resolved%/*}" in /lib|/usr/lib|/usr/lib/lua|/usr/lib/lua/luci) file=$resolved;; *) source_state=unsafe_target;; esac
}
path_for() {
    source_state=present; binary=0
    case "$1" in
      ui) file=/usr/bin/zte_topsw_devui;;
      english) file=/usr/ui/language/English.ini;;
      chinese) file=/usr/ui/language/Chinese.ini;;
      init) file=/etc/init.d/zte_topsw_devui;;
      font_zhengyuan) file=/usr/ui/fonts/ZTEZhengYuan.ttf;;
      font_roboto) file=/usr/ui/fonts/Roboto.ttf;;
      font_oswald) file=/usr/ui/fonts/Zoswald-Medium-24.ttf;;
      busybox) file=/bin/busybox; binary=1;;
      dropbear) file=/usr/sbin/dropbear; binary=1;;
      curl) file=/usr/bin/curl; binary=1;;
      ipacm) file=/usr/bin/ipacm; binary=1;;
      ipa_switch) file=/sbin/ipacm_switch.sh;;
      network_init) file=/etc/init.d/network;;
      netifd) file=/sbin/netifd; binary=1;;
      procd) file=/sbin/procd; binary=1;;
      ubusd) file=/sbin/ubusd; binary=1;;
      ubus_cli) file=/bin/ubus; binary=1;;
      uci_cli) file=/sbin/uci; binary=1;;
      lua_cli) file=/usr/bin/lua; binary=1
        if test -L "$file"; then
            resolved=$(readlink -f "$file" 2>/dev/null) || { source_state=not_assessed; return; }
            case "$resolved" in /usr/bin/lua|/usr/bin/lua5.1|/usr/bin/lua5.2|/usr/bin/lua5.3|/usr/bin/lua5.4) file=$resolved;; *) source_state=unsafe_target;; esac
        fi;;
      mdm) file=/usr/bin/zte_topsw_mdm; binary=1;;
      qcril) file=/usr/bin/qcrilNrd; binary=1;;
      diag_router) file=/usr/bin/diag-router; binary=1;;
      libdiag) binary=1; library /usr/lib/libdiag.so.1 /usr/lib/libdiag.so;;
      libzte_sdk) binary=1; library /usr/lib/libzte_SDKowrt.so;;
      libzte_gesture) binary=1; library /usr/lib/libzte_gesture.so;;
      libzte_log) binary=1; library /usr/lib/libztelog.so;;
      libfreetype) binary=1; library /usr/lib/libfreetype.so.6;;
      libpng) binary=1; library /usr/lib/libpng16.so.16;;
      libdrm) binary=1; library /usr/lib/libdrm.so.2;;
      libgcc) binary=1; library /lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1;;
      libc) binary=1; library /lib/libc.so /lib/libc.so.6;;
      libuci) binary=1; library /lib/libuci.so /usr/lib/libuci.so;;
      libubus) binary=1; library /lib/libubus.so /usr/lib/libubus.so;;
      libubox) binary=1; library /lib/libubox.so /usr/lib/libubox.so;;
      libblobmsg_json) binary=1; library /lib/libblobmsg_json.so /usr/lib/libblobmsg_json.so;;
      libjson_c) binary=1; library /usr/lib/libjson-c.so.5 /usr/lib/libjson-c.so /lib/libjson-c.so.5;;
      liblua) binary=1; library /usr/lib/liblua.so.5.1 /usr/lib/liblua.so /usr/lib/liblua5.1.so;;
      lua_uci) binary=1; library /usr/lib/lua/uci.so;;
      lua_jsonc) binary=1; library /usr/lib/lua/luci/jsonc.so /usr/lib/lua/jsonc.so;;
      firmware_mdt) file=/firmware/image/modem.mdt;;
      firmware_b16) file=/firmware/image/modem.b16;;
      libqcril_nr) binary=1; library /usr/lib/libqcrilNr.so /lib/libqcrilNr.so;;
      libqcril_nrril) binary=1; library /usr/lib/libqcrilNrril.so.1 /usr/lib/libqcrilNrril.so /lib/libqcrilNrril.so.1 /lib/libqcrilNrril.so;;
      libzte_qmi) binary=1; library /usr/lib/libzteqmi.so /lib/libzteqmi.so;;
      libqmiservices) binary=1; library /usr/lib/libqmiservices.so /lib/libqmiservices.so;;
      libqmi_cci) binary=1; library /usr/lib/libqmi_cci.so.1 /usr/lib/libqmi_cci.so /lib/libqmi_cci.so.1 /lib/libqmi_cci.so;;
      libqmi_csi) binary=1; library /usr/lib/libqmi_csi.so.1 /usr/lib/libqmi_csi.so /lib/libqmi_csi.so.1 /lib/libqmi_csi.so;;
      libqmi_common) binary=1; library /usr/lib/libqmi_common_so.so.1 /usr/lib/libqmi_common_so.so /lib/libqmi_common_so.so.1 /lib/libqmi_common_so.so;;
      libqmi_encdec) binary=1; library /usr/lib/libqmi_encdec.so.1 /usr/lib/libqmi_encdec.so /lib/libqmi_encdec.so.1 /lib/libqmi_encdec.so;;
      libqmi_sap) binary=1; library /usr/lib/libqmi_sap.so.1 /usr/lib/libqmi_sap.so /lib/libqmi_sap.so.1 /lib/libqmi_sap.so;;
      libqrtr) binary=1; library /usr/lib/libqrtr.so.1 /usr/lib/libqrtr.so /lib/libqrtr.so.1 /lib/libqrtr.so;;
      libqsocket) binary=1; library /usr/lib/libqsocket.so.1 /usr/lib/libqsocket.so /lib/libqsocket.so.1 /lib/libqsocket.so;;
      libglib) binary=1; library /usr/lib/libglib-2.0.so.0 /usr/lib/libglib-2.0.so /lib/libglib-2.0.so.0 /lib/libglib-2.0.so;;
      libgthread) binary=1; library /usr/lib/libgthread-2.0.so.0 /usr/lib/libgthread-2.0.so /lib/libgthread-2.0.so.0 /lib/libgthread-2.0.so;;
      liblog) binary=1; library /usr/lib/liblog.so.0 /usr/lib/liblog.so /lib/liblog.so.0 /lib/liblog.so;;
      libtime_genoff) binary=1; library /usr/lib/libtime_genoff.so.1 /usr/lib/libtime_genoff.so /lib/libtime_genoff.so.1 /lib/libtime_genoff.so;;
      libsqlite3) binary=1; library /usr/lib/libsqlite3.so /lib/libsqlite3.so;;
      original_ui) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/zte_topsw_devui;;
      original_english) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/English.ini;;
      original_chinese) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/Chinese.ini;;
      original_init) originals_allowed || return 1; file=/data/zte-imei-screen-ru/backup/zte_topsw_devui.init;;
      *) return 1;;
    esac
}
file_state() {
    state=$source_state
    test "$state" = present || return 0
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
    if test "$state" = present && test "$binary" = 1; then
        if ! command -v od >/dev/null 2>&1; then state=not_assessed
        elif test "$(od -An -tx1 -N4 "$file" | tr -d ' \r\n')" != 7f454c46; then state=not_elf; fi
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

# Radio adaptation records are projected metadata only. No device node is opened,
# no NV/EF or card identifier is read, and no radio or profile state is changed.
radio_path() (
    radio_id=$1; file=$2; source_state=present; binary=0
    file_state
    if test "$state" != present; then printf 'PATH %s state=%s\n' "$radio_id" "$state"; return; fi
    command -v stat >/dev/null 2>&1 || { printf 'PATH %s state=not_assessed\n' "$radio_id"; return; }
    info=$(stat -c '%u %a %s' "$file" 2>/dev/null) || { printf 'PATH %s state=not_assessed\n' "$radio_id"; return; }
    set -- $info
    test "$#" = 3 || { printf 'PATH %s state=not_assessed\n' "$radio_id"; return; }
    case "$1:$2:$3" in *[!0-9:]*) printf 'PATH %s state=not_assessed\n' "$radio_id"; return;; esac
    radio_hash=not_assessed
    if command -v sha256sum >/dev/null 2>&1; then
        value=$(sha256sum "$file" 2>/dev/null) || value=
        value=${value%% *}
        case "$value" in ''|*[!0-9a-f]*) ;; *) test "${#value}" != 64 || radio_hash=$value;; esac
    fi
    printf 'PATH %s state=present type=regular uid=%s mode=%s bytes=%s sha256=%s\n' "$radio_id" "$1" "$2" "$3" "$radio_hash"
)
radio_node() (
    node_id=$1; node_path=$2; node_type=missing
    if test -L "$node_path"; then node_type=symlink
    elif test -c "$node_path"; then node_type=character
    elif test -b "$node_path"; then node_type=block
    elif test -S "$node_path"; then node_type=socket
    elif test -d "$node_path"; then node_type=directory
    elif test -e "$node_path"; then node_type=other
    elif test ! -d "${node_path%/*}" || test ! -x "${node_path%/*}"; then node_type=not_assessed; fi
    node_uid=not_assessed; node_mode=not_assessed
    if test "$node_type" != missing && test "$node_type" != not_assessed && command -v stat >/dev/null 2>&1; then
        value=$(stat -c '%u %a' "$node_path" 2>/dev/null) || value=
        case "$value" in ''|*[!0-9\ ]*) ;; *) set -- $value; if test "$#" = 2; then node_uid=$1; node_mode=$2; fi;; esac
    fi
    printf 'NODE %s type=%s uid=%s mode=%s\n' "$node_id" "$node_type" "$node_uid" "$node_mode"
)
radio_slot() (
    slot_source=$1; shift; value=not_assessed
    # The getter can return private fields. Only its numeric route enum leaves
    # this function. Each OEM source is retained separately without interpretation.
    case "$slot_source" in
      mdm_get_sim_info|mdm_get_current_slot_info)
        if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
            if reply=$(ubus -t 5 call zwrt_zte_mdm.api "$1" '{}' 2>/dev/null); then
                value=$(printf '%s' "$reply" | jsonfilter -e '@.current_sim_slot' 2>/dev/null) || value=not_assessed
            fi
        fi;;
      uci_active_card_id|uci_active_slot_temp)
        if command -v uci >/dev/null 2>&1; then value=$(uci -q get "$1" 2>/dev/null) || value=not_assessed; fi;;
    esac
    case "$value" in 0|1|2|3) ;; *) value=not_assessed;; esac
    printf 'SLOT %s value=%s\n' "$slot_source" "$value"
)
radio_report() {
    printf 'FIRMWARE_RADIO_V1\n'
    for pair in firmware_mdt:/firmware/image/modem.mdt firmware_b16:/firmware/image/modem.b16 mdm:/usr/bin/zte_topsw_mdm diag_router:/usr/bin/diag-router; do
        radio_path "${pair%%:*}" "${pair#*:}"
    done
    for segment in /firmware/image/modem.b[0-9][0-9]; do
        test -e "$segment" || test -L "$segment" || continue
        name=${segment##*/}; test "$name" != modem.b16 || continue
        radio_path "modem_segment_${name#modem.}" "$segment"
    done
    for pair in diag:/dev/diag diag_tty:/dev/diag_tty at_mdm0:/dev/at_mdm0 at_mdm1:/dev/at_mdm1 ffs_diag:/dev/ffs-diag ffs_diag_1:/dev/ffs-diag-1 ffs_diag_2:/dev/ffs-diag-2 diag_socket:/dev/socket/diag; do
        radio_node "${pair%%:*}" "${pair#*:}"
    done
    if command -v awk >/dev/null 2>&1 && test -r /proc/net/unix; then
        awk 'NR>1 && ($8=="@diag" || $8=="@diag_socket" || $8=="/dev/socket/diag") && $4~/^[0-9A-Fa-f]+$/ && $5~/^[0-9A-Fa-f]+$/ && $6~/^[0-9A-Fa-f]+$/ {name=($8=="@diag"?"abstract_diag":($8=="@diag_socket"?"abstract_diag_socket":"filesystem_diag"));printf "DIAG_SOCKET %s flags=%s type=%s state=%s\n",name,$4,$5,$6;n++} END{printf "DIAG_SOCKETS state=observed count=%d\n",n+0}' /proc/net/unix
    else printf 'DIAG_SOCKETS state=not_assessed count=0\n'; fi
    radio_slot mdm_get_sim_info get_sim_info
    radio_slot mdm_get_current_slot_info zte_get_current_slot_info
    radio_slot uci_active_card_id zwrt_zte_mdm.sim_info.sim_active_card_id
    radio_slot uci_active_slot_temp zwrt_zte_mdm.sim_info.simcard_active_slot_temp
    # qrtr-lookup asks only the name service for endpoint numbers. It does not
    # connect to UIM/DIAG services or send card/NV messages.
    if command -v timeout >/dev/null 2>&1 && command -v qrtr-lookup >/dev/null 2>&1 && command -v awk >/dev/null 2>&1 && reply=$(timeout 6 qrtr-lookup 2>/dev/null); then
        printf '%s\n' "$reply" | awk 'NF>=5 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ && $4~/^[0-9]+$/ && $5~/^[0-9]+$/ && length($1)<=10 && length($2)<=10 && length($3)<=10 && length($4)<=10 && length($5)<=10 {printf "QRTR service=%s version=%s instance=%s node=%s port=%s\n",$1,$2,$3,$4,$5;n++} END{printf "QRTR_INVENTORY state=observed count=%d\n",n+0}'
    else printf 'QRTR_INVENTORY state=not_assessed count=0\n'; fi
    if command -v awk >/dev/null 2>&1; then
        for block in /sys/class/block/mmcblk[0-9]p[0-9]*; do
            test -d "$block" && test -r "$block/uevent" || continue
            name=$(awk -F= '$1=="PARTNAME" && $2~/^(modem|modem_a|modem_b|modemst1|modemst2|fsg|fsc|persist|userdata|rawdump|system|system_b|ztedata|ztedata_b|zterw|zteoverlay)$/ {print $2}' "$block/uevent")
            case "$name" in ''|*[!a-z0-9_]*) continue;; esac
            block_name=${block##*/}; block_index=${block_name#mmcblk[0-9]p}; case "$block_index" in ''|*[!0-9]*) continue;; esac
            sectors=$(cat "$block/size" 2>/dev/null) || sectors=not_assessed
            start=$(cat "$block/start" 2>/dev/null) || start=not_assessed
            ro=$(cat "$block/ro" 2>/dev/null) || ro=not_assessed
            case "$sectors" in ''|*[!0-9]*) sectors=not_assessed;; esac
            case "$start" in ''|*[!0-9]*) start=not_assessed;; esac
            case "$ro" in 0|1) ;; *) ro=not_assessed;; esac
            printf 'PARTITION name=%s block=%s sectors=%s start=%s ro=%s\n' "$name" "$block_name" "$sectors" "$start" "$ro"
        done
        if test -r /proc/self/mountinfo; then
            awk '$5=="/data" || $5=="/firmware" {mount=($5=="/data"?"data":"firmware");mode="unknown";if($6~/(^|,)rw(,|$)/)mode="rw";else if($6~/(^|,)ro(,|$)/)mode="ro";kind="unknown";for(i=7;i<NF;i++)if($i=="-"){if($(i+1)~/^(ext4|squashfs|ubifs|tmpfs|overlay|vfat)$/)kind=$(i+1);break}printf "MOUNT %s mode=%s type=%s\n",mount,mode,kind}' /proc/self/mountinfo
        fi
    fi
    printf 'POLICY nv_read=0 apdu_sent=0 radio_changed=0 profile_changed=0 private_identifiers_exported=0\n'
    printf 'FIRMWARE_RADIO_END\n'
}

case "$action" in
radio)
    test "$#" = 1 || fail ARGUMENTS
    radio_report
    ;;
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
    for id in ui english chinese init original_ui original_english original_chinese original_init font_zhengyuan font_roboto font_oswald busybox dropbear curl ipacm ipa_switch network_init netifd procd ubusd ubus_cli uci_cli lua_cli mdm qcril diag_router libdiag libzte_sdk libzte_gesture libzte_log libfreetype libpng libdrm libgcc libc libuci libubus libubox libblobmsg_json libjson_c liblua lua_uci lua_jsonc firmware_mdt firmware_b16 libqcril_nr libqcril_nrril libzte_qmi libqmiservices libqmi_cci libqmi_csi libqmi_common libqmi_encdec libqmi_sap libqrtr libqsocket libglib libgthread liblog libtime_genoff libsqlite3; do file_row "$id"; done
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
