#!/bin/sh
# Transactional access installation after a fresh measured preflight. Specific
# hardware functions retain their own adapters; access never certifies NV/eSIM.
# No password is an argument, diagnostic, or journal field.
set -eu
umask 077
base=/data/local/tmp/zte-imei-installations
firmware_sha=604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263
router_sha=55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f
profile=b31
boot_id=
fail() { printf 'INSTALL_ERROR %s\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
hex() { case "$1" in ''|*[!0-9a-f]*) return 1;; esac; }
identity() {
    test "$(id -u)" = 0 || fail ROOT_REQUIRED
    test "$(uname -s)" = Linux || fail OS_MISMATCH
    test "$(uname -m)" = aarch64 || fail ARCH_MISMATCH
    hex "$1" && test "${#1}" = 32 || fail CID_FORMAT
    test "$(cat /sys/block/mmcblk0/device/cid)" = "$1" || fail CID_MISMATCH
    if test "$profile" = linux-arm64-access; then
        test "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id" || fail BOOT_MISMATCH
        measured_file /firmware/image/modem.b16 "$firmware_sha" FIRMWARE_MISMATCH
        measured_file /usr/bin/diag-router "$router_sha" ROUTER_MISMATCH
    else
        test "$(hash /firmware/image/modem.b16)" = "$firmware_sha" || fail FIRMWARE_MISMATCH
        test "$(hash /usr/bin/diag-router)" = "$router_sha" || fail ROUTER_MISMATCH
    fi
}
plain_file() { test -f "$1" && test ! -L "$1"; }
# Validate every existing ancestor before treating a missing object as absent.
# Unreadable paths and symlinks cannot become an "absent" identity witness.
measured_file() {
    parent=${1%/*}
    while test -n "$parent"; do
        test ! -L "$parent" || fail IDENTITY_PATH_LINK
        if test -e "$parent"; then
            test -d "$parent" && test -r "$parent" && test -x "$parent" || fail IDENTITY_UNREADABLE
        fi
        parent=${parent%/*}
    done
    if test "$2" = absent; then
        test ! -e "$1" && test ! -L "$1" || fail "$3"
    else
        plain_file "$1" && test -r "$1" || fail IDENTITY_UNREADABLE
        actual=$(hash "$1") || fail IDENTITY_UNREADABLE
        test "$actual" = "$2" || fail "$3"
    fi
}
select_profile() {
    boot_id=${4:-}
    case "$1:$2:$3" in
      b31:604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263:55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f|b02-experimental:7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e:55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f) test -z "$boot_id" || fail ARGUMENTS;;
      linux-arm64-access:*)
        test "$1" = linux-arm64-access || fail UNSUPPORTED_PROFILE
        for value in "$2" "$3"; do
            if test "$value" != absent; then hex "$value" && test "${#value}" = 64 || fail HASH_FORMAT; fi
        done
        printf '%s\n' "$boot_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail BOOT_FORMAT
        ;;
      *) fail UNSUPPORTED_PROFILE;;
    esac
    profile=$1; firmware_sha=$2; router_sha=$3
}
discovery_startup() {
    plain_file "$1" && sh -n "$1" || fail DISCOVERY_STARTUP_REQUIRED
    test "$(grep -cFx "export ZTE_AGENT_MODE='discovery'" "$1")" = 1 || fail DISCOVERY_STARTUP_REQUIRED
    # Reject additional assignments that could override the selected mode.
    test "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?ZTE_AGENT_MODE=' "$1")" = 1 || fail DISCOVERY_STARTUP_REQUIRED
}

safe_directory() {
    test ! -L "$1" || fail DIRECTORY_LINK
    if test -e "$1"; then
        test -d "$1" && test "$(stat -c %u "$1")" = 0 || fail DIRECTORY_OWNER
        permission=$(stat -c %a "$1")
        case "$permission" in ''|*[!0-7]*) fail DIRECTORY_MODE;; esac
        test "$((0$permission & 022))" = 0 || fail DIRECTORY_MODE
    fi
}
mount_access() {
    # Find the effective mount for a path, including an existing bind mount on
    # any ancestor. Duplicate equally-specific mounts are treated as unknown.
    awk -v path="$1" -v need_exec="$2" '
      $5=="/" || $5==path || index(path,$5"/")==1 {
        n=length($5)
        if(n>best){best=n;count=0;opts=$6;type="";for(i=7;i<=NF;i++)if($i=="-")type=$(i+1)}
        if(n==best)count++
      }
      END {exit !(count==1 && opts ~ /(^|,)rw(,|$)/ && (!need_exec || opts !~ /(^|,)noexec(,|$)/) && (type=="ext4" || type=="overlay"))}' /proc/self/mountinfo || fail MOUNT_LAYOUT
}
structural_preflight() {
    for command in sh sha256sum awk grep tr sed cut stat df chmod mkdir cp mv rm rmdir cat sync pidof readlink nohup logger wc sleep id uname; do
        command -v "$command" >/dev/null 2>&1 || fail MISSING_TOOL
    done
    if test "$profile" = linux-arm64-access; then
        for command in od timeout; do command -v "$command" >/dev/null 2>&1 || fail MISSING_TOOL; done
        test "$(cat /proc/1/comm)" = procd || fail STARTUP_NOT_ASSESSED
        plain_file /etc/init.d/done && test -r /etc/init.d/done || fail STARTUP_NOT_ASSESSED
        grep -qE '^[[:space:]]*sh[[:space:]]+/etc/rc\.local([[:space:]]|$)' /etc/init.d/done || fail STARTUP_NOT_ASSESSED
    else
        command -v ubus >/dev/null 2>&1 || fail MISSING_TOOL
    fi
    for directory in /data /data/local /data/local/tmp /data/bin /data/dropbear /etc /etc/dropbear "$base"; do safe_directory "$directory"; done
    test -d /data && test -w /data && test -d /etc && test -w /etc || fail REQUIRED_DIRECTORY
    test -r /proc/self/mountinfo && test -r /proc/net/tcp || fail PROC_LAYOUT
    plain_file /usr/bin/curl && test -x /usr/bin/curl || fail CURL_REQUIRED
    test -d /var/run && test -w /var/run || fail RUNTIME_DIRECTORY
    mount_access /data/local/tmp 1; mount_access /data/bin 1; mount_access /data/dropbear 0; mount_access /etc/dropbear 0
    plain_file /etc/rc.local && test -w /etc/rc.local || fail RC_LOCAL_TYPE
    sh -n /etc/rc.local || fail RC_LOCAL_SYNTAX
    for pending in "$base/active" "$base/lock" /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /tmp/zte-imei-app.lock; do
        test ! -e "$pending" && test ! -L "$pending" || fail RECOVERY_PENDING
    done
    data_free=$(df -Pk /data | awk 'END {print $4}')
    etc_free=$(df -Pk /etc | awk 'END {print $4}')
    case "$data_free:$etc_free" in *[!0-9:]*) fail SPACE_UNKNOWN;; esac
    test -n "$data_free" && test -n "$etc_free" && test "$data_free" -ge 16384 && test "$etc_free" -ge 2048 || fail INSUFFICIENT_SPACE
}
live_agent() {
    for process in $(pidof zte-agent 2>/dev/null || true); do
        if test "$(readlink "/proc/$process/exe" 2>/dev/null || true)" = /data/zte-agent; then
            if test "$profile" = linux-arm64-access; then
                test -r "/proc/$process/environ" || continue
                tr '\000' '\n' < "/proc/$process/environ" | grep -qFx 'ZTE_AGENT_MODE=discovery' || continue
            fi
            return 0
        fi
    done
    return 1
}
safe_id() {
    test "${#1}" = 36 || return 1
    case "$1" in *[!a-zA-Z0-9-]*) return 1;; esac
}

if test "${1:-}" = --preflight; then
    test "$#" = 5 || test "$#" = 6 || fail ARGUMENTS
    select_profile "$3" "$4" "$5" "${6:-}"
    identity "$2"
    structural_preflight
    # /config is a DIAG/EFS object, not the Linux /config path. Firmware/router
    # matches do not establish NV/EFS compatibility; strict runtime reads do.
    printf 'INSTALL_PREFLIGHT %s imei_config=unknown\n' "$profile"
    exit 0
fi

if test "${1:-}" = --commit; then
    test "$#" = 3 || test "$#" = 6 || test "$#" = 7 || fail ARGUMENTS
    journal=$2
    case "$journal" in "$base/"*) ;; *) fail JOURNAL_PATH;; esac
    token=${journal#"$base/"}; safe_id "$token" || fail JOURNAL_ID
    for directory in /data /data/local /data/local/tmp "$base" "$journal"; do safe_directory "$directory"; done
    if test -e "$journal/profile.identity" || test -L "$journal/profile.identity"; then
        plain_file "$journal/profile.identity" && test "$(stat -c %u:%a "$journal/profile.identity")" = 0:600 || fail JOURNAL_PROFILE
        test "$(wc -l < "$journal/profile.identity" | tr -d ' ')" = 1 || fail JOURNAL_PROFILE
        IFS=' ' read -r saved_profile saved_firmware saved_router saved_boot saved_extra < "$journal/profile.identity" || fail JOURNAL_PROFILE
        test -z "$saved_extra" || fail JOURNAL_PROFILE
        select_profile "$saved_profile" "$saved_firmware" "$saved_router" "$saved_boot"
    fi
    if test "$profile" = linux-arm64-access; then
        test "$#" = 7 && test "$7" = "$boot_id" || fail JOURNAL_BOOT_MISMATCH
        discovery_startup /data/local/tmp/start_zte_agent.sh
    fi
    if test "$#" = 6 || test "$#" = 7; then
        test "$4:$5:$6" = "$profile:$firmware_sha:$router_sha" || fail JOURNAL_PROFILE_MISMATCH
    fi
    identity "$3"
    test "$(cat "$journal/cid")" = "$3" || fail JOURNAL_CID
    state=$(cat "$journal/state")
    case "$state" in ready|complete) ;; *) fail JOURNAL_STATE;; esac
    if test "$state" = ready; then test "$(cat "$base/active")" = "$token" || fail JOURNAL_OWNER; fi
    sha256sum -c "$journal/after.sha256" >/dev/null || fail DEPLOYMENT_CHANGED
    live_agent || fail AGENT_NOT_RUNNING
    if test "$state" = complete; then
        printf 'INSTALL_COMMITTED %s\n' "$journal"
        exit 0
    fi
    printf '%s\n' complete > "$journal/state.new"
    mv "$journal/state.new" "$journal/state"
    sync
    rm "$base/active" "$base/lock/owner"
    rmdir "$base/lock"
    sync
    printf 'INSTALL_COMMITTED %s\n' "$journal"
    exit 0
fi

test "$#" = 5 || test "$#" = 8 || test "$#" = 9 || fail ARGUMENTS
stage=$1; cid=$2; agent_sha=$3; dropbear_sha=$4; public_sha=$5
explicit_profile=0
if test "$#" = 8 || test "$#" = 9; then select_profile "$6" "$7" "$8" "${9:-}"; explicit_profile=1; fi
case "$stage" in /data/local/tmp/zte-imei-setup-*) ;; *) fail STAGE_PATH;; esac
token=${stage#/data/local/tmp/zte-imei-setup-}; safe_id "$token" || fail STAGE_ID
for value in "$agent_sha" "$dropbear_sha" "$public_sha"; do
    hex "$value" && test "${#value}" = 64 || fail HASH_FORMAT
done
identity "$cid"
structural_preflight
for directory in /data /data/local /data/local/tmp /data/bin /data/dropbear /etc /etc/dropbear "$base" "$stage"; do
    test ! -L "$directory" || fail DIRECTORY_LINK
    if test -e "$directory"; then test -d "$directory" || fail DIRECTORY_TYPE; fi
done
test -d "$stage" || fail STAGE_MISSING
safe_directory "$stage"
if test "$explicit_profile" = 1; then
    plain_file "$stage/.owner" && test "$(stat -c %u:%a "$stage/.owner")" = 0:600 || fail STAGE_OWNER
    owner="$token $cid $profile $firmware_sha $router_sha"
    if test "$profile" = linux-arm64-access; then owner="$owner $boot_id"; fi
    test "$(cat "$stage/.owner")" = "$owner" || fail STAGE_OWNER
fi
for item in zte-agent dropbear id_ed25519.pub start-agent.sh start_zte_imei_studio.sh setup-agent.sh; do
    plain_file "$stage/$item" || fail STAGE_FILE
done
test "$(hash "$stage/zte-agent")" = "$agent_sha" || fail AGENT_HASH
test "$(hash "$stage/dropbear")" = "$dropbear_sha" || fail DROPBEAR_HASH
test "$(hash "$stage/id_ed25519.pub")" = "$public_sha" || fail PUBLIC_HASH
test "$(wc -l < "$stage/id_ed25519.pub" | tr -d ' ')" = 1 || fail PUBLIC_LINES
awk 'NF >= 2 && $1 == "ssh-ed25519" && $2 ~ /^[A-Za-z0-9+\/=]+$/ {ok=1} END {exit !ok}' "$stage/id_ed25519.pub" || fail PUBLIC_FORMAT
sh -n "$stage/start-agent.sh" || fail AGENT_SCRIPT_SYNTAX
sh -n "$stage/start_zte_imei_studio.sh" || fail STARTUP_SYNTAX
if test "$profile" = linux-arm64-access; then
    discovery_startup "$stage/start-agent.sh"
    for executable in zte-agent dropbear; do
        header=$(od -An -tx1 -N20 "$stage/$executable" | tr -d ' \n')
        case "$header" in 7f454c46020101??????????????????0200b700|7f454c46020101??????????????????0300b700) ;; *) fail PAYLOAD_ABI;; esac
    done
    timeout 5 "$stage/dropbear" -V >/dev/null 2>&1 || fail DROPBEAR_ABI
    # The pinned self-check verifies embedded resources and exits before any
    # server construction, configuration migration or device operation.
    ZTE_AGENT_MODE=normal timeout 5 "$stage/zte-agent" --esim-check >/dev/null 2>&1 || fail AGENT_ABI
fi
plain_file /etc/rc.local || fail RC_LOCAL_TYPE
sh -n /etc/rc.local || fail RC_LOCAL_SYNTAX
test ! -e "$base/active" && test ! -e "$base/lock" || fail RECOVERY_PENDING
test ! -e "$base/$token" || fail JOURNAL_ALREADY_EXISTS
test ! -e /data/local/tmp/open-u60-transactions/active || fail OTHER_RECOVERY_PENDING

targets='data/zte-agent
data/bin/dropbear
data/bin/dropbearkey
etc/dropbear/authorized_keys
etc/dropbear/dropbear_ed25519_host_key
etc/dropbear/dropbear_rsa_host_key
data/dropbear/authorized_keys
data/dropbear/dropbear_ed25519_host_key
data/dropbear/dropbear_rsa_host_key
data/local/tmp/start_zte_agent.sh
data/local/tmp/start_zte_imei_studio.sh
etc/rc.local'
for target in $targets; do
    if test -e "/$target" || test -L "/$target"; then
        plain_file "/$target" || fail EXISTING_FILE_TYPE
    fi
done
for executable in /data/zte-agent /data/bin/dropbear /data/bin/dropbearkey; do
    if test -e "$executable"; then test -x "$executable" || fail EXISTING_NOT_EXECUTABLE; fi
done
# A preserved helper must be the same pinned multi-call Dropbear we inspected.
# Do not execute unknown pre-existing helpers during a generic transaction.
if test "$profile" = linux-arm64-access; then
    for executable in /data/bin/dropbear /data/bin/dropbearkey; do
        if test -e "$executable"; then
            test "$(hash "$executable")" = "$dropbear_sha" || fail EXISTING_DROPBEAR_REVIEW_REQUIRED
        fi
    done
fi
# Never replace a previous agent or its credentials. An orphaned installation
# must be repaired explicitly instead of silently assigning a new password.
if test -e /data/zte-agent; then
    plain_file /data/local/tmp/start_zte_agent.sh || fail EXISTING_AGENT_STARTUP_MISSING
    sh -n /data/local/tmp/start_zte_agent.sh || fail EXISTING_AGENT_STARTUP_SYNTAX
    if test "$profile" = linux-arm64-access; then
        discovery_startup /data/local/tmp/start_zte_agent.sh
        test "$(hash /data/zte-agent)" = "$agent_sha" || fail EXISTING_AGENT_REVIEW_REQUIRED
        if pidof zte-agent >/dev/null 2>&1; then live_agent || fail EXISTING_AGENT_REVIEW_REQUIRED; fi
    fi
elif test -e /data/local/tmp/start_zte_agent.sh; then
    fail ORPHAN_AGENT_STARTUP
fi
data_free=$(df -Pk /data | awk 'END {print $4}')
etc_free=$(df -Pk /etc | awk 'END {print $4}')
test "$data_free" -ge 16384 && test "$etc_free" -ge 2048 || fail INSUFFICIENT_SPACE

# Recheck measured identity immediately before the first persistent mutation.
identity "$cid"
structural_preflight
mkdir -p "$base"
mkdir "$base/lock" || fail RECOVERY_LOCK
printf '%s\n' "$token" > "$base/lock/owner"
journal=$base/$token
mkdir "$journal" "$journal/before" "$journal/present"
printf '%s\n' "$cid" > "$journal/cid"
if test "$profile" = linux-arm64-access; then
    printf '%s %s %s %s\n' "$profile" "$firmware_sha" "$router_sha" "$boot_id" > "$journal/profile.identity"
else
    printf '%s %s %s\n' "$profile" "$firmware_sha" "$router_sha" > "$journal/profile.identity"
fi
printf '%s\n' preparing > "$journal/state"
trap 'code=$?; if test "$code" != 0; then printf "INSTALL_INCOMPLETE %s\n" "$journal" >&2; fi' EXIT
trap 'exit 130' HUP INT TERM
for target in $targets; do
    name=$(printf '%s' "$target" | tr / _)
    if test -e "/$target"; then
        cp -p "/$target" "$journal/before/$name"
        test "$(hash "/$target")" = "$(hash "$journal/before/$name")" || fail SNAPSHOT_MISMATCH
        : > "$journal/present/$name"
    fi
done
printf '%s\n' "$targets" > "$journal/targets"
sync
printf '%s\n' pending > "$journal/state"
printf '%s\n' "$token" > "$base/active.new"
mv "$base/active.new" "$base/active"
sync
printf 'INSTALL_SNAPSHOT %s\n' "$journal"

atomic_copy() {
    source=$1; destination=$2; mode=$3
    temporary=$destination.zte-imei-$token
    (set -C; : > "$temporary") || fail STAGING_COLLISION
    cp -p "$source" "$temporary"
    test "$(hash "$source")" = "$(hash "$temporary")" || fail STAGING_HASH
    if test "$mode" != preserve; then chmod "$mode" "$temporary"; fi
    case "$destination" in *.sh|/etc/rc.local) sh -n "$temporary" || fail STAGING_SYNTAX;; esac
    mv "$temporary" "$destination"
}
for directory in /data/bin /data/dropbear /etc/dropbear; do
    if test ! -d "$directory"; then mkdir -m 700 "$directory"; fi
done
if test ! -e /data/zte-agent; then
    atomic_copy "$stage/zte-agent" /data/zte-agent 700
    atomic_copy "$stage/start-agent.sh" /data/local/tmp/start_zte_agent.sh 700
    printf '%s\n' 'INSTALL_AGENT new'
else
    printf '%s\n' 'INSTALL_AGENT preserved'
fi
if test ! -e /data/bin/dropbear; then atomic_copy "$stage/dropbear" /data/bin/dropbear 700; fi
if test ! -e /data/bin/dropbearkey; then atomic_copy "$stage/dropbear" /data/bin/dropbearkey 700; fi

authorized=$journal/authorized_keys.new
if test -e /etc/dropbear/authorized_keys; then cat /etc/dropbear/authorized_keys > "$authorized"; else : > "$authorized"; fi
public=$(cat "$stage/id_ed25519.pub")
if ! grep -qFx "$public" "$authorized"; then
    printf '\n%s\n' "$public" >> "$authorized"
fi
atomic_copy "$authorized" /etc/dropbear/authorized_keys 600
for kind in ed25519 rsa; do
    destination=/etc/dropbear/dropbear_${kind}_host_key
    if test ! -e "$destination"; then
        temporary=$journal/dropbear_${kind}_host_key.new
        /data/bin/dropbearkey -t "$kind" -f "$temporary" >/dev/null 2>&1 || fail HOST_KEY_GENERATION
        atomic_copy "$temporary" "$destination" 600
    fi
    /data/bin/dropbearkey -y -f "$destination" >/dev/null 2>&1 || fail HOST_KEY_INVALID
done
for item in authorized_keys dropbear_ed25519_host_key dropbear_rsa_host_key; do
    atomic_copy "/etc/dropbear/$item" "/data/dropbear/$item" 600
done
atomic_copy "$stage/start_zte_imei_studio.sh" /data/local/tmp/start_zte_imei_studio.sh 700
entry='sh /data/local/tmp/start_zte_imei_studio.sh'
if ! grep -qFx "$entry" /etc/rc.local; then
    # Add before the first stock exit only. Preserve every existing line,
    # including the boot-time ADB switch, and never alter USB composition live.
    cp -p /etc/rc.local "$journal/rc.local.new"
    awk -v line="$entry" 'BEGIN {inserted=0} /^exit 0([ \t]|$)/ && !inserted {print line; inserted=1} {print} END {if (!inserted) print line}' /etc/rc.local > "$journal/rc.local.new"
    atomic_copy "$journal/rc.local.new" /etc/rc.local preserve
fi
sync
sh /data/local/tmp/start_zte_imei_studio.sh
tries=0
while ! live_agent; do
    tries=$((tries + 1)); test "$tries" -lt 10 || fail AGENT_NOT_RUNNING
    sleep 1
done
identity "$cid"
: > "$journal/after.sha256"
for target in $targets; do sha256sum "/$target" >> "$journal/after.sha256"; done
sha256sum "$journal/cid" "$journal/profile.identity" >> "$journal/after.sha256"
sync
printf '%s\n' ready > "$journal/state.new"
mv "$journal/state.new" "$journal/state"
sync
printf 'INSTALL_AGENT_SHA256 %s\n' "$(hash /data/zte-agent)"
printf 'INSTALL_DROPBEAR_SHA256 %s\n' "$(hash /data/bin/dropbear)"
printf 'INSTALL_READY %s\n' "$journal"
