using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Features;

public sealed partial class DeviceFeatureService
{
    private const string DashboardInstallerHash = "6f88a16d63e9f71bc1fc6caa19eb479f4e8c0c4d613086b62fd70ed47560f90d";
    private static readonly string[] DashboardInstallNames = ["dashboard.sh", "dashboard.tar.gz", "dashboard-uhttpd", "start-dashboard.sh", "dashboard-html.sh", "stop-owned-listener.sh", "update-rc-local.sh", "preserve-dashboard-assets.sh", "payload.sha256"];

    // Fresh onboarding preserves an existing custom/legacy agent and does not attach a new UI to it.
    public Task<bool> InstallDashboardForCurrentAgentAsync(CancellationToken ct = default)
        => MutateAsync(async (identity, token) =>
        {
            var status = await GetAgentInstallationStatusAsync(ct);
            if (!status.IsCurrent || !status.Running || status.RecoveryPending) return false;
            await InstallBundledDashboardAsync(identity, token, await LoadBundledDashboardAsync(ct), ct);
            return true;
        }, ct, measuredAgentPlatform: true);

    private async Task<Dictionary<string, byte[]>> LoadBundledDashboardAsync(CancellationToken ct)
    {
        var files = await LoadResourcesAsync("AgentDashboardInstall", DashboardInstallNames, ct);
        Check(Sha(files["dashboard.sh"]) == DashboardInstallerHash, "Несовместимый установщик веб-панели.");
        return files;
    }

    private async Task InstallBundledDashboardAsync(DeviceIdentity identity, string token, Dictionary<string, byte[]> files, CancellationToken ct, Func<Task>? installAgent = null)
    {
        var stage = await StageAsync("zte-dashboard-stage", files, ct);
        var remoteFinished = true;
        try
        {
            var id = stage["/tmp/zte-dashboard-stage-".Length..];
            var command = Guard(identity, token) + "sh " + Quote(stage + "/dashboard.sh") + " " + Quote(stage) + " " + Quote(identity.Cid) + " " + Quote(AgentPackage.Sha256);
            Check(identity == await ReadAgentIdentityAsync(ct), "Устройство изменилось во время операции с агентом.");
            remoteFinished = false;
            var preflight = await _shell.RunAsync(command + " preflight", timeout: TimeSpan.FromSeconds(60), ct: ct);
            remoteFinished = KnownInstallerExit(preflight.ExitCode);
            Check(remoteFinished && preflight.Success && Text(preflight.Stdout) == "DASHBOARD_PREFLIGHT " + id,
                InstallerFailure("dashboard_preflight", preflight));
            // No agent is changed until the dashboard's read-only checks succeed.
            if (installAgent is not null) await installAgent();
            Check(identity == await ReadAgentIdentityAsync(ct), "Устройство изменилось во время операции с агентом.");
            remoteFinished = false;
            var result = await _shell.RunAsync(command, timeout: TimeSpan.FromSeconds(180), ct: ct);
            remoteFinished = result.ExitCode >= 0 && result.ExitCode != 255;
            Check(remoteFinished && result.Success && Text(result.Stdout) == "DASHBOARD_INSTALLED " + id,
                InstallerFailure("dashboard_install", result));
        }
        catch (Exception) when (!ct.IsCancellationRequested && !remoteFinished)
        {
            throw new DeviceFeatureException("Установка веб-панели не подтверждена: transport_unknown. Файлы установки сохранены для завершения отката; обновите состояние перед повтором.");
        }
        finally
        {
            // The remote trap can still need stop-owned-listener.sh after a lost SSH session.
            if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None);
        }
    }
}
