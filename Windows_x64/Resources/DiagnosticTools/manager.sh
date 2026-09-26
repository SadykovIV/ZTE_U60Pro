#!/bin/sh
# Private, reversible diagnostic tools. Never invokes opkg or changes startup/PATH.
set -eu
umask 077
export LC_ALL=C
BASE=/data/zte-imei-apps
ROOT=/data/zte-imei-apps/diagnostics
RELEASES=$ROOT/releases
TIMEOUT_SHA=6e81024c273080294a251ae38572f1ef0cb496fbd16c7009c6a4ae1c07fb55ff
fail() { printf 'DIAG_ERROR %s\n' "$1" >&2; exit 1; }
hex64() { printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{64}$'; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
hash() { sha256sum "$1" | awk '{print $1}'; }
safe_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u' "$1")" = 0 ] || fail UNSAFE_DIRECTORY
    mode=$(stat -c '%a' "$1")
    [ "$((0$mode & 022))" = 0 ] || fail UNSAFE_PERMISSIONS
}
private_dir() { safe_dir "$1"; [ "$(stat -c '%a' "$1")" = 700 ] || fail UNSAFE_PERMISSIONS; }
safe_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u' "$1")" = 0 ] && [ "$(stat -c '%h' "$1")" = 1 ] || fail UNSAFE_FILE
    mode=$(stat -c '%a' "$1")
    case "$mode" in 600|700) ;; *) fail UNSAFE_PERMISSIONS;; esac
}
# An atomic directory serializes Windows-bundled manager invocations even on
# B31, where neither a standalone flock nor a BusyBox flock applet exists.
# A killed process leaves the directory in place: do not guess that it is stale.
verify_lock_dir() { private_dir "$1"; }
verify_lock_file() { safe_file "$1"; }
# ATOMIC_LOCK_BEGIN
acquire_atomic_lock() {
    LOCK_DIR=$1; LOCK_TOKEN=$CID:$BOOT:$$; LOCK_HELD=0
    if ! mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then fail BUSY; fi
    LOCK_HELD=1
    verify_lock_dir "$LOCK_DIR"
    printf '%s\n' "$LOCK_TOKEN" > "$LOCK_DIR/owner" || fail LOCK_OWNER
    verify_lock_file "$LOCK_DIR/owner"
}
release_atomic_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] &&
        [ -f "$LOCK_DIR/owner" ] && [ ! -L "$LOCK_DIR/owner" ] &&
        [ "$(cat "$LOCK_DIR/owner")" = "$LOCK_TOKEN" ] || return 1
    rm "$LOCK_DIR/owner" && rmdir "$LOCK_DIR" || return 1
    LOCK_HELD=0
}
# ATOMIC_LOCK_END
diagnostic_cleanup() {
    code=$?; trap - EXIT HUP INT TERM
    release_atomic_lock || code=1
    exit "$code"
}
check_base() {
    safe_dir /; safe_dir /data
    if exists "$BASE"; then
        safe_dir "$BASE"; safe_file "$BASE/.zte-imei-owner"
        [ "$(cat "$BASE/.zte-imei-owner")" = zte-imei-apps-v1 ] || fail UNKNOWN_OWNER
    fi
}
check_identity() {
    [ "$(cat /sys/block/mmcblk0/device/cid)" = "$CID" ] && [ "$(cat /proc/sys/kernel/random/boot_id)" = "$BOOT" ] || fail DEVICE_CHANGED
}
read_free() {
    FREE=$(df -Pk /data | awk 'NR==2 {print $4}')
    case "$FREE" in ''|*[!0-9]*) fail FREE_SPACE;; esac
}
check_capabilities() {
    for utility in tar gzip od sha256sum stat find sort awk sed df sync; do
        command -v "$utility" >/dev/null 2>&1 || fail "CAPABILITY_$utility"
    done
}
check_platform() {
    [ "$(id -u)" = 0 ] || fail ROOT_REQUIRED
    [ "$(uname -m)" = aarch64 ] || fail UNSUPPORTED_PLATFORM
    grep -qx "DISTRIB_RELEASE='23.05.4'" /etc/openwrt_release && grep -qx "DISTRIB_ARCH='aarch64_cortex-a53'" /etc/openwrt_release || fail UNSUPPORTED_PLATFORM
    awk '$2 == "/data" {n++; split($4,a,","); for(i in a) {if(a[i]=="rw")rw=1; if(a[i]=="noexec")bad=1}} END {exit !(n==1 && rw && !bad)}' /proc/mounts || fail DATA_NOT_EXECUTABLE
    read_free
}
check_supervisor() {
    supervisor_stage=${0%/*}
    printf '%s\n' "$supervisor_stage" | grep -Eq '^/tmp/zte-diag-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail SUPERVISOR_PATH
    private_dir "$supervisor_stage"
    supervisor=$supervisor_stage/zte-timeout
    [ -f "$supervisor" ] && [ ! -L "$supervisor" ] && [ -x "$supervisor" ] || fail SUPERVISOR_FILE
    safe_file "$supervisor"
    [ "$(hash "$supervisor")" = "$TIMEOUT_SHA" ] || fail SUPERVISOR_HASH
}
check_version() {
    # Firmware B31 lacks timeout, including the BusyBox applet. Every self-test
    # uses this invocation's pinned supervisor; inspection does not execute it.
    check_supervisor
    "$supervisor" 10 "$1" --version >/dev/null 2>&1 || fail SELF_TEST
}
check_mounts() {
    if awk -v root="$ROOT" '$2 == root || index($2,root "/")==1 {found=1} END {exit !found}' /proc/mounts; then fail NESTED_MOUNT; fi
}
running() {
    RUNNING=0
    for entry in /proc/[0-9]*/exe; do
        target=$(readlink "$entry" 2>/dev/null || true)
        case "$target" in "$RELEASES"/*) RUNNING=1;; esac
    done
    for entry in /proc/[0-9]*/maps; do
        [ -f "$entry" ] || continue
        if grep -F "$RELEASES/" "$entry" >/dev/null 2>&1; then RUNNING=1
        else
            code=$?
            [ "$code" = 1 ] || [ ! -e "$entry" ] || fail PROCESS_CHECK
        fi
    done
}
stopped() { running; [ "$RUNNING" = 0 ] || fail TOOLS_RUNNING; }
verify_release() {
    release=$RELEASES/$1
    private_dir "$release"; safe_file "$release/FILES.sha256"
    [ "$(hash "$release/FILES.sha256")" = "$1" ] || fail MANIFEST_HASH
    # Reject aliases, traversal, duplicate paths and manifest self-reference
    # before sha256sum is allowed to open any manifest-specified path.
    awk '
      length($1)!=64 || $1 ~ /[^0-9a-f]/ || substr($0,65,2)!="  " {exit 1}
      {p=substr($0,67); if(p=="" || p=="FILES.sha256" || p !~ /^[a-zA-Z0-9_.\/+\-]+$/ || p ~ /^\// || p ~ /\/$/ || p ~ /\/\// || p ~ /(^|\/)\.\.?($|\/)/ || seen[p]++) exit 1; n++}
      END {if(n<6 || n>512) exit 1}' "$release/FILES.sha256" || fail MANIFEST_FORMAT
    actual=$(find "$release" -type f | sed "s|^$release/||" | sort) || fail INVENTORY
    expected=$({ printf '%s\n' FILES.sha256; awk '{print substr($0,67)}' "$release/FILES.sha256"; } | sort)
    [ "$actual" = "$expected" ] || fail INVENTORY
    find "$release" -print | while IFS= read -r item; do
        [ ! -L "$item" ] || fail UNSAFE_FILE
        if [ -d "$item" ]; then private_dir "$item"; else safe_file "$item"; fi
    done 2>/dev/null || fail UNSAFE_RELEASE
    (cd "$release" && sha256sum -c FILES.sha256 >/dev/null 2>&1) || fail CONTENT_HASH
    for tool in htop iperf3 mtr tcpdump mtr-packet; do [ -x "$release/bin/$tool" ] || fail MISSING_TOOL; done
    [ -f "$release/VERSION" ] || fail MISSING_VERSION
}
ALL_TOOLS=htop,iperf3,mtr,tcpdump
canonical_selection() {
    selected_result=
    for selected_tool in htop iperf3 mtr tcpdump; do
        case ",$1," in *,$selected_tool,*) selected_result=${selected_result:+$selected_result,}$selected_tool;; esac
    done
    printf '%s' "${selected_result:-none}"
}
valid_selection() { [ "$1" = none ] || [ "$1" = "$(canonical_selection "$1")" ]; }
without_tool() {
    removal_result=
    for removal_tool in htop iperf3 mtr tcpdump; do
        case ",$1," in *,$removal_tool,*)
            if [ "$removal_tool" != "$2" ]; then removal_result=${removal_result:+$removal_result,}$removal_tool; fi;;
        esac
    done
    printf '%s' "${removal_result:-none}"
}
read_state() {
    ACTIVE=none; PREVIOUS=unset; SELECTED=none; PREVIOUS_SELECTED=unset; LEGACY=0
    exists "$ROOT" || return 0
    private_dir "$ROOT"; private_dir "$RELEASES"; safe_file "$ROOT/.zte-imei-owner"; safe_file "$ROOT/state"
    [ "$(cat "$ROOT/.zte-imei-owner")" = zte-diagnostic-tools-v1 ] || fail UNKNOWN_OWNER
    state_bytes=$(stat -c '%s' "$ROOT/state")
    [ "$state_bytes" -le 320 ] || fail STATE_FORMAT
    # Read once so selected and version are from the same atomic generation.
    state_data=$(cat "$ROOT/state"; printf x); state_data=${state_data%x}
    [ "$(printf '%s' "$state_data" | wc -c | tr -d ' ')" = "$state_bytes" ] || fail STATE_FORMAT
    state_lines=$(printf '%s' "$state_data" | wc -l | tr -d ' ')
    [ "$state_lines" = 2 ] || [ "$state_lines" = 4 ] || fail STATE_FORMAT
    printf '%s' "$state_data" | awk 'NR==1 {if($0 !~ /^active=/)exit 1; p=substr($0,8); if(p!="none" && (length(p)!=64 || p~/[^0-9a-f]/))exit 1}
         NR==2 {if($0 !~ /^previous=/)exit 1; p=substr($0,10); if(p!="none" && p!="unset" && (length(p)!=64 || p~/[^0-9a-f]/))exit 1}
         NR==3 {if($0 !~ /^selected=/)exit 1}
         NR==4 {if($0 !~ /^previous_selected=/)exit 1}
         NR>4 {exit 1} END {if(NR!=2 && NR!=4)exit 1}' || fail STATE_FORMAT
    ACTIVE=$(printf '%s' "$state_data" | sed -n '1s/^active=//p'); PREVIOUS=$(printf '%s' "$state_data" | sed -n '2s/^previous=//p')
    if [ "$state_lines" = 2 ]; then
        # V1 was installed as one unit. Inspection never rewrites it.
        LEGACY=1
        [ "$ACTIVE" = none ] || SELECTED=$ALL_TOOLS
        case "$PREVIOUS" in unset) PREVIOUS_SELECTED=unset;; none) PREVIOUS_SELECTED=none;; *) PREVIOUS_SELECTED=$ALL_TOOLS;; esac
    else
        SELECTED=$(printf '%s' "$state_data" | sed -n '3s/^selected=//p')
        PREVIOUS_SELECTED=$(printf '%s' "$state_data" | sed -n '4s/^previous_selected=//p')
        valid_selection "$SELECTED" || fail STATE_FORMAT
        case "$PREVIOUS_SELECTED" in unset) [ "$PREVIOUS" = unset ] || fail STATE_FORMAT;; *) valid_selection "$PREVIOUS_SELECTED" || fail STATE_FORMAT;; esac
        if [ "$ACTIVE" = none ]; then [ "$SELECTED" = none ] || fail STATE_FORMAT
        else [ "$SELECTED" != none ] || fail STATE_FORMAT; fi
        case "$PREVIOUS" in
            unset) [ "$PREVIOUS_SELECTED" = unset ] || fail STATE_FORMAT;;
            none) [ "$PREVIOUS_SELECTED" = none ] || fail STATE_FORMAT;;
            *) [ "$PREVIOUS_SELECTED" != none ] && [ "$PREVIOUS_SELECTED" != unset ] || fail STATE_FORMAT;;
        esac
    fi
    [ "$ACTIVE" = none ] || verify_release "$ACTIVE"
    case "$PREVIOUS" in none|unset) ;; *) verify_release "$PREVIOUS";; esac
}
report() {
    read_state; running; read_free
    printf 'ZTE_DIAG_TOOLS_V2\nactive=%s\nprevious=%s\nselected=%s\nprevious_selected=%s\nrunning=%s\nfree_kib=%s\n' "$ACTIVE" "$PREVIOUS" "$SELECTED" "$PREVIOUS_SELECTED" "$RUNNING" "$FREE"
}
lock_and_initialize() {
    if [ "$ACTION" != install ] && ! exists "$ROOT"; then fail NOT_INSTALLED; fi
    if ! exists "$BASE"; then mkdir -m 700 "$BASE"; printf '%s\n' zte-imei-apps-v1 > "$BASE/.zte-imei-owner"; fi
    check_base
    # When available, also take the old advisory lock to coordinate with an
    # already running pre-Windows manager. It is never required on B31.
    if command -v flock >/dev/null 2>&1; then
        if exists "$BASE/.diagnostics.lock"; then safe_file "$BASE/.diagnostics.lock"; fi
        exec 9>> "$BASE/.diagnostics.lock"
        flock -n 9 2>/dev/null || fail BUSY
    fi
    LOCK_HELD=0
    trap diagnostic_cleanup EXIT
    trap 'exit 1' HUP INT TERM
    acquire_atomic_lock "$BASE/.diagnostics.lock.d"
    if ! exists "$ROOT"; then
        [ "$ACTION" = install ] || fail NOT_INSTALLED
        init=$BASE/.diagnostics-init-$$
        ! exists "$init" || fail STAGING_EXISTS
        mkdir -m 700 "$init" "$init/releases"
        printf '%s\n' zte-diagnostic-tools-v1 > "$init/.zte-imei-owner"
        printf 'active=none\nprevious=unset\nselected=none\nprevious_selected=unset\n' > "$init/state"
        mv "$init" "$ROOT"
    fi
    read_state
}
# Decode raw USTAR headers instead of trusting human-readable tar listings.
# No PAX/GNU headers, prefix aliases, links, devices, sparse files or directories.
tar_inventory() {
    od -An -v -tu1 "$1" | awk '
    function bad(){failed=1; exit 1}
    function string(a,z, v,i,ended){v="";ended=0;for(i=a;i<=z;i++){if(b[i]==0)ended=1;else{if(ended || b[i]<32 || b[i]>126)bad();v=v sprintf("%c",b[i])}}return v}
    function octal(a,z, v,i,n,ended){v=0;n=0;ended=0;for(i=a;i<=z;i++){if(b[i]==0 || b[i]==32){if(n)ended=1}else{if(ended || b[i]<48 || b[i]>55)bad();v=v*8+b[i]-48;n++}}if(!n)bad();return v}
    function header( i,zero,n,mode,size,sum,stored){
      if(skip>0){skip--;return}
      zero=1;for(i=1;i<=512;i++)if(b[i]!=0)zero=0
      if(zero){ends++;return} if(ends)bad()
      n=string(1,100);if(n=="" || n !~ /^[a-zA-Z0-9_.\/+\-]+$/ || n~/^\// || n~/\/$/ || n~/\/\// || n~/(^|\/)\.\.?($|\/)/ || seen[n]++)bad()
      if(string(258,263)!="ustar" || string(264,265)!="00" || (b[157]!=0 && b[157]!=48) || string(158,257)!="" || string(346,500)!="")bad()
      mode=octal(101,108);if(mode!=384 && mode!=448)bad()
      if(octal(109,116)!=0 || octal(117,124)!=0)bad()
      size=octal(125,136);total+=size;if(size>33554432 || total>33554432 || ++files>513)bad()
      stored=octal(149,156);sum=0;for(i=1;i<=512;i++)sum+= (i>=149 && i<=156 ? 32 : b[i]);if(sum!=stored)bad()
      print n;skip=int((size+511)/512)
    }
    {for(i=1;i<=NF;i++){b[++pos]=$i;if(pos==512){header();pos=0}}}
    END {if(failed || pos || skip || ends<2 || files<7)exit 1}'
}
check_stage() {
    printf '%s\n' "$STAGE" | grep -Eq '^/tmp/zte-diag-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail STAGE_PATH
    private_dir "$STAGE"; safe_file "$STAGE/bundle.tar.gz"
    [ "$(stat -c '%s' "$STAGE/bundle.tar.gz")" -le 16777216 ] || fail ARCHIVE_SIZE
    [ "$(hash "$STAGE/bundle.tar.gz")" = "$ARCHIVE_SHA" ] || fail ARCHIVE_HASH
    ! exists "$STAGE/bundle.tar" && ! exists "$STAGE/archive.files" || fail STAGING_EXISTS
    (ulimit -f 65536; gzip -dc "$STAGE/bundle.tar.gz" > "$STAGE/bundle.tar") || fail ARCHIVE_FORMAT
    safe_file "$STAGE/bundle.tar"
    [ "$(stat -c '%s' "$STAGE/bundle.tar")" -le 33554432 ] || fail ARCHIVE_SIZE
    tar_inventory "$STAGE/bundle.tar" > "$STAGE/archive.files" || fail ARCHIVE_FORMAT
    grep -qx FILES.sha256 "$STAGE/archive.files" || fail MISSING_MANIFEST
}
commit() {
    check_identity; check_base; check_mounts; stopped
    # Revalidate the exact old state under the lock before the atomic switch.
    read_state
    [ "$ACTIVE" = "$OLD_ACTIVE" ] && [ "$PREVIOUS" = "$OLD_PREVIOUS" ] && [ "$SELECTED" = "$OLD_SELECTED" ] && [ "$PREVIOUS_SELECTED" = "$OLD_PREVIOUS_SELECTED" ] || fail STATE_CHANGED
    case "$NEW_ACTIVE" in none) ;; *) verify_release "$NEW_ACTIVE";; esac
    temp=$ROOT/.state-$$
    ! exists "$temp" || fail STAGING_EXISTS
    printf 'active=%s\nprevious=%s\nselected=%s\nprevious_selected=%s\n' "$NEW_ACTIVE" "$NEW_PREVIOUS" "$NEW_SELECTED" "$NEW_PREVIOUS_SELECTED" > "$temp"
    safe_file "$temp"; sync
    check_identity; stopped
    mv "$temp" "$ROOT/state"; sync
}
[ "$#" -ge 1 ] || fail ARGUMENTS
ACTION=$1; shift
check_capabilities; check_base; check_mounts
case "$ACTION" in
inspect) [ "$#" = 0 ] || fail ARGUMENTS; check_platform; report; exit 0;;
install)
    [ "$#" = 5 ] || [ "$#" = 6 ] || fail ARGUMENTS
    STAGE=$1; BUNDLE=$2; ARCHIVE_SHA=$3
    if [ "$#" = 6 ]; then TOOL=$4; CID=$5; BOOT=$6; else TOOL=all; CID=$4; BOOT=$5; fi
    case "$TOOL" in all|htop|iperf3|mtr|tcpdump) ;; *) fail UNKNOWN_TOOL;; esac
    hex64 "$BUNDLE" && hex64 "$ARCHIVE_SHA" || fail ARGUMENTS
    ;;
