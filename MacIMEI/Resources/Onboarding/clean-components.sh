#!/bin/sh
# Post-preparation cleanup. Originals are moved into a retained private recovery
# directory only after the host verifies a downloaded archive. Never touches SSH,
# agent credentials, installation journals, prior backups or OEM /data content.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
action=${1:-}; tx=${2:-}; uuid=${3:-}; cid=${4:-}; boot=${5:-}; fw=${6:-}; router=${7:-}; token=${8:-}; approved=${9:-}
fail() { printf 'CLEAN_ERROR %s\n' "$1" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
hash() { result=$(sha256sum "$1") || return 1; printf '%s\n' "${result%% *}"; }
hex() { case "$1" in ''|*[!0-9a-f]*) return 1;; esac; [ "${#1}" = "$2" ]; }
uuid_valid() { [ "${#1}" = 36 ] && printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'; }
# Protected root700 component/transaction ancestors carry the access boundary;
# copied OEM backups legitimately retain 0606/0666 modes. Do not chmod them.
plain() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%h "$1")" = 0:1 ]; }
oem_plain() { plain "$1"; }
safe_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 1; perm=$(stat -c %a "$1"); [ "$((0$perm & 022))" = 0 ]; }
private_dir() { safe_dir "$1" && [ "$(stat -c %a "$1")" = 700 ]; }
identity() {
 [ "$(id -u)" = 0 ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || fail PLATFORM
 [ "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" ] && [ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || fail IDENTITY
 [ "$(hash /firmware/image/modem.b16)" = "$fw" ] && [ "$(hash /usr/bin/diag-router)" = "$router" ] || fail IDENTITY
}
case "$action" in prepare|status|stream|clean) ;; *) exit 64;; esac
uuid_valid "$uuid" && uuid_valid "$boot" && uuid_valid "$token" && hex "$cid" 32 && hex "$fw" 64 && hex "$router" 64 || exit 64
[ "$tx" = "/data/zte-imei-studio/cleanup-$uuid" ] || exit 64
identity
for d in /data /etc /etc/init.d /etc/rc.d /etc/config; do safe_dir "$d" || fail LAYOUT; done
private_dir /data/zte-imei-studio || fail LAYOUT
owner=$(printf '%s\n%s\n%s\n%s\n%s' "$uuid" "$cid" "$boot" "$fw" "$router")
lock=/tmp/zte-imei-app.lock
if [ "$action" != stream ]; then
 mkdir "$lock" 2>/dev/null || fail BUSY
 printf '%s\n' "$token" > "$lock/owner"
 unlock() { if private_dir "$lock" && plain "$lock/owner" && [ "$(cat "$lock/owner")" = "$token" ]; then rm "$lock/owner"; rmdir "$lock"; fi; }
 trap unlock EXIT
 trap 'exit 1' HUP INT TERM
