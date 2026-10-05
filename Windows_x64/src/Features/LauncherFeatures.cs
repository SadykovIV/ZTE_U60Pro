using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Features;

public sealed record LauncherMetric(string Id, bool Enabled);
public sealed record LauncherLayout(string Style, IReadOnlyList<LauncherMetric> Metrics)
{
    public static readonly string[] MetricIds = ["cpu", "signal", "network", "carriers", "cpu_temp", "modem_temp", "memory", "storage", "uptime", "battery", "rsrq", "sinr"];
    public static LauncherLayout Default => new("list", MetricIds.Select((id, index) => new LauncherMetric(id, index < 6)).ToArray());

    public byte[] Encode()
    {
        if (Style is not ("list" or "tiles") || Metrics.Count != MetricIds.Length ||
            !Metrics.Select(value => value.Id).ToHashSet(StringComparer.Ordinal).SetEquals(MetricIds) ||
            Metrics.Count(value => value.Enabled) is < 1 or > 12)
            throw new DeviceFeatureException("Настройка дисплея должна содержать все показатели ровно по одному; включите от 1 до 12.");
        var body = "ZTE_INFO_LAYOUT_V2\nstyle=" + Style + "\n" +
                   string.Concat(Metrics.Select(value => value.Id + "=" + (value.Enabled ? "1" : "0") + "\n"));
        var data = Encoding.ASCII.GetBytes(body);
        if (data.Length > 512) throw new DeviceFeatureException("Настройка дисплея слишком велика.");
        return data;
    }

    public static LauncherLayout Decode(byte[] data)
    {
        if (data.Length is 0 or > 512 || data.Any(value => value != 10 && (value < 32 || value > 126)))
            throw new DeviceFeatureException("Повреждён формат настройки дисплея.");
        var lines = Encoding.ASCII.GetString(data).Split('\n');
        var legacy = lines[0] == "ZTE_INFO_LAYOUT_V1";
        if (!(legacy || lines[0] == "ZTE_INFO_LAYOUT_V2") || lines[^1] != "" || lines.Length != (legacy ? 11 : 15))
            throw new DeviceFeatureException("Неизвестная версия настройки дисплея.");
        var style = "list";
        var start = 1;
        if (!legacy)
        {
            var styleParts = lines[1].Split('=', 2);
            if (styleParts.Length != 2 || styleParts[0] != "style" || styleParts[1] is not ("list" or "tiles"))
                throw new DeviceFeatureException("Неизвестный стиль дисплея.");
            style = styleParts[1]; start = 2;
        }
        var metrics = new List<LauncherMetric>();
        foreach (var line in lines.Skip(start).SkipLast(1))
        {
            var pair = line.Split('=', 2);
            if (pair.Length != 2 || !MetricIds.Contains(pair[0]) || pair[1] is not ("0" or "1"))
                throw new DeviceFeatureException("Некорректный показатель дисплея.");
            metrics.Add(new LauncherMetric(pair[0], pair[1] == "1"));
        }
        if (legacy) metrics.AddRange(MetricIds.Skip(9).Select(id => new LauncherMetric(id, false)));
        var result = new LauncherLayout(style, metrics);
        _ = result.Encode();
        return result;
    }
}

public sealed record LauncherStatus(string State, bool Running, bool CanInstall, bool CanApplyLayout,
    string? InstalledHash, LauncherLayout? Layout, string? Detail = null, LauncherPages? Pages = null);

public sealed partial class DeviceFeatureService
{
    private const string LauncherRoot = "/data/zte-launcher";
    private const string LauncherManifestHash = "638952749088173eb8a90656e24a9f34ef19937bf21cd490cc332974df9d2664";
    private static readonly string[] LauncherNames = ["launcher.so", "launcher-run.sh", "launcher-watch.sh", "launcher-service.sh", "launcher-start.sh", "launcher.sha256", "install-launcher.sh"];
    private static readonly HashSet<string> UiHashes = ["e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9", "16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4"];
    private static readonly HashSet<string> InitHashes = ["a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35", "0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50"];

