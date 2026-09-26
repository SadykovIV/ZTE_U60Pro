using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows;

public sealed record CatalogLocalizedText(string Ru, string En)
{
    public string Text(string language) => language.StartsWith("en", StringComparison.OrdinalIgnoreCase) ? En : Ru;
}
public sealed record CatalogVerification(string Date, string Result, string Level, string Evidence,
    string EvidenceSHA256, CatalogLocalizedText Summary);
public sealed record VerifiedCatalogEntry(string Id, string Name, string Version, string InstallerID,
    CatalogLocalizedText Description, IReadOnlyList<string> Firmware, IReadOnlyList<string> Architecture,
    IReadOnlyList<string> Openwrt, CatalogVerification Verification);
public sealed record VerifiedCatalogDocument(int SchemaVersion, int Revision, string IssuedAt,
    string MinimumManagerVersion, IReadOnlyList<VerifiedCatalogEntry> Apps);
internal sealed record VerifiedCatalogEnvelope(string Payload, string Signature);

/// <summary>Approval metadata only. It cannot carry commands, executable URLs or new versions.</summary>
public static class VerifiedCatalogPolicy
{
    public const string ManagerVersion = "1.20.0";
    public const int MaxPayloadBytes = 131072;
    public const int MaxCacheBytes = 180000;
    public const string PublicKeyBase64 = "BMUqXhjGxY7o6keBHS1qOvTY7QR67c8mR+KHclTf8ut9LiHf3SHHqTgG4PRTPY9ILJvw06jSx4m7jJIUK7flva4=";
    internal const string BaselinePayload = "ewogICJzY2hlbWFWZXJzaW9uIjogMSwKICAicmV2aXNpb24iOiAxLAogICJpc3N1ZWRBdCI6ICIyMDI2LTA5LTI2VDAwOjAwOjAwWiIsCiAgIm1pbmltdW1NYW5hZ2VyVmVyc2lvbiI6ICIxLjIwLjAiLAogICJhcHBzIjogWwogICAgewogICAgICAiaWQiOiAiaHRvcCIsCiAgICAgICJuYW1lIjogImh0b3AiLAogICAgICAidmVyc2lvbiI6ICIzLjMuMC0xIiwKICAgICAgImluc3RhbGxlcklEIjogImh0b3AiLAogICAgICAiZGVzY3JpcHRpb24iOiB7CiAgICAgICAgInJ1IjogItCf0YDQvtGG0LXRgdGB0YssINC30LDQs9GA0YPQt9C60LAgQ1BVINC4INC40YHQv9C+0LvRjNC30L7QstCw0L3QuNC1INC/0LDQvNGP0YLQuC4iLAogICAgICAgICJlbiI6ICJQcm9jZXNzZXMsIENQVSBsb2FkIGFuZCBtZW1vcnkgdXNhZ2UuIgogICAgICB9LAogICAgICAiZmlybXdhcmUiOiBbCiAgICAgICAgIk1VNTI1MC1CMzEiCiAgICAgIF0sCiAgICAgICJhcmNoaXRlY3R1cmUiOiBbCiAgICAgICAgImFhcmNoNjRfY29ydGV4LWE1MyIKICAgICAgXSwKICAgICAgIm9wZW53cnQiOiBbCiAgICAgICAgIjIzLjA1LjQiCiAgICAgIF0sCiAgICAgICJ2ZXJpZmljYXRpb24iOiB7CiAgICAgICAgImRhdGUiOiAiMjAyNi0wOS0yNSIsCiAgICAgICAgInJlc3VsdCI6ICJwYXNzZWQiLAogICAgICAgICJsZXZlbCI6ICJwaHlzaWNhbC1tb2RlbS1pbnN0YWxsLWFuZC1sYXVuY2giLAogICAgICAgICJldmlkZW5jZSI6ICJldmlkZW5jZS9CMzEtYXBwcy0yMDI2MDkyNS5tZCIsCiAgICAgICAgImV2aWRlbmNlU0hBMjU2IjogIjA5OTQwNGQxN2VmYmI0ZGI3YzNjZjBiNWYzYzkyZWNjZTk5MTFiZGI1MWYzMzkyNjg5Y2MwYjY4YzQxNWFlZDIiLAogICAgICAgICJzdW1tYXJ5IjogewogICAgICAgICAgInJ1IjogItCd0LAgQjMxINC/0YDQvtCy0LXRgNC10L3RiyDRg9GB0YLQsNC90L7QstC60LAg0Lgg0LfQsNC/0YPRgdC6IC0tdmVyc2lvbi4g0JjQvdGC0LXRgNCw0LrRgtC40LLQvdCw0Y8g0YDQsNCx0L7RgtCwINC/0L7QutCwINC90LUg0L/RgNC+0LLQtdGA0LXQvdCwLiIsCiAgICAgICAgICAiZW4iOiAiSW5zdGFsbGF0aW9uIGFuZCAtLXZlcnNpb24gc3RhcnR1cCB2ZXJpZmllZCBvbiBCMzEuIEludGVyYWN0aXZlIG9wZXJhdGlvbiBoYXMgbm90IGJlZW4gdmVyaWZpZWQuIgogICAgICAgIH0KICAgICAgfQogICAgfSwKICAgIHsKICAgICAgImlkIjogIm9wa2ciLAogICAgICAibmFtZSI6ICJvcGtnIiwKICAgICAgInZlcnNpb24iOiAiMjAyMi0wMi0yNC1kMDM4ZTViNi0yIiwKICAgICAgImluc3RhbGxlcklEIjogIm9wa2ciLAogICAgICAiZGVzY3JpcHRpb24iOiB7CiAgICAgICAgInJ1IjogItCt0LrRgdC/0LXRgNC40LzQtdC90YLQsNC70YzQvdGL0Lkg0LzQtdC90LXQtNC20LXRgCDQv9Cw0LrQtdGC0L7QsiDQsiDQvtGC0LTQtdC70YzQvdC+0Lwg0YXRgNCw0L3QuNC70LjRidC1IC9kYXRhLiIsCiAgICAgICAgImVuIjogIkV4cGVyaW1lbnRhbCBwYWNrYWdlIG1hbmFnZXIgaW4gaXNvbGF0ZWQgL2RhdGEgc3RvcmFnZS4iCiAgICAgIH0sCiAgICAgICJmaXJtd2FyZSI6IFsKICAgICAgICAiTVU1MjUwLUIzMSIKICAgICAgXSwKICAgICAgImFyY2hpdGVjdHVyZSI6IFsKICAgICAgICAiYWFyY2g2NF9jb3J0ZXgtYTUzIgogICAgICBdLAogICAgICAib3BlbndydCI6IFsKICAgICAgICAiMjMuMDUuNCIKICAgICAgXSwKICAgICAgInZlcmlmaWNhdGlvbiI6IHsKICAgICAgICAiZGF0ZSI6ICIyMDI2LTA5LTI1IiwKICAgICAgICAicmVzdWx0IjogInBhc3NlZCIsCiAgICAgICAgImxldmVsIjogInBoeXNpY2FsLW1vZGVtLWluc3RhbGwtYW5kLWxhdW5jaCIsCiAgICAgICAgImV2aWRlbmNlIjogImV2aWRlbmNlL0IzMS1hcHBzLTIwMjYwOTI1Lm1kIiwKICAgICAgICAiZXZpZGVuY2VTSEEyNTYiOiAiMDk5NDA0ZDE3ZWZiYjRkYjdjM2NmMGI1ZjNjOTJlY2NlOTkxMWJkYjUxZjMzOTI2ODljYzBiNjhjNDE1YWVkMiIsCiAgICAgICAgInN1bW1hcnkiOiB7CiAgICAgICAgICAicnUiOiAi0J3QsCBCMzEg0L/RgNC+0LLQtdGA0LXQvdGLINGD0YHRgtCw0L3QvtCy0LrQsCDQsNC00LDQv9GC0LXRgNCwLCDQt9Cw0L/Rg9GB0Log0LggbGlzdC1pbnN0YWxsZWQuINCj0YHRgtCw0L3QvtCy0LrQsCDQv9Cw0LrQtdGC0L7QsiDQuNC3INC40L3RgtC10YDQvdC10YLQsCDQv9C+0LrQsCDQvdC1INC/0YDQvtCy0LXRgNC10L3QsC4iLAogICAgICAgICAgImVuIjogIkFkYXB0ZXIgaW5zdGFsbGF0aW9uLCBzdGFydHVwIGFuZCBsaXN0LWluc3RhbGxlZCB2ZXJpZmllZCBvbiBCMzEuIEludGVybmV0IHBhY2thZ2UgaW5zdGFsbGF0aW9uIGhhcyBub3QgYmVlbiB2ZXJpZmllZC4iCiAgICAgICAgfQogICAgICB9CiAgICB9CiAgXQp9Cg==";
    internal const string BaselineSignature = "+yQWUhTZxMgYlrEi5PmC1fYqYzY4Qrrfq6JDeW6NdmxGGzTATuCRhQhcz8ea9SnM1TP+ELaGu/NK9wzfwNZJZw==";
    public static readonly Uri Endpoint = new("https://raw.githubusercontent.com/SadykovIV/ZTE_U60Pro/main/Catalog/verified-apps.json");
    public static readonly Uri SignatureEndpoint = new("https://raw.githubusercontent.com/SadykovIV/ZTE_U60Pro/main/Catalog/verified-apps.sig");
    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { MaxDepth = 16 };
    private static readonly IReadOnlyDictionary<string, string> Versions = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["htop"] = "3.3.0-1", ["iperf3"] = "3.17.1-4", ["mtr"] = "0.95-3", ["tcpdump"] = "4.99.4-1",
        ["opkg"] = "2022-02-24-d038e5b6-2", ["ssclash"] = "v6.4.1"
    };
    public static bool Compatible(VerifiedCatalogEntry item) => item.Id == item.InstallerID &&
        Versions.TryGetValue(item.Id, out var version) && item.Version == version &&
        item.Firmware.Contains("MU5250-B31", StringComparer.Ordinal) &&
        item.Architecture.Contains("aarch64_cortex-a53", StringComparer.Ordinal) &&
        item.Openwrt.Contains("23.05.4", StringComparer.Ordinal);

    public static VerifiedCatalogDocument Validate(byte[] payload, byte[] signature, int minimumRevision = 1,
        byte[]? currentPayload = null, DateTimeOffset? now = null)
    {
        static void Check(bool condition, string reason)
        {
            if (!condition) throw new InvalidDataException("Каталог отклонён: " + reason);
        }
        Check(payload.Length <= MaxPayloadBytes && signature.Length == 64, "размер или формат подписи");
        var point = Convert.FromBase64String(PublicKeyBase64);
        using var key = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = point[1..33], Y = point[33..65] } });
        Check(key.VerifyData(payload, signature, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation), "неверная цифровая подпись");
        var doc = JsonSerializer.Deserialize<VerifiedCatalogDocument>(payload, JsonOptions) ?? throw new InvalidDataException("Empty catalog");
        Check(doc.SchemaVersion == 1 && doc.Revision >= 1, "неподдерживаемая схема");
        Check(doc.Revision >= minimumRevision, "устаревшая ревизия");
        if (doc.Revision == minimumRevision && currentPayload != null)
            Check(payload.AsSpan().SequenceEqual(currentPayload), "повтор ревизии с другим содержимым");
        Check(DateTimeOffset.TryParseExact(doc.IssuedAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var issued) && issued <= (now ?? DateTimeOffset.UtcNow).AddDays(1), "дата публикации");
        Check(Version.TryParse(doc.MinimumManagerVersion, out var needed) && needed.Build >= 0 && needed.Revision < 0 &&
            needed <= Version.Parse(ManagerVersion), "требуется новая версия программы");
        Check(doc.Apps != null && doc.Apps.Count <= 100 && doc.Apps.Select(x => x.Id).Distinct(StringComparer.Ordinal).Count() == doc.Apps.Count, "состав каталога");
        static bool TextOk(string? text, int max) => !string.IsNullOrEmpty(text) && Encoding.UTF8.GetByteCount(text) <= max && !text.Any(c => c < 32 || c == 127);
        static bool LocalizedOk(CatalogLocalizedText? text) => text != null && TextOk(text.Ru, 2048) && TextOk(text.En, 2048);
        foreach (var item in doc.Apps!)
        {
            Check(item != null && Regex.IsMatch(item.Id ?? "", "^[a-z0-9][a-z0-9-]{0,39}$") && item.Id == item.InstallerID &&
                TextOk(item.Name, 100) && TextOk(item.Version, 64) && LocalizedOk(item.Description), "поля приложения");
            Check(new[] { item!.Firmware, item.Architecture, item.Openwrt }.All(x => x != null && x.Count is > 0 and <= 8 && x.All(v => TextOk(v, 80))), "профиль совместимости");
            var proof = item.Verification;
            Check(proof != null && proof.Result == "passed" && proof.Level == "physical-modem-install-and-launch" && LocalizedOk(proof.Summary), "нет физической проверки");
            Check(Regex.IsMatch(proof!.Date ?? "", "^20[0-9]{2}-[0-9]{2}-[0-9]{2}$") && TextOk(proof.Evidence, 200) &&
                proof.Evidence.StartsWith("evidence/", StringComparison.Ordinal) && !proof.Evidence.Contains("..", StringComparison.Ordinal) &&
                !proof.Evidence.Contains('\\') && Regex.IsMatch(proof.EvidenceSHA256 ?? "", "^[a-f0-9]{64}$"), "ссылка на результаты проверки");
        }
        return doc;
    }
    public static byte[] EncodeEnvelope(byte[] payload, byte[] signature) => JsonSerializer.SerializeToUtf8Bytes(
        new VerifiedCatalogEnvelope(Convert.ToBase64String(payload), Convert.ToBase64String(signature)), JsonOptions);
    public static (VerifiedCatalogDocument Document, byte[] Payload, byte[] Signature) ReadEnvelope(byte[] bytes, int minimumRevision = 1, byte[]? currentPayload = null)
    {
        if (bytes.Length > MaxCacheBytes) throw new InvalidDataException("Каталог отклонён: слишком большой кэш");
        var envelope = JsonSerializer.Deserialize<VerifiedCatalogEnvelope>(bytes, JsonOptions) ?? throw new InvalidDataException("Empty catalog cache");
        var payload = Convert.FromBase64String(envelope.Payload); var signature = Convert.FromBase64String(envelope.Signature);
        return (Validate(payload, signature, minimumRevision, currentPayload), payload, signature);
    }
}