fi
verify_tx() {
 private_dir "$tx" && plain "$tx/owner" && [ "$(cat "$tx/owner")" = "$owner" ] || fail TRANSACTION
 for name in phase phase.new roots before.manifest recheck.manifest components.tar components.tar.new archive.sha256 archive.bytes vpn-mode tar.log scan.list scan.sorted digest.list digest.sorted digest.records moves moves.new rc.local.cleaned network.restored; do
  if exists "$tx/$name"; then plain "$tx/$name" || fail TRANSACTION; fi
 done
 if exists "$tx/retained"; then private_dir "$tx/retained" || fail TRANSACTION; fi
}
receipt() {
 plain "$tx/components.tar" && plain "$tx/archive.sha256" && plain "$tx/archive.bytes" || fail ARCHIVE
 archive_sha=$(cat "$tx/archive.sha256"); archive_bytes=$(cat "$tx/archive.bytes")
 hex "$archive_sha" 64 || fail ARCHIVE
 case "$archive_bytes" in ''|*[!0-9]*) fail ARCHIVE;; esac
 [ "$archive_bytes" -gt 0 ] && [ "$(wc -c < "$tx/components.tar" | tr -d ' ')" = "$archive_bytes" ] && [ "$(hash "$tx/components.tar")" = "$archive_sha" ] || fail ARCHIVE
}
# Moving is resumable without re-running service stops or UCI restoration.
move_digest() {
 dir=$1
 (cd "$(dirname "$dir")"; find "$(basename "$dir")" -print) > "$tx/digest.list" || return 1
 sort "$tx/digest.list" > "$tx/digest.sorted" || return 1
 (cd "$(dirname "$dir")"
  while IFS= read -r f; do
   rel=${f#*/}; [ "$rel" != "$f" ] || rel=.
   if [ -L "$f" ]; then target=$(readlink "$f") || exit 1; printf 'L %s %s\n' "$rel" "$target"
   elif [ -d "$f" ]; then mode=$(stat -c %u:%a "$f") || exit 1; printf 'D %s %s\n' "$rel" "$mode"
   else plain "$f" || exit 1; mode=$(stat -c %u:%a:%h "$f") || exit 1; value=$(hash "$f") || exit 1; hex "$value" 64 || exit 1; printf 'F %s %s %s\n' "$rel" "$mode" "$value"; fi
  done < "$tx/digest.sorted") > "$tx/digest.records" || return 1
 value=$(hash "$tx/digest.records") || return 1; hex "$value" 64 || return 1; printf '%s\n' "$value"
}

verify_moves() {
 plain "$tx/moves" && private_dir "$tx/retained" || fail TRANSACTION
 awk 'NF!=2 || length($1)!=64 || $1~/[^0-9a-f]/ || seen[$2]++ {bad=1} END{exit bad}' "$tx/moves" || fail TRANSACTION
 # Each planned path is fixed and each source/destination is checked before
 # the first rename, including when resuming after a lost SSH response.
 while read -r expected p; do
  case "$p" in /data/zte-vpn|/data/zte-launcher|/data/zte-dashboard-runtime|/data/zte-agent-installer|/etc/init.d/zte_vpn|/etc/init.d/zte_launcher|/etc/rc.d/S99zte_vpn|/etc/rc.d/K01zte_vpn|/etc/rc.d/S99zte_launcher|/etc/rc.d/K01zte_launcher) ;; *) fail TRANSACTION;; esac
  hex "$expected" 64 || fail TRANSACTION
  dest=$tx/retained/$(printf '%s' "${p#/}" | tr / _)
  if exists "$p"; then ! exists "$dest" || fail CHANGED; chosen=$p
  else exists "$dest" || fail CHANGED; chosen=$dest; fi
  # Rename changes basename; digest uses contents and metadata, no root name.
  [ "$(move_digest "$chosen")" = "$expected" ] || fail CHANGED
 done < "$tx/moves"
}
complete_proof() {
 verify_moves
 for p in /data/zte-vpn /data/zte-launcher /data/zte-dashboard-runtime /data/zte-agent-installer /etc/init.d/zte_vpn /etc/init.d/zte_launcher /etc/rc.d/S99zte_vpn /etc/rc.d/K01zte_vpn /etc/rc.d/S99zte_launcher /etc/rc.d/K01zte_launcher; do
  ! exists "$p" || fail CHANGED
 done
}
finish_moves() {
 verify_moves
 while read -r expected p; do
  if exists "$p"; then mv "$p" "$tx/retained/$(printf '%s' "${p#/}" | tr / _)"; fi
 done < "$tx/moves"
 complete_proof
 setphase complete
 echo CLEAN_COMPLETE
}
if exists "$tx"; then verify_tx; fi
if [ "$action" = status ]; then
 if ! exists "$tx"; then echo CLEAN_ABSENT; exit; fi
 if ! plain "$tx/phase"; then echo CLEAN_INCOMPLETE; exit; fi
 phase=$(cat "$tx/phase")
 case "$phase" in complete) receipt; complete_proof; echo CLEAN_COMPLETE;; prepared|moving|stopping) receipt; if [ "$phase" = prepared ]; then echo "CLEAN_PREPARED $archive_sha $archive_bytes"; else echo "CLEAN_PENDING $archive_sha $archive_bytes"; fi;; preparing) echo CLEAN_INCOMPLETE;; *) fail RECOVERY_REQUIRED;; esac
 exit
fi
if [ "$action" = stream ]; then
 verify_tx; receipt
 cat "$tx/components.tar"
 printf 'BACKUP_RESULT sha256=%s bytes=%s\n' "$archive_sha" "$archive_bytes" >&2
 exit
