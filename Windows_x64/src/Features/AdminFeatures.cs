using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Features;

public sealed record AgentInstallationStatus(string Hash, bool Running, bool StartupReady, bool RecoveryPending, string? BackupHash, string? Warning = null)
{
    public string? Version => AgentPackage.VersionForHash(Hash);
    public bool IsCurrent => Hash == AgentPackage.Sha256;
}
public sealed record ScreenLocalizationStatus(string State, string Language, int Mounted, bool BootEnabled, int Pid, string Revision, string? Reason = null);

public sealed partial class DeviceFeatureService
{
    private const string AgentManagerHash = "ba9216b75d9b6a5a003e05137416335083609f4d840a0394e6f9016d27527844";
    private const string ScreenRoot = "/data/zte-imei-screen-ru";
    private const string ScreenManagerHash = "810aae3c07c8019f2d0657f2bad6f1ee38f1dea5f1081210ab144478dd87c7b8";
    private static readonly HashSet<string> ScreenLegacyManagerHashes = ["6aed6654afb7a4fde7792a5f6034aa41e15b0fd77d794ed04d3a12c111c95fd2", "586a7727fb24a5701990c7cd82889887220c1c5566261c53ca21f3bb12549bfa"];
    private static readonly string[] ScreenFileNames = ["install.sh", "service.sh", "English.ini", "Chinese.ini", "font.patch.json"];

    public Task<AgentInstallationStatus> GetAgentInstallationStatusAsync(CancellationToken ct = default)
        => InvokeAgentAsync("status", ct);
    public Task<AgentInstallationStatus> GetAgentStatusAsync(CancellationToken ct = default)
        => GetAgentInstallationStatusAsync(ct);
    public Task<AgentInstallationStatus> InstallAgentAsync(CancellationToken ct = default)
        => InvokeAgentAsync("install", ct);
    public Task<AgentInstallationStatus> InstallCustomAgentAsync(AgentCandidate candidate, CancellationToken ct = default)
        => InvokeAgentAsync("install", ct, candidate);
    public Task<AgentInstallationStatus> RestoreAgentAsync(CancellationToken ct = default)
        => InvokeAgentAsync("restore", ct);

