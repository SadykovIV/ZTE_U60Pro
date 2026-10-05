#!/bin/sh
# Read capabilities or control only verified application services for this boot.
set -eu
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
fail() { printf 'ACCESS_ERROR %s\n' "$1" >&2; exit 1; }
hash() { sha256sum "$1" | awk '{print $1}'; }
plain() {
    test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || return 1
    case "$(stat -c %a "$1")" in 600|644|700|755) ;; *) return 1;; esac
}
safe_dir() {
    test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || return 1
    case "$(stat -c %a "$1")" in 700|750|755) ;; *) return 1;; esac
}
identity() {
    test "$(id -u)" = 0 && test "$(uname -m)" = aarch64 &&
    test "$(cat /sys/block/mmcblk0/device/cid)" = "$cid" &&
    test "$(hash /firmware/image/modem.b16)" = 604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263 &&
    test "$(hash /usr/bin/diag-router)" = 55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f
}
# Only PIDs that own a LISTEN socket at the selected port. No name-based kill.
listeners() {
    inodes=$(awk -v port="$1" '$2 ~ (":" port "$") && $4=="0A" {print $10}' /proc/net/tcp /proc/net/tcp6 | sort -u)
    test -n "$inodes" || return 0
    for process in /proc/[0-9]*; do
        test -d "$process/fd" || continue
        matched=0
        for fd in "$process"/fd/*; do
            link=$(readlink "$fd" 2>/dev/null || true)
            for inode in $inodes; do if test "$link" = "socket:[$inode]"; then matched=1; break; fi; done
            test "$matched" = 0 || break
        done
        test "$matched" = 0 || printf '%s\n' "${process#/proc/}"
    done
}
port_open() { awk -v port="$1" '$2 ~ (":" port "$") && $4=="0A" {found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6; }
agent_launcher_valid() {
    plain "$1" || return 1
    # Accept only the generated launcher grammar. A shell-quoted password is
    # validated byte-for-byte but never printed, evaluated separately or logged.
    awk '
      /^[[:space:]]*$/ || /^#/ {next}
      {n++; if(n==1) {
        prefix="export ZTE_AGENT_PASSWORD="; if(index($0,prefix)!=1)exit 1;
        value=substr($0,length(prefix)+1); q=sprintf("%c",39); bs=sprintf("%c",92);
        if(substr(value,1,1)!=q || substr(value,length(value),1)!=q)exit 1;
        for(i=2;i<length(value);i++) if(substr(value,i,1)==q) {
          if(substr(value,i,4)!=q bs q q || i+3>=length(value))exit 1; i+=3;
        }
      } else if(n==2 && $0!="unset ZTE_AGENT_PIN")exit 1;
      else if(n==3 && $0!="trap " sprintf("%c%c",39,39) " HUP")exit 1;
      else if(n==4 && $0!="nohup sh -c " sprintf("%c",39) "/data/zte-agent 2>&1 | logger -t zte-agent" sprintf("%c",39) " >/dev/null 2>&1 </dev/null &")exit 1;
      else if(n>4)exit 1 }
      END{if(n!=4)exit 1}' "$1"
}
dashboard_root() {
    # Validate the selected document root before granting controls or stopping a
    # running listener. The installed release uses www.current, not /data/www.
    docroot=/data/www
    if test -e /data/www.current || test -L /data/www.current; then
        test -L /data/www.current || return 1
        docroot=$(readlink -f /data/www.current) || return 1
    fi
    case "$docroot" in
      /data/www) ;;
      /data/open-u60-dashboards/*) safe_dir /data/open-u60-dashboards || return 1;;
      /data/open-u60-agent-releases/2.4.1-ru-ttl.1/dashboard)
        safe_dir /data/open-u60-agent-releases && safe_dir /data/open-u60-agent-releases/2.4.1-ru-ttl.1 || return 1;;
      *) return 1;;
    esac
    safe_dir "$docroot" && plain "$docroot/index.html"
}
service_info() {
    service=$1; controlled=0; exe=; port=; launch=
    case "$service" in
      stockWeb) port=0050;;
      dashboard)
        port=1F90; exe=/data/bin/dashboard-uhttpd; launch=/data/local/tmp/start_dashboard.sh
        if safe_dir /data && safe_dir /data/bin && plain "$exe" && test "$(hash "$exe")" = 76f021c43a02eab5bb634b01461370fcb8bfb270b1f14e348e5b57acb43b1d12 &&
           plain "$launch" && test "$(hash "$launch")" = 2f4c2b45dd6142fcc5b6b7aeaf5c0fc5923ba647f4cb3b95fe45e6b1f665c301 &&
           plain /data/local/tmp/stop_open_u60_listener.sh && test "$(hash /data/local/tmp/stop_open_u60_listener.sh)" = 82474a9f2ee061d105041986efb904c2cb0ee43353a7be94cd2ad18f450d9d08 && dashboard_root; then controlled=1; fi;;
      agent)
        port=2382; exe=/data/zte-agent; launch=/data/zte-imei-studio/start_zte_agent.sh
        if safe_dir /data && safe_dir /data/zte-imei-studio && plain "$exe" && test "$(hash "$exe")" = b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537 && agent_launcher_valid "$launch"; then controlled=1; fi;;
      managementSSH) port=08AE;;
      userSSH)
        port=08AF; exe=/data/zte-imei-admin/bin/dropbear; launch=/data/zte-imei-admin/start-ssh-users.sh
        if safe_dir /data && safe_dir /data/zte-imei-admin && safe_dir /data/zte-imei-admin/bin && safe_dir /etc/zte-imei-admin && plain "$exe" && test "$(hash "$exe")" = e3833acdaa8b11e6150f82a35d3dc53d685561d5504ef337ad4af5e530345378 &&
           plain "$launch" && test "$(hash "$launch")" = 35d0e51c65f0ba3499c62d16df1447b91c67e4e0cca26bc9c0e05efb712ef297 &&
           plain /etc/zte-imei-admin/listen-address && test "$(cat /etc/zte-imei-admin/listen-address)" = "$address"; then controlled=1; fi;;
      adb) ;; *) return 1;;
    esac
}
owned_pids() {
    pids=$(listeners "$port")
    if port_open "$port" && test -z "$pids"; then return 1; fi
    count=0
    for pid in $pids; do
        count=$((count+1)); test "$count" = 1 || return 1
        test "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" = "$exe" || return 1
        if test "$service" = userSSH; then
            tr '\000' '\n' < "/proc/$pid/cmdline" | grep -qFx "$address:2223" &&
            tr '\000' '\n' < "/proc/$pid/cmdline" | grep -qFx -- -w &&
            tr '\000' '\n' < "/proc/$pid/cmdline" | awk 'prev=="-G" && $0=="zteimei" {yes=1} {prev=$0} END{exit !yes}' || return 1
        fi
    done
}
report() {
    printf 'ACCESS_SCHEMA 1\n'
    for item in stockWeb dashboard agent managementSSH userSSH adb; do
        service_info "$item" || return 1
        state=stopped; capability=readonly
        if test "$item" = adb; then
            state=unavailable
            for process in /proc/[0-9]*; do
                case "$(readlink "$process/exe" 2>/dev/null || true)" in /sbin/adbd|/usr/bin/adbd|/usr/sbin/adbd|/system/bin/adbd) state=running;; esac
            done
        else
            if port_open "$port"; then state=running
            elif test -n "$exe" && ! test -f "$exe"; then state=unavailable; fi
            if test "$controlled" = 1; then
                if owned_pids; then capability=control; else state=unknown; fi
            fi
        fi
        test "$item" != managementSSH || capability=protected
        printf 'ACCESS_SERVICE %s %s %s\n' "$item" "$state" "$capability"
    done
}
mode=${1:-}; cid=${2:-}; address=${3:-}
printf '%s\n' "$cid" | grep -Eq '^[a-f0-9]{32}$' || fail CID_FORMAT
printf '%s\n' "$address" | awk -F. 'NF==4 {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1;exit 0}{exit 1}' || fail ADDRESS
identity || fail IDENTITY
case "$mode" in status) test "$#" = 3 || fail ARGUMENTS; report; exit 0;; action) test "$#" = 7 || fail ARGUMENTS;; *) fail ARGUMENTS;; esac
chosen=$4; action=$5; stage=$6; lock_token=$7
case "$chosen" in agent|dashboard|userSSH) ;; *) fail PROTECTED_SERVICE;; esac
case "$action" in start|stop|restart) ;; *) fail ACTION;; esac
case "$stage" in /tmp/zte-access-*) ;; *) fail STAGE;; esac
stage_token=${stage#/tmp/zte-access-}
test "${#stage_token}" = 36 && case "$stage_token" in *[!a-f0-9-]*) false;; *) true;; esac || fail STAGE_TOKEN
test "${#lock_token}" = 36 && case "$lock_token" in *[!a-f0-9-]*) false;; *) true;; esac || fail LOCK_TOKEN
safe_dir "$stage" && test "$(stat -c %a "$stage")" = 700 || fail STAGE_MODE
safe_dir /tmp/zte-imei-app.lock && plain /tmp/zte-imei-app.lock/owner && test "$(cat /tmp/zte-imei-app.lock/owner)" = "$lock_token" || fail GLOBAL_LOCK
# The calling SSH transport must remain on the protected application endpoint.
port_open 08AE || fail MANAGEMENT_CHANNEL
for pending in /data/zte-imei-admin/active /data/zte-imei-studio/installations/active /data/local/tmp/zte-imei-installations/active /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing; do test ! -e "$pending" && test ! -L "$pending" || fail OTHER_TRANSACTION; done
service_info "$chosen" && test "$controlled" = 1 && owned_pids || fail UNVERIFIED_SERVICE
was_running=0; test -z "$pids" || was_running=1
# Copy the validated launcher into the private stage and validate the copy too.
cp "$launch" "$stage/launcher.private.sh"
if test "$chosen" = agent; then agent_launcher_valid "$stage/launcher.private.sh" || fail LAUNCHER_CHANGED
elif test "$chosen" = dashboard; then test "$(hash "$stage/launcher.private.sh")" = 2f4c2b45dd6142fcc5b6b7aeaf5c0fc5923ba647f4cb3b95fe45e6b1f665c301 || fail LAUNCHER_CHANGED
else test "$(hash "$stage/launcher.private.sh")" = 35d0e51c65f0ba3499c62d16df1447b91c67e4e0cca26bc9c0e05efb712ef297 || fail LAUNCHER_CHANGED; fi
cleanup() { rm -f "$stage/launcher.private.sh"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
if test "$action" != start && test "$was_running" = 1; then
    identity && service_info "$chosen" && test "$controlled" = 1 && owned_pids && test -n "$pids" || fail SERVICE_CHANGED
    for pid in $pids; do kill -TERM "$pid" || fail STOP; done
    attempts=0
    while port_open "$port"; do attempts=$((attempts+1)); test "$attempts" -le 8 || fail STOP_TIMEOUT; sleep 1; done
fi
if test "$action" != stop; then
    # Never run a launcher if a foreign process took the port during the stop.
    service_info "$chosen" && test "$controlled" = 1 && owned_pids || fail SERVICE_CHANGED
    if test -z "$pids"; then
        identity || fail IDENTITY_CHANGED
        if test "$chosen" = dashboard; then
            dashboard_root || fail DOCROOT
            nohup "$exe" -f -h "$docroot" -p 0.0.0.0:8080 -D >/dev/null 2>&1 </dev/null &
        else sh "$stage/launcher.private.sh" >/dev/null 2>&1 || fail START; fi
        attempts=0
        until port_open "$port"; do attempts=$((attempts+1)); test "$attempts" -le 10 || fail START_TIMEOUT; sleep 1; done
    fi
    service_info "$chosen" && owned_pids && test -n "$pids" || fail START_VERIFY
    stable=$pids; sleep 1; owned_pids && test "$pids" = "$stable" || fail UNSTABLE_SERVICE
fi
report
