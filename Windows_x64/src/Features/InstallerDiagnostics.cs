using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Features;

public sealed partial class DeviceFeatureService
{
    private static bool KnownInstallerExit(int exitCode) => exitCode >= 0 && exitCode != 255;

    // Only known script error words may leave the private installation channel.
    // Never display arbitrary SSH stderr, which can include device/session data.
    private static string InstallerFailure(string phase, RemoteResult result)
    {
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
}
