#!/bin/sh
# Transactional access installation after a fresh measured preflight. Specific
# hardware functions retain their own adapters; access never certifies NV/eSIM.
# No password is an argument, diagnostic, or journal field.
set -eu
umask 077
reinstall=0
clean_reinstall=0
preserve_agent_settings=0
while :; do
 case "${1:-}" in
  --reinstall|--clean-reinstall) reinstall=1; clean_reinstall=1; shift;;
  --preserve-agent-settings) preserve_agent_settings=1; shift;;
  *) break;;
 esac
done
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
hash() { hash_result=$(sha256sum "$1") || return 1; printf '%s\n' "${hash_result%% *}"; }
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
# A known older launcher may be readable by other users, but must never be
# writable by them. Only this startup migration accepts these extra modes;
# journal, key and payload validation continues to require private_file.
startup_file_check() {
    test ! -L "$1" || fail EXISTING_AGENT_STARTUP_LINK
    test -f "$1" || fail EXISTING_AGENT_STARTUP_TYPE
    test "$(stat -c %u "$1")" = 0 || fail EXISTING_AGENT_STARTUP_OWNER
    test "$(stat -c %h "$1")" = 1 || fail EXISTING_AGENT_STARTUP_HARDLINK
    startup_mode=$(stat -c %a "$1")
    startup_normalize=0
    case "$startup_mode" in
      600|700) ;;
      640|644|750|755) startup_normalize=1;;
      ''|*[!0-7]*) fail EXISTING_AGENT_STARTUP_MODE;;
      *) test "$((0$startup_mode & 022))" = 0 || fail EXISTING_AGENT_STARTUP_WRITABLE
         fail EXISTING_AGENT_STARTUP_MODE;;
    esac
}
# Copy through an opened descriptor and compare both metadata and bytes before
# using the private snapshot. Never chmod or execute a shared source in place.
copy_agent_startup() {
    startup_origin=$1
    startup_file_check "$startup_origin"
    exec 9< "$startup_origin" || fail LEGACY_STARTUP_READ
    startup_metadata=$(stat -c %d:%i:%u:%a:%h "$startup_origin")
    test "$(stat -L -c %d:%i:%u:%a:%h /proc/self/fd/9)" = "$startup_metadata" || fail LEGACY_STARTUP_CHANGED
    startup_digest=$(hash /proc/self/fd/9) || fail LEGACY_STARTUP_READ
    hex "$startup_digest" && test "${#startup_digest}" = 64 || fail LEGACY_STARTUP_READ
    startup_source=$stage/legacy-agent.private.sh
    (set -C; : > "$startup_source") || fail LEGACY_STARTUP_COLLISION
    cat <&9 > "$startup_source" || fail LEGACY_STARTUP_READ
    test "$(stat -L -c %d:%i:%u:%a:%h /proc/self/fd/9)" = "$startup_metadata" &&
    test "$(hash /proc/self/fd/9)" = "$startup_digest" &&
    test "$(hash "$startup_source")" = "$startup_digest" || fail LEGACY_STARTUP_CHANGED
    exec 9<&-
    startup_source_unchanged
    agent_launcher_valid "$startup_source" || fail LEGACY_STARTUP_GRAMMAR
}
startup_source_unchanged() {
    test -n "$startup_origin" || return 0
    plain_file "$startup_origin" && test "$(stat -c %u "$startup_origin")" = 0 || fail LEGACY_STARTUP_CHANGED
    test "$(stat -c %d:%i:%u:%a:%h "$startup_origin")" = "$startup_metadata" &&
    test "$(hash "$startup_origin")" = "$startup_digest" || fail LEGACY_STARTUP_CHANGED
}
# Only our generated launcher grammar may migrate from a shared legacy path.
# This validator never evaluates or prints the shell-quoted secret.
agent_launcher_valid() {
    sh -n "$1" || return 1
    # Accept current startup plus the exact formats generated by earlier releases.
    # The password is parsed as literal shell-quoted data, never evaluated.
    LC_ALL=C awk '
      function reject() {bad=1;exit 1}
      function quoted(value, i,q,bs) {
        q=sprintf("%c",39);bs=sprintf("%c",92)
        if(length(value)<3 || substr(value,1,1)!=q || substr(value,length(value),1)!=q)return 0
        for(i=2;i<length(value);i++)if(substr(value,i,1)==q) {
          if(substr(value,i,4)!=q bs q q || i+3>=length(value))return 0;i+=3
        }
        return 1
      }
      function bind_valid(line, prefix,value,ip,a,n,i) {
        prefix="export ZTE_AGENT_BIND=";if(index(line,prefix)!=1)return 0
        value=substr(line,length(prefix)+1);if(!quoted(value))return 0
        ip=substr(value,2,length(value)-2);if(ip !~ /:9090$/)return 0
        sub(/:9090$/,"",ip);n=split(ip,a,".");if(n!=4)return 0
        for(i=1;i<=4;i++)if(a[i] !~ /^[0-9]+$/ || (length(a[i])>1 && substr(a[i],1,1)=="0") || a[i]+0>255)return 0
        return 1
      }
      /\r/ {reject()}
      /^[ \t]*$/ || /^#/ {next}
      /[[:cntrl:]]/ {reject()}
      {lines[++n]=$0;if(n>8)reject()}
      END {
        if(bad || (n!=4 && n!=5 && n!=6 && n!=8))exit 1
        prefix="export ZTE_AGENT_PASSWORD="
        if(index(lines[1],prefix)!=1 || !quoted(substr(lines[1],length(prefix)+1)))exit 1
        next_line=2
        if(lines[next_line]=="unset ZTE_AGENT_MODE" && lines[next_line+1]=="unset ZTE_AGENT_BIND")next_line+=2
        q=sprintf("%c",39)
        if(lines[next_line]=="export ZTE_AGENT_MODE=" q "discovery" q) {
          if(!bind_valid(lines[next_line+1]))exit 1
          next_line+=2
        } else if(bind_valid(lines[next_line]))next_line++
        if(n!=next_line+2 || lines[next_line]!="unset ZTE_AGENT_PIN" || lines[next_line+1]!="trap " sprintf("%c%c",39,39) " HUP")exit 1
        if(lines[next_line+2]!="nohup sh -c " q "/data/zte-agent 2>&1 | logger -t zte-agent" q " >/dev/null 2>&1 </dev/null &")exit 1
      }' "$1"
}
# Extract only shell-quoted literal values; never source or run an old launcher.
# Other historical commands are deliberately omitted from the regenerated file.
agent_settings() {
 settings_source=$anchor/start_zte_agent.sh
 if test ! -e "$settings_source" && test ! -L "$settings_source"; then settings_source=/data/local/tmp/start_zte_agent.sh; fi
 plain_file "$settings_source" && test "$(stat -c %u "$settings_source")" = 0 || return 1
 test "$(stat -c %s "$settings_source")" -le 65536 || return 1
 exec 9< "$settings_source" || return 1
 settings_metadata=$(stat -L -c %d:%i:%u:%a:%h /proc/self/fd/9) || return 1
 settings_digest=$(hash /proc/self/fd/9) || return 1
 settings_values=$(LC_ALL=C awk '
 function literal(v,i,q,bs){q=sprintf("%c",39);bs=sprintf("%c",92);if(length(v)<2||substr(v,1,1)!=q||substr(v,length(v),1)!=q)return 0;for(i=2;i<length(v);i++)if(substr(v,i,1)==q){if(substr(v,i,4)!=q bs q q||i+3>=length(v))return 0;i+=3}return 1}
 /[[:cntrl:]]/ {bad=1}
 /^export ZTE_AGENT_PASSWORD=/ {if(p++||!literal(substr($0,27)))bad=1;password=$0}
 /^export ZTE_AGENT_MODE=/ {if(m++||$0!="export ZTE_AGENT_MODE=" sprintf("%c",39) "discovery" sprintf("%c",39))bad=1;mode=$0}
 /^export ZTE_AGENT_BIND=/ {v=substr($0,23);if(b++||!literal(v))bad=1;ip=substr(v,2,length(v)-2);if(ip!~/:9090$/)bad=1;sub(/:9090$/,"",ip);if(split(ip,a,".")!=4)bad=1;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]+0>255)bad=1;bind=$0}
 END {if(bad||p!=1)exit 1;print password;print "unset ZTE_AGENT_MODE";print "unset ZTE_AGENT_BIND";if(m)print mode;if(b)print bind}
 ' <&9) || { exec 9<&-; return 1; }
 test "$(stat -L -c %d:%i:%u:%a:%h /proc/self/fd/9)" = "$settings_metadata" &&
 test "$(stat -c %d:%i:%u:%a:%h "$settings_source")" = "$settings_metadata" &&
 test "$(hash "$settings_source")" = "$settings_digest" || { exec 9<&-; return 1; }
 exec 9<&-
 printf '%s\n' '#!/bin/sh' "$settings_values" 'unset ZTE_AGENT_PIN' "trap '' HUP" "nohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &"
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
check_recovery_markers() {
    for pending in "$base/active" "$base/lock" /data/local/tmp/zte-imei-installations/active /data/local/tmp/zte-imei-installations/lock /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /tmp/zte-imei-app.lock; do
        if test -e "$pending" || test -L "$pending"; then
            # Fixed categories only: no owner tokens, paths or journal contents
            # are exposed, and no marker is removed by this diagnostic check.
            case "$pending" in
              "$base/active") fail RECOVERY_PENDING_OWN_ACTIVE;;
              "$base/lock") fail RECOVERY_PENDING_OWN_LOCK;;
              /data/local/tmp/zte-imei-installations/active) fail RECOVERY_PENDING_LEGACY_ACTIVE;;
              /data/local/tmp/zte-imei-installations/lock) fail RECOVERY_PENDING_LEGACY_LOCK;;
              /data/local/tmp/open-u60-transactions/active) fail RECOVERY_PENDING_NV;;
              /tmp/fota_install_processing) fail RECOVERY_PENDING_FOTA;;
              /tmp/zte-imei-app.lock) fail RECOVERY_PENDING_APP_LOCK;;
            esac
        fi
    done
}
# Older product directories can be readable, but never writable by another
# user. Record their original metadata before narrowing access to private mode.
normalize_core_directories() {
    safe_directory /data
    mount_access "$anchor" 1
    changed=0
    for directory in "$anchor" "$anchor/bin" "$base"; do
        safe_directory "$directory"
        if test -d "$directory" && test "$(stat -c %a "$directory")" != 700; then changed=1; fi
    done
    test "$changed" = 1 || return 0
    normalization_id=$(cat /proc/sys/kernel/random/uuid) || fail CORE_DIRECTORY_ARCHIVE
    safe_id "$normalization_id" || fail CORE_DIRECTORY_ARCHIVE
    normalization=$anchor/directory-recovery-$normalization_id
    test ! -e "$normalization" && test ! -L "$normalization" || fail CORE_DIRECTORY_ARCHIVE
    mkdir -m 700 "$normalization" || fail CORE_DIRECTORY_ARCHIVE
    for directory in "$anchor" "$anchor/bin" "$base"; do
        if test -d "$directory"; then printf '%s %s\n' "$(stat -c %d:%i:%u:%a:%h "$directory")" "$directory" >> "$normalization/modes"; fi
    done
    sync
    for directory in "$anchor" "$anchor/bin" "$base"; do
        if test -d "$directory"; then safe_directory "$directory"; chmod 700 "$directory"; fi
    done
    sync
}
# Retire old product installation history as opaque data. No old recovery
# script or manifest is evaluated; OEM/NV/FOTA and the shared operation lock
# remain outside this replacement. The current installer is never superseded.
core_reconcile() {
    for marker in /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /tmp/zte-imei-app.lock; do
        if test -e "$marker" || test -L "$marker"; then
            case "$marker" in /data/local/tmp/open-u60-transactions/active) fail RECOVERY_PENDING_NV;; /tmp/fota_install_processing) fail RECOVERY_PENDING_FOTA;; *) fail RECOVERY_PENDING_APP_LOCK;; esac
        fi
    done
    needed=0
    for history in "$base" /data/local/tmp/zte-imei-installations; do
        for marker in "$history/active" "$history/lock"; do
            if test -e "$marker" || test -L "$marker"; then needed=1; fi
        done
    done
    if test -e /data/zte-agent-installer || test -L /data/zte-agent-installer; then needed=1; fi
    test "$needed" = 1 || return 0
    # Compare actual PID ancestry, not command text, when excluding this call.
    ancestors=" $$ "
    parent=$$
    count=0
    while test "$count" -lt 16 && test -r "/proc/$parent/stat"; do
        parent=$(sed 's/^[0-9][0-9]* (.*) //' "/proc/$parent/stat" | awk '{print $2}') || fail CORE_RECOVERY_PROCESS
        case "$parent" in ''|0|*[!0-9]*) break;; esac
        case "$ancestors" in *" $parent "*) break;; esac
        ancestors="$ancestors$parent "; count=$((count+1))
    done
    core_installers_absent() {
        for directory in /proc/[0-9]*; do
            test -d "$directory" || continue
            case "$ancestors" in *" ${directory##*/} "*) continue;; esac
            test -r "$directory/cmdline" || { test ! -d "$directory" || fail CORE_RECOVERY_PROCESS; continue; }
            command_line=$(tr '\000' '\n' < "$directory/cmdline" 2>/dev/null) || { test ! -d "$directory" || fail CORE_RECOVERY_PROCESS; continue; }
            case "$command_line" in *'/setup-agent.sh'*|*'/agent-manager.sh'*|*'/update-agent.sh'*|*'/upgrade-controller.sh'*|*'/zte-vpn-agent'*|*'/zte-agent-stage-'*'/manager.sh'*|*"$anchor/stage-"*|*'/data/local/tmp/zte-imei-setup-'*) fail CORE_RECOVERY_BUSY;; esac
        done
    }
    core_installers_absent
    private_directory "$anchor"
    archive_id=$(cat /proc/sys/kernel/random/uuid) || fail CORE_RECOVERY_ARCHIVE
    safe_id "$archive_id" || fail CORE_RECOVERY_ARCHIVE
    archive=$anchor/core-recovery-$archive_id
    test ! -e "$archive" && test ! -L "$archive" || fail CORE_RECOVERY_ARCHIVE
    mkdir -m 700 "$archive" || fail CORE_RECOVERY_ARCHIVE
    printf '%s\n%s\n' "$cid" "$profile $firmware_sha $router_sha" > "$archive/identity"
    # Whole-directory rename retains unknown old schemas, backups and secrets.
    # It does not traverse links or execute anything inside the old directory.
    for history in "$base" /data/local/tmp/zte-imei-installations /data/zte-agent-installer; do
        present=0
        if test "$history" = /data/zte-agent-installer && { test -e "$history" || test -L "$history"; }; then present=1; fi
        for marker in "$history/active" "$history/lock"; do
            if test -e "$marker" || test -L "$marker"; then present=1; fi
        done
        test "$present" = 1 || continue
        if test "$history" = /data/local/tmp/zte-imei-installations; then
            for parent in /data/local /data/local/tmp; do
                test -d "$parent" && test ! -L "$parent" && test "$(stat -c %u "$parent")" = 0 || fail CORE_RECOVERY_PATH
            done
        fi
        if test "$history" != /data/zte-agent-installer; then safe_directory "$history"; fi
        awk -v path="$history" '$5==path || index($5,path"/")==1 {bad=1} END{exit bad}' /proc/self/mountinfo || fail CORE_OBJECT_MOUNT
        case "$history" in "$base") name=installations;; /data/zte-agent-installer) name=agent-installer;; *) name=legacy-installations;; esac
        before=$(stat -c %d:%i:%u:%a:%h "$history") || fail CORE_RECOVERY_CHANGED
        core_installers_absent
        test "$(stat -c %d:%i:%u:%a:%h "$history")" = "$before" || fail CORE_RECOVERY_CHANGED
        mv "$history" "$archive/$name" || fail CORE_RECOVERY_ARCHIVE
        sync
    done
    printf '1\n' > "$archive/complete"
    sync
    printf 'INSTALL_CORE_RECOVERY_ARCHIVED\n' >&2
}

