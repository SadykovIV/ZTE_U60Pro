#!/bin/sh
# Configfs ADB transaction with persistent removal/restoration of our boot unlock.
# USB network links are preserved; rc.local and USB roll back without a fresh SSH ACK.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
BASE=/sys/kernel/config/usb_gadget/g1
LOCK=/tmp/zte-imei-app.lock
RC=/etc/rc.local
BACKUPS=/data/zte-imei-studio/adb-control
BOOT_LINE='echo 1 > /sys/class/android_usb/android0/usb_op'
ROUTER=55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f
fail() { printf 'ADB_CONTROL_REFUSED\n' >&2; exit 71; }
regular() { test -f "$1" && test ! -L "$1" && test "$(stat -c '%u:%a:%h' "$1")" = 0:600:1; }
private_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c '%u:%a' "$1")" = 0:700; }
write() { test ! -e "$STAGE/$1.new" && test ! -L "$STAGE/$1.new" || fail; (umask 077; printf '%s\n' "$2" > "$STAGE/$1.new"); mv "$STAGE/$1.new" "$STAGE/$1"; }
read_saved() { regular "$STAGE/$1" && test "$(stat -c %s "$STAGE/$1")" -le 8192 || fail; cat "$STAGE/$1"; }
binding() {
  expected_router=$ROUTER
  test "$(id -u)" = 0 && test "$(uname -s)" = Linux && test "$(uname -m)" = aarch64 || fail
  test "$(cat /sys/block/mmcblk0/device/cid)" = "$CID" && test "$(cat /proc/sys/kernel/random/boot_id)" = "$BOOT" || fail
  for component in /usr/bin/diag-router /sbin/adbd; do
    test -f "$component" && test ! -L "$component" && test "$(stat -c %u "$component")" = 0 || fail
  done
  image=absent
  if test -e /firmware/image/modem.b16 || test -L /firmware/image/modem.b16; then
    test -f /firmware/image/modem.b16 && test ! -L /firmware/image/modem.b16 && test "$(stat -c %u /firmware/image/modem.b16)" = 0 || fail
    image=$(sha256sum /firmware/image/modem.b16 | cut -d ' ' -f 1)
  fi
  case "$image" in
    604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263|5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478) :;;
    4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e)
      test -f /usr/bin/zte_topsw_mdm && test ! -L /usr/bin/zte_topsw_mdm && test "$(stat -c %u /usr/bin/zte_topsw_mdm)" = 0 || fail
      test "$(sha256sum /usr/bin/zte_topsw_mdm | cut -d ' ' -f 1)" = 00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d || fail
      expected_router=786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f;;
    c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81|absent)
      test -f /usr/bin/zte_topsw_mdm && test ! -L /usr/bin/zte_topsw_mdm && test "$(stat -c %u /usr/bin/zte_topsw_mdm)" = 0 || fail
      test "$(sha256sum /usr/bin/zte_topsw_mdm | cut -d ' ' -f 1)" = 93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64 || fail
      info=$(ubus -t 5 call zwrt_web device_info '{}') || fail
      test "$(printf '%s' "$info" | jsonfilter -e '@.integrate_version')" = XCBZ_HK_MU5250V1.0.0B04 || fail
      test "$(printf '%s' "$info" | jsonfilter -e '@.wa_inner_version')" = BD_XCBZHKMU5250V1.0.0B04 || fail;;
    *) fail;;
  esac
  test "$(sha256sum /usr/bin/diag-router | cut -d ' ' -f 1)" = "$expected_router" || fail
}
layout() {
  for directory in /sys/kernel/config /sys/kernel/config/usb_gadget "$BASE" "$BASE/configs" "$BASE/configs/c.1" "$BASE/functions"; do
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
  # B28 has the same measured configfs layout. Verify its actual root daemon
  # and open FunctionFS endpoints instead of mistaking the B31 binary pin for
  # a USB capability. No firmware override can bypass the binding above.
  test "$(sha256sum /sbin/adbd | cut -d ' ' -f 1)" = "$(sha256sum "/proc/$pid/exe" | cut -d ' ' -f 1)" || fail
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
rc_regular() { test -f "$RC" && test ! -L "$RC" && test "$(stat -c '%u:%h' "$RC")" = 0:1 && test -w "$RC"; }
rc_matches() { rc_regular && cmp -s "$RC" "$STAGE/rc.$1"; }
rc_prepare() {
  rc_regular && sh -n "$RC" || fail
  # Only our exact standalone boot activation is edited. OEM startup, SSH,
  # agent and all unrelated lines remain intact. Never execute usb_op live.
  test "$(awk '$0=="#!/bin/sh" {n++} END {print n+0}' "$RC")" = 1 || fail
  cat "$RC" > "$STAGE/rc.before"
  write rc.mode "$(stat -c %a "$RC")"
  awk -v wanted="$WANT" -v line="$BOOT_LINE" '
    $0 == line {next}
    {print}
    $0 == "#!/bin/sh" && wanted == 1 {print line}
  ' "$RC" > "$STAGE/rc.after"
  sh -n "$STAGE/rc.after" || fail
}
rc_install() (
  source=$1; expected=$2
  rc_matches "$expected" || fail
  test ! -e "$RC.zte-adb-$TOKEN" && test ! -L "$RC.zte-adb-$TOKEN" || fail
  trap 'test ! -L "$RC.zte-adb-$TOKEN" && rm -f "$RC.zte-adb-$TOKEN"' EXIT
  cat "$STAGE/rc.$source" > "$RC.zte-adb-$TOKEN"
  chmod "$(read_saved rc.mode)" "$RC.zte-adb-$TOKEN"
  sh -n "$RC.zte-adb-$TOKEN" && cmp -s "$STAGE/rc.$source" "$RC.zte-adb-$TOKEN" || fail
  rc_matches "$expected" || fail
  mv "$RC.zte-adb-$TOKEN" "$RC"
  trap - EXIT
)
rc_backup() {
  for directory in /data /data/zte-imei-studio; do
    test -d "$directory" && test ! -L "$directory" && test "$(stat -c %u "$directory")" = 0 || fail
  done
  if test ! -e "$BACKUPS" && test ! -L "$BACKUPS"; then mkdir -m 700 "$BACKUPS"; fi
  private_dir "$BACKUPS" || fail
  test ! -e "$BACKUPS/rc.local.$TOKEN.before" && test ! -L "$BACKUPS/rc.local.$TOKEN.before" || fail
  cat "$STAGE/rc.before" > "$BACKUPS/rc.local.$TOKEN.before"
  regular "$BACKUPS/rc.local.$TOKEN.before" && cmp -s "$STAGE/rc.before" "$BACKUPS/rc.local.$TOKEN.before" || fail
}
owned() { private_dir "$LOCK" && regular "$LOCK/owner" && test "$(cat "$LOCK/owner")" = "$TOKEN"; }
release() {
  owned && lock_safe || return 1
  test ! -e "$STAGE/released-lock" && test ! -L "$STAGE/released-lock" || return 1
  # Same /tmp filesystem: ownership is archived atomically, never erased while
  # the global lock still exists. A crash leaves a replayable private receipt.
  mv -T "$LOCK" "$STAGE/released-lock" || return 1
  released_lock_safe
}
phase() { write phase "$1"; }
validate_current() {
  binding; layout
  test "$(udc)" = "$(read_saved udc)" || fail
  if test "$(read_saved daemon)" = not-ready; then
    # With no live ADB link the off request only changes our boot entry.
    # It needs no FunctionFS daemon and never rebinds USB.
    test "$WANT" = 0 && test "$(read_saved before)" = "$(read_saved after)" || fail
  else test "$(daemon)" = "$(read_saved daemon)" || fail; fi
  actual=$(links) || fail
  test "$actual" = "$(read_saved "$1")" || fail
  rc_matches "$1" || fail
}
restore() {
  # Exactly one best-effort rollback; no retry after an uncertain sysfs write.
  binding && layout && owned || return 1
  current=$(links) || return 1
  before=$(read_saved before) || return 1
  after=$(read_saved after) || return 1
  if rc_matches after; then rc_install before after || return 1
  else rc_matches before || return 1; fi
  # Persistence-only changes do not interrupt USB or touch its function links.
  if test "$before" = "$after"; then validate_current before; return; fi
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
# Reconciliation never changes USB or rc.local. It runs from the currently
# verified host bundle, not from a possibly old staged executable.
empty_private_dir() {
  private_dir "$1" || return 1
  for item in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    test ! -e "$item" && test ! -L "$item" || return 1
  done
}
released_lock_safe() {
  private_dir "$STAGE/released-lock" && regular "$STAGE/released-lock/owner" && test "$(cat "$STAGE/released-lock/owner")" = "$TOKEN" || return 1
  for item in "$STAGE/released-lock"/* "$STAGE/released-lock"/.[!.]* "$STAGE/released-lock"/..?*; do
    test ! -e "$item" && test ! -L "$item" && continue
    test "$item" = "$STAGE/released-lock/owner" || return 1
  done
}
lock_safe() {
  if test ! -e "$LOCK" && test ! -L "$LOCK"; then return 0; fi
  owned || return 1
  for item in "$LOCK"/* "$LOCK"/.[!.]* "$LOCK"/..?*; do
    test ! -e "$item" && test ! -L "$item" && continue
    test "$item" = "$LOCK/owner" || return 1
  done
}
process_start() {
  # comm may contain spaces or parentheses; starttime is field 20 after comm.
  awk '{sub(/^.*\) /, ""); print $20}' "$1/stat"
}
no_worker() {
  stage_hex=$(printf '%s' "$STAGE" | od -An -v -tx1 | tr -d ' \n')
  scanned=0
  for proc in /proc/[0-9]*; do
    test -d "$proc" || continue
    test "${proc##*/}" != "$$" || continue
    scanned=$((scanned + 1)); test "$scanned" -le 4096 || fail
    start_before=$(process_start "$proc" 2>/dev/null) || { test ! -d "$proc" && continue; fail; }
    case "$start_before" in ''|*[!0-9]*) test ! -d "$proc" && continue; fail;; esac
    # Never emit cmdline. Oversized, unreadable or reused live PIDs are unknown.
    command_bytes=$(od -An -v -N 8193 -tx1 "$proc/cmdline" 2>/dev/null) || { test ! -d "$proc" && continue; fail; }
    command_hex=$(printf '%s' "$command_bytes" | tr -d ' \n')
    test -r "$proc/cmdline" || { test ! -d "$proc" && continue; fail; }
    test "${#command_hex}" -le 16384 || fail
    start_after=$(process_start "$proc" 2>/dev/null) || { test ! -d "$proc" && continue; fail; }
    test "$start_before" = "$start_after" || fail
    case "$command_hex" in *"$stage_hex"*) fail;; esac
  done
}
acquire_recovery_marker() {
  marker=$1
  if test -e "$marker" || test -L "$marker"; then
    empty_private_dir "$marker" || fail
    marker_identity=$(stat -c '%d:%i:%u:%a' "$marker") || fail
    no_worker
    test "$(stat -c '%d:%i:%u:%a' "$marker")" = "$marker_identity" && empty_private_dir "$marker" || fail
    rmdir "$marker" || fail
  fi
  # A concurrent prepare winning this gap causes refusal, never its removal.
  mkdir "$marker" || fail
}
recovery_inventory() {
  for item in "$STAGE"/* "$STAGE"/.[!.]* "$STAGE"/..?*; do
    test ! -e "$item" && test ! -L "$item" && continue
    case "${item##*/}" in
      adb-toggle.sh|phase|before|after|udc|daemon|name|target|desired|original|ack|worker.log|rc.before|rc.after|rc.mode|phase.new|before.new|after.new|udc.new|daemon.new|name.new|target.new|desired.new|original.new|ack.new|rc.mode.new)
        regular "$item" || fail
        test "$(stat -c %s "$item")" -le 65536 || fail;;
      released-lock) released_lock_safe || fail;;
      decision|apply-once|settle-active|prepare-active) empty_private_dir "$item" || fail;;
      *) fail;;
    esac
  done
}
validate_saved_links() {
  printf '%s\n' "$1" | awk -F= '
    NF != 2 || $1 !~ /^f([1-9]|[12][0-9]|3[0-2])$/ || $2 !~ /^[a-zA-Z0-9._-]+$/ {exit 1}
    seen[$1]++ {exit 1}
    {n++; if ($2 == "ffs.adb") adb++}
    END {if (n > 32 || adb > 1) exit 1}' || fail
  test "$(printf '%s\n' "$1" | sort)" = "$1" || fail
}
recovery_snapshots() {
  before=$(read_saved before); after=$(read_saved after)
  validate_saved_links "$before"; validate_saved_links "$after"
  name=$(read_saved name); case "$name" in f[1-9]|f[12][0-9]|f3[0-2]) :;; *) fail;; esac
  original=$(read_saved original); case "$original" in present|absent) :;; *) fail;; esac
  test "$(read_saved desired)" = "$WANT" || fail
  before_adb=$(printf '%s\n' "$before" | awk -F= '$2 == "ffs.adb" {print $1}')
  if test "$original" = present; then test "$before_adb" = "$name" || fail
  else test -z "$before_adb" && ! printf '%s\n' "$before" | awk -F= -v n="$name" '$1 == n {found=1} END {exit !found}' || fail; fi
  expected=$(printf '%s\n' "$before" | sed "/^$name=/d")
  if test "$WANT" = 1; then expected=$(printf '%s\n%s=ffs.adb\n' "$expected" "$name" | sed '/^$/d' | sort); fi
  test "$after" = "$expected" || fail
  for saved in rc.before rc.after; do
    regular "$STAGE/$saved" && test "$(stat -c %s "$STAGE/$saved")" -le 65536 && sh -n "$STAGE/$saved" || fail
  done
  test "$(awk '$0=="#!/bin/sh" {n++} END {print n+0}' "$STAGE/rc.before")" = 1 || fail
  # Compare streams, not command substitutions which discard terminal newlines.
  awk -v wanted="$WANT" -v line="$BOOT_LINE" '$0 == line {next} {print} $0 == "#!/bin/sh" && wanted == 1 {print line}' "$STAGE/rc.before" | cmp -s - "$STAGE/rc.after" || fail
  saved_mode=$(read_saved rc.mode); case "$saved_mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) :;; *) fail;; esac
  test "$(stat -c %a "$RC")" = "$saved_mode" || fail
}
recovery_current() {
  binding; layout
  test "$(udc)" = "$(read_saved udc)" || fail
  current=$(links)
  if test "$current" = "$before" && rc_matches before; then settled=settled-before
  elif test "$current" = "$after" && rc_matches after; then settled=settled-after
  else fail; fi
  if printf '%s\n' "$current" | awk -F= '$2 == "ffs.adb" {found=1} END {exit !found}'; then
    current_daemon=$(daemon) || fail
  else current_daemon=not-linked; fi
}
reconcile() {
  expected_script=${7:-}
  case "$expected_script" in ????????????????????????????????????????????????????????????????) case "$expected_script" in *[!0-9a-f]*) fail;; esac;; *) fail;; esac
  regular "$STAGE/adb-toggle.sh" && test "$(sha256sum "$STAGE/adb-toggle.sh" | cut -d ' ' -f 1)" = "$expected_script" || fail
  no_worker
  acquire_recovery_marker "$STAGE/settle-active"
  trap 'rmdir "$STAGE/settle-active" 2>/dev/null || :' EXIT
  recovery_inventory; lock_safe || fail
  state=preparing
  if test -e "$STAGE/phase" || test -L "$STAGE/phase"; then state=$(read_saved phase); fi
  if test "$state" = prepared && test -d "$STAGE/apply-once"; then state=changing; fi
  case "$state" in
    preparing|prepared|cancelled)
      # The decision directory is the same atomic fence used by old apply.
      # It blocks a delayed launch even when its SSH dispatch reply was lost.
      test ! -e "$STAGE/apply-once" && test ! -L "$STAGE/apply-once" || fail
      acquire_recovery_marker "$STAGE/prepare-active"
      trap 'rmdir "$STAGE/prepare-active" "$STAGE/settle-active" 2>/dev/null || :' EXIT
      if test -e "$STAGE/decision" || test -L "$STAGE/decision"; then empty_private_dir "$STAGE/decision" || fail
      else mkdir "$STAGE/decision" || fail; fi
      no_worker; binding; lock_safe || fail
      if owned; then release || fail; fi
      if test -e "$STAGE/phase.new"; then regular "$STAGE/phase.new" || fail; rm "$STAGE/phase.new"; fi
      phase cancelled
      printf 'ADB_RECOVERED=cancelled\n';;
    changing|awaiting-ack|committed|rolled-back|rollback-unknown|cleanup-unknown|settled-before|settled-after)
      empty_private_dir "$STAGE/decision" && empty_private_dir "$STAGE/apply-once" || fail
      recovery_snapshots; recovery_current
      first_settled=$settled; first_daemon=$current_daemon
      no_worker; recovery_inventory; lock_safe || fail
      recovery_snapshots; recovery_current
      test "$first_settled" = "$settled" && test "$first_daemon" = "$current_daemon" || fail
      if owned; then release || fail; fi
      printf 'ADB_RECOVERED=%s\n' "$settled";;
    *) fail;;
  esac
}

