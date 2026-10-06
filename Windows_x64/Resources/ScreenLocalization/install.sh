#!/bin/sh
# Screen localization manager for exact, independently verified UI profiles. A pinned, reversible stock-UI init hook is
# needed because /etc's persistent overlay mounts after procd queues rc.d paths.
# No rc.local, modem/NV or read-only rootfs writes.
# install: sh STAGE/install.sh install STAGE CID
# runtime: sh /data/zte-imei-screen-ru/manager.sh status|enable|disable [CID]
# S47 calls boot; stock S48 owns the first screen start.
set -eu
umask 077
root=/data/zte-imei-screen-ru
owner_tag=zte-imei-screen-ru-v1
hook=/etc/init.d/zte_imei_screen_ru
boot_link=/etc/rc.d/S47zte_imei_screen_ru
lock=/tmp/zte-imei-screen-ru.lock
service=/etc/init.d/zte_topsw_devui
english_target=/usr/ui/language/English.ini
chinese_target=/usr/ui/language/Chinese.ini
ui_target=/usr/bin/zte_topsw_devui
cache_target=/cache/language.txt
revision=20261006
english_sha=d97925e40f9c119e05dd692e8fbce36593b55aa3faf718af373b2cb57075981a
chinese_sha=5c4b6e3896593172608f2d8890da56c7ff521667129375d0a52383243bb760df
patched_ui_sha=16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4
original_english_sha=47348faa9783bc69109743eb9cfcc3bd3888508040e9eca51cb4a6460b7a70ce
original_chinese_sha=b84c05af9046dd2458b2220633320fb0089e1000e03c45c3dc81dc72df0c44fc
original_ui_sha=e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9
service_sha=8b25166707a21bb3b55f77d9af34822a39aa5e8058b5c521431f0379386051e9
original_init_sha=a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35
patched_init_sha=0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50
mode=${1:-}
expected_cid=
lock_owned=0
mutation=0
restart_after=1
error_code=
data_device=

hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
fail() { error_code=$1; printf 'SCREEN_RU_ERROR %s\n' "$1" >&2; exit 1; }
exists() { test -e "$1" || test -L "$1"; }
regular() { test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0; }
safe_dir() {
    test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || return 1
    permissions=$(stat -c %a "$1") || return 1
    case "$permissions" in ''|*[!0-7]*) return 1;; esac
    test "$((0$permissions & 022))" = 0
}
private_dir() { safe_dir "$1" && test "$(stat -c %a "$1")" = 700; }
valid_cid() { test "${#1}" = 32 && case "$1" in *[!a-f0-9]*) return 1;; esac; }
is_mounted() { awk -v target="$1" '$5 == target {n++} END {exit !n}' /proc/self/mountinfo; }
owned_mount() {
    awk -v target="$1" -v root="/zte-imei-screen-ru/$2" -v dev="$data_device" '
      $5 == target {n++; if($4==root && $3==dev) owned++}
      END {exit !(n==1 && owned==1)}' /proc/self/mountinfo
}
layout_safe() {
    for directory in /data /etc /etc/init.d /etc/rc.d /usr /usr/bin /usr/ui /usr/ui/language /cache; do safe_dir "$directory" || return 1; done
    for target in "$english_target" "$chinese_target" "$ui_target" "$cache_target"; do regular "$target" || return 1; done
    # Reject foreign mounts over source directories, target ancestors or cache.
    awk -v root="$root" '
      $5=="/usr" || $5=="/usr/bin" || $5=="/usr/ui" || $5=="/usr/ui/language" || $5=="/cache/language.txt" || $5==root || index($5,root "/")==1 {bad=1}
      END {exit bad}' /proc/self/mountinfo || return 1
    data_device=$(awk '$5=="/data" && $4=="/" && $6 ~ /(^|,)rw(,|$)/ && $6 !~ /(^|,)noexec(,|$)/ {for(i=7;i<=NF;i++) if($i=="-" && $(i+1)=="ext4") {n++; dev=$3}} END {if(n!=1) exit 1; print dev}' /proc/self/mountinfo) || return 1
}
mounts_safe() {
    if is_mounted "$english_target"; then owned_mount "$english_target" English.ini || return 1; fi
    if is_mounted "$chinese_target"; then owned_mount "$chinese_target" Chinese.ini || return 1; fi
    if is_mounted "$ui_target"; then owned_mount "$ui_target" zte_topsw_devui || return 1; fi
}
# Select from the true original, including when the current path is bind-mounted.
# No firmware-name or unrelated radio binary is a screen ABI grant.
select_profile() {
    profile_ui=$ui_target; profile_english=$english_target; profile_chinese=$chinese_target
    if exists "$root"; then
        root_owned || return 1
        profile_ui=$root/backup/zte_topsw_devui
        profile_english=$root/backup/English.ini; profile_chinese=$root/backup/Chinese.ini
        regular "$root/backup/zte_topsw_devui.init" && test "$(hash "$root/backup/zte_topsw_devui.init")" = "$original_init_sha" || return 1
    fi
    regular "$profile_ui" && regular "$profile_english" && regular "$profile_chinese" || return 1
    case "$(hash "$profile_ui")" in
      e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9)
        screen_profile=b31
        original_ui_sha=e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9
        patched_ui_sha=16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4
        original_english_sha=47348faa9783bc69109743eb9cfcc3bd3888508040e9eca51cb4a6460b7a70ce;;
      8d2ebbde880934f52195ad9595815d728f7aa4671bb0633d5a5149b09467ae90)
        screen_profile=fly-b28
        original_ui_sha=8d2ebbde880934f52195ad9595815d728f7aa4671bb0633d5a5149b09467ae90
        patched_ui_sha=d6c3cd409705d5aa9c12185c84074513b159088025f005da7dbf01c51e3c3715
        original_english_sha=24a1022bf9380cfadaf4c4a737f1f0ce8ecf1ad025563376f7dd83eb94e6ceae;;
      *) return 1;;
    esac
    test "$(hash "$profile_english")" = "$original_english_sha" && test "$(hash "$profile_chinese")" = "$original_chinese_sha"
}
font_valid() {
    safe_dir /usr/ui/fonts && regular /usr/ui/fonts/ZTEZhengYuan.ttf &&
    test "$(hash /usr/ui/fonts/ZTEZhengYuan.ttf)" = b8b1aca17b0e53c2ea7e840f7fe5d6f05db038f2d549fde95c1308a600665a56
}
originals_visible() {
    test "$(hash "$english_target")" = "$original_english_sha" && test "$(hash "$chinese_target")" = "$original_chinese_sha" && test "$(hash "$ui_target")" = "$original_ui_sha"
}
root_owned() {
    private_dir "$root" && regular "$root/owner" && test "$(cat "$root/owner")" = "$owner_tag" || return 1
    # Only this manager's known files may occupy the installation directory.
    for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        exists "$entry" || continue
        case "${entry##*/}" in
          backup) private_dir "$entry" || return 1;;
          owner|cid|English.ini|Chinese.ini|zte_topsw_devui|manager.sh|manager.sha256|service.sh|.enabled|.enabled.new|.transaction|.last-error) regular "$entry" || return 1;;
          *) return 1;;
        esac
    done
    regular "$root/cid" && valid_cid "$(cat "$root/cid")" || return 1
    test "$(cat "$root/cid")" = "$(cat /sys/block/mmcblk0/device/cid)" || return 1
    if test -n "$expected_cid"; then test "$(cat "$root/cid")" = "$expected_cid" || return 1; fi
    if exists "$root/backup"; then
        private_dir "$root/backup" || return 1
        for entry in "$root/backup"/* "$root/backup"/.[!.]* "$root/backup"/..?*; do
            exists "$entry" || continue
            case "${entry##*/}" in English.ini|Chinese.ini|zte_topsw_devui|zte_topsw_devui.init|language|cache|cache.sha256) regular "$entry" || return 1;; *) return 1;; esac
        done
    fi
}
assets_valid() {
    regular "$root/English.ini" && test "$(hash "$root/English.ini")" = "$english_sha" &&
    regular "$root/Chinese.ini" && test "$(hash "$root/Chinese.ini")" = "$chinese_sha" &&
    regular "$root/zte_topsw_devui" && test "$(hash "$root/zte_topsw_devui")" = "$patched_ui_sha" && test "$(stat -c %a "$root/zte_topsw_devui")" = 755 &&
    regular "$root/service.sh" && test "$(hash "$root/service.sh")" = "$service_sha" &&
    regular "$root/manager.sh" && regular "$root/manager.sha256" && test "$(hash "$root/manager.sh")" = "$(cat "$root/manager.sha256")"
}
hook_safe() {
    regular "$service" && test -x "$service" && test "$(stat -c %a "$service")" = 755 || return 1
    current_init_sha=$(hash "$service")
    test "$current_init_sha" = "$original_init_sha" || test "$current_init_sha" = "$patched_init_sha" || return 1
    if exists "$hook"; then regular "$hook" && test "$(hash "$hook")" = "$service_sha" || return 1; fi
    if exists "$boot_link"; then test -L "$boot_link" && test "$(readlink "$boot_link")" = ../init.d/zte_imei_screen_ru || return 1; fi
}
hook_present() { regular "$hook" && test "$(hash "$hook")" = "$service_sha" && test -L "$boot_link" && test "$(readlink "$boot_link")" = ../init.d/zte_imei_screen_ru && test "$(hash "$service")" = "$patched_init_sha"; }
write_stock_hook() {
    hook_safe || return 1
    case "$1" in patch) desired_init_sha=$patched_init_sha;; restore) desired_init_sha=$original_init_sha;; *) return 1;; esac
    if test "$(hash "$service")" = "$desired_init_sha"; then return 0; fi
    regular "$root/backup/zte_topsw_devui.init" && test "$(hash "$root/backup/zte_topsw_devui.init")" = "$original_init_sha" || return 1
    init_temp="/etc/init.d/.zte_topsw_devui.screen-ru-$$"
    ! exists "$init_temp" || return 1
    cp -p "$root/backup/zte_topsw_devui.init" "$init_temp" || return 1
    if test "$1" = patch; then
        # S48 already existed in the lowerdir before S03 mounted /etc. Its body
        # is read afterwards, so this block works even if new S47 wasn't queued.
        # No PID + no manager lock also avoids recursive procd start/stop calls.
        if ! awk '
          {print}
          $0 == "start_service() {" {
            print "        # BEGIN zte-imei-screen-ru-v1: prepare before the queued stock S48 UI."
            print "        if [ ! -d /tmp/zte-imei-screen-ru.lock ] && ! pidof zte_topsw_devui >/dev/null 2>&1; then"
            print "                if [ -f /etc/init.d/zte_imei_screen_ru ] && [ ! -L /etc/init.d/zte_imei_screen_ru ]; then"
            print "                        case \"$(sha256sum /etc/init.d/zte_imei_screen_ru 2>/dev/null)\" in"
            print "                                \"8b25166707a21bb3b55f77d9af34822a39aa5e8058b5c521431f0379386051e9 \"*)"
            print "                                        /etc/init.d/zte_imei_screen_ru boot >&2 || true"
            print "                                        ;;"
            print "                        esac"
            print "                fi"
            print "        fi"
            print "        # END zte-imei-screen-ru-v1"
          }' "$root/backup/zte_topsw_devui.init" > "$init_temp"; then rm -f "$init_temp"; return 1; fi
    fi
    if test "$(hash "$init_temp")" != "$desired_init_sha" || ! hook_safe; then rm -f "$init_temp"; return 1; fi
    chmod 755 "$init_temp" || { rm -f "$init_temp"; return 1; }
    test -x "$init_temp" && test "$(stat -c %a "$init_temp")" = 755 || { rm -f "$init_temp"; return 1; }
    mv "$init_temp" "$service" || return 1
    sync
    test "$(hash "$service")" = "$desired_init_sha"
}
enabled_marker() { regular "$root/.enabled" && test "$(cat "$root/.enabled")" = enabled-v1; }
external_guards() {
    ! exists /tmp/zte-vpn-screen && ! exists /tmp/zte-screen-russian-menu-trial.lock && ! exists /data/local/tmp/zte-imei-installations/active && ! exists /tmp/fota_install_processing
}
uci_safe() {
    pending=$(uci -q changes zwrt_deviceui) || return 1
    test -z "$pending" || printf '%s\n' "$pending" | awk 'index($0,"zwrt_deviceui.Device.device_language=") != 1 {bad=1} END {exit bad}'
}
set_language() {
    uci_safe || return 1
    case "$1" in en) cache_value=english;; cn) cache_value=chinese;; *) return 1;; esac
    if test "$(uci -q get zwrt_deviceui.Device.device_language)" != "$1" || test -n "$pending"; then
        uci -q set "zwrt_deviceui.Device.device_language=$1" && uci -q commit zwrt_deviceui || return 1
    fi
    if test "$1" = en && regular "$root/backup/cache" && regular "$root/backup/cache.sha256" && test "$(cat "$root/backup/cache")" = english && test "$(hash "$root/backup/cache")" = "$(cat "$root/backup/cache.sha256")"; then
        cp -p "$root/backup/cache" "$cache_target" || return 1
    else
        printf '%s' "$cache_value" > "$cache_target" || return 1
    fi
    test "$(uci -q get zwrt_deviceui.Device.device_language)" = "$1" && test "$(cat "$cache_target")" = "$cache_value"
}
run_service() {
    "$service" "$1" >&2 &
    service_pid=$!; service_wait=30
    while kill -0 "$service_pid" 2>/dev/null; do
        if test "$service_wait" -le 0; then
            kill -TERM "$service_pid" 2>/dev/null || true; sleep 1
            kill -KILL "$service_pid" 2>/dev/null || true
            wait "$service_pid" 2>/dev/null || true; return 1
        fi
        service_wait=$((service_wait - 1)); sleep 1
    done
    wait "$service_pid"
}
stop_screen() {
    run_service stop || true
    screen_wait=20
    while pidof zte_topsw_devui >/dev/null 2>&1; do test "$screen_wait" -gt 0 || return 1; screen_wait=$((screen_wait - 1)); sleep 1; done
}
start_screen() {
    current_ui=$(hash "$ui_target")
    test "$current_ui" = "$original_ui_sha" || test "$current_ui" = "$patched_ui_sha" || return 1
    if pidof zte_topsw_devui >/dev/null 2>&1; then return 0; fi
    run_service start || true
    screen_wait=20
    until pidof zte_topsw_devui >/dev/null 2>&1; do test "$screen_wait" -gt 0 || return 1; screen_wait=$((screen_wait - 1)); sleep 1; done
    stable_pid=$(pidof zte_topsw_devui | awk '{print $1}')
    sleep 2
    test -n "$stable_pid" && test "$(pidof zte_topsw_devui 2>/dev/null | awk '{print $1}')" = "$stable_pid"
}
acquire_lock() {
    if ! mkdir "$lock" 2>/dev/null; then
        private_dir "$lock" && regular "$lock/owner" && test "$(cat "$lock/owner")" = "$owner_tag" && regular "$lock/pid" || return 1
        previous_pid=$(cat "$lock/pid")
        case "$previous_pid" in ''|*[!0-9]*) return 1;; esac
        kill -0 "$previous_pid" 2>/dev/null && return 1
        # No unknown entries are removed; rmdir fails if anything else is present.
        rm "$lock/owner" "$lock/pid" && rmdir "$lock" && mkdir "$lock" || return 1
    fi
    printf '%s\n' "$owner_tag" > "$lock/owner"
    printf '%s\n' "$$" > "$lock/pid"
    lock_owned=1
}
release_lock() {
    if test "$lock_owned" = 1 && test "$(cat "$lock/pid" 2>/dev/null || true)" = "$$"; then rm -f "$lock/owner" "$lock/pid"; rmdir "$lock" 2>/dev/null || true; fi
    lock_owned=0
}
recover_original() {
    # Journal must be durable before revoking .enabled, including failed boots.
    if ! exists "$root/.transaction"; then printf '%s\n' recovery > "$root/.transaction" || return 1; fi
    regular "$root/.transaction" || return 1
    sync
    # .enabled is revoked before any restoration. S47 remains a recovery hook.
    rm -f "$root/.enabled" "$root/.enabled.new" || return 1
    sync
    layout_safe && mounts_safe && uci_safe || return 1
    if test "$restart_after" = 1 || pidof zte_topsw_devui >/dev/null 2>&1; then stop_screen || return 1; fi
    set_language en || return 1
    if is_mounted "$ui_target"; then owned_mount "$ui_target" zte_topsw_devui && umount "$ui_target" || return 1; fi
    if is_mounted "$chinese_target"; then owned_mount "$chinese_target" Chinese.ini && umount "$chinese_target" || return 1; fi
    if is_mounted "$english_target"; then owned_mount "$english_target" English.ini && umount "$english_target" || return 1; fi
    originals_visible || return 1
    # Restore the exact init body only after English and stock files are back.
    write_stock_hook restore || return 1
    if test "$restart_after" = 1; then start_screen || return 1; fi
    rm -f "$root/.transaction" "$root/.enabled.new" || return 1
    sync
}
report_status() {
    report_state=absent; mounted=0; boot=0
    for target in "$english_target" "$chinese_target" "$ui_target"; do if is_mounted "$target"; then mounted=$((mounted + 1)); fi; done
    language=$(uci -q get zwrt_deviceui.Device.device_language 2>/dev/null || true)
    case "$language" in en|cn) ;; *) language=other;; esac
    pid=$(pidof zte_topsw_devui 2>/dev/null | awk '{print $1}' || true)
    case "$pid" in ''|*[!0-9]*) pid=0;; esac
    if exists "$root"; then
        report_state=error
        if root_owned && layout_safe && mounts_safe && hook_safe; then
            if enabled_marker && hook_present; then boot=1; fi
            if test "$boot" = 1 && test "$mounted" = 3 && { test "$pid" != 0 || test "$mode" = boot; } && ! exists "$root/.transaction" && assets_valid && test "$(hash "$english_target")" = "$english_sha" && test "$(hash "$chinese_target")" = "$chinese_sha" && test "$(hash "$ui_target")" = "$patched_ui_sha"; then
                report_state=enabled
            elif ! exists "$root/.enabled" && ! exists "$root/.transaction" && test "$mounted" = 0 && originals_visible; then report_state=disabled; fi
        fi
    elif test "$mounted" != 0 || exists "$hook" || exists "$boot_link"; then report_state=error; fi
    if test -n "$error_code"; then report_state=error; fi
    printf 'SCREEN_RU_STATUS state=%s language=%s mounted=%s boot=%s pid=%s revision=%s\n' "$report_state" "$language" "$mounted" "$boot" "$pid" "$revision"
}
finish() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" != 0 && test "$mutation" = 1; then
        if root_owned; then
            printf '%s\n' "${error_code:-INTERRUPTED}" > "$root/.last-error" || true
            if ! recover_original; then
                printf 'SCREEN_RU_ERROR RECOVERY_PENDING\n' >&2
                # Keep the journal/error, but leave a usable English screen
                # after a recoverable partial unmount. Never start at cold boot
                # or through a foreign mount / an unknown executable.
                if test "$restart_after" = 1 && layout_safe && mounts_safe && test "$(uci -q get zwrt_deviceui.Device.device_language)" = en && test "$(cat "$cache_target")" = english; then
                    start_screen || true
                fi
            fi
        fi
    fi
    release_lock
    report_status
    exit "$result"
}
trap finish EXIT
trap 'fail INTERRUPTED' HUP INT TERM

