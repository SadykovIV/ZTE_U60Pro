using System.Text;
using System.Text.Json;

namespace ZteImeiStudio.Windows.Esim;

public static class EsimProtocol
{
    public static async Task<EsimResult> ExchangeAsync(Stream output, Stream input, EsimRequest request,
        Func<JsonElement, CancellationToken, Task<(int Code, string Hex)>> http, IProgress<string>? progress, CancellationToken ct,
        Action<string, JsonElement?>? diagnostic = null)
    {
        EsimValidation.Request(request);
        await WriteAsync(input, request, ct);
        var reader = new BoundedLines(output); EsimResult? result = null;
        ulong lastId = 0, lastLogSequence = 0; int messages = 0;
        while (await reader.ReadAsync(ct) is { } line)
        {
            if (++messages > 10000 || result is not null) throw new EsimException();
            using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 32 });
            var root = document.RootElement;
            var fields = new HashSet<string>();
            foreach (var field in root.EnumerateObject()) if (!fields.Add(field.Name)) throw new EsimException();
            switch (root.GetProperty("type").GetString())
            {
                case "progress":
                    var stage = root.GetProperty("stage").GetString();
                    if (stage is null || !EsimDiagnostics.Stages.Contains(stage)) throw new EsimException();
                    JsonElement? detail = root.TryGetProperty("detail", out var progressDetail) ? progressDetail : null;
                    _ = EsimDiagnostics.ProgressLine(stage, detail);
                    if (detail is { } typed)
                    {
                        var sequence = typed.GetProperty("log_seq").GetUInt64();
                        if (sequence <= lastLogSequence) throw new EsimException();
                        lastLogSequence = sequence;
                    }
                    diagnostic?.Invoke(stage, detail);
                    progress?.Report(stage); break;
                case "http":
                    if (request.Operation is not ("download" or "enable" or "delete")) throw new EsimException();
                    var id = root.GetProperty("id").GetUInt64();
                    if (id == 0 || id <= lastId) throw new EsimException();
                    lastId = id;
                    var response = await http(root.GetProperty("payload"), ct);
                    await WriteAsync(input, new { type = "http_response", id, rcode = response.Code, rx = response.Hex }, ct); break;
                case "result":
                    bool ok = root.GetProperty("ok").GetBoolean();
                    bool hasComponentError = root.TryGetProperty("component_error", out var componentField);
                    var componentError = EsimDiagnostics.SafeComponentError(hasComponentError && componentField.ValueKind == JsonValueKind.String ? componentField.GetString() : null);
                    if (ok && hasComponentError) throw new EsimException();
                    bool? modemVerified = root.TryGetProperty("modem_verified", out var modemField) ? modemField.GetBoolean() : null;
                    bool? radioRestored = root.TryGetProperty("radio_restored", out var radioField) ? radioField.GetBoolean() : null;
                    EsimSnapshot? snapshot = null;
                    if (root.TryGetProperty("snapshot", out var raw))
                    {
                        snapshot = raw.Deserialize<EsimSnapshot>() ?? throw new EsimException();
                        EsimValidation.Snapshot(snapshot);
                    }
                    if (ok)
                    {
                        if (snapshot is null) throw new EsimException();
                        EsimValidation.Postcondition(request, snapshot);
                        var changed = root.GetProperty("changed").GetBoolean();
                        bool expectedChange = request.Operation != "list" && (request.Operation != "enable" || request.ExpectedSnapshot!.Profiles.Single(p => p.Iccid == request.Iccid).State != "enabled");
                        if (changed != expectedChange || request.Operation == "enable" && (modemVerified != true || radioRestored != true)) throw new EsimException();
                        result = new(true, snapshot, changed, root.GetProperty("notifications_pending").GetBoolean(), ModemVerified: modemVerified, RadioRestored: radioRestored);
                    }
                    else result = new(false, snapshot, false, false,
                        EsimDiagnostics.SafeError(root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String ? error.GetString() : null), modemVerified, radioRestored, componentError);
                    break;
                default: throw new EsimException();
            }
        }
        return result ?? throw new EsimException();
    }
    public static EsimResult Completed(EsimResult result, int exitCode) => exitCode == 0 ? result :
        throw (result.Ok ? new EsimException("agent_exit_failed") : new EsimException(result.Error, result.ComponentError));
    private static async Task WriteAsync(Stream stream, object value, CancellationToken ct)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        if (bytes.Length > EsimValidation.MaximumLineBytes) throw new EsimException();
        await stream.WriteAsync(bytes, ct); await stream.WriteAsync("\n"u8.ToArray(), ct); await stream.FlushAsync(ct);
    }
    private sealed class BoundedLines(Stream source)
    {
        private readonly byte[] buffer = new byte[65536]; private int position, count;
        public async Task<string?> ReadAsync(CancellationToken ct)
        {
            using var line = new MemoryStream();
            while (true)
            {
                if (position == count)
                {
                    count = await source.ReadAsync(buffer, ct); position = 0;
                    if (count == 0) { if (line.Length != 0) throw new EsimException(); return null; }
                }
                int end = Array.IndexOf(buffer, (byte)'\n', position, count - position);
                int length = (end < 0 ? count : end) - position;
                if (line.Length + length > EsimValidation.MaximumLineBytes) throw new EsimException();
                line.Write(buffer, position, length); position += length;
                if (end < 0) continue;
                position++; return new UTF8Encoding(false, true).GetString(line.GetBuffer(), 0, (int)line.Length);
            }
        }
    }
}
