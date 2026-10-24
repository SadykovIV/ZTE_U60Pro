using System.Text;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Diagnostics;

public sealed record ModemLogFile(string Name, string Text, int ExitCode, bool Truncated);
public sealed record ModemLogCollection(DateTimeOffset StartedAt, DateTimeOffset CompletedAt, string Status,
    IReadOnlyList<ModemLogFile> Files, IReadOnlyList<string> Issues)
{
    internal static ModemLogCollection Skipped(string reason) => new(DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, "skipped", [], [reason]);
}

/// Reads logs through the already selected SSH connection. A failed modem read
/// must not prevent exporting local preparation and application errors.
internal static class ModemLogCollector
{
    internal const string AdbTransactionMetadataCommand = """
        set -eu
        # Files may vanish during collection; never publish a private stage path in errors.
        exec 2>/dev/null
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        # Metadata only: never emit token, identity, argv, startup contents or logs.
        for tool in stat cat head sha256sum cut od tr awk cmp readlink sort; do command -v "$tool" >/dev/null 2>&1 || { printf 'adb_recovery=not-assessed\n'; exit 0; }; done
        regular() { test -f "$1" && test ! -L "$1" && test "$(stat -c '%u:%a:%h' "$1")" = 0:600:1 && test "$(stat -c %s "$1")" -le 65536; }
        private_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c '%u:%a' "$1")" = 0:700; }
        state() { if test -L "$1"; then printf unsafe; elif test -e "$1"; then printf present; else printf absent; fi; }
        count=0
        for stage in /tmp/zte-adb-toggle-*; do
         test -e "$stage" || test -L "$stage" || continue
         count=$((count+1)); if test "$count" -gt 16; then printf 'adb_stages=truncated\n'; break; fi
         printf 'ADB_STAGE index=%s\n' "$count"
         token=${stage##*/zte-adb-toggle-}
         case "$token" in ????????-????-????-????-????????????) case "$token" in *[!0-9a-f-]*) printf 'layout=unsafe\n'; continue;; esac;; *) printf 'layout=unsafe\n'; continue;; esac
         if ! private_dir "$stage"; then printf 'layout=unsafe\n'; continue; fi
         printf 'layout=private\n'
         hash_class=unknown
         if regular "$stage/adb-toggle.sh"; then
          hash=$(sha256sum "$stage/adb-toggle.sh" | cut -d ' ' -f 1)
          case "$hash" in 8e8f39ca743a4e53971db885afc3117ab3023a0ff3d6144c0954b078f6562a79) hash_class=current;; 0ca5d10426c8398bab5e35af525782c490dce30f841a073e2cc64e3dc49c27dd) hash_class=previous-reviewed;; esac
         fi
         printf 'script=%s\n' "$hash_class"
         phase=missing
         if test -e "$stage/phase" || test -L "$stage/phase"; then
          phase=unknown
          if regular "$stage/phase" && test "$(stat -c %s "$stage/phase")" -le 32; then
           value=$(cat "$stage/phase")
           case "$value" in preparing|prepared|changing|awaiting-ack|committed|rolled-back|rollback-unknown|cleanup-unknown|cancelled|settled-before|settled-after) phase=$value;; esac
          fi
         fi
         printf 'phase=%s\n' "$phase"
         for name in prepare-active decision apply-once settle-active released-lock; do printf '%s=%s\n' "$name" "$(state "$stage/$name")"; done
         lock=absent
         if test -e /tmp/zte-imei-app.lock || test -L /tmp/zte-imei-app.lock; then
          lock=unknown
          if private_dir /tmp/zte-imei-app.lock && regular /tmp/zte-imei-app.lock/owner && test "$(stat -c %s /tmp/zte-imei-app.lock/owner)" -le 37; then
           if test "$(cat /tmp/zte-imei-app.lock/owner)" = "$token"; then lock=owned; else lock=other-owner; fi
          fi
         fi
         printf 'common_lock=%s\n' "$lock"
         rc=unknown
         if regular "$stage/rc.before" && regular "$stage/rc.after" && test -f /etc/rc.local && test ! -L /etc/rc.local && test "$(stat -c '%u:%h' /etc/rc.local)" = 0:1 && test "$(stat -c %s /etc/rc.local)" -le 65536; then
          rc=neither; if cmp -s /etc/rc.local "$stage/rc.before"; then rc=before; fi
          if cmp -s /etc/rc.local "$stage/rc.after"; then if test "$rc" = before; then rc=both; else rc=after; fi; fi
         fi
         printf 'startup_snapshot=%s\n' "$rc"
         workers=0; complete=1; scanned=0
         stage_hex=$(printf '%s' "$stage" | od -An -v -tx1 | tr -d ' \n')
         for proc in /proc/[0-9]*; do
          test -d "$proc" || continue
          scanned=$((scanned+1)); if test "$scanned" -gt 4096; then complete=0; break; fi
          before=$(awk '{sub(/^.*\) /, "");print $20}' "$proc/stat" 2>/dev/null) || { test ! -d "$proc" && continue; complete=0; continue; }
          value=$(od -An -v -N 8193 -tx1 "$proc/cmdline" 2>/dev/null) || { test ! -d "$proc" && continue; complete=0; continue; }
          value=$(printf '%s' "$value" | tr -d ' \n')
          after=$(awk '{sub(/^.*\) /, "");print $20}' "$proc/stat" 2>/dev/null) || { test ! -d "$proc" && continue; complete=0; continue; }
          if test "$before" != "$after" || test "${#value}" -gt 16384; then complete=0; continue; fi
          case "$value" in *"$stage_hex"*) workers=$((workers+1));; esac
         done
         printf 'stage_processes=%s\nprocess_scan_complete=%s\n' "$workers" "$complete"
        done
        printf 'adb_recovery=observed\n'
        """;
    internal const string SetupStateCommand = """
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        for base in /data/zte-imei-studio/installations /data/local/tmp/zte-imei-installations; do
          printf 'INSTALLATIONS %s\n' "$base"
          safe=1; parent=$base
          while test "$parent" != /; do
            if test -L "$parent" || test ! -d "$parent" || test ! -r "$parent" || test ! -x "$parent"; then safe=0; break; fi
            parent=${parent%/*}; test -n "$parent" || parent=/
          done
          if test "$safe" != 1; then printf 'layout=absent-or-unreadable\n'; continue; fi
          active=
          if test -f "$base/active" && test ! -L "$base/active" && test "$(stat -c %s "$base/active")" -le 64; then
            candidate=$(cat "$base/active")
            if printf '%s\n' "$candidate" | grep -qE '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'; then active=$candidate; printf 'active=present\n'; else printf 'active=invalid\n'; fi
          elif test -e "$base/active" || test -L "$base/active"; then printf 'active=unreadable\n'
          else printf 'active=absent\n'; fi
          if test -d "$base/lock" && test ! -L "$base/lock"; then printf 'lock=present\n'; else printf 'lock=absent-or-invalid\n'; fi
          count=0
          for journal in "$base"/*; do
            test -d "$journal" && test ! -L "$journal" || continue
            name=${journal##*/}
            printf '%s\n' "$name" | grep -qE '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' || continue
            count=$((count+1)); test "$count" -le 32 || { printf 'journals=truncated\n'; break; }
            printf 'journal=%s\n' "$count"
            if test "$name" = "$active"; then printf 'current=yes\n'; else printf 'current=no\n'; fi
            for key in state mode; do
              value=unavailable
              if test -f "$journal/$key" && test ! -L "$journal/$key" && test "$(stat -c %s "$journal/$key")" -le 64; then
                candidate=$(cat "$journal/$key")
                case "$key:$candidate" in state:preparing|state:pending|state:ready|state:complete|state:rolled-back|mode:reinstall|mode:install) value=$candidate;; *) value=unknown;; esac
              fi
              printf '%s=%s\n' "$key" "$value"
            done
            for file in before.sha256 after.sha256 targets cid profile.identity; do
              if test -f "$journal/$file" && test ! -L "$journal/$file"; then printf '%s=present\n' "$file"; else printf '%s=absent-or-invalid\n' "$file"; fi
            done
          done
          printf 'journal_count=%s\n' "$count"
        done
        printf 'RESET_RECOVERY\n'
        anchor=/data/zte-imei-studio
        safe=1; parent=$anchor
        while test "$parent" != /; do
          if test -L "$parent" || test ! -d "$parent" || test ! -r "$parent" || test ! -x "$parent"; then safe=0; break; fi
          parent=${parent%/*}; test -n "$parent" || parent=/
        done
        if test "$safe" != 1; then printf 'archive_layout=absent-or-unreadable\n'
        else
          count=0; metadata_present=0; metadata_incomplete=0; unsafe=0; truncated=0
          for archive in "$anchor"/reset-recovery-*; do
            test -e "$archive" || test -L "$archive" || continue
            name=${archive##*/}
            printf '%s\n' "$name" | grep -qE '^reset-recovery-[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}-[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' || continue
            count=$((count+1)); test "$count" -le 32 || { truncated=1; break; }
            if test ! -d "$archive" || test -L "$archive" || test "$(stat -c '%u:%a' "$archive" 2>/dev/null)" != 0:700; then unsafe=$((unsafe+1)); continue; fi
            present=1
            for directory in journal current; do
              test -d "$archive/$directory" && test ! -L "$archive/$directory" || present=0
            done
            for file in snapshot.sha256 cid boot; do
              test -f "$archive/$file" && test ! -L "$archive/$file" || present=0
            done
            if test "$present" = 1; then metadata_present=$((metadata_present+1)); else metadata_incomplete=$((metadata_incomplete+1)); fi
          done
          printf 'archive_count=%s\narchive_metadata_present=%s\narchive_metadata_incomplete=%s\narchive_layout_unsafe=%s\narchive_inventory_truncated=%s\n' "$count" "$metadata_present" "$metadata_incomplete" "$unsafe" "$truncated"
          printf 'archive_contents_verified=not-performed\n'
        fi
        :
        """;
    internal const string IpaMetadataCommand = """
        (
        # Current, bounded metadata only. Never execute installed helpers or print private values.
        set -f
        exec 2>/dev/null
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        for tool in stat head awk sha256sum readlink od tr uci; do command -v "$tool" >/dev/null 2>&1 || exit 1; done
        root=/data/zte-vpn
        safe_dir() { test -d "$1" && test ! -L "$1" && test -r "$1" && test -x "$1" && test "$(stat -c %u "$1")" = 0; }
        plain() { test -f "$1" && test ! -L "$1" && test -r "$1" && test "$(stat -c '%u:%h' "$1")" = 0:1 && test "$(stat -c %s "$1")" -le "$2"; }
        stamp() { stat -c '%d:%i:%s:%Y:%Z' "$1"; }
        # All hashes remain internal; the manifest may name only these two fixed files.
        snapshot() {
         safe_dir /data && safe_dir "$root" || { printf unknown; return; }
         if test ! -e "$root/ipa-backup" && test ! -L "$root/ipa-backup"; then printf absent; return; fi
         for directory in "$root/ipa-backup" "$root/ipa-backup/deltas"; do
          safe_dir "$directory" && test "$(stat -c %a "$directory")" = 700 || { printf invalid; return; }
         done
         for pair in state:128 SHA256SUMS:1024 zwrt_router:1048576; do
          name=${pair%:*}; limit=${pair#*:}
          plain "$root/ipa-backup/$name" "$limit" || { printf unknown; return; }
         done
         before=$(stamp "$root/ipa-backup/SHA256SUMS") || { printf unknown; return; }
         expected=$(head -c 1025 "$root/ipa-backup/SHA256SUMS" | awk 'NF!=2 || $2!~/^(state|zwrt_router)$/ || length($1)!=64 || $1~/[^0-9a-f]/ || seen[$2]++ {bad=1} {hash[$2]=$1} END{if(bad||NR!=2)exit 1;print hash["state"],hash["zwrt_router"]}') || { printf invalid; return; }
         for name in state zwrt_router; do
          old=$(stamp "$root/ipa-backup/$name") || { printf unknown; return; }
          digest=$(head -c 1048577 "$root/ipa-backup/$name" | sha256sum | awk '{print $1}')
          test "$old" = "$(stamp "$root/ipa-backup/$name")" || { printf unknown; return; }
          case "$name" in state) wanted=${expected% *};; zwrt_router) wanted=${expected#* };; esac
          test "$digest" = "$wanted" || { printf invalid; return; }
         done
         head -c 129 "$root/ipa-backup/state" | awk 'NR==1 && /^close=(0|1|absent)$/ {next} NR==2 && /^disabled=(0|1|absent)$/ {next} NR==3 && /^close_pending=[01]$/ {next} NR==4 && /^disabled_pending=[01]$/ {next} {bad=1} END{exit bad||NR!=4}' || { printf invalid; return; }
         test "$before" = "$(stamp "$root/ipa-backup/SHA256SUMS")" || { printf unknown; return; }
         printf valid
        }
        flag() {
         value=$({ if uci -q get "$1"; then printf 'IPA_UCI_RC=0\n'; else printf 'IPA_UCI_RC=1\n'; fi; } | head -c 65)
         case "$value" in "$(printf '0\nIPA_UCI_RC=0')") printf 0;; "$(printf '1\nIPA_UCI_RC=0')") printf 1;; *) printf unknown;; esac
        }
        proc_meta() {
         head -c 4096 "$1/stat" | awk '{sub(/^.*\) /, "");if(NF>=20 && $7~/^[0-9]+$/ && $20~/^[0-9]+$/) print $1,$7,$20;else exit 1} END{if(NR!=1)exit 1}'
        }
        clock_seconds() {
         IFS=' ' read -r seconds rest < /proc/uptime || return 1
         seconds=${seconds%%.*}; case "$seconds" in ''|*[!0-9]*) return 1;; esac
         printf '%s' "$seconds"
        }
        # Leave room in the existing 20s request for the rest of the runtime report.
        scan_started=$(clock_seconds) || scan_started=
        # Inspect mappings, including processes with an empty argv. No PID/argv is emitted.
        set +f
        mapped=0; scanned=0; complete=1; only_pid=; only_start=
        for proc in /proc/[0-9]*; do
         test -d "$proc" || continue
         now=$(clock_seconds) || { complete=0; break; }
         if test -z "$scan_started" || test "$now" -ge "$((scan_started+5))"; then complete=0; break; fi
         scanned=$((scanned+1)); if test "$scanned" -gt 4096; then complete=0; break; fi
         meta=$(proc_meta "$proc") || { test ! -d "$proc" && continue; complete=0; continue; }
         exe=$(readlink "$proc/exe") || {
          test ! -d "$proc" && continue
          set -- $meta
          if test "$1" = Z || test "$(( $2 & 2097152 ))" != 0; then continue; fi
          complete=0; continue
         }
         after=$(proc_meta "$proc") || { complete=0; continue; }
         if test "$meta" != "$after"; then complete=0; continue; fi
         case "$exe" in /usr/bin/ipacm|'/usr/bin/ipacm (deleted)') mapped=$((mapped+1)); only_pid=${proc##*/}; only_start=${meta##* };; esac
        done
        marker=unknown
        if safe_dir /data && safe_dir "$root"; then
         if test ! -e "$root/ipa-runtime" && test ! -L "$root/ipa-runtime"; then marker=absent
         elif plain "$root/ipa-runtime" 128 && test "$complete" = 1; then
          marker=no
          if test "$mapped" = 1; then
           boot=$(head -c 64 /proc/sys/kernel/random/boot_id)
           if printf '%s\n' "$boot" | awk 'length($0)!=36 || $0!~/^[0-9a-f-]+$/ {bad=1} END{exit bad||NR!=1}'; then
            expected=$(printf '%s %s\n' "$boot" "$only_pid" | od -An -v -tx1 | tr -d ' \n')
            actual=$(od -An -v -N 129 -tx1 "$root/ipa-runtime" | tr -d ' \n')
            current=$(proc_meta "/proc/$only_pid") || current=unknown
            if test "$current" = unknown || test "${current##* }" != "$only_start"; then marker=unknown
            elif test "$actual" = "$expected" && test "$(readlink "/proc/$only_pid/exe")" = /usr/bin/ipacm; then marker=yes; fi
           else marker=unknown; fi
          fi
         fi
        fi
        snapshot_state=$(snapshot)
        close=$(flag zwrt_router.tmp_router.close_ipa_acce)
        disabled=$(flag zwrt_router.other.ipa_disable)
        printf '\nIPA_METADATA\nipa_snapshot=%s\nclose_ipa_acce=%s\nipa_disable=%s\nmapped_ipacm_count=%s\nipacm_scan_complete=%s\nruntime_marker_matches_current_boot_pid=%s\nipa_metadata=current-observation\n' "$snapshot_state" "$close" "$disabled" "$mapped" "$complete" "$marker"
        ) 2>/dev/null || printf '\nIPA_METADATA\nipa_metadata=not-assessed\n'
        :
        """;
    internal const int ByteLimit = 512 * 1024;
    internal static readonly (string Name, string Command)[] Commands = [
        ("system.log", "if ubus list log 2>/dev/null | grep -qFx log; then logread; else printf 'Служба системного журнала недоступна\\n'; exit 3; fi"),
        ("kernel.log", "dmesg"),
        ("setup-state.txt", SetupStateCommand),
        ("adb-transaction.txt", AdbTransactionMetadataCommand),
        ("services.txt", "found=0; for p in /tmp/zte-agent.log /tmp/dashboard-uhttpd.log /data/zte-vpn/last-validation.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 131072 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'Отдельные файлы журналов служб отсутствуют; агент может использовать системный журнал.\\n'; exit 3; fi"),
        ("vpn.log", "found=0; for p in /data/zte-vpn/core.log /data/zte-vpn/core.previous.log /data/zte-vpn/actions.log /data/zte-vpn/profile-actions.jsonl /data/zte-vpn/firewall.log /data/zte-vpn/reload.log /data/zte-vpn/dns.log /data/zte-vpn/dns.previous.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 65536 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'VPN runtime logs are not present\\n'; fi"),
        ("vpn-runtime.txt", "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; run() { printf '\\nCOMMAND'; printf ' %s' \"$@\"; printf '\\n'; \"$@\" 2>&1 || printf 'READ_FAILED=%s\\n' \"$?\"; }; for name in core dns; do p=/data/zte-vpn/$name.pid; printf '\\nPROCESS %s\\n' \"$name\"; if test -f \"$p\" && test ! -L \"$p\"; then pid=$(cat \"$p\"); case \"$pid\" in ''|*[!0-9]*) printf 'INVALID_PID\\n';; *) run readlink \"/proc/$pid/exe\";; esac; else printf 'MISSING_PID\\n'; fi; done; for dev in br-vpn zvpn-tun wlan1 wlan3; do run ip -s link show dev \"$dev\"; run readlink \"/sys/class/net/$dev/master\"; done; run ip -4 addr show dev br-vpn; run ip -4 route show table 19090; run ip -4 rule show; run ip -4 route show; for section in guest_2g guest_5g; do for field in disabled network bridge guest_active_time guest_remaining; do run uci -q get \"wireless.$section.$field\"; done; done; for dev in wlan1 wlan3; do printf '\\nHOSTAPD %s\\n' \"$dev\"; hostapd_cli -p /data/vendor/wifi/hostapd -i \"$dev\" status 2>/dev/null | sed -n '/^state=/p'; done; run cat /proc/net/tcp /proc/net/udp; for spec in 'filter ZVPN_IN' 'filter ZVPN_FW' 'mangle ZVPN_PRE' 'nat ZVPN_DNS'; do set -- $spec; run iptables -w 2 -t \"$1\" -nvxL \"$2\"; done; run nft list table inet zte_vpn_guard; for chain in ZVPN_L2IN ZVPN_L2FW ZVPN_L2OUT; do run ebtables -L \"$chain\" --Lc; done; run cat /proc/sys/net/ipv4/ip_forward; for dev in all br-vpn zvpn-tun; do run cat \"/proc/sys/net/ipv4/conf/$dev/rp_filter\"; done; :" + "\n" + IpaMetadataCommand),
    ];

