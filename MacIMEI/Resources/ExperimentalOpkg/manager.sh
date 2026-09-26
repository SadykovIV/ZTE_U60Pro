#!/bin/sh
# opkg is genuine, but runs in a private chroot AND offline root. No host DB/feed writes.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
unset LD_PRELOAD LD_LIBRARY_PATH ENV BASH_ENV
BASE=/data/zte-imei-apps
ROOT=$BASE/opkg-private
GEN=$ROOT/generations
TIMEOUT_SHA=6e81024c273080294a251ae38572f1ef0cb496fbd16c7009c6a4ae1c07fb55ff
SELF_DIR=${0%/*}
SUPERVISOR=$SELF_DIR/zte-timeout
fail() { printf 'OPKG_ERROR %s\n' "$*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
private() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a "$1")" = 0:700 ] || fail PRIVATE_DIRECTORY; }
plain() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%h "$1")" = 0:1 ] && [ "$(stat -c %a "$1")" = 600 ] || fail PRIVATE_FILE; }
generation() { printf '%s\n' "$1" | grep -Eq '^g-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
identity() {
 [ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] || fail ROOT_ARCH
 [ "$(cat /sys/block/mmcblk0/device/cid)" = "$CID" ] && [ "$(cat /proc/sys/kernel/random/boot_id)" = "$BOOT" ] || fail DEVICE_CHANGED
 [ "$(sha /firmware/image/modem.b16)" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ] || fail FIRMWARE
 grep -qx "DISTRIB_RELEASE='23.05.4'" /etc/openwrt_release && grep -qx "DISTRIB_ARCH='aarch64_cortex-a53'" /etc/openwrt_release || fail PLATFORM
 [ ! -e /tmp/fota_install_processing ] || fail FIRMWARE_UPDATE
}
platform() {
 identity
 [ -d /data ] && [ ! -L /data ] && [ "$(stat -c %u /data)" = 0 ] || fail DATA
 mode=$(stat -c %a /data);[ "$((0$mode & 022))" = 0 ] || fail DATA_MODE
 awk '$2=="/data" {n++;split($4,a,",");for(i in a){if(a[i]=="rw")rw=1;if(a[i]=="noexec")bad=1}} END{exit !(n==1&&rw&&!bad)}' /proc/mounts || fail DATA_NOT_EXECUTABLE
 for c in chroot flock cp tar gzip find sha256sum stat awk sed readlink mknod sort cmp; do command -v "$c" >/dev/null || fail "CAPABILITY_$c"; done
 if exists "$BASE"; then
  [ -d "$BASE" ] && [ ! -L "$BASE" ] && [ "$(stat -c %u "$BASE")" = 0 ] || fail OWNER
  mode=$(stat -c %a "$BASE");[ "$((0$mode & 022))" = 0 ] || fail OWNER
  plain "$BASE/.zte-imei-owner"
  [ "$(cat "$BASE/.zte-imei-owner")" = zte-imei-apps-v1 ] || fail OWNER
 fi
 if awk -v r="$ROOT" '$2==r||index($2,r"/")==1{bad=1}END{exit !bad}' /proc/mounts; then fail NESTED_MOUNT; fi
}
free_space() { FREE=$(df -Pk /data | awk 'NR==2{print $4}'); case "$FREE" in ''|*[!0-9]*) fail FREE_SPACE;; esac; }
running() {
 RUNNING=0
 for p in /proc/[0-9]*/exe;do [ -L "$p" ] || continue;target=$(readlink "$p") || { [ ! -e "$p" ] || fail PROCESS_SCAN;continue; };case "$target" in "$GEN/"*) RUNNING=1;;esac;done
 for p in /proc/[0-9]*/maps; do [ -f "$p" ] || continue; [ -r "$p" ] || fail PROCESS_SCAN; if grep -F "$GEN/" "$p" >/dev/null 2>&1; then RUNNING=1; else code=$?; [ "$code" = 1 ] || { [ ! -e "$p" ] || fail PROCESS_SCAN; }; fi; done
}
state() {
 ACTIVE=none; PREVIOUS=unset
 exists "$ROOT" || return 0
 private "$ROOT";private "$GEN";plain "$ROOT/owner";plain "$ROOT/state"
 [ "$(cat "$ROOT/owner")" = "zte-private-opkg-v1:$CID" ] || fail OWNER
 [ "$(stat -c %s "$ROOT/state")" -le 150 ] || fail STATE
 SNAPSHOT=$(cat "$ROOT/state")
 [ "$(printf '%s\n' "$SNAPSHOT" | wc -l | tr -d ' ')" = 2 ] || fail STATE
 ACTIVE=$(printf '%s\n' "$SNAPSHOT" | sed -n '1s/^active=//p');PREVIOUS=$(printf '%s\n' "$SNAPSHOT" | sed -n '2s/^previous=//p')
 [ "$ACTIVE" = none ] || generation "$ACTIVE" || fail STATE
 case "$PREVIOUS" in none|unset) ;; *) generation "$PREVIOUS" || fail STATE;; esac
 [ "$ACTIVE:$PREVIOUS" != none:none ] && [ "$ACTIVE" != "$PREVIOUS" ] || fail STATE
}
# Seals live outside chroot, so package extraction cannot alter them. The
# inventory records exact paths, types, modes, owners, link targets and bytes.
inventory() {
 (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r item; do
  case "$item" in *[!a-zA-Z0-9_./+@,:=-]*) fail UNSUPPORTED_PATH;; esac
  if [ "$2" = runtime ];then case "$item" in ./packages|./packages/*) continue;; esac;fi
  mode=$(stat -c %a "$item");[ "$(stat -c %u "$item")" = 0 ] || fail PAYLOAD_OWNER
  if [ -L "$item" ];then
   target=$(readlink "$item");case "$target" in ''|/*|*..*|*[!a-zA-Z0-9_./+-]*) fail UNSAFE_SYMLINK;;esac
   printf 'l %s %s %s\n' "$mode" "$item" "$target"
  else
   [ "$((0$mode & 06022))" = 0 ] || fail PAYLOAD_MODE
   if [ -d "$item" ];then printf 'd %s %s\n' "$mode" "$item"
   elif [ -f "$item" ];then [ "$(stat -c %h "$item")" = 1 ] || fail HARDLINK;printf 'f %s %s %s\n' "$mode" "$item" "$(sha "$item")"
   elif [ -c "$item" ];then
    case "$item:$(stat -c %t:%T "$item"):$mode" in ./dev/null:1:3:600|./dev/urandom:1:9:600) ;; *) fail SPECIAL_FILE;;esac
    printf 'c %s %s %s\n' "$mode" "$item" "$(stat -c %t:%T "$item")"
   else fail SPECIAL_FILE;fi
  fi
 done)
}
verify_generation() {
 private "$GEN/$1";private "$GEN/$1/sandbox"
 for file in files.inventory runtime.inventory manager.sh seal;do plain "$GEN/$1/$file";done
 [ "$(cat "$GEN/$1/seal")" = "$(sha "$GEN/$1/files.inventory") $(sha "$GEN/$1/runtime.inventory") $(sha "$GEN/$1/manager.sh")" ] || fail GENERATION_SEAL
 actual=$(inventory "$GEN/$1/sandbox" all) || fail CHANGED_GENERATION
 [ "$actual" = "$(cat "$GEN/$1/files.inventory")" ] || fail CHANGED_GENERATION
}

report() {
 state;free_space;running
 printf '__ZTE_PRIVATE_OPKG_V1__\ninstalled=%s\ngeneration=%s\nprevious=%s\nrollback=%s\nfree_kib=%s\nrunning=%s\n' "$(if [ "$ACTIVE" = none ];then echo 0;else echo 1;fi)" "$ACTIVE" "$PREVIOUS" "$(if [ "$PREVIOUS" = unset ];then echo 0;else echo 1;fi)" "$FREE" "$RUNNING"
 if [ "$ACTIVE" != none ]; then
  verify_generation "$ACTIVE"
  awk 'BEGIN{RS="";FS="\n"}{name="";version="";description="";ok=0;for(i=1;i<=NF;i++){if($i~/^Package: /)name=substr($i,10);if($i~/^Version: /)version=substr($i,10);if($i~/^Description: /)description=substr($i,14,300);if($i~/^Status: .* installed$/)ok=1}if(ok&&name!="zte-private-musl"){gsub(/\t/," ",description);printf "package=%s\t%s\t%s\n",name,version,description}}' "$GEN/$ACTIVE/sandbox/packages/usr/lib/opkg/status"
 fi
 printf '__END__\n'
}
validate_args() {
 [ "$#" -ge 1 ] && [ "$#" -le 9 ] || fail ARGUMENTS
 COMMAND=$1;shift
 case "$COMMAND" in update) [ "$#" = 0 ] || fail ARGUMENTS;; install|remove|search|info) [ "$#" -ge 1 ] || fail ARGUMENTS;; files) [ "$#" = 1 ] || fail ARGUMENTS;; list|list-installed|status) ;; *) fail COMMAND;; esac
 for name in "$@"; do
  [ "${#name}" -le 100 ] || fail PACKAGE
  case "$name" in ''|-*|*..*|*[!a-z0-9+._?*-]*) fail PACKAGE;; esac
  case "$COMMAND" in files) case "$name" in *\**|*\?*) fail PACKAGE;;esac;;esac
  case "$COMMAND" in install|remove)
   case "$name" in *\**|*\?*|kmod-*|luci-*|kernel|libc|libpthread|zte-private-musl|busybox|opkg|base-files|procd|netifd|firewall|firewall4) fail UNSUPPORTED_PACKAGE;; esac;;
  esac
 done
}
# Only ordinary user-space files may be published. Offline scripts never execute;
# default no-op OpenWrt wrappers may remain, custom maintainer actions are rejected.
audit_packages() {
 PKG=$CAND/sandbox/packages
 find "$PKG" -print | while IFS= read -r item; do
  rel=${item#"$PKG"};rel=${rel#/}
  case "$rel" in *[!a-zA-Z0-9_./+@,:=-]*) fail UNSUPPORTED_PATH;; esac
  case "$rel" in etc/*|lib/modules|lib/modules/*|lib/firmware|lib/firmware/*|usr/libexec/*|usr/lib/opkg/alternatives/*) fail SERVICE_OR_SYSTEM_PAYLOAD;; esac
  [ "$item" = "$PKG" ] && continue
  case "$rel" in bin|bin/*|sbin|sbin/*|lib|lib/*|usr|usr/*|etc|var|var/lock|var/lock/opkg.lock|var/opkg-lists|var/opkg-lists/*) ;; *) fail UNSUPPORTED_PATH;; esac
  if [ -L "$item" ]; then
   target=$(readlink "$item")
   case "$target" in ''|/*|*..*|*[!a-zA-Z0-9_./+-]*) fail UNSAFE_SYMLINK;; esac
  elif [ -d "$item" ];then :
  elif [ -f "$item" ];then [ "$(stat -c %h "$item")" = 1 ] || fail HARDLINK
  else fail SPECIAL_FILE;fi
 done
 for f in "$PKG"/usr/lib/opkg/info/*.preinst "$PKG"/usr/lib/opkg/info/*.postinst* "$PKG"/usr/lib/opkg/info/*.prerm "$PKG"/usr/lib/opkg/info/*.postrm; do
  [ -e "$f" ] || continue
  case "$(sha "$f")" in 61511dd6dcc9e5ae9038f7ea8b0ecdf3bdd17612af012c3d9536e9aca03691df|41e62438f65308026184be1d4d931ae9100923e5ae97b146fb678e5b6cd0fc6c) ;; *) fail CUSTOM_MAINTAINER_SCRIPT;; esac
 done
 if awk '/^Package: /{if($2~/^kmod-/||$2~/^luci-/||$2~/^(kernel|busybox|opkg|base-files|procd|netifd|firewall|firewall4)$/)bad=1}END{exit !bad}' "$PKG/usr/lib/opkg/status"; then fail UNSUPPORTED_DEPENDENCY;fi
 # Runtime files, config and keys must stay byte-for-byte unchanged.
 actual=$(inventory "$CAND/sandbox" runtime) || fail RUNTIME_CHANGED
 [ "$actual" = "$(cat "$CAND/runtime.inventory")" ] || fail RUNTIME_CHANGED
}
manifest() {
 free_space;[ "$FREE" -ge 65536 ] || fail FREE_SPACE
 inventory "$CAND/sandbox" all > "$CAND/files.inventory" || fail PAYLOAD_INVENTORY
 cp "$0" "$CAND/manager.sh";chmod 600 "$CAND/manager.sh"
 printf '%s %s %s\n' "$(sha "$CAND/files.inventory")" "$(sha "$CAND/runtime.inventory")" "$(sha "$CAND/manager.sh")" > "$CAND/seal"
}

check_supervisor() {
 private "$SELF_DIR"
 [ -f "$SUPERVISOR" ] && [ ! -L "$SUPERVISOR" ] && [ -x "$SUPERVISOR" ] && [ "$(stat -c %u:%h "$SUPERVISOR")" = 0:1 ] && [ "$(stat -c %a "$SUPERVISOR")" = 700 ] || fail TIMEOUT_HELPER_FILE
 [ "$(sha "$SUPERVISOR")" = "$TIMEOUT_SHA" ] || fail TIMEOUT_HELPER_HASH
}
legacy_cli() {
 cat <<'LEGACY_CLI'
#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
unset LD_PRELOAD LD_LIBRARY_PATH ENV BASH_ENV
root=/data/zte-imei-apps/opkg-private
active=$(sed -n '1s/^active=//p' "$root/state")
printf '%s\n' "$active" | grep -Eq '^g-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || { echo 'opkg adapter is disabled' >&2;exit 1; }
dir=$root/generations/$active
expected=$(awk '{print $3}' "$dir/seal")
[ "$(sha256sum "$dir/manager.sh" | cut -d ' ' -f1)" = "$expected" ] || exit 1
exec sh "$dir/manager.sh" execute "$(cat /sys/block/mmcblk0/device/cid)" "$(cat /proc/sys/kernel/random/boot_id)" "$@"
LEGACY_CLI
}
cli_text() {
 printf '#!/bin/sh\n# ZTE private opkg runner v2\nmanager_hash=%s\ntimeout_hash=%s\n' "$1" "$2"
 cat <<'RUNNER_CLI'
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
unset LD_PRELOAD LD_LIBRARY_PATH ENV BASH_ENV
root=/data/zte-imei-apps/opkg-private
runner=$root/runners/$manager_hash
for directory in "$root" "$root/runners" "$runner";do
 [ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(stat -c %u:%a "$directory")" = 0:700 ] || exit 1
done
for file in manager.sh zte-timeout;do [ -f "$runner/$file" ] && [ ! -L "$runner/$file" ] && [ "$(stat -c %u:%h "$runner/$file")" = 0:1 ] || exit 1;done
[ "$(stat -c %a "$runner/manager.sh")" = 600 ] && [ "$(stat -c %a "$runner/zte-timeout")" = 700 ] && [ -x "$runner/zte-timeout" ] || exit 1
[ "$(sha256sum "$runner/manager.sh" | cut -d ' ' -f1)" = "$manager_hash" ] && [ "$(sha256sum "$runner/zte-timeout" | cut -d ' ' -f1)" = "$timeout_hash" ] || exit 1
exec sh "$runner/manager.sh" execute "$(cat /sys/block/mmcblk0/device/cid)" "$(cat /proc/sys/kernel/random/boot_id)" "$@"
RUNNER_CLI
}
check_runner() {
 private "$ROOT/runners";private "$ROOT/runners/$1"
 plain "$ROOT/runners/$1/manager.sh"
 [ "$(sha "$ROOT/runners/$1/manager.sh")" = "$1" ] || fail RUNNER_HASH
 tool=$ROOT/runners/$1/zte-timeout
 [ -f "$tool" ] && [ ! -L "$tool" ] && [ -x "$tool" ] && [ "$(stat -c %u:%h "$tool")" = 0:1 ] && [ "$(stat -c %a "$tool")" = 700 ] && [ "$(sha "$tool")" = "$2" ] || fail RUNNER_TIMEOUT
}
check_cli() {
 exists "$ROOT/opkg" || return 0
 [ -f "$ROOT/opkg" ] && [ ! -L "$ROOT/opkg" ] && [ "$(stat -c %u:%h "$ROOT/opkg")" = 0:1 ] && [ "$(stat -c %a "$ROOT/opkg")" = 700 ] || fail CLI_CHANGED
 actual_cli=$(sha "$ROOT/opkg")
 [ "$actual_cli" != "$(legacy_cli | sha256sum | awk '{print $1}')" ] || return 0
 old_manager=$(sed -n '3s/^manager_hash=//p' "$ROOT/opkg");old_timeout=$(sed -n '4s/^timeout_hash=//p' "$ROOT/opkg")
 for hash_value in "$old_manager" "$old_timeout";do printf '%s\n' "$hash_value" | grep -Eq '^[0-9a-f]{64}$' || fail CLI_CHANGED;done
 [ "$actual_cli" = "$(cli_text "$old_manager" "$old_timeout" | sha256sum | awk '{print $1}')" ] || fail CLI_CHANGED
 check_runner "$old_manager" "$old_timeout"
}
prepare_cli() {
 # Package generations keep their original sealed managers. Host runner updates
 # are independent, so legacy generations remain verifiable and rollbackable.
 check_cli;check_supervisor
 manager_hash=$(sha "$0")
 if exists "$ROOT/runners";then private "$ROOT/runners";else mkdir -m 700 "$ROOT/runners";fi
 if ! exists "$ROOT/runners/$manager_hash";then
  runner_stage=$ROOT/runners/.stage-$$
  ! exists "$runner_stage" || fail STAGING_EXISTS
  mkdir -m 700 "$runner_stage"
  cp "$0" "$runner_stage/manager.sh";chmod 600 "$runner_stage/manager.sh"
  cp "$SUPERVISOR" "$runner_stage/zte-timeout";chmod 700 "$runner_stage/zte-timeout"
  [ "$(sha "$runner_stage/manager.sh")" = "$manager_hash" ] && [ "$(sha "$runner_stage/zte-timeout")" = "$TIMEOUT_SHA" ] || fail RUNNER_HASH
  sync;mv "$runner_stage" "$ROOT/runners/$manager_hash"
 fi
 check_runner "$manager_hash" "$TIMEOUT_SHA"
 CLI=$ROOT/.opkg-$$;! exists "$CLI" || fail STAGING_EXISTS
 cli_text "$manager_hash" "$TIMEOUT_SHA" > "$CLI";chmod 700 "$CLI";sync
}
publish_cli() {
 # The temporary runner and CLI are verified before opkg or state changes. Only
 # this final atomic rename changes the permanent entry point after success.
 check_cli;check_runner "$manager_hash" "$TIMEOUT_SHA"
 identity;mv "$CLI" "$ROOT/opkg";CLI=;sync
}

commit() {
 identity;running;[ "$RUNNING" = 0 ] || fail TOOLS_RUNNING
 tmp=$ROOT/.state-$$;! exists "$tmp" || fail STAGING_EXISTS
 printf 'active=%s\nprevious=%s\n' "$NEW" "$ACTIVE" > "$tmp";sync
 identity;mv "$tmp" "$ROOT/state";sync
}
invoke() {
 # No host paths are mounted into this chroot. All config, keys, cache, scripts,
 # package database and absolute symlink targets are confined to this sandbox.
 "$SUPERVISOR" 540 chroot "$SANDBOX" /bin/opkg -f /etc/opkg.conf --offline-root /packages --tmp-dir /tmp "$@"
}
# Source names become list filenames, so only a small unambiguous ASCII form
# is allowed. Input is parsed as data; no shell expansion or extra directives.
normalize_feeds() {
 [ "$(stat -c %s "$1")" -le 16384 ] || fail FEEDS_SIZE
 awk '
 function invalid(){bad=1;exit 1}
 /^[ \t]*($|#)/{next}
 {
  if(NF!=3 || $1!="src/gz" || length($2)>48 || $2!~/^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/ || seen[$2]++)invalid()
  u=$3;if(length(u)>1024 || u!~/^https?:\/\// || u~/[^a-zA-Z0-9:._~%+\/=[\]-]/)invalid()
  escapes=u;gsub(/%[0-9a-fA-F][0-9a-fA-F]/,"",escapes);if(escapes~/%/)invalid()
  sub(/^https?:\/\//,"",u);split(u,parts,"/");authority=parts[1]
  if(authority~/^\[/){if(authority!~/^\[[0-9a-fA-F:]+\](:[0-9]+)?$/)invalid();port=authority;sub(/^.*\]/,"",port)}
  else{if(authority!~/^[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?$/)invalid();port=authority;sub(/^[^:]*/,"",port)}
  if(port!=""){sub(/^:/,"",port);if(length(port)>5 || port+0<1 || port+0>65535)invalid()}
  if(++count>16)invalid()
  print "src/gz " $2 " " $3
 }
 END{if(bad)exit 1}' "$1" || fail FEEDS_FORMAT
}
configured_feeds() {
 # Non-source configuration is immutable except for this explicit save action.
 awk '$1=="src/gz"{print}' "$1"
}
print_feeds() {
 [ "$ACTIVE" != none ] || fail NOT_INSTALLED
 verify_generation "$ACTIVE"
 config=$GEN/$ACTIVE/sandbox/etc/opkg.conf;plain "$config"
 sources=$(configured_feeds "$config")
 # Validate without creating any file during read-only load.
 printf '__ZTE_OPKG_FEEDS_V1__\nrelease=23.05.4\narchitecture=aarch64_cortex-a53\ngeneration=%s\n' "$ACTIVE"
 for key in "$GEN/$ACTIVE/sandbox/etc/opkg/keys/"*;do
  [ -f "$key" ] || continue
  key_name=${key##*/};printf '%s\n' "$key_name" | grep -Eq '^[0-9a-f]{16}$' || fail FEED_KEY_NAME
  printf 'key=%s\n' "$key_name"
 done
 if [ -n "$sources" ];then printf '%s\n' "$sources" | sed 's/^/source=/';fi
 printf '__END_FEEDS__\n'
}
verify_indexes() {
 # Upstream update may return zero after signature failure. Check exactly the
 # configured dynamic feed set, with the pinned verifier and trusted keys.
 sources=$(configured_feeds "$SANDBOX/etc/opkg.conf")
 [ -n "$sources" ] || fail NO_FEEDS
 feeds=$(printf '%s\n' "$sources" | awk '{print $2}')
 for feed in $feeds;do
  case "$feed" in ''|*[!a-zA-Z0-9_-]*) fail FEEDS_FORMAT;;esac
  [ -f "$SANDBOX/packages/var/opkg-lists/$feed" ] && [ -f "$SANDBOX/packages/var/opkg-lists/$feed.sig" ] || fail FEED_INDEX_UNVERIFIED
  plain "$SANDBOX/packages/var/opkg-lists/$feed"
  plain "$SANDBOX/packages/var/opkg-lists/$feed.sig"
  "$SUPERVISOR" 60 chroot "$SANDBOX" /usr/sbin/opkg-key verify "/packages/var/opkg-lists/$feed.sig" "/packages/var/opkg-lists/$feed" || fail FEED_SIGNATURE
 done
}

