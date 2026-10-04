using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Features;

public sealed record VpnProfile(string Id, string Name, string Transport, bool Active);
public sealed record VpnStatus(
    bool Installed, bool HelperReady, bool AgentReady, bool DashboardReady, bool LauncherReady,
    bool Configured, bool Enabled, bool CoreRunning, string Version, string Ssid,
    string? DesiredSsid, string? PasswordMode, bool SettingsSupported,
    IReadOnlyList<VpnProfile> Profiles, string ActiveProfile, string? Detail = null);

public enum VpnPasswordMode { Main, Custom, Preserve }

public sealed partial class DeviceFeatureService
{
    private const string VpnRoot = "/data/zte-vpn";
    private const string VpnHelperHash = "a388d8fa771b3e4bb46d500202ff750df410b4e6608d0f4902288b6aad16d731";
    private const string LegacyPublicVpnHelperHash = "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4";
    private const string LegacyPagesVpnHelperHash = "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca";
    private const string LegacyDirectRadioVpnHelperHash = "cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0";
    private const string LegacyRadioVpnHelperHash = "9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce";
    // Controller pinned in the preserved 2.7.0-esim.8 build receipt. Read status only.
    private const string LegacyRecoveryVpnHelperHash = "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231";
    private const string VpnAgentHash = AgentPackage.Sha256;
    private const string DashboardHash = "4dca88160448846cef4def4b182f72f6e26ba0a6ba18402471df21424d6ca8fe";
    private const string LauncherHash = "fc550f785beca647b46a2fda06aa36731de4975986dd4765c2733f8b6a9c6762";
    private static readonly string[] VpnInstallNames = ["install.sh", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "vpnctl", "mihomo"];
    private static readonly string[] VpnIntegrationNames = ["upgrade-controller.sh", "vpnctl", "manager.sh", "configure.lua", "update-agent.sh", "dashboard-install.sh", "payload.sha256", "dashboard.tar.gz", "dashboard-uhttpd", "start-dashboard.sh", "dashboard-html.sh", "preserve-dashboard-assets.sh", "stop-owned-listener.sh", "update-rc-local.sh", "launcher.so", "launcher-run.sh", "launcher-watch.sh", "launcher-service.sh", "launcher-start.sh", "launcher.sha256", "install-launcher.sh"];
    private static bool CanReadVpnStatus(string hash) => hash is VpnHelperHash or LegacyRadioVpnHelperHash or
        LegacyDirectRadioVpnHelperHash or LegacyPagesVpnHelperHash or LegacyPublicVpnHelperHash or LegacyRecoveryVpnHelperHash;
    // Literal errors from the pinned controller; an arbitrary JSON string is not a log message.
    private static string VpnErrorCode(JsonElement reply) => StringProperty(reply, "code") switch
    {
        "VPN_ACTIVE_PROFILE_DELETE" or "VPN_AUDIT_FAILED" or "VPN_BRIDGE_NOT_READY" or "VPN_BUSY" or
        "VPN_CONFIGURATION_PENDING" or "VPN_CONFLICTING_OPTION" or "VPN_CORE_INTEGRITY" or "VPN_CORE_NOT_READY" or
        "VPN_DEVICE_CHANGED" or "VPN_DUPLICATE_OPTION" or "VPN_FILE_UNAVAILABLE" or "VPN_GUEST_IN_USE" or
        "VPN_INTEGRITY" or "VPN_INVALID_EXTRA" or "VPN_INVALID_KEY" or "VPN_INVALID_NAME" or "VPN_INVALID_PATH" or
        "VPN_INVALID_PORT" or "VPN_INVALID_PROFILE_ID" or "VPN_INVALID_REQUEST" or "VPN_INVALID_SERVER" or
        "VPN_INVALID_STATE" or "VPN_INVALID_URI" or "VPN_INVALID_UUID" or "VPN_INVALID_WIFI_PASSWORD" or
        "VPN_INVALID_WIFI_SETTINGS" or "VPN_INVALID_WIFI_SSID" or "VPN_IPA_ENABLED" or "VPN_LAUNCHER_NOT_INSTALLED" or
        "VPN_LAUNCHER_NOT_READY" or "VPN_LAUNCHER_PAGE_CONFIG_INVALID" or "VPN_LAUNCHER_PAGE_NOT_INSTALLED" or
        "VPN_MESH_CONFLICT" or "VPN_NETWORK_INIT_CHANGED" or "VPN_NOT_INSTALLED" or "VPN_NO_ACTIVE_PROFILE" or
        "VPN_OPERATION_FAILED" or "VPN_OPERATION_TIMEOUT" or "VPN_OTHER_PROXY" or "VPN_OTHER_TRANSACTION" or
        "VPN_PENDING_CHANGES" or "VPN_PROFILE_EXISTS" or "VPN_PROFILE_LIMIT" or "VPN_PROFILE_TOO_LARGE" or
        "VPN_ROOT_REQUIRED" or "VPN_ROUTE_CONFLICT" or "VPN_SPX_PRESERVED" or "VPN_SUBNET_CONFLICT" or
        "VPN_UNSAFE_FILE" or "VPN_UNSUPPORTED_ENCRYPTION" or "VPN_UNSUPPORTED_FIRMWARE" or "VPN_UNSUPPORTED_OPTION" or
        "VPN_UNSUPPORTED_SECURITY" or "VPN_UNSUPPORTED_TRANSPORT" or "VPN_VALIDATION_FAILED" or "VPN_VLESS_ONLY" or
        "VPN_WIFI_CONFIGURATION_CHANGED" or "VPN_WIFI_NOT_CONFIGURED" or "VPN_WIFI_NOT_READY" or
        "VPN_WIFI_SETTINGS_ENABLED" or "VPN_WIFI_SETTINGS_PENDING" or "VPN_WRITE_FAILED" => StringProperty(reply, "code")!,
        _ => "VPN_CONTROLLER_FAILED"
    };
    private static bool RequiredVpnBool(JsonElement value, string key)
    {
        Check(value.TryGetProperty(key, out var item) && item.ValueKind is JsonValueKind.True or JsonValueKind.False,
            "Некорректное состояние VPN (VPN_REPLY_INVALID).");
        return item.GetBoolean();
    }
    private static string RejectedVpnCode(byte[] output)
    {
        if (output.Length > 262144) return "VPN_CONTROLLER_FAILED";
        try
        {
            using var document = JsonDocument.Parse(output);
            var root = document.RootElement;
            return root.ValueKind == JsonValueKind.Object && root.TryGetProperty("ok", out var ok) &&
                ok.ValueKind == JsonValueKind.False ? VpnErrorCode(root) : "VPN_CONTROLLER_FAILED";
        }
        catch (JsonException) { return "VPN_CONTROLLER_FAILED"; }
    }

