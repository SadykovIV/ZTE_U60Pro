#!/bin/sh
# Called under the native application's common operation lock. All inputs are
# bundled and pinned; profiles, radio configuration and stock init stay intact.
set -eu
umask 077
stage=${1:?}
mode=${2:-apply}
case "$mode" in apply|preflight) ;; *) exit 64;; esac
root=/data/zte-launcher
case "$stage" in /tmp/zte-vpn-agent-*) ;; *) exit 64;; esac
[ -d /tmp/zte-imei-app.lock ] && [ -f /tmp/zte-imei-app.lock/owner ] || exit 65
[ ! -e /tmp/zte-vpn-screen ] && [ ! -e /tmp/zte-launcher-trial/supervisor ] || exit 66
for dir in /data /etc /etc/init.d "$stage"; do
 [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -c %u "$dir")" = 0 ] || exit 67
 perm=$(stat -c %a "$dir");[ "$((0$perm & 022))" = 0 ] || exit 67
done
[ "$(sha256sum /firmware/image/modem.b16 | cut -d' ' -f1)" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ] || exit 68
case "$(sha256sum /etc/init.d/zte_topsw_devui | cut -d' ' -f1)" in
 a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35|0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50) ;;
 *) exit 69;;
esac
# PAYLOAD_PINS_BEGIN
[ "$(sha256sum "$stage/launcher.so" | cut -d' ' -f1)" = 3e8338319bc2eb3764fdfa4efbbb6966ddce185a951f8b9122c15025804fbd2a ] || exit 70
[ "$(sha256sum "$stage/launcher-run.sh" | cut -d' ' -f1)" = d873533e471a4e86b20adb89ee77e6f72f1532972269e05f3616111b88b6e06e ] || exit 70
[ "$(sha256sum "$stage/launcher-watch.sh" | cut -d' ' -f1)" = 13dbaa1520f0a503270109bbd07eea331317396824566d389bba37bdc91a16e2 ] || exit 70
[ "$(sha256sum "$stage/launcher-service.sh" | cut -d' ' -f1)" = e0d5c80f061af69a8a7329476e33e6b4766a80b37a9a38e3d3217712551b4e90 ] || exit 70
[ "$(sha256sum "$stage/launcher-start.sh" | cut -d' ' -f1)" = 8aed90c6fe28ad488b78caeadbc61117dfcfda795793894325e39baf0ac03633 ] || exit 70
[ "$(sha256sum "$stage/launcher.sha256" | cut -d' ' -f1)" = 638952749088173eb8a90656e24a9f34ef19937bf21cd490cc332974df9d2664 ] || exit 70
# PAYLOAD_PINS_END
for file in launcher.so launcher-run.sh launcher-watch.sh launcher-service.sh launcher-start.sh launcher.sha256; do
 [ -f "$stage/$file" ] && [ ! -L "$stage/$file" ] || exit 70