    private Task<AgentInstallationStatus> InvokeAgentAsync(string action, CancellationToken ct, AgentCandidate? candidate = null)
    {
        // Read and validate the selected bytes before the first remote write, and keep
        // exactly these bytes for the upload even if the local file changes later.
        var selectedBytes = candidate?.ReadValidatedBytes();
        if (action == "status") return ReadOnly();
        return MutateAsync(async (identity, token) => await Invoke(identity, token), ct, measuredAgentPlatform: candidate is not null || action == "restore");

        async Task<AgentInstallationStatus> ReadOnly()
        {
            var manager = await ResourceAsync("AgentInstallation", "manager.sh", ct);
            Check(Sha(manager) == AgentManagerHash, "Несовместимый установщик агента.");
            var session = await SshReadProof.ReadSessionAsync(_shell, ct);
            var result = await _shell.RunAsync("unset ZTE_AGENT_TEST_ROOT; sh -s -- status", manager, TimeSpan.FromSeconds(30), ct);
            Check(result.Success, AgentStatusFailure(result));
            var status = ParseAgentStatus(Text(result.Stdout));
            session.Verify(await SshReadProof.ReadSessionAsync(_shell, ct));
            return status;
        }
        async Task<AgentInstallationStatus> Invoke(DeviceIdentity identity, string? token)
        {
            var manager = await ResourceAsync("AgentInstallation", "manager.sh", ct);
            Check(Sha(manager) == AgentManagerHash, "Несовместимый установщик агента.");
            var files = new Dictionary<string, byte[]> { ["manager.sh"] = manager };
            Dictionary<string, byte[]>? dashboardFiles = null;
            if (action == "install")
            {
                var agent = selectedBytes ?? await File.ReadAllBytesAsync(Path.Combine(_resourcesRoot, "Onboarding", "zte-agent"), ct);
                if (candidate is null) AgentPackage.VerifyPayload(agent);
                files.Add("agent.bin", agent);
                if (candidate is null) dashboardFiles = await LoadBundledDashboardAsync(ct);
            }
            var stage = await StageAsync("zte-agent-stage", files, ct);
            var remoteFinished = true;
            try
            {
                var before = await AgentStatusAtStageAsync(stage, ct);
                if (action == "status") return before;
                if (token == null) throw new DeviceFeatureException("Потеряна блокировка установки агента.");
                if (action == "install")
                {
                    Check(!before.RecoveryPending && before.StartupReady && (before.Hash != "absent" || !before.Running), "Сначала выполните подготовку SSH/агента либо восстановите предыдущую версию.");
                    if (candidate is not null)
                    {
                        if (candidate.Interpreter is { } loader)
                            Check((await _shell.RunAsync("test -x " + Quote(loader), ct: ct)).Success,
                                "На модеме нет загрузчика, необходимого выбранному ELF-файлу.");
                        Check(identity == await ReadAgentIdentityAsync(ct), "Устройство изменилось во время операции с агентом.");
                        return await InstallAgentBinaryAtStageAsync(identity, token, stage, before, ct,
                            finished => remoteFinished = finished, candidate.Sha256);
                    }
                    if (before.Hash == "absent")
                    {
                        await InstallAgentBinaryAtStageAsync(identity, token, stage, before, ct, finished => remoteFinished = finished);
                        before = await AgentStatusAtStageAsync(stage, ct);
                    }
                    var vpn = await RunTextAsync("if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo present; else echo absent; fi", ct: ct);
                    Check(vpn is "present" or "absent", "Каталог VPN требует ручной проверки.");
                    if (vpn == "present")
                    {
                        // The agent pins its controller, which pins the launcher.
                        // Reuse their existing transaction under this same lock;
                        // it preserves VPN configuration and the saved page layout.
                        await UpdateVpnIntegrationAsync(identity, token, ct);
                    }
                    else
                    {
                        // Updating an agent must not install VPN on a device without it.
                        await InstallBundledDashboardAsync(identity, token, dashboardFiles!, ct,
                            () => InstallAgentBinaryAtStageAsync(identity, token, stage, before, ct, finished => remoteFinished = finished));
                    }
                    var final = await AgentStatusAtStageAsync(stage, ct);
                    Check(final.IsCurrent && final.Running && !final.RecoveryPending,
                        "Агент после установки веб-панели требует проверки.");
                    return final;
                }
                Check(action == "restore" && before.BackupHash != null, "Проверенной копии предыдущего агента нет.");
                Check(identity == await ReadAgentIdentityAsync(ct), "Устройство изменилось во время операции с агентом.");
                remoteFinished = false;
                var restore = await _shell.RunAsync(Guard(identity, token) + "sh " + Quote(stage + "/manager.sh") + " restore", timeout: TimeSpan.FromSeconds(120), ct: ct);
                remoteFinished = KnownInstallerExit(restore.ExitCode);
                Check(remoteFinished && restore.Success, InstallerFailure("agent_restore", restore));
                var restored = await AgentStatusAtStageAsync(stage, ct);
                Check(restored.Hash == before.BackupHash && restored.Running && !restored.RecoveryPending, "Восстановление агента не подтверждено.");
                return restored;
            }
            catch (Exception) when (!ct.IsCancellationRequested && !remoteFinished)
            {
                throw new DeviceFeatureException("Установка агента не подтверждена: transport_unknown. Файлы установки сохранены; обновите состояние перед повтором.");
            }
            finally { if (remoteFinished) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
        }
    }

    // Used under the existing operation/device lock by VPN integration as well.
    // It deliberately does not install a dashboard or acquire a second lock.
    private async Task InstallBundledAgentBinaryAsync(DeviceIdentity identity, string token, byte[] agent, byte[] manager, CancellationToken ct)
    {
        var files = new Dictionary<string, byte[]> { ["manager.sh"] = manager, ["agent.bin"] = agent };
        var stage = await StageAsync("zte-agent-stage", files, ct);
        var cleanup = true;
        try
        {
            var before = await AgentStatusAtStageAsync(stage, ct);
            Check(!before.RecoveryPending && before.StartupReady && (before.Hash != "absent" || !before.Running), "Сначала выполните подготовку SSH/агента либо восстановите предыдущую версию.");
            await InstallAgentBinaryAtStageAsync(identity, token, stage, before, ct, finished => cleanup = finished);
        }
        catch (Exception) when (!ct.IsCancellationRequested && !cleanup)
        {
            throw new DeviceFeatureException("Установка агента не подтверждена: transport_unknown. Файлы установки сохранены; обновите состояние перед повтором.");
        }
        finally { if (cleanup) await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
    }

    private async Task<AgentInstallationStatus> InstallAgentBinaryAtStageAsync(DeviceIdentity identity, string token, string stage, AgentInstallationStatus before, CancellationToken ct, Action<bool>? completion = null, string? candidateHash = null)
    {
        var expectedHash = candidateHash ?? VpnAgentHash;
        if (before.Hash == expectedHash && before.Running) return before;
        completion?.Invoke(false);
        var result = await _shell.RunAsync(Guard(identity, token) + "sh " + Quote(stage + "/manager.sh") + " install " + Quote(stage + "/agent.bin") + " " + Quote(expectedHash), timeout: TimeSpan.FromSeconds(120), ct: ct);
        completion?.Invoke(KnownInstallerExit(result.ExitCode));
        Check(KnownInstallerExit(result.ExitCode) && result.Success, InstallerFailure("agent_install", result));
        var after = await AgentStatusAtStageAsync(stage, ct);
        Check(after.Hash == expectedHash && after.Running && after.BackupHash == (before.Hash == "absent" ? null : before.Hash) && !after.RecoveryPending,
            "Установка агента не подтверждена; проверьте состояние восстановления.");
        return after;
    }

    private async Task<AgentInstallationStatus> AgentStatusAtStageAsync(string stage, CancellationToken ct)
    {
        var output = await RunTextAsync("set -eu; test \"$(sha256sum " + Quote(stage + "/manager.sh") + " | cut -d ' ' -f1)\" = " + Quote(AgentManagerHash) + "; sh " + Quote(stage + "/manager.sh") + " status", ct: ct);
        return ParseAgentStatus(output);
    }

    private static string AgentStatusFailure(ZteImeiStudio.Transport.RemoteResult result)
    {
        var codes = Text(result.Stderr).Split('\n').Where(line => line.StartsWith("AGENT_ERROR ", StringComparison.Ordinal))
            .Select(line => line[12..]).Distinct(StringComparer.Ordinal).ToArray();
        var code = codes.Length == 1 && codes[0] is "CID" or "OWNER" or "BINARY" or "ROOT_REQUIRED" or "UNSAFE_LAYOUT"
            ? codes[0] : "STATUS_FAILED";
        return code switch
        {
            "CID" => "Не удалось прочитать идентификатор устройства для проверки агента (AGENT_CID).",
            "OWNER" => "Каталог установщика агента не подтвердил принадлежность программе (AGENT_OWNER).",
            "BINARY" => "Файл агента не прошёл проверку типа и владельца (AGENT_BINARY).",
            "ROOT_REQUIRED" => "Для проверки этого состояния агента нужен root (AGENT_ROOT_REQUIRED).",
            "UNSAFE_LAYOUT" => "Каталоги агента не прошли проверку безопасности (AGENT_UNSAFE_LAYOUT).",
            _ => "Не удалось проверить состояние агента (AGENT_STATUS_FAILED).",
        };
    }

    private static AgentInstallationStatus ParseAgentStatus(string output)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var pair = line.Split(' ', 2);
            Check(pair.Length == 2 && values.TryAdd(pair[0], pair[1]), "Повреждён ответ проверки агента.");
        }
        Check(values.TryGetValue("AGENT_SHA", out var hash) && (hash == "absent" || Regex.IsMatch(hash, "^[0-9a-f]{64}$")), "Нет контрольной суммы установленного агента.");
        Check(values.Keys.All(key => key is "AGENT_SHA" or "AGENT_RUNNING" or "AGENT_STARTUP" or "AGENT_PENDING" or "AGENT_BACKUP" or "AGENT_WARNING") &&
              new[] { "AGENT_RUNNING", "AGENT_STARTUP", "AGENT_PENDING" }.All(key => !values.TryGetValue(key, out var flag) || flag is "yes" or "no"),
              "Повреждён ответ проверки агента.");
        Check(!values.TryGetValue("AGENT_WARNING", out var warning) || warning == "OWNER", "Повреждён ответ проверки агента.");
        string? backup = values.GetValueOrDefault("AGENT_BACKUP");
        Check(backup == null || Regex.IsMatch(backup, "^[0-9a-f]{64}$"), "Повреждён бэкап агента.");
        return new AgentInstallationStatus(hash!, values.GetValueOrDefault("AGENT_RUNNING") == "yes",
            values.GetValueOrDefault("AGENT_STARTUP") == "yes", values.GetValueOrDefault("AGENT_PENDING") == "yes", backup, warning);
    }

