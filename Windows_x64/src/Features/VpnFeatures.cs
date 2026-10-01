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
    private const string VpnAgentHash = AgentPackage.Sha256;
    private const string DashboardHash = "4dca88160448846cef4def4b182f72f6e26ba0a6ba18402471df21424d6ca8fe";
    private const string LauncherHash = "fc550f785beca647b46a2fda06aa36731de4975986dd4765c2733f8b6a9c6762";
    private static readonly string[] VpnInstallNames = ["install.sh", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "vpnctl", "mihomo"];
    private static readonly string[] VpnIntegrationNames = ["upgrade-controller.sh", "vpnctl", "manager.sh", "configure.lua", "update-agent.sh", "dashboard-install.sh", "payload.sha256", "dashboard.tar.gz", "dashboard-uhttpd", "start-dashboard.sh", "dashboard-html.sh", "preserve-dashboard-assets.sh", "stop-owned-listener.sh", "update-rc-local.sh", "launcher.so", "launcher-run.sh", "launcher-watch.sh", "launcher-service.sh", "launcher-start.sh", "launcher.sha256", "install-launcher.sh"];

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
        var readableHelper = installed && (helper || parts[1] == LegacyRadioVpnHelperHash || parts[1] == LegacyDirectRadioVpnHelperHash || parts[1] == LegacyPagesVpnHelperHash || parts[1] == LegacyPublicVpnHelperHash);
        if (!readableHelper)
            return new VpnStatus(installed, false, agent, dashboard, launcher, false, false, false, "", "", null, null, false, [], "", installed ? "Компоненты VPN требуют обновления или проверки целостности." : null);
        var json = await VpnRequestAsync(new { action = "status" }, ct, parts[1]);
        Check(json.TryGetProperty("schema_version", out var schema) && schema.GetInt32() == 1, "Неизвестный формат VPN.");
        var profiles = new List<VpnProfile>();
        if (json.TryGetProperty("profiles", out var array) && array.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in array.EnumerateArray())
                profiles.Add(new VpnProfile(StringProperty(item, "id") ?? "", StringProperty(item, "name") ?? "", StringProperty(item, "transport") ?? "", BoolProperty(item, "active")));
        }
        Check(profiles.Count <= 32, "Список профилей VPN повреждён.");
        return new VpnStatus(installed, helper, agent, dashboard, launcher,
            BoolProperty(json, "configured"), BoolProperty(json, "enabled"), BoolProperty(json, "core_running"),
            StringProperty(json, "version") ?? "", StringProperty(json, "ssid") ?? "",
            StringProperty(json, "desired_ssid"), StringProperty(json, "password_mode"),
            BoolProperty(json, "settings_supported"), profiles, StringProperty(json, "active_profile") ?? "", helper ? null : "Компоненты VPN требуют обновления; сохранённое состояние прочитано.");
    }

    private async Task<JsonElement> VpnRequestAsync(object request, CancellationToken ct, string? statusHelperHash = null)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(request);
        Check(body.Length <= 65536, "Запрос VPN превышает допустимый размер.");
        var expectedHelperHash = VpnHelperHash;
        if (statusHelperHash is not null)
        {
            var value = JsonSerializer.SerializeToElement(request);
            Check(StringProperty(value, "action") == "status" &&
                (statusHelperHash == VpnHelperHash || statusHelperHash == LegacyRadioVpnHelperHash || statusHelperHash == LegacyDirectRadioVpnHelperHash || statusHelperHash == LegacyPagesVpnHelperHash || statusHelperHash == LegacyPublicVpnHelperHash),
                "Неподдерживаемый контроллер VPN для чтения состояния.");
            expectedHelperHash = statusHelperHash;
        }
        var command = "set -eu; test -d " + VpnRoot + " && test ! -L " + VpnRoot +
            "; test \"$(stat -c '%u:%a' " + VpnRoot + ")\" = 0:700; test -f " + VpnRoot +
            "/vpnctl && test ! -L " + VpnRoot + "/vpnctl; test \"$(sha256sum " + VpnRoot +
            "/vpnctl | cut -d ' ' -f1)\" = " + Quote(expectedHelperHash) + "; exec " + VpnRoot + "/vpnctl request";
        var output = (await RunAsync(command, body, 240, ct)).Stdout;
        Check(output.Length <= 262144, "Слишком большой ответ менеджера VPN.");
        using var document = JsonDocument.Parse(output);
        var root = document.RootElement;
        if (!BoolProperty(root, "ok"))
            throw new DeviceFeatureException("Менеджер VPN отклонил действие: " + (StringProperty(root, "code") ?? "UNKNOWN"));
        Check(root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object, "Ответ менеджера VPN не содержит состояние.");
        return data.Clone();
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
