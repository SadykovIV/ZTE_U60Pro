using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Features;

public sealed record InstalledPackage(string Name, string Version);
public sealed record CatalogApplication(string Id, string Name, string Version, string Description, bool Installed);
public sealed record ApplicationInventory(string Release, string Architecture, ulong DataFreeKiB,
    ulong MemoryAvailableKiB, IReadOnlyList<InstalledPackage> InstalledPackages,
    bool OpkgSystemWritable, bool SsclashInstalled, bool SsclashRunning, bool SsclashProxyRunning,
    bool SsclashUnmanaged, IReadOnlyList<CatalogApplication> Catalog);
public sealed record SsclashRemovalResult(string LocalArchive, string RemoteArchive, string Sha256);

public sealed partial class DeviceFeatureService
{
    internal Func<CancellationToken, Task<byte[]>>? SsclashAssetLoader { get; init; }

    private const string SsclashRoot = "/data/zte-imei-apps/ssclash";
    private const string SsclashService = "/etc/init.d/zte_imei_ssclash";
    private const string SsclashHash = "38ba859187c953d159cdd4f1ff397feb5f29116e0bfc7dc284c45b1a6766c770";
    private const int SsclashBytes = 11_010_232;
    private const string SsclashUrl = "https://github.com/zerolabnet/SSClash-Go/releases/download/v6.4.1/ssclash-linux-arm64";
    private const string SsclashRemoveHash = "8948d37e3298e0de5a57beee9556056ccc3f86dd0eed6da7a5c1ff796db65ddd";

    private static string Section(string output, string start, string end)
    {
        var from = output.IndexOf(start + "\n", StringComparison.Ordinal);
        var to = output.IndexOf(end + "\n", StringComparison.Ordinal);
        Check(from >= 0 && to > from, "Неполный ответ инвентаризации приложений.");
        return output[(from + start.Length + 1)..to];
    }