    public async Task<ScreenLocalizationStatus> GetScreenLocalizationStatusAsync(CancellationToken ct = default)
    {
        var session = await SshReadProof.ReadSessionAsync(_shell, ct);
        var presence = await RunTextAsync("if test -e " + ScreenRoot + " || test -L " + ScreenRoot + "; then echo present; else echo absent; fi", ct: ct);
        if (presence == "absent")
        {
            var output = await RunTextAsync("set -eu; language=$(uci -q get zwrt_deviceui.Device.device_language || true); case \"$language\" in en|cn) ;; *) language=other;; esac; " +
                "mounted=$(awk '$5==\"/usr/ui/language/English.ini\" || $5==\"/usr/ui/language/Chinese.ini\" || $5==\"/usr/bin/zte_topsw_devui\" {n++} END {print n+0}' /proc/self/mountinfo); " +
                "state=absent; if test \"$mounted\" != 0 || test -e /etc/init.d/zte_imei_screen_ru || test -L /etc/init.d/zte_imei_screen_ru || test -e /etc/rc.d/S47zte_imei_screen_ru || test -L /etc/rc.d/S47zte_imei_screen_ru || test ! -f /etc/init.d/zte_topsw_devui || test -L /etc/init.d/zte_topsw_devui || test \"$(sha256sum /etc/init.d/zte_topsw_devui 2>/dev/null | cut -d ' ' -f1)\" != a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35; then state=error; fi; " +
                "pid=$(pidof zte_topsw_devui 2>/dev/null | awk '{print $1}' || true); case \"$pid\" in ''|*[!0-9]*) pid=0;; esac; " +
                "printf 'SCREEN_RU_STATUS state=%s language=%s mounted=%s boot=0 pid=%s revision=20260924\\n' \"$state\" \"$language\" \"$mounted\" \"$pid\"", ct: ct);
            var status = ParseScreenStatus(output);
            if (status.State == "error") status = status with { Reason = await ReadScreenFailureReasonAsync(ct) };
            session.Verify(await SshReadProof.ReadSessionAsync(_shell, ct));
            return status;
        }
        Check(presence == "present", "Не удалось определить состояние русификации.");
        var installedHash = await RunTextAsync("set -eu; test -d " + ScreenRoot + " && test ! -L " + ScreenRoot + "; test -f " + ScreenRoot + "/manager.sh && test ! -L " + ScreenRoot + "/manager.sh; sha256sum " + ScreenRoot + "/manager.sh | cut -d ' ' -f1", ct: ct);
        Check(installedHash == ScreenManagerHash || ScreenLegacyManagerHashes.Contains(installedHash), "Менеджер русификации изменён.");
        var command = ScreenManagerCommand("status", null, installedHash);
        var installed = ParseScreenStatus(await RunTextAsync(command, seconds: 45, ct: ct));
        if (installed.State == "error") installed = installed with { Reason = await ReadScreenFailureReasonAsync(ct) };
        session.Verify(await SshReadProof.ReadSessionAsync(_shell, ct));
        return installed;
    }

