using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Features;

public sealed record AgentInstallationStatus(string Hash, bool Running, bool StartupReady, bool RecoveryPending, string? BackupHash);
public sealed record ScreenLocalizationStatus(string State, string Language, int Mounted, bool BootEnabled, int Pid, string Revision);

public sealed partial class DeviceFeatureService
{
    private const string AgentManagerHash = "d12154677e50567a311ca1d9f7d4f4019565e2e6f41cf7dc75d10d47fc8ef3a1";
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
    public Task<AgentInstallationStatus> RestoreAgentAsync(CancellationToken ct = default)
        => InvokeAgentAsync("restore", ct);

    private Task<AgentInstallationStatus> InvokeAgentAsync(string action, CancellationToken ct)
    {
        if (action == "status") return ReadOnly();
        return MutateAsync(async (identity, token) => await Invoke(identity, token), ct);

        async Task<AgentInstallationStatus> ReadOnly()
        {
            var identity = await ReadIdentityAsync(requireSupportedFirmware: true, ct);
            var status = await Invoke(identity, null);
            await VerifyIdentityAsync(identity, ct);
            return status;
        }
        async Task<AgentInstallationStatus> Invoke(DeviceIdentity identity, string? token)
        {
            var manager = await ResourceAsync("AgentInstallation", "manager.sh", ct);
            Check(Sha(manager) == AgentManagerHash, "Несовместимый установщик агента.");
            var files = new Dictionary<string, byte[]> { ["manager.sh"] = manager };
            if (action == "install")
            {
                var agent = await File.ReadAllBytesAsync(Path.Combine(_resourcesRoot, "Onboarding", "zte-agent"), ct);
                Check(Sha(agent) == VpnAgentHash && agent.Length is >= 64 and <= 64 * 1024 * 1024 && agent.AsSpan(0, 6).SequenceEqual(new byte[] { 0x7f, 0x45, 0x4c, 0x46, 2, 1 }),
                    "Встроенный агент повреждён или относится к другой архитектуре.");
                files.Add("agent.bin", agent);
            }
            var stage = await StageAsync("zte-agent-stage", files, ct);
            try
            {
                var before = await AgentStatusAtStageAsync(stage, ct);
                if (action == "status") return before;
                if (token == null) throw new DeviceFeatureException("Потеряна блокировка установки агента.");
                if (action == "install")
                {
                    Check(!before.RecoveryPending && before.Hash != "absent" && before.StartupReady, "Сначала выполните подготовку SSH/агента либо восстановите предыдущую версию.");
                    if (before.Hash == VpnAgentHash && before.Running) return before;
                    await RunAsync(Guard(identity, token) + "sh " + Quote(stage + "/manager.sh") + " install " + Quote(stage + "/agent.bin") + " " + Quote(VpnAgentHash), seconds: 120, ct: ct);
                    var after = await AgentStatusAtStageAsync(stage, ct);
                    Check(after.Hash == VpnAgentHash && after.Running && after.BackupHash == before.Hash && !after.RecoveryPending,
                        "Установка агента не подтверждена; проверьте состояние восстановления.");
                    return after;
                }
                Check(action == "restore" && before.BackupHash != null, "Проверенной копии предыдущего агента нет.");
                await RunAsync(Guard(identity, token) + "sh " + Quote(stage + "/manager.sh") + " restore", seconds: 120, ct: ct);
                var restored = await AgentStatusAtStageAsync(stage, ct);
                Check(restored.Hash == before.BackupHash && restored.Running && !restored.RecoveryPending, "Восстановление агента не подтверждено.");
                return restored;
            }
            finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
        }
    }

