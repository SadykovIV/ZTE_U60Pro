#!/bin/sh
# Owned account transaction. Password is a single line on stdin, never argv.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
base=/data/zte-imei-admin
config=/etc/zte-imei-admin
fail() { printf 'SSH_USERS_ERROR %s\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
plain() { test -f "$1" && test ! -L "$1"; }
safe_directory() {
    test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail DIRECTORY_TYPE
    case "$(stat -c %a "$1")" in 700|750|755) ;; *) fail DIRECTORY_MODE;; esac
}
identity() {
    test "$(id -u)" = 0 && test "$(uname -s)" = Linux && test "$(uname -m)" = aarch64 || fail ROOT_ARCH
    test "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" || fail CID_MISMATCH
}
test "$#" = 6 || fail ARGUMENTS
stage=$1; cid=$2; address=$3; user=$4; doas_sha=$5; dropbear_sha=$6
case "$stage" in /tmp/zte-ssh-users-*) ;; *) fail STAGE_PATH;; esac
token=${stage#/tmp/zte-ssh-users-}
printf '%s\n' "$token" | grep -Eq '^[a-f0-9-]{36}$' || fail STAGE_TOKEN
case "$user" in ''|*[!a-z0-9_]*) fail USER_NAME;; esac
case "$user" in [a-z]*) ;; *) fail USER_NAME;; esac
test "${#user}" -le 24 || fail USER_NAME
case "$user" in root|zteimei|daemon|nobody) fail RESERVED_USER;; esac
printf '%s\n' "$cid" | grep -Eq '^[a-f0-9]{32}$' || fail CID_FORMAT
for value in "$doas_sha" "$dropbear_sha"; do printf '%s\n' "$value" | grep -Eq '^[a-f0-9]{64}$' || fail HASH_FORMAT; done
printf '%s\n' "$address" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; exit 0} {exit 1}' || fail ADDRESS
identity
IFS= read -r password || fail PASSWORD_INPUT
if IFS= read -r extra; then unset password extra; fail PASSWORD_LINES; fi
# Byte length is authoritative, matching Swift validation. No control characters.
length=$(printf '%s' "$password" | wc -c | tr -d ' ')
test "$length" -ge 8 && test "$length" -le 128 || fail PASSWORD_LENGTH
if printf '%s' "$password" | LC_ALL=C grep -q '[^ -~]'; then unset password; fail PASSWORD_CHARACTERS; fi
for directory in /data /etc "$stage"; do safe_directory "$directory"; done
for file in passwd shadow group rc.local; do
    plain "/etc/$file" && test "$(stat -c %u "/etc/$file")" = 0 || fail DATABASE_TYPE
done
for item in create-ssh-user.sh start-ssh-users.sh doas dropbear; do plain "$stage/$item" || fail STAGED_TYPE; done
test "$(hash "$stage/doas")" = "$doas_sha" && test "$(hash "$stage/dropbear")" = "$dropbear_sha" || fail STAGED_HASH
sh -n "$stage/start-ssh-users.sh" && sh -n /etc/rc.local || fail SCRIPT_SYNTAX
# /data must retain setuid semantics for password-required doas.
awk '$2=="/data" && $4 !~ /(^|,)nosuid(,|$)/ && $4 !~ /(^|,)noexec(,|$)/ {found=1} END {exit !found}' /proc/mounts || fail DATA_MOUNT
for directory in "$base" "$base/bin" "$base/homes" "$base/transactions" "$config"; do
    if test ! -e "$directory" && test ! -L "$directory"; then mkdir -m 755 "$directory"; fi
    safe_directory "$directory"
done
chmod 700 "$base/transactions"
test ! -e "$base/active" && test ! -L "$base/active" || fail RECOVERY_PENDING
# Advisory passwd lock plus snapshot/hash guards detect other writers.
exec 9> /etc/.zte-imei-account.lock
flock -n 9 || fail ACCOUNT_LOCK
awk -F: -v name="$user" '$1==name {found=1} END {exit found}' /etc/passwd /etc/shadow /etc/group || fail USER_EXISTS
home=$base/homes/$user
test ! -e "$home" && test ! -L "$home" || fail HOME_EXISTS
uid=$(awk -F: 'FNR==NR {used[$3]=1; next} {used[$3]=1} END {for(i=50000;i<=59999;i++) if(!used[i]) {print i; exit}}' /etc/passwd /etc/group)
test -n "$uid" || fail UID_EXHAUSTED
gid=$(awk -F: '$1=="zteimei" {print $3}' /etc/group)
if test -n "$gid"; then
    printf '%s\n' "$gid" | grep -Eq '^[0-9]+$' && test "$gid" -ge 50000 && test "$gid" -le 59999 || fail GROUP_CONFLICT
    plain "$config/doas.conf" && test "$(stat -c '%u:%g:%a' "$config/doas.conf")" = 0:0:600 || fail GROUP_UNMANAGED
    awk -F: '$1=="zteimei" && $4!="" {bad=1} END {exit bad}' /etc/group || fail GROUP_MEMBERS
    awk -F: -v gid="$gid" -v base="$base/homes/" '$4==gid && ($3<50000 || $3>59999 || $6!=base $1) {bad=1} END {exit bad}' /etc/passwd || fail GROUP_UNMANAGED