    public async Task<LauncherStatus> GetLauncherStatusAsync(CancellationToken ct = default)
    {
        var identity = await ReadIdentityAsync(ct: ct);
        const string probe = "set -eu; uname -m; id -u; sha256sum /usr/bin/zte_topsw_devui /etc/init.d/zte_topsw_devui | cut -d ' ' -f1; " +
            "if test -e /data/zte-launcher || test -L /data/zte-launcher; then echo present; else echo absent; fi; " +
            "if test -d /data/zte-launcher && test ! -L /data/zte-launcher; then " +
            "stat -c %u:%a /data/zte-launcher; cat /data/zte-launcher/owner 2>/dev/null || true; cat /data/zte-launcher/cid 2>/dev/null || true; " +
            "for f in launcher.so launcher.sha256; do if test -f /data/zte-launcher/$f && test ! -L /data/zte-launcher/$f; then sha256sum /data/zte-launcher/$f | cut -d ' ' -f1; else echo missing; fi; done; " +
            "if test -f /data/zte-launcher/enabled && test ! -e /data/zte-launcher/failed; then echo enabled; else echo disabled; fi; " +
            "if test -f /etc/init.d/zte_launcher && cmp -s /etc/init.d/zte_launcher /data/zte-launcher/launcher-service.sh; then echo service-ok; else echo service-bad; fi; " +
            "if (cd /data/zte-launcher && sha256sum -c launcher.sha256 >/dev/null 2>&1); then echo integrity-ok; else echo integrity-bad; fi; fi; " +
            "if test -e /data/zte-launcher-update || test -L /data/zte-launcher-update; then echo pending; else echo clear; fi";
        var lines = (await RunTextAsync(probe, ct: ct)).Split('\n', StringSplitOptions.TrimEntries);
        Check(lines.Length >= 6, "Неполный ответ проверки Launcher.");
        var compatible = identity.FirmwareHash == FirmwareHash && identity.RouterHash == RouterHash && lines[0] == "aarch64" && lines[1] == "0" && UiHashes.Contains(lines[2]) && InitHashes.Contains(lines[3]);
        if (lines[4] == "absent")
        {
            if (lines[5] == "pending") return new LauncherStatus("recovery-pending", false, false, false, null, null, "Есть незавершённая установка Launcher.");
            return new LauncherStatus(compatible ? "absent" : "unsupported", false, compatible, false, null, LauncherLayout.Default, Pages: LauncherPages.Default);
        }
        Check(lines[4] == "present" && lines.Length >= 14, "Неполный ответ установленного Launcher.");
        if (!compatible) return new LauncherStatus("unsupported", false, false, false, null, null, "Экранный интерфейс этой прошивки не поддерживается.");
        if (lines[5] != "0:700" || lines[6] != "zte-native-launcher-v1" || lines[7] != identity.Cid)
            return new LauncherStatus("failed", false, false, false, null, null, "Владелец или привязка Launcher к модему не подтверждены.");
        var hash = lines[8];
        var manifest = lines[9];
        var safe = lines[12] == "integrity-ok" && lines[11] == "service-ok" && lines[13] == "clear";
        if (!safe) return new LauncherStatus("failed", false, false, false, hash, null, "Файлы Launcher, служба или обновление требуют проверки.");
        var layout = await ReadLauncherLayoutAsync(ct);
        var pages = await ReadLauncherPagesAsync(ct);
        var current = hash == LauncherHash && manifest == LauncherManifestHash && lines[10] == "enabled";
        var running = await RunTextAsync("if test -f /tmp/zte-launcher/ready && test ! -L /tmp/zte-launcher/ready && pidof zte_topsw_devui >/dev/null 2>&1; then echo running; else echo stopped; fi", ct: ct) == "running";
        return new LauncherStatus(current ? "ready" : "outdated", running, layout != null && pages != null, current && layout != null && pages != null, hash, layout,
            layout == null || pages == null ? "Настройки Launcher изменены или повреждены." : current ? null : "Можно обновить Launcher из комплекта приложения.", pages);
    }

