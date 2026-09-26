#!/bin/sh
# Remove only an account proven by this application's completed creation journal.
# The home directory is retained in a root-private archive. No password is read.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
base=/data/zte-imei-admin
config=/etc/zte-imei-admin
fail() { printf 'SSH_USERS_DELETE_ERROR %s\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
exists() { test -e "$1" || test -L "$1"; }
plain() { test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0; }
safe_dir() {
    test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail DIRECTORY
    case "$(stat -c %a "$1")" in 700|750|755) ;; *) fail DIRECTORY_MODE;; esac
}
identity() {
    test "$(id -u)" = 0 && test "$(uname -m)" = aarch64 || fail ROOT_ARCH
    test "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" || fail CID_MISMATCH
    test "$(hash /firmware/image/modem.b16)" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 || fail FIRMWARE_MISMATCH
    test "$(hash /usr/bin/diag-router)" = 55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f || fail ROUTER_MISMATCH
    safe_dir /tmp/zte-imei-app.lock
    plain /tmp/zte-imei-app.lock/owner && test "$(cat /tmp/zte-imei-app.lock/owner)" = "$lock_token" || fail GLOBAL_LOCK
}
valid_token() { test "${#1}" = 36 && case "$1" in *[!a-f0-9-]*) return 1;; esac; }
valid_user() {
    case "$1" in ''|*[!a-z0-9_]*|root|zteimei|daemon|nobody) return 1;; esac
    case "$1" in [a-z]*) ;; *) return 1;; esac
    test "${#1}" -le 24
}
# pid is populated only for the exact dedicated password listener.
listener() {
    listener_pid=
    if ! awk '$2 ~ /:08AF$/ && $4=="0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6; then return 0; fi
    plain /var/run/zte-imei-users.pid || return 1
    listener_pid=$(cat /var/run/zte-imei-users.pid)
    case "$listener_pid" in ''|*[!0-9]*) return 1;; esac
    test "$(readlink "/proc/$listener_pid/exe" 2>/dev/null || true)" = "$base/bin/dropbear" &&
    tr '\000' '\n' < "/proc/$listener_pid/cmdline" | grep -qFx -- -w &&
    tr '\000' '\n' < "/proc/$listener_pid/cmdline" | grep -qFx "$(cat "$config/listen-address"):2223" &&
    tr '\000' '\n' < "/proc/$listener_pid/cmdline" | awk 'previous=="-G" && $0=="zteimei" {yes=1} {previous=$0} END{exit !yes}'
}
listener_stop() {
    listener || return 1
    test -n "$listener_pid" || return 0
    kill -TERM "$listener_pid" || return 1
    attempts=0
    while listener && test -n "$listener_pid"; do
        attempts=$((attempts+1)); test "$attempts" -lt 6 || return 1; sleep 1
    done
    listener && test -z "$listener_pid"
}
no_user_processes() {
    for status in /proc/[0-9]*/status; do
        test -f "$status" || continue
        if awk -v uid="$uid" '$1=="Uid:" {for(i=2;i<=NF;i++)if($i==uid)found=1} END{exit !found}' "$status" 2>/dev/null; then return 1; fi
    done
}
listener_start() {
    test "$listener_before" = 1 || return 0
    test "$(hash "$base/start-ssh-users.sh")" = 35d0e51c65f0ba3499c62d16df1447b91c67e4e0cca26bc9c0e05efb712ef297 || return 1
    sh "$base/start-ssh-users.sh" 9>&- && listener && test -n "$listener_pid"
}
rollback() {
    listener_stop || return 1
    failed=0
    # Do not overwrite an external writer, even while recovering our journal.
    for file in group shadow doas.conf passwd; do
        case "$file" in doas.conf) destination=$config/doas.conf;; *) destination=/etc/$file;; esac
        plain "$journal/before/$file" && plain "$journal/after/$file" || { failed=1; continue; }
        if plain "$destination" && test "$(hash "$destination")" = "$(hash "$journal/after/$file")"; then
            temporary=$destination.zte-rollback-$token
            (set -C; : > "$temporary") && cp -p "$journal/before/$file" "$temporary" && mv "$temporary" "$destination" || failed=1
        elif ! plain "$destination" || test "$(hash "$destination")" != "$(hash "$journal/before/$file")"; then failed=1; fi
    done
    if exists "$archive"; then
        if test ! -L "$archive" && test -d "$archive" && ! exists "$home"; then mv "$archive" "$home" || failed=1
        else failed=1; fi
    elif test ! -d "$home" || test -L "$home"; then failed=1; fi
    # An inconsistent account database must never be exposed by reopening SSH.
    if test "$failed" = 0; then listener_start || failed=1; fi
    if test "$failed" = 0; then printf 'rolled-back\n' > "$journal/state"; sync; rm -f "$base/active"; sync
    else printf 'recovery-required\n' > "$journal/state"; sync; fi
    test "$failed" = 0
}
mode=${1:-}
case "$mode" in delete) test "$#" = 5 || fail ARGUMENTS; stage=$2; cid=$3; user=$4; lock_token=$5;; recover) test "$#" = 4 || fail ARGUMENTS; stage=$2; cid=$3; lock_token=$4;; *) fail ARGUMENTS;; esac
case "$stage" in /tmp/zte-ssh-users-*) ;; *) fail STAGE_PATH;; esac
stage_token=${stage#/tmp/zte-ssh-users-}; valid_token "$stage_token" && valid_token "$lock_token" || fail TOKEN
printf '%s\n' "$cid" | grep -Eq '^[a-f0-9]{32}$' || fail CID_FORMAT
identity
for dir in /etc /data "$stage" "$base" "$base/bin" "$base/homes" "$base/transactions" "$config"; do safe_dir "$dir"; done
for file in /etc/passwd /etc/group /etc/shadow "$config/doas.conf" "$config/listen-address" "$base/start-ssh-users.sh" "$base/bin/doas" "$base/bin/dropbear"; do plain "$file" || fail FILE_TYPE; done
test "$(hash "$base/bin/doas")" = f162f2d83476d22559fd844203b6af52c6a74250390cdf08c1d6b99e58c9ec97 || fail DOAS_INTEGRITY
test "$(hash "$base/bin/dropbear")" = e3833acdaa8b11e6150f82a35d3dc53d685561d5504ef337ad4af5e530345378 || fail DROPBEAR_INTEGRITY
test "$(hash "$base/start-ssh-users.sh")" = 35d0e51c65f0ba3499c62d16df1447b91c67e4e0cca26bc9c0e05efb712ef297 || fail STARTUP_INTEGRITY
if exists /etc/.zte-imei-account.lock; then plain /etc/.zte-imei-account.lock || fail ACCOUNT_LOCK_TYPE; fi
exec 9> /etc/.zte-imei-account.lock
flock -n 9 || fail ACCOUNT_LOCK
if test "$mode" = recover; then
    plain "$base/active" || fail NO_RECOVERY
    token=$(cat "$base/active"); valid_token "$token" || fail JOURNAL_TOKEN
    journal=$base/transactions/$token; safe_dir "$journal"; safe_dir "$journal/before"; safe_dir "$journal/after"
    for file in cid user operation uid listener-before state; do plain "$journal/$file" || fail JOURNAL_FILE; done
    test "$(cat "$journal/operation")" = delete && test "$(cat "$journal/cid")" = "$cid" || fail JOURNAL_OWNER
    user=$(cat "$journal/user"); valid_user "$user" || fail USER_NAME
    uid=$(cat "$journal/uid"); case "$uid" in ''|*[!0-9]*) fail UID;; esac
    test "$uid" -ge 50000 && test "$uid" -le 59999 || fail UID
    listener_before=$(cat "$journal/listener-before"); case "$listener_before" in 0|1) ;; *) fail JOURNAL_LISTENER;; esac
    home=$base/homes/$user; archive=$base/archive/$token/$user
    safe_dir "$base/archive"; safe_dir "$base/archive/$token"
    no_user_processes || fail USER_LOGGED_IN
    rollback || fail RECOVERY_CONFLICT
    printf 'SSH_USERS_RECOVERED %s\n' "$journal"
    exit 0