    private static readonly HashSet<string> ScreenStatusReasons = ["STOCK_INIT_MISSING", "STOCK_INIT_CHANGED", "LEFTOVER_HOOK_OR_MOUNT", "BOOT_HOOK_MISSING", "TRANSACTION_PENDING", "UI_NOT_RUNNING", "STATUS_UNVERIFIED"];

    internal static string ScreenFailureDescription(string? reason) => reason switch {
                "STOCK_INIT_MISSING" => "Отсутствует штатный сценарий запуска экрана (SCREEN_RU_STOCK_INIT_MISSING).",
                "STOCK_INIT_CHANGED" => "Штатный сценарий запуска экрана отличается от проверенного (SCREEN_RU_STOCK_INIT_CHANGED).",
                "LEFTOVER_HOOK_OR_MOUNT" => "Обнаружены оставшиеся подключения русификации без её каталога (SCREEN_RU_LEFTOVER_HOOK_OR_MOUNT).",
                "BOOT_HOOK_MISSING" => "Отсутствует автозапуск установленной русификации (SCREEN_RU_BOOT_HOOK_MISSING).",
                "TRANSACTION_PENDING" => "Осталась незавершённая операция русификации (SCREEN_RU_TRANSACTION_PENDING).",
                "UI_NOT_RUNNING" => "Процесс штатного экрана не запущен (SCREEN_RU_UI_NOT_RUNNING).",
                _ => "Состояние русификации не подтверждено (SCREEN_RU_STATUS_UNVERIFIED).",
                };

