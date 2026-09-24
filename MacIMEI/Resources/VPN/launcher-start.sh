#!/bin/sh
set -eu
root=/data/zte-launcher
[ -d "$root" ] && [ ! -L "$root" ] && [ "$(stat -c %u:%a "$root")" = 0:700 ] || exit 1
(cd "$root" && sha256sum -c launcher.sha256 >/dev/null 2>&1) || exit 1
[ -f /etc/init.d/zte_launcher ] && [ ! -L /etc/init.d/zte_launcher ] || exit 1
cmp -s "$root/launcher-service.sh" /etc/init.d/zte_launcher || exit 1
/etc/init.d/zte_launcher start