# These are product program file names, never shared SSH keys or OEM files.
# Preserve unexpected directories/links as opaque objects by rename; do not
# follow a link or execute an old object to decide how it should be removed.
core_quarantine_objects() {
    object_archive=
    for object in /data/zte-agent "$anchor/bin/dropbear" "$anchor/bin/dropbearkey" "$anchor/start_zte_agent.sh" "$anchor/start_zte_imei_studio.sh"; do
        test -e "$object" || test -L "$object" || continue
        if plain_file "$object" && test "$(stat -c %u "$object")" = 0; then continue; fi
        # Moving a mount or its ancestor must never relocate unrelated storage.
        awk -v path="$object" '$5==path || index($5,path"/")==1 {bad=1} END{exit bad}' /proc/self/mountinfo || fail CORE_OBJECT_MOUNT
        if test -z "$object_archive"; then
            object_id=$(cat /proc/sys/kernel/random/uuid) || fail CORE_OBJECT_ARCHIVE
            safe_id "$object_id" || fail CORE_OBJECT_ARCHIVE
            object_archive=$anchor/core-objects-$object_id
            test ! -e "$object_archive" && test ! -L "$object_archive" || fail CORE_OBJECT_ARCHIVE
            mkdir -m 700 "$object_archive" || fail CORE_OBJECT_ARCHIVE
            printf '%s\n%s\n' "$cid" "$profile $firmware_sha $router_sha" > "$object_archive/identity"
        fi
        object_name=$(printf '%s' "$object" | tr / _)
        printf '%s\n' "$object" >> "$object_archive/paths"
        sync
        mv "$object" "$object_archive/$object_name" || fail CORE_OBJECT_ARCHIVE
        sync
    done
    if test -n "$object_archive"; then printf '1\n' > "$object_archive/complete"; sync; printf 'INSTALL_CORE_RECOVERY_ARCHIVED\n' >&2; fi
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
    check_recovery_markers
    data_free=$(df -Pk /data | awk 'END {print $4}')
    etc_free=$(df -Pk /etc | awk 'END {print $4}')
    case "$data_free:$etc_free" in *[!0-9:]*) fail SPACE_UNKNOWN;; esac
    test -n "$data_free" && test -n "$etc_free" && test "$data_free" -ge 16384 && test "$etc_free" -ge 2048 || fail INSUFFICIENT_SPACE
}
live_agent() {
    for process in $(pidof zte-agent 2>/dev/null || true); do
        if test "$(readlink "/proc/$process/exe" 2>/dev/null || true)" = /data/zte-agent; then
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
# Replacement may encounter multiple older/deleted images at the fixed product
# path. Record each mapped image and start time; never signal by process name.
core_agent_processes() {
    for process in $(pidof zte-agent 2>/dev/null || true); do
        case "$process" in ''|0|*[!0-9]*) return 1;; esac
        case "$(readlink "/proc/$process/exe" 2>/dev/null)" in /data/zte-agent|"/data/zte-agent (deleted)") ;; *) return 1;; esac
        test "$(stat -L -c %u "/proc/$process/exe")" = 0 || return 1
        started=$(sed 's/^[0-9][0-9]* (.*) //' "/proc/$process/stat" | awk '{print $20}') || return 1
        case "$started" in ''|*[!0-9]*) return 1;; esac
        mapped=$(hash "/proc/$process/exe") || return 1
        printf '%s:%s:%s\n' "$process" "$started" "$mapped"
    done
}
core_stop_agents() {
    test "$(core_agent_processes)" = "$agent_process" || return 1
    printf '%s\n' "$agent_process" | while IFS=: read -r process started mapped; do
        test -n "$process" || continue
        # Earlier PIDs may take seconds to stop; re-prove this PID immediately
        # before its first signal, not just when the whole list was recorded.
        if ! pidof zte-agent 2>/dev/null | tr ' ' '\n' | grep -qx "$process"; then continue; fi
        case "$(readlink "/proc/$process/exe" 2>/dev/null)" in /data/zte-agent|"/data/zte-agent (deleted)") ;; *) exit 1;; esac
        test "$(sed 's/^[0-9][0-9]* (.*) //' "/proc/$process/stat" | awk '{print $20}')" = "$started" &&
        test "$(hash "/proc/$process/exe")" = "$mapped" || exit 1
        kill -TERM "$process" || exit 1
        attempt=0
        while pidof zte-agent 2>/dev/null | tr ' ' '\n' | grep -qx "$process"; do
            case "$(readlink "/proc/$process/exe" 2>/dev/null)" in /data/zte-agent|"/data/zte-agent (deleted)") ;; *) exit 1;; esac
            test "$(sed 's/^[0-9][0-9]* (.*) //' "/proc/$process/stat" | awk '{print $20}')" = "$started" &&
            test "$(hash "/proc/$process/exe")" = "$mapped" || exit 1
            attempt=$((attempt+1)); test "$attempt" -lt 8 || exit 1
            if test "$attempt" = 5; then kill -KILL "$process" || exit 1; fi
            sleep 1
        done
    done || return 1
    ! pidof zte-agent >/dev/null 2>&1
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
            case "$(readlink "/proc/$process/exe" 2>/dev/null || true)" in "$anchor/bin/dropbear"|"$anchor/bin/dropbear (deleted)"|/data/bin/dropbear|"/data/bin/dropbear (deleted)") ;; *) continue;; esac
            test "$(stat -L -c %u "/proc/$process/exe")" = 0 || return 1
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
    # Core replacement rollback restores files without executing old programs.
    if private_file "$journal/core-replacement"; then
        test "$(cat "$journal/core-replacement")" = 1 || return 1
        ! pidof zte-agent >/dev/null 2>&1 || return 1
    elif test "$saved_running" = yes; then
        owned_agent_process "$(hash "$journal/before/data_zte-agent")" >/dev/null || return 1
    else ! pidof zte-agent >/dev/null 2>&1 || return 1; fi
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
recovery_conflicts_clear() {
    for pending in /data/local/tmp/zte-imei-installations/active /data/local/tmp/zte-imei-installations/lock /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /tmp/zte-imei-app.lock; do
        test ! -e "$pending" && test ! -L "$pending" || fail CLEAN_RECOVERY_FOREIGN_PENDING
    done
}
recovery_installer_absent() {
    test -d /proc && test -r /proc && test -x /proc || fail CLEAN_RECOVERY_PROCESS_UNREADABLE
    recovery_process_seen=0
    for process_directory in /proc/[0-9]*; do
        test -d "$process_directory" || continue
        # This trusted invocation is the recovery worker itself.
        test "${process_directory##*/}" != "$$" || continue
        cmdline=$process_directory/cmdline
        if test ! -r "$cmdline"; then
            test ! -d "$process_directory" || fail CLEAN_RECOVERY_PROCESS_UNREADABLE
            continue
        fi
        if ! command_line=$(tr '\000' '\n' < "$cmdline" 2>/dev/null); then
            test ! -d "$process_directory" || fail CLEAN_RECOVERY_PROCESS_UNREADABLE
            continue
        fi
        recovery_process_seen=1
        # Also match a standalone stage argv (without a trailing slash), shell
        # command strings and legacy paths. Do not kill an uncertain owner.
        if test "${empty_lock:-0}" = 1; then
            case "$command_line" in
              *"$anchor/stage-"*|*"$base/"*|*"/data/local/tmp/zte-imei-setup-"*) fail CLEAN_RECOVERY_BUSY;;
            esac
        fi
        case "$command_line" in
          *"$anchor/stage-$old_token"*|*"$old_journal"*|*"/data/local/tmp/zte-imei-setup-$old_token"*) fail CLEAN_RECOVERY_BUSY;;
        esac
    done
    test "$recovery_process_seen" = 1 || fail CLEAN_RECOVERY_PROCESS_UNREADABLE
}
recovery_journal_inventory() {
    for entry in "$old_journal" "$base/lock" "$base/lock"/* "$base/lock"/.[!.]* "$base/lock"/..?* "$old_journal"/* "$old_journal"/.[!.]* "$old_journal"/..?* \
        "$old_journal"/before/* "$old_journal"/before/.[!.]* "$old_journal"/before/..?* \
        "$old_journal"/present/* "$old_journal"/present/.[!.]* "$old_journal"/present/..?* \
        "$old_journal"/planned/* "$old_journal"/planned/.[!.]* "$old_journal"/planned/..?* \
        "$old_journal"/completed-lock/* "$old_journal"/completed-lock/.[!.]* "$old_journal"/completed-lock/..?*; do
        test -e "$entry" || test -L "$entry" || continue
        entry_metadata=$(stat -c %d:%i:%u:%a:%h "$entry") || return 1
        printf '%s %s\n' "$entry_metadata" "$entry" || return 1
    done
}
recovery_record_source() {
    plain_file "$1" && test "$(stat -c %u:%h "$1")" = 0:1 || fail CLEAN_RECOVERY_CHANGED
    source_metadata=$(stat -c %d:%i:%u:%a:%h "$1") || fail CLEAN_RECOVERY_CHANGED
    source_digest=$(hash "${2:-$1}") || fail CLEAN_RECOVERY_CHANGED
    hex "$source_digest" && test "${#source_digest}" = 64 &&
    test "$(hash "$1")" = "$source_digest" || fail CLEAN_RECOVERY_CHANGED
    if test "$#" = 2; then
        test "$(stat -c %u:%a "$1")" = "$(stat -c %u:%a "$2")" || fail CLEAN_RECOVERY_CHANGED
    fi
    printf '%s  %s\n' "$source_digest" "$1" >> "$archive/sources.sha256"
    printf '%s %s\n' "$source_metadata" "$1" >> "$archive/sources.metadata"
}
recovery_empty_lock() {
    test -d "$1" || fail CLEAN_RECOVERY_OWNER
    private_directory "$1"
    for lock_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        test ! -e "$lock_entry" && test ! -L "$lock_entry" || fail CLEAN_RECOVERY_OWNER
    done
}
archive_previous_boot_owner() (
    # Explicit clean installation may supersede an abandoned owned transaction
    # on this boot or an earlier one. Preserve its journal and today's targets;
    # never roll back current data or clear another operation's markers.
    test "$clean_reinstall" = 1 || exit 1
    recovery_conflicts_clear
    recovery_boot=$(cat /proc/sys/kernel/random/boot_id) || fail CLEAN_RECOVERY_IDENTITY
    printf '%s\n' "$recovery_boot" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail CLEAN_RECOVERY_IDENTITY
    private_directory "$anchor"; private_directory "$base"
    empty_lock=0
    if test -e "$base/active" || test -L "$base/active"; then
        private_file "$base/active" || fail CLEAN_RECOVERY_OWNER
        old_token=$(cat "$base/active")
    elif test -e "$base/lock/owner" || test -L "$base/lock/owner"; then
        private_file "$base/lock/owner" || fail CLEAN_RECOVERY_OWNER
        old_token=$(cat "$base/lock/owner")
    else
        # mkdir(lock) precedes owner creation. Only the explicit requested stage
        # can supply identity for this empty, private application lock.
        test -n "${expected_recovery_token:-}" || fail CLEAN_RECOVERY_OWNER
        recovery_empty_lock "$base/lock"
        old_token=$expected_recovery_token; empty_lock=1
    fi
    safe_id "$old_token" || fail CLEAN_RECOVERY_OWNER
    old_journal=$base/$old_token
    test -z "${expected_recovery_token:-}" || test "$old_token" = "$expected_recovery_token" || fail CLEAN_RECOVERY_OWNER
    test ! -L "$old_journal" || fail CLEAN_RECOVERY_JOURNAL
    private_directory "$old_journal"
    partial_metadata=$empty_lock
    for item in cid state profile.identity targets; do
        if test -e "$old_journal/$item" || test -L "$old_journal/$item"; then
            private_file "$old_journal/$item" || fail CLEAN_RECOVERY_METADATA
        else partial_metadata=1; fi
    done
    old_boot=
    if test -e "$old_journal/profile.identity"; then
        IFS=' ' read -r old_profile old_fw old_router old_boot extra < "$old_journal/profile.identity" || fail CLEAN_RECOVERY_IDENTITY
        test -z "$extra" && test "$old_profile $old_fw $old_router" = "$profile $firmware_sha $router_sha" || fail CLEAN_RECOVERY_IDENTITY
    fi
    if test "$partial_metadata" = 1; then
        # The first persistent lock precedes journal metadata. A private staged
        # owner is the independent witness for missing fields, never a substitute
        # for contradictory fields that were already written.
        old_stage=$anchor/stage-$old_token
        test -d "$old_stage" || fail CLEAN_RECOVERY_METADATA
        private_directory "$old_stage"
        private_file "$old_stage/.owner" && test "$(stat -c %a "$old_stage/.owner")" = 600 || fail CLEAN_RECOVERY_METADATA
        IFS=' ' read -r stage_token stage_cid stage_profile stage_fw stage_router stage_boot extra < "$old_stage/.owner" || fail CLEAN_RECOVERY_IDENTITY
        test -z "$extra" && test "$stage_token $stage_cid $stage_profile $stage_fw $stage_router" = "$old_token $cid $profile $firmware_sha $router_sha" || fail CLEAN_RECOVERY_IDENTITY
        test ! -e "$old_journal/profile.identity" || test "$stage_boot" = "$old_boot" || fail CLEAN_RECOVERY_IDENTITY
        old_boot=$stage_boot
    fi
    test ! -e "$old_journal/cid" || test "$(cat "$old_journal/cid")" = "$cid" || fail CLEAN_RECOVERY_IDENTITY
    test ! -e "$old_journal/targets" || test "$(cat "$old_journal/targets")" = "$expected_targets" || fail CLEAN_RECOVERY_IDENTITY
    if test -e "$old_journal/state"; then
        case "$(cat "$old_journal/state")" in preparing|pending|ready|complete|rolled-back) ;; *) fail CLEAN_RECOVERY_STATE;; esac
    fi
    case "$profile" in
      linux-arm64-access)
        printf '%s\n' "$old_boot" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail CLEAN_RECOVERY_IDENTITY
        test "$recovery_boot" = "$boot_id" || fail CLEAN_RECOVERY_IDENTITY;;
      b31|b02-experimental) test -z "$old_boot" || fail CLEAN_RECOVERY_IDENTITY;;
      *) fail CLEAN_RECOVERY_IDENTITY;;
    esac
    bound_profile="$profile $firmware_sha $router_sha"
    if test "$profile" = linux-arm64-access; then bound_profile="$bound_profile $old_boot"; fi
    test ! -e "$old_journal/profile.identity" || test "$(cat "$old_journal/profile.identity")" = "$bound_profile" || fail CLEAN_RECOVERY_IDENTITY
    if test "$partial_metadata" = 1; then
        test "$(cat "$old_stage/.owner")" = "$old_token $cid $bound_profile" || fail CLEAN_RECOVERY_IDENTITY
    fi
    recovery_installer_absent
    if test -e "$base/active" || test -L "$base/active"; then
        private_file "$base/active" && test "$(cat "$base/active")" = "$old_token" || fail CLEAN_RECOVERY_OWNER
    fi
    if test -e "$base/lock" || test -L "$base/lock"; then
        private_directory "$base/lock"
        if test "$empty_lock" = 1; then recovery_empty_lock "$base/lock"
        else private_file "$base/lock/owner" && test "$(cat "$base/lock/owner")" = "$old_token" || fail CLEAN_RECOVERY_OWNER; fi
        for item in "$base/lock"/* "$base/lock"/.[!.]* "$base/lock"/..?*; do
            test -e "$item" || test -L "$item" || continue
            test "$item" = "$base/lock/owner" || fail CLEAN_RECOVERY_FOREIGN_FILE
        done
    fi
    # The archive is copied only after validating the complete, fixed layout.
    for item in "$old_journal"/* "$old_journal"/.[!.]* "$old_journal"/..?*; do
        test -e "$item" || test -L "$item" || continue
        case "${item##*/}" in
          completed-lock)
            private_directory "$item"
            private_file "$item/owner" && test "$(cat "$item/owner")" = "$old_token" || fail CLEAN_RECOVERY_OWNER
            for file in "$item"/* "$item"/.[!.]* "$item"/..?*; do
                test -e "$file" || test -L "$file" || continue
                test "$file" = "$item/owner" || fail CLEAN_RECOVERY_FOREIGN_FILE
            done;;
          before|present|planned)
            private_directory "$item"
            for file in "$item"/* "$item"/.[!.]* "$item"/..?*; do
                test -e "$file" || test -L "$file" || continue
                valid=0
                for target in $expected_targets; do test "${file##*/}" != "$(printf '%s' "$target" | tr / _)" || valid=1; done
                test "$valid" = 1 && plain_file "$file" && test "$(stat -c %u:%h "$file")" = 0:1 || fail CLEAN_RECOVERY_FOREIGN_FILE
            done;;
          cid|state|profile.identity|targets|before.sha256|after.sha256|mode|agent-was-running|core-replacement|startup.before.sh|authorized_keys.new|dropbear_ed25519_host_key.new|dropbear_rsa_host_key.new|rc.local.new)
            plain_file "$item" && test "$(stat -c %u:%h "$item")" = 0:1 || fail CLEAN_RECOVERY_FOREIGN_FILE;;
          *) fail CLEAN_RECOVERY_FOREIGN_FILE;;
        esac
    done
    old_inventory=$(recovery_journal_inventory) || fail CLEAN_RECOVERY_CHANGED
    validated_metadata=$(
        for metadata_file in cid state profile.identity targets; do
            test ! -e "$old_journal/$metadata_file" || sha256sum "$old_journal/$metadata_file" || exit 1
        done
        if test "$partial_metadata" = 1; then sha256sum "$old_stage/.owner" || exit 1; fi
    ) || fail CLEAN_RECOVERY_CHANGED
    archive_id=$(cat /proc/sys/kernel/random/uuid)
    safe_id "$archive_id" || fail CLEAN_RECOVERY_ARCHIVE
    archive=$anchor/reset-recovery-$old_token-$archive_id
    test ! -e "$archive" && test ! -L "$archive" || fail CLEAN_RECOVERY_ARCHIVE
    mkdir "$archive" "$archive/current" || fail CLEAN_RECOVERY_ARCHIVE
    if test -d "$old_journal"; then cp -Rp "$old_journal" "$archive/journal" || fail CLEAN_RECOVERY_ARCHIVE
    else mkdir "$archive/journal" || fail CLEAN_RECOVERY_ARCHIVE; fi
    : > "$archive/snapshot.sha256"
    : > "$archive/sources.sha256"
    : > "$archive/sources.metadata"
    : > "$archive/absent"
    printf '%s\n' "$validated_metadata" > "$archive/validated.sha256"
    if test ! -e "$old_journal"; then printf '%s\n' "$old_journal" >> "$archive/absent"; fi
    if test "$partial_metadata" = 1; then
        cp -p "$old_stage/.owner" "$archive/stage.owner" || fail CLEAN_RECOVERY_ARCHIVE
        recovery_record_source "$old_stage/.owner" "$archive/stage.owner"
        sha256sum "$archive/stage.owner" >> "$archive/snapshot.sha256"
    fi
    for original in "$old_journal"/* "$old_journal"/before/* "$old_journal"/present/* "$old_journal"/planned/* "$old_journal"/completed-lock/*; do
        test -e "$original" || test -L "$original" || continue
        test ! -d "$original" || continue
        copied=$archive/journal${original#"$old_journal"}
        plain_file "$original" && plain_file "$copied" && test "$(hash "$original")" = "$(hash "$copied")" || fail CLEAN_RECOVERY_CHANGED
        sha256sum "$copied" >> "$archive/snapshot.sha256"
        recovery_record_source "$original" "$copied"
    done
    for target in $expected_targets; do
        if test -e "/$target" || test -L "/$target"; then
            plain_file "/$target" && test "$(stat -c %u:%h "/$target")" = 0:1 || fail CLEAN_RECOVERY_TARGET
            name=$(printf '%s' "$target" | tr / _)
            cp -p "/$target" "$archive/current/$name" || fail CLEAN_RECOVERY_ARCHIVE
            test "$(hash "/$target")" = "$(hash "$archive/current/$name")" || fail CLEAN_RECOVERY_CHANGED
            sha256sum "$archive/current/$name" >> "$archive/snapshot.sha256"
            recovery_record_source "/$target" "$archive/current/$name"
        else
            printf '%s\n' "/$target" >> "$archive/absent"
        fi
    done
    for marker in "$base/active" "$base/lock/owner"; do
        if test -e "$marker" || test -L "$marker"; then
            case "$marker" in "$base/active") marker_copy=proof-active;; *) marker_copy=proof-lock-owner;; esac
            cp -p "$marker" "$archive/$marker_copy" || fail CLEAN_RECOVERY_ARCHIVE
            recovery_record_source "$marker" "$archive/$marker_copy"
            sha256sum "$archive/$marker_copy" >> "$archive/snapshot.sha256"
        else printf '%s\n' "$marker" >> "$archive/absent"; fi
    done
    if test "$empty_lock" = 1; then
        : > "$archive/proof-empty-lock"
        sha256sum "$archive/proof-empty-lock" >> "$archive/snapshot.sha256"
    fi
    printf '%s\n' "$cid" > "$archive/cid"
    printf '%s\n' "$recovery_boot" > "$archive/boot"
    sync
    identity "$cid"
    test "$(cat /proc/sys/kernel/random/boot_id)" = "$recovery_boot" || fail CLEAN_RECOVERY_IDENTITY
    recovery_conflicts_clear
    recovery_installer_absent
    current_inventory=$(recovery_journal_inventory) || fail CLEAN_RECOVERY_CHANGED
    test "$current_inventory" = "$old_inventory" || fail CLEAN_RECOVERY_CHANGED
    sha256sum -c "$archive/snapshot.sha256" >/dev/null 2>&1 &&
    sha256sum -c "$archive/validated.sha256" >/dev/null 2>&1 &&
    sha256sum -c "$archive/sources.sha256" >/dev/null 2>&1 || fail CLEAN_RECOVERY_CHANGED
    while IFS=' ' read -r metadata original; do
        plain_file "$original" && test "$(stat -c %d:%i:%u:%a:%h "$original")" = "$metadata" || fail CLEAN_RECOVERY_CHANGED
    done < "$archive/sources.metadata"
    while IFS= read -r original; do
        test ! -e "$original" && test ! -L "$original" || fail CLEAN_RECOVERY_CHANGED
    done < "$archive/absent"
    # Persist the bound receipt before marker moves so a lost final response or
    # interruption after both moves remains provable without recreating a lock.
    printf '%s\n' "$old_token $cid $profile $firmware_sha $router_sha" > "$archive/recovery.prepared"
    sync
    # Moving the owned markers retains their exact bytes and makes interruption
    # resumable: either remaining marker still identifies this old journal.
    if test -e "$base/lock"; then
        if test "$empty_lock" = 1; then recovery_empty_lock "$base/lock"
        else test "$(cat "$base/lock/owner")" = "$old_token" || fail CLEAN_RECOVERY_CHANGED; fi
        mv "$base/lock" "$archive/lock" || fail CLEAN_RECOVERY_ARCHIVE
    fi
    if test -e "$base/active"; then
        test "$(cat "$base/active")" = "$old_token" || fail CLEAN_RECOVERY_CHANGED
        mv "$base/active" "$archive/active" || fail CLEAN_RECOVERY_ARCHIVE
    fi
    sync
    printf 'INSTALL_RESET_ARCHIVED %s\n' "$archive" >&2
)
recovery_archive_proof() (
    old_token=$expected_recovery_token
    for archive in "$anchor"/reset-recovery-"$old_token"-*; do
        test -e "$archive" || test -L "$archive" || continue
        private_directory "$archive"
        private_file "$archive/recovery.prepared" || continue
        test "$(cat "$archive/recovery.prepared")" = "$old_token $cid $profile $firmware_sha $router_sha" || continue
        private_file "$archive/snapshot.sha256" || fail CLEAN_RECOVERY_ARCHIVE
        sha256sum -c "$archive/snapshot.sha256" >/dev/null 2>&1 || fail CLEAN_RECOVERY_ARCHIVE
        moved=0
        for name in active lock; do
            case "$name" in active) proof=proof-active; moved_owner=$archive/active;; lock) proof=proof-lock-owner; moved_owner=$archive/lock/owner;; esac
            if test -e "$archive/$proof" || test -L "$archive/$proof"; then
                private_file "$archive/$proof" && private_file "$moved_owner" || fail CLEAN_RECOVERY_ARCHIVE
                test "$(cat "$moved_owner")" = "$old_token" && test "$(hash "$moved_owner")" = "$(hash "$archive/$proof")" || fail CLEAN_RECOVERY_ARCHIVE
                if test "$name" = lock; then private_directory "$archive/lock"; fi
                moved=1
            fi
        done
        if test -e "$archive/proof-empty-lock" || test -L "$archive/proof-empty-lock"; then
            private_file "$archive/proof-empty-lock" && test ! -s "$archive/proof-empty-lock" || fail CLEAN_RECOVERY_ARCHIVE
            recovery_empty_lock "$archive/lock"
            empty_lock=1; moved=1
        fi
        test "$moved" = 1 || fail CLEAN_RECOVERY_ARCHIVE
        old_journal=$base/$old_token
        recovery_installer_absent
        exit 0
    done
    exit 1
)
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
cleanup_committed_secret() (
    # This stage is kept for retry verification, but its copied password is no
    # longer required once the installed deployment has been committed. An old
    # caller without a bound owner is left to its own stage cleanup.
    committed_stage="$anchor/stage-$token"
    test ! -e "$committed_stage" && test ! -L "$committed_stage" && exit 0
    private_directory "$committed_stage" || exit 0
    private_file "$committed_stage/.owner" || exit 0
    committed_owner="$token $cid $profile $firmware_sha $router_sha"
    if test "$profile" = linux-arm64-access; then committed_owner="$committed_owner $boot_id"; fi
    test "$(cat "$committed_stage/.owner")" = "$committed_owner" || exit 0
    committed_secret="$committed_stage/start-agent.sh"
    test ! -e "$committed_secret" && test ! -L "$committed_secret" && exit 0
    private_file "$committed_secret" || exit 0
    rm "$committed_secret" || exit 1
    sync
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

if test "${1:-}" = --verify-not-started; then
    test "$reinstall" = 0 && { test "$#" = 6 || test "$#" = 7; } || fail ARGUMENTS
    stage=$2; cid=$3
    case "$stage" in "$anchor"/stage-*) token=${stage#"$anchor"/stage-};;
      /data/local/tmp/zte-imei-setup-*) token=${stage#/data/local/tmp/zte-imei-setup-};;
      *) fail STAGE_PATH;; esac
    safe_id "$token" || fail STAGE_ID
    select_profile "$4" "$5" "$6" "${7:-}"
    identity "$cid"
    parent=$stage
    while test -n "$parent"; do safe_directory "$parent"; parent=${parent%/*}; done
    test -d "$stage" || fail STAGE_MISSING
    private_directory "$stage"
    owner="$token $cid $profile $firmware_sha $router_sha"
    if test "$profile" = linux-arm64-access; then owner="$owner $boot_id"; fi
    private_file "$stage/.owner" && test "$(cat "$stage/.owner")" = "$owner" || fail STAGE_OWNER
    if test -e "$stage/.install-requested" || test -L "$stage/.install-requested"; then
        private_file "$stage/.install-requested" && test "$(cat "$stage/.install-requested")" = "$owner" || fail STAGE_OWNER
    fi
    for history in "$base" /data/local/tmp/zte-imei-installations; do
        safe_directory "$history"
        for name in "$token" active lock; do
            test ! -e "$history/$name" && test ! -L "$history/$name" || fail INSTALLATION_STARTED
        done
    done
    # A timed-out host may have left its installer running. Inspect argv as
    # NUL-delimited data; never execute the saved staged installer to recover.
    for command_line in /proc/[0-9]*/cmdline; do
        test -r "$command_line" || continue
        if tr '\000' '\n' < "$command_line" 2>/dev/null | awk -v script="$stage/setup-agent.sh" 'NR==2 && $0==script {found=1} END {exit !found}'; then
            fail INSTALLER_RUNNING
        fi
    done
    identity "$cid"
    printf 'INSTALL_NOT_STARTED %s\n' "$stage"
    exit 0