mode=${1:-}; STAGE=${2:-}; TOKEN=${3:-}; CID=${4:-}; BOOT=${5:-}; WANT=${6:-}
case "$mode" in prepare|apply|ack|result|cancel|reconcile) :;; *) fail;; esac
case "$TOKEN" in ????????-????-????-????-????????????) case "$TOKEN" in *[!0-9a-f-]*) fail;; esac;; *) fail;; esac
case "$CID" in ????????????????????????????????) case "$CID" in *[!0-9a-f]*) fail;; esac;; *) fail;; esac
case "$BOOT" in ????????-????-????-????-????????????) case "$BOOT" in *[!0-9a-f-]*) fail;; esac;; *) fail;; esac
case "$WANT" in 0|1) :;; *) fail;; esac
test "$STAGE" = "/tmp/zte-adb-toggle-$TOKEN" && private_dir "$STAGE" || fail
umask 077
binding
if test "$mode" = reconcile; then reconcile "$@"; exit 0; fi
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
  for tool in sh stat readlink sha256sum cut awk sed sort pidof nohup sleep cat mv rm rmdir mkdir ln id uname cmp chmod; do command -v "$tool" >/dev/null 2>&1 || fail; done
  test -w "$STAGE" || fail
  layout; original_links=$(links); original_udc=$(udc)
  name=; target=; found=0
  for link in "$BASE"/configs/c.1/*; do
    test -L "$link" || continue
    if test "$(readlink -f "$link")" = "$BASE/functions/ffs.adb"; then
      found=$((found + 1)); name=${link##*/}; target=$(readlink "$link")
    fi
  done
  test "$found" -le 1 || fail
  original_daemon=$(daemon 2>/dev/null) || {
    test "$found" = 0 && test "$WANT" = 0 || fail
    original_daemon=not-ready
  }
  rc_prepare
  if test "$found" = "$WANT" && cmp -s "$STAGE/rc.before" "$STAGE/rc.after"; then printf 'ADB_UNCHANGED\n'; exit 0; fi
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
  if test "$found" = "$WANT"; then expected=$original_links; fi
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
rc_backup
rc_install after before
name=$(read_saved name)
if test "$(read_saved before)" != "$(read_saved after)"; then
printf '\n' > "$BASE/UDC"
if test "$WANT" = 0; then
  test -L "$BASE/configs/c.1/$name" && test "$(readlink -f "$BASE/configs/c.1/$name")" = "$BASE/functions/ffs.adb" || fail
  rm "$BASE/configs/c.1/$name"
else
  test ! -e "$BASE/configs/c.1/$name" && test ! -L "$BASE/configs/c.1/$name" || fail
  ln -s "$(read_saved target)" "$BASE/configs/c.1/$name"
fi
printf '%s\n' "$(read_saved udc)" > "$BASE/UDC"
fi
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
