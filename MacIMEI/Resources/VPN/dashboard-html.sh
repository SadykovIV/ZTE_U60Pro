#!/bin/sh
# HTML is a release pointer; hashed JS/CSS may stay cached, HTML must not.
set -eu
file=${1:-}
case "$file" in /data/www/index.html|/data/www/mobile.html|/data/open-u60-dashboards/*/index.html|/data/open-u60-dashboards/*/mobile.html) ;;
    *) printf 'Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found\n'; exit 0;;
esac
[ -f "$file" ] && [ ! -L "$file" ] || exit 1
printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nExpires: 0\r\n\r\n'
exec cat "$file"