    public async Task<ApplicationInventory> GetApplicationsAsync(CancellationToken ct = default)
    {
        const string command = "set -eu; printf '__RELEASE__\\n'; cat /etc/openwrt_release; printf '__DATA__\\n'; df -Pk /data; " +
            "printf '__MEM__\\n'; cat /proc/meminfo; printf '__PACKAGES__\\n'; cat /usr/lib/opkg/status; " +
            "printf '__FLAGS__\\n'; if test -w /usr/lib/opkg/status && test -w /usr/bin && test -w /lib && test -w /bin && test -w /sbin; then echo opkg=1; else echo opkg=0; fi; " +
            "if test -e /data/zte-imei-apps/ssclash || test -L /data/zte-imei-apps/ssclash; then echo present=1; else echo present=0; fi; " +
                "if test -d /data/zte-imei-apps/ssclash && test ! -L /data/zte-imei-apps/ssclash && test \"$(cat /data/zte-imei-apps/ssclash/.zte-imei-owner 2>/dev/null)\" = zte-imei-ssclash-v1 && test -f /data/zte-imei-apps/ssclash/bin/ssclash && test ! -L /data/zte-imei-apps/ssclash/bin/ssclash && test \"$(sha256sum /data/zte-imei-apps/ssclash/bin/ssclash | cut -d ' ' -f1)\" = " + SsclashHash + "; then echo ssclash=1; else echo ssclash=0; fi; " +
            "running=0; for pid in $(pidof ssclash 2>/dev/null || true); do if test \"$(readlink /proc/$pid/exe 2>/dev/null || true)\" = /data/zte-imei-apps/ssclash/bin/ssclash; then running=1; fi; done; echo running=$running; " +
            "proxy=0; for p in /proc/[0-9]*/exe; do t=$(readlink \"$p\" 2>/dev/null || true); case \"$t\" in /data/zte-imei-apps/ssclash/bin/clash*|/data/zte-imei-apps/ssclash/bin/mihomo*) proxy=1;; esac; done; echo proxy=$proxy";
        var output = await RunTextAsync(command, seconds: 90, ct: ct);
        Check(Encoding.UTF8.GetByteCount(output) <= 4 * 1024 * 1024, "Слишком большой список пакетов модема.");
        var release = Section(output, "__RELEASE__", "__DATA__");
        var data = Section(output, "__DATA__", "__MEM__");
        var memory = Section(output, "__MEM__", "__PACKAGES__");
        var packagesText = Section(output, "__PACKAGES__", "__FLAGS__");
        var flags = output[(output.LastIndexOf("__FLAGS__\n", StringComparison.Ordinal) + "__FLAGS__\n".Length)..].Split('\n', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
        string Field(string key)
        {
            var match = Regex.Match(release, "(?m)^" + Regex.Escape(key) + "='?([^'\\r\\n]+)'?$", RegexOptions.CultureInvariant);
            return match.Success ? match.Groups[1].Value.TrimEnd('\'') : "";
        }
        var dfLine = data.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var dfColumns = dfLine.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        ulong freeKiB = 0;
        Check(dfColumns.Length >= 4 && ulong.TryParse(dfColumns[3], out freeKiB), "Не удалось прочитать свободное место /data.");
        var memMatch = Regex.Match(memory, "(?m)^MemAvailable:\\s+(\\d+) kB$");
        var available = memMatch.Success && ulong.TryParse(memMatch.Groups[1].Value, out var mem) ? mem : 0;
        var packages = new List<InstalledPackage>();
        foreach (var paragraph in packagesText.Split("\n\n", StringSplitOptions.RemoveEmptyEntries))
        {
            var name = Regex.Match(paragraph, "(?m)^Package: ([^\\r\\n]+)$").Groups[1].Value;
            var version = Regex.Match(paragraph, "(?m)^Version: ([^\\r\\n]+)$").Groups[1].Value;
            var status = Regex.Match(paragraph, "(?m)^Status: ([^\\r\\n]+)$").Groups[1].Value;
            if (name.Length > 0 && version.Length > 0 && status.EndsWith("installed", StringComparison.Ordinal)) packages.Add(new InstalledPackage(name, version));
        }
        var installed = flags.Contains("ssclash=1");
        var present = flags.Contains("present=1");
        var catalog = new List<CatalogApplication>
        {
            new("ssclash", "SSClash-Go", "6.4.1", "Веб-панель прокси; ядро и профиль настраиваются отдельно.", installed),
            new("htop", "htop", "3.3.0", "Процессы, CPU и память.", false),
            new("iperf3", "iperf3", "3.17.1", "Измерение скорости сети.", false),
            new("mtr", "mtr", "0.95", "Маршрут и потери пакетов.", false),
            new("tcpdump", "tcpdump", "4.99.4", "Захват пакетов по команде пользователя.", false)
        };
        try
        {
            var diagnostics = await GetDiagnosticToolsStatusAsync(ct);
            for (var i = 1; i < catalog.Count; i++) catalog[i] = catalog[i] with { Installed = diagnostics.Selected.Contains(catalog[i].Id) };
        }
        catch { /* The stock package inventory remains available independently. */ }
        return new ApplicationInventory(Field("DISTRIB_RELEASE"), Field("DISTRIB_ARCH"), freeKiB, available,
            packages, flags.Contains("opkg=1"), installed, flags.Contains("running=1"), flags.Contains("proxy=1"),
            present && !installed, catalog);
    }

    public Task<ApplicationInventory> InstallSsclashAsync(string password, string lanAddress, CancellationToken ct = default)
    {
        Check(Encoding.UTF8.GetByteCount(password) is >= 8 and <= 128 && password == password.Trim() && !password.Any(ch => ch is '\r' or '\n' or '\0'),
            "Пароль SSClash: 8–128 байт без переносов строк и пробелов по краям.");
        Check(IPAddress.TryParse(lanAddress, out var address) && address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address), "Укажите локальный IPv4 модема.");
        return MutateAsync(async (identity, token) =>
        {
            var state = await GetApplicationsAsync(ct);
            Check(state.Release == "23.05.4" && state.Architecture == "aarch64_cortex-a53" && !state.SsclashInstalled && !state.SsclashUnmanaged && state.DataFreeKiB >= 64 * 1024,
                "Для SSClash нужны OpenWrt 23.05.4 / aarch64_cortex-a53, 64 МиБ и свободное место установки.");
            var binary = await (SsclashAssetLoader ?? DownloadSsclashAsync)(ct);
            ValidateSsclashAsset(binary);
            Check(identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
            var template = await ResourceAsync("Applications", "ssclash-service.sh", ct);
            var service = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(template).Replace("__ZTE_LAN_IPV4__", lanAddress, StringComparison.Ordinal));
            var stage = "/data/zte-imei-apps/.ssclash-" + Guid.NewGuid().ToString("D");
            var serviceStage = "/etc/init.d/.zte-imei-ssclash-" + Guid.NewGuid().ToString("D");
            var guard = Guard(identity, token);
            var preflight = guard + "test \"$(uname -m)\" = aarch64; test ! -e " + SsclashRoot + " && test ! -L " + SsclashRoot + "; test ! -e " + SsclashService + " && test ! -L " + SsclashService + "; " +
                "command -v curl >/dev/null; command -v procd >/dev/null; command -v netstat >/dev/null; " +
                "if pidof clash >/dev/null 2>&1; then exit 73; fi; if netstat -ltn | awk 'NR>2 && $4 ~ /:9091$/ {found=1} END {exit !found}'; then exit 73; fi; " +
                "ip -o -4 addr show | awk -v address=" + Quote(lanAddress) + " '{split($4,a,\"/\");if(a[1]==address)f=1}END{exit !f}'; " +
                "if test -e /data/zte-imei-apps || test -L /data/zte-imei-apps; then test -d /data/zte-imei-apps && test ! -L /data/zte-imei-apps && test \"$(cat /data/zte-imei-apps/.zte-imei-owner)\" = zte-imei-apps-v1; else umask 077; mkdir -m 700 /data/zte-imei-apps; printf zte-imei-apps-v1 > /data/zte-imei-apps/.zte-imei-owner; fi; " +
                "umask 077; mkdir -m 700 " + Quote(stage) + " " + Quote(stage + "/bin") + "; printf zte-imei-ssclash-v1 > " + Quote(stage + "/.zte-imei-owner");
            await RunAsync(preflight, ct: ct);
            var promoted = false;
            var serviceCreated = false;
            try
            {
                var upload = guard + "umask 077; cat > " + Quote(stage + "/bin/ssclash") + "; chmod 700 " + Quote(stage + "/bin/ssclash") + "; sha256sum " + Quote(stage + "/bin/ssclash");
                var proof = await RunTextAsync(upload, binary, 180, ct);
                Check(proof.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() == SsclashHash, "SSClash повреждён при передаче.");
                var version = await RunTextAsync(guard + Quote(stage + "/bin/ssclash") + " version", seconds: 30, ct: ct);
                Check(version.Contains("6.4.1", StringComparison.Ordinal), "Версия SSClash не совпала.");
                await RunAsync(guard + "SSCLASH_ROOT=" + Quote(stage) + " SSCLASH_PLATFORM=openwrt " + Quote(stage + "/bin/ssclash") + " setpass", Encoding.UTF8.GetBytes(password + "\n"), 30, ct);
                await RunAsync(guard + "test -s " + Quote(stage + "/.ssclash/password") + "; grep -q '^pbkdf2[$]' " + Quote(stage + "/.ssclash/password") + "; mv " + Quote(stage) + " " + SsclashRoot, ct: ct);
                promoted = true;
                var serviceHash = Sha(service);
                proof = await RunTextAsync(guard + "umask 077; cat > " + Quote(serviceStage) + "; chmod 700 " + Quote(serviceStage) + "; sha256sum " + Quote(serviceStage), service, 30, ct);
                Check(proof.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() == serviceHash, "Служба SSClash повреждена при передаче.");
                await RunAsync(guard + "test ! -e " + SsclashService + "; ln " + Quote(serviceStage) + " " + SsclashService + "; rm " + Quote(serviceStage), ct: ct);
                serviceCreated = true;
                await RunAsync(guard + SsclashService + " start", seconds: 60, ct: ct);
                var after = await GetApplicationsAsync(ct);
                Check(after.SsclashInstalled && after.SsclashRunning && !after.SsclashProxyRunning, "Служба SSClash не подтвердила запуск с выключенным прокси.");
                await VerifySsclashLoginAsync(password, lanAddress, ct);
                return after;
            }
            catch
            {
                if (serviceCreated)
                    try { await RunAsync(guard + "if test -f " + SsclashService + " && test ! -L " + SsclashService + " && test \"$(sha256sum " + SsclashService + " | cut -d ' ' -f1)\" = " + Quote(Sha(service)) + "; then " + SsclashService + " stop; fi", seconds: 30, ct: CancellationToken.None); } catch { }
                if (!promoted)
                    try { await RunAsync(guard + "test -d " + Quote(stage) + " && test ! -L " + Quote(stage) + "; rm -f " + Quote(stage + "/bin/ssclash") + " " + Quote(stage + "/.zte-imei-owner") + " " + Quote(stage + "/.ssclash/password") + "; rmdir " + Quote(stage + "/.ssclash") + " " + Quote(stage + "/bin") + " " + Quote(stage), seconds: 15, ct: CancellationToken.None); } catch { }
                throw;
            }
        }, ct, measuredAgentPlatform: true);
    }

