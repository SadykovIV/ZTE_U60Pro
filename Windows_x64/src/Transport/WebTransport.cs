using System.Buffers;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ZteImeiStudio.Transport;

public sealed record WebIdentity(string Imei, string Firmware, string Inner);
public sealed record WebReply(byte[] Data, IReadOnlyDictionary<string, string[]> Headers);
public enum WebProbeState { AuthenticationRequired }

public interface IWebTransport
{
    Task<WebReply> RequestAsync(string path, byte[]? data = null,
        string? contentType = null, string? cookie = null, CancellationToken ct = default);
}

public enum WebFailureKind
{
    PasswordRequired,
    InvalidPassword,
    AuthenticationRejected,
    MalformedResponse,
    RpcRejected,
    Transport,
}

public sealed class ModemWebException(WebFailureKind kind, string message, int? code = null)
    : IOException(message)
{
    public WebFailureKind Kind { get; } = kind;
    public int? Code { get; } = code;
}

/// <summary>
/// Isolated stock-web HTTP transport. It never uses a proxy, redirects, disk
/// cookies, a persistent cache, or URLs outside the three known modem paths.
/// </summary>
public sealed class WebTransport : IWebTransport, IDisposable
{
    private const int MaximumReplyBytes = 32 * 1024 * 1024;
    private static readonly HashSet<string> AllowedPaths =
        ["/ubus/", "/backup/back_parameter", "/cgi-bin/cgi-upload"];
    private readonly HttpClient _client;
    private readonly Uri _origin;

    public WebTransport(string host)
    {
        ValidateIpv4(host);
        _origin = new Uri("http://" + host, UriKind.Absolute);
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            UseProxy = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(5),
        };
        _client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public async Task<WebReply> RequestAsync(string path, byte[]? data = null,
        string? contentType = null, string? cookie = null, CancellationToken ct = default)
    {
        if (!AllowedPaths.Contains(path))
            throw new ArgumentException("Неизвестный штатный веб-метод модема.", nameof(path));
        if (data is { Length: > MaximumReplyBytes })
            throw new ArgumentException("Передаваемый веб-файл слишком велик.", nameof(data));
        if (cookie is not null && !ValidCookie(cookie))
            throw new ArgumentException("Некорректная веб-сессия.", nameof(cookie));

        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(TimeSpan.FromSeconds(80));
        using var request = new HttpRequestMessage(data is null ? HttpMethod.Get : HttpMethod.Post,
            new Uri(_origin, path));
        request.Headers.TryAddWithoutValidation("Origin", _origin.AbsoluteUri.TrimEnd('/'));
        request.Headers.Referrer = new Uri(_origin.AbsoluteUri.TrimEnd('/') + "/");
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        if (cookie is not null)
            request.Headers.TryAddWithoutValidation("Cookie", "webtoken=\"" + cookie + "\"");
        if (data is not null)
        {
            request.Content = new ByteArrayContent(data);
            if (contentType is not null)
                request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        }
        try
        {
            using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead,
                lifetime.Token).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK ||
                response.Content.Headers.ContentLength > MaximumReplyBytes)
                throw new ModemWebException(WebFailureKind.Transport,
                    "Модем вернул HTTP " + (int)response.StatusCode + " или слишком большой ответ.",
                    (int)response.StatusCode);
            await using var source = await response.Content.ReadAsStreamAsync(lifetime.Token)
                .ConfigureAwait(false);
            using var output = new MemoryStream();
            var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
            try
            {
                while (true)
                {
                    var count = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), lifetime.Token)
                        .ConfigureAwait(false);
                    if (count == 0) break;
                    if (count > MaximumReplyBytes - output.Length)
                        throw new ModemWebException(WebFailureKind.Transport,
                            "Ответ модема превышает допустимый размер.");
                    output.Write(buffer, 0, count);
                }
            }
            finally { ArrayPool<byte>.Shared.Return(buffer); }
            var headers = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
            foreach (var header in response.Headers)
                headers[header.Key] = header.Value.ToArray();
            return new WebReply(output.ToArray(), headers);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException("Веб-интерфейс модема не ответил вовремя.");
        }
    }

    public void Dispose() => _client.Dispose();

    internal static bool ValidCookie(string text) =>
        text.Length is > 0 and <= 1024 && text.All(c => c is >= '!' and <= '~' and not '"' and not ';');

    internal static void ValidateIpv4(string host)
    {
        if (string.IsNullOrEmpty(host) || host.Split('.').Length != 4 ||
            host.Any(c => c != '.' && (c < '0' || c > '9')) ||
            !IPAddress.TryParse(host, out var address) || address.AddressFamily != AddressFamily.InterNetwork)
            throw new ArgumentException("Введите полный IPv4-адрес модема.", nameof(host));
    }
}

/// <summary>Stock MU5250 ubus login, identity, and encrypted backup protocol.</summary>
public sealed class ModemWebClient : IDisposable
{
    private static readonly string ZeroSession = new('0', 32);
    private readonly IWebTransport _transport;
    private readonly bool _ownsTransport;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string _session = ZeroSession;
    private string? _cookie;

