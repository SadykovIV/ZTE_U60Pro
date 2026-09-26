#!/bin/sh
# B31 IPv4 TTL manager. Only owned mangle chains and marked persistence entries
# are changed. No firewall restart, global flush, conntrack or IPv6 changes.
# install STAGE CID OUT IN | status CID | apply CID OUT IN | disable CID | reapply
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
root=/data/zte-imei-ttl
tag=zte-imei-ttl-v1
lock=/tmp/zte-imei-ttl-lock
hotplug=/etc/hotplug.d/iface/99-zte-imei-ttl
firewall=/etc/config/firewall
rc_local=/etc/rc.local
out_chain=ZTE_IMEI_TTL_OUT
in_chain=ZTE_IMEI_TTL_IN
revision=20260922
firmware_sha=604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263
router_sha=55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f
boot_sha=d13e69f8b9471ac6ab11fbace62cac1d5b64a16770c02d728bbebae3bd898040
firewall_sha=7610ef7955d21dd21532ce7149a57418daedd7dfcac1887350eb3223ba943600
hotplug_sha=5943e73d5f09a19b920f0ca3687a4f4a3215f9bd972d619af3a0b7d780dee30a
mode=${1:-}
cid=
outbound=off
inbound=off
error_code=
work=
lock_owned=0
transaction=0
acceleration_policy_verified=1
ipa_switch=/sbin/ipacm_switch.sh
ipa_switch_sha=8947eee9c554453dc8eeb77df933cd12899f447c8c03df3505c57c7b526d22b9
ipacm_sha=95385816da7b2edb9a977cee328c091753463fcd4a70a67fa1676e8b335c11c0
ipa_runtime=$lock/ipacm.state

hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
exists() { test -e "$1" || test -L "$1"; }
plain() { test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0; }
safe_dir() {
    test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || return 1
    permissions=$(stat -c %a "$1")
    case "$permissions" in ''|*[!0-7]*) return 1;; esac
    test "$((0$permissions & 022))" = 0
}
private() { safe_dir "$1" && test "$(stat -c %a "$1")" = 700; }
valid_cid() { test "${#1}" = 32 && case "$1" in *[!a-f0-9]*) return 1;; esac; }
valid_value() {
    test "$1" = off && return 0
    case "$1" in ''|*[!0-9]*|0*) return 1;; esac
    test "${#1}" -le 3 && test "$1" -ge 1 && test "$1" -le 255
}
fail() { error_code=$1; printf 'TTL_ERROR %s\n' "$1" >&2; exit 1; }
profile_supported() {
    test "$(id -u)" = 0 && test "$(uname -m)" = aarch64 &&
    test "$(hash /firmware/image/modem.b16)" = "$firmware_sha" &&
    test "$(hash /usr/bin/diag-router)" = "$router_sha" &&
    iptables --version 2>/dev/null | grep -q 'v1.8.8 (legacy)' &&
    grep -q '^TTL$' /proc/net/ip_tables_targets
}
# This B31 policy passed the sustained-flow trial recorded in evidence/ttl-20260922.
# A populated rule/counter does not prove that later IPA packets use netfilter.
ipa_tools_valid() {
    plain "$ipa_switch" && plain /usr/bin/ipacm &&
    test "$(hash "$ipa_switch")" = "$ipa_switch_sha" && test "$(hash /usr/bin/ipacm)" = "$ipacm_sha"
}
ipa_flags() {
    ipa_close=$(uci -q get zwrt_router.tmp_router.close_ipa_acce 2>/dev/null || printf absent)
    ipa_disabled=$(uci -q get zwrt_router.other.ipa_disable 2>/dev/null || printf absent)
    case "$ipa_close:$ipa_disabled" in 0:0|0:1|0:absent|1:0|1:1|1:absent|absent:0|absent:1|absent:absent) ;; *) return 1;; esac
}
ipa_pid() {
    candidates=$(pidof ipacm 2>/dev/null) || return 1
    ipacm_pid=
    for candidate in $candidates; do
        case "$candidate" in ''|*[!0-9]*) return 1;; esac
        if test "$(readlink "/proc/$candidate/exe" 2>/dev/null || true)" = /usr/bin/ipacm; then
            test -z "$ipacm_pid" || return 1
            ipacm_pid=$candidate
        fi
    done
    test -n "$ipacm_pid"
}
ipa_switch_mode() {
    ipa_pid && ipa_flags || return 1
    # Mirror the pinned vendor switch's flag/signals, but resolve /proc/exe
    # ourselves: stock pgrep can select the separate ujail wrapper named ipacm.
    case "$1" in
      off) uci -q set zwrt_router.tmp_router.close_ipa_acce=1 && kill -USR1 "$ipacm_pid";;
      on)
        uci -q set zwrt_router.tmp_router.close_ipa_acce=0 || return 1
        if test "$ipa_disabled" != 1; then kill -USR2 "$ipacm_pid"; fi
        ;;
      *) return 1;;
    esac
}
acceleration_supported() {
    test "$acceleration_policy_verified" = 1 && ipa_tools_valid && ipa_flags && ipa_pid || return 1
    ! grep -Eq '^(shortcut[_-]fe|fast_classifier|sfe_|nf_flow_table)' /proc/modules &&
    ! grep -q '^FLOWOFFLOAD$' /proc/net/ip_tables_targets
}
ipa_original_valid() {
    plain "$root/ipa.original" && test "$(stat -c %a "$root/ipa.original")" = 600 || return 1
    awk 'NR==1 && /^close=(0|1|absent)$/ {a=1;next} NR==2 && /^disabled=(0|1|absent)$/ {b=1;next} NR==3 && /^pending=(0|1)$/ {c=1;next} {bad=1} END{exit !(a && b && c && NR==3 && !bad)}' "$root/ipa.original" || return 1
    original_close=$(sed -n '1s/^close=//p' "$root/ipa.original")
    original_disabled=$(sed -n '2s/^disabled=//p' "$root/ipa.original")
    original_pending=$(sed -n '3s/^pending=//p' "$root/ipa.original")
}
ipa_persisted_close() {
    # Query a differently named private copy: live /tmp/.uci/zwrt_router deltas
    # cannot be loaded for this package. Never commit or revert the package.
    plain /etc/config/zwrt_router || return 1
    persisted_package="zte_imei_ttl_persisted_$$"
    cp /etc/config/zwrt_router "$work/$persisted_package" || return 1
    persisted_close=$(uci -q -c "$work" -t "$work" get "$persisted_package.tmp_router.close_ipa_acce" 2>/dev/null || printf absent)
    rm "$work/$persisted_package" || return 1
    case "$persisted_close" in 0|1|absent) ;; *) return 1;; esac
}
acceleration_prepare() {
    acceleration_supported || return 1
    if ! exists "$root/ipa.original"; then
        router_pending=$(uci -q changes zwrt_router) || return 1
        own_pending=0
        if printf '%s\n' "$router_pending" | grep -Eq '^[+-]?zwrt_router\.tmp_router(\.close_ipa_acce)?(=|$)'; then own_pending=1; fi
        printf 'close=%s\ndisabled=%s\npending=%s\n' "$ipa_close" "$ipa_disabled" "$own_pending" > "$root/.ipa.new" &&
        mv "$root/.ipa.new" "$root/ipa.original" && sync || return 1
    fi
    ipa_original_valid || return 1
    before_pid=$ipacm_pid
    ipa_switch_mode off || return 1
    ipa_flags && ipa_pid && test "$ipa_close" = 1 && test "$ipacm_pid" = "$before_pid" || return 1
    if exists "$ipa_runtime"; then plain "$ipa_runtime" && test "$(stat -c %a "$ipa_runtime")" = 600 || return 1; fi
    printf '%s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$ipacm_pid" > "$ipa_runtime"
}
acceleration_active() {
    acceleration_supported && test "$ipa_close" = 1 && ipa_original_valid && plain "$ipa_runtime" &&
    test "$(stat -c %a "$ipa_runtime")" = 600 &&
    test "$(cat "$ipa_runtime")" = "$(cat /proc/sys/kernel/random/boot_id) $ipacm_pid"
}
acceleration_restore() {
    exists "$root/ipa.original" || return 0
    ipa_tools_valid && ipa_original_valid && ipa_flags && ipa_pid || return 1
    # Only undo the close flag while its effective value is still ours. The
    # stock 'on' command respects the current separate ipa_disable setting.
    # An originally software-only modem never receives an enable request.
    if test "$ipa_close" = 1 && test "$original_close" != 1; then
        before_pid=$ipacm_pid
        ipa_switch_mode on || return 1
        ipa_flags && ipa_pid && test "$ipa_close" = 0 && test "$ipacm_pid" = "$before_pid" || return 1
        if test "$original_close" = absent; then
            uci -q delete zwrt_router.tmp_router.close_ipa_acce || return 1
            ipa_flags && test "$ipa_close" = absent || return 1
        fi
    fi
    if test "$original_pending" = 0 && test "$ipa_close" = "$original_close"; then
        ipa_persisted_close || return 1
        if test "$persisted_close" = "$original_close"; then
            uci -q revert zwrt_router.tmp_router.close_ipa_acce || return 1
            ipa_flags && test "$ipa_close" = "$original_close" || return 1
        fi
    fi
    rm -f "$root/ipa.original" "$root/.ipa.new" || return 1
    if exists "$ipa_runtime"; then plain "$ipa_runtime" && rm "$ipa_runtime" || return 1; fi
    sync
}
layout_safe() {
    for directory in /data /etc /etc/config /etc/hotplug.d /etc/hotplug.d/iface; do safe_dir "$directory" || return 1; done
    plain "$firewall" && plain "$rc_local" || return 1
    awk '$5=="/data" && $4=="/" && $6 ~ /(^|,)rw(,|$)/ {for(i=7;i<=NF;i++) if($i=="-" && $(i+1)=="ext4") good++}
      $5=="/data/zte-imei-ttl" || index($5,"/data/zte-imei-ttl/")==1 || $5=="/etc/config" || $5=="/etc/config/firewall" || $5=="/etc/rc.local" || $5=="/etc/hotplug.d" || $5=="/etc/hotplug.d/iface" {bad=1}
      END {exit !(good==1 && !bad)}' /proc/self/mountinfo
}
root_owned() {
    private "$root" && plain "$root/owner" && test "$(cat "$root/owner")" = "$tag" || return 1
    for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        exists "$entry" || continue
        case "${entry##*/}" in
          backup) private "$entry" || return 1;;
          owner|cid|manager.sh|manager.sha256|boot.sh|firewall.sh|hotplug.sh|settings|.pending|.settings.new|ipa.original|.ipa.new) plain "$entry" && test "$(stat -c %a "$entry")" = 600 || return 1;;
          *) return 1;;
        esac
    done
    plain "$root/cid" && valid_cid "$(cat "$root/cid")" && test "$(cat "$root/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" || return 1
    test -z "$cid" || test "$(cat "$root/cid")" = "$cid" || return 1
    if exists "$root/backup"; then
        for entry in "$root/backup"/* "$root/backup"/.[!.]* "$root/backup"/..?*; do
            exists "$entry" || continue
            case "${entry##*/}" in rc.local|firewall) plain "$entry" || return 1;; *) return 1;; esac
        done
    fi
}
assets_valid() {
    for item in manager.sh manager.sha256 boot.sh firewall.sh hotplug.sh; do plain "$root/$item" || return 1; done
    test "$(hash "$root/manager.sh")" = "$(cat "$root/manager.sha256")" &&
    test "$(hash "$root/boot.sh")" = "$boot_sha" &&
    test "$(hash "$root/firewall.sh")" = "$firewall_sha" &&
    test "$(hash "$root/hotplug.sh")" = "$hotplug_sha"
}
read_settings() {
    plain "$root/settings" || return 1
    awk 'NR==1 && /^outbound=(off|[1-9][0-9]*)$/ {a=1;next} NR==2 && /^inbound_inc=(off|[1-9][0-9]*)$/ {b=1;next} {bad=1} END {exit !(a && b && !bad && NR==2)}' "$root/settings" || return 1
    outbound=$(sed -n '1s/^outbound=//p' "$root/settings")
    inbound=$(sed -n '2s/^inbound_inc=//p' "$root/settings")
    valid_value "$outbound" && valid_value "$inbound"
}
write_settings() {
    printf 'outbound=%s\ninbound_inc=%s\n' "$1" "$2" > "$root/.settings.new" &&
    chmod 600 "$root/.settings.new" && mv "$root/.settings.new" "$root/settings" && sync
}
firewall_block() {
    cat <<'EOF'
# BEGIN zte-imei-ttl-v1
config include 'zte_imei_ttl'
        option type 'script'
        option path '/data/zte-imei-ttl/firewall.sh'
        option family 'ipv4'
        option reload '1'
        option enabled '1'
# END zte-imei-ttl-v1
EOF
}
rc_block() {
    cat <<EOF
# BEGIN zte-imei-ttl-v1
if [ -f /data/zte-imei-ttl/boot.sh ] && [ ! -L /data/zte-imei-ttl/boot.sh ] && [ "\$(sha256sum /data/zte-imei-ttl/boot.sh | awk '{print \$1}')" = "$boot_sha" ]; then
        sh /data/zte-imei-ttl/boot.sh >/dev/null 2>&1 || true
fi
# END zte-imei-ttl-v1
EOF
}
extract_block() {
    awk '/^# BEGIN zte-imei-ttl-v1$/ {if(active || seen++)bad=1;active=1} active {print} /^# END zte-imei-ttl-v1$/ {if(!active)bad=1;active=0;ended++} END {if(active || seen!=1 || ended!=1 || bad)exit 1}' "$1"
}
hooks_valid() {
    plain "$hotplug" && test "$(hash "$hotplug")" = "$hotplug_sha" || return 1
    test "$(extract_block "$rc_local")" = "$(rc_block)" && firewall_section_valid
}
firewall_section_valid() {
    # A normal vendor UCI commit removes comments/reformats this file. Ownership
    # is the exact named section and options, not its original text formatting.
    actual_section=$(uci -q show firewall.zte_imei_ttl | LC_ALL=C sort) || return 1
    expected_section=$(printf '%s\n' "firewall.zte_imei_ttl=include" "firewall.zte_imei_ttl.type='script'" "firewall.zte_imei_ttl.path='/data/zte-imei-ttl/firewall.sh'" "firewall.zte_imei_ttl.family='ipv4'" "firewall.zte_imei_ttl.reload='1'" "firewall.zte_imei_ttl.enabled='1'" | LC_ALL=C sort)
    test "$actual_section" = "$expected_section"
}
atomic_replace() {
    source_file=$1; destination=$2; before_sha=$3
    test "$(hash "$destination")" = "$before_sha" || return 1
    temporary="${destination}.zte-imei-ttl-$$"
    ! exists "$temporary" || return 1
    cp -p "$destination" "$temporary" && cat "$source_file" > "$temporary" || return 1
    test "$(hash "$destination")" = "$before_sha" || { rm -f "$temporary"; return 1; }
    mv "$temporary" "$destination" && sync
}
install_hooks() {
    test -z "$(uci -q changes firewall)" || return 1
    if uci -q get firewall.zte_imei_ttl >/dev/null 2>&1; then
        firewall_section_valid || return 1
    else
        ! grep -q 'zte-imei-ttl-v1' "$firewall" || return 1
        before_sha=$(hash "$firewall")
        cat "$firewall" > "$work/firewall.new"
        printf '\n' >> "$work/firewall.new"
        firewall_block >> "$work/firewall.new"
        atomic_replace "$work/firewall.new" "$firewall" "$before_sha" || return 1
    fi
    if grep -q 'zte-imei-ttl-v1' "$rc_local"; then
        test "$(extract_block "$rc_local")" = "$(rc_block)" || return 1
    else
        before_sha=$(hash "$rc_local")
        rc_block > "$work/block"
        awk -v block="$work/block" 'BEGIN{n=0} /^exit 0([ \t]|$)/ && !n {while((getline line < block)>0)print line;close(block);n=1} {print} END{if(!n)exit 1}' "$rc_local" > "$work/rc.new" || return 1
        sh -n "$work/rc.new" || return 1
        atomic_replace "$work/rc.new" "$rc_local" "$before_sha" || return 1
    fi
    if exists "$hotplug"; then plain "$hotplug" && test "$(hash "$hotplug")" = "$hotplug_sha" || return 1
    else
        temporary="${hotplug}.zte-imei-ttl-$$"
        ! exists "$temporary" || return 1
        cp "$root/hotplug.sh" "$temporary" && chmod 600 "$temporary" && mv "$temporary" "$hotplug" && sync || return 1
    fi
    hooks_valid
}
get_devices() {
    route_output=$(ip -4 route show default) || return 1
    devices=$(printf '%s\n' "$route_output" | awk '$1=="default" {for(i=1;i<NF;i++)if($i=="dev" && $(i+1) ~ /^rmnet_data[0-9]+$/)print $(i+1)}' | LC_ALL=C sort -u) || return 1
    for device in $devices; do test "${#device}" -le 15 || return 1; done
}
snapshot() { iptables-save -t mangle > "$work/mangle"; }
owned_rules_safe() {
    # Only exact, commented jump/TTL rule forms constitute our ownership.
    # Any foreign reference to our chain or unexpected content blocks mutation.
    awk -v out="$out_chain" -v incoming="$in_chain" '
      {gsub(/"/,"")}
      $1==":" out {has_out=1;next}
      $1==":" incoming {has_in=1;next}
      $1=="-A" && ($2==out || $2==incoming) {
        if($2==out && $0 ~ /^-A ZTE_IMEI_TTL_OUT -o rmnet_data[0-9]+ -m comment --comment zte-imei-ttl-v1:out -j TTL --ttl-set [1-9][0-9]*$/ && $NF<=255){out_rules++;next}
        if($2==incoming && $0 ~ /^-A ZTE_IMEI_TTL_IN -i rmnet_data[0-9]+ -o br-lan -m comment --comment zte-imei-ttl-v1:in -j TTL --ttl-inc [1-9][0-9]*$/ && $NF<=255){in_rules++;next}
        bad=1;next
      }
      index($0,out) || index($0,incoming) {
        if($0=="-A POSTROUTING -m comment --comment zte-imei-ttl-v1:out -j " out)next
        if($0=="-A FORWARD -m comment --comment zte-imei-ttl-v1:in -j " incoming)next
        bad=1
      }
      END {exit (bad || (has_out && !out_rules) || (has_in && !in_rules))}' "$work/mangle"
}
own_lines() {
    awk '{gsub(/"/,"")} $1=="-A" && ($2=="ZTE_IMEI_TTL_OUT" || $2=="ZTE_IMEI_TTL_IN" || $NF=="ZTE_IMEI_TTL_OUT" || $NF=="ZTE_IMEI_TTL_IN") {print}' "$1" | LC_ALL=C sort
}
desired_lines() {
    if test "$1" != off && test -n "$devices"; then
        printf '%s\n' '-A POSTROUTING -m comment --comment zte-imei-ttl-v1:out -j ZTE_IMEI_TTL_OUT'
        for device in $devices; do printf '%s\n' "-A $out_chain -o $device -m comment --comment $tag:out -j TTL --ttl-set $1"; done
    fi
    if test "$2" != off && test -n "$devices"; then
        printf '%s\n' '-A FORWARD -m comment --comment zte-imei-ttl-v1:in -j ZTE_IMEI_TTL_IN'
        for device in $devices; do printf '%s\n' "-A $in_chain -i $device -o br-lan -m comment --comment $tag:in -j TTL --ttl-inc $2"; done
    fi
}
rules_match() {
    snapshot && owned_rules_safe || return 1
    desired_lines "$1" "$2" | LC_ALL=C sort > "$work/desired"
    own_lines "$work/mangle" > "$work/actual"
    cmp -s "$work/desired" "$work/actual"
}
apply_rules() {
    requested_out=$1; requested_in=$2
    snapshot && owned_rules_safe || return 1
    {
        printf '*mangle\n'
        # All deletions and insertions form one atomic mangle COMMIT. --noflush
        # retains unmentioned chains, policies, marks and rules. Kernel/vendor
        # counter preservation is not guaranteed by this operation.
        awk '{gsub(/"/,"")} $1=="-A" && ($NF=="ZTE_IMEI_TTL_OUT" || $NF=="ZTE_IMEI_TTL_IN") {sub(/^-A /,"-D ");print}' "$work/mangle"
        for chain in "$out_chain" "$in_chain"; do
            if grep -q "^:$chain " "$work/mangle"; then printf '%s\n' "-F $chain" "-X $chain"; fi
        done
        if test "$requested_out" != off && test -n "$devices"; then printf '%s\n' "-N $out_chain"; fi
        if test "$requested_in" != off && test -n "$devices"; then printf '%s\n' "-N $in_chain"; fi
        desired_lines "$requested_out" "$requested_in"
        printf 'COMMIT\n'
    } > "$work/restore"
    iptables-restore --wait 10 --noflush < "$work/restore" || return 1
    rules_match "$requested_out" "$requested_in"
}
acquire_lock() {
    # Publish a private directory atomically before opening writable files.
    # A check-then-open directly in world-writable /tmp permits symlink races.
    if ! mkdir -m 700 "$lock" 2>/dev/null; then private "$lock" || return 1; fi
    if exists "$lock/mutex"; then plain "$lock/mutex" && test "$(stat -c %a "$lock/mutex")" = 600 || return 1; fi
    exec 9> "$lock/mutex"
    # The modem's BusyBox flock has -n but no util-linux -w option.
    lock_attempt=0
    until flock -n 9; do
        lock_attempt=$((lock_attempt + 1))
        test "$lock_attempt" -lt 20 || return 1
        sleep 1
    done
    lock_owned=1
    new_work="/tmp/zte-imei-ttl-work-$$"
    ! exists "$new_work" && mkdir -m 700 "$new_work" || return 1
    work=$new_work
}
status_line() {
    state=disabled; capability=unknown; persistence=none; verification=not-applicable
    if profile_supported; then
        if acceleration_supported; then capability=supported; else capability=unsupported; fi
    else capability=unsupported; fi
    if exists "$root"; then
        if root_owned && assets_valid && read_settings; then
            if hooks_valid; then persistence=boot; fi
            if test "$outbound" != off || test "$inbound" != off; then
                verification=unverified
                if test "$capability" = unsupported || test "$persistence" != boot || ! acceleration_active; then state=error
                else state=configured; fi
            fi
            if test -z "$work" || ! get_devices || ! rules_match "$outbound" "$inbound"; then state=error; fi
            if test "$outbound" != off || test "$inbound" != off; then test -n "${devices:-}" || state=error; fi
            exists "$root/.pending" && state=error
            if test "$outbound" = off && test "$inbound" = off && exists "$root/ipa.original"; then state=error; fi
        else state=error; fi
    elif test -n "$work"; then
        get_devices && rules_match off off || state=error
    fi
    test -z "$error_code" || state=error
    printf 'TTL_STATUS state=%s outbound=%s inbound_inc=%s capability=%s verification=%s persistence=%s\n' "$state" "$outbound" "$inbound" "$capability" "$verification" "$persistence"
}
finish() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$transaction" = 1; then
        # settings is the last durable configuration. A killed action is also
        # reconciled from that file by the next fw3/hotplug/boot invocation.
        if root_owned && read_settings && get_devices; then
            if test "$outbound" = off && test "$inbound" = off; then
                if apply_rules off off >&2; then acceleration_restore >&2 || true; fi
            elif profile_supported && acceleration_active; then apply_rules "$outbound" "$inbound" >&2 || true
            else apply_rules off off >&2 || true; fi
        fi
    fi
    status_line || true
    if test -n "$work" && private "$work"; then
        for item in mangle desired actual restore firewall.new rc.new block; do rm -f "$work/$item"; done
        rmdir "$work" 2>/dev/null || true
    fi
    exit "$result"
}
trap finish EXIT
trap 'error_code=INTERRUPTED; exit 1' HUP INT TERM

case "$mode" in
  install) test "$#" = 5 || fail ARGUMENTS; stage=$2; cid=$3; new_out=$4; new_in=$5;;
  apply) test "$#" = 4 || fail ARGUMENTS; cid=$2; new_out=$3; new_in=$4;;
  disable) test "$#" = 2 || fail ARGUMENTS; cid=$2; new_out=off; new_in=off;;
  status) test "$#" = 2 || fail ARGUMENTS; cid=$2;;
  reapply) test "$#" = 1 || fail ARGUMENTS;;
  *) fail ARGUMENTS;;
