#!/bin/sh
# Upgrade only recognized controllers; keep a complete rollback snapshot.
set -eu
umask 077
ROOT=/data/zte-vpn
stage=${1:-}
case "$stage" in /tmp/zte-vpn-agent-????????-????-????-????-????????????) ;; *) exit 64;; esac
helper_sha=1c0e3e6d308a6c4b161faf896a00437b8e011fe5b7eff7969b9870c85d8d0c5c
manager_sha=f836b522c48a115c75233594207191214459f624180b7f98fabb754517d695b1
configure_sha=a41e5de83268c6963a54760c8b5f5362ea2c5cdac81bede6ac281fea81e28543
hash() { sha256sum "$1" | awk '{print $1}'; }
known() {
    case "$1" in 8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827|96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88|48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4|572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5|80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23|3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3|e2ffd02708220d332bf31f7f1f4c3abe369fbc2af1665af885c1f4375a884ff0|c67f5fdc44ee1f90c38dca15fd452c18743def22f776018aaac270863eafb229|bdc6aa07f217ce38e34e113d279e0d983d307fefd0f58027a9c221861f953dbf|9c2e3c21eecace7031c4029c969efdec44241f000716447df805f3020dfce95e|29e98c9301609b4f20ea94c7e8b208c25786690be451bae05145721a35b91179|9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce|cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0|3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca|f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4|1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231|a388d8fa771b3e4bb46d500202ff750df410b4e6608d0f4902288b6aad16d731|7a12d8b869d064229270a264e8de9adf64f620337995fb186854c35cadbee068|7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb|"$helper_sha") return 0;; *) return 1;; esac
}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] && [ "$(stat -c '%u:%a' "$ROOT")" = 0:700 ]
[ ! -e "$ROOT/transaction" ] && [ ! -L "$ROOT/transaction" ]
for file in vpnctl manager.sh configure.lua; do [ -f "$stage/$file" ] && [ ! -L "$stage/$file" ]; done
[ "$(hash "$stage/vpnctl")" = "$helper_sha" ]
[ "$(hash "$stage/manager.sh")" = "$manager_sha" ]
[ "$(hash "$stage/configure.lua")" = "$configure_sha" ]
[ ! -d /tmp/zte-vpn-screen ] || { echo VPN_SCREEN_BUSY >&2; exit 1; }
backup="$ROOT/controller-upgrade"
restore() {
    [ -f "$backup/ready" ] && [ ! -L "$backup/ready" ] || return 0
    known "$(hash "$backup/vpnctl")"
    (cd "$backup" && sha256sum -c SHA256SUMS >/dev/null)
    cp "$backup/manager.sh" "$ROOT/manager.sh.restore"; chmod 700 "$ROOT/manager.sh.restore"
    cp "$backup/vpnctl" "$ROOT/vpnctl.restore"; chmod 700 "$ROOT/vpnctl.restore"
    if [ -f "$backup/configure.lua" ]; then
        cp "$backup/configure.lua" "$ROOT/configure.lua.restore"; chmod 700 "$ROOT/configure.lua.restore"
        mv "$ROOT/configure.lua.restore" "$ROOT/configure.lua"
    fi
    cp "$backup/network" /etc/init.d/network.vpn-restore; chmod 755 /etc/init.d/network.vpn-restore
    mv "$ROOT/manager.sh.restore" "$ROOT/manager.sh"
    mv "$ROOT/vpnctl.restore" "$ROOT/vpnctl"
    mv /etc/init.d/network.vpn-restore /etc/init.d/network
    if [ -f "$backup/network-init.sha256" ]; then cp "$backup/network-init.sha256" "$ROOT/network-init.sha256"; fi
    sync
    "$ROOT/vpnctl" integrity >/dev/null
    rm -rf "$backup"
}
if [ -e "$backup" ]; then
    [ -d "$backup" ] && [ ! -L "$backup" ] && [ "$(stat -c '%u:%a' "$backup")" = 0:700 ]
    restore
    # Incomplete preparation did not modify the installed files.
    [ ! -e "$backup" ] || rm -rf "$backup"
fi
known "$(hash "$ROOT/vpnctl")"
"$ROOT/vpnctl" integrity >/dev/null
if [ "$(hash "$ROOT/vpnctl")" = "$helper_sha" ]; then exit 0; fi
[ -f /etc/init.d/network ] && [ ! -L /etc/init.d/network ]
if [ -f "$ROOT/configured" ]; then
    [ "$(hash /etc/init.d/network)" = "$(cat "$ROOT/network-init.sha256")" ]
    grep -q 'BEGIN zte-vpn-v1:' /etc/init.d/network
fi
old_helper=$(hash "$ROOT/vpnctl"); old_manager=$(hash "$ROOT/manager.sh")
mkdir "$backup"
for file in vpnctl manager.sh configure.lua; do cp -p "$ROOT/$file" "$backup/$file"; done
cp -p /etc/init.d/network "$backup/network"
[ ! -f "$ROOT/network-init.sha256" ] || cp "$ROOT/network-init.sha256" "$backup/network-init.sha256"
(cd "$backup" && sha256sum vpnctl manager.sh configure.lua network > SHA256SUMS)
sync
touch "$backup/ready"; sync
committed=0
finish() {
    result=$?; trap - EXIT HUP INT TERM
    if [ "$committed" = 0 ]; then restore || true; fi
    exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
cp "$stage/vpnctl" "$ROOT/vpnctl.new"; chmod 700 "$ROOT/vpnctl.new"
cp "$stage/manager.sh" "$ROOT/manager.sh.new"; chmod 700 "$ROOT/manager.sh.new"
cp "$stage/configure.lua" "$ROOT/configure.lua.new"; chmod 700 "$ROOT/configure.lua.new"
sed -e "s/$old_helper/$helper_sha/g" -e "s/$old_manager/$manager_sha/g" "$backup/network" > /etc/init.d/network.vpn-new
chmod 755 /etc/init.d/network.vpn-new
sh -n /etc/init.d/network.vpn-new
mv "$ROOT/manager.sh.new" "$ROOT/manager.sh"
mv "$ROOT/configure.lua.new" "$ROOT/configure.lua"
mv "$ROOT/vpnctl.new" "$ROOT/vpnctl"
"$ROOT/vpnctl" integrity >/dev/null
mv /etc/init.d/network.vpn-new /etc/init.d/network
hash /etc/init.d/network > "$ROOT/network-init.sha256"
sync
# The atomic rename commits the update before optional cleanup.
[ ! -e "$ROOT/controller-upgrade.done" ] || rm -rf "$ROOT/controller-upgrade.done"
mv "$backup" "$ROOT/controller-upgrade.done"; sync
committed=1
rm -rf "$ROOT/controller-upgrade.done"
echo VPN_CONTROLLER_UPDATED