    // Upstream forbids redistribution of this executable. Only an explicit
    // install action downloads the pinned original asset; no copy is bundled.
    private static async Task<byte[]> DownloadSsclashAsync(CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ZTE-IMEI-Studio/1.19.0");
        using var response = await http.GetAsync(SsclashUrl, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        Check(response.RequestMessage?.RequestUri?.Scheme == "https", "Загрузка SSClash должна использовать HTTPS.");
        Check(response.Content.Headers.ContentLength is null or SsclashBytes, "Размер ответа SSClash не соответствует закреплённому релизу.");
        await using var input = await response.Content.ReadAsStreamAsync(ct);
        using var output = new MemoryStream(SsclashBytes);
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = await input.ReadAsync(buffer, ct);
            if (count == 0) break;
            Check(output.Length + count <= SsclashBytes, "Ответ SSClash превышает ожидаемый размер.");
            output.Write(buffer, 0, count);
        }
        var bytes = output.ToArray();
        return bytes;
    }

    private static void ValidateSsclashAsset(byte[] bytes)
    {
        Check(bytes.Length == SsclashBytes && Sha(bytes) == SsclashHash &&
            bytes.AsSpan(0, 6).SequenceEqual(new byte[] { 0x7f, 0x45, 0x4c, 0x46, 2, 1 }) &&
            bytes[18] == 0xb7 && bytes[19] == 0,
            "Загруженный SSClash не соответствует проверенному Linux ARM64 релизу.");
    }