else gid=$uid; fi
for target in "$config/doas.conf" "$config/listen-address" "$base/start-ssh-users.sh" "$base/bin/doas" "$base/bin/dropbear"; do
    if test -e "$target" || test -L "$target"; then plain "$target" && test "$(stat -c %u "$target")" = 0 || fail EXISTING_TYPE; fi
done
if test -f "$base/bin/doas"; then test "$(hash "$base/bin/doas")" = "$doas_sha" || fail DOAS_VERSION; fi
if test -f "$base/bin/dropbear"; then test "$(hash "$base/bin/dropbear")" = "$dropbear_sha" || fail DROPBEAR_VERSION; fi
if test -f "$config/listen-address"; then test "$(cat "$config/listen-address")" = "$address" || fail EXISTING_ADDRESS; fi
if test -f "$config/doas.conf"; then
    test "$(stat -c '%u:%g:%a' "$config/doas.conf")" = 0:0:600 || fail DOAS_CONFIG_MODE
    # Accept only rules this manager emits; never inherit nopass/persist rules.
    awk 'NF==0 {next} NF!=4 || $1!="permit" || $2!~/^[a-z][a-z0-9_]*$/ || $3!="as" || $4!="root" {bad=1} END {exit bad}' "$config/doas.conf" || fail DOAS_CONFIG_UNMANAGED
fi
# A third-party service at this port is never stopped or reconfigured.
listener_before=0
if awk '$2 ~ /:08AF$/ && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6; then
    test -f "$base/start-ssh-users.sh" || fail PORT_IN_USE
    sh "$base/start-ssh-users.sh" 9>&- || fail PORT_IN_USE
    listener_before=1
fi
journal=$base/transactions/$token
mkdir "$journal" "$journal/before" "$journal/after" "$journal/present"
printf '%s\n' "$cid" > "$journal/cid"
printf '%s\n' "$user" > "$journal/user"
printf '%s\n' "$token" > "$base/active"
printf '%s\n' preparing > "$journal/state"
committing=0
cleanup() {
    code=$?
    unset password password_hash
    if test "$code" != 0; then
        failed=0
        if test "$committing" = 1; then
            # Stop only the new, managed listener. Existing service stays live.
            if test "$listener_before" = 0 && test -f /var/run/zte-imei-users.pid; then
                pid=$(cat /var/run/zte-imei-users.pid)
                case "$pid" in ''|*[!0-9]*) failed=1;; *)
                    if test "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" = "$base/bin/dropbear"; then kill "$pid" 2>/dev/null || failed=1; fi;; esac
            fi
            for file in passwd rc.local doas.conf listen-address start-ssh-users.sh group shadow; do
                destination=$(awk -F'|' -v item="$file" '$1==item {print $2}' "$journal/targets")
                test -n "$destination" || continue
                if plain "$destination" && test "$(hash "$destination")" = "$(hash "$journal/after/$file")"; then
                    if test -f "$journal/present/$file"; then
                        temporary=$destination.zte-rollback-$token
                        (set -C; : > "$temporary") && cp -p "$journal/before/$file" "$temporary" && mv "$temporary" "$destination" || failed=1
                    else rm "$destination" || failed=1; fi
                elif test -f "$journal/present/$file"; then
                    plain "$destination" && test "$(hash "$destination")" = "$(hash "$journal/before/$file")" || failed=1
                elif test -e "$destination" || test -L "$destination"; then failed=1; fi
            done
            if test -d "$home"; then
                if test "$(stat -c %u "$home")" = "$uid" && test ! -e "$home/.ssh"; then
                    rm -f "$home/.profile"; rmdir "$home" 2>/dev/null || failed=1
                else failed=1; fi
            fi
        fi
        if test "$failed" = 0; then printf '%s\n' rolled-back > "$journal/state"; rm -f "$base/active"; else printf '%s\n' recovery-required > "$journal/state"; fi
        sync
        printf 'SSH_USERS_INCOMPLETE %s\n' "$journal" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