    private async Task<string> ReadScreenFailureReasonAsync(CancellationToken ct)
    {
        const string command = """
        reason=STATUS_UNVERIFIED
        if test ! -f /etc/init.d/zte_topsw_devui || test -L /etc/init.d/zte_topsw_devui; then reason=STOCK_INIT_MISSING
        elif test ! -e /data/zte-imei-screen-ru && test ! -L /data/zte-imei-screen-ru; then
          if test "$(sha256sum /etc/init.d/zte_topsw_devui 2>/dev/null | cut -d ' ' -f1)" != a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35; then reason=STOCK_INIT_CHANGED
          elif test -e /etc/init.d/zte_imei_screen_ru || test -L /etc/init.d/zte_imei_screen_ru || test -e /etc/rc.d/S47zte_imei_screen_ru || test -L /etc/rc.d/S47zte_imei_screen_ru || awk '$5=="/usr/ui/language/English.ini" || $5=="/usr/ui/language/Chinese.ini" || $5=="/usr/bin/zte_topsw_devui" {found=1} END {exit !found}' /proc/self/mountinfo; then reason=LEFTOVER_HOOK_OR_MOUNT; fi
        elif test -d /data/zte-imei-screen-ru && test ! -L /data/zte-imei-screen-ru; then
          if test -e /data/zte-imei-screen-ru/.transaction || test -L /data/zte-imei-screen-ru/.transaction; then reason=TRANSACTION_PENDING
          elif test -e /data/zte-imei-screen-ru/.enabled && { test ! -f /etc/init.d/zte_imei_screen_ru || test ! -L /etc/rc.d/S47zte_imei_screen_ru; }; then reason=BOOT_HOOK_MISSING
          elif ! pidof zte_topsw_devui >/dev/null 2>&1; then reason=UI_NOT_RUNNING; fi
        fi
        printf '%s\n' "$reason"
        """;
        var result = await _shell.RunAsync(command, timeout: TimeSpan.FromSeconds(15), ct: ct);
        var reason = Text(result.Stdout);
        return result.Success && ScreenStatusReasons.Contains(reason) ? reason : "STATUS_UNVERIFIED";
    }

