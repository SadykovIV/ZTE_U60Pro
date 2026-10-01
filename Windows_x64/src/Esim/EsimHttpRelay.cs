using System.Net;
using System.Collections.Frozen;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Esim;

public sealed record EsimHttpResponse(int Code, string Hex, string? Error = null);

public sealed class EsimHttpRelay : IDisposable
{
    public const string GsmaDerSha256 = "5e3e91fd454327c3af5d32a7a73bbc59fe43aa7d85fd32d5db44423f80a56bb3";
    public const string GsmaWiseKeyDerSha256 = "9c9fa2e94602c260137122d9704d79993a6ef6d067ce0999ec2f4c109dd7a1a2";
    public static readonly IReadOnlySet<string> GsmaRootHashes = new[] { GsmaDerSha256, GsmaWiseKeyDerSha256 }.ToFrozenSet(StringComparer.Ordinal);
    private readonly X509Certificate2Collection roots = [];
    private readonly HttpClient client;
    public EsimHttpRelay(string pemPath)
    {
        roots.ImportFromPem(File.ReadAllText(pemPath));
        var actualRoots = roots.Cast<X509Certificate2>().Select(root => Convert.ToHexStringLower(SHA256.HashData(root.RawData))).ToHashSet(StringComparer.Ordinal);
        if (actualRoots.Count != roots.Count || !GsmaRootHashes.SetEquals(actualRoots))
        { foreach (var root in roots) root.Dispose(); throw new EsimException("resource_integrity_failed"); }
        var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.None };
        handler.ServerCertificateCustomValidationCallback = (request, certificate, chain, errors) =>
            VerifyServer(request.RequestUri?.IdnHost, certificate, chain, errors, roots.Cast<X509Certificate2>());
        client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }
    public static bool ValidUrl(string? value, out Uri? uri)
    {
        uri = null;
        if (value is null || value.Length > 8192 || value.Any(c => c > 127) || value.Any(char.IsWhiteSpace) || value.Any(char.IsControl) || value.Contains('\\') || !Uri.TryCreate(value, UriKind.Absolute, out var candidate)) return false;
        if (candidate.Scheme != "https" || candidate.Port != 443 || candidate.UserInfo.Length != 0 || candidate.Fragment.Length != 0 || candidate.HostNameType != UriHostNameType.Dns || IPAddress.TryParse(candidate.Host, out _)) return false;
        var domain = candidate.Host;
        var labels = domain.Split('.');
        if (domain.Any(c => c > 127) || labels.Length < 2 || !labels[^1].Any(char.IsAsciiLetter)) return false;
        if (domain.Length is < 1 or > 253 || labels.Any(label => !Regex.IsMatch(label, "^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"))) return false;
        uri = candidate; return true;
    }
    public static bool VerifyServer(string? host, X509Certificate2? certificate, X509Chain? presented, SslPolicyErrors errors, X509Certificate2 trustedRoot)
        => VerifyServer(host, certificate, presented, errors, new[] { trustedRoot });
    public static bool VerifyServer(string? host, X509Certificate2? certificate, X509Chain? presented, SslPolicyErrors errors, IEnumerable<X509Certificate2> trustedRoots)
    {
        if (certificate is null || (errors & (SslPolicyErrors.RemoteCertificateNotAvailable | SslPolicyErrors.RemoteCertificateNameMismatch)) != 0) return false;
        if (errors == SslPolicyErrors.None) return true;
        // GSMA RSP PKI is shared by SM-DP+ operators. The platform has already
        // checked the requested hostname; this adds only the pinned RSP root.
        if (host is null || !ValidUrl("https://" + host + "/", out _) || errors != SslPolicyErrors.RemoteCertificateChainErrors) return false;
        var approved = trustedRoots.ToArray();
        if (approved.Length == 0 || approved.Length > GsmaRootHashes.Count || approved.Any(root => !GsmaRootHashes.Contains(Convert.ToHexStringLower(SHA256.HashData(root.RawData))))) return false;
        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        foreach (var root in approved) chain.ChainPolicy.CustomTrustStore.Add(root);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
        chain.ChainPolicy.DisableCertificateDownloads = true;
        chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));
        if (presented is not null) foreach (var item in presented.ChainElements) chain.ChainPolicy.ExtraStore.Add(item.Certificate);
        return chain.Build(certificate);
    }
    public static HttpRequestMessage BuildRequest(JsonElement payload)
    {
        if (!ValidUrl(payload.GetProperty("url").GetString(), out var uri)) throw new EsimException();
        string hex = payload.GetProperty("tx").GetString() ?? throw new EsimException();
        if (hex.Length > EsimValidation.MaximumHttpBytes * 2 || (hex.Length & 1) != 0 || hex.Any(c => !Uri.IsHexDigit(c))) throw new EsimException();
        var request = new HttpRequestMessage(HttpMethod.Post, uri) { Content = new ByteArrayContent(Convert.FromHexString(hex)) };
        try
        {
            var headers = payload.GetProperty("headers");
            if (headers.ValueKind != JsonValueKind.Array || headers.GetArrayLength() > 3) throw new EsimException();
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var header in headers.EnumerateArray())
            {
                string value = header.GetString() ?? throw new EsimException(); int colon = value.IndexOf(':');
                if (colon < 1 || value.Length > 1024 || value.Any(char.IsControl)) throw new EsimException();
                string name = value[..colon]; string content = value[(colon + 1)..].Trim();
                if (!names.Add(name) || !new[] { "Content-Type", "User-Agent", "X-Admin-Protocol" }.Contains(name, StringComparer.OrdinalIgnoreCase)) throw new EsimException();
                if (name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) request.Content.Headers.TryAddWithoutValidation(name, content);
                else request.Headers.TryAddWithoutValidation(name, content);
            }
            return request;
        }
        catch { request.Dispose(); throw; }
    }
    public async Task<(int Code, string Hex)> SendAsync(JsonElement payload, CancellationToken ct)
    {
        var response = await SendDetailedAsync(payload, ct).ConfigureAwait(false);
        return (response.Code, response.Hex);
    }
    public async Task<EsimHttpResponse> SendDetailedAsync(JsonElement payload, CancellationToken ct)
    {
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(60));
            using var request = BuildRequest(payload);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
            if (response.Content.Headers.ContentLength > EsimValidation.MaximumHttpBytes) return new(0, "", "http_response_too_large");
            using var data = new MemoryStream(); await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
            var bytes = new byte[65536]; int length;
            while ((length = await stream.ReadAsync(bytes, deadline.Token)) != 0)
            {
                if (data.Length + length > EsimValidation.MaximumHttpBytes) return new(0, "", "http_response_too_large");
                data.Write(bytes, 0, length);
            }
            return new((int)response.StatusCode, Convert.ToHexString(data.GetBuffer().AsSpan(0, (int)data.Length)));
        }
        catch (Exception error) { return new(0, "", FailureCode(error, ct.IsCancellationRequested)); }
    }
    // No exception text, URLs, headers or bodies are exposed to the journal.
    public static string FailureCode(Exception error, bool callerCancelled = false)
    {
        if (callerCancelled) return "http_cancelled";
        if (error is OperationCanceledException or TimeoutException) return "http_timeout";
        if (error is AuthenticationException) return "http_tls_failed";
        if (error is HttpRequestException request)
        {
            if (request.HttpRequestError == HttpRequestError.SecureConnectionError) return "http_tls_failed";
            if (request.HttpRequestError == HttpRequestError.NameResolutionError) return "http_dns_failed";
            if (request.HttpRequestError == HttpRequestError.ConnectionError) return "http_connection_failed";
        }
        if (error is SocketException socket) return socket.SocketErrorCode is SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain ? "http_dns_failed" : "http_connection_failed";
        if (error.InnerException is { } inner) return FailureCode(inner);
        return error is EsimException or JsonException or FormatException ? "invalid_http_request" : "http_failed";
    }
    public void Dispose() { client.Dispose(); foreach (var root in roots) root.Dispose(); }
}
