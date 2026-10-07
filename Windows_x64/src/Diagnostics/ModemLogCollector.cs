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
    internal const int ByteLimit = 512 * 1024;
    internal static readonly (string Name, string Command)[] Commands = [
        ("system.log", "if ubus list log 2>/dev/null | grep -qFx log; then logread; else printf 'Служба системного журнала недоступна\\n'; exit 3; fi"),
        ("kernel.log", "dmesg"),
        ("services.txt", "found=0; for p in /tmp/zte-agent.log /tmp/dashboard-uhttpd.log /data/zte-vpn/last-validation.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 131072 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'Отдельные файлы журналов служб отсутствуют; агент может использовать системный журнал.\\n'; exit 3; fi"),
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
