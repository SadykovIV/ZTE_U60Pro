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
    private const string LauncherManifestHash = "eeae2396f3fe909574146e12eee60ab38298ca039bfe373f16235e8227df8390";
    private static readonly string[] LauncherNames = ["launcher.so", "launcher-run.sh", "launcher-watch.sh", "launcher-service.sh", "launcher-start.sh", "launcher.sha256", "install-launcher.sh"];
    private static readonly HashSet<string> UiHashes = ["e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9", "16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4", "8d2ebbde880934f52195ad9595815d728f7aa4671bb0633d5a5149b09467ae90", "d6c3cd409705d5aa9c12185c84074513b159088025f005da7dbf01c51e3c3715"];
    private static readonly HashSet<string> InitHashes = ["a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35", "0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50"];

    public async Task<LauncherStatus> GetLauncherStatusAsync(CancellationToken ct = default)
    {
        var identity = await ReadAgentIdentityAsync(ct);
        return await ReadLauncherStatusAsync(identity, ct);
    }

    private async Task<LauncherStatus> ReadLauncherStatusAsync(DeviceIdentity identity, CancellationToken ct)
    {
        var status = await ReadLauncherStateAsync(identity, ct);
        Check(identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
        return status;
    }

    private async Task<LauncherStatus> ReadLauncherStateAsync(DeviceIdentity identity, CancellationToken ct)
    {
        const string probe = "set -eu; uname -m; id -u; sha256sum /usr/bin/zte_topsw_devui /etc/init.d/zte_topsw_devui | cut -d ' ' -f1; " +
            "if test -e /data/zte-launcher || test -L /data/zte-launcher; then echo present; else echo absent; fi; " +
            "if test -d /data/zte-launcher && test ! -L /data/zte-launcher; then " +
            "stat -c %u:%a /data/zte-launcher; cat /data/zte-launcher/owner 2>/dev/null || true; cat /data/zte-launcher/cid 2>/dev/null || true; " +
            "for f in launcher.so launcher.sha256; do if test -f /data/zte-launcher/$f && test ! -L /data/zte-launcher/$f; then sha256sum /data/zte-launcher/$f | cut -d ' ' -f1; else echo missing; fi; done; " +
            "if test -f /data/zte-launcher/enabled && test ! -e /data/zte-launcher/failed; then echo enabled; else echo disabled; fi; " +
            "if test ! -e /etc/init.d/zte_launcher && test ! -L /etc/init.d/zte_launcher; then echo service-missing; elif test -f /etc/init.d/zte_launcher && test ! -L /etc/init.d/zte_launcher && cmp -s /etc/init.d/zte_launcher /data/zte-launcher/launcher-service.sh; then echo service-ok; else echo service-bad; fi; " +
            "if (cd /data/zte-launcher && sha256sum -c launcher.sha256 >/dev/null 2>&1); then echo integrity-ok; else echo integrity-bad; fi; fi; " +
            "if test -e /data/zte-launcher-update || test -L /data/zte-launcher-update; then echo pending; else echo clear; fi";
        var lines = (await RunTextAsync(probe, ct: ct)).Split('\n', StringSplitOptions.TrimEntries);
        Check(lines.Length >= 6, "Неполный ответ проверки Launcher.");
        var compatible = lines[0] == "aarch64" && lines[1] == "0" && UiHashes.Contains(lines[2]) && InitHashes.Contains(lines[3]);
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
        var serviceMissing = lines[11] == "service-missing";
        var safe = lines[12] == "integrity-ok" && (serviceMissing || lines[11] == "service-ok") && lines[13] == "clear";
        if (!safe) return new LauncherStatus("failed", false, false, false, hash, null, "Файлы Launcher, служба или обновление требуют проверки.");
        var layout = await ReadLauncherLayoutAsync(ct);
        var pages = await ReadLauncherPagesAsync(ct);
        if (serviceMissing)
            return new LauncherStatus("failed", false, layout != null && pages != null, false, hash, layout,
                layout == null || pages == null ? "Настройки Launcher изменены или повреждены." :
                    "Служба запуска плиток отсутствует. Повторная установка восстановит её, сохранив раскладку.", pages);
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

    private async Task<LauncherStatus> InstallLauncherWithPagesAsync(LauncherPages? requested, bool includeEsim, CancellationToken ct)
    {
        var installed = await MutateAsync(async (identity, token) =>
        {
            var before = await ReadLauncherStatusAsync(identity, ct);
            Check(before.CanInstall && before.Layout is not null && before.Pages is not null, before.Detail ?? "Launcher не поддерживается на этом устройстве.");
            var savedLayout = before.Layout!.Encode();
            var savedPages = before.Pages!;
            var desiredPages = requested ?? (includeEsim ? savedPages.IncludeEsim() : savedPages);
            var writePages = requested is not null || !desiredPages.Order.SequenceEqual(savedPages.Order);
            var files = await LoadResourcesAsync("VPN", LauncherNames, ct);
            if (writePages) files.Add("page-layout.conf", desiredPages.Encode());
            var stage = await StageAsync("zte-vpn-agent", files, ct);
            var remoteFinished = false;
            try
            {
                var command = Guard(identity, token) + "sh " + Quote(stage + "/install-launcher.sh") + " " + Quote(stage);
                var check = await _shell.RunAsync(command + " preflight", timeout: TimeSpan.FromSeconds(60), ct: ct);
                remoteFinished = KnownInstallerExit(check.ExitCode);
                Check(remoteFinished && check.Success && Text(check.Stdout) == "LAUNCHER_PREFLIGHT_OK", InstallerFailure("launcher_preflight", check));
                if (desiredPages.Order.Contains("esim"))
                {
                    var helper = await _shell.RunAsync("set -eu; test -f /data/zte-agent && test ! -L /data/zte-agent && test -x /data/zte-agent; " +
                        "test \"$(stat -c %u /data/zte-agent)\" = 0; mode=$(stat -c %a /data/zte-agent); test \"$((0$mode & 022))\" = 0; " +
                        "sha256sum /data/zte-agent | cut -d ' ' -f1", timeout: TimeSpan.FromSeconds(15), ct: ct);
                    Check(helper.Success && Text(helper.Stdout) == AgentPackage.Sha256,
                        "Для страницы eSIM нужен актуальный компонент eSIM из комплекта агента. Установите или обновите его в разделе «Агент». Запуск постоянного агента не требуется.");
                }
                remoteFinished = false;
                var applied = await _shell.RunAsync(command, timeout: TimeSpan.FromSeconds(180), ct: ct);
                remoteFinished = KnownInstallerExit(applied.ExitCode);
                Check(remoteFinished && applied.Success && Text(applied.Stdout) == "LAUNCHER_INSTALLED", InstallerFailure("launcher_install", applied));
            }
            catch (Exception) when (!ct.IsCancellationRequested && !remoteFinished)
            {
                throw new DeviceFeatureException("Установка страниц Launcher не подтверждена: transport_unknown. Файлы установки сохранены; обновите состояние перед повтором.");
            }
            finally { if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
            var after = await GetLauncherStatusAsync(ct);
            // The watcher attaches only after the operation lock is released.
            // Validate installation here; runtime attachment is observed on refresh.
            Check(after.State == "ready" && after.Layout?.Encode().SequenceEqual(savedLayout) == true &&
                after.Pages is not null && after.Pages.Order.SequenceEqual(desiredPages.Order) &&
                after.Pages.UsesDefault == (!writePages && savedPages.UsesDefault),
                "Установка страниц Launcher или сохранение настроек дисплея не подтверждены.");
            return (Status: after, Identity: identity);
        }, ct, measuredAgentPlatform: true);
        // The remote watcher can attach now. This is a read, never another apply.
        try
        {
            Check(installed.Identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
            var current = await ReadLauncherStatusAsync(installed.Identity, ct);
            return current.Running ? current : current with { Detail = current.Detail ?? "Файлы страниц установлены. Запуск экрана пока не подтверждён; обновите состояние позже." };
        }
        catch (Exception error) when (error is DeviceFeatureException or InvalidDataException or IOException or TimeoutException or OperationCanceledException)
        {
            return installed.Status with { Running = false, CanInstall = false, CanApplyLayout = false,
                Detail = "Файлы страниц установлены, но последующая проверка запуска не завершилась. Обновите состояние перед следующей операцией." };
        }
    }

    public Task<LauncherStatus> ApplyLauncherLayoutAsync(LauncherLayout layout, CancellationToken ct = default)
    {
        var bytes = layout.Encode();
        return MutateAsync(async (identity, token) =>
        {
            var before = await ReadLauncherStatusAsync(identity, ct);
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
        }, ct, measuredAgentPlatform: true);
    }
}