    public Task<ScreenLocalizationStatus> GetLocalizationStatusAsync(CancellationToken ct = default)
        => GetScreenLocalizationStatusAsync(ct);
    public Task<ScreenLocalizationStatus> InstallLocalizationAsync(CancellationToken ct = default)
        => InstallScreenLocalizationAsync(ct);
    public Task<ScreenLocalizationStatus> RestoreLocalizationAsync(CancellationToken ct = default)
        => RestoreScreenLocalizationAsync(ct);

    public Task<ScreenLocalizationStatus> InstallScreenLocalizationAsync(CancellationToken ct = default)
        => MutateAsync(async (identity, token) =>
        {
            var current = await GetScreenLocalizationStatusAsync(ct);
            if (current.State != "absent" && current.Revision == "20260924")
            {
                if (current.State == "enabled") return current;
                var result = ParseScreenStatus(await RunTextAsync(Guard(identity, token) + ScreenManagerCommand("enable", identity.Cid, ScreenManagerHash), seconds: 240, ct: ct));
                Check(result.State == "enabled" && result.Language == "cn" && result.Pid > 0, "Русификация не подтвердила запуск.");
                return result;
            }
            var originalCommand = current.State == "absent" ? "cat /usr/bin/zte_topsw_devui" : "cat " + ScreenRoot + "/backup/zte_topsw_devui";
            var original = (await RunAsync(originalCommand, seconds: 120, ct: ct)).Stdout;
            var files = await LoadResourcesAsync("ScreenLocalization", ScreenFileNames, ct);
            var patched = ApplyScreenFontPatch(original, files["font.patch.json"]);
            files.Add("zte_topsw_devui", patched);
            await VerifyIdentityAsync(identity, ct);
            var stage = await StageAsync("zte-screen-ru-install", files, ct);
            try
            {
                var output = await RunTextAsync(Guard(identity, token) + "sh " + Quote(stage + "/install.sh") + " install " + Quote(stage) + " " + Quote(identity.Cid), seconds: 270, ct: ct);
                var result = ParseScreenStatus(output);
                Check(result.State == "enabled" && result.Language == "cn" && result.Pid > 0, "Русификация не подтвердила запуск.");
                return result;
            }
            finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
        }, ct);

    public Task<ScreenLocalizationStatus> RestoreScreenLocalizationAsync(CancellationToken ct = default)
        => MutateAsync(async (identity, token) =>
        {
            var current = await GetScreenLocalizationStatusAsync(ct);
            if (current.State == "absent") return current;
            Check(current.State is "enabled" or "disabled", ScreenFailureDescription(current.Reason));
            var hash = current.Revision switch
            {
                "20260924" => ScreenManagerHash,
                "20260922" => "6aed6654afb7a4fde7792a5f6034aa41e15b0fd77d794ed04d3a12c111c95fd2",
                "20260923" => "586a7727fb24a5701990c7cd82889887220c1c5566261c53ca21f3bb12549bfa",
                _ => throw new DeviceFeatureException("Неизвестная версия русификации.")
            };
            var result = ParseScreenStatus(await RunTextAsync(Guard(identity, token) + ScreenManagerCommand("disable", identity.Cid, hash), seconds: 240, ct: ct));
            Check(result.State == "disabled" && result.Language == "en" && result.Pid > 0, "Штатный интерфейс не подтвердил восстановление.");
            return result;
        }, ct);