fi

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

if test "${1:-}" = --recover-owned; then
    test "$clean_reinstall" = 1 || fail ARGUMENTS
    test "$#" = 6 || test "$#" = 7 || fail ARGUMENTS
    expected_recovery_token=$2; safe_id "$expected_recovery_token" || fail JOURNAL_ID
    cid=$3; select_profile "$4" "$5" "$6" "${7:-}"
    identity "$cid"
    safe_directory /data; private_directory "$anchor"; private_directory "$base"
    recovery_conflicts_clear
    if test -e "$base/active" || test -L "$base/active" || test -e "$base/lock" || test -L "$base/lock"; then
        archive_previous_boot_owner || fail CLEAN_RECOVERY_UNPROVEN
    fi
    recovery_archive_proof || fail CLEAN_RECOVERY_UNPROVEN
    identity "$cid"
    check_recovery_markers
    printf 'INSTALL_RECOVERY_ARCHIVED %s/%s\n' "$base" "$expected_recovery_token"
    exit 0
fi

if test "${1:-}" = --preflight; then
    reinstall=1; clean_reinstall=1
    test "$#" = 5 || test "$#" = 6 || fail ARGUMENTS
    select_profile "$3" "$4" "$5" "${6:-}"
    identity "$2"
    cid=$2
    if test "$preserve_agent_settings" = 1; then agent_settings >/dev/null || fail AGENT_SETTINGS_REQUIRED; fi
    normalize_core_directories
    core_reconcile
    structural_preflight
    if test "$preserve_agent_settings" = 1; then agent_settings >/dev/null || fail AGENT_SETTINGS_REQUIRED; fi
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
        cleanup_committed_secret || fail CLEANUP_FAILED
        printf 'INSTALL_COMMITTED %s\n' "$journal"
        exit 0
    fi
    printf '%s\n' complete > "$journal/state.new"
    mv "$journal/state.new" "$journal/state"
    sync
    release_completed_owner || fail JOURNAL_OWNER
    if private_file "$journal/mode" && test "$(cat "$journal/mode")" = reinstall; then cleanup_old_stages; fi
    cleanup_committed_secret || fail CLEANUP_FAILED
    printf 'INSTALL_COMMITTED %s\n' "$journal"
    exit 0
