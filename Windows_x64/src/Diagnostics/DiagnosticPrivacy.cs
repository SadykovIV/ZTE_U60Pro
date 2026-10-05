using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Windows.Research;

namespace ZteImeiStudio.Windows.Diagnostics;

/// Known inputs stay in memory only. Persisted diagnostics never contain parameters.
public sealed class DiagnosticPrivacy
{
    private readonly object gate = new();
    private readonly HashSet<string> secrets = new(StringComparer.Ordinal);
    private int secretCharacters;
    private bool suppressDetails;
    private static readonly Regex SensitiveName = new(
        "password|passwd|passphrase|secret|token|authorization|cookie|private.?key|api.?key|psk|pin|puk|backup.?key.?suffix|activation.?code|confirmation.?code|matching.?id|key_2g|key_5g|пароль",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    public void Remember(IEnumerable<string?> values)
    {
        lock (gate)
        {
            foreach (var value in values)
            {
                if (string.IsNullOrEmpty(value) || secrets.Contains(value)) continue;
                if (secrets.Count >= 256 || value.Length > 65536 || secretCharacters + value.Length > 262144)
                { suppressDetails = true; continue; }
                secrets.Add(value); secretCharacters += value.Length;
            }
        }
    }

    public void RememberParameters(IReadOnlyDictionary<string, string>? values)
    {
        if (values is null) return;
        try
        {
            Remember(values.Where(x => SensitiveName.IsMatch(x.Key) || x.Key is "imei1" or "imei2" or "iccid" or "eid" or "ssid")
                .Select(x => x.Value));
        }
        catch (Exception error) when (error is RegexMatchTimeoutException or ArgumentException or InvalidOperationException)
        { lock (gate) suppressDetails = true; }
    }

    public string Clean(string value)
    {
        lock (gate)
        {
            if (suppressDetails) return "[Diagnostic detail omitted: private input limit]";
            if (value.Length > 65536) return "[Diagnostic detail omitted: size limit]";
            try
            {
                // Replace known values before truncating, including values shorter than the
                // research redactor's three-character minimum and JSON-escaped inputs.
                foreach (var secret in secrets.OrderByDescending(x => x.Length))
                {
                    value = value.Replace(secret, "[REDACTED]", StringComparison.Ordinal);
                    var escaped = System.Text.Json.JsonSerializer.Serialize(secret)[1..^1];
                    if (escaped != secret) value = value.Replace(escaped, "[REDACTED]", StringComparison.Ordinal);
                }
                value = Regex.Replace(value, @"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)", "[PRIVATE KEY REDACTED]", RegexOptions.None, TimeSpan.FromSeconds(1));
                // Discard a whole credential-bearing line: quoted JSON/shell escapes and
                // Cookie lists must not leak a suffix. No raw transport output is collected.
                value = string.Join('\n', value.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').Select(line =>
                    Regex.IsMatch(line, @"(?i)\bLPA:|\bBearer\s|(?:password|passwd|passphrase|secret|token|authorization|cookie|private.?key|api.?key|psk|pin|puk|backup.?key.?suffix|activation.?code|confirmation.?code|matching.?id|key_2g|key_5g|пароль)[""']?\s*(?:[:=]|\s+\S)", RegexOptions.None, TimeSpan.FromSeconds(1))
                        ? "[Confidential line omitted]" : line));
                value = Regex.Replace(value, @"(?i)\b(?:https?|ftp|ssh|socks[45]?|vless|vmess|trojan|ss|ssr|hysteria2?|tuic)://[^\s""<>]+|\b(?:APP_(?:NV|EFS|CONFIG)|EFS_CHUNK)[^\n]*|[A-Za-z0-9_+/=-]{100,}", "[PRIVATE DATA REDACTED]", RegexOptions.None, TimeSpan.FromSeconds(1));
                value = new ResearchRedactor().Clean(value);
                // Preserve diagnostic text, not terminal control sequences.
                value = new string(value.Where(c => !char.IsControl(c) || c is '\n' or '\t').ToArray());
                return value.Length <= 4096 ? value : value[..4096] + " [truncated]";
            }
            catch (RegexMatchTimeoutException) { return "[Diagnostic detail omitted: redaction limit]"; }
        }
    }
}