    internal static string Wrap(string command) => "umask 077; d=$(mktemp -d /tmp/zte-diagnostic.XXXXXX) || exit 1; trap 'rm -f \"$d/out\"; rmdir \"$d\"' EXIT HUP INT TERM; ( set -e; ulimit -f 1025; " + command + " ) > \"$d/out\" 2>&1; code=$?; head -c " + (ByteLimit + 1) + " \"$d/out\"; printf '\\n__DIAGNOSTIC_RESULT__%s\\n' \"$code\"";

    internal static ModemLogFile Decode(string name, RemoteResult reply)
    {
        var output = Encoding.UTF8.GetString(reply.Stdout);
        const string marker = "\n__DIAGNOSTIC_RESULT__";
        var index = output.LastIndexOf(marker, StringComparison.Ordinal);
        var hasExit = index >= 0 && int.TryParse(output[(index + marker.Length)..].Trim(), out var parsed) && parsed is >= 0 and <= 255;
        var exit = reply.ExitCode != 0 ? reply.ExitCode : hasExit ? int.Parse(output[(index + marker.Length)..].Trim()) : -2;
        var body = index < 0 ? output : output[..index];
        if (reply.ExitCode != 0 || !hasExit) body += "\n" + Encoding.UTF8.GetString(reply.Stderr);
        var bytes = Encoding.UTF8.GetBytes(body);
        var truncated = bytes.Length > ByteLimit;
        if (truncated && exit == 153 && reply.Success) exit = 0;
        if (truncated) body = Encoding.UTF8.GetString(bytes, 0, ByteLimit) + "\n[Вывод ограничен 512 КиБ]\n";
        return new(name, body, exit, truncated);
    }