# Validate commands before touching device state.
test "$(id -u)" = 0 || fail ROOT_REQUIRED
test "$(uname -s)" = Linux && test "$(uname -m)" = aarch64 || fail PLATFORM
case "$mode" in
  install) test "$#" = 3 || fail ARGUMENTS; stage=$2; expected_cid=$3; valid_cid "$expected_cid" || fail CID_FORMAT;;
  status|enable|disable) test "$#" -ge 1 && test "$#" -le 2 || fail ARGUMENTS; expected_cid=${2:-};;
  boot) test "$#" = 1 || fail ARGUMENTS; restart_after=0; if pidof zte_topsw_devui >/dev/null 2>&1; then restart_after=1; fi;;
  *) fail MODE;;
esac
if test -n "$expected_cid"; then valid_cid "$expected_cid" && test "$expected_cid" = "$(cat /sys/block/mmcblk0/device/cid)" || fail CID_CHANGED; fi
select_profile || fail SCREEN_PROFILE
if test "$mode" = status; then exit 0; fi
layout_safe || fail UNSAFE_LAYOUT
external_guards || fail OTHER_DEVICE_OPERATION
acquire_lock || fail LOCK_BUSY

if test "$mode" = install; then
    case "$stage" in /tmp/zte-screen-ru-install-*) ;; *) fail STAGE_PATH;; esac
    token=${stage#/tmp/zte-screen-ru-install-}
    test "${#token}" = 36 || fail STAGE_TOKEN
    case "$token" in *[!a-f0-9-]*) fail STAGE_TOKEN;; esac
    private_dir "$stage" || fail STAGE_PERMISSIONS
    for file in English.ini Chinese.ini zte_topsw_devui install.sh service.sh; do regular "$stage/$file" || fail STAGE_FILE; done
    test "$(hash "$stage/English.ini")" = "$english_sha" && test "$(hash "$stage/Chinese.ini")" = "$chinese_sha" && test "$(hash "$stage/zte_topsw_devui")" = "$patched_ui_sha" && test "$(hash "$stage/service.sh")" = "$service_sha" || fail STAGE_HASH
    test "$(hash "$stage/install.sh")" = "$(hash "$0")" || fail STAGE_MANAGER
    font_valid || fail FONT_CHANGED
    hook_safe || fail FOREIGN_BOOT_HOOK
    if exists "$root"; then
        root_owned || fail UNKNOWN_INSTALLATION
        ! exists "$root/.transaction" || fail TRANSACTION_PENDING
        installed_manager=$(hash "$root/manager.sh")
        case "$installed_manager" in
          6aed6654afb7a4fde7792a5f6034aa41e15b0fd77d794ed04d3a12c111c95fd2)
            prior_english=1f16a064f6caf5837e9bcea0afcc6d27873a2995cd70b7e4c0d3a254843572a5
            prior_chinese=b4f09012bd4f291dd60c86ab107521ea3a7dc86b7f85c4f0094a4f75deb0156c;;
          586a7727fb24a5701990c7cd82889887220c1c5566261c53ca21f3bb12549bfa)
            prior_english=ff50ba66260b636a3bc10b90baae3df0ba68fcc37f343288ea802d3e65fea11e
            prior_chinese=92dd43aff9057ba801a4e41069168a658bd8ed5acd3a12fddee1e245b05c5d98;;
          810aae3c07c8019f2d0657f2bad6f1ee38f1dea5f1081210ab144478dd87c7b8)
            prior_english=$english_sha; prior_chinese=$chinese_sha;;
          *) prior_english=; prior_chinese=;;
        esac
        if test -n "$prior_english"; then
            test "$screen_profile" = b31 || fail UNKNOWN_INSTALLATION
            test "$(hash "$root/English.ini")" = "$prior_english" &&
            test "$(hash "$root/Chinese.ini")" = "$prior_chinese" &&
            test "$(hash "$root/zte_topsw_devui")" = "$patched_ui_sha" &&
            test "$(hash "$root/service.sh")" = "$service_sha" &&
            test "$(cat "$root/manager.sha256")" = "$(hash "$root/manager.sh")" || fail UNKNOWN_INSTALLATION
            mutation=1
            recover_original || fail UPGRADE_RECOVERY_FAILED
            printf '%s\n' upgrade > "$root/.transaction"
            sync
            for file in English.ini Chinese.ini; do cp "$stage/$file" "$root/$file" || fail UPGRADE_COPY; done
            cp "$stage/install.sh" "$root/manager.sh" || fail UPGRADE_COPY
            chmod 700 "$root/manager.sh"
            hash "$root/manager.sh" > "$root/manager.sha256"
            sync
        fi
        assets_valid || fail UNKNOWN_INSTALLATION
        test "$(hash "$root/manager.sh")" = "$(hash "$stage/install.sh")" || fail MANAGER_VERSION
    else
        test ! -e "$hook" && ! exists "$boot_link" || fail ORPHAN_BOOT_HOOK
        test "$(hash "$service")" = "$original_init_sha" || fail STOCK_INIT_CHANGED
        ! is_mounted "$english_target" && ! is_mounted "$chinese_target" && ! is_mounted "$ui_target" && originals_visible || fail ORIGINAL_CHANGED
        initial_language=$(uci -q get zwrt_deviceui.Device.device_language)
        initial_cache=$(cat "$cache_target")
        case "$initial_language:$initial_cache" in en:english|cn:chinese) ;; *) fail LANGUAGE_CHANGED;; esac
        uci_safe && test -z "$pending" || fail UCI_PENDING_CHANGES
        pending_root="/data/zte-imei-screen-ru.install-$token"
        ! exists "$pending_root" || fail STAGED_INSTALL_EXISTS
        mkdir "$pending_root" && mkdir "$pending_root/backup" || fail PREPARE_DIRECTORY
        printf '%s\n' "$owner_tag" > "$pending_root/owner"
        printf '%s\n' "$expected_cid" > "$pending_root/cid"
        for file in English.ini Chinese.ini zte_topsw_devui service.sh; do cp "$stage/$file" "$pending_root/$file" || fail COPY_PAYLOAD; done
        cp "$stage/install.sh" "$pending_root/manager.sh"
        hash "$pending_root/manager.sh" > "$pending_root/manager.sha256"
        chmod 755 "$pending_root/zte_topsw_devui"
        chmod 700 "$pending_root/manager.sh" "$pending_root/service.sh"
        cp -p "$english_target" "$pending_root/backup/English.ini"
        cp -p "$chinese_target" "$pending_root/backup/Chinese.ini"
        cp -p "$ui_target" "$pending_root/backup/zte_topsw_devui"
        cp -p "$service" "$pending_root/backup/zte_topsw_devui.init"
        test "$(hash "$pending_root/backup/zte_topsw_devui.init")" = "$original_init_sha" || fail INIT_BACKUP_CHANGED
        uci -q get zwrt_deviceui.Device.device_language > "$pending_root/backup/language"
        cp -p "$cache_target" "$pending_root/backup/cache"
        hash "$pending_root/backup/cache" > "$pending_root/backup/cache.sha256"
        # Keep cache metadata for an exact EN restore; its parent is private.
        chmod 600 "$pending_root/backup/English.ini" "$pending_root/backup/Chinese.ini" "$pending_root/backup/zte_topsw_devui" "$pending_root/backup/language" "$pending_root/backup/cache.sha256"
        printf '%s\n' install > "$pending_root/.transaction"
        sync
        mv "$pending_root" "$root" || fail PUBLISH_INSTALLATION
        mutation=1
        root_owned && assets_valid || fail COPIED_INSTALLATION_INVALID
    fi
    mode=enable