    private sealed record SsclashHttpReply(int Status, string Cookie, string Body);

    private async Task VerifySsclashLoginAsync(string password, string lanAddress, CancellationToken ct)
    {
        SsclashHttpReply? login = null;
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                var reply = await SsclashCurlAsync(lanAddress, "/login", null, null, ct);
                if (reply.Status == 200) { login = reply; break; }
            }
            catch (DeviceFeatureException) when (attempt < 9) { }
            if (attempt < 9) await Task.Delay(500, ct);
        }
        Check(login != null, "Web-панель SSClash не запустилась.");
        Check(login!.Body.Contains("action=\"/login\"", StringComparison.Ordinal) &&
              !login.Body.Contains("action=\"/setup\"", StringComparison.Ordinal), "SSClash не требует заранее заданный пароль.");
        var csrf = Regex.Match(login.Body, "name=\"csrf\" value=\"([^\"]+)\"");
        Check(csrf.Success, "Не получен CSRF входа SSClash.");
        var body = "csrf=" + Uri.EscapeDataString(csrf.Groups[1].Value) + "&password=" + Uri.EscapeDataString(password);
        var signedIn = await SsclashCurlAsync(lanAddress, "/login", login.Cookie, body, ct);
        Check(signedIn.Status is 302 or 303 && signedIn.Cookie.Length > 0, "SSClash не подтвердил вход с заданным паролем.");
        var status = await SsclashCurlAsync(lanAddress, "/api/status", signedIn.Cookie, null, ct);
        Check(status.Status == 200, "SSClash не подтвердил авторизованный запрос состояния.");
        using var document = JsonDocument.Parse(status.Body);
        Check(document.RootElement.ValueKind == JsonValueKind.Object &&
              document.RootElement.TryGetProperty("running", out var running) && running.ValueKind == JsonValueKind.False,
            "Не подтверждено выключенное состояние прокси SSClash.");
        var anonymous = await SsclashCurlAsync(lanAddress, "/api/status", null, null, ct);
        Check(anonymous.Status is 302 or 303 or 401 or 403, "SSClash API доступен без авторизации; панель остановлена.");
    }

    private async Task<SsclashHttpReply> SsclashCurlAsync(string lanAddress, string path, string? cookie, string? body, CancellationToken ct)
    {
        static string ConfigQuote(string value) => "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
        Check(cookie == null || !cookie.Any(ch => ch is '\r' or '\n' or '\0'), "Некорректный cookie SSClash.");
        var config = "url = " + ConfigQuote("http://" + lanAddress + ":9091" + path) + "\ninclude\nsilent\nshow-error\nmax-time = 10\nconnect-timeout = 3\nnoproxy = \"*\"\n";
        if (!string.IsNullOrEmpty(cookie)) config += "header = " + ConfigQuote("Cookie: " + cookie) + "\n";
        if (body != null) config += "header = \"Content-Type: application/x-www-form-urlencoded\"\ndata = " + ConfigQuote(body) + "\n";
        // curl runs on the modem. The password travels only over SSH stdin and local loopback HTTP.
        var bytes = (await RunAsync("curl --config -", Encoding.UTF8.GetBytes(config), 15, ct)).Stdout;
        Check(bytes.Length <= 1024 * 1024, "Слишком большой ответ панели SSClash.");
        var raw = Encoding.UTF8.GetString(bytes);
        var boundary = raw.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        Check(boundary > 0, "Неполный HTTP-ответ SSClash.");
        var headers = raw[..boundary].Split("\r\n", StringSplitOptions.None);
        var match = Regex.Match(headers[0], "^HTTP/[0-9.]+ ([0-9]{3})(?: |$)");
        Check(match.Success && int.TryParse(match.Groups[1].Value, out _), "Некорректный HTTP-статус SSClash.");
        var cookies = headers.Where(line => line.StartsWith("Set-Cookie:", StringComparison.OrdinalIgnoreCase))
            .Select(line => line[11..].Trim().Split(';', 2)[0]).Where(value => value.Length > 0).ToArray();
        var resultCookie = string.Join("; ", cookies);
        Check(!resultCookie.Any(ch => ch is '\r' or '\n' or '\0'), "Некорректный cookie SSClash.");
        return new SsclashHttpReply(int.Parse(match.Groups[1].Value), resultCookie, raw[(boundary + 4)..]);
    }

    public Task<SsclashRemovalResult> RemoveSsclashAsync(string? recoveryDirectory = null, CancellationToken ct = default)
        => MutateAsync(async (identity, token) =>
        {
            var state = await GetApplicationsAsync(ct);
            Check(state.SsclashInstalled && !state.SsclashUnmanaged && !state.SsclashProxyRunning, "SSClash не принадлежит приложению или прокси ещё работает.");
            var script = await ResourceAsync("Applications", "ssclash-remove.sh", ct);
            Check(Sha(script) == SsclashRemoveHash, "Повреждён сценарий удаления SSClash.");
            var serviceText = await RunTextAsync("set -eu; test -f " + SsclashService + " && test ! -L " + SsclashService + "; cat " + SsclashService, ct: ct);
            var ipMatch = Regex.Match(serviceText, "SSCLASH_ADDR=\"([0-9.]+):9091\"");
            Check(ipMatch.Success && IPAddress.TryParse(ipMatch.Groups[1].Value, out _), "Служба SSClash изменена.");
            var template = await ResourceAsync("Applications", "ssclash-service.sh", ct);
            var expectedService = Encoding.UTF8.GetString(template).Replace("__ZTE_LAN_IPV4__", ipMatch.Groups[1].Value, StringComparison.Ordinal);
            Check(serviceText == expectedService.TrimEnd('\r', '\n'), "Служба SSClash не соответствует встроенному шаблону.");
            var serviceHash = Sha(Encoding.UTF8.GetBytes(expectedService));
            var id = Guid.NewGuid().ToString("D");
            var remoteArchive = "/data/zte-imei-apps/.removals/" + id + "/archive.tar.gz";
            string Command(string action, string? archiveHash = null) => Guard(identity, token) + "sh -s -- " + string.Join(" ",
                (archiveHash == null ? new[] { action, id, SsclashHash, serviceHash } : new[] { action, id, SsclashHash, serviceHash, archiveHash }).Select(Quote));
            Check(identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
            var response = await RunTextAsync(Command("prepare"), script, 180, ct);
            var match = Regex.Match(response, "^SSCLASH_ARCHIVE sha256=([0-9a-f]{64}) bytes=([0-9]+)$");
            long size = 0;
            Check(match.Success && long.TryParse(match.Groups[2].Value, out size) && size is > 0 and <= 256 * 1024 * 1024, "Резервная копия SSClash не подтверждена.");
            var hash = match.Groups[1].Value;
            var bytes = await _shell.DownloadAsync(remoteArchive, TimeSpan.FromSeconds(180), ct);
            Check(bytes.LongLength == size && Sha(bytes) == hash, "Резервная копия SSClash повреждена при передаче; удаление остановлено.");
            recoveryDirectory ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZteImeiStudio", "SsclashBackups");
            Directory.CreateDirectory(recoveryDirectory);
            var localArchive = Path.Combine(recoveryDirectory, "ssclash-" + id + ".tar.gz");
            await using (var file = new FileStream(localArchive, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
            {
                await file.WriteAsync(bytes, ct);
                file.Flush(true);
            }
            Check(identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
            var removed = await RunTextAsync(Command("commit", hash), script, 120, ct);
            Check(removed == "SSCLASH_REMOVED archive=" + remoteArchive, "Удаление SSClash не подтверждено.");
            return new SsclashRemovalResult(localArchive, remoteArchive, hash);
        }, ct, measuredAgentPlatform: true);
}