fi

reinstall=1; clean_reinstall=1
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
normalize_core_directories
core_reconcile
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
    "$stage/zte-timeout" 5 "$stage/zte-agent" --esim-check >/dev/null 2>&1 || fail AGENT_ABI
fi
plain_file /etc/rc.local || fail RC_LOCAL_TYPE
sh -n /etc/rc.local || fail RC_LOCAL_SYNTAX
check_recovery_markers
test ! -e "$base/$token" || fail JOURNAL_ALREADY_EXISTS
if test "$preserve_agent_settings" = 1; then agent_settings >/dev/null || fail AGENT_SETTINGS_REQUIRED; fi
core_quarantine_objects

targets=$expected_targets
for target in $targets; do
    if test -e "/$target" || test -L "/$target"; then
        plain_file "/$target" || fail EXISTING_FILE_TYPE
    fi
done
# Existing fixed product files are archived as data. Their version, permissions
# and old startup grammar cannot determine whether the current payload replaces
# them. Never execute the old startup, binary or SSH helper.
startup_source=
startup_origin=
replace_orphan_agent=0
replace_existing_agent=1
agent_was_running=no
agent_process=
original_agent_sha=
if test -e /data/zte-agent || test -L /data/zte-agent; then
    plain_file /data/zte-agent && test "$(stat -c %u /data/zte-agent)" = 0 || fail EXISTING_AGENT_TYPE
    original_agent_sha=$(hash /data/zte-agent)
