#!/bin/sh
# Read-only backup producer. Only its private /tmp work directory is written.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
mode=${1:-}; cid=${2:-}; name=${3:-}
fail() { printf 'BACKUP_ERROR %s\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
[ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] || fail PROFILE
case "$cid" in *[!a-f0-9]*|'') fail CID;; esac
[ "${#cid}" = 32 ] && [ "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" ] || fail CID
[ "$(hash /firmware/image/modem.b16)" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ] || fail PROFILE
for pending in /data/local/tmp/zte-imei-installations/active /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /data/zte-vpn/transaction /data/zte-vpn/controller-upgrade; do
  [ ! -e "$pending" ] && [ ! -L "$pending" ] || fail PENDING
 done
partition() {
  case "$name" in
    modemst1) dev=mmcblk0p8; expected=8192;;
    modemst2) dev=mmcblk0p9; expected=8192;;
    fsg) dev=mmcblk0p10; expected=8192;;
    persist) dev=mmcblk0p56; expected=16384;;
    *) fail PARTITION;;
  esac
  # sysfs size is a count of 512-byte sectors; known B31 sizes are 4/4/4/8 MiB.
  [ "$(cat /sys/class/block/$dev/size)" = "$expected" ] || fail PARTITION_SIZE
  grep -qx "PARTNAME=$name" "/sys/class/block/$dev/uevent" || fail PARTITION_NAME
  [ -b "/dev/$dev" ] && [ ! -L "/dev/$dev" ] || fail PARTITION_DEVICE
  expected=$((expected * 512))
}
config_paths() {
  set -- etc/config etc/rc.local
  for path in etc/dropbear etc/ssh etc/passwd etc/group etc/shadow etc/zte-imei-admin etc/init.d etc/rc.d etc/hotplug.d/iface/99-zte-imei-ttl data/dropbear data/zte-imei-admin data/zte-imei-ttl data/zte-imei-screen-ru data/zte-imei-apps/ssclash/.ssclash data/local/tmp/start_zte_agent.sh data/local/tmp/start_dropbear.sh data/local/tmp/start_dashboard.sh data/local/tmp/dashboard-html.sh data/local/tmp/start_zte_imei_studio.sh data/local/tmp/start_ttl.sh data/zte-vpn/profiles data/zte-vpn/config.json data/zte-vpn/active data/zte-vpn/configured data/zte-vpn/cid data/zte-vpn/owner data/zte-vpn/backup data/zte-vpn/manager.sh data/zte-vpn/firewall.sh data/zte-vpn/configure.lua data/zte-vpn/nft-guard.nft data/zte-vpn/dnsmasq.conf data/zte-vpn/service.sh data/zte-vpn/network-init.sha256; do
    if [ -e "/$path" ] || [ -L "/$path" ]; then set -- "$@" "$path"; fi
  done
  tar -cf - -C / "$@"
}
case "$mode" in
  estimate)
    case "$name" in
      modem) bytes=20971520;;
      userData) bytes=$(du -sk /data | awk '{print $1 * 1024}');;
      configuration) bytes=$(du -sk /etc /data/zte-imei-admin /data/zte-imei-ttl /data/zte-imei-screen-ru /data/zte-imei-apps/ssclash/.ssclash /data/dropbear /data/zte-vpn 2>/dev/null | awk '{n += $1} END {printf "%.0f", n * 1024 + 1048576}');;
      *) fail KIND;;
    esac
    case "$bytes" in ''|*[!0-9]*) fail ESTIMATE;; esac
    printf 'BACKUP_ESTIMATE bytes=%s\n' "$bytes"
    exit 0;;
  partition) partition;;
  userData)
    [ -d /data ] && [ ! -L /data ] || fail DATA_LAYOUT
    # Do not cross an unexpected mount nested under /data.
    awk '$5 ~ /^\/data\// {bad=1} END{exit bad}' /proc/self/mountinfo || fail DATA_MOUNTS;;
  configuration)
    [ -d /etc/config ] && [ ! -L /etc/config ] && [ -f /etc/rc.local ] && [ ! -L /etc/rc.local ] || fail CONFIG_LAYOUT;;
  *) fail MODE;;
esac
stage=${0%/*}
case "$stage" in /tmp/zte-device-backup-????????-????-????-????-????????????) ;; *) fail STAGE;; esac
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c %u "$stage")" = 0 ] && [ "$(stat -c %a "$stage")" = 700 ] || fail STAGE
work="$stage/stream-$$"
mkdir -m 700 "$work" || fail WORK
cleanup() { rm -f "$work/hash.pipe" "$work/size.pipe" "$work/hash" "$work/size" "$work/result" "$work/exclude"; rmdir "$work" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# This firmware's BusyBox tar supports -X but has no --exclude option.
# Keep the list fixed and private; never accept caller-supplied archive paths.
if [ "$mode" = userData ]; then
  cat >"$work/exclude" <<'EXCLUSIONS'
data/local/tmp
data/cache
data/log
data/logs
data/open-u60-agent-backups
data/zte-imei-admin/backups
data/zte-imei-ttl/backup
data/zte-imei-screen-ru/backup
data/.open-u60-switch.*
EXCLUSIONS
fi
if [ "$mode" = partition ]; then before=$(hash "/dev/$dev"); fi
mkfifo "$work/hash.pipe" "$work/size.pipe"
sha256sum <"$work/hash.pipe" >"$work/hash" & hash_pid=$!
wc -c <"$work/size.pipe" >"$work/size" & size_pid=$!
# The producer writes its own exit status: pipeline success cannot hide a tar
# read error or a file changed while being archived.
set +e
(
  case "$mode" in
    partition) dd if="/dev/$dev" bs=65536;;
    userData) tar -cf - -X "$work/exclude" -C / data;;
    configuration) config_paths;;
  esac
  result=$?
  printf '%s\n' "$result" >"$work/result"
  exit "$result"
) | tee "$work/hash.pipe" "$work/size.pipe"
tee_status=$?
wait "$hash_pid"; hash_status=$?
wait "$size_pid"; size_status=$?
set -e
[ "$tee_status" = 0 ] && [ "$hash_status" = 0 ] && [ "$size_status" = 0 ] && [ "$(cat "$work/result")" = 0 ] || fail READ
sha=$(awk '{print $1}' "$work/hash"); bytes=$(tr -d ' \n' <"$work/size")
if [ "$mode" = partition ]; then
  after=$(hash "/dev/$dev")
  [ "$before" = "$sha" ] && [ "$after" = "$sha" ] && [ "$bytes" = "$expected" ] || fail CHANGED_PARTITION
fi
[ "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" ] || fail CID
printf 'BACKUP_RESULT sha256=%s bytes=%s\n' "$sha" "$bytes" >&2
