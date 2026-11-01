#!/bin/sh
# procd still owns the stock UI; this wrapper only prepares its environment.
set -eu
umask 077
root=/data/zte-launcher
stock=/usr/bin/zte_topsw_devui
sdk=/usr/lib/libzte_SDKowrt.so
# Never inherit an opt-in from a previous process or an unknown UI/SDK pair.
unset ZTE_LAUNCHER_NETWORK_NAME_B31
plain() { exec "$stock"; }
[ -d "$root" ] && [ ! -L "$root" ] && [ "$(stat -c %u:%a "$root")" = 0:700 ] || plain
[ -f "$root/enabled" ] && [ ! -e "$root/failed" ] || plain
[ "$(cat "$root/owner")" = zte-native-launcher-v1 ] || plain
[ "$(cat "$root/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" ] || plain
(cd "$root" && sha256sum -c launcher.sha256 >/dev/null 2>&1) || plain
[ "$(id -u)" = 0 ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || plain
[ -f "$stock" ] && [ ! -L "$stock" ] || plain
ui_sha=$(sha256sum "$stock" | cut -d' ' -f1)
case "$ui_sha" in
 e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9|16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4|8d2ebbde880934f52195ad9595815d728f7aa4671bb0633d5a5149b09467ae90|d6c3cd409705d5aa9c12185c84074513b159088025f005da7dbf01c51e3c3715|dbe6eadc92d43a0cd7206264f9d75ab242df90e88c02ee2ba3ac65598b58523e|0db2294b3e428fb53f4b6b725063ad8ffd9c396e5a27c54452f0ea479fa78f3b|d7aab64cafb5d0ec5c9479c3247a2e504c6ab76dd192cf8de997fc12f5d213fe|83c2623f4a7a87816466ba9e1eeae1da24384b7ff6e8c972e9df836495103c55) ;;
 *) plain;;
esac
# B31 main/status provider ABI only. Other supported UI profiles retain their
# stock operator display. No vendor file, UCI metadata or SIM state is changed.
case "$ui_sha" in
 e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9|16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4)
  if [ -f "$sdk" ] && [ ! -L "$sdk" ] &&
   [ "$(sha256sum "$sdk" | cut -d' ' -f1)" = 2433d902270b787373acc9d56d776fbd002e349a023d6fd999b19230c4e2c4d7 ]; then
   export ZTE_LAUNCHER_NETWORK_NAME_B31=1
  fi;;
esac
[ ! -e /tmp/zte-vpn-screen ] || plain
state=/tmp/zte-launcher
if [ ! -e "$state" ]; then mkdir -m 700 "$state"; fi
[ -d "$state" ] && [ ! -L "$state" ] && [ "$(stat -c %u:%a "$state")" = 0:700 ] || plain
rm -f "$state/ready" "$state/page" "$state/status"
# pidof alone is insufficient: DRM can remain owned briefly after UI exit.
for n in $(seq 1 100); do
 [ ! -r /sys/kernel/debug/dri/0/clients ] && break
 [ "$(wc -l < /sys/kernel/debug/dri/0/clients)" -eq 1 ] && break
 sleep 0.1
done
if [ -r /sys/kernel/debug/dri/0/clients ] && [ "$(wc -l < /sys/kernel/debug/dri/0/clients)" -ne 1 ]; then
 printf '%s\n' DISPLAY_BUSY > "$root/failed"
 plain
fi
export LD_PRELOAD="$root/launcher.so" ZTE_LAUNCHER=1
exec "$stock"
