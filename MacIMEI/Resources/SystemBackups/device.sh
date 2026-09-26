#!/bin/sh
# B31 eMMC backup/recovery transport. No mode boots, formats, fscks or stops radio.
# restore-chunk accepts only an already staged private file, at most 8 MiB.
# SIGKILL/power loss cannot run traps: preserve this stage and call relock, then
# hash-chunk to reconcile its journal before resuming. /tmp journal is volatile.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
fail() { printf 'BACKUP_ERROR %s\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; case "$1" in 0|[1-9]*) ;; *) return 1;; esac; [ "${#1}" -le 13 ]; }
hexhash() { [ "${#1}" = 64 ] && case "$1" in *[!a-f0-9]*) return 1;; esac; }
uuid() { [ "${#1}" = 36 ] && case "$1" in *[!a-f0-9-]*) return 1;; esac; }
plain() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a "$1")" = 0:600 ] && [ "$(stat -c %h "$1")" = 1 ]; }
private() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a "$1")" = 0:700 ]; }
mode=${1:-}; cid=${2:-}; token=${3:-}
case "$mode" in inventory|relock|capture|preflight|restore-chunk|hash-chunk|hash-device) ;; *) fail MODE;; esac
if [ "$mode" = inventory ] && [ "$cid" = - ]; then cid=$(cat /sys/block/mmcblk0/device/cid); fi
[ "${#cid}" = 32 ] && case "$cid" in *[!a-f0-9]*) false;; *) true;; esac || fail CID
uuid "$token" || fail TOKEN
stage=${0%/*}
case "$stage" in /tmp/zte-system-backup-*) ;; *) fail STAGE;; esac
uuid "${stage#/tmp/zte-system-backup-}" && private "$stage" || fail STAGE
plain "$0" || fail HELPER_FILE
# /tmp must itself be the expected root-owned directory; staged parents cannot
# contain caller-controlled links. Subdirectories below stage are never accepted.
[ -d /tmp ] && [ ! -L /tmp ] && [ "$(stat -c %u /tmp)" = 0 ] || fail TMP
lock=/tmp/zte-imei-app.lock
identity() {
 [ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] || fail ROOT_ARCH
 [ "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" ] || fail CID_CHANGED
 private "$lock" && [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] && [ "$(stat -c %u "$lock/owner")" = 0 ] && [ "$(cat "$lock/owner")" = "$token" ] || fail GLOBAL_LOCK
}
identity
work=$stage/work
[ ! -L "$work" ] || fail WORK
if ! exists "$work"; then mkdir -m 700 "$work" || fail WORK; fi
private "$work" || fail WORK
# Serialize helper instances independently of the application operation lock.
if exists "$stage/helper.lock"; then plain "$stage/helper.lock" || fail HELPER_LOCK; fi
exec 9>"$stage/helper.lock"
flock -n 9 || fail HELPER_BUSY
journal=$stage/restore-journal.tsv
protection_touched=0
force_path=; force_before=
write_started=0
load_journal() {
 plain "$journal" || fail JOURNAL
 [ "$(wc -l < "$journal" | tr -d ' \n')" = 1 ] || fail JOURNAL
 IFS=' ' read -r jcid jboot jlayout jtarget joffset jbytes jhash jforce jstate < "$journal" || fail JOURNAL
 [ "$jcid" = "$cid" ] && uuid "$jboot" && hexhash "$jlayout" && hexhash "$jhash" && uint "$joffset" && uint "$jbytes" || fail JOURNAL
 case "$jtarget" in mmcblk0|mmcblk0boot0|mmcblk0boot1) ;; *) fail JOURNAL;; esac
 case "$jforce" in none|0|1) ;; *) fail JOURNAL;; esac
 case "$jstate" in prepared|writing|failed|relock-failed|complete|verified) ;; *) fail JOURNAL;; esac
}
save_journal() {
 [ ! -L "$journal" ] && [ ! -L "$journal.new" ] || return 1
 if exists "$journal.new"; then plain "$journal.new" || return 1; rm "$journal.new" || return 1; fi
 (set -C; printf '%s %s %s %s %s %s %s %s %s\n' "$cid" "$boot_id" "$layout_hash" "$target" "$offset" "$length" "$wanted" "${force_before:-none}" "$1" > "$journal.new") || return 1
 mv "$journal.new" "$journal" && sync
}
flash_pair() {
 if [ -e /proc/driver/sensor_id ] && [ -e /proc/driver/codec_id ]; then flash=vendor
 elif [ ! -e /proc/driver/sensor_id ] && [ ! -e /proc/driver/codec_id ]; then flash=none
 else return 1; fi
}
restore_protection() {
 restored=0
 if ! flash_pair; then restored=1
 elif [ "$flash" = vendor ]; then cat /proc/driver/codec_id >/dev/null || restored=1
 fi
 if [ -n "$force_path" ]; then
  printf '%s\n' "$force_before" > "$force_path" || restored=1
  [ "$(cat "$force_path" 2>/dev/null)" = "$force_before" ] || restored=1
 fi
 [ "$restored" = 0 ]
}
finish() {
 result=$?
 trap - EXIT HUP INT TERM
 if [ "$protection_touched" = 1 ]; then
  if ! restore_protection; then
   result=1
   [ "$write_started" = 0 ] || save_journal relock-failed || true
   printf 'BACKUP_ERROR RELOCK_FAILED\n' >&2
  elif [ "$result" != 0 ] && [ "$write_started" = 1 ]; then save_journal failed || true
  fi
 fi
 for file in stream.hash.pipe stream.hash stream.status readback.bin layout.tsv devices.tsv partitions.tsv block-ids; do
  if exists "$work/$file"; then [ ! -L "$work/$file" ] && rm -f "$work/$file" || true; fi
 done
 exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
fresh() { [ ! -L "$1" ] || fail WORK_LINK; if exists "$1"; then plain "$1" || fail WORK_FILE; rm "$1"; fi; (set -C; : > "$1") || fail WORK_FILE; }
node_matches() {
 [ -b "/dev/$1" ] && [ ! -L "/dev/$1" ] || return 1
 node_hex=$(stat -Lc '%t %T' "/dev/$1") || return 1
 node_expected=$(cat "/sys/class/block/$1/dev") || return 1
 set -- $node_hex
 [ "$#" = 2 ] || return 1
 node_major=$(printf '%d' "0x$1") && node_minor=$(printf '%d' "0x$2") || return 1
 [ "$node_major:$node_minor" = "$node_expected" ]
}
inventory() {
 identity
 boot_id=$(cat /proc/sys/kernel/random/boot_id); uuid "$boot_id" || fail BOOT_ID
 for file in layout.tsv devices.tsv partitions.tsv block-ids; do fresh "$work/$file"; done
 for target in mmcblk0 mmcblk0boot0 mmcblk0boot1; do
  node=/dev/$target; sys=/sys/class/block/$target
  [ -b "$node" ] && [ ! -L "$node" ] || fail BLOCK_DEVICE
  node_matches "$target" || fail BLOCK_IDENTITY
  sectors=$(cat "$sys/size"); uint "$sectors" && [ "$sectors" -gt 0 ] || fail SIZE
  bytes=$((sectors * 512)); [ "$bytes" -le 17179869184 ] || fail SIZE
  logical=$(cat "$sys/queue/logical_block_size"); physical=$(cat "$sys/queue/physical_block_size")
  case "$logical:$physical" in 512:512|512:4096|4096:4096) ;; *) fail SECTOR_SIZE;; esac
  dev_id=$(cat "$sys/dev"); printf '%s\n' "$dev_id" | grep -Eq '^[0-9]+:[0-9]+$' || fail DEVICE_ID
  printf '%s\n' "$dev_id" >> "$work/block-ids"
  printf '%s %s %s %s %s\n' "$target" "$bytes" "$sectors" "$logical" "$physical" >> "$work/devices.tsv"
  printf 'D %s %s %s %s %s\n' "$target" "$bytes" "$sectors" "$logical" "$physical" >> "$work/layout.tsv"
 done
 count=0
 for sys in /sys/class/block/mmcblk0p*; do
  [ -d "$sys" ] || continue
  target=${sys##*/}; number=$(cat "$sys/partition"); start=$(cat "$sys/start"); sectors=$(cat "$sys/size")
  uint "$number" && uint "$start" && uint "$sectors" && [ "$number" -gt 0 ] && [ "$sectors" -gt 0 ] || fail PARTITION
  [ "$target" = "mmcblk0p$number" ] || fail PARTITION
  name=$(sed -n 's/^PARTNAME=//p' "$sys/uevent")
  case "$name" in ''|*[!a-zA-Z0-9_:-]*) fail PARTITION_NAME;; esac
  [ "${#name}" -le 64 ] || fail PARTITION_NAME
  dev_id=$(cat "$sys/dev"); printf '%s\n' "$dev_id" | grep -Eq '^[0-9]+:[0-9]+$' || fail DEVICE_ID
  printf '%s\n' "$dev_id" >> "$work/block-ids"
  printf '%s %s %s %s %s\n' "$target" "$name" "$number" "$start" "$sectors" >> "$work/partitions.tsv"
  printf 'P %s %s %s %s %s\n' "$target" "$name" "$number" "$start" "$sectors" >> "$work/layout.tsv"
  count=$((count+1))
 done
 [ "$count" -gt 0 ] || fail NO_PARTITIONS
 layout_hash=$(hash "$work/layout.tsv")
 disk_bytes=$(awk '$1=="mmcblk0" {print $2}' "$work/devices.tsv")
 firmware_hash=
 if [ -f /firmware/image/modem.b16 ]; then firmware_hash=$(hash /firmware/image/modem.b16); fi
 offline=false; reason=UNKNOWN
 if offline_check; then offline=true; reason=; fi
}
offline_check() {
 # Do not accept a block-backed or overlay root, even if its displayed source
 # is /dev/root; recovery must run wholly from RAM.
 if ! awk '$5=="/" {n++;for(i=7;i<=NF;i++)if($i=="-"){if($(i+1)=="tmpfs"||$(i+1)=="ramfs"||$(i+1)=="rootfs")ok=1}} END{exit !(n==1&&ok)}' /proc/self/mountinfo; then reason=ROOT_NOT_RAM; return 1; fi
 for mounts in /proc/[0-9]*/mountinfo /proc/self/mountinfo; do
  [ -e "$mounts" ] || continue
  if ! awk 'NR==FNR {ids[$1]=1;next} $3 in ids {bad=1} END{exit bad}' "$work/block-ids" "$mounts"; then reason=EMMC_MOUNTED; return 1; fi
 done
 if ! awk 'NR>1 {bad=1} END{exit bad}' /proc/swaps; then reason=SWAP_ACTIVE; return 1; fi
 for sys in /sys/class/block/mmcblk0 /sys/class/block/mmcblk0boot0 /sys/class/block/mmcblk0boot1 /sys/class/block/mmcblk0p*; do
  [ -d "$sys" ] || continue
  [ -d "$sys/holders" ] || { reason=HOLDERS_UNKNOWN; return 1; }
  for holder in "$sys"/holders/*; do [ ! -e "$holder" ] && [ ! -L "$holder" ] || { reason=BLOCK_HOLDER; return 1; }; done
 done
 found_modem=0
 for remote in /sys/class/remoteproc/remoteproc*; do
  [ -d "$remote" ] || continue
  remote_name=$(cat "$remote/name" 2>/dev/null) || { reason=BASEBAND_UNKNOWN; return 1; }
  case "$remote_name" in *modem*|*mpss*|*MPSS*)
   found_modem=1
   [ "$(cat "$remote/state" 2>/dev/null)" = offline ] || { reason=BASEBAND_ONLINE; return 1; };;
  esac
 done
 [ "$found_modem" = 1 ] || { reason=BASEBAND_UNKNOWN; return 1; }
 # Scan open descriptors in all visible processes; a by-name alias still has
 # the same block rdev. Do not consider unmounted raw radio partitions idle.
 for process in /proc/[0-9]*; do
  if [ -r "$process/comm" ]; then
   process_name=$(cat "$process/comm" 2>/dev/null) || continue
   case "$process_name" in rmt_storage|rmtfs|qcom_rmtfs|fsck*|e2fsck|resize2fs|parted|fdisk|sfdisk|mmc|flash_erase|nandwrite|fastbootd|update_engine|zte_fota)
    reason=STORAGE_WRITER_ACTIVE; return 1;;
   esac
  fi
  [ -d "$process/fd" ] || continue
  [ -r "$process/fd" ] && [ -x "$process/fd" ] || { reason=PROCESS_UNKNOWN; return 1; }
  for fd in "$process"/fd/*; do
   [ -b "$fd" ] || continue
   raw=$(stat -Lc '%t %T' "$fd" 2>/dev/null) || { reason=PROCESS_UNKNOWN; return 1; }
   set -- $raw
   [ "$#" = 2 ] || { reason=PROCESS_UNKNOWN; return 1; }
   major=$(printf '%d' "0x$1") || { reason=PROCESS_UNKNOWN; return 1; }
   minor=$(printf '%d' "0x$2") || { reason=PROCESS_UNKNOWN; return 1; }
   if grep -qx "$major:$minor" "$work/block-ids"; then reason=RAW_DEVICE_OPEN; return 1; fi
  done
 done
 flash_pair || { reason=FLASH_INTERFACE_INCOMPLETE; return 1; }
 return 0
}
print_inventory() {
 printf '{"schema":1,"cid":"%s","bootID":"%s","firmwareHash":"%s","diskBytes":%s,"layoutHash":"%s","offline":%s,"offlineReason":"%s","capture":"%s","devices":[' "$cid" "$boot_id" "$firmware_hash" "$disk_bytes" "$layout_hash" "$offline" "$reason" "$(if [ "$offline" = true ]; then printf offline; else printf live-non-atomic; fi)"
 comma=
 while read -r name bytes sectors logical physical; do
  printf '%s{"name":"%s","source":"/dev/%s","bytes":%s,"sectors":%s,"logicalSectorBytes":%s,"physicalSectorBytes":%s}' "$comma" "$name" "$name" "$bytes" "$sectors" "$logical" "$physical"; comma=,
 done < "$work/devices.tsv"
 printf '],"partitions":['; comma=
 while read -r device name number start sectors; do
  printf '%s{"device":"%s","name":"%s","number":%s,"startSector":%s,"sectors":%s}' "$comma" "$device" "$name" "$number" "$start" "$sectors"; comma=,
 done < "$work/partitions.tsv"
 printf ']}\n'
}
select_target() {
 target=$1
 case "$target" in mmcblk0|mmcblk0boot0|mmcblk0boot1) ;; *) fail TARGET;; esac
 target_bytes=$(awk -v name="$target" '$1==name {print $2}' "$work/devices.tsv")
 target_logical=$(awk -v name="$target" '$1==name {print $4}' "$work/devices.tsv")
 uint "$target_bytes" && uint "$target_logical" || fail TARGET
}
check_range() {
 uint "$offset" && uint "$length" && [ "$length" -gt 0 ] && [ "$length" -le 8388608 ] || fail RANGE
 [ "$offset" -le "$target_bytes" ] && [ "$length" -le "$((target_bytes-offset))" ] || fail RANGE
 [ "$((offset % target_logical))" = 0 ] && [ "$((length % target_logical))" = 0 ] || fail ALIGNMENT
}
check_expected() {
 [ "$boot_id" = "$expected_boot" ] || fail BOOT_CHANGED
 [ "$layout_hash" = "$expected_layout" ] || fail LAYOUT_CHANGED
}
read_range() {
 ram_reserve
 fresh "$work/readback.bin"
 dd if="/dev/$target" of="$work/readback.bin" bs=512 skip="$((offset/512))" count="$((length/512))" 2>/dev/null || fail READBACK
 [ "$(stat -c %s "$work/readback.bin")" = "$length" ] || fail READBACK_SIZE
 actual=$(hash "$work/readback.bin"); hexhash "$actual" || fail HASH
}
ram_reserve() {
 available=$(awk '$1=="MemAvailable:" {print $2; found=1} END{if(!found)exit 1}' /proc/meminfo) || fail RAM_UNKNOWN
 free_kib=$(df -Pk "$stage" | awk 'END{print $4}')
 uint "$available" && uint "$free_kib" && [ "$available" -ge 65536 ] && [ "$free_kib" -ge 65536 ] || fail RAM_INSUFFICIENT
}
receipt() { printf 'RESTORE_RESULT target=%s offset=%s bytes=%s sha256=%s\n' "$target" "$offset" "$length" "$actual"; }
case "$mode" in
 relock)
  [ "$#" = 3 ] || fail ARGUMENTS
  if exists "$journal"; then
   load_journal
   case "$jtarget:$jforce" in mmcblk0boot[01]:[01]) force_path=/sys/class/block/$jtarget/force_ro; force_before=$jforce;; esac
  fi
  protection_touched=1
  restore_protection || fail RELOCK_FAILED
  protection_touched=0
  printf 'SYSTEM_RELOCKED\n'; exit 0;;
 inventory) [ "$#" = 3 ] || fail ARGUMENTS; inventory; print_inventory; exit 0;;
 capture)
  [ "$#" = 4 ] || fail ARGUMENTS
  requested_target=$4; inventory; select_target "$requested_target"
  captured_boot=$boot_id; captured_layout=$layout_hash; captured_offline=$offline; captured_bytes=$target_bytes
  # A live capture is allowed only on the exact known B31 profile. Offline
  # recovery can read the same CID without a mounted /firmware filesystem.
  if [ "$offline" != true ]; then [ "$firmware_hash" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ] || fail PROFILE; fi
  for file in stream.hash stream.status; do fresh "$work/$file"; done
  [ ! -e "$work/stream.hash.pipe" ] && [ ! -L "$work/stream.hash.pipe" ] || fail PIPE
  mkfifo -m 600 "$work/stream.hash.pipe"
  sha256sum <"$work/stream.hash.pipe" >"$work/stream.hash" & hp=$!
  set +e
  (dd if="/dev/$target" bs=1048576; result=$?; printf '%s\n' "$result" >"$work/stream.status"; exit "$result") | tee "$work/stream.hash.pipe"
  tp=$?; wait "$hp"; hs=$?
  set -e
  [ "$tp" = 0 ] && [ "$hs" = 0 ] && [ "$(cat "$work/stream.status")" = 0 ] || fail READ
  actual=$(awk '{print $1}' "$work/stream.hash"); hexhash "$actual" || fail CAPTURE_HASH
  inventory
  [ "$boot_id" = "$captured_boot" ] || fail BOOT_CHANGED
  [ "$layout_hash" = "$captured_layout" ] || fail LAYOUT_CHANGED
  if [ "$captured_offline" = true ]; then [ "$offline" = true ] || fail OFFLINE_CHANGED; fi
  # Report the verified geometry, not a potentially 32-bit remote wc counter.
  # The Mac receiver MUST compare its 64-bit actual file size with this exact
  # size and compare SHA256 with the hash of the bytes sent above. A successful
  # dd/SSH exit alone is never sufficient to publish a complete backup.
  printf 'BACKUP_RESULT sha256=%s bytes=%s\n' "$actual" "$captured_bytes" >&2; exit 0;;
esac
expected_boot=${4:-}; expected_layout=${5:-}
uuid "$expected_boot" && hexhash "$expected_layout" || fail EXPECTED_IDENTITY
inventory; check_expected
if [ "$mode" = preflight ]; then [ "$#" = 5 ] || fail ARGUMENTS; [ "$offline" = true ] || fail "$reason"; print_inventory; exit 0; fi
if [ "$mode" = hash-device ]; then
 [ "$#" = 6 ] || fail ARGUMENTS
 requested_target=$6; select_target "$requested_target"
 [ "$offline" = true ] || fail "$reason"
 full_hash=$(sha256sum "/dev/$target") || fail READ
 actual=${full_hash%% *}; hexhash "$actual" || fail HASH
 inventory; check_expected; select_target "$requested_target"
 [ "$offline" = true ] || fail OFFLINE_CHANGED
 printf 'SYSTEM_HASH target=%s bytes=%s sha256=%s\n' "$target" "$target_bytes" "$actual"; exit 0
fi
case "$mode:$#" in hash-chunk:8|restore-chunk:10) ;; *) fail ARGUMENTS;; esac
requested_target=$6; offset=$7; length=$8
select_target "$requested_target"; check_range
[ "$offline" = true ] || fail "$reason"
if [ "$mode" = hash-chunk ]; then
 read_range
 if exists "$journal"; then
  load_journal
  if [ "$jlayout" = "$layout_hash" ] && [ "$jtarget" = "$target" ] && [ "$joffset" = "$offset" ] && [ "$jbytes" = "$length" ] && [ "$jhash" = "$actual" ]; then
   wanted=$jhash; force_before=$jforce; save_journal verified || fail JOURNAL
  fi
 fi
 receipt; exit 0
fi
wanted=$9; chunk=${10}
hexhash "$wanted" || fail HASH
[ "$chunk" = "$stage/chunk.bin" ] && plain "$chunk" || fail CHUNK_FILE
[ "$(stat -c %s "$chunk")" = "$length" ] && [ "$(hash "$chunk")" = "$wanted" ] || fail CHUNK_HASH
ram_reserve
# Always recover a previous interrupted protection window first. Its bytes are
# reconciled separately, and only the exact pending write is allowed to retry.
if exists "$journal"; then
 load_journal
 case "$jstate" in complete|verified) ;; *)
  [ "$jlayout" = "$layout_hash" ] && [ "$jtarget" = "$target" ] && [ "$joffset" = "$offset" ] && [ "$jbytes" = "$length" ] && [ "$jhash" = "$wanted" ] || fail JOURNAL_PENDING;;
 esac
 case "$jtarget:$jforce" in mmcblk0boot[01]:[01]) force_path=/sys/class/block/$jtarget/force_ro; force_before=$jforce;; esac
 protection_touched=1; restore_protection || fail RELOCK_FAILED; protection_touched=0
 force_path=; force_before=
fi
case "$target" in mmcblk0boot0|mmcblk0boot1)
 force_path=/sys/class/block/$target/force_ro
 force_before=$(cat "$force_path"); case "$force_before" in 0|1) ;; *) fail FORCE_RO;; esac;;
esac
save_journal prepared || fail JOURNAL
write_started=1
# Re-read identity, mount aliases, raw descriptors and baseband immediately before
# enabling writes. The helper itself has not yet opened the block destination.
inventory; check_expected; select_target "$requested_target"; check_range
[ "$offline" = true ] || fail "$reason"
node_matches "$target" || fail BLOCK_IDENTITY
plain "$chunk" && [ "$(stat -c %s "$chunk")" = "$length" ] && [ "$(hash "$chunk")" = "$wanted" ] || fail CHUNK_CHANGED
save_journal writing || fail JOURNAL
protection_touched=1
flash_pair || fail FLASH_INTERFACE_INCOMPLETE
if [ "$flash" = vendor ]; then cat /proc/driver/sensor_id >/dev/null || fail FLASH_UNLOCK; fi
if [ -n "$force_path" ] && [ "$force_before" = 1 ]; then printf '0\n' > "$force_path" || fail FORCE_RO; [ "$(cat "$force_path")" = 0 ] || fail FORCE_RO; fi
dd if="$chunk" of="/dev/$target" bs=512 seek="$((offset/512))" count="$((length/512))" conv=notrunc 2>/dev/null || fail WRITE
sync
read_range; [ "$actual" = "$wanted" ] || fail VERIFY
restore_protection || fail RELOCK_FAILED
protection_touched=0
save_journal complete || fail JOURNAL
receipt
