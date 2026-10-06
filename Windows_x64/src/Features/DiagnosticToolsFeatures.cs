using System.Text;
using System.Text.Json;

namespace ZteImeiStudio.Windows.Features;

public sealed record DiagnosticToolsStatus(string? Active, string? Previous, bool CanRollback,
    bool Running, ulong FreeKiB, IReadOnlySet<string> Selected, IReadOnlySet<string> PreviousSelected);

public sealed partial class DeviceFeatureService
{
    private const string DiagnosticManagerHash = "159a0ccdf8582f480dec9e6481b6ea2ca4eea2b3e078ec5c7ed5b96f228b4d18";
    private const string DiagnosticMetadataHash = "eca4ce7778bf5d14a0e9000850c32e620a7b4f286a7764b5acbd8507cdcd0426";
    private static readonly string[] DiagnosticToolIds = ["htop", "iperf3", "mtr", "tcpdump"];

    public Task<DiagnosticToolsStatus> GetDiagnosticToolsStatusAsync(CancellationToken ct = default)
        => InvokeDiagnosticAsync("inspect", null, ct);
    public Task<DiagnosticToolsStatus> InstallDiagnosticToolsAsync(string? toolId = null, CancellationToken ct = default)
    {
        Check(toolId == null || DiagnosticToolIds.Contains(toolId), "Неизвестное диагностическое приложение.");
        return InvokeDiagnosticAsync("install", toolId, ct);
    }
    public Task<DiagnosticToolsStatus> RemoveDiagnosticToolsAsync(string? toolId = null, CancellationToken ct = default)
    {
        Check(toolId == null || DiagnosticToolIds.Contains(toolId), "Неизвестное диагностическое приложение.");
        return InvokeDiagnosticAsync("remove", toolId, ct);
    }
    public Task<DiagnosticToolsStatus> RollbackDiagnosticToolsAsync(CancellationToken ct = default)
        => InvokeDiagnosticAsync("rollback", null, ct);

    private Task<DiagnosticToolsStatus> InvokeDiagnosticAsync(string action, string? toolId, CancellationToken ct)
    {
        if (action == "inspect") return ReadOnly();
        return MutateAsync(async (identity, token) => await Invoke(identity, token), ct, measuredAgentPlatform: true);

        async Task<DiagnosticToolsStatus> ReadOnly()
        {
            var identity = await ReadAgentIdentityAsync(ct);
            var result = await Invoke(identity, null);
            Check(identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
            return result;
        }
        async Task<DiagnosticToolsStatus> Invoke(DeviceIdentity identity, string? token)
        {
            var files = new Dictionary<string, byte[]>(StringComparer.Ordinal)
            {
                ["manager.sh"] = await ResourceAsync("DiagnosticTools", "manager.sh", ct)
            };
            Check(Sha(files["manager.sh"]) == DiagnosticManagerHash, "Несовместимый менеджер диагностических утилит.");
            JsonElement metadata = default;
            if (action == "install")
            {
                var bytes = await ResourceAsync("DiagnosticTools", "bundle.json", ct);
                Check(Sha(bytes) == DiagnosticMetadataHash, "Несовместимый каталог диагностических утилит.");
                using var document = JsonDocument.Parse(bytes);
                metadata = document.RootElement.Clone();
                var archive = await ResourceAsync("DiagnosticTools", "bundle.tar.gz", ct);
                Check(archive.Length == metadata.GetProperty("archiveBytes").GetInt32() && Sha(archive) == StringProperty(metadata, "archiveSHA256"), "Архив диагностических утилит повреждён.");
                files.Add("bundle.tar.gz", archive);
            }
            if (token != null) files.Add("zte-timeout", await ResourceAsync("HostTools", "zte-timeout", ct));
            var stage = await StageAsync("zte-diag", files, ct);
            try
            {
                var args = new List<string> { action };
                if (action == "install") args.AddRange([stage, StringProperty(metadata, "id") ?? "", StringProperty(metadata, "archiveSHA256") ?? "", toolId ?? "all", identity.Cid, identity.BootId]);
                if (action == "remove") args.AddRange([toolId ?? "all", identity.Cid, identity.BootId]);
                if (action == "rollback") args.AddRange([identity.Cid, identity.BootId]);
                var command = (token != null ? Guard(identity, token) : "set -eu; ") +
                    "test \"$(sha256sum " + Quote(stage + "/manager.sh") + " | cut -d ' ' -f1)\" = " + Quote(DiagnosticManagerHash) +
                    "; sh " + Quote(stage + "/manager.sh") + " " + string.Join(" ", args.Select(Quote));
                var result = (await RunAsync(command, seconds: token == null ? 60 : 180, ct: ct)).Stdout;
                return ParseDiagnosticStatus(result);
            }
            finally { await CleanupStageAsync(stage, files.Keys.Concat(["bundle.tar", "archive.files"]), CancellationToken.None); }
        }
    }

    private static DiagnosticToolsStatus ParseDiagnosticStatus(byte[] bytes)
    {
        Check(bytes.Length <= 4096, "Слишком большой ответ диагностики.");
        var lines = Encoding.UTF8.GetString(bytes).Split('\n');
        var legacy = lines[0] == "ZTE_DIAG_TOOLS_V1";
        Check((legacy ? lines.Length == 6 : lines.Length == 8 && lines[0] == "ZTE_DIAG_TOOLS_V2") && lines[^1] == "", "Неполный ответ диагностики.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in lines.Skip(1).SkipLast(1))
        {
            var pair = line.Split('=', 2);
            Check(pair.Length == 2 && fields.TryAdd(pair[0], pair[1]), "Повреждены поля диагностики.");
        }
        var expected = legacy ? new[] { "active", "previous", "running", "free_kib" } : new[] { "active", "previous", "running", "free_kib", "selected", "previous_selected" };
        ulong free = 0;
        Check(fields.Keys.ToHashSet().SetEquals(expected) && ulong.TryParse(fields["free_kib"], out free) && fields["running"] is "0" or "1", "Некорректный статус диагностики.");
        IReadOnlySet<string> ParseSelection(string value)
        {
            if (value is "none" or "unset") return new HashSet<string>();
            var selection = value.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
            Check(selection.IsSubsetOf(DiagnosticToolIds) && selection.Count > 0, "Неизвестный список диагностических утилит.");
            return selection;
        }
        var active = fields["active"] == "none" ? null : fields["active"];
        var previous = fields["previous"] is "none" or "unset" ? null : fields["previous"];
        var selected = legacy ? (active == null ? ParseSelection("none") : ParseSelection(string.Join(',', DiagnosticToolIds))) : ParseSelection(fields["selected"]);
        var previousSelected = legacy ? (previous == null ? ParseSelection("none") : ParseSelection(string.Join(',', DiagnosticToolIds))) : ParseSelection(fields["previous_selected"]);
        Check((active == null) == (selected.Count == 0) && (previous == null) == (previousSelected.Count == 0), "Состав диагностических утилит не совпадает с версией.");
        return new DiagnosticToolsStatus(active, previous, fields["previous"] != "unset", fields["running"] == "1", free, selected, previousSelected);
    }
}