done
(cd "$stage" && sha256sum -c launcher.sha256 >/dev/null) || exit 71
[ -f /etc/rc.local ] && [ ! -L /etc/rc.local ] || exit 72
[ "$(stat -c %u /etc/rc.local)" = 0 ] || exit 72
transaction=/data/zte-launcher-update
page_layout_valid() {
 [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a:%h "$1")" = 0:600:1 ] || return 1
 bytes=$(wc -c < "$1")
 [ "$bytes" -gt 0 ] && [ "$bytes" -le 128 ] || return 1
 # Comparing the reconstructed byte count also rejects a missing final LF.
 # LC_ALL=C makes byte length independent of the caller's locale.
 expected=$(LC_ALL=C awk '
  NR==1 {if($0!="ZTE_LAUNCHER_PAGES_V1")exit 1;total=length($0)+1;next}
  {if(($0!="info"&&$0!="vpn"&&$0!="esim")||seen[$0]++||NR>4)exit 1;total+=length($0)+1}
  END {if(NR<1)exit 1;print total}
 ' "$1") || return 1
 [ "$bytes" -eq "$expected" ]
}
page_layout_optional() {
 if [ -e "$1" ] || [ -L "$1" ]; then page_layout_valid "$1";else return 0;fi
}
owned_root() {
 [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%a "$1")" = 0:700 ] &&
 [ "$(cat "$1/owner" 2>/dev/null)" = zte-native-launcher-v1 ] &&
 [ "$(cat "$1/cid" 2>/dev/null)" = "$(cat /sys/block/mmcblk0/device/cid)" ] &&
 page_layout_optional "$1/page-layout.conf"
}
recover() {
 [ -e "$transaction" ] || return 0
 [ -d "$transaction" ] && [ ! -L "$transaction" ] && [ "$(stat -c %u:%a "$transaction")" = 0:700 ] || return 1
 [ "$(cat "$transaction/owner" 2>/dev/null)" = zte-launcher-update-v1 ] || return 1
 [ "$(cat "$transaction/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" ] || return 1
 # Never restore a directory whose separately stored page selection is unsafe.
 if [ -e "$transaction/old" ] || [ -L "$transaction/old" ]; then owned_root "$transaction/old" || return 1;fi
 if [ -e "$transaction/commit" ]; then rm -rf "$transaction";return 0;fi
 if [ ! -e "$transaction/started" ] && [ ! -d "$transaction/old" ]; then rm -rf "$transaction";return 0;fi
 (cd "$transaction" && sha256sum -c backup.sha256 >/dev/null) || return 1
 if [ -e "$transaction/started" ] || [ -d "$transaction/old" ]; then
  if [ -f /etc/init.d/zte_launcher ] && [ ! -L /etc/init.d/zte_launcher ]; then /etc/init.d/zte_launcher stop >/dev/null 2>&1 || true;fi
  if [ -e "$root" ]; then owned_root "$root" || return 1;rm -rf "$root";fi
  if [ -d "$transaction/old" ]; then mv "$transaction/old" "$root";fi
  cp -p "$transaction/rc.local" /etc/rc.local
  if [ -f "$transaction/service" ]; then cp -p "$transaction/service" /etc/init.d/zte_launcher
  else rm -f /etc/init.d/zte_launcher;fi
  /etc/init.d/zte_topsw_devui restart || true
  if [ -d "$root" ] && [ -f "$transaction/service" ]; then sh "$root/launcher-start.sh" || true;fi
 fi
 rm -rf "$transaction"
}
# Optional user data is not part of the binary payload manifest. Validate it
# before even recovery can change installed state; absence preserves old data.
page_layout_optional "$stage/page-layout.conf" || exit 73
if [ -e "$root" ] || [ -L "$root" ]; then owned_root "$root" || exit 73;fi
if [ "$mode" = preflight ]; then
 # Inspection must never recover, remove or stop a previous installation.
 [ ! -e "$transaction" ] && [ ! -L "$transaction" ] || exit 74
else
 recover || exit 74
fi
service_missing=0
if [ -e "$root" ] || [ -L "$root" ]; then
 owned_root "$root" || exit 73
 (cd "$root" && sha256sum -c launcher.sha256 >/dev/null) || exit 73
 if [ ! -e /etc/init.d/zte_launcher ] && [ ! -L /etc/init.d/zte_launcher ]; then
  # A reset may remove /etc while preserving this owned, intact /data bundle.
  # Only the reviewed service from the pinned payload may repair that absence.
  [ -f "$root/launcher-service.sh" ] && [ ! -L "$root/launcher-service.sh" ] &&
   cmp -s "$root/launcher-service.sh" "$stage/launcher-service.sh" || exit 73
  service_missing=1
 else
  [ -f /etc/init.d/zte_launcher ] && [ ! -L /etc/init.d/zte_launcher ] && cmp -s /etc/init.d/zte_launcher "$root/launcher-service.sh" || exit 73
 fi
else
 [ ! -e /etc/init.d/zte_launcher ] && [ ! -L /etc/init.d/zte_launcher ] || exit 73
fi
# Keep the user's order and selections across library upgrades. A configuration
# is data outside the payload manifest; never follow or copy an unsafe path.
layout="$root/info-layout.conf"
if [ -e "$layout" ] || [ -L "$layout" ]; then
 [ -f "$layout" ] && [ ! -L "$layout" ] && [ "$(stat -c %u:%a:%h "$layout")" = 0:600:1 ] || exit 73
 [ "$(wc -c < "$layout")" -le 512 ] || exit 73
fi
if [ "$mode" = preflight ]; then
 printf '%s\n' LAUNCHER_PREFLIGHT_OK
 exit 0
fi
mkdir -m 700 "$transaction"
printf '%s\n' zte-launcher-update-v1 > "$transaction/owner"
cat /sys/block/mmcblk0/device/cid > "$transaction/cid"
cp -p /etc/rc.local "$transaction/rc.local"
if [ -f /etc/init.d/zte_launcher ]; then cp -p /etc/init.d/zte_launcher "$transaction/service";fi
(cd "$transaction"; sha256sum rc.local > backup.sha256; [ ! -f service ] || sha256sum service >> backup.sha256)
mkdir -m 700 "$transaction/new"
printf '%s\n' zte-native-launcher-v1 > "$transaction/new/owner"
cp "$transaction/cid" "$transaction/new/cid"
if [ -d "$root" ]; then cp -p "$root/rc.local.backup" "$transaction/new/rc.local.backup"
else cp -p /etc/rc.local "$transaction/new/rc.local.backup";fi
chmod 600 "$transaction/new/rc.local.backup"
if [ -f "$layout" ]; then
 cp -p "$layout" "$transaction/new/info-layout.conf"
 cmp -s "$layout" "$transaction/new/info-layout.conf" || exit 73
fi
pages="$root/page-layout.conf"
if [ -e "$stage/page-layout.conf" ]; then pages="$stage/page-layout.conf";fi
if [ -e "$pages" ]; then
 page_layout_valid "$pages" || exit 73
 cp -p "$pages" "$transaction/new/page-layout.conf"
 page_layout_valid "$transaction/new/page-layout.conf" && cmp -s "$pages" "$transaction/new/page-layout.conf" || exit 73
fi
for file in launcher.so launcher-run.sh launcher-watch.sh launcher-service.sh launcher-start.sh launcher.sha256; do
 cp "$stage/$file" "$transaction/new/$file";chmod 700 "$transaction/new/$file"
done
(cd "$transaction/new" && sha256sum -c launcher.sha256 >/dev/null)
printf '%s\n' enabled > "$transaction/new/enabled"
startup='sh /data/zte-launcher/launcher-start.sh'
cp -p /etc/rc.local "$transaction/rc.new"
if ! grep -qFx "$startup" /etc/rc.local; then
 awk -v line="$startup" 'BEGIN{done=0} /^exit 0[[:space:]]*$/&&!done {print line;done=1} {print} END{if(!done)print line}' /etc/rc.local > "$transaction/rc.new"
fi
sh -n "$transaction/rc.new"
# A complete, verified replacement and backups exist before any running state changes.
trap 'code=$?;trap - EXIT INT TERM;recover || true;exit "$code"' EXIT
trap 'exit 75' INT TERM
if [ -d "$root" ]; then
 if [ "$service_missing" = 0 ]; then /etc/init.d/zte_launcher stop;fi
 mv "$root" "$transaction/old"
fi
# Recovery also handles interruption immediately after the old-directory rename.
touch "$transaction/started"
sync
mv "$transaction/new" "$root"
cp "$root/launcher-service.sh" /etc/init.d/.zte_launcher.new
chmod 755 /etc/init.d/.zte_launcher.new
mv /etc/init.d/.zte_launcher.new /etc/init.d/zte_launcher
cp -p "$transaction/rc.new" /etc/rc.local
# Reload any old mapped library through the original service, after files are complete.
/etc/init.d/zte_topsw_devui restart
sh "$root/launcher-start.sh"
sync
touch "$transaction/commit"
sync
rm -rf "$transaction"
trap - EXIT INT TERM
printf '%s\n' LAUNCHER_INSTALLED
