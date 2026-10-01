#!/bin/sh
# All executable dashboard files live below one application-owned private root.
set -eu
umask 077
runtime=/data/zte-dashboard-runtime
for dir in /data "$runtime"; do
    test -d "$dir" && test ! -L "$dir" || exit 1
    test "$(stat -c %u "$dir")" = 0
    mode=$(stat -c %a "$dir"); test "$((0$mode & 022))" = 0
done
test "$(stat -c %a "$runtime")" = 700
for file in dashboard.log dashboard.pid; do
    path=$runtime/$file
    if [ -e "$path" ] || [ -L "$path" ]; then
        test -f "$path" && test ! -L "$path" || exit 1
        test "$(stat -c '%u:%h' "$path")" = 0:1
        mode=$(stat -c %a "$path"); test "$((0$mode & 022))" = 0
    else (umask 077; set -C; : > "$path"); fi
done
sh "$runtime/stop-owned-listener.sh" dashboard-uhttpd 1F90
sleep 1
test -L "$runtime/current"
docroot=$(readlink -f "$runtime/current")
case "$docroot" in /data/www|/data/open-u60-dashboards/*|/data/zte-dashboard-runtime/dashboards/*) ;; *) exit 1;; esac
test -d "$docroot"
test -x "$runtime/dashboard-html.sh"
trap '' HUP
nohup "$runtime/dashboard-uhttpd" -f -h "$docroot" -p 0.0.0.0:8080 -D -i ".html=$runtime/dashboard-html.sh" >"$runtime/dashboard.log" 2>&1 </dev/null &
echo $! > "$runtime/dashboard.pid"