cat > "$journal/targets" <<TARGETS
shadow|/etc/shadow
group|/etc/group
start-ssh-users.sh|$base/start-ssh-users.sh
listen-address|$config/listen-address
doas.conf|$config/doas.conf
rc.local|/etc/rc.local
passwd|/etc/passwd
TARGETS
while IFS='|' read -r name destination; do
    if test -e "$destination"; then
        cp -p "$destination" "$journal/before/$name"
        test "$(hash "$destination")" = "$(hash "$journal/before/$name")" || fail SNAPSHOT_CHANGED
        : > "$journal/present/$name"
    fi
done < "$journal/targets"
sync
printf 'SSH_USERS_SNAPSHOT %s\n' "$journal"
password_hash=$(printf '%s\n' "$password" | /usr/bin/openssl passwd -6 -stdin)
unset password
printf '%s\n' "$password_hash" | grep -Eq '^\$6\$[./A-Za-z0-9]{8,16}\$[./A-Za-z0-9]{86}$' || fail PASSWORD_HASH
for name in passwd shadow group rc.local; do cp -p "$journal/before/$name" "$journal/after/$name"; done
printf '\n%s:x:%s:%s:ZTE IMEI Studio:%s:/bin/ash\n' "$user" "$uid" "$gid" "$home" >> "$journal/after/passwd"
days=$(( $(date +%s) / 86400 ))
printf '\n%s:%s:%s:0:99999:7:::\n' "$user" "$password_hash" "$days" >> "$journal/after/shadow"
unset password_hash
if ! awk -F: '$1=="zteimei" {found=1} END {exit !found}' /etc/group; then
    printf '\nzteimei:x:%s:\n' "$gid" >> "$journal/after/group"
fi
# Primary group membership is sufficient for Dropbear's -G filter.
if test -f "$config/doas.conf"; then cat "$config/doas.conf" > "$journal/after/doas.conf"; else : > "$journal/after/doas.conf"; fi
printf '\npermit %s as root\n' "$user" >> "$journal/after/doas.conf"
printf '%s\n' "$address" > "$journal/after/listen-address"
cp "$stage/start-ssh-users.sh" "$journal/after/start-ssh-users.sh"
entry="sh $base/start-ssh-users.sh"
if ! grep -qFx "$entry" /etc/rc.local; then
    awk -v entry="$entry" 'BEGIN {done=0} /^exit 0([ \t]|$)/ && !done {print entry;done=1} {print} END {if(!done)print entry}' /etc/rc.local > "$journal/after/rc.local"
fi
sh -n "$journal/after/rc.local" && sh -n "$journal/after/start-ssh-users.sh" || fail STAGED_SYNTAX
"$stage/doas" -C "$journal/after/doas.conf" || fail DOAS_CONFIG
chmod 600 "$journal/after/shadow" "$journal/after/doas.conf" "$journal/after/listen-address"
chmod 644 "$journal/after/passwd" "$journal/after/group"
chmod 700 "$journal/after/start-ssh-users.sh"
# Install verified binaries within the protected directory, never /data/bin (777).
for binary in doas dropbear; do
    if test ! -f "$base/bin/$binary"; then
        cp "$stage/$binary" "$base/bin/$binary.new-$token"
        chmod 755 "$base/bin/$binary.new-$token"
        mv "$base/bin/$binary.new-$token" "$base/bin/$binary"
    fi
done
chmod 4755 "$base/bin/doas"
test "$(stat -c '%u:%g:%a' "$base/bin/doas")" = 0:0:4755 || fail DOAS_MODE
identity
committing=1
printf '%s\n' committing > "$journal/state"
while IFS='|' read -r name destination; do
    if test -f "$journal/present/$name"; then
        plain "$destination" && test "$(hash "$destination")" = "$(hash "$journal/before/$name")" || fail CONCURRENT_CHANGE
    else test ! -e "$destination" && test ! -L "$destination" || fail CONCURRENT_CREATE; fi
    temporary=$destination.zte-$token
    (set -C; : > "$temporary") || fail TEMPORARY_COLLISION
    cp -p "$journal/after/$name" "$temporary"
    mv "$temporary" "$destination"
    : > "$journal/committed-$name"
    test "$(hash "$destination")" = "$(hash "$journal/after/$name")" || fail COMMIT_MISMATCH
done < "$journal/targets"
mkdir -m 700 "$home"
printf 'export PATH=/data/zte-imei-admin/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' > "$home/.profile"
chown -R "$uid:$gid" "$home"
sync
sh "$base/start-ssh-users.sh" 9>&- || fail LISTENER_START
identity
test "$(id -u "$user")" = "$uid" && test "$(id -g "$user")" = "$gid" || fail ACCOUNT_VERIFY
printf '%s\n' complete > "$journal/state"
sync
rm "$base/active"
sync
printf 'SSH_USERS_CREATED %s %s %s\n' "$user" "$uid" "$journal"
