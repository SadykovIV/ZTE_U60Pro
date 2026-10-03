using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

/// <summary>Local application state. Device writes are delegated to verified feature managers.</summary>
public sealed partial class WindowsModemService : IModemService
{
    private readonly string _storage = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZTE IMEI Studio");
    private readonly string _resources = Path.Combine(AppContext.BaseDirectory, "Resources");
    private readonly SemaphoreSlim _operation = new(1,1);
    private readonly List<LogEntry> _logs = [];
    private IReadOnlyDictionary<string,string>? _operationValues;
    private readonly AdbTransport _adb = new();
    private SshTransport? _ssh;
    private DeviceFeatureService? _features;
    private ImeiEngine? _imei;
    private DeviceSnapshot _snapshot = new(false,"Нет подключения");
    private string _host = "192.168.0.1";
    private int _port = 2222;
    private string? _serial;
    private string? _adbCid;
    private bool _skipFirmwareCheck;
    private string _keyPath;
    private string _knownHostsPath;
    private string KeyPath => _keyPath;
    private string KnownHostsPath => _knownHostsPath;

    public WindowsModemService()
    {
        _keyPath = Path.Combine(_storage,"SSH","id_ed25519");
        _knownHostsPath = Path.Combine(_storage,"SSH","known_hosts");
        Directory.CreateDirectory(_storage);
        var settings = Path.Combine(_storage,"connection.json");
        if (File.Exists(settings))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllBytes(settings));
                var root = doc.RootElement;
                var host = root.GetProperty("host").GetString();
                if (System.Net.IPAddress.TryParse(host,out var address) && address.AddressFamily == AddressFamily.InterNetwork) _host = host!;
                if (root.TryGetProperty("port",out var value) && value.TryGetInt32(out var port) && port is >= 1 and <= 65535) _port = port;
                if (root.TryGetProperty("key_path",out var key) && key.GetString() is { } kp && Path.IsPathFullyQualified(kp)) _keyPath = kp;
                if (root.TryGetProperty("known_hosts_path",out var hosts) && hosts.GetString() is { } hp && Path.IsPathFullyQualified(hp)) _knownHostsPath = hp;
            }
            catch { /* invalid saved settings do not grant a connection */ }
        }
    }
    private void Log(string level,string message)
    {
        lock (_logs)
        {
            _logs.Add(new LogEntry(DateTimeOffset.Now,level,message));
            if (_logs.Count > 2000) _logs.RemoveRange(0,_logs.Count-2000);
        }
    }
    public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken cancellationToken = default) => Task.FromResult(_snapshot with { AdbActivationPending = File.Exists(Path.Combine(_storage, "adb-access-pending.json")), PreparationPending = File.Exists(Path.Combine(_storage, "setup-pending.json")) });
    public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken cancellationToken = default)
    {
        lock (_logs) return Task.FromResult<IReadOnlyList<LogEntry>>(_logs.ToArray());
    }
    public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken cancellationToken = default)
    {
        var list = new List<BackupInfo>();
        var directory = Path.Combine(_storage,"Backups","IMEI");
        if (Directory.Exists(directory)) foreach (var path in Directory.EnumerateDirectories(directory))
        {
            try
            {
                var manifest = JsonSerializer.Deserialize<ImeiBackupManifest>(File.ReadAllText(Path.Combine(path,"manifest.json")));
                if (manifest is { Schema: 1 } && Guid.TryParse(manifest.Id,out _))
                    list.Add(new BackupInfo(manifest.Id, "IMEI " + string.Join(" / ",manifest.Imeis), "IMEI",manifest.Created,path,
                        new DirectoryInfo(path).EnumerateFiles().Sum(file => file.Length)));
            }
            catch { /* damaged backup never appears selectable */ }
        }
        foreach (var item in DeviceBackupManager.List(_storage))
            list.Add(new BackupInfo(item.Manifest.Id,"Бэкап данных модема", "Устройство",
                item.Manifest.CreatedAt,item.Path,item.Bytes));
        foreach (var item in SystemBackupManager.List(_storage))
            list.Add(new BackupInfo(item.Id, "Образ системы · " + item.Capture,
                "Система", item.Created, item.Path, item.Bytes));
        return Task.FromResult<IReadOnlyList<BackupInfo>>(list.OrderByDescending(x => x.CreatedAt).ToArray());
    }
    public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken cancellationToken = default)
        => ListApplicationsCoreAsync(cancellationToken);

    private static LauncherPages ParseLauncherPages(string value)
    {
        var pages = new LauncherPages(value.Length == 0 ? [] : value.Split(','));
        _ = pages.Encode();
        return pages;
    }

    private static string Param(IReadOnlyDictionary<string,string>? values,string name,string fallback="")
        => values?.TryGetValue(name,out var value) == true ? value.Trim() : fallback;
    private void RequireSsh()
    {
        if (_ssh is null || _features is null || _imei is null) throw new InvalidOperationException("Для этого действия сначала подключитесь к модему по SSH.");
    }
    public async Task<OperationResult> RunAsync(OperationRequest request,CancellationToken cancellationToken = default)
    {
        if (!await _operation.WaitAsync(0,cancellationToken)) return new OperationResult(false,"Другая операция уже выполняется.");
        try
        {
            _operationValues = null;
            var p = request.Parameters;
            string result;
            switch (request.Operation)
            {
                case ModemOperation.DiscoverConnections: result = await DiscoverAsync(p,cancellationToken); break;
                case ModemOperation.Connect: result = await ConnectAsync(p,cancellationToken); break;
                case ModemOperation.PrepareSsh: result = await PrepareSshAsync(p,cancellationToken); break;
                case ModemOperation.EnableDiagnosticAdb: result = await EnableDiagnosticAdbAsync(p,cancellationToken); break;
                case ModemOperation.RefreshDevice: result = await RefreshDeviceAsync(cancellationToken); break;
                case ModemOperation.ReadImei:
                    if (_imei is not null)
                    {
                        var state = await _imei.InspectAsync(cancellationToken);
                        _snapshot = _snapshot with { Imei = string.Join(" / ",state.Imeis), Serial = state.Identity.Cid };
                        result = "Оба IMEI подтверждены по NV и API.";
                    }
                    else if (_serial is not null)
                    {
                        var imeis = new List<string>();
                        foreach (var method in new[] { "get_imei", "get_imei2" })
                        {
                            var reply = await AdbReadAsync("ubus call zwrt_zte_mdm.api " + method,cancellationToken);
                            using var doc = JsonDocument.Parse(reply.Stdout);
                            var values = doc.RootElement.EnumerateObject().Where(x => x.Value.ValueKind == JsonValueKind.String)
                                .Select(x => x.Value.GetString()).Where(ImeiCodec.IsValid).ToArray();
                            if (values.Length != 1) throw new InvalidDataException("ADB API не вернул однозначный IMEI.");
                            imeis.Add(values[0]!);
                        }
                        _snapshot = _snapshot with { Imei = string.Join(" / ",imeis) };
                        result = "IMEI прочитаны по ADB API; NV в ограниченном режиме не проверены.";
                    }
                    else throw new InvalidOperationException("Сначала подключитесь по SSH или ADB.");
                    break;
                case ModemOperation.CreateImeiBackup:
                    RequireSsh(); result = "Проверенный бэкап IMEI: " + await _imei!.CreateBackupAsync(cancellationToken); break;
                case ModemOperation.RefreshLauncher:
                    RequireSsh(); var launcher = await _features!.GetLauncherStatusAsync(cancellationToken);
                    _snapshot = _snapshot with { Launcher = launcher.State,
                        LauncherStyle = launcher.Layout?.Style,
                        LauncherMetrics = launcher.Layout is null ? null : string.Join(',', launcher.Layout.Metrics.Where(x => x.Enabled).Select(x => x.Id)),
                        LauncherMetricOrder = launcher.Layout is null ? null : string.Join(',', launcher.Layout.Metrics.Select(x => x.Id)),
                        LauncherPages = launcher.Pages is null ? null : string.Join(',', launcher.Pages.Order) };
                    result = launcher.Detail ?? launcher.State; break;
                case ModemOperation.InstallLauncher:
                case ModemOperation.InstallEsimLauncher:
                    RequireSsh(); launcher = request.Operation == ModemOperation.InstallEsimLauncher
                        ? await _features!.InstallEsimLauncherAsync(cancellationToken)
                        : p?.ContainsKey("pages") == true
                            ? await _features!.InstallLauncherPagesAsync(ParseLauncherPages(p["pages"]), cancellationToken)
                            : await _features!.InstallLauncherAsync(cancellationToken);
                    _snapshot = _snapshot with { Launcher = launcher.State,
                        LauncherStyle = launcher.Layout?.Style,
                        LauncherMetrics = launcher.Layout is null ? null : string.Join(',', launcher.Layout.Metrics.Where(x => x.Enabled).Select(x => x.Id)),
                        LauncherMetricOrder = launcher.Layout is null ? null : string.Join(',', launcher.Layout.Metrics.Select(x => x.Id)),
                        LauncherPages = launcher.Pages is null ? null : string.Join(',', launcher.Pages.Order) };
                    result = request.Operation == ModemOperation.InstallEsimLauncher ? "Страница eSIM установлена на экран модема. Профили не изменены." : launcher.Detail ?? launcher.State; break;
                case ModemOperation.ApplyLauncherPages:
                    RequireSsh();
                    if (p?.ContainsKey("pages") != true) throw new InvalidDataException("Выбор страниц не передан.");
                    launcher = await _features!.ApplyLauncherPagesAsync(ParseLauncherPages(p["pages"]), cancellationToken);
                    _snapshot = _snapshot with { Launcher = launcher.State, LauncherPages = string.Join(',', launcher.Pages!.Order) };
                    result = "Выбор и порядок страниц сохранены. Перезапуск экрана не требуется."; break;
                case ModemOperation.ApplyLauncherLayout:
                    RequireSsh();
                    var style = Param(p,"style","list").ToLowerInvariant() switch
                    {
                        "плитки" or "tiles" => "tiles",
                        "список" or "list" => "list",
                        _ => throw new InvalidDataException("Неизвестный стиль экрана модема."),
                    };
                    var metricIds = LauncherLayout.MetricIds;
                    var order = Param(p,"metric_order",_snapshot.LauncherMetricOrder ?? string.Join(',',metricIds))
                        .Split(',',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries);
                    if (order.Length != metricIds.Length ||
                        !order.ToHashSet(StringComparer.Ordinal).SetEquals(metricIds) ||
                        order.Distinct(StringComparer.Ordinal).Count() != metricIds.Length)
                        throw new InvalidDataException("Порядок показателей должен содержать все 12 пунктов ровно один раз.");
                    var selected = Param(p,"metrics","cpu,signal,network,carriers,cpu_temp,modem_temp")
                        .Split(',',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries);
                    var enabled = selected.ToHashSet(StringComparer.Ordinal);
                    if (selected.Length != enabled.Count || enabled.Count is < 1 or > 12 ||
                        !enabled.IsSubsetOf(metricIds))
                        throw new InvalidDataException("Выберите от 1 до 12 известных показателей без повторов.");
                    var layout = new LauncherLayout(style,
                        order.Select(id => new LauncherMetric(id,enabled.Contains(id))).ToArray());
                    launcher = await _features!.ApplyLauncherLayoutAsync(layout,cancellationToken);
                    _snapshot = _snapshot with { Launcher = launcher.State, LauncherStyle = style,
                        LauncherMetrics = string.Join(',', layout.Metrics.Where(x => x.Enabled).Select(x => x.Id)),
                        LauncherMetricOrder = string.Join(',', layout.Metrics.Select(x => x.Id)) };
                    result = launcher.Detail ?? launcher.State; break;
                case ModemOperation.RefreshTtl:
                    RequireSsh(); var ttl = await _features!.GetTtlStatusAsync(cancellationToken);
                    _snapshot = _snapshot with { Ttl = ttl.State }; result = ttl.Detail ?? ttl.State; break;
                case ModemOperation.ApplyTtl:
                    RequireSsh();
                    int? outbound = int.TryParse(Param(p,"outbound_ttl"),out var o) ? o : null;
                    int? inbound = int.TryParse(Param(p,"incoming_delta"),out var i) ? i : null;
                    ttl = await _features!.SetTtlAsync(outbound,inbound,cancellationToken);
                    _snapshot = _snapshot with { Ttl = ttl.State }; result = ttl.Detail ?? ttl.State; break;
                case ModemOperation.RefreshVpn:
                    RequireSsh(); var vpn = await _features!.GetVpnStatusAsync(cancellationToken);
                    _snapshot = _snapshot with { Vpn = VpnSummary(vpn), VpnPage = VpnPage(vpn),
                        VpnSsid = vpn.Ssid, VpnPasswordMode = vpn.PasswordMode?.ToString().ToLowerInvariant() };
                    result = _snapshot.Vpn!; break;
                case ModemOperation.InstallVpn:
                    RequireSsh(); vpn = await _features!.InstallVpnAsync(cancellationToken);
                    _snapshot = _snapshot with { Vpn = VpnSummary(vpn), VpnPage = VpnPage(vpn),
                        VpnSsid = vpn.Ssid, VpnPasswordMode = vpn.PasswordMode?.ToString().ToLowerInvariant() };
                    result = _snapshot.Vpn!; break;
                case ModemOperation.SaveVpnWifi:
                    RequireSsh();
                    var ssid = Param(p,"ssid"); var mode = Param(p,"password_mode","main") switch { "custom" => VpnPasswordMode.Custom,"preserve" => VpnPasswordMode.Preserve,_ => VpnPasswordMode.Main };
                    var password = p?.GetValueOrDefault("custom_password");
                    if (mode == VpnPasswordMode.Custom && password != p?.GetValueOrDefault("confirm_password")) throw new InvalidDataException("Пароли Wi-Fi не совпадают.");
                    vpn = await _features!.ConfigureVpnWifiAsync(ssid,mode,password,cancellationToken);
                    _snapshot = _snapshot with { Vpn = VpnSummary(vpn), VpnPage = VpnPage(vpn),
                        VpnSsid = vpn.Ssid, VpnPasswordMode = vpn.PasswordMode?.ToString().ToLowerInvariant() };
                    result = "Настройки VPN Wi-Fi сохранены. Сеть остаётся выключенной."; break;
                case ModemOperation.RefreshVpnWifi:
                    RequireSsh(); vpn = await _features!.GetVpnStatusAsync(cancellationToken);
                    _snapshot = _snapshot with { Vpn = VpnSummary(vpn), VpnPage = VpnPage(vpn),
                        VpnSsid = vpn.Ssid, VpnPasswordMode = vpn.PasswordMode?.ToString().ToLowerInvariant() };
                    _operationValues = new Dictionary<string,string> { ["ssid"] = vpn.Ssid ?? "", ["password_mode"] = vpn.PasswordMode?.ToString().ToLowerInvariant() ?? "main" };
                    result = "Guest SSID: " + vpn.Ssid; break;
                case ModemOperation.RefreshApplications: result = "Приложения обновлены: " + (await ListApplicationsCoreAsync(cancellationToken)).Count; break;
                default: result = await RunExtendedAsync(request,cancellationToken); break;
            }
            Log("ok",request.Operation + ": " + result);
            return new OperationResult(true,result,Values:_operationValues);
        }
        catch (Exception error)
        {
            var message = error is OperationCanceledException ? "Операция отменена. Проверьте состояние модема перед повтором." : error.Message;
            Log("error",request.Operation + ": " + message);
            return new OperationResult(false,message);
        }
        finally { _operation.Release(); }
    }

    private async Task<string> DiscoverAsync(IReadOnlyDictionary<string,string>? parameters,CancellationToken ct)
    {
        var host = Param(parameters,"host",_host);
        if (!System.Net.IPAddress.TryParse(host,out var address) || address.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("Введите IPv4-адрес модема.");
        var status = new List<string>();
        var sshOpen = false;
        using (var tcp = new TcpClient())
        {
            try { await tcp.ConnectAsync(host,_port,ct).AsTask().WaitAsync(TimeSpan.FromSeconds(3),ct); sshOpen = true; }
            catch { status.Add("SSH: недоступен"); }
        }
        if (sshOpen)
        {
            var key = Param(parameters,"key_path",_keyPath);
            var known = Param(parameters,"known_hosts_path",_knownHostsPath);
            if (!File.Exists(key) || !File.Exists(known)) status.Add("SSH: порт доступен, требуется подготовка ключа");
            else
            {
                try
                {
                    var ssh = new SshTransport(host,_port,key,known);
                    var reply = await ssh.RunAsync("id -u",timeout:TimeSpan.FromSeconds(10),ct:ct);
                    status.Add(reply.Success && Encoding.UTF8.GetString(reply.Stdout).Trim() == "0"
                        ? "SSH: доступен, root подтверждён" : "SSH: вход не подтверждён");
                }
                catch (SshTrustException) { status.Add("SSH: ключ сервера изменился"); }
                catch (Renci.SshNet.Common.SshAuthenticationException) { status.Add("SSH: ключ пользователя не принят"); }
                catch (Exception) { status.Add("SSH: порт доступен, вход не подтверждён"); }
            }
        }
        try
        {
            var inventory = await _adb.InspectUsbAsync(ct);
            var devices = inventory.ReadyDevices;
            if (devices.Count == 1)
            {
                var probe = await _adb.ShellAsync(devices[0].Serial,"id -u",TimeSpan.FromSeconds(10),ct);
                status.Add(probe.Success && Encoding.UTF8.GetString(probe.Stdout).Trim() == "0"
                    ? "ADB: доступен, root подтверждён" : "ADB: доступен, root не подтверждён");
            }
            else status.Add(devices.Count == 0 ? "ADB: " + inventory.UnavailableReason : "ADB: несколько USB-устройств");
        }
        catch (Exception e) { status.Add("ADB: " + e.Message); }
        try
        {
            using var web = new ModemWebClient(host);
            _ = await web.ProbeAsync(ct);
            var password = parameters?.GetValueOrDefault("web_password");
            if (string.IsNullOrEmpty(password)) status.Add("Web: доступен, нужен пароль");
            else
            {
                try { await web.LoginAsync(password,ct); _ = await web.GetIdentityAsync(skipFirmwareCheck:true,ct:ct); status.Add("Web: доступен, пароль верен"); }
                catch (ModemWebException error) when (error.Kind == WebFailureKind.InvalidPassword)
                { status.Add("Web: неверный пароль"); }
            }
        }
        catch { status.Add("Web: недоступен"); }
        status.Add(await ProbeAgentAsync(host,parameters?.GetValueOrDefault("agent_password"),ct));
        return string.Join(" · ",status);
    }

    private static async Task<string> ProbeAgentAsync(string host,string? password,CancellationToken ct)
    {
        using var handler = new HttpClientHandler { UseProxy = false, UseCookies = false, AllowAutoRedirect = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(7) };
        var origin = "http://" + host + ":9090";
        try
        {
            using var health = await client.GetAsync(origin + "/api/health",ct);
            if (health.StatusCode == System.Net.HttpStatusCode.Forbidden) return "Агент: пароль не настроен";
            if (health.StatusCode != System.Net.HttpStatusCode.Unauthorized) return "Агент: сервис не распознан";
            if (health.Content.Headers.ContentLength > 64*1024) return "Агент: сервис не распознан";
            var healthBody = await health.Content.ReadAsByteArrayAsync(ct);
            if (healthBody.Length > 64*1024) return "Агент: сервис не распознан";
            using (var healthDoc = JsonDocument.Parse(healthBody))
            {
                var healthRoot = healthDoc.RootElement;
                if (healthRoot.ValueKind != JsonValueKind.Object ||
                    !healthRoot.TryGetProperty("ok",out var healthOk) || healthOk.ValueKind != JsonValueKind.False ||
                    !healthRoot.TryGetProperty("error",out var healthError) || healthError.GetString() != "unauthorized")
                    return "Агент: сервис не распознан";
            }
            if (string.IsNullOrEmpty(password)) return "Агент: доступен, нужен пароль";
            var content = JsonSerializer.SerializeToUtf8Bytes(new { password });
            using var request = new HttpRequestMessage(HttpMethod.Post,origin + "/api/auth/login") {
                Content = new ByteArrayContent(content),
            };
            request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
            using var reply = await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
            if (reply.StatusCode == System.Net.HttpStatusCode.Unauthorized) return "Агент: неверный пароль";
            if (reply.StatusCode == System.Net.HttpStatusCode.TooManyRequests) return "Агент: вход временно ограничен";
            if (reply.StatusCode != System.Net.HttpStatusCode.OK || reply.Content.Headers.ContentLength > 64*1024)
                return "Агент: вход не подтверждён";
            var body = await reply.Content.ReadAsByteArrayAsync(ct);
            if (body.Length > 64*1024) return "Агент: некорректный ответ";
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            return root.TryGetProperty("ok",out var ok) && ok.ValueKind == JsonValueKind.True &&
                root.TryGetProperty("data",out var data) && data.ValueKind == JsonValueKind.Object &&
                data.TryGetProperty("token",out var token) && token.ValueKind == JsonValueKind.String &&
                !string.IsNullOrEmpty(token.GetString()) ? "Агент: доступен, пароль верен" : "Агент: вход не подтверждён";
        }
        catch (Exception) when (!ct.IsCancellationRequested) { return "Агент: недоступен"; }
    }
    private async Task<string> ConnectAsync(IReadOnlyDictionary<string,string>? values,CancellationToken ct)
    {
        var host = Param(values,"host",_host);
        if (!System.Net.IPAddress.TryParse(host,out var address) || address.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("Введите IPv4-адрес модема.");
        _host = host;
        if (!string.IsNullOrWhiteSpace(Param(values,"key_path"))) _keyPath = Param(values,"key_path");
        if (!string.IsNullOrWhiteSpace(Param(values,"known_hosts_path"))) _knownHostsPath = Param(values,"known_hosts_path");
        _skipFirmwareCheck = Param(values,"skip_firmware_check").Equals("true",StringComparison.OrdinalIgnoreCase);
        // The application's working channel is SSH. USB ADB remains available
        // independently for preparation and read-only firmware research.
        _ssh = null; _imei = null; _features = null; _serial = null; _adbCid = null;
        _snapshot = new DeviceSnapshot(false, "SSH не подключён; проверьте доступ или выполните предварительную подготовку.", IpAddress: host);
        var ssh = new SshTransport(host,_port,KeyPath,KnownHostsPath);
        var imei = new ImeiEngine(ssh,_storage,_resources);
        var identity = await imei.MeasuredIdentityAsync(ct);
        _ssh = ssh; _imei = imei; _features = new DeviceFeatureService(ssh,_resources,_storage); _serial = null; _adbCid = null;
        var supported = identity.FirmwareHash == ImeiEngine.FirmwareHash && identity.RouterHash == ImeiEngine.RouterHash;
        _snapshot = new DeviceSnapshot(true,supported ? "Подключено по SSH" : "Подключено по SSH · доступ подтверждён; функции проверяются отдельно",
            IpAddress:host,ConnectionMode:"SSH",Serial:identity.Cid);
        await HydrateConnectedAsync(supported && Param(values,"access_only")!="true",ct);
        await File.WriteAllTextAsync(Path.Combine(_storage,"connection.json"),JsonSerializer.Serialize(new { host, port = _port, key_path = _keyPath, known_hosts_path = _knownHostsPath }),ct);
        return supported ? "SSH подключён; CID и прошивка проверены." :
            "SSH подключён: root и устройство подтверждены. Установка доступа проверяется отдельно; IMEI и компоненты этой прошивки не разрешены автоматически.";
    }
    private async Task<string> RefreshDeviceAsync(CancellationToken ct)
    {
        RemoteResult info;
        if (_ssh is not null) info = await _ssh.RunAsync("ubus call system board",timeout:TimeSpan.FromSeconds(20),ct:ct);
        else if (_serial is not null) info = await AdbReadAsync("ubus call system board",ct);
        else throw new InvalidOperationException("Сначала подключитесь к модему.");
        if (!info.Success) throw new IOException("Не удалось прочитать сведения о модеме.");
        using var doc = JsonDocument.Parse(info.Stdout);
        var root = doc.RootElement;
        string? property(string name) => root.TryGetProperty(name,out var value) ? value.ToString() : null;
        string? release = root.TryGetProperty("release",out var r) && r.ValueKind == JsonValueKind.Object &&
            r.TryGetProperty("description",out var d) ? d.GetString() : property("release");
        _snapshot = _snapshot with { Model = property("model"), Firmware = release,
            Details = new Dictionary<string,string> { ["Система"] = property("system") ?? "", ["Ядро"] = property("kernel") ?? "", ["Версия"] = property("version") ?? "" } };
        return "Сведения о модеме обновлены.";
    }

    private async Task<RemoteResult> AdbReadAsync(string command,CancellationToken ct)
    {
        if (_serial is null || _adbCid is null) throw new InvalidOperationException("ADB не подключён.");
        var proof = await _adb.ShellAsync(_serial,"set -eu; test \"$(id -u)\" = 0; cat /sys/block/mmcblk0/device/cid",
            TimeSpan.FromSeconds(15),ct);
        if (!proof.Success || Encoding.UTF8.GetString(proof.Stdout).Trim().ToLowerInvariant() != _adbCid)
            throw new InvalidDataException("Устройство ADB изменилось или root утрачен.");
        var reply = await _adb.ShellAsync(_serial,command,TimeSpan.FromSeconds(20),ct);
        if (!reply.Success) throw new IOException("ADB-команда чтения завершилась с кодом " + reply.ExitCode + ".");
        return reply;
    }

    private async Task HydrateConnectedAsync(bool supported,CancellationToken ct)
    {
        async Task Try(string name,Func<Task> work)
        {
            try { await work(); }
            catch (Exception error) when (!ct.IsCancellationRequested) { Log("warning",name + ": " + error.GetType().Name); }
        }
        await Try("Сведения",async () => { _ = await RefreshDeviceAsync(ct); });
        if (!supported) return;
        await Try("IMEI",async () => {
            var state = await _imei!.InspectAsync(ct);
            _snapshot = _snapshot with { Imei = string.Join(" / ",state.Imeis) };
        });
        await Try("Агент",async () => {
            var status = await _features!.GetAgentStatusAsync(ct);
            _snapshot = _snapshot with { Agent = DescribeAgent(status) };
        });
        await Try("Launcher",async () => {
            var status = await _features!.GetLauncherStatusAsync(ct);
            _snapshot = _snapshot with { Launcher = status.State,
                LauncherStyle = status.Layout?.Style,
                LauncherMetrics = status.Layout is null ? null : string.Join(',', status.Layout.Metrics.Where(x => x.Enabled).Select(x => x.Id)),
                LauncherMetricOrder = status.Layout is null ? null : string.Join(',', status.Layout.Metrics.Select(x => x.Id)),
                LauncherPages = status.Pages is null ? null : string.Join(',', status.Pages.Order) };
        });
        await Try("TTL",async () => {
            var status = await _features!.GetTtlStatusAsync(ct);
            _snapshot = _snapshot with { Ttl = status.State };
        });
        await Try("VPN",async () => {
            var status = await _features!.GetVpnStatusAsync(ct);
            _snapshot = _snapshot with { Vpn = VpnSummary(status), VpnPage = VpnPage(status),
                VpnSsid = status.Ssid, VpnPasswordMode = status.PasswordMode?.ToString().ToLowerInvariant() };
        });
    }

    private static string VpnSummary(VpnStatus status) => status.Installed
        ? status.Enabled ? "Установлен · включён" : "Установлен · выключен"
        : "Не установлен";

    private static VpnPageSnapshot VpnPage(VpnStatus status)
    {
        var active = status.Profiles.FirstOrDefault(profile =>
            profile.Active || (status.ActiveProfile.Length > 0 && profile.Id == status.ActiveProfile))?.Name;
        return new VpnPageSnapshot(status.Installed,
            status.HelperReady && status.AgentReady && status.DashboardReady && status.LauncherReady,
            status.Configured, status.Enabled,
            status.CoreRunning, status.Ssid, status.Profiles.Select(profile => profile.Name).ToArray(), active);
    }
    private async Task<IReadOnlyList<ModemAppInfo>> ListApplicationsCoreAsync(CancellationToken ct)
    {
        if (_features is null) return [];
        return await ListApplicationsExtendedAsync(ct);
    }
    private partial Task<IReadOnlyList<ModemAppInfo>> ListApplicationsExtendedAsync(CancellationToken ct);
    private partial Task<string> RunExtendedAsync(OperationRequest request,CancellationToken ct);
    private partial Task<string> PrepareSshAsync(IReadOnlyDictionary<string,string>? parameters,CancellationToken ct);
    public Task<ITerminalSession> OpenTerminalAsync(CancellationToken cancellationToken = default)
        => OpenTerminalCoreAsync(cancellationToken);
    private partial Task<ITerminalSession> OpenTerminalCoreAsync(CancellationToken ct);
}
