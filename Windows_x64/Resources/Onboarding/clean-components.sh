#!/bin/sh
# Post-preparation cleanup. Originals are moved into a retained private recovery
# directory only after the host verifies a downloaded archive. Never touches SSH,
# agent credentials, installation journals, prior backups or OEM /data content.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
action=${1:-}; tx=${2:-}; uuid=${3:-}; cid=${4:-}; boot=${5:-}; fw=${6:-}; router=${7:-}; token=${8:-}; approved=${9:-}; new_boot=${10:-}
fail() { reported_error=1; printf 'CLEAN_ERROR %s\n' "$1" >&2; exit 1; }
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
observed_file_matches() {
 cursor=${1%/*}
 while [ -n "$cursor" ]; do
  [ ! -L "$cursor" ] || return 1
  if [ -e "$cursor" ]; then [ -d "$cursor" ] && [ -r "$cursor" ] && [ -x "$cursor" ] || return 1; fi
  cursor=${cursor%/*}
 done
 if [ "$2" = absent ]; then ! exists "$1"
 else [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] && [ "$(hash "$1")" = "$2" ]; fi
}
identity() {
 [ "$(id -u)" = 0 ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || fail PLATFORM
 [ "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" ] && [ "$(cat /proc/sys/kernel/random/boot_id)" = "$effective_boot" ] || fail IDENTITY
 observed_file_matches /firmware/image/modem.b16 "$fw" && observed_file_matches /usr/bin/diag-router "$router" || fail IDENTITY
}
case "$action" in prepare|status|stream|clean|rebind) ;; *) exit 64;; esac
uuid_valid "$uuid" && uuid_valid "$boot" && uuid_valid "$token" && hex "$cid" 32 && { [ "$fw" = absent ] || hex "$fw" 64; } && { [ "$router" = absent ] || hex "$router" 64; } || exit 64
[ "$tx" = "/data/zte-imei-studio/cleanup-$uuid" ] || exit 64
for d in /data /etc /etc/init.d /etc/rc.d /etc/config; do safe_dir "$d" || fail LAYOUT; done
private_dir /data/zte-imei-studio || fail LAYOUT
owner=$(printf '%s\n%s\n%s\n%s\n%s' "$uuid" "$cid" "$boot" "$fw" "$router")
effective_boot=$boot
if [ "$action" = rebind ]; then
 uuid_valid "$new_boot" || exit 64
 effective_boot=$new_boot
elif exists "$tx/accepted-boot"; then
 private_dir "$tx" && plain "$tx/owner" && [ "$(cat "$tx/owner")" = "$owner" ] && plain "$tx/accepted-boot" || fail TRANSACTION
 effective_boot=$(cat "$tx/accepted-boot"); uuid_valid "$effective_boot" || fail TRANSACTION
fi
identity
clean_stage=LOCK
reported_error=0
lock=/tmp/zte-imei-app.lock
if [ "$action" = status ] && ! exists "$tx"; then echo CLEAN_ABSENT; exit; fi
if [ "$action" != stream ]; then
 # Publish complete private intent before acquiring the shared lock. A crash
 # while preparing the sibling leaves no invalid transaction at the fixed path.
 if ! exists "$tx"; then
  case "$action" in prepare|rebind) :;; *) fail TRANSACTION;; esac
  initializing=/data/zte-imei-studio/cleanup-init-$uuid-$token
  ! exists "$initializing" || fail TRANSACTION
  mkdir "$initializing"
  printf '%s\n' "$owner" > "$initializing/owner"
  printf '%s\n' "$token" > "$initializing/lock-token"
  mv -T "$initializing" "$tx" || fail TRANSACTION
 fi
 private_dir "$tx" && plain "$tx/owner" && [ "$(cat "$tx/owner")" = "$owner" ] || fail TRANSACTION
 intent=$tx/lock-intent-$token
 if exists "$intent"; then plain "$intent" && [ "$(cat "$intent")" = "$owner" ] || fail TRANSACTION
 else (set -C; printf '%s\n' "$owner" > "$intent") || fail TRANSACTION; fi
 unlock() { if private_dir "$lock" && plain "$lock/owner" && [ "$(cat "$lock/owner")" = "$token" ]; then
  if [ -d "$lock/probe" ] && [ ! -L "$lock/probe" ]; then rmdir "$lock/probe" || return 1; fi
  rm "$lock/owner"; rmdir "$lock"; fi; }
 finish() { result=$?; trap - EXIT HUP INT TERM; unlock || :; if [ "$result" != 0 ] && [ "$reported_error" = 0 ]; then printf 'CLEAN_ERROR %s\n' "$clean_stage" >&2; fi; exit "$result"; }
 trap finish EXIT
 trap 'exit 1' HUP INT TERM
 if ! mkdir "$lock" 2>/dev/null; then
  # Recover only a lock previously recorded by this exact cleanup journal.
  # Other application owners, missing journals and live matching processes
  # remain blockers. Move the stale marker into recovery storage, never delete.
  private_dir "$tx" && plain "$tx/owner" && [ "$(cat "$tx/owner")" = "$owner" ] &&
   plain "$tx/lock-token" && private_dir "$lock" && plain "$lock/owner" || fail BUSY
  old_lock=$(cat "$lock/owner")
  uuid_valid "$old_lock" || fail BUSY
  [ "$(cat "$tx/lock-token")" = "$old_lock" ] || { plain "$tx/lock-intent-$old_lock" && [ "$(cat "$tx/lock-intent-$old_lock")" = "$owner" ]; } || fail BUSY
  for entry in "$lock"/* "$lock"/.[!.]* "$lock"/..?*; do
   exists "$entry" || continue
   if [ "$entry" = "$lock/probe" ]; then private_dir "$entry" && [ -z "$(ls -A "$entry")" ] || fail BUSY
   else [ "$entry" = "$lock/owner" ] || fail BUSY; fi
  done
  for process_dir in /proc/[0-9]*; do
   exists "$process_dir" || continue
   proc="$process_dir/cmdline"
   if [ ! -r "$proc" ]; then ! exists "${proc%/cmdline}" || fail BUSY; continue; fi
   command_line=$(tr '\000' ' ' < "$proc" 2>/dev/null) || { ! exists "${proc%/cmdline}" || fail BUSY; continue; }
   case "$command_line" in *"$old_lock"*) fail BUSY;; esac
  done
  ! exists "$tx/retained-lock-$old_lock" && [ "$(cat "$lock/owner")" = "$old_lock" ] || fail BUSY
  mv "$lock" "$tx/retained-lock-$old_lock" || fail BUSY
  mkdir "$lock" 2>/dev/null || fail BUSY
 fi
 printf '%s\n' "$token" > "$lock/owner"
 if exists "$tx"; then
  private_dir "$tx" && plain "$tx/owner" && [ "$(cat "$tx/owner")" = "$owner" ] || fail TRANSACTION
  if exists "$tx/lock-token"; then plain "$tx/lock-token" || fail TRANSACTION; fi
  printf '%s\n' "$token" > "$tx/lock-token"
 fi
 mkdir "$lock/probe"
fi
verify_tx() {
 private_dir "$tx" && plain "$tx/owner" && [ "$(cat "$tx/owner")" = "$owner" ] || fail TRANSACTION
 for name in accepted-boot accepted-boot.new lock-token plan.ready plan.ready.new plan.scan stable.before stable.current phase phase.new roots before.manifest recheck.manifest components.tar components.tar.new archive.exclude archive.sha256 archive.bytes vpn-mode tar.log scan.list scan.sorted digest.list digest.sorted digest.records moves moves.new rc.local.cleaned network.restored; do
  if exists "$tx/$name"; then plain "$tx/$name" || fail TRANSACTION; fi
 done
 if exists "$tx/retained"; then private_dir "$tx/retained" || fail TRANSACTION; fi
 if exists "$tx/plan"; then
  private_dir "$tx/plan" || fail TRANSACTION
  find "$tx/plan" -print > "$tx/plan.scan"
  while IFS= read -r entry; do
   if [ -d "$entry" ]; then private_dir "$entry" || fail TRANSACTION; else plain "$entry" || fail TRANSACTION; fi
  done < "$tx/plan.scan"
 fi
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
  case "$p" in /data/zte-vpn|/data/zte-launcher|/data/zte-dashboard-runtime|/data/zte-agent-installer|/data/zte-launcher-update|/etc/init.d/zte_vpn|/etc/init.d/zte_launcher|/etc/rc.d/S99zte_vpn|/etc/rc.d/K01zte_vpn|/etc/rc.d/S99zte_launcher|/etc/rc.d/K01zte_launcher) ;; *) fail TRANSACTION;; esac
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
 for p in /data/zte-vpn /data/zte-launcher /data/zte-dashboard-runtime /data/zte-agent-installer /data/zte-launcher-update /etc/init.d/zte_vpn /etc/init.d/zte_launcher /etc/rc.d/S99zte_vpn /etc/rc.d/K01zte_vpn /etc/rc.d/S99zte_launcher /etc/rc.d/K01zte_launcher; do
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
 case "$phase" in complete) receipt; complete_proof; echo CLEAN_COMPLETE;; prepared|moving|stopping|changing) receipt; if [ "$phase" = prepared ]; then echo "CLEAN_PREPARED $archive_sha $archive_bytes"; else echo "CLEAN_PENDING $archive_sha $archive_bytes"; fi;; preparing) echo CLEAN_INCOMPLETE;; *) fail RECOVERY_REQUIRED;; esac
 exit
fi
if [ "$action" = stream ]; then
 verify_tx; receipt
 cat "$tx/components.tar"
 printf 'BACKUP_RESULT sha256=%s bytes=%s\n' "$archive_sha" "$archive_bytes" >&2
 exit
fi
owned_roots='/data/zte-vpn /data/zte-launcher /data/zte-dashboard-runtime /data/zte-agent-installer /data/zte-launcher-update'
check_root() {
 p=$1; label=$2
 if exists "$p"; then
  safe_dir "$p" && plain "$p/owner" && [ "$(cat "$p/owner")" = "$label" ] || fail OWNER
  case "$p" in /data/zte-vpn|/data/zte-launcher) plain "$p/cid" && [ "$(cat "$p/cid")" = "$cid" ] || fail IDENTITY;;
   *) if exists "$p/cid"; then plain "$p/cid" && [ "$(cat "$p/cid")" = "$cid" ] || fail IDENTITY; fi;; esac
 fi
}
# Reviewed release payloads only. tools/check_cleanup_compatibility.py prevents
# a release from shipping runtime files which its own cleaner cannot handle.
known_payload() {
 case "$1:$2" in
  vpn-service:3411d076729a717024d50ae8feb0777acf7ab792bb3878cb16ab7b282cbde63a|vpn-service:a171e7764a2355b2ff86c0c0f87385f9029cddf92c5d1a2f8dd417f6f58b2af9) return 0;;
  manager:f2cdcb76dca87cfe873374d5a7be83a6440a46042a0ef26a4586f803dac99075|manager:f836b522c48a115c75233594207191214459f624180b7f98fabb754517d695b1|manager:ef5989252bbcdea112f793234827105e320cb9e8fdfd1fd699e63b33833fa94c|manager:f4c6145fb08b13ff6e9b68caa399beee373e7c6daba2a4648b4ee70eeb1958a0) return 0;;
  firewall:6fd50b7d16b93a6d0964dfd937c328eb93273fdab42204e2edf5bb72b7ea0da3|firewall:7d8ce304153612d4097c78738aa0f23c5cc420060b76a48c26dd668ac2657c99|firewall:91a8bc05543e34916e37dfa0b0ccc9394c102c2e0f13d590340bc5de3646848d) return 0;;
  configure:a41e5de83268c6963a54760c8b5f5362ea2c5cdac81bede6ac281fea81e28543|configure:0c392c8302d83ef4a12ed5669092f95637b7d3c5153677a9525642d8601575e8) return 0;;
  ikev2:7ca9acbcac8cac4124769917d9c8a8528f27a675e48338437d4c9cd41cc3c5c0) return 0;;
  launcher-service:e0d5c80f061af69a8a7329476e33e6b4766a80b37a9a38e3d3217712551b4e90) return 0;;
  *) return 1;;
 esac
}
checked_payload() {
 plain "$1" && known_payload "$2" "$(hash "$1")" || return 1
 # Installed programs may be executed only while untrusted users cannot edit
 # them, including when a historical component root is 0750/0755.
 perm=$(stat -c %a "$1"); [ "$((0$perm & 022))" = 0 ]
}
check_service() {
 if exists "$1"; then checked_payload "$1" "$2" || fail SERVICE; perm=$(stat -c %a "$1"); [ "$((0$perm & 022))" = 0 ] || fail SERVICE; fi
}
stock_sha=093e5461be5ea5d23d24522374a27b9a134c4932df3c89b3b756274f123ac508
dashboard_sha=76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12
validate_components() {
 check_root /data/zte-vpn zte-vpn-v1
 check_root /data/zte-launcher zte-native-launcher-v1
 check_root /data/zte-dashboard-runtime zte-dashboard-runtime-v1
 check_root /data/zte-agent-installer zte-agent-installer-v1
 for p in /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing; do exists "$p" && fail PENDING_FOREIGN; done
 for process_dir in /proc/[0-9]*; do
  exists "$process_dir" || continue
  proc="$process_dir/cmdline"
  if [ ! -r "$proc" ]; then ! exists "${proc%/cmdline}" || fail PENDING_LIVE; continue; fi
  command_line=$(tr '\000' ' ' < "$proc" 2>/dev/null) || { ! exists "${proc%/cmdline}" || fail PENDING_LIVE; continue; }
  case "$command_line" in *'/install-launcher.sh '*|*'/upgrade-controller.sh '*|*'/dashboard-install.sh '*|*'/agent-manager.sh '*|*'/zte-agent-stage-'*'/manager.sh '*) fail PENDING_LIVE;; esac
 done
 for p in /data/zte-vpn/controller-upgrade /data/zte-vpn/transaction /data/zte-vpn/transaction.preparing /data/zte-vpn/transaction.done /data/zte-dashboard-runtime/installer/lock; do
  if exists "$p"; then private_dir "$p" || fail PENDING_OWNER; fi
 done
 # A host agent updater journal may also guard the still-running SSH/agent.
 # Only its explicit completed state may be archived; never guess from age.
 if exists /data/zte-agent-installer/pending; then
  plain /data/zte-agent-installer/pending && plain /data/zte-agent-installer/previous.sha256 || fail PENDING_AGENT
  value=$(cat /data/zte-agent-installer/pending)
  [ "$value" = restore ] || hex "$value" 64 || fail PENDING_AGENT
  previous=$(cat /data/zte-agent-installer/previous.sha256)
  if [ "$previous" = absent ]; then ! exists /data/zte-agent-installer/previous.bin || fail PENDING_AGENT
  else hex "$previous" 64 && plain /data/zte-agent-installer/previous.bin && [ "$(hash /data/zte-agent-installer/previous.bin)" = "$previous" ] || fail PENDING_AGENT; fi
 fi
 if exists /data/zte-launcher-update; then
  check_root /data/zte-launcher-update zte-launcher-update-v1
  plain /data/zte-launcher-update/cid && [ "$(cat /data/zte-launcher-update/cid)" = "$cid" ] || fail IDENTITY
 fi
 if [ -d /data/zte-launcher ]; then
  plain /etc/init.d/zte_topsw_devui || fail SERVICE
  case "$(hash /etc/init.d/zte_topsw_devui)" in a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35|0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50) ;; *) fail SERVICE;; esac
  cfg=$(ubus call service list '{"name":"zte_topsw_devui"}') || fail SERVICE
  ui_command=$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[0]') || fail SERVICE
  case "$ui_command" in /usr/bin/zte_topsw_devui) ;; /bin/sh)
   [ "$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[1]')" = /data/zte-launcher/launcher-run.sh ] || fail SERVICE;; *) fail SERVICE;; esac
 fi
 check_service /etc/init.d/zte_launcher launcher-service
 check_service /etc/init.d/zte_vpn vpn-service
 for n in S99zte_vpn K01zte_vpn S99zte_launcher K01zte_launcher; do
  p=/etc/rc.d/$n
  if exists "$p"; then
   case "$n" in *zte_vpn) name=zte_vpn;; *) name=zte_launcher;; esac
   [ -L "$p" ] && [ "$(readlink "$p")" = "../init.d/$name" ] || fail SERVICE
  fi
 done
 if exists /etc/init.d/zte_launcher; then safe_dir /data/zte-launcher || fail OWNER; fi
 if exists /etc/init.d/zte_vpn; then safe_dir /data/zte-vpn || fail OWNER; fi
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
 checked_payload "$v/configure.lua" configure && checked_payload "$v/firewall.sh" firewall || fail VPN_INTEGRITY
 if exists "$v/ikev2"; then checked_payload "$v/ikev2.sh" ikev2 || fail VPN_INTEGRITY; fi
 if exists "$v/ipa-backup"; then
  checked_payload "$v/manager.sh" manager || fail VPN_INTEGRITY
  sh "$v/manager.sh" ipa-check >/dev/null 2>&1 || fail VPN_CONFIGURATION
 fi
 oem_plain /etc/init.d/network || fail VPN_NETWORK
 if ! grep -qF zte-vpn /etc/init.d/network; then
  # A reset may leave stale private markers but must not leave live owned UCI.
  lua - "$lock/probe" <<'LUA' >/dev/null 2>&1 || fail VPN_CONFIGURATION
local c=require('uci').cursor('/etc/config',arg[1])
assert(c:load('network') and c:load('wireless') and c:load('firewall'))
assert(not c:get_all('network','vpn') and not c:get_all('network','br_vpn'))
assert(not c:get_all('firewall','zte_vpn_zone') and not c:get_all('firewall','zte_vpn_rules'))
for _,n in ipairs({'guest_2g','guest_5g'}) do assert(c:get('wireless',n)=='wifi-iface' and c:get('wireless',n,'network')~='vpn' and c:get('wireless',n,'bridge')~='br-vpn') end
LUA
  vpn_mode=stock; return 0
 fi
 { plain "$v/configured" || plain "$v/configuring"; } && plain "$v/network-init.sha256" && [ "$(cat "$v/network-init.sha256")" = "$(hash /etc/init.d/network)" ] || fail VPN_NETWORK
 safe_dir "$v/backup" && plain "$v/backup/SHA256SUMS" && plain "$v/backup/network.init" || fail VPN_BACKUP
 sh -n "$v/backup/network.init" && ! grep -qF zte-vpn "$v/backup/network.init" || fail VPN_BACKUP
 # Exactly the five known backup entries; no arbitrary manifest paths.
 awk 'NF!=2 || $2!~/^(network|wireless|firewall|dhcp|network.init)$/ || length($1)!=64 || $1~/[^0-9a-f]/ || seen[$2]++ {bad=1} END{exit bad||NR!=5}' "$v/backup/SHA256SUMS" || fail VPN_BACKUP
 (cd "$v/backup" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail VPN_BACKUP
 for pkg in network wireless firewall dhcp; do oem_plain "/etc/config/$pkg" || fail VPN_CONFIGURATION; [ -z "$(uci -q changes "$pkg")" ] || fail VPN_CONFIGURATION; done
 # Compare only owned sections against their exact original installer shapes.
 lua - "$lock/probe" <<'LUA' >/dev/null 2>&1 || fail VPN_CONFIGURATION
local c=require('uci').cursor('/etc/config',arg[1])
local function section(pkg,name,kind,want)
 local got=c:get_all(pkg,name); if not got then return end;assert(got['.type']==kind)
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
local b=require('uci').cursor('/data/zte-vpn/backup',arg[1])
for _,n in ipairs({'guest_2g','guest_5g'}) do
 assert(c:get('wireless',n)=='wifi-iface' and b:get('wireless',n)=='wifi-iface' and b:get('wireless',n,'disabled')=='1')
 local net,bridge=c:get('wireless',n,'network'),c:get('wireless',n,'bridge')
 assert((net=='vpn' and bridge=='br-vpn') or (net==b:get('wireless',n,'network') and bridge==b:get('wireless',n,'bridge')))
 assert(c:get('wireless',n,'disabled')==nil or c:get('wireless',n,'disabled')=='0' or c:get('wireless',n,'disabled')=='1')
end
LUA
 vpn_mode=configured
}
# Fixed archive roots only. No caller-supplied path list is consumed.
list_roots() {
 for p in $owned_roots /etc/init.d/zte_vpn /etc/init.d/zte_launcher /etc/rc.d/S99zte_vpn /etc/rc.d/K01zte_vpn /etc/rc.d/S99zte_launcher /etc/rc.d/K01zte_launcher; do exists "$p" && printf '%s\n' "${p#/}"; done
 printf '%s\n' etc/rc.local
 if [ -d /data/zte-vpn ]; then for p in /etc/init.d/network /etc/config/network /etc/config/wireless /etc/config/firewall /etc/config/dhcp; do oem_plain "$p" || fail VPN_CONFIGURATION; printf '%s\n' "${p#/}"; done; fi
 if exists /data/zte-vpn/ipa-backup; then oem_plain /etc/config/zwrt_router || fail VPN_CONFIGURATION; printf '%s\n' etc/config/zwrt_router; fi
}
# Only these known runtime artifacts are excluded from the stable backup.
# Profile/configuration/certificate files and all backups remain included.
runtime_path() {
 case "$1" in
 /data/zte-vpn/actions.log|/data/zte-vpn/reload.log|/data/zte-vpn/core.log|/data/zte-vpn/core.previous.log|/data/zte-vpn/dns.log|/data/zte-vpn/dns.previous.log|/data/zte-vpn/firewall.log|/data/zte-vpn/core.pid|/data/zte-vpn/dns.pid|/data/zte-vpn/firewall.lock|/data/zte-vpn/firewall.backend|/data/zte-vpn/firewall-next.nft|/data/zte-vpn/runtime-disabled|/data/zte-vpn/ipa-runtime|/data/zte-vpn/ikev2/charon.pid|/data/zte-vpn/ikev2/charon.vici|/data/zte-vpn/ikev2/connected|/data/zte-vpn/ikev2/auth-state|/data/zte-vpn/ikev2/attempt-issued|/data/zte-vpn/ikev2/attempt-boot|/data/zte-vpn/ikev2/network-owned|/data/zte-vpn/ikev2/vip|/data/zte-vpn/ikev2/children|/data/zte-vpn/ikev2/children/*|/data/zte-vpn/ikev2/connected-check.*|/data/zte-vpn/cache.db|/data/zte-dashboard-runtime/dashboard.log|/data/zte-dashboard-runtime/dashboard.pid|/data/zte-launcher/failed) return 0;;
 *) return 1;; esac
}
runtime_exclusions() {
 cat <<'RUNTIME'
data/zte-vpn/actions.log
data/zte-vpn/reload.log
data/zte-vpn/core.log
data/zte-vpn/core.previous.log
data/zte-vpn/dns.log
data/zte-vpn/dns.previous.log
data/zte-vpn/firewall.log
data/zte-vpn/core.pid
data/zte-vpn/dns.pid
data/zte-vpn/firewall.lock
data/zte-vpn/firewall.backend
data/zte-vpn/firewall-next.nft
data/zte-vpn/runtime-disabled
data/zte-vpn/ipa-runtime
data/zte-vpn/ikev2/charon.pid
data/zte-vpn/ikev2/charon.vici
data/zte-vpn/ikev2/connected
data/zte-vpn/ikev2/auth-state
data/zte-vpn/ikev2/attempt-issued
data/zte-vpn/ikev2/attempt-boot
data/zte-vpn/ikev2/network-owned
data/zte-vpn/ikev2/vip
data/zte-vpn/ikev2/children
data/zte-vpn/ikev2/children/*
data/zte-vpn/ikev2/connected-check.*
data/zte-vpn/cache.db
data/zte-dashboard-runtime/dashboard.log
data/zte-dashboard-runtime/dashboard.pid
data/zte-launcher/failed
RUNTIME
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
  if runtime_path "$p"; then
   [ ! -L "$p" ] || fail SYMLINK
   if [ "$p" = /data/zte-vpn/ikev2/charon.vici ]; then [ -S "$p" ] || plain "$p" || fail OWNER
   elif [ -d "$p" ]; then safe_dir "$p" || fail OWNER
   else plain "$p" || fail OWNER; fi
   continue
  fi
  if [ -L "$p" ]; then
   target=$(readlink "$p") || return 1
   case "$p" in /etc/rc.d/*) ;;
    /data/zte-dashboard-runtime/current|/data/zte-dashboard-runtime/previous)
     case "$target" in /data/www|/data/open-u60-dashboards/*|/data/zte-dashboard-runtime/dashboards/*|dashboards/*) case "$target" in *..*) fail SYMLINK;; esac;; *) fail SYMLINK;; esac;;
    *) case "$target" in /*|*..*) fail SYMLINK;; esac
     resolved=$(readlink -f "$p") || fail SYMLINK
     case "$resolved" in /data/zte-dashboard-runtime/*|/data/zte-launcher/*|/data/zte-vpn/*|/data/zte-agent-installer/*|/data/zte-launcher-update/*) ;; *) fail SYMLINK;; esac;; esac
   printf 'L\t%s\t%s\n' "$target" "$p"
  elif [ -d "$p" ]; then [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ] || fail OWNER; mode=$(stat -c %a "$p") || return 1; printf 'D\t%s\t%s\n' "$mode" "$p"
  else
   case "$p" in /etc/rc.local|/etc/init.d/network|/etc/config/network|/etc/config/wireless|/etc/config/firewall|/etc/config/dhcp) oem_plain "$p" || fail OWNER;; *) plain "$p" || fail OWNER;; esac
   mode=$(stat -c %a "$p") || return 1; value=$(hash "$p") || return 1; hex "$value" 64 || return 1; printf 'F\t%s\t%s\t%s\n' "$mode" "$value" "$p"; fi
 done < "$tx/scan.sorted"
}

# Build the exact inverse from the already downloaded archive, never from a
# later live configuration. Every replacement keeps the original file mode.
archive_original() {
 rel=$1; dest=$2
 expected=$(awk -F '\t' -v p="/$rel" '$1=="F" && $4==p {print $3}' "$tx/before.manifest")
 mode=$(awk -F '\t' -v p="/$rel" '$1=="F" && $4==p {print $2}' "$tx/before.manifest")
 hex "$expected" 64 && [ -n "$mode" ] || fail TRANSACTION
 if ! exists "$dest"; then
  tar -xOf "$tx/components.tar" "$rel" > "$dest.new" || fail ARCHIVE
  [ "$(hash "$dest.new")" = "$expected" ] || fail ARCHIVE
  chmod "$mode" "$dest.new"; mv "$dest.new" "$dest"
 fi
 plain "$dest" && [ "$(hash "$dest")" = "$expected" ] || fail TRANSACTION
}
plan_inverse() {
 if exists "$tx/plan.ready"; then
  plain "$tx/plan.ready" && [ "$(cat "$tx/plan.ready")" = 1 ] || fail TRANSACTION
  awk 'NF!=2 || length($1)!=64 || $1~/[^0-9a-f]/ || $2!~/^(before|after)\/(rc.local|network|wireless|firewall|network.init)$/ && $2!="off/wireless" && $2!="backup/wireless" || seen[$2]++ {bad=1} END{exit bad || (NR!=2 && NR!=12)}' "$tx/plan/SHA256SUMS" || fail TRANSACTION
  (cd "$tx/plan" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail TRANSACTION
  return
 fi
 for d in "$tx/plan" "$tx/plan/before" "$tx/plan/after" "$tx/plan/off" "$tx/plan/backup" "$tx/plan/deltas" "$tx/plan/backup-deltas"; do
  if exists "$d"; then private_dir "$d" || fail TRANSACTION; else mkdir "$d"; fi
 done
 archive_original etc/rc.local "$tx/plan/before/rc.local"
 awk -v lines="$(wc -l < "$tx/plan/before/rc.local")" '
  function keep(s) {return s!="sh /data/zte-launcher/launcher-start.sh" && s!="sh /data/zte-dashboard-runtime/start-dashboard.sh"}
  {if(NR>1 && keep(previous))printf "%s\n",previous; previous=$0}
  END {if(NR>0 && keep(previous)){printf "%s",previous;if(lines>=NR)printf "\n"}}
 ' "$tx/plan/before/rc.local" > "$tx/plan/after/rc.local"
 chmod "$(stat -c %a "$tx/plan/before/rc.local")" "$tx/plan/after/rc.local"
 sh -n "$tx/plan/after/rc.local" || fail STARTUP
 vpn_mode=$(cat "$tx/vpn-mode")
 case "$vpn_mode" in none|stock) :;; configured)
  for pkg in network wireless firewall; do
   archive_original "etc/config/$pkg" "$tx/plan/before/$pkg"
   cp -p "$tx/plan/before/$pkg" "$tx/plan/after/$pkg"
  done
  cp -p "$tx/plan/before/wireless" "$tx/plan/off/wireless"
  archive_original etc/init.d/network "$tx/plan/before/network.init"
  archive_original data/zte-vpn/backup/network.init "$tx/plan/after/network.init"
  archive_original data/zte-vpn/backup/wireless "$tx/plan/backup/wireless"
  lua - "$tx/plan" <<'LUA' >/dev/null 2>&1 || fail VPN_PLAN
local root=arg[1]
local uci=require('uci')
local c=uci.cursor(root..'/after',root..'/deltas')
local b=uci.cursor(root..'/backup',root..'/backup-deltas')
local off=uci.cursor(root..'/off',root..'/deltas')
local fields={'ssid','key','encryption','network','bridge','disabled','isolate','wps_state','ieee80211w','sae','guest_active_time','guest_remaining'}
assert(c:load('network') and c:load('wireless') and c:load('firewall') and off:load('wireless'))
for _,name in ipairs({'guest_2g','guest_5g'}) do
 assert(c:get('wireless',name)=='wifi-iface' and b:get('wireless',name)=='wifi-iface')
 assert(off:set('wireless',name,'disabled','1'))
 for _,field in ipairs(fields) do
  local value=b:get('wireless',name,field)
  if value==nil then c:delete('wireless',name,field) else assert(c:set('wireless',name,field,value)) end
 end
end
c:delete('network','vpn');c:delete('network','br_vpn')
c:delete('firewall','zte_vpn_zone');c:delete('firewall','zte_vpn_rules')
for _,pkg in ipairs({'network','wireless','firewall'}) do assert(c:save(pkg) and c:commit(pkg)) end
assert(off:save('wireless') and off:commit('wireless'))
LUA
  for pkg in network wireless firewall; do chmod "$(stat -c %a "$tx/plan/before/$pkg")" "$tx/plan/after/$pkg"; done
  chmod "$(stat -c %a "$tx/plan/before/wireless")" "$tx/plan/off/wireless"
  ;; *) fail TRANSACTION;; esac
 (cd "$tx/plan"; find before after off backup -type f -print | sort | while IFS= read -r p; do sha256sum "$p" || exit 1; done) > "$tx/plan/SHA256SUMS" || fail VPN_PLAN
 printf '1\n' > "$tx/plan.ready.new"; mv "$tx/plan.ready.new" "$tx/plan.ready"; sync
 plan_inverse
}
# Write only if the current bytes are the original or one of our exact planned
# states. This allows every interrupted replacement to resume without adopting
# a concurrent stock UI/user change as its own work.
replace_planned() {
 target=$1; name=$2; wanted=$3
 oem_plain "$target" || fail CHANGED
 actual_mode=$(stat -c %a "$target")
 [ "$actual_mode" = "$(stat -c %a "$tx/plan/before/$name")" ] || [ "$actual_mode" = "$(stat -c %a "$tx/plan/after/$name")" ] || fail CHANGED
 observed=$(hash "$target") || fail CHANGED
 previous=$(hash "$tx/plan/before/$name") || fail TRANSACTION
 desired=$(hash "$tx/plan/$wanted/$name") || fail TRANSACTION
 if [ "$observed" = "$desired" ]; then return; fi
 allowed=0
 [ "$observed" != "$previous" ] || allowed=1
 if [ "$name" = wireless ]; then
  [ "$observed" != "$(hash "$tx/plan/off/wireless")" ] || allowed=1
  # A resume after restoration must not turn the network back into VPN.
  [ "$observed" != "$(hash "$tx/plan/after/wireless")" ] || { [ "$wanted" != off ] || return 0; allowed=1; }
 fi
 [ "$allowed" = 1 ] || fail CHANGED
 if exists "$target.zte-clean-$uuid"; then plain "$target.zte-clean-$uuid" || fail TRANSACTION; fi
 cp -p "$tx/plan/$wanted/$name" "$target.zte-clean-$uuid" || fail WRITE
 [ "$(hash "$target.zte-clean-$uuid")" = "$desired" ] && [ "$(hash "$target")" = "$observed" ] || fail CHANGED
 mv "$target.zte-clean-$uuid" "$target" || fail WRITE
 sync
}
# Services mutate logs, pid files and their private IPA recovery state while
# stopping. All other component bytes remain pinned to the verified snapshot.
immutable_records() {
 awk -v config=/etc/config -v vpn=/data/zte-vpn -v rc=/etc/rc.local -v network=/etc/init.d/network -F '\t' '
 {p=$NF}
 p==rc || p==network || p==config"/network" || p==config"/wireless" || p==config"/firewall" || p==config"/dhcp" || p==config"/zwrt_router" {next}
 index(p,vpn"/")==1 {r=substr(p,length(vpn)+2);if(r~/^(ipa-backup|ipa-restored|ipa-uci|backup-deltas|uci)(\/|$)/)next}
 {print}' "$1"
}
check_immutable() {
 manifest > "$tx/recheck.manifest" || fail SNAPSHOT
 immutable_records "$tx/before.manifest" > "$tx/stable.before"
 immutable_records "$tx/recheck.manifest" > "$tx/stable.current"
 cmp -s "$tx/stable.before" "$tx/stable.current" || fail CHANGED
}

setphase() { printf '%s\n' "$1" > "$tx/phase.new"; mv "$tx/phase.new" "$tx/phase"; sync; }
if [ "$action" = rebind ] && [ "$approved" = none ]; then
 # Before any clean dispatch there may be no archive yet. Rebind only the
 # private preparation metadata; a pending mutation still needs its SHA proof.
 if ! exists "$tx"; then mkdir "$tx"; printf '%s\n' "$owner" > "$tx/owner"; printf '%s\n' "$token" > "$tx/lock-token"; fi
 verify_tx
 prior_phase=preparing
 if exists "$tx/phase"; then prior_phase=$(cat "$tx/phase"); fi
 case "$prior_phase" in
 preparing) archive_sha=none; archive_bytes=0;;
 prepared) receipt; validate_components; check_immutable;;
 *) fail BACKUP_NOT_VERIFIED;; esac
 identity
 printf '%s\n' "$new_boot" > "$tx/accepted-boot.new"; mv "$tx/accepted-boot.new" "$tx/accepted-boot"; sync
 printf 'CLEAN_REBOUND %s %s %s\n' "$new_boot" "$archive_sha" "$archive_bytes"
 exit
fi
if [ "$action" = prepare ]; then
 clean_stage=PREPARE
 if exists "$tx" && plain "$tx/phase"; then
  case "$(cat "$tx/phase")" in prepared) receipt; echo "CLEAN_PREPARED $archive_sha $archive_bytes"; exit;; moving|stopping|changing) receipt; echo "CLEAN_PENDING $archive_sha $archive_bytes"; exit;; complete) receipt; complete_proof; echo CLEAN_COMPLETE; exit;; preparing) :;; *) fail RECOVERY_REQUIRED;; esac
 fi
 validate_components; vpn_check
 for d in $owned_roots; do
  # A nested mount must never become an omitted part of the archive.
  awk -v p="$d" '$2==p || index($2,p"/")==1 {bad=1} END{exit bad}' /proc/mounts || fail MOUNT
 done
 if ! exists "$tx"; then mkdir "$tx"; printf '%s\n' "$owner" > "$tx/owner"; printf '%s\n' "$token" > "$tx/lock-token"; fi
 # A failed snapshot never changed source files; overwrite only fixed private
 # producer outputs, never an unknown file or a symlink.
 for name in roots before.manifest recheck.manifest components.tar.new components.tar archive.sha256 archive.bytes vpn-mode tar.log phase.new; do
  if exists "$tx/$name"; then plain "$tx/$name" || fail TRANSACTION; fi
 done
 setphase preparing
 list_roots > "$tx/roots"
 manifest > "$tx/before.manifest" || fail SNAPSHOT
 runtime_exclusions > "$tx/archive.exclude"
 tar -C / -cf "$tx/components.tar.new" -X "$tx/archive.exclude" -T "$tx/roots" 2> "$tx/tar.log" || fail ARCHIVE
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
clean_stage=CLEAN
hex "$approved" 64 && [ "$approved" = "$archive_sha" ] || fail BACKUP_NOT_VERIFIED
phase=$(cat "$tx/phase")
if [ "$action" = rebind ]; then
 # The original owner and verified archive stay immutable across reboots.
 # Rebinding authorizes only this explicit cleanup retry on the same hardware.
 case "$phase" in
 complete) complete_proof;;
 moving) verify_moves;;
 prepared|stopping|changing) validate_components; check_immutable; if exists "$tx/plan.ready"; then plan_inverse; fi;;
 *) fail RECOVERY_REQUIRED;; esac
 identity
 printf '%s\n' "$new_boot" > "$tx/accepted-boot.new"; mv "$tx/accepted-boot.new" "$tx/accepted-boot"; sync
 printf 'CLEAN_REBOUND %s %s %s\n' "$new_boot" "$archive_sha" "$archive_bytes"
 exit
fi
[ "$phase" != complete ] || { complete_proof; echo CLEAN_COMPLETE; exit; }
if [ "$phase" = moving ]; then finish_moves; exit; fi
[ "$phase" = prepared ] || [ "$phase" = stopping ] || [ "$phase" = changing ] || fail RECOVERY_REQUIRED
validate_components
if [ "$phase" = prepared ]; then
 vpn_check
 manifest > "$tx/recheck.manifest" || fail SNAPSHOT
 cmp -s "$tx/before.manifest" "$tx/recheck.manifest" || fail CHANGED
else check_immutable; fi
clean_stage=PLAN
plan_inverse
vpn_mode=$(cat "$tx/vpn-mode")
identity
# No mutation above this line beyond private transaction/lock files. The caller
# has now confirmed a byte-verified, private local archive.
clean_stage=STOP
if [ "$phase" != changing ]; then setphase stopping; fi
# Disable only our owned guest sections after the host has verified its archive.
if [ "$vpn_mode" = configured ]; then
 replace_planned /etc/config/wireless wireless off
 for dev in wlan1 wlan3; do ip link set "$dev" down 2>/dev/null || true; done
fi
if exists /etc/init.d/zte_vpn; then /etc/init.d/zte_vpn stop >/dev/null 2>&1 || fail STOP; fi
if exists /etc/init.d/zte_launcher; then /etc/init.d/zte_launcher stop >/dev/null 2>&1 || fail STOP; fi
if exists /data/zte-vpn/ikev2; then
 checked_payload /data/zte-vpn/ikev2.sh ikev2 || fail VPN_INTEGRITY
 sh /data/zte-vpn/ikev2.sh cleanup >/dev/null 2>&1 || fail IKE_RESTORE
fi
# procd normally reaps these workers. A previous interrupted stop can leave
# an orphaned native DNS/IKE process; identify its exact private configuration
# rather than killing every dnsmasq/charon on the modem.
for proc in /proc/[0-9]*; do
 actual=$(readlink "$proc/exe" 2>/dev/null || true)
 owned=0
 case "$actual" in
 /usr/sbin/dnsmasq|/sbin/dnsmasq)
  if [ -r "$proc/cmdline" ] && tr '\000' '\n' < "$proc/cmdline" | grep -Eq '^--conf-file=/data/zte-vpn/(ikev2/)?dnsmasq.conf$'; then owned=1; fi;;
 /usr/lib/ipsec/charon)
  if [ -r "$proc/environ" ] && tr '\000' '\n' < "$proc/environ" | grep -Fx 'STRONGSWAN_CONF=/data/zte-vpn/ikev2/strongswan.conf' >/dev/null; then owned=1; fi;;
 esac
 if [ "$owned" = 1 ]; then
  started=$(awk '{print $22}' "$proc/stat") || fail PROCESS
  [ "$(readlink "$proc/exe")" = "$actual" ] && [ "$(awk '{print $22}' "$proc/stat")" = "$started" ] || fail PROCESS
  kill "${proc##*/}" || fail STOP
 fi
 done
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
  if [ "$actual" = /usr/lib/ipsec/charon ] && [ -r "$proc/environ" ] && tr '\000' '\n' < "$proc/environ" | grep -Fx 'STRONGSWAN_CONF=/data/zte-vpn/ikev2/strongswan.conf' >/dev/null; then running=1; fi
  if [ -r "$proc/cmdline" ]; then case "$(tr '\000' ' ' < "$proc/cmdline")" in *'/data/zte-vpn/manager.sh '*|*'/data/zte-launcher/launcher-watch.sh'*|*'--conf-file=/data/zte-vpn/'*) running=1;; esac; fi
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
# Stable component bytes must remain unchanged; planned writes verify each
# OEM file immediately before replacement and also on every retry.
check_immutable
clean_stage=RESTORE
setphase changing
if [ "$vpn_mode" = configured ]; then
 for pkg in network firewall wireless; do replace_planned "/etc/config/$pkg" "$pkg" after; done
 checked_payload /data/zte-vpn/firewall.sh firewall || fail VPN_INTEGRITY
 sh /data/zte-vpn/firewall.sh remove >/dev/null 2>&1 || fail VPN_RESTORE
 replace_planned /etc/init.d/network network.init after
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
if exists /data/zte-vpn/ipa-backup; then
 sh /data/zte-vpn/manager.sh ipa-restore >/dev/null 2>&1 || fail VPN_RESTORE
fi
replace_planned /etc/rc.local rc.local after
identity
# Keep removed components for recovery in addition to the downloaded tar.
: > "$tx/moves.new"
for p in /etc/rc.d/S99zte_vpn /etc/rc.d/K01zte_vpn /etc/rc.d/S99zte_launcher /etc/rc.d/K01zte_launcher /etc/init.d/zte_vpn /etc/init.d/zte_launcher $owned_roots; do
 if exists "$p"; then value=$(move_digest "$p") || fail SNAPSHOT; printf '%s %s\n' "$value" "$p" >> "$tx/moves.new"; fi
done
mv "$tx/moves.new" "$tx/moves"
clean_stage=MOVE
setphase moving
finish_moves