    public async Task<VpnStatus> GetVpnStatusAsync(CancellationToken ct = default)
    {
        var probe = await RunTextAsync("set -eu; if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo PRESENT; else echo ABSENT; fi; for f in /data/zte-vpn/vpnctl /data/zte-agent /data/zte-dashboard-runtime/current/index.html /data/zte-launcher/launcher.so; do if test -f \"$f\" && test ! -L \"$f\"; then sha256sum \"$f\" | cut -d ' ' -f1; else echo missing; fi; done", ct: ct);
        var parts = probe.Split('\n', StringSplitOptions.TrimEntries);
        Check(parts.Length == 5 && (parts[0] == "PRESENT" || parts[0] == "ABSENT"), "Некорректный ответ проверки VPN.");
        var installed = parts[0] == "PRESENT";
        var helper = installed && parts[1] == VpnHelperHash;
        var agent = AgentPackage.SupportsVpn(parts[2]);
        var dashboard = parts[3] == DashboardHash;
        var launcher = parts[4] == LauncherHash;
        var readableHelper = installed && CanReadVpnStatus(parts[1]);
        if (!readableHelper)
            return new VpnStatus(installed, false, agent, dashboard, launcher, false, false, false, "", "", null, null, false, [], "", installed ? "Компоненты VPN требуют обновления или проверки целостности." : null);
        var json = await VpnRequestAsync(new { action = "status" }, ct, parts[1]);
        Check(json.TryGetProperty("schema_version", out var schema) && schema.ValueKind == JsonValueKind.Number &&
            schema.TryGetInt32(out var schemaVersion) && schemaVersion == 1, "Неизвестный формат VPN (VPN_REPLY_INVALID).");
        var configured = RequiredVpnBool(json, "configured");
        var enabled = RequiredVpnBool(json, "enabled");
        var coreRunning = RequiredVpnBool(json, "core_running");
        var settingsSupported = json.TryGetProperty("settings_supported", out _) && RequiredVpnBool(json, "settings_supported");
        Check(json.TryGetProperty("profiles", out var array) && array.ValueKind == JsonValueKind.Array,
            "Список профилей VPN повреждён (VPN_REPLY_INVALID).");
        Check(array.GetArrayLength() <= 32, "Список профилей VPN повреждён (VPN_REPLY_INVALID).");
        var profiles = new List<VpnProfile>();
        foreach (var item in array.EnumerateArray())
        {
            Check(item.ValueKind == JsonValueKind.Object, "Список профилей VPN повреждён (VPN_REPLY_INVALID).");
            profiles.Add(new VpnProfile(StringProperty(item, "id") ?? "", StringProperty(item, "name") ?? "", StringProperty(item, "transport") ?? "", RequiredVpnBool(item, "active")));
        }
        return new VpnStatus(installed, helper, agent, dashboard, launcher,
            configured, enabled, coreRunning,
            StringProperty(json, "version") ?? "", StringProperty(json, "ssid") ?? "",
            StringProperty(json, "desired_ssid"), StringProperty(json, "password_mode"),
            settingsSupported, profiles, StringProperty(json, "active_profile") ?? "", helper ? null : "Компоненты VPN требуют обновления; сохранённое состояние прочитано.");
    }