fi
if pidof zte-agent >/dev/null 2>&1; then
    agent_process=$(core_agent_processes) || fail EXISTING_AGENT_PROCESS
    agent_was_running=yes
fi
if test "$preserve_agent_settings" = 1; then
    (set -C; : > "$stage/settings.private.new") || fail STAGING_COLLISION
    if ! agent_settings > "$stage/settings.private.new"; then rm "$stage/settings.private.new"; fail AGENT_SETTINGS_REQUIRED; fi
    chmod 600 "$stage/settings.private.new"
    mv "$stage/settings.private.new" "$stage/start-agent.sh"
    startup_source=$settings_source
    startup_origin=$settings_source
    startup_metadata=$settings_metadata
    startup_digest=$settings_digest
fi
force_ssh_listener || fail EXISTING_SSH_2222_UNVERIFIED
data_free=$(df -Pk /data | awk 'END {print $4}')
etc_free=$(df -Pk /etc | awk 'END {print $4}')
test "$data_free" -ge 16384 && test "$etc_free" -ge 2048 || fail INSUFFICIENT_SPACE

# Recheck measured identity immediately before the first persistent mutation.
identity "$cid"
structural_preflight
startup_source_unchanged
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
printf '1\n' > "$journal/core-replacement"
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
    target_name=
    for target in $targets; do
        if test "$destination" = "/$target"; then target_name=$(printf '%s' "$target" | tr / _); break; fi
    done
    test -n "$target_name" || fail STAGING_TARGET
    if test -f "$journal/present/$target_name"; then
        plain_file "$destination" && test "$(hash "$destination")" = "$(hash "$journal/before/$target_name")" || fail EXISTING_TARGET_CHANGED
    else test ! -e "$destination" && test ! -L "$destination" || fail EXISTING_TARGET_CHANGED; fi
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
            # Atomic restoration changes the path only. Running SSH keeps its
            # mapped inode and established connections throughout rollback.
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
    # Never restart the archived binary or its unknown startup. SSH stays live.
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
        test "$(core_agent_processes)" = "$agent_process" || fail EXISTING_AGENT_PROCESS
    else ! pidof zte-agent >/dev/null 2>&1 || fail EXISTING_AGENT_STARTED
    fi
    force_started=1
    if test "$agent_was_running" = yes; then core_stop_agents || fail EXISTING_AGENT_STOP; fi
