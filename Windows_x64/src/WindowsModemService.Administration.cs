using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

public sealed partial class WindowsModemService
{
    private partial async Task<string> PrepareSshAsync(IReadOnlyDictionary<string,string>? parameters,CancellationToken ct)
    {
        if (_ssh is not null) throw new InvalidOperationException("SSH уже подключён; предварительная подготовка не требуется.");
        var host = Param(parameters,"host",_host);
        var webPassword = parameters?.GetValueOrDefault("web_password") ?? "";
        var agentPassword = parameters?.GetValueOrDefault("agent_password") ?? "";
        var backupKeySuffix = parameters?.GetValueOrDefault("backup_key_suffix") ?? "";
        var skipFirmware = Param(parameters,"skip_firmware_check") == "true";
        if (string.IsNullOrEmpty(webPassword) || string.IsNullOrEmpty(agentPassword))
            throw new ArgumentException("Для подготовки нужны пароль веб-интерфейса и пароль агента.");
        var onboarding = new OnboardingEngine(host,_storage,_resources,_adb,skipFirmware);
        var setup = await onboarding.PrepareAsync(webPassword,agentPassword,backupKeySuffix,ct);
        _host = host;
        _keyPath = setup.KeyPath;
        _knownHostsPath = setup.KnownHostsPath;
        var connection = new Dictionary<string,string> {
            ["host"] = host, ["mode"] = "SSH", ["key_path"] = _keyPath,
            ["known_hosts_path"] = _knownHostsPath,
            ["skip_firmware_check"] = skipFirmware ? "true" : "false",
        };
        var message = await ConnectAsync(connection,ct);
        return "Предварительная подготовка завершена. " + message;
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
                return _snapshot.Agent!;
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
                foreach (var name in new[] { "imei-pending.json", "pending.json", "setup-pending.json", "system-restore-pending.json" })
                    if (File.Exists(Path.Combine(_storage,name)))
                        throw new InvalidOperationException("Сначала завершите незавершённую операцию; перезагрузка сейчас запрещена.");
                using var local = new FileStream(Path.Combine(_storage,"operation.lock"),FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,FileShare.None);
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
            status.Running ? "Агент установлен и запущен" : "Агент установлен, но не запущен";
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
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory,"report-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".json");
        var logs = await GetLogsAsync(ct);
        var document = new {
            schema = 1,
            createdAt = DateTimeOffset.UtcNow,
            application = "ZTE IMEI Studio Windows x64",
            connectionMode = _snapshot.ConnectionMode,
            model = _snapshot.Model,
            firmware = _snapshot.Firmware,
            operations = logs.Select(x => new { x.Timestamp, x.Level, operation = x.Message.Split(':',2)[0] }).ToArray(),
            note = "Пароли, команды, ответы модема, IMEI и CID в этот отчёт не включены."
        };
        await using var output = new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough);
        await JsonSerializer.SerializeAsync(output,document,new JsonSerializerOptions { WriteIndented = true },ct);
        await output.FlushAsync(ct);
        return "Диагностический журнал приложения сохранён: " + path;
    }
}