esac
if test "$mode" != reapply; then valid_cid "$cid" && test "$cid" = "$(cat /sys/block/mmcblk0/device/cid)" || fail CID_MISMATCH; fi
if test "$mode" = install || test "$mode" = apply || test "$mode" = disable; then
    valid_value "$new_out" && valid_value "$new_in" || fail VALUE_RANGE
fi
layout_safe || fail LAYOUT
acquire_lock || fail BUSY
if test "$mode" = status; then exit 0; fi
if test "$mode" = reapply && ! exists "$root"; then exit 0; fi
if test "$mode" = install || test "$mode" = apply; then
    profile_supported || fail UNSUPPORTED_PROFILE
    if test "$new_out" != off || test "$new_in" != off; then acceleration_supported || fail ACCELERATION_UNVERIFIED; fi
    ! exists /data/local/tmp/zte-imei-installations/active && ! exists /data/local/tmp/open-u60-transactions/active && ! exists /tmp/fota_install_processing || fail OTHER_TRANSACTION
    get_devices || fail ROUTES
    if test "$new_out" != off || test "$new_in" != off; then test -n "$devices" || fail NO_CELLULAR_DEFAULT; fi
fi
if test "$mode" = install; then
    case "$stage" in /tmp/zte-imei-ttl-*) ;; *) fail STAGE_PATH;; esac
    token=${stage#/tmp/zte-imei-ttl-}
    test "${#token}" = 36 && case "$token" in *[!a-f0-9-]*) false;; *) true;; esac || fail STAGE_TOKEN
    private "$stage" || fail STAGE_DIRECTORY
    for item in manager.sh boot.sh firewall.sh hotplug.sh; do plain "$stage/$item" && sh -n "$stage/$item" || fail STAGE_FILE; done
    test "$(hash "$stage/manager.sh")" = "$(hash "$0")" && test "$(hash "$stage/boot.sh")" = "$boot_sha" && test "$(hash "$stage/firewall.sh")" = "$firewall_sha" && test "$(hash "$stage/hotplug.sh")" = "$hotplug_sha" || fail STAGE_INTEGRITY
    if ! exists "$root"; then
        snapshot && owned_rules_safe && rules_match off off || fail FOREIGN_RULES
        ! exists "$hotplug" && ! uci -q get firewall.zte_imei_ttl >/dev/null 2>&1 && ! grep -q 'zte-imei-ttl-v1' "$rc_local" "$firewall" || fail FOREIGN_HOOKS
        staging="/data/zte-imei-ttl.install-$token"
        ! exists "$staging" && mkdir -m 700 "$staging" && mkdir -m 700 "$staging/backup" || fail INSTALL_STAGING
        printf '%s\n' "$tag" > "$staging/owner"
        printf '%s\n' "$cid" > "$staging/cid"
        for item in manager.sh boot.sh firewall.sh hotplug.sh; do cp "$stage/$item" "$staging/$item"; chmod 600 "$staging/$item"; done
        hash "$staging/manager.sh" > "$staging/manager.sha256"
        printf 'outbound=off\ninbound_inc=off\n' > "$staging/settings"
        cp -p "$rc_local" "$staging/backup/rc.local"
        cp -p "$firewall" "$staging/backup/firewall"
        sync
        mv "$staging" "$root" && sync || fail INSTALL_PUBLISH
    fi
    root_owned && assets_valid && test "$(hash "$root/manager.sh")" = "$(hash "$stage/manager.sh")" || fail UNKNOWN_INSTALLATION
    install_hooks || fail HOOK_INSTALL