    public ModemWebClient(string host, IWebTransport? transport = null)
    {
        _transport = transport ?? new WebTransport(host);
        _ownsTransport = transport is null;
    }

    /// <summary>
    /// Passive check of the stock ubus protocol. It sends no password and never
    /// treats an arbitrary HTTP 200 page as a recognized modem web service.
    /// </summary>
    public async Task<WebProbeState> ProbeAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            _session = ZeroSession;
            _cookie = null;
            var info = await CallCoreAsync("zwrt_web", "web_login_info", null, ct).ConfigureAwait(false);
            if (!info.TryGetProperty("zte_web_sault", out var value) ||
                value.ValueKind != JsonValueKind.String ||
                string.IsNullOrEmpty(value.GetString()) ||
                Encoding.UTF8.GetByteCount(value.GetString()!) > 1024)
                throw Malformed("устройство не подтвердило протокол веб-интерфейса");
            return WebProbeState.AuthenticationRequired;
        }
        finally { _gate.Release(); }
    }

    public async Task LoginAsync(string password, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(password))
            throw new ModemWebException(WebFailureKind.PasswordRequired, "Введите пароль веб-интерфейса.");
        if (Encoding.UTF8.GetByteCount(password) > 256 || password.Contains('\0'))
            throw new ArgumentException("Пароль веб-интерфейса имеет недопустимую длину.", nameof(password));
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            _session = ZeroSession;
            _cookie = null;
            var info = await CallCoreAsync("zwrt_web", "web_login_info", null, ct).ConfigureAwait(false);
            if (!info.TryGetProperty("zte_web_sault", out var saltValue) ||
                saltValue.ValueKind != JsonValueKind.String)
                throw Malformed("не получен challenge веб-интерфейса");
            var salt = saltValue.GetString()!;
            if (salt.Length == 0 || Encoding.UTF8.GetByteCount(salt) > 1024)
                throw Malformed("неверный challenge веб-интерфейса");
            var first = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(password)));
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(first + salt)));
            var result = await CallCoreAsync("zwrt_web", "web_login",
                new Dictionary<string, object?> { ["password"] = hash }, ct).ConfigureAwait(false);
            if (!result.TryGetProperty("result", out var codeValue) || !TryStatusCode(codeValue, out var code))
                throw Malformed("не получен код входа");
            if (code == 1)
                throw new ModemWebException(WebFailureKind.InvalidPassword,
                    "Вход отклонён: неверный пароль веб-интерфейса.");
            if (code != 0)
                throw new ModemWebException(WebFailureKind.AuthenticationRejected,
                    "Веб-интерфейс отклонил вход (код " + code + ").", code);
            if (!result.TryGetProperty("ubus_rpc_session", out var sessionValue) ||
                sessionValue.ValueKind != JsonValueKind.String ||
                !ValidSession(sessionValue.GetString()) || _cookie is null)
                throw Malformed("вход подтверждён, но не получена действительная веб-сессия");
            _session = sessionValue.GetString()!;
        }
        catch
        {
            _session = ZeroSession;
            _cookie = null;
            throw;
        }
        finally { _gate.Release(); }
    }

    public async Task<WebIdentity> GetIdentityAsync(bool skipFirmwareCheck = false,
        CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var value = await CallCoreAsync("zwrt_web", "device_info", null, ct).ConfigureAwait(false);
            var imei = RequiredString(value, "imei");
            var firmware = RequiredString(value, "integrate_version");
            var inner = RequiredString(value, "wa_inner_version");
            if (!ValidImei(imei)) throw Malformed("некорректный IMEI устройства");
            if (firmware.Length == 0 || inner.Length == 0 ||
                Encoding.UTF8.GetByteCount(firmware) > 256 || Encoding.UTF8.GetByteCount(inner) > 256 ||
                firmware.Contains('\0') || inner.Contains('\0'))
                throw Malformed("некорректные сведения о прошивке");
            if (!skipFirmwareCheck &&
                (firmware != "CN_ZTE_MU5250V1.0.0B31" || inner != "BD_CNMU5250V1.0.0B31"))
                throw new ModemWebException(WebFailureKind.AuthenticationRejected,
                    "Автоматическая настройка поддерживает только проверенную MU5250 B31.");
            return new WebIdentity(imei, firmware, inner);
        }
        finally { _gate.Release(); }
    }

    public async Task<byte[]> DownloadFreshBackupAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await CallCoreAsync("zwrt_mc.device.manager", "device_backup_proc",
                new Dictionary<string, object?> { ["procType"] = "web" }, ct).ConfigureAwait(false);
            await Task.Delay(TimeSpan.FromSeconds(2), ct).ConfigureAwait(false);
            var reply = await _transport.RequestAsync("/backup/back_parameter", cookie: _cookie, ct: ct)
                .ConfigureAwait(false);
            if (reply.Data.Length is < 24 or > 8 * 1024 * 1024 ||
                !reply.Data.AsSpan(0, 8).SequenceEqual("Salted__"u8))
                throw Malformed("некорректный зашифрованный бэкап");
            return reply.Data;
        }
        finally { _gate.Release(); }
    }

    public async Task UploadBackupAsync(byte[] encrypted, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(encrypted);
        if (encrypted.Length is < 24 or > 16 * 1024 * 1024 ||
            !encrypted.AsSpan(0, 8).SequenceEqual("Salted__"u8))
            throw new ArgumentException("Некорректный зашифрованный бэкап.", nameof(encrypted));
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var boundary = "----zte-imei-" + Guid.NewGuid();
            using var body = new MemoryStream();
            body.Write(Encoding.UTF8.GetBytes("--" + boundary +
                "\r\nContent-Disposition: form-data; name=\"filename\"\r\n\r\n/tmp/back_parameter\r\n--" + boundary +
                "\r\nContent-Disposition: form-data; name=\"filedata\"; filename=\"back_parameter\"" +
                "\r\nContent-Type: application/octet-stream\r\n\r\n"));
            body.Write(encrypted);
            body.Write(Encoding.UTF8.GetBytes("\r\n--" + boundary + "--\r\n"));
            var reply = await _transport.RequestAsync("/cgi-bin/cgi-upload", body.ToArray(),
                "multipart/form-data; boundary=" + boundary, _cookie, ct).ConfigureAwait(false);
            using var document = ParseJson(reply.Data);
            var root = document.RootElement;
            var expected = Convert.ToHexString(SHA256.HashData(encrypted)).ToLowerInvariant();
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("sha256sum", out var checksum) ||
                checksum.ValueKind != JsonValueKind.String || checksum.GetString() != expected)
                throw Malformed("SHA256 загруженного бэкапа не совпал; восстановление не запущено");
        }
        finally { _gate.Release(); }
    }

    /// <summary>Never call this again after a connection loss without reconciling device state.</summary>
    public async Task RestoreBackupAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await CallCoreAsync("zwrt_mc.device.manager", "device_restore_proc",
                new Dictionary<string, object?> { ["procType"] = "web" }, ct).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonElement> CallCoreAsync(string target, string method,
        Dictionary<string, object?>? arguments, CancellationToken ct)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new[]
        {
            new Dictionary<string, object?>
            {
                ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "call",
                ["params"] = new object?[] { _session, target, method, arguments ?? new Dictionary<string, object?>() },
            },
        });
        var reply = await _transport.RequestAsync("/ubus/", payload, "application/json", _cookie, ct)
            .ConfigureAwait(false);
        using var document = ParseJson(reply.Data);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() != 1 ||
            root[0].ValueKind != JsonValueKind.Object ||
            !root[0].TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Array ||
            result.GetArrayLength() < 1 || !TryStatusCode(result[0], out var code))
            throw Malformed("не получен результат " + method);
        if (code != 0)
            throw new ModemWebException(WebFailureKind.RpcRejected,
                "Веб-интерфейс отклонил операцию " + method + " (код " + code + ").", code);
        if (result.GetArrayLength() > 2 ||
            (result.GetArrayLength() == 2 && result[1].ValueKind != JsonValueKind.Object))
            throw Malformed("неверные данные " + method);
        if (reply.Headers.TryGetValue("Set-Cookie", out var cookies))
        {
            foreach (var line in cookies)
            foreach (var part in line.Split(';'))
            {
                var item = part.Trim();
                if (!item.StartsWith("webtoken=", StringComparison.Ordinal)) continue;
                var token = item[9..].Trim('"');
                if (!WebTransport.ValidCookie(token)) throw Malformed("неверный токен веб-сессии");
                _cookie = token;
            }
        }
        if (result.GetArrayLength() == 2) return result[1].Clone();
        using var empty = JsonDocument.Parse("{}");
        return empty.RootElement.Clone();
    }

    private static JsonDocument ParseJson(byte[] data)
    {
        try { return JsonDocument.Parse(data); }
        catch (JsonException) { throw Malformed("неверный JSON-ответ модема"); }
    }

    private static string RequiredString(JsonElement root, string name)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
            throw Malformed("отсутствует поле " + name);
        return value.GetString()!;
    }

    private static bool TryStatusCode(JsonElement value, out int result)
    {
        result = 0;
        return value.ValueKind switch
        {
            JsonValueKind.Number => value.TryGetInt32(out result),
            JsonValueKind.String => int.TryParse(value.GetString(), out result),
            _ => false,
        };
    }

    private static bool ValidSession(string? value) => value is { Length: 32 } &&
        value != ZeroSession && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F');

    private static bool ValidImei(string value)
    {
        if (value.Length != 15 || value.Any(c => c is < '0' or > '9')) return false;
        var sum = 0;
        for (var index = 0; index < value.Length; index++)
        {
            var digit = value[index] - '0';
            if (index % 2 == 1) digit *= 2;
            sum += digit > 9 ? digit - 9 : digit;
        }
        return sum % 10 == 0;
    }

    private static ModemWebException Malformed(string detail) =>
        new(WebFailureKind.MalformedResponse, "Некорректный ответ веб-интерфейса: " + detail + ".");

    public void Dispose()
    {
        _gate.Dispose();
        if (_ownsTransport && _transport is IDisposable owned) owned.Dispose();
    }
}