fi
owned_roots='/data/zte-vpn /data/zte-launcher /data/zte-dashboard-runtime /data/zte-agent-installer'
check_root() {
 p=$1; label=$2
 if exists "$p"; then
  private_dir "$p" && plain "$p/owner" && [ "$(cat "$p/owner")" = "$label" ] || fail OWNER
  case "$p" in /data/zte-vpn|/data/zte-launcher) plain "$p/cid" && [ "$(cat "$p/cid")" = "$cid" ] || fail IDENTITY;;
   *) if exists "$p/cid"; then plain "$p/cid" && [ "$(cat "$p/cid")" = "$cid" ] || fail IDENTITY; fi;; esac
 fi
}
check_service() {
 p=$1; expected=$2
 if exists "$p"; then plain "$p" && [ "$(hash "$p")" = "$expected" ] || fail SERVICE; perm=$(stat -c %a "$p"); [ "$((0$perm & 022))" = 0 ] || fail SERVICE; fi
}
launcher_service_sha=e0d5c80f061af69a8a7329476e33e6b4766a80b37a9a38e3d3217712551b4e90
vpn_service_sha=3411d076729a717024d50ae8feb0777acf7ab792bb3878cb16ab7b282cbde63a
stock_sha=093e5461be5ea5d23d24522374a27b9a134c4932df3c89b3b756274f123ac508
configure_sha=a41e5de83268c6963a54760c8b5f5362ea2c5cdac81bede6ac281fea81e28543
firewall_sha=6fd50b7d16b93a6d0964dfd937c328eb93273fdab42204e2edf5bb72b7ea0da3
dashboard_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
validate_components() {
 check_root /data/zte-vpn zte-vpn-v1
 check_root /data/zte-launcher zte-native-launcher-v1
 check_root /data/zte-dashboard-runtime zte-dashboard-runtime-v1
 check_root /data/zte-agent-installer zte-agent-installer-v1
 for p in /data/zte-launcher-update /data/zte-vpn/controller-upgrade /data/zte-vpn/transaction /data/zte-vpn/transaction.preparing /data/zte-vpn/transaction.done /data/zte-agent-installer/pending /data/zte-dashboard-runtime/installer/lock /data/local/tmp/open-u60-transactions/active; do exists "$p" && fail PENDING; done
 if [ -d /data/zte-launcher ]; then
  plain /etc/init.d/zte_topsw_devui || fail SERVICE
  case "$(hash /etc/init.d/zte_topsw_devui)" in a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35|0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50) ;; *) fail SERVICE;; esac
  cfg=$(ubus call service list '{"name":"zte_topsw_devui"}') || fail SERVICE
  ui_command=$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[0]') || fail SERVICE
  case "$ui_command" in /usr/bin/zte_topsw_devui) ;; /bin/sh)
   [ "$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[1]')" = /data/zte-launcher/launcher-run.sh ] || fail SERVICE;; *) fail SERVICE;; esac
 fi
 check_service /etc/init.d/zte_launcher "$launcher_service_sha"
 check_service /etc/init.d/zte_vpn "$vpn_service_sha"
 for n in S99zte_vpn K01zte_vpn S99zte_launcher K01zte_launcher; do
  p=/etc/rc.d/$n
  if exists "$p"; then
   case "$n" in *zte_vpn) name=zte_vpn;; *) name=zte_launcher;; esac
   [ -L "$p" ] && [ "$(readlink "$p")" = "../init.d/$name" ] || fail SERVICE
  fi
 done
 if exists /etc/init.d/zte_launcher; then private_dir /data/zte-launcher || fail OWNER; fi
 if exists /etc/init.d/zte_vpn; then private_dir /data/zte-vpn || fail OWNER; fi
 oem_plain /etc/rc.local || fail STARTUP
 sh -n /etc/rc.local || fail STARTUP
 # Only exact known lines are removed; noncanonical references require review.
 awk '/zte-launcher|zte-dashboard-runtime/ {if($0!="sh /data/zte-launcher/launcher-start.sh" && $0!="sh /data/zte-dashboard-runtime/start-dashboard.sh" && $0!~/^[ \t]*#/)exit 1}' /etc/rc.local || fail STARTUP
}
vpn_check() {
 vpn_mode=none
 [ -d /data/zte-vpn ] || return 0
 v=/data/zte-vpn
 for f in configure.lua firewall.sh; do plain "$v/$f" || fail VPN_INTEGRITY; done
 [ "$(hash "$v/configure.lua")" = "$configure_sha" ] && [ "$(hash "$v/firewall.sh")" = "$firewall_sha" ] || fail VPN_INTEGRITY
 oem_plain /etc/init.d/network || fail VPN_NETWORK
 if [ "$(hash /etc/init.d/network)" = "$stock_sha" ]; then
  # A reset may leave stale private markers but must not leave live owned UCI.
  lua - <<'LUA' >/dev/null 2>&1 || fail VPN_CONFIGURATION
local c=require('uci').cursor('/etc/config','/tmp/zte-clean-unused-deltas')
assert(c:load('network') and c:load('wireless') and c:load('firewall'))
assert(not c:get_all('network','vpn') and not c:get_all('network','br_vpn'))
assert(not c:get_all('firewall','zte_vpn_zone') and not c:get_all('firewall','zte_vpn_rules'))
for _,n in ipairs({'guest_2g','guest_5g'}) do assert(c:get('wireless',n)=='wifi-iface' and c:get('wireless',n,'network')~='vpn' and c:get('wireless',n,'bridge')~='br-vpn') end
LUA
  vpn_mode=stock; return 0
 fi
 plain "$v/configured" && plain "$v/network-init.sha256" && [ "$(cat "$v/network-init.sha256")" = "$(hash /etc/init.d/network)" ] || fail VPN_NETWORK
 private_dir "$v/backup" && plain "$v/backup/SHA256SUMS" && plain "$v/backup/network.init" && [ "$(hash "$v/backup/network.init")" = "$stock_sha" ] || fail VPN_BACKUP
 # Exactly the five known backup entries; no arbitrary manifest paths.
 awk 'NF!=2 || $2!~/^(network|wireless|firewall|dhcp|network.init)$/ || length($1)!=64 || $1~/[^0-9a-f]/ || seen[$2]++ {bad=1} END{exit bad||NR!=5}' "$v/backup/SHA256SUMS" || fail VPN_BACKUP
 (cd "$v/backup" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail VPN_BACKUP
 for pkg in network wireless firewall dhcp; do oem_plain "/etc/config/$pkg" || fail VPN_CONFIGURATION; [ -z "$(uci -q changes "$pkg")" ] || fail VPN_CONFIGURATION; done
 # Compare only owned sections against their exact original installer shapes.
 lua - <<'LUA' >/dev/null 2>&1 || fail VPN_CONFIGURATION
local c=require('uci').cursor('/etc/config','/tmp/zte-clean-unused-deltas')
local function section(pkg,name,kind,want)
 local got=c:get_all(pkg,name); assert(got and got['.type']==kind)
 for k,v in pairs(got) do if k:sub(1,1)~='.' then
  local w=want[k]; assert(w~=nil)
  if type(w)=='table' then assert(type(v)=='table' and #v==#w);for i,x in ipairs(w) do assert(v[i]==x) end else assert(v==w) end
 end end
 for k,v in pairs(want) do assert(got[k]~=nil) end
end
section('network','br_vpn','device',{name='br-vpn',type='bridge',ports={'wlan1','wlan3'},bridge_empty='1',ipv6='0'})
section('network','vpn','interface',{device='br-vpn',type='bridge',ifname='wlan1 wlan3',bridge_empty='1',force_link='1',proto='static',ipaddr='192.168.50.1',netmask='255.255.255.0',delegate='0'})
section('firewall','zte_vpn_zone','zone',{name='vpn',network={'vpn'},input='REJECT',output='ACCEPT',forward='REJECT'})
section('firewall','zte_vpn_rules','include',{type='script',path='/data/zte-vpn/firewall.sh',reload='1',enabled='1'})
for _,n in ipairs({'guest_2g','guest_5g'}) do assert(c:get('wireless',n)=='wifi-iface' and c:get('wireless',n,'network')=='vpn' and c:get('wireless',n,'bridge')=='br-vpn' and c:get('wireless',n,'disabled')=='1') end
local b=require('uci').cursor('/data/zte-vpn/backup','/data/zte-vpn/backup-deltas')
for _,n in ipairs({'guest_2g','guest_5g'}) do assert(b:get('wireless',n)=='wifi-iface' and b:get('wireless',n,'disabled')=='1') end
LUA
 vpn_mode=configured
}
# Fixed archive roots only. No caller-supplied path list is consumed.
list_roots() {
 for p in $owned_roots /etc/init.d/zte_vpn /etc/init.d/zte_launcher /etc/rc.d/S99zte_vpn /etc/rc.d/K01zte_vpn /etc/rc.d/S99zte_launcher /etc/rc.d/K01zte_launcher; do exists "$p" && printf '%s\n' "${p#/}"; done
 printf '%s\n' etc/rc.local
 if [ -d /data/zte-vpn ]; then for p in /etc/init.d/network /etc/config/network /etc/config/wireless /etc/config/firewall /etc/config/dhcp; do oem_plain "$p" || fail VPN_CONFIGURATION; printf '%s\n' "${p#/}"; done; fi
}
# Validate every entry before archiving/moving. Only internal relative symlinks
# are allowed in owned trees; service links have a fixed separately checked form.
manifest() {
 : > "$tx/scan.list"
 while IFS= read -r rel; do
  p=/$rel
  if [ -d "$p" ] && [ ! -L "$p" ]; then find "$p" -xdev -print >> "$tx/scan.list" || return 1; else printf '%s\n' "$p" >> "$tx/scan.list"; fi
 done < "$tx/roots"
 sort -u "$tx/scan.list" > "$tx/scan.sorted" || return 1
 while IFS= read -r p; do
  case "$p" in *'\'*|*'	'*|*'
'*) fail PATH;; esac
  [ "$(stat -c %u "$p")" = 0 ] || fail OWNER
  if [ -L "$p" ]; then
   target=$(readlink "$p") || return 1
   case "$p" in /etc/rc.d/*) ;;
    /data/zte-dashboard-runtime/current|/data/zte-dashboard-runtime/previous)
     case "$target" in /data/www|/data/open-u60-dashboards/*|/data/zte-dashboard-runtime/dashboards/*|dashboards/*) case "$target" in *..*) fail SYMLINK;; esac;; *) fail SYMLINK;; esac;;
    *) case "$target" in /*|*..*) fail SYMLINK;; esac
     resolved=$(readlink -f "$p") || fail SYMLINK
     case "$resolved" in /data/zte-dashboard-runtime/*|/data/zte-launcher/*|/data/zte-vpn/*|/data/zte-agent-installer/*) ;; *) fail SYMLINK;; esac;; esac
   printf 'L\t%s\t%s\n' "$target" "$p"
  elif [ -d "$p" ]; then [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] || fail OWNER; mode=$(stat -c %a "$p") || return 1; printf 'D\t%s\t%s\n' "$mode" "$p"
  else
   case "$p" in /etc/rc.local|/etc/init.d/network|/etc/config/network|/etc/config/wireless|/etc/config/firewall|/etc/config/dhcp) oem_plain "$p" || fail OWNER;; *) plain "$p" || fail OWNER;; esac
   mode=$(stat -c %a "$p") || return 1; value=$(hash "$p") || return 1; hex "$value" 64 || return 1; printf 'F\t%s\t%s\t%s\n' "$mode" "$value" "$p"; fi
 done < "$tx/scan.sorted"
}

setphase() { printf '%s\n' "$1" > "$tx/phase.new"; mv "$tx/phase.new" "$tx/phase"; sync; }
if [ "$action" = prepare ]; then
 if exists "$tx" && plain "$tx/phase"; then
  case "$(cat "$tx/phase")" in prepared|moving|stopping) receipt; echo "CLEAN_PREPARED $archive_sha $archive_bytes"; exit;; complete) receipt; complete_proof; echo CLEAN_COMPLETE; exit;; preparing) :;; *) fail RECOVERY_REQUIRED;; esac
 fi
 validate_components; vpn_check
 for d in $owned_roots; do
  # A nested mount must never become an omitted part of the archive.
  awk -v p="$d" '$2==p || index($2,p"/")==1 {bad=1} END{exit bad}' /proc/mounts || fail MOUNT
 done
 if ! exists "$tx"; then mkdir "$tx"; printf '%s\n' "$owner" > "$tx/owner"; fi
 # A failed snapshot never changed source files; overwrite only fixed private
 # producer outputs, never an unknown file or a symlink.
 for name in roots before.manifest recheck.manifest components.tar.new components.tar archive.sha256 archive.bytes vpn-mode tar.log phase.new; do
  if exists "$tx/$name"; then plain "$tx/$name" || fail TRANSACTION; fi
 done
 setphase preparing
 list_roots > "$tx/roots"
 manifest > "$tx/before.manifest" || fail SNAPSHOT
 tar -C / -cf "$tx/components.tar.new" -T "$tx/roots" 2> "$tx/tar.log" || fail ARCHIVE
 manifest > "$tx/recheck.manifest" || fail SNAPSHOT
 cmp -s "$tx/before.manifest" "$tx/recheck.manifest" || fail CHANGED
 mv "$tx/components.tar.new" "$tx/components.tar"
 hash "$tx/components.tar" > "$tx/archive.sha256"
 wc -c < "$tx/components.tar" | tr -d ' ' > "$tx/archive.bytes"
 printf '%s\n' "$vpn_mode" > "$tx/vpn-mode"
 if exists "$tx/retained"; then private_dir "$tx/retained" && [ -z "$(ls -A "$tx/retained")" ] || fail TRANSACTION; else mkdir "$tx/retained"; fi
 setphase prepared
 receipt; echo "CLEAN_PREPARED $archive_sha $archive_bytes"; exit
fi
verify_tx; receipt
hex "$approved" 64 && [ "$approved" = "$archive_sha" ] || fail BACKUP_NOT_VERIFIED
phase=$(cat "$tx/phase")
[ "$phase" != complete ] || { complete_proof; echo CLEAN_COMPLETE; exit; }
if [ "$phase" = moving ]; then finish_moves; exit; fi
[ "$phase" = prepared ] || [ "$phase" = stopping ] || fail RECOVERY_REQUIRED
validate_components; vpn_check
manifest > "$tx/recheck.manifest" || fail SNAPSHOT
cmp -s "$tx/before.manifest" "$tx/recheck.manifest" || fail CHANGED
identity
# No mutation above this line beyond private transaction/lock files. The caller
# has now confirmed a byte-verified, private local archive.
setphase stopping
if exists /etc/init.d/zte_vpn; then /etc/init.d/zte_vpn stop >/dev/null 2>&1 || fail STOP; fi
if exists /etc/init.d/zte_launcher; then /etc/init.d/zte_launcher stop >/dev/null 2>&1 || fail STOP; fi
# Stop only the pinned dashboard executable. Keep all SSH/agent processes alive.
for exe in /proc/[0-9]*/exe; do
 actual=$(readlink "$exe" 2>/dev/null || true)
 case "$actual" in /data/zte-dashboard-runtime/dashboard-uhttpd)
  [ "$(hash "$exe")" = "$dashboard_sha" ] || fail PROCESS
  pid=${exe#/proc/}; pid=${pid%/exe}; start=$(awk '{print $22}' "/proc/$pid/stat")
  [ "$(readlink "$exe")" = "$actual" ] && [ "$(hash "$exe")" = "$dashboard_sha" ] && [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" ] || fail PROCESS
  kill "$pid" || fail STOP;;
 esac
done
# Services must have stopped before their executable trees move.
n=0
while :; do
 running=0
 for proc in /proc/[0-9]*; do
  actual=$(readlink "$proc/exe" 2>/dev/null || true)
  case "$actual" in /data/zte-vpn/*|/data/zte-dashboard-runtime/*) running=1;; esac
  if [ -r "$proc/cmdline" ]; then case "$(tr '\000' ' ' < "$proc/cmdline")" in *'/data/zte-vpn/manager.sh '*|*'/data/zte-launcher/launcher-watch.sh'*) running=1;; esac; fi
 done
 [ "$running" = 0 ] && break
 n=$((n+1)); [ "$n" -lt 10 ] || fail STOP; sleep 1
done
if [ -d /data/zte-launcher ]; then
 /etc/init.d/zte_topsw_devui restart >/dev/null 2>&1 || fail STOP
 n=0
 while :; do
  cfg=$(ubus call service list '{"name":"zte_topsw_devui"}') || fail STOP
  ui_command=$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[0]') || fail STOP
  ui_pid=$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.pid') || fail STOP
  case "$ui_pid" in ''|0|*[!0-9]*) ready=0;; *)
   ready=1
   [ "$ui_command" = /usr/bin/zte_topsw_devui ] && [ "$(readlink "/proc/$ui_pid/exe" 2>/dev/null)" = /usr/bin/zte_topsw_devui ] || ready=0
   [ -r "/proc/$ui_pid/maps" ] && ! grep -qF /data/zte-launcher/launcher.so "/proc/$ui_pid/maps" || ready=0;; esac
  [ "$ready" = 1 ] && break
  n=$((n+1)); [ "$n" -lt 10 ] || fail STOP; sleep 1
 done
fi
# Service shutdown may take time. Recheck the archived OEM files immediately
# before the first configuration/startup write; do not overwrite a newer change.
for p in /etc/rc.local /etc/init.d/network /etc/config/network /etc/config/wireless /etc/config/firewall /etc/config/dhcp; do
 expected=$(awk -F '	' -v p="$p" '$1=="F" && $4==p {print $3}' "$tx/before.manifest")
 if [ -n "$expected" ]; then oem_plain "$p" && [ "$(hash "$p")" = "$expected" ] || fail CHANGED; fi
done
setphase changing
if [ "$vpn_mode" = configured ]; then
 lua /data/zte-vpn/configure.lua restore >/dev/null 2>&1 || fail VPN_RESTORE
 sh /data/zte-vpn/firewall.sh remove >/dev/null 2>&1 || fail VPN_RESTORE
 cp -p /data/zte-vpn/backup/network.init "$tx/network.restored"
 [ "$(hash "$tx/network.restored")" = "$stock_sha" ] || fail VPN_RESTORE
 mv "$tx/network.restored" /etc/init.d/network
 for key in network.vpn network.br_vpn firewall.zte_vpn_zone firewall.zte_vpn_rules; do [ -z "$(uci -q get "$key" 2>/dev/null || true)" ] || fail VPN_RESTORE; done
 # Apply the verified inverse to the live network too. Without reload the old
 # br-vpn address/route survives the UCI change and conflicts with a fresh setup.
 ubus -t 30 call network reload '{}' >/dev/null || fail VPN_RESTORE
 n=0
 while :; do
  addresses=
  if [ -d /sys/class/net/br-vpn ]; then
   addresses=$(ip -4 addr show dev br-vpn) || fail VPN_RESTORE
  fi
  routes=$(ip -4 route show table all) || fail VPN_RESTORE
  if ! printf '%s\n' "$addresses" | grep -Eq '(^|[[:space:]])inet[[:space:]]' &&
     ! printf '%s\n' "$routes" | grep -Eq '(^|[[:space:]])dev[[:space:]]+br-vpn([[:space:]]|$)'; then break; fi
  n=$((n+1)); [ "$n" -lt 20 ] || fail VPN_RESTORE; sleep 1
 done
fi
# Preserve every unrelated byte of rc.local, including SSH/agent startup lines.
awk -v lines="$(wc -l < /etc/rc.local)" '
 function keep(s) {return s!="sh /data/zte-launcher/launcher-start.sh" && s!="sh /data/zte-dashboard-runtime/start-dashboard.sh"}
 {if(NR>1 && keep(previous))printf "%s\n",previous; previous=$0}
 END {if(NR>0 && keep(previous)){printf "%s",previous;if(lines>=NR)printf "\n"}}
' /etc/rc.local > "$tx/rc.local.cleaned"
sh -n "$tx/rc.local.cleaned" || fail STARTUP
chmod "$(stat -c %a /etc/rc.local)" "$tx/rc.local.cleaned"
mv "$tx/rc.local.cleaned" /etc/rc.local
identity
# Keep removed components for recovery in addition to the downloaded tar.
: > "$tx/moves.new"
for p in /etc/rc.d/S99zte_vpn /etc/rc.d/K01zte_vpn /etc/rc.d/S99zte_launcher /etc/rc.d/K01zte_launcher /etc/init.d/zte_vpn /etc/init.d/zte_launcher $owned_roots; do
 if exists "$p"; then value=$(move_digest "$p") || fail SNAPSHOT; printf '%s %s\n' "$value" "$p" >> "$tx/moves.new"; fi
done
mv "$tx/moves.new" "$tx/moves"
setphase moving
finish_moves