make_candidate() {
 free_space
 used=$(du -sk "$GEN/$ACTIVE" 2>/dev/null | awk '{print $1}')
 [ -n "$used" ] || used=0
 [ "$FREE" -ge "$((used+65536))" ] || fail FREE_SPACE
 NEW=g-$(cat /proc/sys/kernel/random/uuid);generation "$NEW" || fail GENERATION
 CAND=$GEN/$NEW;! exists "$CAND" || fail STAGING_EXISTS
 mkdir -m 700 "$CAND"
 if [ "$ACTIVE" != none ];then verify_generation "$ACTIVE";cp -a "$GEN/$ACTIVE/sandbox" "$CAND/sandbox";cp "$GEN/$ACTIVE/runtime.inventory" "$CAND/runtime.inventory";else mkdir -m 700 "$CAND/sandbox";fi
 SANDBOX=$CAND/sandbox
}
[ "$#" -ge 3 ] || fail ARGUMENTS
ACTION=$1;CID=$2;BOOT=$3;shift 3
printf '%s\n' "$CID" | grep -Eq '^[0-9a-f]{32}$' || fail CID
printf '%s\n' "$BOOT" | grep -Eq '^[0-9a-f-]{36}$' || fail BOOT
platform;state
if [ "$ACTION" = inspect ];then [ "$#" = 0 ] || fail ARGUMENTS;report;exit 0;fi
if [ "$ACTION" = read-feeds ];then [ "$#" = 0 ] || fail ARGUMENTS;print_feeds;report;exit 0;fi
check_supervisor
case "$ACTION" in execute) validate_args "$@";;install-adapter|remove-adapter|rollback|save-feeds) ;;*) fail COMMAND;;esac
if [ "$ACTION" != install-adapter ] && ! exists "$ROOT";then fail NOT_INSTALLED;fi
if ! exists "$BASE";then mkdir -m 700 "$BASE";printf '%s\n' zte-imei-apps-v1 > "$BASE/.zte-imei-owner";fi
if ! exists "$ROOT";then mkdir -m 700 "$ROOT" "$GEN";printf 'zte-private-opkg-v1:%s\n' "$CID" > "$ROOT/owner";printf 'active=none\nprevious=unset\n' > "$ROOT/state";fi
private "$ROOT";if exists "$ROOT/lock";then plain "$ROOT/lock";fi
exec 9>>"$ROOT/lock";flock -n 9 || fail BUSY
state;running;[ "$RUNNING" = 0 ] || fail TOOLS_RUNNING
check_cli
CAND=;CLI=;PUBLISHED=0
cleanup() {
 code=$?;trap - EXIT HUP INT TERM
 if [ -n "$CLI" ] && [ -f "$CLI" ] && [ ! -L "$CLI" ];then rm -f "$CLI";fi
 if [ -n "$CAND" ] && [ "$PUBLISHED" = 0 ];then
  state
  # An ambiguous post-rename failure must never delete a published generation.
  if [ "${CAND##*/}" != "$ACTIVE" ] && [ "${CAND##*/}" != "$PREVIOUS" ];then rm -rf "$CAND";fi
 fi
 exit "$code"
}
trap cleanup EXIT;trap 'exit 1' HUP INT TERM
case "$ACTION:${COMMAND-}" in install-adapter:*|remove-adapter:*|rollback:*|execute:update|execute:install|execute:remove) prepare_cli;;esac
case "$ACTION" in
install-adapter)
 [ "$#" = 3 ] || fail ARGUMENTS
 STAGE=$1;ARCHIVE=$2;MANIFEST=$3
 [ "$ACTIVE" = none ] || { printf 'Адаптер уже установлен.\n';publish_cli;report;exit 0; }
 case "$STAGE" in /tmp/zte-opkg-*) ;; *) fail STAGE;;esac
 private "$STAGE";plain "$STAGE/runtime.tar.gz"
 [ "$(sha "$STAGE/runtime.tar.gz")" = "$ARCHIVE" ] || fail ARCHIVE_HASH
 make_candidate
 tar -xzf "$STAGE/runtime.tar.gz" -C "$SANDBOX"
 [ "$(sha "$SANDBOX/RUNTIME.sha256")" = "$MANIFEST" ] || fail RUNTIME_MANIFEST
 (cd "$SANDBOX" && sha256sum -c RUNTIME.sha256 >/dev/null) || fail RUNTIME_HASH
 mkdir -p "$SANDBOX/tmp" "$SANDBOX/var/lock" "$SANDBOX/dev" "$SANDBOX/packages/lib" "$SANDBOX/packages/usr/lib/opkg/info" "$SANDBOX/packages/var/opkg-lists" "$SANDBOX/packages/var/lock"
 mknod -m 600 "$SANDBOX/dev/null" c 1 3;mknod -m 600 "$SANDBOX/dev/urandom" c 1 9
 cp "$SANDBOX/lib/libc.so" "$SANDBOX/packages/lib/libc.so";cp "$SANDBOX/lib/libc.so" "$SANDBOX/packages/lib/ld-musl-aarch64.so.1"
 printf 'Package: zte-private-musl\nVersion: 1.2.5\nProvides: libc, libpthread\nArchitecture: aarch64_cortex-a53\nStatus: install ok installed\nEssential: yes\nDescription: Private bundled musl runtime\n\n' > "$SANDBOX/packages/usr/lib/opkg/status"
 printf '/packages/lib/libc.so\n/packages/lib/ld-musl-aarch64.so.1\n' > "$SANDBOX/packages/usr/lib/opkg/info/zte-private-musl.list"
 if [ -f /etc/resolv.conf ];then cp -L /etc/resolv.conf "$SANDBOX/etc/resolv.conf";fi
 inventory "$SANDBOX" runtime > "$CAND/runtime.inventory" || fail RUNTIME_INVENTORY
 invoke --version || fail RUNTIME_SELF_TEST
 audit_packages;manifest
 commit;PUBLISHED=1;publish_cli
 printf 'Изолированный opkg установлен. Выполните update для загрузки подписанного каталога.\n'
 ;;