    private async Task<LauncherLayout?> ReadLauncherLayoutAsync(CancellationToken ct)
    {
        var output = await RunTextAsync("set -eu; f=/data/zte-launcher/info-layout.conf; if test ! -e \"$f\" && test ! -L \"$f\"; then echo missing; elif test -f \"$f\" && test ! -L \"$f\" && test \"$(stat -c %u:%a:%h \"$f\")\" = 0:600:1 && test \"$(stat -c %s \"$f\")\" -le 512; then echo data; base64 \"$f\"; else echo unsafe; fi", ct: ct);
        if (output == "missing") return LauncherLayout.Default;
        if (!output.StartsWith("data\n", StringComparison.Ordinal)) return null;
        try { return LauncherLayout.Decode(Convert.FromBase64String(output[5..].Replace("\n", "", StringComparison.Ordinal))); }
        catch { return null; }
    }

    public Task<LauncherStatus> InstallLauncherAsync(CancellationToken ct = default)
        => InstallLauncherWithPagesAsync(null, false, ct);

    public Task<LauncherStatus> InstallLauncherPagesAsync(LauncherPages pages, CancellationToken ct = default)
    {
        _ = pages.Encode();
        return InstallLauncherWithPagesAsync(pages, false, ct);
    }

    public Task<LauncherStatus> InstallEsimLauncherAsync(CancellationToken ct = default)
        => InstallLauncherWithPagesAsync(null, true, ct);