fi

root_owned || fail UNKNOWN_INSTALLATION
mounts_safe || fail FOREIGN_MOUNT
hook_safe || fail FOREIGN_BOOT_HOOK
if test "$mode" = disable; then
    uci_safe || fail UCI_PENDING_CHANGES
    printf '%s\n' disable > "$root/.transaction"
    mutation=1
    sync
    recover_original || fail DISABLE_FAILED
    mutation=0
    rm -f "$root/.last-error"
    exit 0
fi
if test "$mode" = boot && ! enabled_marker; then
    if exists "$root/.transaction" || exists "$root/.enabled" || is_mounted "$english_target" || is_mounted "$chinese_target" || is_mounted "$ui_target"; then
        mutation=1
        recover_original || fail BOOT_RECOVERY_FAILED
        mutation=0
    fi
    exit 0
fi
if test "$mode" = boot && exists "$root/.transaction"; then
    mutation=1
    recover_original || fail BOOT_RECOVERY_FAILED
    mutation=0
    exit 0
fi
# From this point errors in an enabled boot also revoke the marker and restore EN.
if test "$mode" = boot; then mutation=1; fi
assets_valid || fail ASSET_INTEGRITY
font_valid || fail FONT_CHANGED
uci_safe || fail UCI_PENDING_CHANGES
for item in English.ini Chinese.ini zte_topsw_devui; do
    case "$item" in English.ini) target=$english_target; digest=$original_english_sha;; Chinese.ini) target=$chinese_target; digest=$original_chinese_sha;; *) target=$ui_target; digest=$original_ui_sha;; esac
    if ! is_mounted "$target"; then test "$(hash "$target")" = "$digest" || fail ORIGINAL_CHANGED; fi
