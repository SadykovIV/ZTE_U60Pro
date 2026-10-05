#!/bin/sh
# Transactional access installation after a fresh measured preflight. Specific
# hardware functions retain their own adapters; access never certifies NV/eSIM.
# No password is an argument, diagnostic, or journal field.
set -eu
umask 077
reinstall=0
if test "${1:-}" = --reinstall; then reinstall=1; shift; fi
anchor=/data/zte-imei-studio
base=$anchor/installations
expected_targets='data/zte-agent
data/zte-imei-studio/bin/dropbear
data/zte-imei-studio/bin/dropbearkey
etc/dropbear/authorized_keys
etc/dropbear/dropbear_ed25519_host_key
etc/dropbear/dropbear_rsa_host_key
data/zte-imei-studio/start_zte_agent.sh
data/zte-imei-studio/start_zte_imei_studio.sh
etc/rc.local'
firmware_sha=604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263
timeout_sha=6e81024c273080294a251ae38572f1ef0cb496fbd16c7009c6a4ae1c07fb55ff
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
private_directory() {
    safe_directory "$1"
    if test -e "$1"; then test "$(stat -c %a "$1")" = 700 || fail PRIVATE_DIRECTORY_MODE; fi
}
private_file() {
    plain_file "$1" && test "$(stat -c %u:%h "$1")" = 0:1 || return 1
    case "$(stat -c %a "$1")" in 600|700) ;; *) return 1;; esac
}
# Only our generated launcher grammar may migrate from a shared legacy path.
# This validator never evaluates or prints the shell-quoted secret.
agent_launcher_valid() {
    sh -n "$1" || return 1
    awk '
      /^[ \t]*$/ || /^#/ {next}
      {n++; if(n==1) {
        prefix="export ZTE_AGENT_PASSWORD="; if(index($0,prefix)!=1)exit 1;
        value=substr($0,length(prefix)+1); q=sprintf("%c",39); bs=sprintf("%c",92);
        if(length(value)<3 || substr(value,1,1)!=q || substr(value,length(value),1)!=q)exit 1;
        for(i=2;i<length(value);i++) if(substr(value,i,1)==q) {
          if(substr(value,i,4)!=q bs q q || i+3>=length(value))exit 1; i+=3;
        }
      } else if(n==2 && $0=="export ZTE_AGENT_MODE=" sprintf("%c",39) "discovery" sprintf("%c",39)) {discovery=1;next}
      else if(discovery && n==3) {
        prefix="export ZTE_AGENT_BIND=" sprintf("%c",39);
        if(index($0,prefix)!=1 || substr($0,length($0),1)!=sprintf("%c",39))exit 1;
        address=substr($0,length(prefix)+1,length($0)-length(prefix)-1);
        if(address !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:9090$/)exit 1;
        sub(/:9090$/,"",address); split(address,octets,".");
        for(i=1;i<=4;i++)if(octets[i]+0>255 || octets[i] != sprintf("%d",octets[i]+0))exit 1;
      } else {
        step=n-(discovery?2:0);
        if(step==2 && $0!="unset ZTE_AGENT_PIN")exit 1;
        else if(step==3 && $0!="trap " sprintf("%c%c",39,39) " HUP")exit 1;
        else if(step==4 && $0!="nohup sh -c " sprintf("%c",39) "/data/zte-agent 2>&1 | logger -t zte-agent" sprintf("%c",39) " >/dev/null 2>&1 </dev/null &")exit 1;
        else if(step>4)exit 1;
      }}
      END{if(n!=(discovery?6:4))exit 1}' "$1"
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
        for command in od; do command -v "$command" >/dev/null 2>&1 || fail MISSING_TOOL; done
        test "$(cat /proc/1/comm)" = procd || fail STARTUP_NOT_ASSESSED
        plain_file /etc/init.d/done && test -r /etc/init.d/done || fail STARTUP_NOT_ASSESSED
        grep -qE '^[[:space:]]*sh[[:space:]]+/etc/rc\.local([[:space:]]|$)' /etc/init.d/done || fail STARTUP_NOT_ASSESSED
    else
        command -v ubus >/dev/null 2>&1 || fail MISSING_TOOL
    fi
    for directory in /data /etc /etc/dropbear; do safe_directory "$directory"; done
    for directory in "$anchor" "$anchor/bin" "$base"; do private_directory "$directory"; done
    test -d /data && test -w /data && test -d /etc && test -w /etc || fail REQUIRED_DIRECTORY
    test -r /proc/self/mountinfo && test -r /proc/net/tcp || fail PROC_LAYOUT
    plain_file /usr/bin/curl && test -x /usr/bin/curl || fail CURL_REQUIRED
    test -d /var/run && test -w /var/run || fail RUNTIME_DIRECTORY
    mount_access "$anchor" 1; mount_access /etc/dropbear 0
    plain_file /etc/rc.local && test -w /etc/rc.local || fail RC_LOCAL_TYPE
    sh -n /etc/rc.local || fail RC_LOCAL_SYNTAX
    for pending in "$base/active" "$base/lock" /data/local/tmp/zte-imei-installations/active /data/local/tmp/zte-imei-installations/lock /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /tmp/zte-imei-app.lock; do
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

owned_agent_process() {
    expected_hash=$1
    processes=$(pidof zte-agent 2>/dev/null || true)
    set -- $processes
    test "$#" = 1 || return 1
    process=$1
    case "$process" in ''|*[!0-9]*) return 1;; esac
    test "$(readlink "/proc/$process/exe" 2>/dev/null)" = /data/zte-agent &&
    test "$(stat -L -c %u "/proc/$process/exe")" = 0 &&
    test "$(hash "/proc/$process/exe")" = "$expected_hash" || return 1
    started=$(sed 's/^[0-9][0-9]* (.*) //' "/proc/$process/stat" | awk '{print $20}') || return 1
    case "$started" in ''|*[!0-9]*) return 1;; esac
    printf '%s:%s\n' "$process" "$started"
}
stop_owned_agent() {
    stop_hash=$1; stop_proof=$2
    test "$(owned_agent_process "$stop_hash")" = "$stop_proof" || return 1
    process=${stop_proof%%:*}
    kill -TERM "$process" || return 1
    attempt=0
    while pidof zte-agent >/dev/null 2>&1; do
        test "$(owned_agent_process "$stop_hash")" = "$stop_proof" || return 1
        attempt=$((attempt+1))
        if test "$attempt" = 5; then kill -KILL "$process" || return 1; fi
        test "$attempt" -lt 8 || return 1
        sleep 1
    done
}
# A running pinned SSH listener is reused in place: never replace its inode or
# stop Dropbear. Stock port 22 and unrelated listeners are outside this action.
force_ssh_listener() {
    tables=/proc/net/tcp
    if test -r /proc/net/tcp6; then tables="$tables /proc/net/tcp6"; fi
    inodes=$(awk '$2 ~ /:08AE$/ && $4 == "0A" {if($10 !~ /^[0-9]+$/ || $10==0)exit 1;if(!seen[$10]++)print $10}' $tables) || return 1
    for inode in $inodes; do
        found=0
        for process in $(pidof dropbear 2>/dev/null || true); do
            case "$process" in ''|*[!0-9]*) continue;; esac
            test "$(readlink "/proc/$process/exe" 2>/dev/null || true)" = "$anchor/bin/dropbear" || continue
            private_file "$anchor/bin/dropbear" && test "$(hash "$anchor/bin/dropbear")" = "$dropbear_sha" &&
            test "$(stat -L -c %u "/proc/$process/exe")" = 0 && test "$(hash "/proc/$process/exe")" = "$dropbear_sha" || return 1
            for descriptor in /proc/"$process"/fd/*; do
                if test "$(readlink "$descriptor" 2>/dev/null || true)" = "socket:[$inode]"; then found=1; break; fi
            done
            test "$found" = 0 || break
        done
        test "$found" = 1 || return 1
    done
}
rollback_verified() {
    test "$(cat "$journal/mode")" = reinstall && test "$(cat "$journal/state")" = rolled-back || return 1
    test "$(cat "$journal/targets")" = "$expected_targets" || return 1
    sha256sum -c "$journal/before.sha256" >/dev/null 2>&1 || return 1
    while IFS= read -r target; do
        name=$(printf '%s' "$target" | tr / _)
        if test -f "$journal/present/$name"; then
            plain_file "/$target" && test "$(stat -c %u:%h "/$target")" = 0:1 || return 1
            test "$(hash "/$target")" = "$(hash "$journal/before/$name")" &&
            test "$(stat -c %a "/$target")" = "$(stat -c %a "$journal/before/$name")" || return 1
        else
            test ! -e "/$target" && test ! -L "/$target" || return 1
        fi
    done < "$journal/targets"
    test ! -e "$base/active" && test ! -L "$base/active" && test ! -e "$base/lock" && test ! -L "$base/lock" || return 1
    saved_running=$(cat "$journal/agent-was-running") || return 1
    case "$saved_running" in yes|no) ;; *) return 1;; esac
    if test "$saved_running" = yes; then
        owned_agent_process "$(hash "$journal/before/data_zte-agent")" >/dev/null || return 1
    else
        ! pidof zte-agent >/dev/null 2>&1 || return 1
    fi
}
deployment_manifest_valid() {
    private_file "$journal/after.sha256" || return 1
    manifest_paths=$(for target in $expected_targets; do printf '%s|' "/$target"; done; printf '%s|%s' "$journal/cid" "$journal/profile.identity")
    awk -v expected="$manifest_paths" '
      BEGIN {n=split(expected,a,"[|]");for(i=1;i<=n;i++)want[a[i]]=1}
      NF!=2 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || !($2 in want) || seen[$2]++ {bad=1}
      END {if(NR!=n)bad=1;exit bad}' "$journal/after.sha256" || return 1
    sha256sum -c "$journal/after.sha256" >/dev/null 2>&1
}
release_completed_owner() {
    # Completion may have been persisted just before the old process exited.
    # Never clear a lock belonging to another transaction or lacking its owner.
    if test -e "$base/active" || test -L "$base/active"; then
        private_file "$base/active" && test "$(cat "$base/active")" = "$token" || return 1
    fi
    if test -e "$journal/completed-lock" || test -L "$journal/completed-lock"; then
        test -d "$journal/completed-lock" && test ! -L "$journal/completed-lock" &&
        test "$(stat -c %u:%a "$journal/completed-lock")" = 0:700 &&
        private_file "$journal/completed-lock/owner" && test "$(cat "$journal/completed-lock/owner")" = "$token" || return 1
    fi
    if test -e "$base/lock" || test -L "$base/lock"; then
        test -d "$base/lock" && test ! -L "$base/lock" && test "$(stat -c %u:%a "$base/lock")" = 0:700 &&
        private_file "$base/lock/owner" && test "$(cat "$base/lock/owner")" = "$token" || return 1
        # Move the owned lock into its journal before deleting its marker: no
        # ownerless lock is exposed at the common path if cleanup is interrupted.
        test ! -e "$journal/completed-lock" && test ! -L "$journal/completed-lock" || return 1
        mv "$base/lock" "$journal/completed-lock" || return 1
    fi
    if test -e "$base/active"; then rm "$base/active" || return 1; fi
    if test -e "$journal/completed-lock"; then
        private_file "$journal/completed-lock/owner" && test "$(cat "$journal/completed-lock/owner")" = "$token" || return 1
        rm "$journal/completed-lock/owner" && rmdir "$journal/completed-lock" || return 1
    fi
    sync
}
reconcile_completed_owner() {
    test -e "$base/active" || test -L "$base/active" || test -e "$base/lock" || test -L "$base/lock" || return 0
    private_directory "$anchor"; private_directory "$base"
    if test -e "$base/active"; then
        private_file "$base/active" || return 1; token=$(cat "$base/active")
    else
        private_file "$base/lock/owner" || return 1; token=$(cat "$base/lock/owner")
    fi
    safe_id "$token" || return 1
    journal=$base/$token; private_directory "$journal"
    for item in state cid profile.identity; do private_file "$journal/$item" || return 1; done
    test "$(cat "$journal/state")" = complete && test "$(cat "$journal/cid")" = "$cid" || return 1
    expected_profile="$profile $firmware_sha $router_sha"
    if test "$profile" = linux-arm64-access; then expected_profile="$expected_profile $boot_id"; fi
    test "$(cat "$journal/profile.identity")" = "$expected_profile" && deployment_manifest_valid || return 1
    if pidof zte-agent >/dev/null 2>&1; then owned_agent_process "$(hash /data/zte-agent)" >/dev/null || return 1; fi
    release_completed_owner || return 1
    printf 'INSTALL_COMPLETED_OWNER_CLEARED\n' >&2
}
cleanup_old_stage() (
    candidate=$1
    cleanup_rollback=${2:-0}
    if test "$candidate" = "$anchor/stage-$token"; then
        test "$cleanup_rollback" = 1 && rollback_verified || exit 1
    fi
    case "$candidate" in
      "$anchor"/stage-*) old_token=${candidate#"$anchor"/stage-}; old_base=$base; private_directory "$anchor";;
      /data/local/tmp/zte-imei-setup-*) old_token=${candidate#/data/local/tmp/zte-imei-setup-}; old_base=/data/local/tmp/zte-imei-installations
        for parent in /data/local /data/local/tmp; do safe_directory "$parent"; done;;
      *) exit 1;;
    esac
    safe_id "$old_token" || exit 1
    test "$old_token" != "$token" || test "$cleanup_rollback" = 1 || exit 1
    test -d "$candidate" && test ! -L "$candidate" && test "$(stat -c %u:%a "$candidate")" = 0:700 || exit 1
    private_file "$candidate/.owner" || exit 1
    IFS=' ' read -r saved_token saved_cid saved_profile saved_fw saved_router saved_boot extra < "$candidate/.owner" || exit 1
    test -z "$extra" && test "$saved_token" = "$old_token" && test "$saved_cid" = "$cid" || exit 1
    case "$saved_profile" in b31|b02-experimental) test -z "$saved_boot" || exit 1;; linux-arm64-access) test -n "$saved_boot" || exit 1;; *) exit 1;; esac
    owner_text="$saved_token $saved_cid $saved_profile $saved_fw $saved_router"
    if test -n "$saved_boot"; then owner_text="$owner_text $saved_boot"; fi
    test "$(stat -c %s "$candidate/.owner")" = "$((${#owner_text}+1))" && test "$(cat "$candidate/.owner")" = "$owner_text" || exit 1
    for marker in "$base/active" /data/local/tmp/zte-imei-installations/active; do
        if test -e "$marker" || test -L "$marker"; then private_file "$marker" && test "$(cat "$marker")" != "$old_token" || exit 1; fi
    done
    old_journal=$old_base/$old_token
    if test -e "$candidate/.install-requested" || test -L "$candidate/.install-requested"; then
        private_file "$candidate/.install-requested" && test "$(cat "$candidate/.install-requested")" = "$owner_text" || exit 1
        private_directory "$old_base"; private_directory "$old_journal"
        private_file "$old_journal/cid" && test "$(cat "$old_journal/cid")" = "$cid" &&
        private_file "$old_journal/state" || exit 1
        saved_state=$(cat "$old_journal/state")
        test "$saved_state" = complete || { test "$cleanup_rollback" = 1 && test "$old_journal" = "$journal" && test "$saved_state" = rolled-back; } || exit 1
    else
        # A matching owner without dispatch proof can still be another client's
        # active upload. No age heuristic can establish that it is abandoned.
        exit 1
    fi
    # Validate the whole directory before deleting the first exact known file.
    for file in "$candidate"/* "$candidate"/.[!.]* "$candidate"/..?*; do
        test -e "$file" || test -L "$file" || continue
        case "${file##*/}" in
          zte-agent|dropbear|setup-agent.sh|start_zte_imei_studio.sh|id_ed25519.pub|start-agent.sh|zte-timeout|legacy-agent.private.sh|.owner|.install-requested) ;;
          incoming-*)
            test "$saved_state" = complete || exit 1
            printf '%s\n' "${file##*/}" | grep -qE '^incoming-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || exit 1;;
          *) exit 1;;
        esac
        private_file "$file" || exit 1
    done
    test "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" || exit 1
    for file in "$candidate"/* "$candidate"/.[!.]* "$candidate"/..?*; do
        test -e "$file" || test -L "$file" || continue
        rm "$file" || exit 1
    done
    rmdir "$candidate"
)
cleanup_old_stages() {
    removed=0; retained=0
    for candidate in "$anchor"/stage-* /data/local/tmp/zte-imei-setup-*; do
        test -e "$candidate" || test -L "$candidate" || continue
        test "$candidate" != "$anchor/stage-$token" || continue
        if cleanup_old_stage "$candidate" >/dev/null 2>&1; then removed=$((removed+1)); else retained=$((retained+1)); fi
    done
    printf 'INSTALL_CLEANUP removed=%s retained=%s\n' "$removed" "$retained"
}

if test "${1:-}" = --verify-rollback; then
    test "$reinstall" = 0 && { test "$#" = 6 || test "$#" = 7; } || fail ARGUMENTS
    journal=$2; cid=$3
    case "$journal" in "$base/"*) ;; *) fail JOURNAL_PATH;; esac
    token=${journal#"$base/"}; safe_id "$token" || fail JOURNAL_ID
    select_profile "$4" "$5" "$6" "${7:-}"
    identity "$cid"
    safe_directory /data
    for directory in "$anchor" "$base" "$journal" "$journal/before" "$journal/present"; do private_directory "$directory"; done
    for item in mode state cid profile.identity before.sha256 targets agent-was-running; do private_file "$journal/$item" || fail ROLLBACK_METADATA; done
    test "$(cat "$journal/cid")" = "$cid" || fail JOURNAL_CID
    expected_profile="$profile $firmware_sha $router_sha"
    if test "$profile" = linux-arm64-access; then expected_profile="$expected_profile $boot_id"; fi
    test "$(cat "$journal/profile.identity")" = "$expected_profile" || fail JOURNAL_PROFILE_MISMATCH
    rollback_verified || fail ROLLBACK_UNVERIFIED
    identity "$cid"
    printf 'INSTALL_ROLLBACK_VERIFIED %s\n' "$journal"
    exit 0
fi

if test "${1:-}" = --preflight; then
    test "$#" = 5 || test "$#" = 6 || fail ARGUMENTS
    select_profile "$3" "$4" "$5" "${6:-}"
    identity "$2"
    if test "$reinstall" = 1; then cid=$2; reconcile_completed_owner || fail RECOVERY_PENDING; fi
    structural_preflight
    # /config is a DIAG/EFS object, not the Linux /config path. Firmware/router
    # matches do not establish NV/EFS compatibility; strict runtime reads do.
    printf 'INSTALL_PREFLIGHT %s imei_config=unknown\n' "$profile"
    exit 0
fi

if test "${1:-}" = --commit; then
    test "$reinstall" = 0 || fail ARGUMENTS
    test "$#" = 3 || test "$#" = 6 || test "$#" = 7 || fail ARGUMENTS
    journal=$2; cid=$3
    case "$journal" in "$base/"*) ;; *) fail JOURNAL_PATH;; esac
    token=${journal#"$base/"}; safe_id "$token" || fail JOURNAL_ID
    safe_directory /data
    for directory in "$anchor" "$base" "$journal"; do private_directory "$directory"; done
    if test -e "$journal/profile.identity" || test -L "$journal/profile.identity"; then
        plain_file "$journal/profile.identity" && test "$(stat -c %u:%a "$journal/profile.identity")" = 0:600 || fail JOURNAL_PROFILE
        test "$(wc -l < "$journal/profile.identity" | tr -d ' ')" = 1 || fail JOURNAL_PROFILE
        IFS=' ' read -r saved_profile saved_firmware saved_router saved_boot saved_extra < "$journal/profile.identity" || fail JOURNAL_PROFILE
        test -z "$saved_extra" || fail JOURNAL_PROFILE
        select_profile "$saved_profile" "$saved_firmware" "$saved_router" "$saved_boot"
    fi
    if test "$profile" = linux-arm64-access; then
        test "$#" = 7 && test "$7" = "$boot_id" || fail JOURNAL_BOOT_MISMATCH
        discovery_startup /data/zte-imei-studio/start_zte_agent.sh
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
        deployment_manifest_valid && release_completed_owner || fail JOURNAL_OWNER
        if private_file "$journal/mode" && test "$(cat "$journal/mode")" = reinstall; then cleanup_old_stages; fi
        printf 'INSTALL_COMMITTED %s\n' "$journal"
        exit 0
    fi
    printf '%s\n' complete > "$journal/state.new"
    mv "$journal/state.new" "$journal/state"
    sync
    release_completed_owner || fail JOURNAL_OWNER
    if private_file "$journal/mode" && test "$(cat "$journal/mode")" = reinstall; then cleanup_old_stages; fi
    printf 'INSTALL_COMMITTED %s\n' "$journal"
    exit 0
fi

test "$#" = 5 || test "$#" = 8 || test "$#" = 9 || fail ARGUMENTS
stage=$1; cid=$2; agent_sha=$3; dropbear_sha=$4; public_sha=$5
explicit_profile=0
if test "$#" = 8 || test "$#" = 9; then select_profile "$6" "$7" "$8" "${9:-}"; explicit_profile=1; fi
case "$stage" in "$anchor"/stage-*) ;; *) fail STAGE_PATH;; esac
token=${stage#"$anchor"/stage-}; safe_id "$token" || fail STAGE_ID
for value in "$agent_sha" "$dropbear_sha" "$public_sha"; do
    hex "$value" && test "${#value}" = 64 || fail HASH_FORMAT
done
identity "$cid"
structural_preflight
test -d "$stage" || fail STAGE_MISSING
private_directory "$stage"
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
    # The host verifies and stages this pinned static ARM64 supervisor. Reduced
    # firmware does not need a native timeout applet; the deadline remains 5s.
    plain_file "$stage/zte-timeout" && test "$(stat -c %u:%h "$stage/zte-timeout")" = 0:1 || fail TIMEOUT_TYPE
    test "$(hash "$stage/zte-timeout")" = "$timeout_sha" || fail TIMEOUT_HASH
    for executable in zte-timeout zte-agent dropbear; do
        plain_file "$stage/$executable" && test "$(stat -c %u:%h "$stage/$executable")" = 0:1 || fail PAYLOAD_TYPE
        header=$(od -An -tx1 -N20 "$stage/$executable" | tr -d ' \n')
        case "$header" in 7f454c46020101??????????????????0200b700|7f454c46020101??????????????????0300b700) ;; *) fail PAYLOAD_ABI;; esac
    done
    # ADB staging deliberately transfers private non-executable files. Only
    # these verified, singly-linked payloads may gain execution permission.
    for executable in zte-timeout zte-agent dropbear; do
        chmod 700 "$stage/$executable" || fail PAYLOAD_MODE
    done
    "$stage/zte-timeout" 5 "$stage/dropbear" -V >/dev/null 2>&1 || fail DROPBEAR_ABI
    # The pinned self-check verifies embedded resources and exits before any
    # server construction, configuration migration or device operation.
    ZTE_AGENT_MODE=normal "$stage/zte-timeout" 5 "$stage/zte-agent" --esim-check >/dev/null 2>&1 || fail AGENT_ABI
fi
plain_file /etc/rc.local || fail RC_LOCAL_TYPE
sh -n /etc/rc.local || fail RC_LOCAL_SYNTAX
test ! -e "$base/active" && test ! -e "$base/lock" || fail RECOVERY_PENDING
test ! -e "$base/$token" || fail JOURNAL_ALREADY_EXISTS
test ! -e /data/local/tmp/open-u60-transactions/active || fail OTHER_RECOVERY_PENDING

targets=$expected_targets
for target in $targets; do
    if test -e "/$target" || test -L "/$target"; then
        plain_file "/$target" || fail EXISTING_FILE_TYPE
    fi
done
for executable in /data/zte-agent /data/zte-imei-studio/bin/dropbear /data/zte-imei-studio/bin/dropbearkey; do
    if test -e "$executable"; then test -x "$executable" || fail EXISTING_NOT_EXECUTABLE; fi
done
# A preserved helper must be the same pinned multi-call Dropbear we inspected.
# Do not execute unknown pre-existing helpers during a generic transaction.
if test "$profile" = linux-arm64-access || test "$reinstall" = 1; then
    for executable in /data/zte-imei-studio/bin/dropbear /data/zte-imei-studio/bin/dropbearkey; do
        if test -e "$executable"; then
            test "$(hash "$executable")" = "$dropbear_sha" || fail EXISTING_DROPBEAR_REVIEW_REQUIRED
        fi
    done
fi
# Preserve an existing private launcher. Legacy launchers are read through a
# pinned descriptor, validated as data, and copied to the protected stage before
# execution. Shared legacy directories are never chmodded or used for writes.
startup_source=
replace_orphan_agent=0
replace_existing_agent=0
agent_was_running=no
agent_process=
original_agent_sha=
if test -e /data/zte-agent || test -L /data/zte-agent; then
    plain_file /data/zte-agent && test "$(stat -c %u:%h /data/zte-agent)" = 0:1 && test -x /data/zte-agent || fail EXISTING_AGENT_TYPE
    agent_mode=$(stat -c %a /data/zte-agent)
    case "$agent_mode" in ''|*[!0-7]*) fail EXISTING_AGENT_TYPE;; esac
    test "$((0$agent_mode & 022))" = 0 || fail EXISTING_AGENT_TYPE
    original_agent_sha=$(hash /data/zte-agent)
    if pidof zte-agent >/dev/null 2>&1; then
        agent_was_running=yes
        if test "$reinstall" = 1; then
            agent_process=$(owned_agent_process "$original_agent_sha") || fail EXISTING_AGENT_PROCESS
        fi
    fi
    if test -e "$anchor/start_zte_agent.sh" || test -L "$anchor/start_zte_agent.sh"; then
        private_file "$anchor/start_zte_agent.sh" || fail EXISTING_AGENT_STARTUP_TYPE
        startup_source=$anchor/start_zte_agent.sh
        sh -n "$startup_source" || fail EXISTING_AGENT_STARTUP_SYNTAX
    elif test -e /data/local/tmp/start_zte_agent.sh || test -L /data/local/tmp/start_zte_agent.sh; then
        legacy=/data/local/tmp/start_zte_agent.sh
        for directory in /data/local /data/local/tmp; do
            test -d "$directory" && test ! -L "$directory" && test "$(stat -c %u "$directory")" = 0 || fail LEGACY_STARTUP_PARENT
        done
        private_file "$legacy" || fail EXISTING_AGENT_STARTUP_TYPE
        exec 9< "$legacy" || fail LEGACY_STARTUP_READ
        metadata=$(stat -c %d:%i:%u:%a:%h "$legacy")
        test "$(stat -L -c %d:%i:%u:%a:%h /proc/self/fd/9)" = "$metadata" || fail LEGACY_STARTUP_CHANGED
        startup_source=$stage/legacy-agent.private.sh
        (set -C; : > "$startup_source") || fail LEGACY_STARTUP_COLLISION
        cat <&9 > "$startup_source" || fail LEGACY_STARTUP_READ
        test "$(stat -L -c %d:%i:%u:%a:%h /proc/self/fd/9)" = "$metadata" &&
        private_file "$legacy" && test "$(stat -c %d:%i:%u:%a:%h "$legacy")" = "$metadata" || fail LEGACY_STARTUP_CHANGED
        exec 9<&-
        agent_launcher_valid "$startup_source" || fail LEGACY_STARTUP_GRAMMAR
    else
        # A reset may leave only an inactive binary. Snapshot it before replacing
        # it with the verified payload and a newly supplied launcher. Never run
        # an unknown orphan binary or replace credentials of a running process.
        ! pidof zte-agent >/dev/null 2>&1 || fail EXISTING_AGENT_STARTUP_MISSING
        startup_source=$stage/start-agent.sh
        replace_orphan_agent=1
    fi
    # Host verification requires the staged release after preparation. Preserve
    # existing credentials, but never start an older inactive binary merely
    # because its launcher survived a reset. A running older agent must use the
    # separately verified update/reuse flow; preparation does not stop it.
    if test "$(hash /data/zte-agent)" != "$agent_sha"; then
        if test "$reinstall" = 0; then ! pidof zte-agent >/dev/null 2>&1 || fail EXISTING_AGENT_RUNNING_REQUIRES_UPDATE; fi
        replace_existing_agent=1
    fi
    if test "$profile" = linux-arm64-access && test "$reinstall" = 0; then
        discovery_startup "$startup_source"
        if test "$replace_orphan_agent" = 0 && test "$replace_existing_agent" = 0; then
            test "$(hash /data/zte-agent)" = "$agent_sha" || fail EXISTING_AGENT_REVIEW_REQUIRED
        fi
        if pidof zte-agent >/dev/null 2>&1; then live_agent || fail EXISTING_AGENT_REVIEW_REQUIRED; fi
    fi
elif test -e "$anchor/start_zte_agent.sh" || test -L "$anchor/start_zte_agent.sh" ||
     test -e /data/local/tmp/start_zte_agent.sh || test -L /data/local/tmp/start_zte_agent.sh; then
    fail ORPHAN_AGENT_STARTUP
fi
if test "$reinstall" = 1; then force_ssh_listener || fail EXISTING_SSH_2222_UNVERIFIED; fi
data_free=$(df -Pk /data | awk 'END {print $4}')
etc_free=$(df -Pk /etc | awk 'END {print $4}')
test "$data_free" -ge 16384 && test "$etc_free" -ge 2048 || fail INSUFFICIENT_SPACE

# Recheck measured identity immediately before the first persistent mutation.
identity "$cid"
structural_preflight
if test ! -d "$base"; then mkdir -m 700 "$base"; fi
private_directory "$base"
mkdir "$base/lock" || fail RECOVERY_LOCK
printf '%s\n' "$token" > "$base/lock/owner"
journal=$base/$token
mkdir "$journal" "$journal/before" "$journal/present"
printf '%s\n' "$cid" > "$journal/cid"
if test "$reinstall" = 1; then
    printf '%s\n' reinstall > "$journal/mode"
    printf '%s\n' "$agent_was_running" > "$journal/agent-was-running"
fi
if test "$profile" = linux-arm64-access; then
    printf '%s %s %s %s\n' "$profile" "$firmware_sha" "$router_sha" "$boot_id" > "$journal/profile.identity"
else
    printf '%s %s %s\n' "$profile" "$firmware_sha" "$router_sha" > "$journal/profile.identity"
fi
printf '%s\n' preparing > "$journal/state"
trap 'code=$?; if test "$code" != 0; then printf "INSTALL_INCOMPLETE %s\n" "$journal" >&2; fi' EXIT
trap 'exit 130' HUP INT TERM
: > "$journal/before.sha256"
for target in $targets; do
    name=$(printf '%s' "$target" | tr / _)
    if test -e "/$target"; then
        cp -p "/$target" "$journal/before/$name"
        test "$(hash "/$target")" = "$(hash "$journal/before/$name")" || fail SNAPSHOT_MISMATCH
        sha256sum "$journal/before/$name" >> "$journal/before.sha256"
        : > "$journal/present/$name"
    fi
done
printf '%s\n' "$targets" > "$journal/targets"
if test "$reinstall" = 1; then
    mkdir "$journal/planned"
    if test -n "$startup_source"; then
        cp -p "$startup_source" "$journal/startup.before.sh"
        test "$(hash "$startup_source")" = "$(hash "$journal/startup.before.sh")" || fail SNAPSHOT_MISMATCH
    fi
fi
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
    if test "$reinstall" = 1; then
        planned_name=
        for target in $targets; do
            if test "$destination" = "/$target"; then planned_name=$(printf '%s' "$target" | tr / _); break; fi
        done
        test -n "$planned_name" || fail STAGING_TARGET
        hash "$temporary" > "$journal/planned/$planned_name"
        sync
    fi
    mv "$temporary" "$destination"
}
force_restore() {
    # Check every target before touching any of them. Foreign changes are never
    # overwritten merely because an earlier snapshot exists.
    test "$(cat "$base/active")" = "$token" && test "$(cat "$base/lock/owner")" = "$token" || return 1
    sha256sum -c "$journal/before.sha256" >/dev/null 2>&1 || return 1
    for target in $targets; do
        name=$(printf '%s' "$target" | tr / _)
        if test -e "/$target" || test -L "/$target"; then
            plain_file "/$target" && test "$(stat -c %u:%h "/$target")" = 0:1 || return 1
            current=$(hash "/$target") || return 1
            before=; planned=
            if test -f "$journal/present/$name"; then before=$(hash "$journal/before/$name") || return 1; fi
            if test -f "$journal/planned/$name"; then planned=$(cat "$journal/planned/$name"); fi
            test "$current" = "$before" || test "$current" = "$planned" || return 1
            # Do not remove or replace a live SSH executable on rollback. If a
            # fresh listener was created during this failed transaction, retain
            # the journal for recovery rather than cutting the control channel.
            if test "$target" = data/zte-imei-studio/bin/dropbear && test "$current" != "$before"; then
                for process in $(pidof dropbear 2>/dev/null || true); do
                    test "$(readlink "/proc/$process/exe" 2>/dev/null || true)" != "$anchor/bin/dropbear" || return 1
                done
            fi
        elif test -f "$journal/present/$name"; then return 1
        fi
    done
    if pidof zte-agent >/dev/null 2>&1; then
        current_agent=$(hash /data/zte-agent) || return 1
        case "$current_agent" in "$original_agent_sha"|"$agent_sha") ;; *) return 1;; esac
        current_process=$(owned_agent_process "$current_agent") || return 1
        stop_owned_agent "$current_agent" "$current_process" || return 1
    fi
    for target in $targets; do
        name=$(printf '%s' "$target" | tr / _)
        if test -f "$journal/present/$name"; then
            if test "$(hash "/$target")" = "$(hash "$journal/before/$name")" &&
               test "$(stat -c %a "/$target")" = "$(stat -c %a "$journal/before/$name")"; then continue; fi
            restore_temporary=/$target.zte-rollback-$token
            test ! -e "$restore_temporary" && test ! -L "$restore_temporary" || return 1
            (set -C; : > "$restore_temporary") || return 1
            cp -p "$journal/before/$name" "$restore_temporary" || return 1
            test "$(hash "$restore_temporary")" = "$(hash "$journal/before/$name")" || return 1
            mv "$restore_temporary" "/$target" || return 1
        elif test -e "/$target"; then rm "/$target" || return 1
        fi
    done
    if test "$agent_was_running" = yes; then
        sh "$journal/startup.before.sh" >/dev/null 2>&1 || return 1
        attempt=0
        while ! owned_agent_process "$original_agent_sha" >/dev/null; do
            attempt=$((attempt+1)); test "$attempt" -lt 10 || return 1; sleep 1
        done
    fi
    printf '%s\n' rolled-back > "$journal/state.new" && mv "$journal/state.new" "$journal/state" || return 1
    rm "$base/active" "$base/lock/owner" && rmdir "$base/lock" || return 1
    sync
    rollback_verified || return 1
    if cleanup_old_stage "$stage" 1 >/dev/null 2>&1; then printf 'INSTALL_CLEANUP removed=1 retained=0\n'
    else printf 'INSTALL_CLEANUP removed=0 retained=1\n'; fi
}
force_started=0
finish_install() {
    code=$?
    trap - EXIT HUP INT TERM
    if test "$code" != 0; then
        if test "$reinstall" = 1 && test "$force_started" = 1; then
            if (identity "$cid") && force_restore; then printf 'INSTALL_ROLLED_BACK %s\n' "$journal" >&2
            else printf 'INSTALL_ROLLBACK_UNKNOWN %s\n' "$journal" >&2; fi
        else printf 'INSTALL_INCOMPLETE %s\n' "$journal" >&2; fi
    fi
    exit "$code"
}
trap finish_install EXIT
if test "$reinstall" = 1; then
    if test -n "$original_agent_sha"; then
        test "$(hash /data/zte-agent)" = "$original_agent_sha" || fail EXISTING_AGENT_CHANGED
    fi
    if test "$agent_was_running" = yes; then
        test "$(owned_agent_process "$original_agent_sha")" = "$agent_process" || fail EXISTING_AGENT_PROCESS
    else ! pidof zte-agent >/dev/null 2>&1 || fail EXISTING_AGENT_STARTED
    fi
    force_started=1
    if test "$agent_was_running" = yes; then stop_owned_agent "$original_agent_sha" "$agent_process" || fail EXISTING_AGENT_STOP; fi
fi
for directory in "$anchor/bin" /etc/dropbear; do
    if test ! -d "$directory"; then mkdir -m 700 "$directory"; fi
done
if test ! -e /data/zte-agent || test "$replace_orphan_agent" = 1 || test "$replace_existing_agent" = 1 || test "$reinstall" = 1; then
    # Every replaced inactive binary is already in before/ and hashed.
    if test "$replace_orphan_agent" = 1 || test "$replace_existing_agent" = 1; then
        ! pidof zte-agent >/dev/null 2>&1 || fail EXISTING_AGENT_STARTED
        test "$(hash /data/zte-agent)" = "$(hash "$journal/before/data_zte-agent")" || fail EXISTING_AGENT_CHANGED
    fi
    atomic_copy "$stage/zte-agent" /data/zte-agent 700
    if test "$replace_existing_agent" = 1 && test "$replace_orphan_agent" = 0 && test "$reinstall" = 0; then
        if test "$startup_source" != "$anchor/start_zte_agent.sh"; then
            atomic_copy "$startup_source" "$anchor/start_zte_agent.sh" 700
        fi
        printf '%s\n' 'INSTALL_AGENT preserved'
    else
        atomic_copy "$stage/start-agent.sh" /data/zte-imei-studio/start_zte_agent.sh 700
        printf '%s\n' 'INSTALL_AGENT new'
    fi
else
    if test "$startup_source" != "$anchor/start_zte_agent.sh"; then
        atomic_copy "$startup_source" "$anchor/start_zte_agent.sh" 700
    fi
    printf '%s\n' 'INSTALL_AGENT preserved'
fi
if test ! -e /data/zte-imei-studio/bin/dropbear; then atomic_copy "$stage/dropbear" /data/zte-imei-studio/bin/dropbear 700; fi
if test ! -e /data/zte-imei-studio/bin/dropbearkey; then atomic_copy "$stage/dropbear" /data/zte-imei-studio/bin/dropbearkey 700; fi

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
        /data/zte-imei-studio/bin/dropbearkey -t "$kind" -f "$temporary" >/dev/null 2>&1 || fail HOST_KEY_GENERATION
        atomic_copy "$temporary" "$destination" 600
    fi
    /data/zte-imei-studio/bin/dropbearkey -y -f "$destination" >/dev/null 2>&1 || fail HOST_KEY_INVALID
done
atomic_copy "$stage/start_zte_imei_studio.sh" /data/zte-imei-studio/start_zte_imei_studio.sh 700
entry='sh /data/zte-imei-studio/start_zte_imei_studio.sh'
if ! grep -qFx "$entry" /etc/rc.local; then
    # Add before the first stock exit only. Preserve every existing line,
    # including the boot-time ADB switch, and never alter USB composition live.
    cp -p /etc/rc.local "$journal/rc.local.new"
    awk -v line="$entry" 'BEGIN {inserted=0} $0=="sh /data/local/tmp/start_zte_imei_studio.sh" {next} /^exit 0([ \t]|$)/ && !inserted {print line; inserted=1} {print} END {if (!inserted) print line}' /etc/rc.local > "$journal/rc.local.new"
    atomic_copy "$journal/rc.local.new" /etc/rc.local preserve
fi
sync
sh /data/zte-imei-studio/start_zte_imei_studio.sh
tries=0
while ! live_agent; do
    tries=$((tries + 1)); test "$tries" -lt 10 || fail AGENT_NOT_RUNNING
    sleep 1
done
if test "$reinstall" = 1; then owned_agent_process "$agent_sha" >/dev/null || fail INSTALLED_AGENT_PROCESS; fi
identity "$cid"
test "$(hash /data/zte-agent)" = "$agent_sha" || fail INSTALLED_AGENT_HASH
: > "$journal/after.sha256"
for target in $targets; do sha256sum "/$target" >> "$journal/after.sha256"; done
sha256sum "$journal/cid" "$journal/profile.identity" >> "$journal/after.sha256"
sync
printf '%s\n' ready > "$journal/state.new"
mv "$journal/state.new" "$journal/state"
sync
printf 'INSTALL_AGENT_SHA256 %s\n' "$(hash /data/zte-agent)"
printf 'INSTALL_DROPBEAR_SHA256 %s\n' "$(hash /data/zte-imei-studio/bin/dropbear)"
printf 'INSTALL_READY %s\n' "$journal"