    internal static async Task<ModemLogCollection> CollectAsync(IRemoteShell shell, SshReadProof selected, CancellationToken ct)
    {
        var started = DateTimeOffset.UtcNow;
        var files = new List<ModemLogFile>(); var issues = new List<string>();
        try
        {
            // Session proof deliberately excludes firmware hashes: reading logs
            // does not depend on IMEI compatibility or a known firmware profile.
            var before = await SshReadProof.ReadSessionAsync(shell, ct);
            (selected with { FirmwareHash = null, RouterHash = null }).Verify(before);
            foreach (var (name, command) in Commands)
            {
                ct.ThrowIfCancellationRequested();
                var reply = await shell.RunAsync(Wrap(command), timeout: TimeSpan.FromSeconds(20), ct: ct);
                if (reply.ExitCode == 255) throw new IOException("Соединение SSH потеряно при чтении журналов.");
                var file = Decode(name, reply); files.Add(file);
                if (file.ExitCode != 0) issues.Add(name + ": чтение завершилось с кодом " + file.ExitCode + ".");
                if (file.Truncated) issues.Add(name + ": сохранён ограниченный фрагмент журнала.");
            }
            var after = await SshReadProof.ReadSessionAsync(shell, ct);
            try { before.Verify(after); }
            catch { files.Clear(); throw; } // Do not combine different devices or boots.
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception error)
        { issues.Add("Не все журналы модема получены: " + error.Message); }
        return new(started, DateTimeOffset.UtcNow, issues.Count == 0 ? "complete" : "partial", files, issues);
    }
}