done
if test "$mode" = enable && exists "$root/.transaction" && test "$mutation" != 1; then fail TRANSACTION_PENDING; fi
# Install/reinstall our own recovery hook before any cn setting can be committed.
if ! exists "$hook"; then cp "$root/service.sh" "$hook" && chmod 755 "$hook" || fail INSTALL_HOOK; fi
if ! exists "$boot_link"; then ln -s ../init.d/zte_imei_screen_ru "$boot_link" || fail INSTALL_BOOT_LINK; fi
write_stock_hook patch || fail INSTALL_STOCK_HOOK
hook_present || fail BOOT_HOOK_VERIFY
if test "$mode" != boot; then
    printf '%s\n' enable > "$root/.transaction"
    mutation=1
    sync
    rm -f "$root/.enabled" "$root/.enabled.new"
    sync
else
    current_language=$(uci -q get zwrt_deviceui.Device.device_language)
    case "$current_language" in en|cn) ;; *) fail LANGUAGE_CHANGED;; esac
fi
if test "$restart_after" = 1; then stop_screen || fail SCREEN_STOP; fi
if ! is_mounted "$english_target"; then mount -o bind "$root/English.ini" "$english_target" || fail MOUNT_ENGLISH; fi
if ! is_mounted "$chinese_target"; then mount -o bind "$root/Chinese.ini" "$chinese_target" || fail MOUNT_CHINESE; fi
if ! is_mounted "$ui_target"; then mount -o bind "$root/zte_topsw_devui" "$ui_target" || fail MOUNT_UI; fi
mounts_safe && test "$(hash "$english_target")" = "$english_sha" && test "$(hash "$chinese_target")" = "$chinese_sha" && test "$(hash "$ui_target")" = "$patched_ui_sha" || fail MOUNT_VERIFY
if test "$mode" != boot; then set_language cn || fail LANGUAGE_COMMIT; fi
if test "$restart_after" = 1; then start_screen || fail SCREEN_START; fi
if test "$mode" != boot; then
    printf '%s\n' enabled-v1 > "$root/.enabled.new"
    sync
    mv "$root/.enabled.new" "$root/.enabled"
    sync
fi
# A crash with marker+journal is recovered as disabled; never lose both at cn.
rm -f "$root/.transaction" "$root/.last-error"
sync
mutation=0
exit 0