fi
valid_user "$user" || fail USER_NAME
! exists "$base/active" || fail RECOVERY_PENDING
for pending in /data/local/tmp/zte-imei-installations/active /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing; do ! exists "$pending" || fail OTHER_TRANSACTION; done
entry=$(awk -F: -v name="$user" '$1==name {print; n++} END{if(n!=1)exit 1}' /etc/passwd) || fail UNKNOWN_USER
uid=$(printf '%s\n' "$entry" | cut -d: -f3); gid=$(printf '%s\n' "$entry" | cut -d: -f4)
case "$uid:$gid" in *[!0-9:]*) fail UID;; esac
awk -F: -v uid="$uid" -v name="$user" '$3==uid && $1!=name {bad=1} END{exit bad}' /etc/passwd || fail SHARED_UID
printf '%s\n' "$entry" | awk -F: -v base="$base/homes/" '$3>=50000 && $3<=59999 && $5=="ZTE IMEI Studio" && $6==base $1 && $7=="/bin/ash" {yes=1} END{exit !yes}' || fail UNMANAGED_USER
awk -F: -v gid="$gid" '$1=="zteimei" && $3==gid && $4=="" {n++} END{exit n!=1}' /etc/group || fail UNMANAGED_GROUP
awk -F: -v name="$user" '$1==name {n++} END{exit n!=1}' /etc/shadow || fail SHADOW_RECORD
test "$(grep -cFx "permit $user as root" "$config/doas.conf")" = 1 || fail UNMANAGED_DOAS
home=$base/homes/$user
test -d "$home" && test ! -L "$home" && test "$(stat -c %u "$home")" = "$uid" || fail HOME_OWNER
owned=0
for proof in "$base"/transactions/*; do
    test -d "$proof" && test ! -L "$proof" || continue
    for required in cid user state after/passwd; do plain "$proof/$required" || continue 2; done
    test "$(cat "$proof/state")" = complete && test "$(cat "$proof/cid")" = "$cid" && test "$(cat "$proof/user")" = "$user" || continue
    # Creation journals predate the explicit operation field; deletion journals never prove creation.
    if exists "$proof/operation"; then continue; fi
    grep -qFx "$entry" "$proof/after/passwd" && owned=1
done
test "$owned" = 1 || fail CREATION_PROOF_MISSING
no_user_processes || fail USER_LOGGED_IN
listener || fail FOREIGN_LISTENER
listener_before=0; test -z "$listener_pid" || listener_before=1
token=$stage_token; journal=$base/transactions/$token
mkdir -m 700 "$journal" "$journal/before" "$journal/after"
printf '%s\n' "$cid" > "$journal/cid"; printf '%s\n' "$user" > "$journal/user"
printf '%s\n' "$uid" > "$journal/uid"; printf 'delete\n' > "$journal/operation"
printf '%s\n' "$listener_before" > "$journal/listener-before"
for file in passwd group shadow doas.conf; do
    case "$file" in doas.conf) destination=$config/doas.conf;; *) destination=/etc/$file;; esac
    cp -p "$destination" "$journal/before/$file"
    test "$(hash "$destination")" = "$(hash "$journal/before/$file")" || fail SNAPSHOT_CHANGED
    cp -p "$destination" "$journal/after/$file"
done
awk -F: -v name="$user" '$1!=name' "$journal/before/passwd" > "$journal/after/passwd"
awk -F: -v name="$user" '$1!=name' "$journal/before/shadow" > "$journal/after/shadow"
# Preserve the shared group and every unrelated group byte; created users have primary membership only.
awk -F: -v name="$user" 'index("," $4 ",", "," name ",") {bad=1} END{exit bad}' "$journal/before/group" || fail SECONDARY_GROUP_MEMBERSHIP
grep -vFx "permit $user as root" "$journal/before/doas.conf" > "$journal/after/doas.conf" || test "$?" = 1
"$base/bin/doas" -C "$journal/after/doas.conf" || fail DOAS_CONFIG
if ! exists "$base/archive"; then mkdir -m 700 "$base/archive"; fi
safe_dir "$base/archive"; test "$(stat -c %a "$base/archive")" = 700 || fail ARCHIVE_MODE
mkdir -m 700 "$base/archive/$token"
archive=$base/archive/$token/$user
printf 'prepared\n' > "$journal/state"
sync
printf '%s\n' "$token" > "$base/active"
sync
committing=0
cleanup() {
    result=$?; trap - EXIT HUP INT TERM
    if test "$result" != 0; then
        if test "$committing" = 1; then rollback || true
        else
            if listener_start; then printf 'rolled-back\n' > "$journal/state"; sync; rm -f "$base/active"
            else printf 'recovery-required\n' > "$journal/state"; sync; fi
        fi
        printf 'SSH_USERS_DELETE_INCOMPLETE %s\n' "$journal" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
identity
if test "$listener_before" = 1; then
    listener_stop || fail LISTENER_STOP
fi
no_user_processes || fail USER_LOGGED_IN
printf 'committing\n' > "$journal/state"; sync; committing=1
# Remove login and privileges before moving the home. Each file is atomic; journal guards the multi-file transaction.
for file in passwd doas.conf shadow group; do
    case "$file" in doas.conf) destination=$config/doas.conf;; *) destination=/etc/$file;; esac
    plain "$destination" && test "$(hash "$destination")" = "$(hash "$journal/before/$file")" || fail CONCURRENT_CHANGE
    temporary=$destination.zte-$token
    (set -C; : > "$temporary") || fail TEMPORARY_COLLISION
    cp -p "$journal/after/$file" "$temporary" && mv "$temporary" "$destination"
    test "$(hash "$destination")" = "$(hash "$journal/after/$file")" || fail COMMIT_MISMATCH
    sync
done
mv "$home" "$archive"
sync
listener_start || fail LISTENER_START
identity
awk -F: -v name="$user" '$1==name {bad=1} END{exit bad}' /etc/passwd /etc/shadow || fail DELETE_VERIFY
printf 'complete\n' > "$journal/state"; sync; rm "$base/active"; sync
printf 'SSH_USERS_DELETED %s %s %s\n' "$user" "$archive" "$journal"