remove-adapter)
 [ "$#" = 0 ] || fail ARGUMENTS
 [ "$ACTIVE" != none ] || { report;exit 0; }
 NEW=none;commit;publish_cli;printf 'Адаптер отключён; предыдущая приватная среда сохранена для отката.\n'
 ;;
rollback)
 [ "$#" = 0 ] && [ "$PREVIOUS" != unset ] || fail NO_ROLLBACK
 NEW=$PREVIOUS;[ "$NEW" = none ] || verify_generation "$NEW"
 commit;publish_cli;printf 'Предыдущая среда opkg восстановлена.\n'
 ;;
save-feeds)
 [ "$#" = 3 ] || fail ARGUMENTS
 FEED_STAGE=$1;FEED_HASH=$2;EXPECTED=$3
 [ "$ACTIVE" != none ] || fail NOT_INSTALLED
 [ "$ACTIVE" = "$EXPECTED" ] || fail FEEDS_STALE
 case "$FEED_STAGE" in /tmp/zte-opkg-*) ;;*) fail STAGE;;esac
 private "$FEED_STAGE";plain "$FEED_STAGE/feeds.txt"
 [ "$(sha "$FEED_STAGE/feeds.txt")" = "$FEED_HASH" ] || fail FEEDS_HASH
 sources=$(normalize_feeds "$FEED_STAGE/feeds.txt")
 verify_generation "$ACTIVE"
 old_sources=$(configured_feeds "$GEN/$ACTIVE/sandbox/etc/opkg.conf")
 if [ "$sources" = "$old_sources" ];then printf 'Источники opkg не изменились.\n';report;exit 0;fi
 prepare_cli
 make_candidate
 # Only this fixed file is edited. Package writes still cannot alter runtime.
 printf 'dest root /\nlists_dir ext /var/opkg-lists\narch all 1\narch aarch64_cortex-a53 10\noption check_signature 1\noption verify_program /usr/sbin/opkg-key\n' > "$SANDBOX/etc/opkg.conf"
 if [ -n "$sources" ];then printf '%s\n' "$sources" >> "$SANDBOX/etc/opkg.conf";fi
 rm -rf "$SANDBOX/packages/var/opkg-lists";mkdir -m 700 "$SANDBOX/packages/var/opkg-lists"
 inventory "$SANDBOX" runtime > "$CAND/runtime.inventory" || fail RUNTIME_INVENTORY
 audit_packages;manifest;commit;PUBLISHED=1;publish_cli
 printf 'Источники opkg сохранены; кэш индексов очищен. Выполните update для проверки подписей и загрузки каталога.\n'
 ;;

execute)
 [ "$ACTIVE" != none ] || fail NOT_INSTALLED
 verify_generation "$ACTIVE"
 case "$COMMAND" in update|install|remove)
  make_candidate
  if [ "$COMMAND" = install ];then verify_indexes;fi
  invoke "$@" || fail OPKG_COMMAND_FAILED
  if [ "$COMMAND" = update ];then verify_indexes;fi
  audit_packages;manifest;commit;PUBLISHED=1;publish_cli
  ;;
 *) make_candidate;invoke "$@" || fail OPKG_COMMAND_FAILED;;
 esac
 ;;
*) fail COMMAND;;
esac
report
