namespace ZteImeiStudio.Windows.Features;

public sealed record TtlStatus(string State, int? Outbound, int? InboundIncrement, string Capability, string Verification, string Persistence, string? Detail = null);

public sealed partial class DeviceFeatureService
{
    private const string TtlRoot = "/data/zte-imei-ttl";
    private const string TtlManagerHash = "b6588072c82ddd7678093a29b983ec4417c6807562819e3bda69cd6534637b7c";
    private static readonly string[] TtlNames = ["manager.sh", "firewall.sh", "hotplug.sh", "boot.sh"];

    public async Task<TtlStatus> GetTtlStatusAsync(CancellationToken ct = default)
    {
        var identity = await ReadIdentityAsync(ct: ct);
        var installed = await RunTextAsync("if test -e " + TtlRoot + " || test -L " + TtlRoot + "; then echo installed; else echo absent; fi", ct: ct);
        if (installed == "installed")
        {
            var output = await RunTextAsync(TtlManagerCommand("status", identity.Cid), seconds: 90, ct: ct);
            return ParseTtlStatus(output);
        }
        Check(installed == "absent", "Не удалось определить состояние менеджера TTL.");
        var files = await LoadResourcesAsync("TTL", TtlNames, ct);
        var stage = await StageAsync("zte-imei-ttl", files, ct);
        try
        {
            var output = await RunTextAsync("set -eu; test \"$(sha256sum " + Quote(stage + "/manager.sh") + " | cut -d ' ' -f1)\" = " + Quote(TtlManagerHash) + "; sh " + Quote(stage + "/manager.sh") + " status " + Quote(identity.Cid), seconds: 90, ct: ct);
            return ParseTtlStatus(output);
        }
        finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
    }

    public Task<TtlStatus> SetTtlAsync(int? outbound, int? inboundIncrement, CancellationToken ct = default)
    {
        Check((outbound is null or >= 1 and <= 255) && (inboundIncrement is null or >= 1 and <= 255), "TTL должен быть целым числом от 1 до 255.");
        return MutateAsync(async (identity, token) =>
        {
            var installed = await RunTextAsync("if test -e " + TtlRoot + " || test -L " + TtlRoot + "; then echo installed; else echo absent; fi", ct: ct);
            TtlStatus status;
            if (installed == "installed")
            {
                var action = outbound == null && inboundIncrement == null ? "disable" : "apply";
                var arguments = action == "disable" ? new[] { identity.Cid } : new[] { identity.Cid, outbound?.ToString() ?? "off", inboundIncrement?.ToString() ?? "off" };
                var output = await RunTextAsync(Guard(identity, token) + TtlManagerCommand(action, arguments), seconds: 120, ct: ct);
                status = ParseTtlStatus(output);
            }
            else
            {
                Check(installed == "absent", "Каталог TTL требует проверки.");
                var files = await LoadResourcesAsync("TTL", TtlNames, ct);
                var stage = await StageAsync("zte-imei-ttl", files, ct);
                try
                {
                    var action = outbound == null && inboundIncrement == null ? "status " + Quote(identity.Cid) :
                        "install " + Quote(stage) + " " + Quote(identity.Cid) + " " + Quote(outbound?.ToString() ?? "off") + " " + Quote(inboundIncrement?.ToString() ?? "off");
                    var output = await RunTextAsync(Guard(identity, token) + "test \"$(sha256sum " + Quote(stage + "/manager.sh") + " | cut -d ' ' -f1)\" = " + Quote(TtlManagerHash) + "; sh " + Quote(stage + "/manager.sh") + " " + action, seconds: 150, ct: ct);
                    status = ParseTtlStatus(output);
                }
                finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
            }
            Check(status.Outbound == outbound && status.InboundIncrement == inboundIncrement,
                "Модем не подтвердил запрошенные настройки TTL.");
            Check(outbound == null && inboundIncrement == null ? status.State == "disabled" : (status.State is "configured" or "verified") && status.Persistence == "boot",
                "Модем не подтвердил сохранение правил TTL.");
            return status;
        }, ct);
    }

    private static string TtlManagerCommand(string action, params string[] args)
    {
        var manager = TtlRoot + "/manager.sh";
        return "set -eu; for dir in /data " + TtlRoot + "; do test -d \"$dir\" && test ! -L \"$dir\" && test \"$(stat -c %u \"$dir\")\" = 0; done; " +
            "test -f " + manager + " && test ! -L " + manager + "; test \"$(sha256sum " + manager + " | cut -d ' ' -f1)\" = " + Quote(TtlManagerHash) + "; sh " + manager + " " + action + " " + string.Join(" ", args.Select(Quote));
    }

    private static TtlStatus ParseTtlStatus(string output)
    {
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Check(lines.Length == 1, "Неполный ответ менеджера TTL.");
        var fields = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Check(fields.Length == 7 && fields[0] == "TTL_STATUS", "Неизвестный формат статуса TTL.");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var field in fields.Skip(1))
        {
            var pair = field.Split('=', 2);
            Check(pair.Length == 2 && values.TryAdd(pair[0], pair[1]), "Повреждены поля статуса TTL.");
        }
        Check(values.Keys.ToHashSet().SetEquals(["state", "outbound", "inbound_inc", "capability", "verification", "persistence"]), "Неполный статус TTL.");
        Check(new[] { "disabled", "configured", "verified", "unsupported", "error" }.Contains(values["state"]), "Неизвестное состояние TTL.");
        Check(new[] { "unknown", "supported", "unsupported" }.Contains(values["capability"]), "Неизвестные возможности TTL.");
        Check(new[] { "verified", "unverified", "not-applicable" }.Contains(values["verification"]), "Неизвестный результат проверки TTL.");
        Check(new[] { "none", "session", "boot" }.Contains(values["persistence"]), "Неизвестный режим сохранения TTL.");
        int? Value(string raw)
        {
            if (raw == "off") return null;
            Check(int.TryParse(raw, out var result) && result is >= 1 and <= 255, "Некорректное значение TTL.");
            return result;
        }
        var outbound = Value(values["outbound"]);
        var inbound = Value(values["inbound_inc"]);
        if (values["state"] == "disabled") Check(outbound == null && inbound == null && values["verification"] == "not-applicable", "Несогласованное выключенное состояние TTL.");
        if (values["state"] is "configured" or "verified") Check((outbound != null || inbound != null) && values["capability"] == "supported", "Несогласованное активное состояние TTL.");
        return new TtlStatus(values["state"], outbound, inbound, values["capability"], values["verification"], values["persistence"]);
    }
}
