using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;
using ZteImeiStudio.Windows.Diagnostics;

namespace ZteImeiStudio.Windows;

public sealed partial class WindowsModemService
{
    private partial async Task<string> PrepareSshAsync(IReadOnlyDictionary<string,string>? parameters,CancellationToken ct)
    {
        if (_ssh is not null && !File.Exists(Path.Combine(_storage,"setup-pending.json"))) throw new InvalidOperationException("SSH уже подключён; предварительная подготовка не требуется.");
        var host = Param(parameters,"host",_host);
        var webPassword = parameters?.GetValueOrDefault("web_password") ?? "";
        var agentPassword = parameters?.GetValueOrDefault("agent_password") ?? "";
        var backupKeySuffix = parameters?.GetValueOrDefault("backup_key_suffix") ?? "";
        var skipFirmware = Param(parameters,"skip_firmware_check") == "true";
        if (string.IsNullOrEmpty(agentPassword))
            throw new ArgumentException("Для подготовки нужен пароль агента. Без пароля Web используется только уже доступный единственный root USB ADB.");
        var onboarding = new OnboardingEngine(host,_storage,_resources,_adb,skipFirmware,
            progress: message => Log("info","Подготовка: " + message));
        var setup = await onboarding.PrepareAsync(webPassword,agentPassword,backupKeySuffix,ct);
        _host = host;
        _keyPath = setup.KeyPath;
        _knownHostsPath = setup.KnownHostsPath;
        var connection = new Dictionary<string,string> {
            ["host"] = host, ["mode"] = "SSH", ["key_path"] = _keyPath,
            ["known_hosts_path"] = _knownHostsPath,
            ["skip_firmware_check"] = skipFirmware ? "true" : "false",
            ["access_only"] = setup.Profile == "linux-arm64-access" ? "true" : "false",
        };
        var message = await ConnectAsync(connection,ct);
        if (setup.AlreadyConfigured)
            return "Доступ SSH подтверждён. Существующий агент " + setup.ReusedAgentVersion + " сохранён; установка не выполнялась. " + message;
        if (setup.Profile != "linux-arm64-access" && setup.FirmwareHash == DeviceFeatureService.FirmwareHash)
        {
            try
            {
                if (await _features!.InstallDashboardForCurrentAgentAsync(ct))
                    return "Предварительная подготовка завершена. Постоянный агент eSIM и веб-панель готовы. " + message;
                return "Подключение готово. Существующий агент сохранён; обновите агент и веб-панель в разделе «Установка агента». " + message;
            }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                throw new InvalidOperationException("SSH готов, но установка веб-панели не подтверждена. Проверьте состояние и выполните «Установить / обновить» в разделе агента.");
            }
        }
        return "Предварительная подготовка завершена. " + message;
    }

    private async Task<string> EnableDiagnosticAdbAsync(IReadOnlyDictionary<string,string>? parameters, CancellationToken ct)
    {
        var host = Param(parameters, "host", _host);
        var password = parameters?.GetValueOrDefault("web_password") ?? "";
        var backupKeySuffix = parameters?.GetValueOrDefault("backup_key_suffix") ?? "";
        var resuming = File.Exists(Path.Combine(_storage,"adb-access-pending.json"));
        if (string.IsNullOrEmpty(password) && !resuming) throw new ArgumentException("Для включения диагностического ADB введите пароль Web. Пароль агента не нужен.");
        if (_ssh is not null && host != _host)
            throw new InvalidOperationException("Адрес отличается от подключённого SSH-модема. Сначала подключитесь к нужному модему.");
        Core.DeviceIdentity? expected = null;
        string? expectedImei = null;
        var previousCid = _snapshot.Serial;
        if (_ssh is not null && !resuming)
        {
            expected = await _imei!.MeasuredIdentityAsync(ct);
            var reply = await _ssh.RunAsync("ubus call zwrt_web device_info '{}'", timeout:TimeSpan.FromSeconds(15), ct:ct);
            if (!reply.Success) throw new IOException("SSH не подтвердил IMEI для сопоставления с Web.");
            using var document = JsonDocument.Parse(reply.Stdout);
            expectedImei = document.RootElement.GetProperty("imei").GetString();
            if (!ImeiCodec.IsValid(expectedImei)) throw new InvalidDataException("SSH не подтвердил IMEI для сопоставления с Web.");
        }
        var onboarding = new OnboardingEngine(host, _storage, _resources, _adb,
            Param(parameters,"skip_firmware_check") == "true", message => Log("info", "Подготовка: " + message));
        try
        {
            var result = await onboarding.EnableDiagnosticAdbAsync(password, backupKeySuffix, expected, expectedImei, ct);
            return result.AlreadyAvailable ? "Диагностический ADB уже доступен; модем не изменялся." : "Диагностический ADB включён и проверен. Для обычной работы используется SSH.";
        }
        finally
        {
            // Activation may reboot the modem. Never retain a stale connected
            // indicator merely because an SSH transport object still exists.
            if (_ssh is not null)
            {
                try
                {
                    var current = await _imei!.MeasuredIdentityAsync(CancellationToken.None);
                    if (current.Cid != (expected?.Cid ?? previousCid) || expected is not null && current.FirmwareHash != expected.FirmwareHash)
                        throw new InvalidDataException("SSH-модем изменился.");
                    _snapshot = _snapshot with { IsConnected = true, ConnectionMode = "SSH", Status = "Подключено по SSH" };
                }
                catch
                {
                    _ssh = null; _imei = null; _features = null; _serial = null; _adbCid = null;
                    _snapshot = new DeviceSnapshot(false, "После включения ADB SSH не подтверждён. Подключитесь снова.", IpAddress: host);
                }
            }
        }
    }

    private partial async Task<string> RunOtherExtendedAsync(OperationRequest request,CancellationToken ct)
    {
        if (request.Operation is not (ModemOperation.VerifyDeviceBackup or ModemOperation.VerifySystemBackup or ModemOperation.ExportDiagnostics)) RequireSsh();
        var p = request.Parameters;
        switch (request.Operation)
        {
            case ModemOperation.RefreshAgent:
            {
                var status = await _features!.GetAgentStatusAsync(ct);
                _snapshot = _snapshot with { Agent = DescribeAgent(status) };
                return _snapshot.Agent!;
            }
            case ModemOperation.InstallAgent:
            {
                var status = await _features!.InstallAgentAsync(ct);
                _snapshot = _snapshot with { Agent = DescribeAgent(status) };
                return "Постоянный агент eSIM и веб-панель установлены. " + _snapshot.Agent!;
            }
            case ModemOperation.RestoreAgent:
            {
                var status = await _features!.RestoreAgentAsync(ct);
                _snapshot = _snapshot with { Agent = DescribeAgent(status) };
                return _snapshot.Agent!;
            }
            case ModemOperation.RefreshLocalization:
                return DescribeLocalization(await _features!.GetLocalizationStatusAsync(ct));
            case ModemOperation.InstallLocalization:
                return DescribeLocalization(await _features!.InstallLocalizationAsync(ct));
            case ModemOperation.RestoreLocalization:
                return DescribeLocalization(await _features!.RestoreLocalizationAsync(ct));
            case ModemOperation.ApplyImei:
            {
                var first = Param(p,"imei1"); var second = Param(p,"imei2");
                if (!ImeiCodec.IsValid(first) || !ImeiCodec.IsValid(second) || first == second)
                    throw new InvalidDataException("Введите два разных IMEI с верной контрольной цифрой.");
                var result = await _imei!.ApplyAsync(first,second,ct);
                _snapshot = _snapshot with { Imei = string.Join(" / ",result.Imeis) };
                return "Оба IMEI подтверждены после перезагрузки по NV и API.";
            }
            case ModemOperation.RestoreImeiBackup:
            {
                var result = await _imei!.RestoreAsync(Param(p,"id"),ct);
                _snapshot = _snapshot with { Imei = string.Join(" / ",result.Imeis) };
                return "IMEI восстановлены из проверенной копии и подтверждены после перезагрузки.";
            }
            case ModemOperation.ResumeImei:
            {
                var result = await _imei!.ResumeAsync(ct);
                _snapshot = _snapshot with { Imei = string.Join(" / ",result.Imeis) };
                return "Незавершённая операция IMEI продолжена и проверена.";
            }
            case ModemOperation.RefreshAccess:
            {
                var status = await _features!.GetAccessStatusAsync(_host,ct);
                return "Службы: " + string.Join(", ",status.Services.Select(x => x.Id + "=" + x.State)) +
                    "; SSH-пользователей: " + status.Accounts.Accounts.Count +
                    (status.Accounts.RecoveryPending ? "; требуется восстановление учётных записей" : "");
            }
            case ModemOperation.CreateSshAccount:
            {
                var state = await _features!.CreateSshAccountAsync(Param(p,"username"),p?.GetValueOrDefault("password") ?? "",_host,ct);
                return "SSH-пользователь создан; порт " + state.Port + ". Всего: " + state.Accounts.Count + ".";
            }
            case ModemOperation.RemoveSshAccount:
            {
                var state = await _features!.DeleteSshAccountAsync(Param(p,"username"),_host,ct);
                return "SSH-пользователь удалён. Осталось: " + state.Accounts.Count + ".";
            }
            case ModemOperation.ChangeAccessService:
            {
                var status = await _features!.ChangeAccessServiceAsync(Param(p,"service"),Param(p,"service_action"),_host,ct);
                var service = status.Services.Single(x => x.Id == Param(p,"service"));
                return "Служба " + service.Id + ": " + service.State + ".";
            }
            case ModemOperation.CreateDeviceBackup:
            {
                var backup = new DeviceBackupManager(_ssh!,_features!,_storage);
                var path = await backup.CreateAsync(ct);
                return "Бэкап данных модема создан и проверен: " + path;
            }
            case ModemOperation.VerifyDeviceBackup:
            {
                var manifest = await DeviceBackupManager.VerifyStoredAsync(_storage,Param(p,"id"),ct);
                return "Бэкап проверен: " + manifest.Files.Length + " файлов, " +
                    manifest.Files.Sum(x => x.Bytes).ToString("N0") + " байт.";
            }
            case ModemOperation.CreateSystemBackup:
            {
                var backup = await new SystemBackupManager(_ssh!, _features!, _storage).CreateAsync(ct);
                return "Образ системы создан и проверен: " + backup.Path +
                    ". Снимок работающего модема не атомарен; восстановление через приложение недоступно.";
            }
            case ModemOperation.VerifySystemBackup:
            {
                var manifest = await SystemBackupManager.VerifyStoredAsync(_storage, Param(p, "id"), ct);
                return "Образ системы проверен: " + manifest.Files.Length + " областей eMMC, " +
                    manifest.Files.Sum(x => x.Bytes).ToString("N0") + " байт; " + manifest.Capture + ".";
            }
            case ModemOperation.RestoreDeviceBackup:
                throw new NotSupportedException("Автоматическое восстановление этой копии не предусмотрено. Файлы сохранены для ручного восстановления.");
            case ModemOperation.RefreshDiagnostics:
            {
                var diag = await _features!.GetDiagnosticToolsStatusAsync(ct);
                return "Диагностические утилиты: " + (diag.Selected.Count == 0 ? "не установлены" : string.Join(", ",diag.Selected)) +
                    "; свободно на /data: " + (diag.FreeKiB/1024) + " МиБ.";
            }
            case ModemOperation.ExportDiagnostics:
                return await ExportLocalDiagnosticsAsync(ct);
            case ModemOperation.RebootDevice:
            {
                foreach (var name in new[] { "imei-pending.json", "pending.json", "setup-pending.json", "adb-access-pending.json", "system-restore-pending.json" })
                    if (File.Exists(Path.Combine(_storage,name)))
                        throw new InvalidOperationException("Сначала завершите незавершённую операцию; перезагрузка сейчас запрещена.");
                using var local = new FileStream(Path.Combine(_storage,"operation.lock"),FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,FileShare.None);
                foreach (var name in new[] { "imei-pending.json", "pending.json", "setup-pending.json", "adb-access-pending.json", "system-restore-pending.json" })
                    if (File.Exists(Path.Combine(_storage,name)))
                        throw new InvalidOperationException("Сначала завершите незавершённую операцию; перезагрузка сейчас запрещена.");
                var token = Guid.NewGuid().ToString("D");
                var owner = "/tmp/zte-imei-app.lock/owner";
                var acquire = await _ssh!.RunAsync("set -eu; umask 077; mkdir /tmp/zte-imei-app.lock; printf '%s' " +
                    VerifiedHash.ShellQuote(token) + " > " + owner,
                    timeout:TimeSpan.FromSeconds(10),ct:ct);
                if (!acquire.Success) throw new InvalidOperationException("Модем занят другой операцией. Перезагрузка остановлена.");
                try
                {
                    var command = "set -eu; test \"$(cat " + owner + ")\" = " + VerifiedHash.ShellQuote(token) +
                        "; for p in /data/local/tmp/zte-imei-installations/active /data/local/tmp/open-u60-transactions/active /tmp/fota_install_processing /data/zte-vpn/transaction; do test ! -e \"$p\" && test ! -L \"$p\"; done; " +
                        "ubus call zwrt_mc.device.manager device_reboot '{\"moduleName\":\"web\"}'";
                    var response = await _ssh.RunAsync(command,timeout:TimeSpan.FromSeconds(15),ct:ct);
                    if (!response.Success) throw new IOException("Модем не подтвердил команду перезагрузки. Перед повтором проверьте его состояние.");
                }
                finally
                {
                    try { _ = await _ssh.RunAsync("test \"$(cat " + owner + " 2>/dev/null)\" = " +
                        VerifiedHash.ShellQuote(token) + " && rm " + owner + " && rmdir /tmp/zte-imei-app.lock",
                        timeout:TimeSpan.FromSeconds(5),ct:CancellationToken.None); }
                    catch { /* The modem may already be rebooting. */ }
                }
                _ssh = null; _features = null; _imei = null;
                _snapshot = new DeviceSnapshot(false,"Перезагрузка модема; подключитесь снова",IpAddress:_host);
                return "Команда перезагрузки отправлена один раз. Дождитесь появления модема.";
            }
            default:
                throw new NotSupportedException("Эта операция в Windows-сборке не реализована: " + request.Operation);
        }
    }

    private static string DescribeAgent(AgentInstallationStatus status)
        => status.RecoveryPending ? "Требуется восстановление агента" :
            status.Hash == "absent" ? "Агент не установлен" :
            status.Version is null ? (status.Running ? "Неизвестная сборка агента · запущен" : "Неизвестная сборка агента · не запущен") :
            status.IsCurrent ? (status.Running ? $"Агент {status.Version} · запущен" : $"Агент {status.Version} · не запущен") :
            status.Running ? $"Агент {status.Version} · предыдущая сборка · запущен" : $"Агент {status.Version} · предыдущая сборка · не запущен";
    private static string DescribeLocalization(ScreenLocalizationStatus status)
        => status.State switch {
            "enabled" => "Русификация включена (" + status.Language + ").",
            "disabled" => "Штатный интерфейс восстановлен.",
            "absent" => "Русификация не установлена.",
            _ => "Состояние русификации требует проверки.",
        };

    private async Task<string> ExportLocalDiagnosticsAsync(CancellationToken ct)
    {
        var directory = Path.Combine(_storage,"Diagnostics");
        var path = Path.Combine(directory,"report-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".zip");
        var logs = await GetLogsAsync(ct);
        var system = new DiagnosticSystemSnapshot(_snapshot.ConnectionMode, _snapshot.Model, _snapshot.Firmware,
            typeof(WindowsModemService).Assembly.GetName().Version?.ToString() ?? "unknown");
        var result = DiagnosticsExporter.Export(_storage, path, system,
            logs.Select(x => new DiagnosticActivity(x.Timestamp, x.Level, x.Message)),
            _diagnosticPrivacy, _diagnosticJournalWriteFailed, ct);
        return "Диагностический ZIP приложения сохранён: " + result.Path +
            ". Включены действия программы и очищенные трассировки операций. Свежий сбор с модема не выполнялся." +
            (result.Omissions == 0 ? "" : " Часть сохранённых данных пропущена; причины указаны в manifest.json.");
    }
}