fi
for directory in "$anchor/bin" /etc/dropbear; do
    if test ! -d "$directory"; then mkdir -m 700 "$directory"; fi
done
atomic_copy "$stage/zte-agent" /data/zte-agent 700
atomic_copy "$stage/start-agent.sh" /data/zte-imei-studio/start_zte_agent.sh 700
if test "$preserve_agent_settings" = 1; then printf 'INSTALL_AGENT preserved\n'
else printf 'INSTALL_AGENT new\n'; fi
atomic_copy "$stage/dropbear" /data/zte-imei-studio/bin/dropbear 700
atomic_copy "$stage/dropbear" /data/zte-imei-studio/bin/dropbearkey 700

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
# Replace exact product boot entries even when the current entry already exists;
# otherwise an older direct launcher could restart an obsolete program at boot.
cp -p /etc/rc.local "$journal/rc.local.new"
awk -v line="$entry" '
 BEGIN {inserted=0}
 $0==line || $0=="sh /data/local/tmp/start_zte_imei_studio.sh" || $0=="sh /data/local/tmp/start_zte_agent.sh" || $0=="sh /data/zte-imei-studio/start_zte_agent.sh" {next}
 /^exit 0([ \t]|$)/ && !inserted {print line; inserted=1}
 {print}
 END {if (!inserted) print line}
' /etc/rc.local > "$journal/rc.local.new"
atomic_copy "$journal/rc.local.new" /etc/rc.local preserve

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
