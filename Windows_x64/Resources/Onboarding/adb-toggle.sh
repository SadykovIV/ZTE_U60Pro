#!/bin/sh
# Runtime-only configfs ADB transaction. No usb_op, service, boot or UCI writes.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
BASE=/sys/kernel/config/usb_gadget/g1
LOCK=/tmp/zte-imei-app.lock
FIRMWARE=604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263
ROUTER=55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f
fail() { printf 'ADB_CONTROL_REFUSED\n' >&2; exit 71; }
regular() { test -f "$1" && test ! -L "$1" && test "$(stat -c '%u:%a:%h' "$1")" = 0:600:1; }
private_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c '%u:%a' "$1")" = 0:700; }
write() { test ! -e "$STAGE/$1.new" && test ! -L "$STAGE/$1.new" || fail; (umask 077; printf '%s\n' "$2" > "$STAGE/$1.new"); mv "$STAGE/$1.new" "$STAGE/$1"; }
read_saved() { regular "$STAGE/$1" && test "$(stat -c %s "$STAGE/$1")" -le 8192 || fail; cat "$STAGE/$1"; }
binding() {
  test "$(id -u)" = 0 && test "$(uname -s)" = Linux && test "$(uname -m)" = aarch64 || fail
  test "$(cat /sys/block/mmcblk0/device/cid)" = "$CID" && test "$(cat /proc/sys/kernel/random/boot_id)" = "$BOOT" || fail
  for component in /firmware/image/modem.b16 /usr/bin/diag-router /sbin/adbd; do
    test -f "$component" && test ! -L "$component" && test "$(stat -c %u "$component")" = 0 || fail
  done
  test "$(sha256sum /firmware/image/modem.b16 | cut -d ' ' -f 1)" = "$FIRMWARE" || fail
  test "$(sha256sum /usr/bin/diag-router | cut -d ' ' -f 1)" = "$ROUTER" || fail
}
layout() {
  for directory in /sys/kernel/config /sys/kernel/config/usb_gadget "$BASE" "$BASE/configs" "$BASE/configs/c.1" "$BASE/functions" "$BASE/functions/ffs.adb"; do
    test -d "$directory" && test -r "$directory" && test -x "$directory" && test ! -L "$directory" || fail
  done
  count=0
  for configuration in "$BASE"/configs/*; do test ! -e "$configuration" && test ! -L "$configuration" && continue; count=$((count + 1)); done
  test "$count" = 1 || fail
  test -r "$BASE/UDC" && test -w "$BASE/UDC" || fail
}
# Stable configfs item identities. configfs renders its own readlink text,
# which need not equal the relative target string supplied to ln -s.
links() {
  count=0
  for link in "$BASE"/configs/c.1/*; do
    test -L "$link" || continue
    name=${link##*/}; case "$name" in f[1-9]|f[12][0-9]|f3[0-2]) :;; *) fail;; esac
    target=$(readlink "$link") || fail
    case "$target" in ''|*[!a-zA-Z0-9_./-]*) fail;; esac
    test "${#target}" -le 256 || fail
    resolved=$(readlink -f "$link") || fail
    function=${resolved##*/}; case "$function" in ''|*[!a-zA-Z0-9._-]*) fail;; esac
    test "$resolved" = "$BASE/functions/$function" && test -d "$resolved" || fail
    count=$((count + 1)); test "$count" -le 32 || fail
    printf '%s=%s\n' "$name" "$function"
  done
}
udc() {
  value=$(cat "$BASE/UDC") || fail
  case "$value" in ''|*[!a-zA-Z0-9._-]*) fail;; esac
  test "${#value}" -le 64 && test -d "/sys/class/udc/$value" || fail
  printf '%s' "$value"
}
daemon() {
  pid=$(pidof adbd) || fail
  case "$pid" in ''|*[!0-9]*) fail;; esac
  test "$(readlink "/proc/$pid/exe")" = /sbin/adbd && test "$(stat -c %u "/proc/$pid")" = 0 || fail
  test "$(sha256sum /sbin/adbd | cut -d ' ' -f 1)" = 6d42bf97ae1f761ba3c5a0ee48deb84db0b19e4766b6b538b71741743d5b3f90 || fail
  test "$(sha256sum "/proc/$pid/exe" | cut -d ' ' -f 1)" = 6d42bf97ae1f761ba3c5a0ee48deb84db0b19e4766b6b538b71741743d5b3f90 || fail
  ep0=0; ep1=0; ep2=0; count=0
  for fd in "/proc/$pid"/fd/*; do
    test -L "$fd" || continue
    count=$((count + 1)); test "$count" -le 128 || fail
    target=$(readlink "$fd") || fail
    case "$target" in /dev/usb-ffs/adb/ep0) ep0=1;; /dev/usb-ffs/adb/ep1) ep1=1;; /dev/usb-ffs/adb/ep2) ep2=1;; esac
  done
  test "$ep0$ep1$ep2" = 111 || fail
  # The exact process must keep owning the descriptors during detach/rebind.
  start=$(awk '{print $22}' "/proc/$pid/stat") || fail
  case "$start" in ''|*[!0-9]*) fail;; esac
  printf '%s:%s' "$pid" "$start"
}
owned() { private_dir "$LOCK" && regular "$LOCK/owner" && test "$(cat "$LOCK/owner")" = "$TOKEN"; }
release() { owned || return 1; rm "$LOCK/owner" && rmdir "$LOCK"; }
phase() { write phase "$1"; }
validate_current() {
  binding; layout
  test "$(udc)" = "$(read_saved udc)" || fail
  test "$(daemon)" = "$(read_saved daemon)" || fail
  actual=$(links) || fail
  test "$actual" = "$(read_saved "$1")" || fail
}
restore() {
  # Exactly one best-effort rollback; no retry after an uncertain sysfs write.
  binding && layout && owned || return 1
  current=$(links) || return 1
  before=$(read_saved before) || return 1
  after=$(read_saved after) || return 1
  name=$(read_saved name) || return 1
  # Other function links must remain exact even when our link is missing.
  current_other=$(printf '%s\n' "$current" | sed "/^$name=/d")
  before_other=$(printf '%s\n' "$before" | sed "/^$name=/d")
  test "$current_other" = "$before_other" || return 1
  printf '\n' > "$BASE/UDC" || return 1
  if test "$(read_saved original)" = present; then
    original_target=$(read_saved target) || return 1
    if test -L "$BASE/configs/c.1/$name"; then
      test "$(readlink "$BASE/configs/c.1/$name")" = "$original_target" || return 1
    else
      test ! -e "$BASE/configs/c.1/$name" || return 1
      ln -s "$original_target" "$BASE/configs/c.1/$name" || return 1
    fi
  elif test -L "$BASE/configs/c.1/$name"; then
    test "$(readlink -f "$BASE/configs/c.1/$name")" = "$BASE/functions/ffs.adb" || return 1
    rm "$BASE/configs/c.1/$name" || return 1
  else test ! -e "$BASE/configs/c.1/$name" || return 1
  fi
  printf '%s\n' "$(read_saved udc)" > "$BASE/UDC" || return 1
  validate_current before
}
mode=${1:-}; STAGE=${2:-}; TOKEN=${3:-}; CID=${4:-}; BOOT=${5:-}; WANT=${6:-}
case "$mode" in prepare|apply|ack|result|cancel) :;; *) fail;; esac
case "$TOKEN" in ????????-????-????-????-????????????) case "$TOKEN" in *[!0-9a-f-]*) fail;; esac;; *) fail;; esac
case "$CID" in ????????????????????????????????) case "$CID" in *[!0-9a-f]*) fail;; esac;; *) fail;; esac
case "$BOOT" in ????????-????-????-????-????????????) case "$BOOT" in *[!0-9a-f-]*) fail;; esac;; *) fail;; esac
case "$WANT" in 0|1) :;; *) fail;; esac
test "$STAGE" = "/tmp/zte-adb-toggle-$TOKEN" && private_dir "$STAGE" || fail
umask 077
binding
if test "$mode" = cancel; then
  mkdir "$STAGE/prepare-active" || fail
  trap 'rmdir "$STAGE/prepare-active" 2>/dev/null || :' EXIT
  mkdir "$STAGE/decision" || fail
  # No apply-once marker means our worker never began a USB write. This also
  # recovers interrupted prepare/staging; a foreign lock is never removed.
  test ! -e "$STAGE/apply-once" && test ! -L "$STAGE/apply-once" || fail
  if test -e "$STAGE/phase" || test -L "$STAGE/phase"; then
    case "$(read_saved phase)" in preparing|prepared) :;; *) fail;; esac
  fi
  if owned; then release || fail; fi
  phase cancelled
  printf 'ADB_CANCELLED\n'
  exit 0
fi
if test "$mode" = prepare; then
  mkdir "$STAGE/prepare-active" || fail
  trap 'rmdir "$STAGE/prepare-active" 2>/dev/null || :' EXIT
  test ! -e "$STAGE/phase" && test ! -L "$STAGE/phase" || fail
  for tool in sh stat readlink sha256sum cut awk sed sort pidof nohup sleep cat mv rm rmdir mkdir ln id uname; do command -v "$tool" >/dev/null 2>&1 || fail; done
  test -w "$STAGE" || fail
  layout; original_links=$(links); original_udc=$(udc); original_daemon=$(daemon)
  name=; target=; found=0
  for link in "$BASE"/configs/c.1/*; do
    test -L "$link" || continue
    if test "$(readlink -f "$link")" = "$BASE/functions/ffs.adb"; then
      found=$((found + 1)); name=${link##*/}; target=$(readlink "$link")
    fi
  done
  test "$found" -le 1 || fail
  if test "$found" = "$WANT"; then printf 'ADB_UNCHANGED\n'; exit 0; fi
  if test "$found" = 0; then
    i=1
    while test "$i" -le 32; do
      if test ! -e "$BASE/configs/c.1/f$i" && test ! -L "$BASE/configs/c.1/f$i"; then name=f$i; break; fi
      i=$((i + 1))
    done
    test -n "$name" || fail
    target=../../functions/ffs.adb
  fi
  for pending in /tmp/zte-vpn-agent-update.lock /tmp/zte-dashboard-install.lock /tmp/zte-launcher-install.lock /tmp/zte-system-restore.lock; do test ! -e "$pending" && test ! -L "$pending" || fail; done
  test ! -L /tmp && test "$(stat -c %u /tmp)" = 0 || fail
  mkdir -m 700 "$LOCK" || fail
  printf '%s' "$TOKEN" > "$LOCK/owner"
  phase preparing
  write before "$original_links"; write udc "$original_udc"; write daemon "$original_daemon"
  write name "$name"; write target "$target"; write desired "$WANT"
  if test "$found" = 1; then
    write original present
    expected=$(printf '%s\n' "$original_links" | sed "/^$name=/d")
  else
    write original absent
    expected=$(printf '%s\n%s=%s\n' "$original_links" "$name" ffs.adb | sed '/^$/d' | sort)
  fi
  write after "$expected"
  phase prepared
  printf 'ADB_PREPARED\n'
  exit 0
