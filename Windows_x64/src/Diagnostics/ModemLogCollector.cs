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
    internal const int ByteLimit = 512 * 1024;
    internal static readonly (string Name, string Command)[] Commands = [
        ("system.log", "if ubus list log 2>/dev/null | grep -qFx log; then logread; else printf 'Служба системного журнала недоступна\\n'; exit 3; fi"),
        ("kernel.log", "dmesg"),
        ("setup-state.txt", SetupStateCommand),
        ("services.txt", "found=0; for p in /tmp/zte-agent.log /tmp/dashboard-uhttpd.log /data/zte-vpn/last-validation.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 131072 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'Отдельные файлы журналов служб отсутствуют; агент может использовать системный журнал.\\n'; exit 3; fi"),
        ("vpn.log", "found=0; for p in /data/zte-vpn/core.log /data/zte-vpn/core.previous.log /data/zte-vpn/actions.log /data/zte-vpn/profile-actions.jsonl /data/zte-vpn/firewall.log /data/zte-vpn/reload.log /data/zte-vpn/dns.log /data/zte-vpn/dns.previous.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 65536 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'VPN runtime logs are not present\\n'; fi"),
        ("vpn-runtime.txt", "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; run() { printf '\\nCOMMAND'; printf ' %s' \"$@\"; printf '\\n'; \"$@\" 2>&1 || printf 'READ_FAILED=%s\\n' \"$?\"; }; for name in core dns; do p=/data/zte-vpn/$name.pid; printf '\\nPROCESS %s\\n' \"$name\"; if test -f \"$p\" && test ! -L \"$p\"; then pid=$(cat \"$p\"); case \"$pid\" in ''|*[!0-9]*) printf 'INVALID_PID\\n';; *) run readlink \"/proc/$pid/exe\";; esac; else printf 'MISSING_PID\\n'; fi; done; for dev in br-vpn zvpn-tun wlan1 wlan3; do run ip -s link show dev \"$dev\"; run readlink \"/sys/class/net/$dev/master\"; done; run ip -4 addr show dev br-vpn; run ip -4 route show table 19090; run ip -4 rule show; run ip -4 route show; for section in guest_2g guest_5g; do for field in disabled network bridge guest_active_time guest_remaining; do run uci -q get \"wireless.$section.$field\"; done; done; for dev in wlan1 wlan3; do printf '\\nHOSTAPD %s\\n' \"$dev\"; hostapd_cli -p /data/vendor/wifi/hostapd -i \"$dev\" status 2>/dev/null | sed -n '/^state=/p'; done; run cat /proc/net/tcp /proc/net/udp; for spec in 'filter ZVPN_IN' 'filter ZVPN_FW' 'mangle ZVPN_PRE' 'nat ZVPN_DNS'; do set -- $spec; run iptables -w 2 -t \"$1\" -nvxL \"$2\"; done; run nft list table inet zte_vpn_guard; for chain in ZVPN_L2IN ZVPN_L2FW ZVPN_L2OUT; do run ebtables -L \"$chain\" --Lc; done; run cat /proc/sys/net/ipv4/ip_forward; for dev in all br-vpn zvpn-tun; do run cat \"/proc/sys/net/ipv4/conf/$dev/rp_filter\"; done; :"),
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
