#!/bin/sh
# Keep content-addressed assets available to sessions opened before an update.
set -eu
old=${1:?previous root required}
new=${2:?new root required}
[ -d "$new" ] && [ ! -L "$new" ]
[ -d "$old/assets" ] || exit 0
[ ! -L "$old/assets" ]
mkdir -p "$new/assets"
[ ! -L "$new/assets" ]
for source in "$old"/assets/*; do
    [ -e "$source" ] || continue
    [ -f "$source" ] && [ ! -L "$source" ] || exit 1
    name=${source##*/}
    case "$name" in *[!a-zA-Z0-9_.-]*|.*) exit 1;; esac
    target="$new/assets/$name"
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$source" "$target"
    else
        cp -p "$source" "$target"
    fi
done
