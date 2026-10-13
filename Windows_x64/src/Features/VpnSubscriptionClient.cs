using System.Net;
using System.Text;

namespace ZteImeiStudio.Windows.Features;

/// Subscription contents and URLs are credentials. Only fixed failure codes leave this class.
internal static class VpnSubscriptionClient
{
    internal const int MaximumBytes = 8 * 1024 * 1024;
    internal static Uri Validate(string value)
    {
        if (value.Length > 8192 || value.Any(char.IsControl) || !Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            uri.Scheme != "https" || string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0)
            throw new DeviceFeatureException("Нужна ссылка подписки HTTPS без имени пользователя и фрагмента (VPN_SUBSCRIPTION_URL).");
        return uri;
    }
    internal static async Task<string[]> FetchAsync(string url, CancellationToken ct, HttpMessageHandler? suppliedHandler = null)
    {
        var uri = Validate(url);
        using var handler = suppliedHandler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, Credentials = null, AutomaticDecompression = DecompressionMethods.All };
        using var client = new HttpClient(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        // Different providers return different formats for these clients. The modem
        // validates documents in this order; no URL or HTTP response enters logs.
        var tasks = new[] { "clash.meta", "Happ/1.0" }.Select(agent => ReadAsync(agent)).ToArray();
        var replies = await Task.WhenAll(tasks);
        ct.ThrowIfCancellationRequested();
        var documents = replies.Where(value => value is not null).Cast<string>().Distinct(StringComparer.Ordinal).ToArray();
        if (documents.Length == 0) throw new DeviceFeatureException("Не удалось загрузить подписку через интернет компьютера (VPN_SUBSCRIPTION_FETCH).");
        return documents;

        async Task<string?> ReadAsync(string userAgent)
        {
            try
            {
                var target = uri;
                for (var redirects = 0; redirects <= 5; redirects++)
                {
                    using var request = new HttpRequestMessage(HttpMethod.Get, target);
                    request.Headers.UserAgent.ParseAdd(userAgent);
                    using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                    if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                    {
                        if (response.Headers.Location is not { } location || redirects == 5) return null;
                        target = Validate(new Uri(target, location).AbsoluteUri);
                        continue;
                    }
                    if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength > MaximumBytes) return null;
                    await using var input = await response.Content.ReadAsStreamAsync(timeout.Token);
                    using var output = new MemoryStream(); var buffer = new byte[32768];
                    while (true)
                    {
                        var length = await input.ReadAsync(buffer, timeout.Token);
                        if (length == 0) break;
                        if (output.Length + length > MaximumBytes) return null;
                        output.Write(buffer, 0, length);
                    }
                    return new UTF8Encoding(false, true).GetString(output.ToArray()).TrimStart('\uFEFF');
                }
            }
            catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException or DecoderFallbackException or DeviceFeatureException or UriFormatException) { }
            return null;
        }
    }
}
