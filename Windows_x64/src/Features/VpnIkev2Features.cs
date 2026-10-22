using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Features;

public sealed record VpnIkev2Configuration(string Server, string ServerId, string Username, string Password, string CaCertificate, string Dns = "10.0.2.1")
{
    public override string ToString() => "IKEv2 configuration (private)";
}
public sealed record VpnIkev2Profile(string Id, string Name, VpnIkev2Configuration Configuration);

public sealed partial class DeviceFeatureService
{
    internal static VpnIkev2Configuration ValidateVpnIkev2(VpnIkev2Configuration value, bool editing)
    {
        value = value with { Server = value.Server.Trim(), ServerId = string.IsNullOrWhiteSpace(value.ServerId) ? value.Server.Trim() : value.ServerId.Trim(), Dns = value.Dns.Trim() };
        static bool Host(string text)
        {
            if (Encoding.UTF8.GetByteCount(text) > 253 || !text.Contains('.')) return false;
            var labels = text.Split('.');
            if (text.All(c => c is >= '0' and <= '9' or '.'))
                return labels.Length == 4 && labels.All(label => byte.TryParse(label, out var number) && number.ToString(System.Globalization.CultureInfo.InvariantCulture) == label);
            return labels.All(label => label.Length <= 63 && Regex.IsMatch(label, @"\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z"));
        }
        Check(Host(value.Server), VpnMessages.Errors["VPN_IKEV2_INVALID_SERVER"]);
        Check(Host(value.ServerId), VpnMessages.Errors["VPN_IKEV2_INVALID_ID"]);
        Check(value.Username.Length > 0 && Encoding.UTF8.GetByteCount(value.Username) <= 256 && !value.Username.Any(char.IsControl), VpnMessages.Errors["VPN_IKEV2_INVALID_USERNAME"]);
        Check((editing || value.Password.Length > 0) && Encoding.UTF8.GetByteCount(value.Password) <= 1024 && !value.Password.Any(char.IsControl), VpnMessages.Errors["VPN_IKEV2_INVALID_PASSWORD"]);
        Check(Encoding.UTF8.GetByteCount(value.CaCertificate) <= 65536 && value.CaCertificate.Contains("-----BEGIN CERTIFICATE-----", StringComparison.Ordinal) && value.CaCertificate.Contains("-----END CERTIFICATE-----", StringComparison.Ordinal) && !value.CaCertificate.Contains("PRIVATE KEY", StringComparison.Ordinal) && !value.CaCertificate.Contains('\0'), VpnMessages.Errors["VPN_IKEV2_INVALID_CERTIFICATE"]);
        var parts = value.Dns.Split('.');
        var octets = parts.Select(part => byte.TryParse(part, out var n) && n.ToString(System.Globalization.CultureInfo.InvariantCulture) == part ? (int)n : -1).ToArray();
        Check(octets.Length == 4 && octets.All(n => n >= 0) && !(octets[0] == 192 && octets[1] == 168 && octets[2] == 50) && (octets[0] == 10 || (octets[0] == 172 && octets[1] is >= 16 and <= 31) || (octets[0] == 192 && octets[1] == 168)), VpnMessages.Errors["VPN_IKEV2_INVALID_DNS"]);
        return value;
    }

    public Task<VpnStatus> SaveVpnIkev2Async(string? id, string name, VpnIkev2Configuration value, CancellationToken ct = default)
    {
        if (id is not null) ValidateVpnProfileId(id);
        name = ValidateVpnProfileName(name);
        value = ValidateVpnIkev2(value, id is not null);
        var config = new Dictionary<string, object> { ["server"] = value.Server, ["server_id"] = value.ServerId, ["username"] = value.Username, ["ca_certificate"] = value.CaCertificate, ["dns"] = value.Dns };
        if (value.Password.Length > 0) config["password"] = value.Password;
        var request = new Dictionary<string, object> { ["action"] = "save_ikev2", ["name"] = name, ["ikev2"] = config };
        if (id is not null) request["id"] = id;
        Check(JsonSerializer.SerializeToUtf8Bytes(request).Length <= 256 * 1024, "Запрос IKEv2 превышает 256 КиБ.");
        return VpnProfileMutationAsync(request, (before, after) =>
            after.ActiveProfile == before.ActiveProfile && after.Enabled == before.Enabled &&
            (id is null
                ? after.Profiles.Count == before.Profiles.Count + 1 && after.Profiles.Count(p => !before.Profiles.Any(old => old.Id == p.Id) && p.Protocol == "ikev2" && p.Name == name) == 1
                : after.Profiles.Count == before.Profiles.Count && after.Profiles.Any(p => p.Id == id && p.Protocol == "ikev2" && p.Name == name)), ct);
    }

    public async Task<VpnIkev2Profile> GetVpnIkev2Async(string id, CancellationToken ct = default)
    {
        ValidateVpnProfileId(id);
        var identity = await ReadIdentityAsync(ct: ct);
        var payload = await VpnRequestAsync(new { action = "details", id }, ct, expectedIdentity: identity);
        await VerifyIdentityAsync(identity, ct);
        Check(payload.TryGetProperty("profile", out var profile) && StringProperty(profile, "id") == id && StringProperty(profile, "protocol") == "ikev2", "Некорректные настройки IKEv2 (VPN_REPLY_INVALID).");
        Check(profile.TryGetProperty("proxy", out var proxy) && proxy.ValueKind == JsonValueKind.Object && !proxy.TryGetProperty("password", out _), "Некорректные настройки IKEv2 (VPN_REPLY_INVALID).");
        var value = ValidateVpnIkev2(new(StringProperty(proxy, "server") ?? "", StringProperty(proxy, "server_id") ?? "", StringProperty(proxy, "username") ?? "", "", StringProperty(proxy, "ca_certificate") ?? "", StringProperty(proxy, "dns") ?? ""), true);
        return new(id, StringProperty(profile, "name") ?? "", value);
    }
}
