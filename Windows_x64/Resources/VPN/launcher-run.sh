#!/bin/sh
# procd still owns the stock UI; this wrapper only prepares its environment.
set -eu
umask 077
root=/data/zte-launcher
stock=/usr/bin/zte_topsw_devui
plain() { exec "$stock"; }
[ -d "$root" ] && [ ! -L "$root" ] && [ "$(stat -c %u:%a "$root")" = 0:700 ] || plain
[ -f "$root/enabled" ] && [ ! -e "$root/failed" ] || plain
[ "$(cat "$root/owner")" = zte-native-launcher-v1 ] || plain
[ "$(cat "$root/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" ] || plain
(cd "$root" && sha256sum -c launcher.sha256 >/dev/null 2>&1) || plain
case "$(sha256sum "$stock" | cut -d' ' -f1)" in
 e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9|16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4) ;;
 *) plain;;
esac
[ "$(sha256sum /firmware/image/modem.b16 | cut -d' ' -f1)" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 ] || plain
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