fi
root_owned && assets_valid && read_settings || fail INSTALLATION_INTEGRITY
if test "$mode" = apply && { test "$new_out" != off || test "$new_in" != off; }; then install_hooks || fail HOOK_INSTALL; fi
old_out=$outbound; old_in=$inbound
get_devices || fail ROUTES
if test "$mode" = reapply; then
    new_out=$outbound; new_in=$inbound
    if test "$new_out" != off || test "$new_in" != off; then
        if ! profile_supported || ! acceleration_supported; then
            apply_rules off off || fail RULE_CLEANUP
            fail ACCELERATION_OR_PROFILE_UNSUPPORTED
        fi
    fi
fi
if test "$new_out" != off || test "$new_in" != off; then hooks_valid || fail HOOK_INTEGRITY; fi
snapshot && owned_rules_safe || fail FOREIGN_RULES
printf 'reconcile\n' > "$root/.pending" && sync || fail JOURNAL
transaction=1
if test "$new_out" = off && test "$new_in" = off; then
    # Persist disable before removing rules: a concurrent or future callback
    # must never resurrect the previous configuration.
    write_settings off off || fail SETTINGS
    apply_rules off off || fail RULE_APPLY
    acceleration_restore || fail ACCELERATION_RESTORE
else
    if test -z "$devices"; then apply_rules off off || fail RULE_CLEANUP; fail NO_CELLULAR_DEFAULT; fi
    acceleration_prepare || fail ACCELERATION_PREPARE
    if ! apply_rules "$new_out" "$new_in"; then
        apply_rules "$old_out" "$old_in" >&2 || true
        fail RULE_APPLY
    fi
    write_settings "$new_out" "$new_in" || fail SETTINGS
fi
rm -f "$root/.pending" && sync || fail JOURNAL_COMPLETE
transaction=0
exit 0
