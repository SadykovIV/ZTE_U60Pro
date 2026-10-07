using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Windows.Research;

namespace ZteImeiStudio.Windows.Diagnostics;

public sealed record DiagnosticActivity(DateTimeOffset Timestamp, string Level, string Message,
    string Kind = "message", string? Operation = null, string? Outcome = null, long? DurationMs = null);
public sealed record DiagnosticSystemSnapshot(string? ConnectionMode, string? Model, string? Firmware, string ApplicationVersion);
public sealed record DiagnosticExportResult(string Path, int Files, int Events, int Omissions);

/// Fixed local log inputs, with optional fresh SSH log results. No firmware survey or binaries.
public static class DiagnosticsExporter
{
    public const int SegmentLimit = 2 * 1024 * 1024;
    private const int ArchiveLimit = 32 * 1024 * 1024;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly string[] JournalFiles = ["activity.previous.jsonl", "activity.jsonl"];
    private static readonly UTF8Encoding Utf8 = new(false, true);

    private static void SafePath(string path)
    {
        for (string? current = System.IO.Path.GetFullPath(path); current is not null; current = System.IO.Path.GetDirectoryName(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Diagnostic paths cannot use links or reparse points.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    private static DiagnosticActivity Clean(DiagnosticActivity entry, DiagnosticPrivacy privacy)
    {
        var level = entry.Level is "info" or "ok" or "error" or "warning" or "research" ? entry.Level : "info";
        var kind = entry.Kind is "message" or "operation" ? entry.Kind : "message";
        var operation = entry.Operation is { Length: > 0 and <= 64 } op &&
            Enum.TryParse<ModemOperation>(op, false, out var parsed) && Enum.IsDefined(parsed) && parsed.ToString() == op ? op : null;
        var outcome = entry.Outcome is "started" or "completed" or "failed" or "cancelled" ? entry.Outcome : null;
        return new(entry.Timestamp, level, privacy.Clean(entry.Message), kind, operation, outcome,
            entry.DurationMs is >= 0 and <= 86400000 ? entry.DurationMs : null);
    }

    public static void Append(string root, DiagnosticActivity entry, DiagnosticPrivacy privacy)
    {
        var directory = System.IO.Path.Combine(root, "Diagnostics", "Application");
        SafePath(directory); Directory.CreateDirectory(directory); SafePath(directory);
        var path = System.IO.Path.Combine(directory, JournalFiles[1]);
        var previous = System.IO.Path.Combine(directory, JournalFiles[0]);
        SafePath(path); SafePath(previous);
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(Clean(entry, privacy), Json) + "\n");
        if (File.Exists(path) && new FileInfo(path).Length + bytes.Length > SegmentLimit)
            File.Move(path, previous, true);
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
        stream.Write(bytes); stream.Flush();
    }

    private static byte[] ReadBounded(string path)
    {
        SafePath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > SegmentLimit) throw new InvalidDataException("Diagnostic journal exceeds its limit.");
        using var output = new MemoryStream();
        var buffer = new byte[8192]; int count;
        while ((count = stream.Read(buffer)) != 0)
        {
            if (output.Length + count > SegmentLimit) throw new InvalidDataException("Diagnostic journal exceeds its limit.");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }

    public static DiagnosticExportResult Export(string root, string destination, DiagnosticSystemSnapshot system,
        IEnumerable<DiagnosticActivity> currentSession, DiagnosticPrivacy privacy, bool journalWriteFailed = false,
        CancellationToken ct = default, ModemLogCollection? modemLogs = null)
    {
        ct.ThrowIfCancellationRequested(); SafePath(destination);
        var exportedAt = DateTimeOffset.UtcNow;
        var omissions = new HashSet<string>(StringComparer.Ordinal);
        var saved = new List<DiagnosticActivity>();
        foreach (var name in JournalFiles)
        {
            ct.ThrowIfCancellationRequested();
            var path = System.IO.Path.Combine(root, "Diagnostics", "Application", name);
            // Validate even broken symlinks; never follow arbitrary storage files.
            try
            {
                SafePath(path);
                if (!File.Exists(path)) continue;
                foreach (var line in Utf8.GetString(ReadBounded(path)).Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (saved.Count >= 8192) { omissions.Add("Saved activity event limit reached."); break; }
                    if (line.Length > 32768) { omissions.Add("Oversized activity event omitted."); continue; }
                    try
                    {
                        var item = JsonSerializer.Deserialize<DiagnosticActivity>(line, Json);
                        if (item is null || item.Message is null || item.Level is null || item.Timestamp == default)
                            throw new JsonException();
                        saved.Add(Clean(item, privacy));
                    }
                    catch (JsonException) { omissions.Add("Malformed activity event omitted."); }
                }
            }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
            { omissions.Add("Saved activity segment unavailable or unsafe."); }
        }
        if (journalWriteFailed) omissions.Add("Some activity could not be persisted; current-session events are included.");
        var current = currentSession.TakeLast(2000).Select(x => Clean(x, privacy)).ToArray();
        byte[] Lines(IEnumerable<DiagnosticActivity> entries) => Encoding.UTF8.GetBytes(string.Concat(entries.Select(x => JsonSerializer.Serialize(x, Json) + "\n")));
        var report = new
        {
            schema = 1, createdAt = exportedAt, application = "ZTE IMEI Studio Windows x64",
            applicationVersion = privacy.CleanApplicationVersion(system.ApplicationVersion),
            connectionMode = privacy.Clean(system.ConnectionMode ?? ""), model = privacy.Clean(system.Model ?? ""), firmware = privacy.Clean(system.Firmware ?? ""),
            operations = current.Select(x => new { x.Timestamp, x.Level, operation = x.Message.StartsWith("eSIM[", StringComparison.Ordinal) ? x.Message : x.Message.Split(':', 2)[0] }).ToArray(),
            note = "Журналы программы и доступные журналы модема. Результат свежего чтения SSH указан в manifest.json; пароли, ключи, профили, IMEI и CID не включаются."
        };
        var files = new SortedDictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["report.json"] = JsonSerializer.SerializeToUtf8Bytes(report, Json),
            ["application-journal.jsonl"] = Lines(saved),
            ["current-session.jsonl"] = Lines(current),
            ["operation-traces.jsonl"] = Lines(saved.Where(x => x.Kind == "operation" || x.Message.StartsWith("eSIM[", StringComparison.Ordinal))),
            ["README.txt"] = Encoding.UTF8.GetBytes("Application and modem logs. Firmware survey and component files belong to the separate firmware adaptation ZIP.\nreport.json: cached application summary.\napplication-journal.jsonl: sanitized saved preparation, connection and operation events.\ncurrent-session.jsonl: latest in-memory events, which may overlap the saved journal.\noperation-traces.jsonl: action timing/results and eSIM progress.\npreparation/: saved installer logs, when available.\nmodem/: logs read over the existing SSH connection; collection time, command status, omissions and errors are in manifest.json. No agent API is required. When SSH is unavailable, local logs are still exported.\nKeys, trust files, connection settings, backups, VPN profiles and activation codes are never copied.\n")
        };
        if (modemLogs is not null)
        {
            foreach (var entry in modemLogs.Files)
            {
                if (!ModemLogCollector.Commands.Any(x => x.Name == entry.Name)) throw new InvalidDataException("Unknown modem log path.");
                files.Add("modem/" + entry.Name, Encoding.UTF8.GetBytes(ResearchReportFiles.CleanExportText(entry.Text, privacy.Clean, ct)));
            }
            foreach (var issue in modemLogs.Issues) omissions.Add(privacy.Clean(issue));
        }
        // Current session and fresh modem logs take priority over older installer logs.
        var optionalLogs = new List<string>();
        var payloadBytes = files.Values.Sum(x => (long)x.Length);
        const string skippedInstallLogs = "Older saved installation logs omitted at archive size limit.";
        // An installation transcript is useful after failed preparation. Enumerate only
        // direct UUID directories and this fixed filename; never copy backup contents.
        var setupRoot = System.IO.Path.Combine(root, "SetupBackups");
        try
        {
            SafePath(setupRoot);
            if (Directory.Exists(setupRoot))
                foreach (var setupDirectory in Directory.EnumerateDirectories(setupRoot).OrderByDescending(Directory.GetLastWriteTimeUtc))
                {
                    ct.ThrowIfCancellationRequested();
                    if (!Guid.TryParse(System.IO.Path.GetFileName(setupDirectory), out _)) continue;
                    var transcript = System.IO.Path.Combine(setupDirectory, "installation.log");
                    try
                    {
                        SafePath(transcript);
                        if (!File.Exists(transcript)) continue;
                        var data = Encoding.UTF8.GetBytes(ResearchReportFiles.CleanExportText(Utf8.GetString(ReadBounded(transcript)), privacy.Clean, ct));
                        if (payloadBytes + data.Length > ArchiveLimit) { omissions.Add(skippedInstallLogs); continue; }
                        var name = "preparation/" + System.IO.Path.GetFileName(setupDirectory) + "/installation.log";
                        files.Add(name, data); optionalLogs.Add(name); payloadBytes += data.Length;
                    }
                    catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
                    { omissions.Add("Saved installation log unavailable or unsafe."); }
                }
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
        { omissions.Add("Saved installation logs unavailable or unsafe."); }
        byte[] Manifest() => JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1, collectedFromModem = modemLogs?.Files.Count > 0, exportedAt, omissions = omissions.Distinct().ToArray(),
            sources = new { applicationSummary = new { kind = "cached-application-state", capturedAt = (DateTimeOffset?)null },
                modemLogs = modemLogs is null ? null : new { modemLogs.StartedAt, modemLogs.CompletedAt, modemLogs.Status,
                    files = modemLogs.Files.Select(x => new { x.Name, x.ExitCode, x.Truncated }) } },
            files = files.Select(x => new { path = x.Key, bytes = x.Value.Length, sha256 = Convert.ToHexStringLower(SHA256.HashData(x.Value)), source = x.Key.StartsWith("modem/", StringComparison.Ordinal) ? "fresh-modem-log" : x.Key == "report.json" ? "cached-application-state" : "local-application-diagnostics" }).ToArray()
        }, Json);
        // Account for manifest bytes too. Remove the oldest optional transcript,
        // never the current application context, if its metadata tips the budget.
        while (true)
        {
            var manifest = Manifest();
            if (payloadBytes + manifest.Length <= ArchiveLimit) { files.Add("manifest.json", manifest); break; }
            if (optionalLogs.Count == 0) throw new InvalidDataException("Diagnostic export exceeds its size limit.");
            var oldest = optionalLogs[^1]; optionalLogs.RemoveAt(optionalLogs.Count - 1);
            payloadBytes -= files[oldest].Length; files.Remove(oldest); omissions.Add(skippedInstallLogs);
        }
        var directory = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(destination))!;
        Directory.CreateDirectory(directory); SafePath(directory);
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var zip = new ZipArchive(output, ZipArchiveMode.Create))
                foreach (var (name, bytes) in files)
                { ct.ThrowIfCancellationRequested(); using var stream = zip.CreateEntry(name, CompressionLevel.Optimal).Open(); stream.Write(bytes); }
            using (var zip = ZipFile.OpenRead(temporary))
                foreach (var entry in zip.Entries)
                {
                    ct.ThrowIfCancellationRequested(); using var input = entry.Open(); using var output = new MemoryStream(); input.CopyTo(output);
                    if (!files.TryGetValue(entry.FullName, out var expected) || !output.ToArray().AsSpan().SequenceEqual(expected))
                        throw new InvalidDataException("Diagnostic ZIP verification failed.");
                }
            File.Move(temporary, destination, false);
            return new(destination, files.Count, saved.Count, omissions.Distinct().Count());
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