public sealed class VerifiedCatalogStore
{
    public static VerifiedCatalogStore Shared { get; } = new();
    public VerifiedCatalogDocument Document { get; private set; }
    public IReadOnlyList<VerifiedCatalogEntry> Entries => Document.Apps.Where(VerifiedCatalogPolicy.Compatible).ToArray();
    public int Revision => Document.Revision;
    public string Status { get; private set; } = "Встроенный проверенный каталог";
    public string Error { get; private set; } = "";
    public bool IsUpdating { get; private set; }
    public event Action? Changed;
    public bool Allows(string id) => Entry(id) != null;
    public VerifiedCatalogEntry? Entry(string id) => Entries.FirstOrDefault(x => x.Id == id);
    public string StatusText(string language) => Translate(Status, language);
    public string ErrorText(string language) => Translate(Error, language);
    private static string Translate(string text, string language)
    {
        if (!language.StartsWith("en", StringComparison.OrdinalIgnoreCase)) return text;
        var messages = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Встроенный проверенный каталог"] = "Bundled verified catalog",
            ["Сохранённый проверенный каталог"] = "Cached verified catalog",
            ["Каталог актуален"] = "Catalog is up to date",
            ["Каталог обновлён"] = "Catalog updated",
            ["Обновление каталога ещё не опубликовано. Сохранён проверенный локальный список."] = "Catalog updates have not been published yet. The verified local list is retained.",
            ["Не удалось получить каталог. Сохранён проверенный локальный список."] = "Unable to retrieve the catalog. The verified local list is retained.",
            ["Сохранённый каталог повреждён или устарел. Используется встроенный список."] = "The cached catalog is invalid or outdated. Using the bundled list.",
            ["размер или формат подписи"] = "invalid signature size or format", ["неверная цифровая подпись"] = "invalid digital signature",
            ["неподдерживаемая схема"] = "unsupported schema", ["устаревшая ревизия"] = "outdated revision",
            ["повтор ревизии с другим содержимым"] = "different contents for the same revision", ["дата публикации"] = "invalid publication date",
            ["требуется новая версия программы"] = "a newer application version is required", ["состав каталога"] = "invalid catalog entries",
            ["поля приложения"] = "invalid application metadata", ["профиль совместимости"] = "invalid compatibility profile",
            ["нет физической проверки"] = "physical modem verification is missing", ["ссылка на результаты проверки"] = "invalid verification evidence reference",
            ["слишком большой кэш"] = "cache exceeds the size limit", ["размер ответа"] = "invalid response size",
            ["превышен допустимый размер"] = "catalog exceeds the size limit"
        };
        if (messages.TryGetValue(text, out var translated)) return translated;
        const string prefix = "Каталог отклонён: ";
        if (text.StartsWith(prefix, StringComparison.Ordinal)) return "Catalog rejected: " + (messages.GetValueOrDefault(text[prefix.Length..]) ?? "invalid metadata");
        return text.Length == 0 ? "" : "Catalog update failed. The verified local list is retained.";
    }
    private readonly string _cachePath;
    private readonly SemaphoreSlim _updateGate = new(1, 1);
    private byte[] _payload, _signature;
    private readonly Func<HttpMessageHandler>? _handlerFactory;

    public VerifiedCatalogStore(string? cachePath = null, Func<HttpMessageHandler>? handlerFactory = null)
    {
        _handlerFactory = handlerFactory;
        _cachePath = cachePath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZTE U60Pro Manager", "Catalog", "verified-envelope.json");
        _payload = Convert.FromBase64String(VerifiedCatalogPolicy.BaselinePayload);
        _signature = Convert.FromBase64String(VerifiedCatalogPolicy.BaselineSignature);
        // Baseline validity must not depend on an inaccurate local clock.
        Document = VerifiedCatalogPolicy.Validate(_payload, _signature, now: new DateTimeOffset(2090, 1, 1, 0, 0, 0, TimeSpan.Zero));
        if (File.Exists(_cachePath))
        {
            try
            {
                var file = new FileInfo(_cachePath);
                if (file.Length > VerifiedCatalogPolicy.MaxCacheBytes || file.LinkTarget != null) throw new InvalidDataException("Invalid catalog cache");
                var next = VerifiedCatalogPolicy.ReadEnvelope(File.ReadAllBytes(_cachePath), Document.Revision, _payload);
                Document = next.Document; _payload = next.Payload; _signature = next.Signature;
                Status = "Сохранённый проверенный каталог";
            }
            catch { Error = "Сохранённый каталог повреждён или устарел. Используется встроенный список."; }
        }
    }

    public async Task UpdateAsync(CancellationToken ct = default)
    {
        if (!await _updateGate.WaitAsync(0, ct)) return;
        IsUpdating = true; Error = ""; Changed?.Invoke();
        try
        {
            using var handler = _handlerFactory?.Invoke() ?? new HttpClientHandler { AllowAutoRedirect = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(TimeSpan.FromSeconds(30));
            var nextPayload = await DownloadAsync(client, VerifiedCatalogPolicy.Endpoint, VerifiedCatalogPolicy.MaxPayloadBytes, deadline.Token);
            var signatureBytes = await DownloadAsync(client, VerifiedCatalogPolicy.SignatureEndpoint, 256, deadline.Token);
            var nextSignature = Convert.FromBase64String(Encoding.UTF8.GetString(signatureBytes).Trim());
            var next = VerifiedCatalogPolicy.Validate(nextPayload, nextSignature, Document.Revision, _payload);
            var data = VerifiedCatalogPolicy.EncodeEnvelope(nextPayload, nextSignature);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_cachePath))!);
            var temp = _cachePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                await using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    await stream.WriteAsync(data, ct); stream.Flush(true);
                }
                File.Move(temp, _cachePath, overwrite: true);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
            var unchanged = next.Revision == Document.Revision;
            Document = next; _payload = nextPayload; _signature = nextSignature;
            Status = unchanged ? "Каталог актуален" : "Каталог обновлён";
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        { Error = "Обновление каталога ещё не опубликовано. Сохранён проверенный локальный список."; }
        catch (InvalidDataException ex) { Error = ex.Message; }
        catch { Error = "Не удалось получить каталог. Сохранён проверенный локальный список."; }
        finally { IsUpdating = false; _updateGate.Release(); Changed?.Invoke(); }
    }
    private static async Task<byte[]> DownloadAsync(HttpClient client, Uri uri, int maximum, CancellationToken ct)
    {
        if (uri.Scheme != "https" || uri.Host != "raw.githubusercontent.com") throw new InvalidDataException("Некорректный адрес каталога");
        using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentLength > maximum)
            throw new InvalidDataException("Каталог отклонён: размер ответа");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var result = new MemoryStream(); var buffer = new byte[8192];
        for (int count; (count = await stream.ReadAsync(buffer, ct)) > 0;)
        {
            if (result.Length + count > maximum) throw new InvalidDataException("Каталог отклонён: превышен допустимый размер");
            result.Write(buffer, 0, count);
        }
        return result.ToArray();
    }
}