    private async Task<JsonElement> VpnRequestAsync(object request, CancellationToken ct, string? statusHelperHash = null)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(request);
        Check(body.Length <= 65536, "Запрос VPN превышает допустимый размер.");
        var expectedHelperHash = VpnHelperHash;
        if (statusHelperHash is not null)
        {
            var value = JsonSerializer.SerializeToElement(request);
            Check(StringProperty(value, "action") == "status" && CanReadVpnStatus(statusHelperHash),
                "Неподдерживаемый контроллер VPN для чтения состояния.");
            expectedHelperHash = statusHelperHash;
        }
        var command = "set -eu; fail() { printf 'VPN_GUARD_REFUSED\\n' >&2; exit 72; }; " +
            "test -d " + VpnRoot + " && test ! -L " + VpnRoot + " || fail; " +
            "test \"$(stat -c '%u:%a' " + VpnRoot + ")\" = 0:700 || fail; test -f " + VpnRoot +
            "/vpnctl && test ! -L " + VpnRoot + "/vpnctl || fail; test \"$(sha256sum " + VpnRoot +
            "/vpnctl | cut -d ' ' -f1)\" = " + Quote(expectedHelperHash) + " || fail; exec " + VpnRoot + "/vpnctl request";
        var reply = await _shell.RunAsync(command, body, TimeSpan.FromSeconds(240), ct);
        // Classify command failure first; only allowlisted structured refusal codes may reach the UI.
        if (!reply.Success)
        {
            if (reply.ExitCode == 72 && Text(reply.Stderr) == "VPN_GUARD_REFUSED")
                throw new DeviceFeatureException("Проверка каталога или контроллера VPN не пройдена. Обновите состояние (VPN_GUARD_REFUSED).");
            throw new DeviceFeatureException("Контроллер VPN не завершил запрос. Обновите состояние перед повтором (" + RejectedVpnCode(reply.Stdout) + ").");
        }
        Check(reply.Stdout.Length <= 262144, "Слишком большой ответ менеджера VPN (VPN_REPLY_INVALID).");
        try
        {
            using var document = JsonDocument.Parse(reply.Stdout);
            var root = document.RootElement;
            Check(root.ValueKind == JsonValueKind.Object, "Некорректный ответ менеджера VPN (VPN_REPLY_INVALID).");
            Check(BoolProperty(root, "ok"), "Менеджер VPN отклонил запрос. Обновите состояние (" + VpnErrorCode(root) + ").");
            Check(root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object,
                "Ответ менеджера VPN не содержит состояние (VPN_REPLY_INVALID).");
            return data.Clone();
        }
        catch (JsonException)
        {
            throw new DeviceFeatureException("Некорректный ответ менеджера VPN (VPN_REPLY_INVALID).");
        }
    }

    private async Task<VpnStatus> VpnMutationAsync(object request, CancellationToken ct)
        => await MutateAsync(async (identity, token) =>
        {
            var before = await GetVpnStatusAsync(ct);
            Check(before.HelperReady, "Сначала установите или обновите компоненты VPN.");
            var body = JsonSerializer.SerializeToElement(request);
            var map = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(body.GetRawText())!;
            if (StringProperty(body, "action") == "configure_wifi")
                map["lock_token"] = JsonSerializer.SerializeToElement(token);
            await VpnRequestAsync(map, ct);
            await VerifyIdentityAsync(identity, ct);
            return await GetVpnStatusAsync(ct);
        }, ct);

    public Task<VpnStatus> ConfigureVpnWifiAsync(string ssid, VpnPasswordMode mode, string? password = null, CancellationToken ct = default)
    {
        var length = Encoding.UTF8.GetByteCount(ssid);
        Check(length is >= 1 and <= 32 && !ssid.Any(char.IsControl), "Имя VPN Wi-Fi должно содержать от 1 до 32 байт без управляющих символов.");
        if (mode == VpnPasswordMode.Custom)
        {
            var bytes = Encoding.UTF8.GetBytes(password ?? "");
            var passphrase = bytes.Length is >= 8 and <= 63 && bytes.All(value => value is >= 32 and <= 126);
            var hex = bytes.Length == 64 && bytes.All(value => value is >= 48 and <= 57 or >= 65 and <= 70 or >= 97 and <= 102);
            Check(passphrase || hex, "Пароль Wi-Fi: 8–63 печатных ASCII или 64 шестнадцатеричных символа.");
        }
        return Configure();

        async Task<VpnStatus> Configure()
        {
            var before = await GetVpnStatusAsync(ct);
            Check(before.HelperReady && before.SettingsSupported && !before.Enabled, "Отключите VPN Wi-Fi или обновите компоненты VPN перед изменением сети.");
            Check(mode != VpnPasswordMode.Preserve || before.Configured, "Текущий пароль можно сохранить только для настроенной VPN-сети.");
            var request = new Dictionary<string, object?>
            {
                ["action"] = "configure_wifi", ["ssid"] = ssid,
                ["password_mode"] = mode.ToString().ToLowerInvariant()
            };
            if (mode == VpnPasswordMode.Custom) request["password"] = password;
            var after = await VpnMutationAsync(request, ct);
            Check(after.DesiredSsid == ssid && !after.Enabled, "Модем не подтвердил сохранение VPN Wi-Fi.");
            return after;
        }
    }

    public Task<VpnStatus> ImportVpnProfileAsync(string uri, string? name = null, CancellationToken ct = default)
    {
        Check(uri.StartsWith("vless://", StringComparison.OrdinalIgnoreCase) && Encoding.UTF8.GetByteCount(uri) <= 16384, "Требуется ссылка VLESS длиной не больше 16 КиБ.");
        if (name != null) Check(name.Length is >= 1 and <= 64 && !name.Any(char.IsControl), "Недопустимое имя VPN-профиля.");
        return VpnMutationAsync(new { action = "import", uri, name }, ct);
    }
    public Task<VpnStatus> ActivateVpnProfileAsync(string id, CancellationToken ct = default)
    {
        Check(Guid.TryParse(id, out _), "Недопустимый идентификатор VPN-профиля.");
        return VpnMutationAsync(new { action = "activate", id }, ct);
    }
    public Task<VpnStatus> DeleteVpnProfileAsync(string id, CancellationToken ct = default)
    {
        Check(Guid.TryParse(id, out _), "Недопустимый идентификатор VPN-профиля.");
        return VpnMutationAsync(new { action = "delete", id }, ct);
    }
    public Task<VpnStatus> SetVpnEnabledAsync(bool enabled, CancellationToken ct = default)
        => VpnMutationAsync(new { action = "set_enabled", enabled }, ct);

    public Task<VpnStatus> InstallVpnAsync(CancellationToken ct = default)
        => MutateAsync(async (identity, token) =>
        {
            var missing = await RunTextAsync("for c in lua nft iptables ip6tables ebtables dnsmasq ip ubus flock jsonfilter; do command -v \"$c\" >/dev/null 2>&1 || printf '%s ' \"$c\"; done; test -c /dev/net/tun || printf 'TUN'", ct: ct);
            Check(string.IsNullOrWhiteSpace(missing), "В прошивке отсутствуют необходимые компоненты VPN: " + missing);
            var present = await RunTextAsync("if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo PRESENT; else echo ABSENT; fi", ct: ct);
            Check(present is "ABSENT" or "PRESENT", "Каталог VPN требует ручной проверки.");
            if (present == "PRESENT") Check(await RunTextAsync("test -d /data/zte-vpn && test ! -L /data/zte-vpn && echo SAFE", ct: ct) == "SAFE", "Каталог VPN требует ручной проверки.");
            await UpdateVpnIntegrationAsync(identity, token, ct, async () =>
            {
                if (present != "ABSENT") return;
                var files = await LoadResourcesAsync("VPN", VpnInstallNames, ct);
                var stage = await StageAsync("zte-vpn-install", files, ct);
                var remoteFinished = false;
                try
                {
                    var result = await _shell.RunAsync(Guard(identity, token) + "sh " + Quote(stage + "/install.sh") + " " + Quote(stage), timeout: TimeSpan.FromSeconds(180), ct: ct);
                    remoteFinished = KnownInstallerExit(result.ExitCode);
                    Check(remoteFinished && result.Success && Text(result.Stdout).Contains("VPN_COMPONENTS_INSTALLED", StringComparison.Ordinal), InstallerFailure("vpn_components", result));
                }
                finally { if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
            });
            return await GetVpnStatusAsync(ct);
        }, ct);

    private async Task UpdateVpnIntegrationAsync(DeviceIdentity identity, string token, CancellationToken ct, Func<Task>? prepareVpn = null, LauncherPages? pages = null)
    {
        var installedAgent = await RunTextAsync("set -eu; test -f /data/zte-agent && test ! -L /data/zte-agent; sha256sum /data/zte-agent | cut -d ' ' -f1", ct: ct);
        Check(AgentPackage.SupportedUpgradeHashes.Contains(installedAgent), "Установлен сторонний агент. Обновление дисплея остановлено до изменения компонентов VPN; требуется проверка совместимости этого агента.");
        var files = await LoadResourcesAsync("VPN", VpnIntegrationNames, ct);
        if (pages is not null) files.Add("page-layout.conf", pages.Encode());
        var agent = await File.ReadAllBytesAsync(Path.Combine(_resourcesRoot, "Onboarding", "zte-agent"), ct);
        AgentPackage.VerifyPayload(agent);
        var manager = await ResourceAsync("AgentInstallation", "manager.sh", ct);
        Check(Sha(manager) == AgentManagerHash, "Несовместимый установщик агента.");
        files.Add("zte-agent", agent);
        var stage = await StageAsync("zte-vpn-agent", files, ct);
        var remoteFinished = true;
        try
        {
            var guard = Guard(identity, token);
            async Task<string> Step(string script, string phase, int seconds, string suffix = "")
            {
                remoteFinished = false;
                var result = await _shell.RunAsync(guard + "sh " + Quote(stage + "/" + script) + " " + Quote(stage) + suffix, timeout: TimeSpan.FromSeconds(seconds), ct: ct);
                remoteFinished = KnownInstallerExit(result.ExitCode);
                Check(remoteFinished && result.Success, InstallerFailure(phase, result));
                return Text(result.Stdout);
            }
            Check(await Step("update-agent.sh", "vpn_preflight", 60, " preflight") == "VPN_AGENT_PREFLIGHT_OK", "Установка не подтверждена: vpn_preflight; неверный ответ проверки.");
            if (prepareVpn is not null) await prepareVpn();
            await InstallBundledAgentBinaryAsync(identity, token, agent, manager, ct);
            await Step("upgrade-controller.sh", "vpn_controller", 180);
            Check(await Step("update-agent.sh", "vpn_dashboard", 240) == "VPN_AGENT_UPDATED", "Установка не подтверждена: vpn_dashboard; неверный ответ установки.");
            var output = await Step("install-launcher.sh", "vpn_launcher", 180);
            Check(output.Contains("LAUNCHER_INSTALLED", StringComparison.Ordinal), "Установка страниц модема не подтверждена.");
        }
        catch (Exception) when (!ct.IsCancellationRequested && !remoteFinished)
        {
            throw new DeviceFeatureException("Установка VPN не подтверждена: transport_unknown. Файлы установки сохранены для завершения отката; обновите состояние перед повтором.");
        }
        finally { if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
    }
}
