using System.Collections.Frozen;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Features;

public sealed record VpnProfile(string Id, string Name, string Transport, bool Active, string Protocol = "vless",
    string? SubscriptionId = null, bool UpdateAvailable = false, bool RemovedFromSubscription = false, IReadOnlyList<string>? Warnings = null);
public sealed record VpnSubscription(string Id, string Name, string Host, string UpdatedAt, int ProfileCount);
public sealed record VpnImportSkipped(int Index, string Code);
public sealed record VpnImportSummary(int Added, int Updated, int Removed, int Duplicates, int RetainedActive, IReadOnlyList<VpnImportSkipped> Skipped);
public sealed record VpnStatus(
    bool Installed, bool HelperReady, bool AgentReady, bool DashboardReady, bool LauncherReady,
    bool Configured, bool Enabled, bool CoreRunning, string Version, string Ssid,
    string? DesiredSsid, string? PasswordMode, bool SettingsSupported,
    IReadOnlyList<VpnProfile> Profiles, string ActiveProfile, string? Detail = null,
    IReadOnlyList<VpnSubscription>? Subscriptions = null, VpnImportSummary? LastImport = null, bool Ikev2Connected = false, string? Ikev2State = null);

public enum VpnPasswordMode { Main, Custom, Preserve }

public sealed partial class DeviceFeatureService
{
    private const string VpnRoot = "/data/zte-vpn";
    private const string VpnHelperHash = "46257e8e24397f097b3ce3e53067ad59b265803f66aeb2da6d216b05dd2e5db7";
    private const string Legacy12422VpnHelperHash = "b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a";
    private const string Legacy12421VpnHelperHash = "82a8b6655ff6cd43938ffe3735e8841599ef6116bf33079d8d203db9415ca3f2";
    private const string Legacy12420VpnHelperHash = "fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48";
    private const string Legacy12418VpnHelperHash = "b2c3fcfafeccd50fa3000ad5f8f66f1e42ff157b295cdda11dddd31571612af7";
    private const string LegacyB28VpnHelperHash = "cf15a6290316dd6832873e35972831a590d70cf0734eb93dbcd96aab87fab6f1";
    private const string LegacyB31VpnHelperHash = "f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c";
    private const string LegacyPublicVpnHelperHash = "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4";
    private const string LegacyPagesVpnHelperHash = "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca";
    private const string LegacyDirectRadioVpnHelperHash = "cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0";
    private const string LegacyRadioVpnHelperHash = "9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce";
    // Controller pinned in the preserved 2.7.0-esim.8 build receipt. Read status only.
    private const string LegacyRecoveryVpnHelperHash = "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231";
    // Public 1.24.4 build 42 controller. It may only serve a status request.
    private const string LegacyCardStatusVpnHelperHash = "7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb";
    private const string VpnAgentHash = AgentPackage.Sha256;
    private const string DashboardHash = "66864773cfde70fdb56765923b9e90a5f05d820c9fc7b5e310dcca72e9011b58";
    private const string LauncherHash = "6e24686d0310c710c734ccc7c21469858e42a2e474f4a3c073bf1c476b460c50";
    private static readonly string[] VpnInstallNames = ["install.sh", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft", "vpnctl", "mihomo"];
    private static readonly string[] VpnUpgradeNames = ["upgrade-controller.sh", "vpnctl", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft"];
    private static readonly FrozenSet<string> SupportedVpnStatusHashes = new[]
    {
        VpnHelperHash,
        "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231",
        "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca",
        "3b572cf943d16a66dae1d62515b216eceaf77d397035320eb3c08a5db0e21fc4",
        "3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3",
        "48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4",
        "4e8b92cc5089200f3fced24130e47e0918bf8931989af034f709344a42cd5b0d",
        "572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5",
        "61ccaf5fa0361178dd6fe4a0104d964168f4f79a8453a8617a80a7403240d393",
        "7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb",
        "80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23",
        "82a8b6655ff6cd43938ffe3735e8841599ef6116bf33079d8d203db9415ca3f2",
        "8aaece533e2503c7a501497bb1bf191f37a0ffbba067e7a7ff3a4c6f9623673f",
        "8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827",
        "96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88",
        "9c2e3c21eecace7031c4029c969efdec44241f000716447df805f3020dfce95e",
        "9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce",
        "a35d788005d4150cd909f85afc667073a03febd24b50a708facf506b051c8a65",
        "b2c3fcfafeccd50fa3000ad5f8f66f1e42ff157b295cdda11dddd31571612af7",
        "b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a",
        "cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0",
        "cf15a6290316dd6832873e35972831a590d70cf0734eb93dbcd96aab87fab6f1",
        "e00749ed2a6273c95a4b0563212313c81e54928f6564fdbd8f9616d12a4df6ba",
        "f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c",
        "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4",
        "fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48",
        "ff5859edb44d83fad9723ccdc142f28ce918b02fae3da929667726d32746986c",
    }.ToFrozenSet(StringComparer.Ordinal);
    private static bool CanReadVpnStatus(string hash) => SupportedVpnStatusHashes.Contains(hash);
    // Literal errors from the pinned controller; an arbitrary JSON string is not a log message.
    private static string VpnErrorCode(JsonElement reply) => StringProperty(reply, "code") switch
    {
        "VPN_ACTIVE_PROFILE_DELETE" or "VPN_AUDIT_FAILED" or "VPN_BRIDGE_NOT_READY" or "VPN_BUSY" or
        "VPN_CONFIGURATION_PENDING" or "VPN_CONFLICTING_OPTION" or "VPN_CORE_INTEGRITY" or "VPN_CORE_NOT_READY" or "VPN_DHCP_NOT_READY" or
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
        var code when code is not null && VpnMessages.Errors.ContainsKey(code) => code,
        _ => "VPN_CONTROLLER_FAILED"
    };
    private static string VpnRequestError(string code) => VpnMessages.Errors.TryGetValue(code, out var message) ? message + " (" + code + ")" : code == "VPN_DHCP_NOT_READY"
        ? "Не запустилась служба выдачи IP-адресов VPN. Откройте «Логи и журналы»: подробности сохранены в vpn.log." + " (VPN_DHCP_NOT_READY)"
        : "Контроллер VPN не завершил запрос. Обновите состояние перед повтором (" + code + ").";
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

    internal const string VpnHelperReadinessCommand = """
vpn_ready_file() {
    test -f "$1" && test ! -L "$1" && test "$(stat -c %u:%h "$1")" = 0:1 || return 1
    vpn_ready_perm=$(stat -c %a "$1") || return 1
    test "$((0$vpn_ready_perm & 022))" = 0
}
if vpn_ready_file /etc/init.d/zte_vpn && vpn_ready_file /data/zte-vpn/service.sh &&
   cmp -s /etc/init.d/zte_vpn /data/zte-vpn/service.sh &&
   test -L /etc/rc.d/S99zte_vpn && test "$(stat -c %u /etc/rc.d/S99zte_vpn)" = 0 &&
   test "$(readlink /etc/rc.d/S99zte_vpn)" = ../init.d/zte_vpn &&
   test -L /etc/rc.d/K01zte_vpn && test "$(stat -c %u /etc/rc.d/K01zte_vpn)" = 0 &&
   test "$(readlink /etc/rc.d/K01zte_vpn)" = ../init.d/zte_vpn; then
    if test ! -e /data/zte-vpn/configured && test ! -L /data/zte-vpn/configured; then
        echo HELPER_LAYOUT_READY
    elif vpn_ready_file /data/zte-vpn/configured && vpn_ready_file /etc/init.d/network &&
         vpn_ready_file /data/zte-vpn/network-init.sha256 &&
         test "$(sha256sum /etc/init.d/network | cut -d ' ' -f1)" = "$(cat /data/zte-vpn/network-init.sha256)"; then
        echo HELPER_LAYOUT_READY
    fi
fi
true
""";

    public async Task<VpnStatus> GetVpnStatusAsync(CancellationToken ct = default)
    {
        var probe = await RunTextAsync("set -eu; if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo PRESENT; else echo ABSENT; fi; for f in /data/zte-vpn/vpnctl; do if test -f \"$f\" && test ! -L \"$f\"; then sha256sum \"$f\" | cut -d ' ' -f1; else echo missing; fi; done; " + VpnHelperReadinessCommand, ct: ct);
        var parts = probe.Split('\n', StringSplitOptions.TrimEntries);
        Check(parts.Length is 2 or 3 && (parts[0] == "PRESENT" || parts[0] == "ABSENT"), "Некорректный ответ проверки VPN.");
        var installed = parts[0] == "PRESENT";
        var helper = installed && parts[1] == VpnHelperHash && parts.Length == 3 && parts[2] == "HELPER_LAYOUT_READY";
        const bool agent = false, dashboard = false, launcher = false;
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
        Check(array.GetArrayLength() <= 1024, "Список профилей VPN повреждён (VPN_REPLY_INVALID).");
        var profiles = new List<VpnProfile>();
        foreach (var item in array.EnumerateArray())
        {
            Check(item.ValueKind == JsonValueKind.Object, "Список профилей VPN повреждён (VPN_REPLY_INVALID).");
            profiles.Add(new VpnProfile(StringProperty(item, "id") ?? "", StringProperty(item, "name") ?? "", StringProperty(item, "transport") ?? "", RequiredVpnBool(item, "active"),
                StringProperty(item, "protocol") ?? "vless", StringProperty(item, "subscription_id"),
                BoolProperty(item, "update_available"), BoolProperty(item, "removed_from_subscription"), VpnWarnings(item)));
        }
        return new VpnStatus(installed, helper, agent, dashboard, launcher,
            configured, enabled, coreRunning,
            StringProperty(json, "version") ?? "", StringProperty(json, "ssid") ?? "",
            StringProperty(json, "desired_ssid"), StringProperty(json, "password_mode"),
            settingsSupported, profiles, StringProperty(json, "active_profile") ?? "", helper ? null : "Компоненты VPN требуют обновления; сохранённое состояние прочитано.", ParseVpnSubscriptions(json), ParseVpnImportSummary(json), BoolProperty(json, "ikev2_connected"), StringProperty(json, "ikev2_state"));
    }

    private static IReadOnlyList<string> VpnWarnings(JsonElement profile)
    {
        if (!profile.TryGetProperty("warnings", out var values) || values.ValueKind != JsonValueKind.Array) return [];
        return values.EnumerateArray().Where(value => value.ValueKind == JsonValueKind.String)
            .Select(value => value.GetString()!).Where(VpnMessages.Warnings.ContainsKey).Distinct().ToArray();
    }

    private static IReadOnlyList<VpnSubscription> ParseVpnSubscriptions(JsonElement json)
    {
        if (!json.TryGetProperty("subscriptions", out var array)) return [];
        Check(array.ValueKind == JsonValueKind.Array && array.GetArrayLength() <= 1024, "Некорректный список подписок VPN.");
        return array.EnumerateArray().Select(item => new VpnSubscription(
            StringProperty(item, "id") ?? "", StringProperty(item, "name") ?? "", StringProperty(item, "host") ?? "",
            item.TryGetProperty("updated_at", out var updated) ? updated.ToString() : "",
            item.TryGetProperty("profile_count", out var count) && count.ValueKind == JsonValueKind.Number && count.TryGetInt32(out var number) && number >= 0 ? number : 0)).ToArray();
    }
    private static VpnImportSummary? ParseVpnImportSummary(JsonElement json)
    {
        if (!json.TryGetProperty("last_import", out var summary) || summary.ValueKind == JsonValueKind.Null) return null;
        Check(summary.ValueKind == JsonValueKind.Object, "Некорректный результат импорта VPN.");
        int Count(string name) => summary.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var count) && count >= 0 ? count : 0;
        var skipped = new List<VpnImportSkipped>();
        if (summary.TryGetProperty("skipped", out var items) && items.ValueKind == JsonValueKind.Array)
            foreach (var item in items.EnumerateArray())
            {
                var code = StringProperty(item, "code") ?? "VPN_UNSUPPORTED_OPTION";
                if (code.Length > 80 || !code.StartsWith("VPN_", StringComparison.Ordinal) || code.Any(c => !(c is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_'))) code = "VPN_UNSUPPORTED_OPTION";
                skipped.Add(new(item.TryGetProperty("index", out var index) && index.ValueKind == JsonValueKind.Number && index.TryGetInt32(out var n) && n >= 0 ? n : 0, code));
            }
        return new(Count("added"), Count("updated"), Count("removed"), Count("duplicates"), Count("retained_active"), skipped);
    }

    private async Task<JsonElement> VpnRequestAsync(object request, CancellationToken ct, string? statusHelperHash = null, DeviceIdentity? expectedIdentity = null)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(request);
        Check(body.Length <= 32 * 1024 * 1024, "Запрос VPN превышает допустимый размер.");
        var expectedHelperHash = VpnHelperHash;
        if (statusHelperHash is not null)
        {
            var value = JsonSerializer.SerializeToElement(request);
            Check(StringProperty(value, "action") == "status" && CanReadVpnStatus(statusHelperHash),
                "Неподдерживаемый контроллер VPN для чтения состояния.");
            expectedHelperHash = statusHelperHash;
        }
        var targetGuard = expectedIdentity is null ? "" : "test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + Quote(expectedIdentity.Cid) + "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + Quote(expectedIdentity.BootId) + "; ";
        var command = "set -eu; " + targetGuard + "fail() { printf 'VPN_GUARD_REFUSED\\n' >&2; exit 72; }; " +
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
            throw new DeviceFeatureException(VpnRequestError(RejectedVpnCode(reply.Stdout)));
        }
        Check(reply.Stdout.Length <= 2 * 1024 * 1024, "Слишком большой ответ менеджера VPN (VPN_REPLY_INVALID).");
        try
        {
            using var document = JsonDocument.Parse(reply.Stdout);
            var root = document.RootElement;
            Check(root.ValueKind == JsonValueKind.Object, "Некорректный ответ менеджера VPN (VPN_REPLY_INVALID).");
            Check(BoolProperty(root, "ok"), VpnRequestError(VpnErrorCode(root)));
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
        }, ct, measuredAgentPlatform: true);

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

    // The helper takes the shared modem lock. Holding it in MutateAsync as
    // well would make import/activate/delete/rename/toggle fail with VPN_BUSY.
    private async Task<VpnStatus> VpnProfileMutationAsync(object request, Func<VpnStatus,VpnStatus,bool> confirmed, CancellationToken ct, DeviceIdentity? expectedIdentity = null)
    {
        await OperationGate.WaitAsync(ct);
        try
        {
            Directory.CreateDirectory(_storageRoot);
            using var local = new FileStream(Path.Combine(_storageRoot, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            CheckLocalPending();
            var identity = await ReadIdentityAsync(ct: ct);
            if (expectedIdentity is not null) Check(identity == expectedIdentity, "Устройство изменилось во время загрузки подписки (VPN_DEVICE_CHANGED).");
            var before = await GetVpnStatusAsync(ct);
            Check(before.HelperReady, "Сначала установите или обновите компоненты VPN.");
            var reply = await VpnRequestAsync(request, ct, expectedIdentity: identity);
            var after = await GetVpnStatusAsync(ct);
            after = after with { LastImport = ParseVpnImportSummary(reply) ?? after.LastImport };
            await VerifyIdentityAsync(identity, ct);
            Check(confirmed(before, after), "Модем не подтвердил изменение VPN. Обновите состояние перед повтором.");
            return after;
        }
        finally { OperationGate.Release(); }
    }

    internal static string ValidateVpnUri(string uri)
    {
        uri = uri.Trim();
        Check((uri.StartsWith("vless://", StringComparison.Ordinal) || uri.StartsWith("hy2://", StringComparison.Ordinal) || uri.StartsWith("hysteria2://", StringComparison.Ordinal)) && Encoding.UTF8.GetByteCount(uri) <= 32768 && !uri.Any(char.IsControl), "Нужна ссылка VLESS или Hysteria2 длиной не больше 32 КиБ.");
        return uri;
    }
    private static string ValidateVpnProfileName(string name)
    {
        name = name.Trim();
        Check(name.EnumerateRunes().Count() is >= 1 and <= 64 && !name.Any(char.IsControl), "Название должно содержать от 1 до 64 символов без переносов строк.");
        return name;
    }
    private static void ValidateVpnProfileId(string id)
        => Check(id.Length == 36 && Guid.TryParseExact(id, "D", out _), "Недопустимый идентификатор VPN-профиля.");

    public Task<VpnStatus> ImportVpnProfileAsync(string uri, string? name = null, CancellationToken ct = default)
    {
        uri = ValidateVpnUri(uri);
        name = string.IsNullOrWhiteSpace(name) ? null : ValidateVpnProfileName(name);
        return VpnProfileMutationAsync(new { action = "import", uri, name }, (before, after) =>
            after.Profiles.Count == before.Profiles.Count + 1 && after.Profiles.Count(profile => !before.Profiles.Any(old => old.Id == profile.Id)) == 1, ct);
    }
    internal static bool IsVpnConfig(string input) => input.TrimStart('\uFEFF').Split('\n').Select(line => line.Split('#')[0].Trim()).FirstOrDefault(line => line.Length != 0)?.Equals("[Interface]", StringComparison.OrdinalIgnoreCase) == true;
    public Task<VpnStatus> ImportVpnConfigAsync(string config, string? name = null, CancellationToken ct = default)
    {
        Check(Encoding.UTF8.GetByteCount(config) <= 32768 && IsVpnConfig(config), "Нужен конфигурационный файл WireGuard или AmneziaWG не больше 32 КиБ.");
        name = string.IsNullOrWhiteSpace(name) ? null : ValidateVpnProfileName(name);
        return VpnProfileMutationAsync(new { action = "import_config", config, name }, (before, after) => after.Profiles.Count == before.Profiles.Count + 1, ct);
    }
    public async Task<VpnStatus> ImportVpnSubscriptionAsync(string url, string? name = null, CancellationToken ct = default)
    {
        _ = VpnSubscriptionClient.Validate(url);
        name = string.IsNullOrWhiteSpace(name) ? null : ValidateVpnProfileName(name);
        var documents = await VpnSubscriptionClient.FetchAsync(url, ct);
        return await VpnProfileMutationAsync(new { action = "subscription_import", url, name, documents },
            (before, after) => after.LastImport is not null, ct);
    }
    public async Task<VpnStatus> UpdateVpnSubscriptionAsync(string id, CancellationToken ct = default)
    {
        ValidateVpnProfileId(id);
        // The URL is read only into private memory and is never returned in status or journal.
        var identity = await ReadIdentityAsync(ct: ct);
        var details = await VpnRequestAsync(new { action = "subscription_details", id }, ct, expectedIdentity: identity);
        Check(details.TryGetProperty("subscription", out var subscription) && StringProperty(subscription, "id") == id,
            "Модем не подтвердил подписку VPN.");
        var url = StringProperty(subscription, "url") ?? "";
        var documents = await VpnSubscriptionClient.FetchAsync(url, ct);
        await VerifyIdentityAsync(identity, ct);
        return await VpnProfileMutationAsync(new { action = "subscription_update", id, documents },
            (before, after) => after.LastImport is not null, ct, expectedIdentity: identity);
    }
    public Task<VpnStatus> DeleteVpnSubscriptionAsync(string id, CancellationToken ct = default)
    {
        ValidateVpnProfileId(id);
        return VpnProfileMutationAsync(new { action = "subscription_delete", id },
            (before, after) => !(after.Subscriptions ?? []).Any(s => s.Id == id), ct);
    }
    public Task<VpnStatus> ActivateVpnProfileAsync(string id, CancellationToken ct = default)
    {
        ValidateVpnProfileId(id);
        return VpnProfileMutationAsync(new { action = "activate", id }, (_, after) => after.ActiveProfile == id && after.Profiles.Any(p => p.Id == id && p.Active && !p.UpdateAvailable), ct);
    }
    public Task<VpnStatus> RenameVpnProfileAsync(string id, string name, CancellationToken ct = default)
    {
        ValidateVpnProfileId(id); name = ValidateVpnProfileName(name);
        return VpnProfileMutationAsync(new { action = "rename", id, name }, (_, after) => after.Profiles.Any(p => p.Id == id && p.Name == name), ct);
    }
    public Task<VpnStatus> DeleteVpnProfileAsync(string id, CancellationToken ct = default)
    {
        ValidateVpnProfileId(id);
        return VpnProfileMutationAsync(new { action = "delete", id }, (_, after) => after.Profiles.All(p => p.Id != id), ct);
    }
    public Task<VpnStatus> SetVpnEnabledAsync(bool enabled, CancellationToken ct = default)
        => VpnProfileMutationAsync(new { action = "set_enabled", enabled }, (_, after) => after.Enabled == enabled, ct);

    public Task<VpnStatus> InstallVpnAsync(CancellationToken ct = default)
        => MutateAsync(async (identity, token) =>
        {
            var missing = await RunTextAsync("for c in lua nft iptables ip6tables ebtables dnsmasq ip ubus flock jsonfilter; do command -v \"$c\" >/dev/null 2>&1 || printf '%s ' \"$c\"; done; test -c /dev/net/tun || printf 'TUN'", ct: ct);
            Check(string.IsNullOrWhiteSpace(missing), "В прошивке отсутствуют необходимые компоненты VPN: " + missing);
            var present = await RunTextAsync("if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo PRESENT; else echo ABSENT; fi", ct: ct);
            Check(present is "ABSENT" or "PRESENT", "Каталог VPN требует ручной проверки.");
            if (present == "PRESENT") Check(await RunTextAsync("test -d /data/zte-vpn && test ! -L /data/zte-vpn && echo SAFE", ct: ct) == "SAFE", "Каталог VPN требует ручной проверки.");
            var names = present == "ABSENT" ? VpnInstallNames : VpnUpgradeNames;
            var files = await LoadResourcesAsync("VPN", names, ct);
            var stage = await StageAsync(present == "ABSENT" ? "zte-vpn-install" : "zte-vpn-agent", files, ct);
            var remoteFinished = true;
            try
            {
                var script = present == "ABSENT" ? "install.sh" : "upgrade-controller.sh";
                var receipt = present == "ABSENT" ? "VPN_COMPONENTS_INSTALLED" : "VPN_CONTROLLER_UPDATED";
                remoteFinished = false;
                var result = await _shell.RunAsync(Guard(identity, token) + "sh " + Quote(stage + "/" + script) + " " + Quote(stage), timeout: TimeSpan.FromSeconds(180), ct: ct);
                remoteFinished = KnownInstallerExit(result.ExitCode);
                Check(remoteFinished && result.Success && Text(result.Stdout).Split('\n').Contains(receipt), InstallerFailure("vpn_components", result));
            }
            finally { if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
            var status = await GetVpnStatusAsync(ct);
            Check(status.Installed && status.HelperReady, "Установка компонентов VPN не подтверждена. Обновите состояние; подробности — в журнале.");
            return status;
        }, ct, measuredAgentPlatform: true);
}
