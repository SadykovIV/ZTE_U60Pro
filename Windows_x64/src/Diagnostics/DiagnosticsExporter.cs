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

/// Fixed local inputs only: saved application activity and the last saved research report.
public static class DiagnosticsExporter
{
    public const int SegmentLimit = 2 * 1024 * 1024;
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
        CancellationToken ct = default)
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
            applicationVersion = privacy.Clean(system.ApplicationVersion),
            connectionMode = privacy.Clean(system.ConnectionMode ?? ""), model = privacy.Clean(system.Model ?? ""), firmware = privacy.Clean(system.Firmware ?? ""),
            operations = current.Select(x => new { x.Timestamp, x.Level, operation = x.Message.StartsWith("eSIM[", StringComparison.Ordinal) ? x.Message : x.Message.Split(':', 2)[0] }).ToArray(),
            note = "Сохранённые сведения приложения. Свежий сбор с модема не выполнялся; пароли, ключи, профили, IMEI и CID не включаются."
        };
        var files = new SortedDictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["report.json"] = JsonSerializer.SerializeToUtf8Bytes(report, Json),
            ["application-journal.jsonl"] = Lines(saved),
            ["current-session.jsonl"] = Lines(current),
            ["operation-traces.jsonl"] = Lines(saved.Where(x => x.Kind == "operation" || x.Message.StartsWith("eSIM[", StringComparison.Ordinal))),
            ["README.txt"] = Encoding.UTF8.GetBytes("Offline diagnostic bundle; no new modem collection or network access.\nreport.json preserves the cached application system-summary format; it is not a fresh modem snapshot.\napplication-journal.jsonl: sanitized saved activity (two bounded 2 MiB segments). Earlier sessions from versions without this journal cannot be recovered.\ncurrent-session.jsonl: latest 2000 in-memory events, may overlap the saved journal.\noperation-traces.jsonl: structured action timing/results and safe eSIM progress; no raw action commands, stdin or responses.\nfirmware-research/: last saved read-only survey, when available, with its own collection times, application/specification versions and sanitized probe transcripts. It may describe a different device/session than the current application summary; no identity match is inferred. Redaction is reapplied during export.\nExisting private keys, trust files, connection settings, backups, VPN profiles and activation codes are never copied. Missing or unsafe inputs are listed in manifest.json.\n")
        };
        object cachedResearchSource = new { status = "missing", path = "FirmwareResearch/latest.json" };
        try
        {
            ct.ThrowIfCancellationRequested();
            var cachedPath = System.IO.Path.Combine(root, "FirmwareResearch", "latest.json");
            SafePath(cachedPath);
            if (!File.Exists(cachedPath)) omissions.Add("Cached firmware research is missing; no new collection was performed.");
            else
            {
                var before = new FileInfo(cachedPath); var modified = before.LastWriteTimeUtc; var length = before.Length;
                var bytes = ResearchReportFiles.ReadBoundedFile(cachedPath, FirmwareResearchEngine.TotalLimit, ct);
                var after = new FileInfo(cachedPath);
                if (after.LastWriteTimeUtc != modified || after.Length != length || bytes.LongLength != length)
                    throw new InvalidDataException("Cached research changed while being read.");
                var cached = JsonSerializer.Deserialize<ResearchReport>(bytes, ResearchSpec.Json)
                    ?? throw new InvalidDataException("Invalid cached research.");
                // Per-line cleaning preserves bounded multi-line probe output while
                // applying the same secret policy as the application journal.
                string CleanResearch(string value)
                {
                    // PEM bodies must be removed before splitting into lines,
                    // including a block truncated before its closing delimiter.
                    try { value = Regex.Replace(value, @"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)", "[PRIVATE KEY REDACTED]", RegexOptions.None, TimeSpan.FromSeconds(1)); }
                    catch (RegexMatchTimeoutException) { throw new InvalidDataException("Cached research redaction exceeded its limit."); }
                    return string.Join('\n', value.Split('\n').Select(line => { ct.ThrowIfCancellationRequested(); return privacy.Clean(line); }));
                }
                var payload = ResearchReportFiles.BuildExportFiles(cached, CleanResearch, ct);
                foreach (var item in payload) files.Add("firmware-research/" + item.Key, item.Value);
                cachedResearchSource = new { status = "included", path = "FirmwareResearch/latest.json",
                    sourceLastWriteAt = new DateTimeOffset(modified, TimeSpan.Zero), sourceBytes = bytes.Length,
                    sourceSha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)),
                    collectionStartedAt = cached.StartedAt, collectionCompletedAt = cached.CompletedAt,
                    applicationVersion = privacy.Clean(cached.ApplicationVersion), specificationRevision = cached.SpecificationRevision,
                    specificationSha256 = cached.SpecificationSHA256, relationToCurrentConnection = "not-assessed" };
            }
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or ArgumentException or System.Security.SecurityException)
        {
            omissions.Add("Cached firmware research unavailable, malformed, oversized or unsafe; application activity is still included.");
            cachedResearchSource = new { status = "omitted", path = "FirmwareResearch/latest.json" };
        }
        if (files.Values.Sum(x => (long)x.Length) > 32 * 1024 * 1024) throw new InvalidDataException("Diagnostic export exceeds its size limit.");
        files["manifest.json"] = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1, collectedFromModem = false, exportedAt, omissions = omissions.Distinct().ToArray(),
            sources = new { applicationSummary = new { kind = "cached-application-state", capturedAt = (DateTimeOffset?)null }, firmwareResearch = cachedResearchSource },
            files = files.Select(x => new { path = x.Key, bytes = x.Value.Length, sha256 = Convert.ToHexStringLower(SHA256.HashData(x.Value)), source = x.Key.StartsWith("firmware-research/", StringComparison.Ordinal) ? "cached-firmware-research" : x.Key == "report.json" ? "cached-application-state" : "local-application-diagnostics" }).ToArray()
        }, Json);
        if (files.Values.Sum(x => (long)x.Length) > 32 * 1024 * 1024) throw new InvalidDataException("Diagnostic export exceeds its size limit.");
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