    private static string ScreenManagerCommand(string action, string? cid, string hash)
    {
        var manager = ScreenRoot + "/manager.sh";
        return "set -eu; test -d " + ScreenRoot + " && test ! -L " + ScreenRoot + "; test -f " + manager + " && test ! -L " + manager +
            "; test \"$(sha256sum " + manager + " | cut -d ' ' -f1)\" = " + Quote(hash) + "; sh " + manager + " " + Quote(action) + (cid is null ? "" : " " + Quote(cid));
    }

    private static ScreenLocalizationStatus ParseScreenStatus(string output)
    {
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Check(lines.Length == 1, "Неполный статус русификации.");
        var parts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Check(parts.Length is 7 or 8 && parts[0] == "SCREEN_RU_STATUS", "Неизвестный формат статуса русификации.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in parts.Skip(1))
        {
            var pair = part.Split('=', 2);
            Check(pair.Length == 2 && fields.TryAdd(pair[0], pair[1]), "Повреждены поля русификации.");
        }
        int mounted = 0;
        int pid = 0;
        Check(fields.Keys.Where(key => key != "reason").ToHashSet().SetEquals(["state", "language", "mounted", "boot", "pid", "revision"]) &&
              (!fields.TryGetValue("reason", out var reason) || fields["state"] == "error" && ScreenStatusReasons.Contains(reason)) &&
              new[] { "absent", "enabled", "disabled", "error" }.Contains(fields["state"]) &&
              new[] { "en", "cn", "other" }.Contains(fields["language"]) &&
              int.TryParse(fields["mounted"], out mounted) && mounted is >= 0 and <= 3 &&
              int.TryParse(fields["pid"], out pid) && pid >= 0 &&
              fields["boot"] is "0" or "1" &&
              new[] { "20260922", "20260923", "20260924" }.Contains(fields["revision"]), "Некорректный статус русификации.");
        var boot = fields["boot"] == "1";
        Check(fields["state"] == "error" || (fields["state"] == "enabled" ? mounted == 3 && boot : mounted == 0 && !boot), "Состояние русификации не согласовано.");
        return new ScreenLocalizationStatus(fields["state"], fields["language"], mounted, boot, pid, fields["revision"], fields.GetValueOrDefault("reason"));
    }

    private static byte[] ApplyScreenFontPatch(byte[] original, byte[] manifestBytes)
    {
        using var document = JsonDocument.Parse(manifestBytes);
        var manifest = document.RootElement;
        var inputHash = StringProperty(manifest, "inputSHA256");
        var outputHash = StringProperty(manifest, "outputSHA256");
        Check(manifest.GetProperty("version").GetInt32() == 1 && original.Length == manifest.GetProperty("inputSize").GetInt32() &&
              original.Length == manifest.GetProperty("outputSize").GetInt32() && Sha(original) == inputHash,
            "Исходный экранный интерфейс не соответствует проверенной B31.");
        var result = (byte[])original.Clone();
        var previousEnd = 0;
        var patches = manifest.GetProperty("patches").EnumerateArray().ToArray();
        Check(patches.Length is >= 1 and <= 1024, "Некорректный список патчей шрифта.");
        foreach (var edit in patches)
        {
            var offset = edit.GetProperty("offset").GetInt32();
            var before = Convert.FromHexString(edit.GetProperty("originalHex").GetString() ?? "");
            var after = Convert.FromHexString(edit.GetProperty("replacementHex").GetString() ?? "");
            Check(before.Length > 0 && before.Length == after.Length && offset >= previousEnd && offset >= 0 && offset <= original.Length - before.Length &&
                  original.AsSpan(offset, before.Length).SequenceEqual(before), "Патч шрифта не соответствует исходным байтам.");
            after.CopyTo(result.AsSpan(offset));
            previousEnd = offset + before.Length;
        }
        Check(Sha(result) == outputHash, "Контрольная сумма русифицированного экрана не совпала.");
        return result;
    }
}
