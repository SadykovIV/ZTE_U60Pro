using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Esim;

public sealed record EsimProfile(
    [property: JsonPropertyName("iccid")] string Iccid,
    [property: JsonPropertyName("isdp_aid")] string? IsdpAid,
    [property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("enabled")] bool Enabled,
    [property: JsonPropertyName("nickname")] string? Nickname,
    [property: JsonPropertyName("service_provider")] string? ServiceProvider,
    [property: JsonPropertyName("name")] string? Name)
{
    [JsonIgnore] public string DisplayName => EsimValidation.Label(Nickname ?? Name ?? ServiceProvider ?? "Без названия");
    public override string ToString() => DisplayName + " · " + EsimValidation.Mask(Iccid);
}
public sealed record EsimSnapshot(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("eid")] string Eid,
    [property: JsonPropertyName("profiles")] IReadOnlyList<EsimProfile> Profiles)
{
    public override string ToString() => "eUICC · " + EsimValidation.Mask(Eid);
}
public sealed class EsimRequest
{
    [JsonPropertyName("protocol")] public int Protocol => 1;
    [JsonPropertyName("operation")] public required string Operation { get; init; }
    [JsonPropertyName("expected_snapshot"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public EsimSnapshot? ExpectedSnapshot { get; init; }
    [JsonPropertyName("activation_code"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? ActivationCode { get; init; }
    [JsonPropertyName("confirmation_code"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? ConfirmationCode { get; init; }
    [JsonPropertyName("iccid"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Iccid { get; init; }
    [JsonPropertyName("confirm_delete"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] public bool ConfirmDelete { get; init; }
}
public sealed record EsimResult(bool Ok, EsimSnapshot? Snapshot, bool Changed, bool NotificationsPending, string Error = "operation_failed", bool? ModemVerified = null, bool? RadioRestored = null, string? ComponentError = null, EsimCardStatus? Card = null);

/// <summary>Fixed capability metadata, never a physical ordinary-SIM inference or a write grant.</summary>
public sealed record EsimCardStatus
{
    public string Kind { get; }
    public string Management { get; }
    public string Reason { get; }
    public bool CleanupConfirmed { get; }
    private EsimCardStatus(string kind, string management, string reason, bool cleanup)
    { Kind = kind; Management = management; Reason = reason; CleanupConfirmed = cleanup; }
    private static readonly HashSet<string> FailureReasons = ["busy", "open_rejected", "cleanup_unknown", "not_ready", "unsupported_device", "read_failed", "operation_failed"];

    public static EsimCardStatus Parse(JsonElement value, bool success)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new EsimException();
        var names = new HashSet<string>();
        foreach (var field in value.EnumerateObject())
            if (!names.Add(field.Name) || field.Name is not ("kind" or "management" or "reason" or "cleanup_confirmed")) throw new EsimException();
        if (names.Count != 4) throw new EsimException();
        string Text(string name) => value.GetProperty(name).ValueKind == JsonValueKind.String ? value.GetProperty(name).GetString()! : throw new EsimException();
        string kind = Text("kind"), management = Text("management"), reason = Text("reason");
        var flag = value.GetProperty("cleanup_confirmed");
        if (flag.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new EsimException();
        bool cleanup = flag.GetBoolean();
        bool valid = success
            ? kind == "euicc_confirmed" && management == "available" && reason == "eid_and_profiles_read" && cleanup
            : kind == "unknown" && management == "unknown" && FailureReasons.Contains(reason) && !cleanup;
        // Reserved absent/unavailable states require a future evidence contract.
        if (!valid) throw new EsimException();
        return new(kind, management, reason, cleanup);
    }

    /// <summary>Call only after service completion: process exit, identity and owned cleanup have passed.</summary>
    public static EsimCardStatus FromAcceptedResult(EsimResult result)
    {
        if (!result.Ok || result.Snapshot is null || result.ComponentError is not null) throw new EsimException();
        EsimValidation.Snapshot(result.Snapshot);
        if (result.Card is { } card)
        {
            if (card.Kind != "euicc_confirmed" || card.Management != "available" || card.Reason != "eid_and_profiles_read" || !card.CleanupConfirmed) throw new EsimException();
            return card;
        }
        // Older agents return the same validated EID/inventory without metadata.
        return new("euicc_confirmed", "available", "eid_and_profiles_read", true);
    }
}
public sealed class EsimException : Exception
{
    public string Code { get; }
    public string? ComponentError { get; }
    public EsimException(string code = "operation_failed", string? componentError = null) : base(EsimDiagnostics.FailureMessage(code))
    { Code = EsimDiagnostics.SafeError(code); ComponentError = EsimDiagnostics.SafeComponentError(componentError); }
}
public static class EsimValidation
{
    public const int MaximumLineBytes = 9 * 1024 * 1024;
    public const int MaximumHttpBytes = 4 * 1024 * 1024;
    public static string Mask(string? text) => text is { Length: > 8 } ? text[..4] + "••••" + text[^4..] : "••••";
    public static string Label(string? text) => Regex.Replace(new string((text ?? "").Where(c => !char.IsControl(c) && char.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.Format).Take(160).ToArray()), "[0-9]{9,}", "••••");
    public static bool ActivationCodeValid(string? code)
    {
        if (code is null || code.Length is < 8 or > 512 || !code.StartsWith("LPA:1$", StringComparison.Ordinal) || code.Any(c => c > 127) || code.Any(char.IsWhiteSpace) || code.Any(char.IsControl)) return false;
        var parts = code.Split('$');
        return parts.Length is >= 3 and <= 5 && EsimHttpRelay.ValidUrl("https://" + parts[1] + "/", out _) && !parts[1].Any(c => c is '/' or ':' or '?' or '#') && parts[2].Length > 0;
    }
    public static string? ComposeManual(string? address, string? matchingId)
    {
        var host = address?.Trim() ?? "";
        var token = matchingId?.Trim() ?? "";
        if (host.Length == 0 || token.Length == 0 || token.Any(c => c < 33 || c > 126 || c == '$')) return null;
        // Accept a domain, or its HTTPS root URL. Never reinterpret a path or credentials.
        if (host.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            if (!EsimHttpRelay.ValidUrl(host, out var parsed) || parsed!.AbsolutePath != "/" || parsed.Query.Length != 0 || host.Contains('?')) return null;
            var authority = host[8..].TrimEnd('/');
            if (authority.Contains('/')) return null;
            host = parsed.Host;
        }
        else if (host.Any(c => c is '/' or ':' or '?' or '#' or '@' or '$')) return null;
        var code = "LPA:1$" + host + "$" + token;
        return ActivationCodeValid(code) ? code : null;
    }
    public static void Snapshot(EsimSnapshot value)
    {
        if (!value.Ok || !Regex.IsMatch(value.Eid ?? "", "^[0-9]{32}$") || value.Profiles is null || value.Profiles.Count > 1024) throw new EsimException();
        var ids = new HashSet<string>(StringComparer.Ordinal); var aids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in value.Profiles)
        {
            if (p is null || !Regex.IsMatch(p.Iccid ?? "", "^[0-9]{18,20}$") || !ids.Add(p.Iccid!) || p.State is not ("enabled" or "disabled" or "unknown") || p.Enabled != (p.State == "enabled")) throw new EsimException();
            if (new[] { p.Name, p.Nickname, p.ServiceProvider }.Any(s => s?.Length > 4096)) throw new EsimException();
            if (p.IsdpAid is not null && (!Regex.IsMatch(p.IsdpAid, "^(?:[0-9a-fA-F]{2}){1,32}$") || !aids.Add(p.IsdpAid))) throw new EsimException();
        }
    }
    public static void Request(EsimRequest request)
    {
        if (request.Operation == "list")
        {
            if (request.ExpectedSnapshot is not null || request.ActivationCode is not null || request.ConfirmationCode is not null || request.Iccid is not null || request.ConfirmDelete) throw new EsimException();
            return;
        }
        if (request.Operation is not ("download" or "enable" or "delete") || request.ExpectedSnapshot is null) throw new EsimException();
        Snapshot(request.ExpectedSnapshot);
        if (request.Operation == "download")
        {
            if (request.Iccid is not null || request.ConfirmDelete || !ActivationCodeValid(request.ActivationCode) || request.ConfirmationCode is { } c && (c.Length is 0 or > 512 || c.StartsWith('-') || c.Any(char.IsControl) || c.Any(char.IsWhiteSpace))) throw new EsimException();
            return;
        }
        if (request.ActivationCode is not null || request.ConfirmationCode is not null || request.Operation == "enable" && request.ConfirmDelete) throw new EsimException();
        var target = request.ExpectedSnapshot.Profiles.SingleOrDefault(p => p.Iccid == request.Iccid);
        if (target is null || (request.Operation == "delete" ? target.State != "disabled" || !request.ConfirmDelete : target.State is not ("disabled" or "enabled"))) throw new EsimException();
    }
    public static string Inventory(EsimProfile p) => p.Iccid + ":" + p.IsdpAid?.ToUpperInvariant() + ":" + p.State;
    public static void Postcondition(EsimRequest request, EsimSnapshot snapshot)
    {
        Snapshot(snapshot);
        if (request.Operation == "list") return;
        var previous = request.ExpectedSnapshot!;
        if (snapshot.Eid != previous.Eid) throw new EsimException();
        var before = previous.Profiles; var after = snapshot.Profiles;
        bool sameOthers = before.Where(p => p.Iccid != request.Iccid).Select(Inventory).Order().SequenceEqual(after.Where(p => p.Iccid != request.Iccid).Select(Inventory).Order());
        var valid = request.Operation switch
        {
            "download" => after.Count == before.Count + 1 && before.All(p => after.Any(q => Inventory(p) == Inventory(q))) && after.Where(p => !before.Any(q => q.Iccid == p.Iccid)).All(p => p.State == "disabled"),
            "enable" => before.Select(p => (p.Iccid, p.IsdpAid?.ToUpperInvariant())).Order().SequenceEqual(after.Select(p => (p.Iccid, p.IsdpAid?.ToUpperInvariant())).Order()) && after.Any(p => p.Iccid == request.Iccid && p.State == "enabled") && after.Where(p => p.Iccid != request.Iccid).All(p => p.State == "disabled"),
            "delete" => !after.Any(p => p.Iccid == request.Iccid) && sameOthers,
            _ => false,
        };
        if (!valid) throw new EsimException();
    }
}