remove)
    [ "$#" = 2 ] || [ "$#" = 3 ] || fail ARGUMENTS
    if [ "$#" = 3 ]; then TOOL=$1; CID=$2; BOOT=$3; else TOOL=all; CID=$1; BOOT=$2; fi
    case "$TOOL" in all|htop|iperf3|mtr|tcpdump) ;; *) fail UNKNOWN_TOOL;; esac
    ;;
rollback) [ "$#" = 2 ] || fail ARGUMENTS; CID=$1; BOOT=$2;;
*) fail ARGUMENTS;;
esac
printf '%s\n' "$CID" | grep -Eq '^[0-9a-f]{32}$' || fail ARGUMENTS
printf '%s\n' "$BOOT" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail ARGUMENTS
check_identity; check_platform
[ ! -e /tmp/fota_install_processing ] || fail FIRMWARE_UPDATE
if [ "$ACTION" = install ]; then [ "$FREE" -ge 32768 ] || fail FREE_SPACE; check_supervisor; check_stage; fi
check_identity
lock_and_initialize; stopped
OLD_ACTIVE=$ACTIVE; OLD_PREVIOUS=$PREVIOUS; OLD_SELECTED=$SELECTED; OLD_PREVIOUS_SELECTED=$PREVIOUS_SELECTED
case "$ACTION" in
install)
    # A per-tool action must not silently upgrade other selected applications.
    if [ "$TOOL" != all ] && [ "$ACTIVE" != none ] && [ "$ACTIVE" != "$BUNDLE" ] && [ "$SELECTED" != "$TOOL" ]; then fail SHARED_VERSION_CONFLICT; fi
    if [ "$TOOL" = all ]; then NEW_SELECTED=$ALL_TOOLS; TEST_TOOLS='htop iperf3 mtr tcpdump'
    else NEW_SELECTED=$(canonical_selection "$SELECTED,$TOOL"); TEST_TOOLS=$TOOL; fi
    if ! exists "$RELEASES/$BUNDLE"; then
        candidate=$RELEASES/.candidate-${STAGE##*/}
        ! exists "$candidate" || fail STAGING_EXISTS
        mkdir -m 700 "$candidate"
        tar -xf "$STAGE/bundle.tar" -C "$candidate" || fail ARCHIVE_EXTRACT
        # The manifest identifies the final directory. Validate in-place using
        # a temporary RELEASES binding; do not rename unverified content active.
        saved_releases=$RELEASES; candidate_parent=$RELEASES/.verify-${STAGE##*/}
        ! exists "$candidate_parent" || fail STAGING_EXISTS
        mkdir -m 700 "$candidate_parent"; mv "$candidate" "$candidate_parent/$BUNDLE"
        RELEASES=$candidate_parent; verify_release "$BUNDLE"; RELEASES=$saved_releases
        mv "$candidate_parent/$BUNDLE" "$RELEASES/$BUNDLE"; rmdir "$candidate_parent"
    fi
    verify_release "$BUNDLE"
    for tool in $TEST_TOOLS; do check_version "$RELEASES/$BUNDLE/bin/$tool"; done
    verify_release "$BUNDLE"
    NEW_ACTIVE=$BUNDLE
    if [ "$ACTIVE" != "$BUNDLE" ] || [ "$SELECTED" != "$NEW_SELECTED" ]; then
        NEW_PREVIOUS=$ACTIVE; NEW_PREVIOUS_SELECTED=$SELECTED; commit
    elif [ "$LEGACY" = 1 ]; then
        NEW_PREVIOUS=$PREVIOUS; NEW_PREVIOUS_SELECTED=$PREVIOUS_SELECTED; commit
    fi
    ;;
remove)
    if [ "$TOOL" = all ]; then NEW_SELECTED=none; else NEW_SELECTED=$(without_tool "$SELECTED" "$TOOL"); fi
    if [ "$NEW_SELECTED" = none ]; then NEW_ACTIVE=none; else NEW_ACTIVE=$ACTIVE; fi
    if [ "$SELECTED" != "$NEW_SELECTED" ]; then
        NEW_PREVIOUS=$ACTIVE; NEW_PREVIOUS_SELECTED=$SELECTED; commit
    elif [ "$LEGACY" = 1 ]; then
        NEW_PREVIOUS=$PREVIOUS; NEW_PREVIOUS_SELECTED=$PREVIOUS_SELECTED; commit
    fi
    ;;
rollback)
    [ "$PREVIOUS" != unset ] || fail NO_ROLLBACK
    NEW_ACTIVE=$PREVIOUS; NEW_PREVIOUS=$ACTIVE; NEW_SELECTED=$PREVIOUS_SELECTED; NEW_PREVIOUS_SELECTED=$SELECTED
    if [ "$NEW_ACTIVE" != none ]; then
        verify_release "$NEW_ACTIVE"
        for tool in $(printf '%s' "$NEW_SELECTED" | tr ',' ' '); do check_version "$RELEASES/$NEW_ACTIVE/bin/$tool"; done
    fi
    commit
    ;;
esac
report