    private Task<LauncherStatus> InstallLauncherWithPagesAsync(LauncherPages? requested, bool includeEsim, CancellationToken ct)
        => MutateAsync(async (identity, token) =>
        {
            var before = await GetLauncherStatusAsync(ct);
            Check(before.CanInstall && before.Layout is not null && before.Pages is not null, before.Detail ?? "Launcher не поддерживается на этом устройстве.");
            var savedLayout = before.Layout!.Encode();
            var savedPages = before.Pages!;
            var desiredPages = requested ?? (includeEsim ? savedPages.IncludeEsim() : savedPages);
            var writePages = requested is not null || !desiredPages.Order.SequenceEqual(savedPages.Order);
            var files = await LoadResourcesAsync("VPN", LauncherNames, ct);
            if (writePages) files.Add("page-layout.conf", desiredPages.Encode());
            var dashboard = await LoadBundledDashboardAsync(ct);
            var agent = await File.ReadAllBytesAsync(Path.Combine(_resourcesRoot, "Onboarding", "zte-agent"), ct);
            AgentPackage.VerifyPayload(agent);
            var manager = await ResourceAsync("AgentInstallation", "manager.sh", ct);
            Check(Sha(manager) == AgentManagerHash, "Несовместимый установщик агента.");
            var stage = await StageAsync("zte-vpn-agent", files, ct);
            var remoteFinished = false;
            try
            {
                var command = Guard(identity, token) + "sh " + Quote(stage + "/install-launcher.sh") + " " + Quote(stage);
                var check = await _shell.RunAsync(command + " preflight", timeout: TimeSpan.FromSeconds(60), ct: ct);
                remoteFinished = KnownInstallerExit(check.ExitCode);
                Check(remoteFinished && check.Success && Text(check.Stdout) == "LAUNCHER_PREFLIGHT_OK", InstallerFailure("launcher_preflight", check));
                var vpn = await RunTextAsync("if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo present; else echo absent; fi", ct: ct);
                Check(vpn is "present" or "absent", "Каталог VPN требует ручной проверки.");
                if (vpn == "present")
                {
                    // The controller pins the launcher payload. Update it through its
                    // existing transaction while preserving VPN profiles and settings.
                    await UpdateVpnIntegrationAsync(identity, token, ct, pages: writePages ? desiredPages : null);
                }
                else
                {
                    await InstallBundledDashboardAsync(identity, token, dashboard, ct,
                        () => InstallBundledAgentBinaryAsync(identity, token, agent, manager, ct));
                    remoteFinished = false;
                    var applied = await _shell.RunAsync(command, timeout: TimeSpan.FromSeconds(180), ct: ct);
                    remoteFinished = KnownInstallerExit(applied.ExitCode);
                    Check(remoteFinished && applied.Success && Text(applied.Stdout) == "LAUNCHER_INSTALLED", InstallerFailure("launcher_install", applied));
                }
            }
            catch (Exception) when (!ct.IsCancellationRequested && !remoteFinished)
            {
                throw new DeviceFeatureException("Установка страниц Launcher не подтверждена: transport_unknown. Файлы установки сохранены; обновите состояние перед повтором.");
            }
            finally { if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
            var after = await GetLauncherStatusAsync(ct);
            // The launcher process may still be starting after a confirmed install.
            // Recheck readiness only; never repeat the installation.
            for (var attempt = 0; attempt < 5 && after.State == "ready" && !after.Running &&
                after.Layout?.Encode().SequenceEqual(savedLayout) == true; attempt++)
            {
                await Task.Delay(TimeSpan.FromSeconds(1), ct);
                after = await GetLauncherStatusAsync(ct);
            }
            Check(after.State == "ready" && after.Running && after.Layout?.Encode().SequenceEqual(savedLayout) == true &&
                after.Pages is not null && after.Pages.Order.SequenceEqual(desiredPages.Order) &&
                after.Pages.UsesDefault == (!writePages && savedPages.UsesDefault),
                "Установка страниц Launcher или сохранение настроек дисплея не подтверждены.");
            return after;
        }, ct);

    public Task<LauncherStatus> ApplyLauncherLayoutAsync(LauncherLayout layout, CancellationToken ct = default)
    {
        var bytes = layout.Encode();
        return MutateAsync(async (identity, token) =>
        {
            var before = await GetLauncherStatusAsync(ct);
            Check(before.CanApplyLayout && before.Layout != null, before.Detail ?? "Launcher не готов к настройке.");
            var stage = LauncherRoot + "/.info-layout-" + Guid.NewGuid().ToString("D");
            var path = stage + "/layout";
            var guard = Guard(identity, token) + "test -d " + LauncherRoot + " && test ! -L " + LauncherRoot + "; test \"$(stat -c %u:%a " + LauncherRoot + ")\" = 0:700; test \"$(cat " + LauncherRoot + "/owner)\" = zte-native-launcher-v1; test \"$(cat " + LauncherRoot + "/cid)\" = " + Quote(identity.Cid) + "; test \"$(sha256sum " + LauncherRoot + "/launcher.so | cut -d ' ' -f1)\" = " + Quote(LauncherHash) + "; ";
            await RunAsync(guard + "umask 077; mkdir -m 700 " + Quote(stage), ct: ct);
            try
            {
                var uploaded = await RunTextAsync(guard + "cat > " + Quote(path) + "; chmod 600 " + Quote(path) + "; sha256sum " + Quote(path), bytes, 30, ct);
                Check(uploaded.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() == Sha(bytes), "Настройка дисплея повреждена при передаче.");
                await RunAsync(guard + "f=" + Quote(LauncherRoot + "/info-layout.conf") + "; if test -e \"$f\" || test -L \"$f\"; then test -f \"$f\" && test ! -L \"$f\" && test \"$(stat -c %u:%a:%h \"$f\")\" = 0:600:1 || exit 73; fi; test \"$(sha256sum " + Quote(path) + " | cut -d ' ' -f1)\" = " + Quote(Sha(bytes)) + "; mv -f " + Quote(path) + " \"$f\"; sync", ct: ct);
            }
            finally { await CleanupStageAsync(stage, ["layout"], CancellationToken.None); }
            var after = await GetLauncherStatusAsync(ct);
            Check(after.Layout?.Encode().SequenceEqual(bytes) == true, "Модем не подтвердил настройку Launcher.");
            return after;
        }, ct);
    }
}