    private async Task<AgentInstallationStatus> AgentStatusAtStageAsync(string stage, CancellationToken ct)
    {
        var output = await RunTextAsync("set -eu; test \"$(sha256sum " + Quote(stage + "/manager.sh") + " | cut -d ' ' -f1)\" = " + Quote(AgentManagerHash) + "; sh " + Quote(stage + "/manager.sh") + " status", ct: ct);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var pair = line.Split(' ', 2);
            Check(pair.Length == 2 && values.TryAdd(pair[0], pair[1]), "Повреждён ответ проверки агента.");
        }
        Check(values.TryGetValue("AGENT_SHA", out var hash) && (hash == "absent" || Regex.IsMatch(hash, "^[0-9a-f]{64}$")), "Нет контрольной суммы установленного агента.");
        string? backup = values.GetValueOrDefault("AGENT_BACKUP");
        Check(backup == null || Regex.IsMatch(backup, "^[0-9a-f]{64}$"), "Повреждён бэкап агента.");
        return new AgentInstallationStatus(hash!, values.GetValueOrDefault("AGENT_RUNNING") == "yes",
            values.GetValueOrDefault("AGENT_STARTUP") == "yes", values.GetValueOrDefault("AGENT_PENDING") == "yes", backup);
    }

    public async Task<ScreenLocalizationStatus> GetScreenLocalizationStatusAsync(CancellationToken ct = default)
    {
        var identity = await ReadIdentityAsync(requireSupportedFirmware: true, ct);
        var presence = await RunTextAsync("if test -e " + ScreenRoot + " || test -L " + ScreenRoot + "; then echo present; else echo absent; fi", ct: ct);
        if (presence == "absent")
        {
            var output = await RunTextAsync("set -eu; language=$(uci -q get zwrt_deviceui.Device.device_language || true); case \"$language\" in en|cn) ;; *) language=other;; esac; " +
                "mounted=$(awk '$5==\"/usr/ui/language/English.ini\" || $5==\"/usr/ui/language/Chinese.ini\" || $5==\"/usr/bin/zte_topsw_devui\" {n++} END {print n+0}' /proc/self/mountinfo); " +
                "state=absent; if test \"$mounted\" != 0 || test -e /etc/init.d/zte_imei_screen_ru || test -L /etc/init.d/zte_imei_screen_ru || test -e /etc/rc.d/S47zte_imei_screen_ru || test -L /etc/rc.d/S47zte_imei_screen_ru || test ! -f /etc/init.d/zte_topsw_devui || test -L /etc/init.d/zte_topsw_devui || test \"$(sha256sum /etc/init.d/zte_topsw_devui 2>/dev/null | cut -d ' ' -f1)\" != a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35; then state=error; fi; " +
                "pid=$(pidof zte_topsw_devui 2>/dev/null | awk '{print $1}' || true); case \"$pid\" in ''|*[!0-9]*) pid=0;; esac; " +
                "printf 'SCREEN_RU_STATUS state=%s language=%s mounted=%s boot=0 pid=%s revision=20260924\\n' \"$state\" \"$language\" \"$mounted\" \"$pid\"", ct: ct);
            return ParseScreenStatus(output);
        }
        Check(presence == "present", "Не удалось определить состояние русификации.");
        var installedHash = await RunTextAsync("set -eu; test -d " + ScreenRoot + " && test ! -L " + ScreenRoot + "; test -f " + ScreenRoot + "/manager.sh && test ! -L " + ScreenRoot + "/manager.sh; sha256sum " + ScreenRoot + "/manager.sh | cut -d ' ' -f1", ct: ct);
        Check(installedHash == ScreenManagerHash || ScreenLegacyManagerHashes.Contains(installedHash), "Менеджер русификации изменён.");
        var command = ScreenManagerCommand("status", identity.Cid, installedHash);
        return ParseScreenStatus(await RunTextAsync(command, seconds: 45, ct: ct));
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
            Check(current.State != "error", "Текущее состояние русификации требует проверки.");
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
            Check(current.State is "enabled" or "disabled", "Состояние русификации требует проверки.");
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

    private static string ScreenManagerCommand(string action, string cid, string hash)
    {
        var manager = ScreenRoot + "/manager.sh";
        return "set -eu; test -d " + ScreenRoot + " && test ! -L " + ScreenRoot + "; test -f " + manager + " && test ! -L " + manager +
            "; test \"$(sha256sum " + manager + " | cut -d ' ' -f1)\" = " + Quote(hash) + "; sh " + manager + " " + Quote(action) + " " + Quote(cid);
    }

    private static ScreenLocalizationStatus ParseScreenStatus(string output)
    {
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Check(lines.Length == 1, "Неполный статус русификации.");
        var parts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Check(parts.Length == 7 && parts[0] == "SCREEN_RU_STATUS", "Неизвестный формат статуса русификации.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in parts.Skip(1))
        {
            var pair = part.Split('=', 2);
            Check(pair.Length == 2 && fields.TryAdd(pair[0], pair[1]), "Повреждены поля русификации.");
        }
        int mounted = 0;
        int pid = 0;
        Check(fields.Keys.ToHashSet().SetEquals(["state", "language", "mounted", "boot", "pid", "revision"]) &&
              new[] { "absent", "enabled", "disabled", "error" }.Contains(fields["state"]) &&
              new[] { "en", "cn", "other" }.Contains(fields["language"]) &&
              int.TryParse(fields["mounted"], out mounted) && mounted is >= 0 and <= 3 &&
              int.TryParse(fields["pid"], out pid) && pid >= 0 &&
              fields["boot"] is "0" or "1" &&
              new[] { "20260922", "20260923", "20260924" }.Contains(fields["revision"]), "Некорректный статус русификации.");
        var boot = fields["boot"] == "1";
        Check(fields["state"] == "error" || (fields["state"] == "enabled" ? mounted == 3 && boot : mounted == 0 && !boot), "Состояние русификации не согласовано.");
        return new ScreenLocalizationStatus(fields["state"], fields["language"], mounted, boot, pid, fields["revision"]);
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
