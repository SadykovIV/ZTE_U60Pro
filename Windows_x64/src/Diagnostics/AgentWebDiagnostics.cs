using System.Net;
using System.Net.Http;
using System.Net.Sockets;

namespace ZteImeiStudio.Windows.Diagnostics;

public sealed record AgentWebObservation(string Code, bool IsHtml = false)
{
    public bool Available => Code == "200" && IsHtml;
    public string Description => int.TryParse(Code, out _) && Code.Length == 3
        ? "HTTP " + Code + (IsHtml ? " · HTML" : " · ответ не HTML")
        : Code switch {
            "timeout" => "Истекло время ожидания HTTP", "refused" => "Соединение отклонено",
            "cancelled" => "Проверка отменена", "curl-unavailable" => "На модеме отсутствует curl",
            "ssh-unavailable" => "Проверка через SSH недоступна", "invalid-response" => "Некорректный ответ HTTP",
            "invalid-address" => "Некорректный адрес модема", _ => "HTTP недоступен" };
}

public sealed record AgentWebStatus(string Url, AgentWebObservation Loopback, AgentWebObservation Lan, AgentWebObservation Computer)
{
    public string Log => $"Agent web: url={Url} loopback={Loopback.Code}/html={Loopback.IsHtml.ToString().ToLowerInvariant()} lan={Lan.Code}/html={Lan.IsHtml.ToString().ToLowerInvariant()} computer={Computer.Code}/html={Computer.IsHtml.ToString().ToLowerInvariant()}";
    public string Summary => "Веб-панель: " + Url + "\n" +
        "HTTP на модеме (loopback): " + Loopback.Description + "\n" +
        "HTTP на модеме (LAN): " + Lan.Description + "\n" +
        "HTTP с компьютера: " + Computer.Description + (Warning is { } warning ? "\n" + warning : "");
    public string? Warning => Computer.Available ? null : Loopback.Available || Lan.Available
        ? "Веб-панель отвечает на модеме, но доступ с этого компьютера не подтверждён. Откройте указанный HTTP-адрес и проверьте настройки браузера, прокси и сети."
        : "Доступ к веб-панели не подтверждён. Это отдельная проверка HTTP; состояние процесса агента показано выше. Результаты сохранены в журнале.";
}

public static class AgentWebDiagnostics
{
    public static Uri Address(string host)
    {
        var parts = host.Split('.');
        if (parts.Length != 4 || parts.Any(p => p.Length == 0 || p.Length > 1 && p[0] == '0' || p.Any(c => c is < '0' or > '9') || !byte.TryParse(p, out _)))
            throw new ArgumentException("Некорректный адрес модема");
        return new Uri("http://" + host + ":8080/");
    }
    public static string Command(string host)
    {
        _ = Address(host);
        return """
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
probe() {
  if ! command -v curl >/dev/null 2>&1; then printf 'AGENT_WEB %s curl-unavailable no\n' "$1"; return; fi
  value=$(curl -q --noproxy '*' --silent --output /dev/null --write-out '%{http_code} %{content_type}' --connect-timeout 2 --max-time 4 "$2" 2>/dev/null); rc=$?
  if test "$rc" != 0; then case "$rc" in 7) code=refused;; 28) code=timeout;; *) code=unreachable;; esac; html=no
  else code=${value%% *}; kind=${value#* }; case "$code" in [1-5][0-9][0-9]) ;; *) code=invalid-response;; esac
    case "$kind" in text/html|text/html\;*) html=yes;; *) html=no;; esac
  fi
  printf 'AGENT_WEB %s %s %s\n' "$1" "$code" "$html"
}
probe loopback http://127.0.0.1:8080/ &
probe lan http://HOST:8080/ &
wait
""".Replace("http://HOST:", "http://" + host + ":", StringComparison.Ordinal);
    }
    public static (AgentWebObservation Loopback, AgentWebObservation Lan) Parse(string text)
    {
        var found = new Dictionary<string, AgentWebObservation>();
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var words = line.TrimEnd('\r').Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length != 4 || words[0] != "AGENT_WEB" || words[1] is not ("loopback" or "lan") || found.ContainsKey(words[1]) ||
                words[3] is not ("yes" or "no") || !ValidCode(words[2]))
                return (new("invalid-response"), new("invalid-response"));
            found.Add(words[1], new(words[2], words[3] == "yes"));
        }
        return (found.GetValueOrDefault("loopback") ?? new("invalid-response"), found.GetValueOrDefault("lan") ?? new("invalid-response"));
    }
    private static bool ValidCode(string code) => code is "refused" or "timeout" or "unreachable" or "curl-unavailable" or "invalid-response" ||
        code.Length == 3 && int.TryParse(code, out var number) && number is >= 100 and <= 599;

    public static HttpClientHandler Handler() => new() { UseProxy = false, AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, Credentials = null };

    public static async Task<AgentWebObservation> ProbeAsync(Uri url, HttpClient? supplied = null, CancellationToken ct = default)
    {
        try { if (url != Address(url.Host)) return new("invalid-address"); }
        catch (ArgumentException) { return new("invalid-address"); }
        using var owned = supplied is null ? new HttpClient(Handler()) { Timeout = Timeout.InfiniteTimeSpan } : null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(4));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            using var response = await (supplied ?? owned!).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
            return new(((int)response.StatusCode).ToString(System.Globalization.CultureInfo.InvariantCulture),
                string.Equals(response.Content.Headers.ContentType?.MediaType, "text/html", StringComparison.OrdinalIgnoreCase));
        }
        catch (OperationCanceledException) { return new(ct.IsCancellationRequested ? "cancelled" : "timeout"); }
        catch (HttpRequestException error) { return new(error.InnerException is SocketException { SocketErrorCode: SocketError.ConnectionRefused } ? "refused" : "unreachable"); }
        catch (Exception) { return new("unreachable"); }
    }

    public static async Task<AgentWebStatus> CollectAsync(string host, Func<string, CancellationToken, Task<string>> remote,
        Func<Uri, CancellationToken, Task<AgentWebObservation>>? http = null, CancellationToken ct = default)
    {
        Uri url;
        try { url = Address(host); }
        catch (ArgumentException) { var bad = new AgentWebObservation("invalid-address"); return new("", bad, bad, bad); }
        var computer = (http ?? ((uri, token) => ProbeAsync(uri, ct: token)))(url, ct);
        (AgentWebObservation Loopback, AgentWebObservation Lan) pair;
        try { pair = Parse(await remote(Command(host), ct).ConfigureAwait(false)); }
        catch (Exception) { var bad = new AgentWebObservation(ct.IsCancellationRequested ? "cancelled" : "ssh-unavailable"); pair = (bad, bad); }
        AgentWebObservation pc;
        try { pc = await computer.ConfigureAwait(false); }
        catch (Exception) { pc = new(ct.IsCancellationRequested ? "cancelled" : "unreachable"); }
        return new(url.AbsoluteUri, pair.Loopback, pair.Lan, pc);
    }
}
