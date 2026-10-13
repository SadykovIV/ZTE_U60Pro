using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Features;

public sealed partial class DeviceFeatureService
{
    private static bool KnownInstallerExit(int exitCode) => exitCode >= 0 && exitCode != 255;

    // Only known script error words may leave the private installation channel.
    // Never display arbitrary SSH stderr, which can include device/session data.
    private static string InstallerFailure(string phase, RemoteResult result)
    {
        if (phase is "agent_install" or "agent_restore" && result.ExitCode > 0 && result.ExitCode < 255 &&
            System.Text.Encoding.UTF8.GetString(result.Stderr).Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n')
                .Contains("AGENT_ERROR AGENT_SETUP_PENDING", StringComparer.Ordinal))
            return "Подготовка агента ещё владеет его файлами. Завершите её или выберите чистую установку после заводского сброса (AGENT_SETUP_PENDING).";
        if (VpnInstallFailure(result) is { } installFailure) return installFailure;
        if (VpnUpgradeFailure(result) is { } upgradeFailure) return upgradeFailure;
        var permitted = new HashSet<string>(StringComparer.Ordinal)
        {
            "VPN_AGENT_UNSAFE_PARENT", "VPN_AGENT_BAD_STAGE", "VPN_AGENT_FILES_MISSING",
            "VPN_AGENT_HASH_MISMATCH", "VPN_AGENT_PREFLIGHT_FAILED", "VPN_AGENT_REQUIRED",
            "DASHBOARD_UNSAFE_PARENT", "DASHBOARD_LOCKED", "DASHBOARD_PREFLIGHT_FAILED"
        };
        var code = Text(result.Stderr).Split('\n', StringSplitOptions.TrimEntries).FirstOrDefault(permitted.Contains)
            ?? (KnownInstallerExit(result.ExitCode) ? "installer_failed" : "transport_unknown");
        return $"Установка не подтверждена: {phase}; код {result.ExitCode}; {code}. Обновите состояние перед повтором.";
    }

    private static string? VpnInstallFailure(RemoteResult result)
    {
        if (result.ExitCode <= 0 || result.ExitCode >= 255) return null;
        var messages = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["INVALID_STAGE"] = "Не удалось проверить путь временных файлов установки VPN.",
            ["PLATFORM"] = "Для установки VPN нужны root и ARM64.",
            ["UNSAFE_STAGE"] = "Временные файлы VPN не прошли проверку владельца и прав.",
            ["ALREADY_PRESENT"] = "Компоненты или служба VPN уже существуют. Обновите состояние и выполните обновление компонентов.",
            ["UNSUPPORTED_FIRMWARE"] = "Компоненты VPN рассчитаны на исследованные MU5250 CN B31, FLY B28 (B13) и XCBZ HK B04. Соберите данные для адаптации этой прошивки.",
            ["RUNTIME_TOOLS"] = "В прошивке отсутствует одна из необходимых команд VPN: lua, nft, iptables, ip6tables, ebtables, dnsmasq, ip, ubus, sha256sum или flock.",
            ["TUN_UNAVAILABLE"] = "Для VPN недоступно устройство /dev/net/tun.",
            ["LUA_MODULES"] = "Не удалось загрузить модули Lua uci и luci.jsonc, необходимые для настройки VPN.",
            ["NO_SPACE"] = "Для установки VPN требуется не менее 128 МиБ свободного места в /data.",
            ["PAYLOAD"] = "Файлы установки VPN отсутствуют или не прошли проверку контрольной суммы.",
            ["WRITE"] = "Не удалось записать компоненты VPN в /data. Проверьте место и доступность записи.",
            ["INTEGRITY"] = "Записанные компоненты VPN не прошли проверку целостности.",
            ["SERVICE"] = "Не удалось установить службу или автозапуск VPN. Обновите состояние и повторите обновление компонентов."
        };
        const string prefix = "VPN_INSTALL_ERROR ";
        var codes = System.Text.Encoding.UTF8.GetString(result.Stderr)
            .Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n')
            .Where(line => line.StartsWith(prefix, StringComparison.Ordinal))
            .Select(line => line[prefix.Length..]).Where(messages.ContainsKey)
            .Distinct(StringComparer.Ordinal).ToArray();
        return codes.Length == 1 ? messages[codes[0]] + " (VPN_INSTALL_" + codes[0] + ")" : null;
    }

    private static string? VpnUpgradeFailure(RemoteResult result)
    {
        if (result.ExitCode <= 0 || result.ExitCode >= 255) return null;
        var messages = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["INVALID_STAGE"] = "Не удалось проверить временные файлы обновления VPN.",
            ["UNSAFE_LAYOUT"] = "Каталоги компонентов VPN не прошли проверку владельца и прав.",
            ["PAYLOAD"] = "Компоненты обновления VPN не прошли проверку контрольных сумм.",
            ["VPN_PENDING"] = "Сначала завершите предыдущую настройку VPN.",
            ["SCREEN_BUSY"] = "Закройте временную страницу VPN на модеме и повторите обновление.",
            ["CONTROLLER_UNKNOWN"] = "Установлен неизвестный контроллер VPN. Автоматическая замена остановлена.",
            ["OLD_INTEGRITY"] = "Установленные компоненты VPN не прошли проверку целостности.",
            ["DEVICE_CHANGED"] = "Модем изменился во время обновления VPN. Проверьте подключение.",
            ["NETWORK_CHANGED"] = "Сценарий запуска сети изменён и не совпадает со штатным или сохранённым. Обновление VPN остановлено.",
            ["SERVICE_CHANGED"] = "Служба VPN изменена. Посторонний файл не заменён.",
            ["STARTUP_CHANGED"] = "Автозапуск VPN изменён. Посторонние ссылки не заменены.",
            ["STATE_UNSAFE"] = "Сохранённое состояние VPN не прошло проверку. Исходные данные сохранены.",
            ["SNAPSHOT"] = "Не удалось подтвердить резервную копию компонентов VPN.",
            ["WRITE"] = "Не удалось завершить замену компонентов VPN. Проверьте состояние перед повтором.",
            ["NEW_INTEGRITY"] = "Новые компоненты VPN не прошли проверку целостности.",
            ["VERIFY"] = "Результат обновления VPN не подтверждён. Проверьте состояние перед повтором.",
            ["RECOVERY_REQUIRED"] = "Предыдущее обновление VPN требует восстановления; его журнал сохранён.",
            ["ROLLBACK_UNKNOWN"] = "Откат компонентов VPN не подтверждён. Журнал и средства восстановления сохранены.",
        };
        const string prefix = "VPN_UPGRADE_ERROR ";
        // Match complete fixed lines. A lost connection is never a confirmed
        // script refusal, and ambiguous errors never expose child output.
        var codes = System.Text.Encoding.UTF8.GetString(result.Stderr)
            .Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n')
            .Where(line => line.StartsWith(prefix, StringComparison.Ordinal))
            .Select(line => line[prefix.Length..]).Where(messages.ContainsKey)
            .Distinct(StringComparer.Ordinal).ToArray();
        var code = codes.Contains("ROLLBACK_UNKNOWN") ? "ROLLBACK_UNKNOWN" : codes.Length == 1 ? codes[0] : null;
        return code is null ? null : messages[code] + " (VPN_UPGRADE_" + code + ")";
    }
}