fi
if test "$mode" = result; then
  state=$(read_saved phase)
  case "$state" in preparing|prepared|changing|awaiting-ack|committed|rolled-back|rollback-unknown|cleanup-unknown|cancelled) :;; *) fail;; esac
  case "$state" in
    committed) validate_current after; owned && fail;;
    rolled-back) validate_current before; owned && fail;;
    cancelled) test ! -e "$STAGE/apply-once" && test ! -L "$STAGE/apply-once" || fail; owned && fail;;
  esac
  printf 'ADB_PHASE=%s\n' "$state"
  exit 0
fi
regular "$STAGE/desired" && test "$(read_saved desired)" = "$WANT" || fail
owned || fail
if test "$mode" = ack; then
  test "$(read_saved phase)" = awaiting-ack || fail
  validate_current after
  test ! -e "$STAGE/ack" && test ! -L "$STAGE/ack" || fail
  write ack "$TOKEN"
  printf 'ADB_ACKNOWLEDGED\n'
  exit 0
fi
test "$(read_saved phase)" = prepared || fail
validate_current before
mkdir "$STAGE/decision" || fail
# A second dispatch can never repeat the mutation, even if its SSH reply was lost.
mkdir "$STAGE/apply-once" || fail
trap '' HUP
restoring=0
on_exit() {
  code=$?
  trap - EXIT INT TERM
  if test "$restoring" = 0; then
    restoring=1
    if (restore); then
      if release; then phase rolled-back; else phase cleanup-unknown; fi
    else phase rollback-unknown; fi
  fi
  exit "$code"
}
trap on_exit EXIT
trap 'exit 72' INT TERM
phase changing
name=$(read_saved name)
printf '\n' > "$BASE/UDC"
if test "$WANT" = 0; then
  test -L "$BASE/configs/c.1/$name" && test "$(readlink -f "$BASE/configs/c.1/$name")" = "$BASE/functions/ffs.adb" || fail
  rm "$BASE/configs/c.1/$name"
else
  test ! -e "$BASE/configs/c.1/$name" && test ! -L "$BASE/configs/c.1/$name" || fail
  ln -s "$(read_saved target)" "$BASE/configs/c.1/$name"
fi
printf '%s\n' "$(read_saved udc)" > "$BASE/UDC"
validate_current after
phase awaiting-ack
elapsed=0
while test "$elapsed" -lt 60; do
  if test -e "$STAGE/ack" || test -L "$STAGE/ack"; then
    regular "$STAGE/ack" && test "$(cat "$STAGE/ack")" = "$TOKEN" || fail
    validate_current after
    restoring=1
    if release; then phase committed; else phase cleanup-unknown; exit 74; fi
    exit 0
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
exit 73
