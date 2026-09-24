#!/bin/sh
# Keep the optional extension attached when the stock service is restarted by
# localization, language changes or firmware services. Never change its init file.
set -eu
umask 077
root=/data/zte-launcher
lock=/tmp/zte-imei-app.lock
owned=0
unlock() {
 if [ "$owned" = 1 ] && [ "$(cat "$lock/owner" 2>/dev/null)" = "launcher-watch-$$" ]; then
  rm -f "$lock/owner"; rmdir "$lock"; owned=0
 fi
}
trap unlock EXIT
trap 'exit 0' INT TERM
set_ui() {
 if ! mkdir "$lock" 2>/dev/null; then return 1; fi
 owned=1; printf 'launcher-watch-%s' $$ > "$lock/owner"
 if [ -e /tmp/zte-imei-screen-ru.lock ] || [ -e /tmp/zte-vpn-screen ] || [ -e /tmp/zte-launcher-trial/supervisor ]; then unlock; return 1; fi
 case "$(sha256sum /etc/init.d/zte_topsw_devui | cut -d' ' -f1)" in
  a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35|0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50) ;;
  *) unlock; return 1;;
 esac
 # Refuse an unrelated replacement of the stock service.
 cfg=$(ubus call service list '{"name":"zte_topsw_devui"}') || { unlock; return 1; }
 command=$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[0]')
 case "$command" in
  /usr/bin/zte_topsw_devui) ;;
  /bin/sh)
   script=$(printf '%s' "$cfg" | jsonfilter -e '@.zte_topsw_devui.instances.instance1.command[1]')
   [ "$script" = "$root/launcher-run.sh" ] || { unlock; return 1; };;
  *) unlock; return 1;;
 esac
 if [ "$1" = extended ]; then
  ubus call service set '{"name":"zte_topsw_devui","instances":{"instance1":{"command":["/bin/sh","/data/zte-launcher/launcher-run.sh"],"respawn":["3600","5","5"]}}}' >/dev/null
 else
  ubus call service set '{"name":"zte_topsw_devui","instances":{"instance1":{"command":["/usr/bin/zte_topsw_devui"],"respawn":["3600","5","5"]}}}' >/dev/null
 fi
 unlock
}
last_pid=0
restart_window=0
restarts=0
fallback=0
attempted=0
misses=0
while [ -f "$root/enabled" ]; do
 sleep 3
 [ ! -e "$lock" ] && [ ! -e /tmp/zte-imei-screen-ru.lock ] && [ ! -e /tmp/zte-vpn-screen ] && [ ! -e /tmp/zte-launcher-trial/supervisor ] || continue
 if [ -e "$root/failed" ]; then
  if [ "$fallback" = 0 ]; then set_ui plain && fallback=1 || true; fi
  continue
 fi
 pid=$(pidof zte_topsw_devui 2>/dev/null || true)
 case "$pid" in ''|*[!0-9]*)
  if [ "$attempted" = 1 ]; then misses=$((misses+1)); fi
  if [ "$misses" -ge 4 ]; then printf '%s\n' START_FAILED > "$root/failed"; fi
  continue;;
 esac
 if grep -qF "$root/launcher.so" "/proc/$pid/maps"; then
  if [ "$(cat /tmp/zte-launcher/ready 2>/dev/null)" = "$pid" ]; then
   if [ "$last_pid" != 0 ] && [ "$last_pid" != "$pid" ]; then
    now=$(cut -d. -f1 /proc/uptime)
    if [ "$((now-restart_window))" -ge 60 ]; then restart_window=$now;restarts=0;fi
    restarts=$((restarts+1))
    [ "$restarts" -lt 2 ] || printf '%s\n' REPEATED_UI_RESTART > "$root/failed"
    last_pid=$pid;misses=0
   else last_pid=$pid; misses=0; fi
  else
   misses=$((misses+1));[ "$misses" -lt 10 ] || printf '%s\n' NO_PAGES > "$root/failed"
  fi
 else
  if [ "$attempted" = 1 ]; then misses=$((misses+1)); fi
  if [ "$misses" -ge 10 ]; then printf '%s\n' NO_EXTENSION > "$root/failed";continue;fi
  if set_ui extended; then attempted=1; fi
 fi
done
set_ui plain || true
