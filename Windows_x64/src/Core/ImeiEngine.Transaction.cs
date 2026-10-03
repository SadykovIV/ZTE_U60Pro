using System.Text;
using System.Text.Json;

namespace ZteImeiStudio.Windows.Core;

public sealed partial class ImeiEngine
{
    // The SSH command is allowed 240 seconds. After a lost connection the
    // helper may still be running remotely, so resume must wait beyond that
    // deadline before it can issue another raw mutation.
    private static readonly TimeSpan MutationSettleTime = TimeSpan.FromSeconds(270);

    /// <summary>Start a new, journalled two-slot write. A fresh verified backup is mandatory.</summary>
    public Task<ImeiState> ApplyAsync(string imei1, string imei2, CancellationToken ct = default)
    {
        if (!ImeiCodec.IsValid(imei1) || !ImeiCodec.IsValid(imei2) || imei1 == imei2)
            throw new ArgumentException("Введите два разных IMEI с верными контрольными цифрами.");
        return BeginAsync([imei1, imei2], null, ct);
    }

    /// <summary>Restore the two NV550 records from a verified local backup.</summary>
    public Task<ImeiState> RestoreAsync(string backupId, CancellationToken ct = default)
    {
        if (!Guid.TryParse(backupId, out _)) throw new ArgumentException("Неверный ID бэкапа.", nameof(backupId));
        return BeginAsync(null, backupId, ct);
    }

    /// <summary>Explicitly reconcile an interrupted transaction; never starts a fresh write.</summary>
    public async Task<ImeiState> ResumeAsync(CancellationToken ct = default)
    {
        if (!File.Exists(Pending)) throw new InvalidOperationException("Незавершённая операция IMEI не найдена.");
        if (File.Exists(Path.Combine(storageRoot, "adb-access-pending.json")))
            throw new InvalidOperationException("Сначала завершите включение диагностического ADB.");
        var identity = await IdentityForWriteAsync(ct);
        return await Locked(identity, token => ResumeCoreAsync(identity, token), ct);
    }

    public bool HasPendingTransaction => File.Exists(Pending);

    private async Task<ImeiState> BeginAsync(string[]? targets, string? restoreId, CancellationToken ct)
    {
        if (File.Exists(Path.Combine(storageRoot, "setup-pending.json")) || File.Exists(Path.Combine(storageRoot, "adb-access-pending.json")))
            throw new InvalidOperationException("Сначала завершите первоначальную настройку модема.");
        if (File.Exists(Pending))
            throw new InvalidOperationException("Сначала продолжите незавершённую операцию IMEI.");
        var identity = await IdentityForWriteAsync(ct);
        return await Locked(identity, async token =>
        {
            // Recheck after taking both local and device locks; another process
            // must not be able to race a backup with creation of the journal.
            if (File.Exists(Pending)) throw new InvalidOperationException("Найдена незавершённая операция IMEI.");
            var state = await InspectCoreAsync(identity, token);
            byte[][] desired;
            if (restoreId is not null)
            {
                var (source, records, _) = await LoadBackup(Path.Combine(Backups, restoreId), token);
                if (!SameDevice(source.Identity, state.Identity))
                    throw new InvalidDataException("Бэкап относится к другому модему или прошивке.");
                for (var i = 0; i < 2; i++)
                    if (!records[i].AsSpan(9).SequenceEqual(state.Nv[i].AsSpan(9)))
                        throw new InvalidDataException("Остальные байты NV отличаются от бэкапа; восстановление остановлено.");
                desired = records;
            }
            else
            {
                if (targets is not { Length: 2 }) throw new ArgumentException("Нужны два IMEI.");
                desired = [ImeiCodec.EncodeNv550(targets[0], state.Nv[0]),
                    ImeiCodec.EncodeNv550(targets[1], state.Nv[1])];
            }
            if (ImeiCodec.DecodeNv550(desired[0]) == ImeiCodec.DecodeNv550(desired[1]))
                throw new InvalidDataException("Для двух слотов нужны разные IMEI.");
            if (PairEqual(desired, state.Nv))
                throw new InvalidOperationException("Эта пара IMEI уже записана.");

            var backupPath = await CreateBackupCoreAsync(state, token);
            var pending = new ImeiPending(1, Guid.NewGuid().ToString(), Path.GetFileName(backupPath),
                identity, desired.Select(Convert.ToHexString).ToArray(), "prepared");
            await SaveJson(Pending, pending, token);
            return await ResumeCoreAsync(identity, token);
        }, ct);
    }

    private async Task<ImeiState> ResumeCoreAsync(DeviceIdentity connected, CancellationToken ct)
    {
        var pending = JsonSerializer.Deserialize<ImeiPending>(await File.ReadAllTextAsync(Pending, ct))
            ?? throw new InvalidDataException("Повреждён журнал IMEI.");
        if (pending.Schema != 1 || !Guid.TryParse(pending.Id, out _) ||
            !Guid.TryParse(pending.BackupId, out _) || pending.TargetHex is not { Length: 2 } ||
            pending.TargetHex.Any(value => value.Length != 256) ||
            pending.Phase is not ("prepared" or "enabling" or "rebooting-to-enable" or "writing" or
                "written" or "restoring-config" or "final-reboot"))
            throw new InvalidDataException("Повреждён журнал операции IMEI.");
        if (pending.Phase is "enabling" or "restoring-config")
        {
            if (pending.ConfigMutationStartedAt is not { } started)
                throw new InvalidDataException("В журнале нет времени изменения config. Автоматический повтор запрещён.");
            if (DateTimeOffset.UtcNow - started < MutationSettleTime)
                throw new InvalidOperationException("Предыдущая операция config могла ещё выполняться. Дождитесь 270 секунд и выберите «Продолжить».");
        }
        if (pending.Phase == "writing" && pending.WriteStartedAt is null)
            throw new InvalidDataException("В журнале нет времени начала записи. Автоматический повтор запрещён.");
        if (pending.Phase == "writing" && DateTimeOffset.UtcNow - pending.WriteStartedAt!.Value < MutationSettleTime)
            throw new InvalidOperationException("Предыдущая запись NV могла ещё выполняться. Дождитесь 270 секунд и снова выберите «Продолжить».");
        if (!SameDevice(connected, pending.Identity))
            throw new InvalidDataException("Подключён другой модем или изменена прошивка.");

        var (backup, original, originalConfig) = await LoadBackup(Path.Combine(Backups, pending.BackupId), ct);
        if (!SameDevice(backup.Identity, pending.Identity))
            throw new InvalidDataException("Бэкап и журнал относятся к разным устройствам.");
        var desired = pending.TargetHex.Select(Convert.FromHexString).ToArray();
        for (var i = 0; i < 2; i++)
        {
            _ = ImeiCodec.DecodeNv550(desired[i]);
            if (!desired[i].AsSpan(9).SequenceEqual(original[i].AsSpan(9)))
                throw new InvalidDataException("Журнал изменяет посторонние байты NV.");
        }
        if (ImeiCodec.DecodeNv550(desired[0]) == ImeiCodec.DecodeNv550(desired[1]))
            throw new InvalidDataException("В журнале одинаковые IMEI.");
        var candidateConfig = ConfigCodec.Candidate(originalConfig);
        var configPlan = originalConfig.Concat(candidateConfig).ToArray();
        var current = await Snapshot(ct);
        CheckKnownPair(current, original, desired);
        if (pending.Phase is "written" or "restoring-config" or "final-reboot" && !PairEqual(current, desired))
            throw new InvalidDataException("После подтверждённой записи NV изменился. Повторная запись запрещена.");
        var diskConfig = await ReadConfig(ct);
        CheckKnownConfig(diskConfig, originalConfig, candidateConfig);
        var boot = connected.BootId;

        if (!PairEqual(current, desired))
        {
            if (diskConfig.AsSpan().SequenceEqual(originalConfig))
            {
                pending = pending with { Phase = "enabling", ConfigMutationStartedAt = DateTimeOffset.UtcNow };
                await SaveJson(Pending, pending, ct);
                await Helper("zte_config", "--enable-flag", configPlan, ct);
                diskConfig = await ReadConfig(ct);
                if (!diskConfig.AsSpan().SequenceEqual(candidateConfig))
                    throw new InvalidDataException("Флаг записи config не подтвердился.");
            }
            pending = pending with { Phase = "rebooting-to-enable", ConfigMutationStartedAt = null };
            await SaveJson(Pending, pending, ct);

            if (boot == pending.Identity.BootId)
            {
                connected = await RebootAsync(boot, pending.Identity, ct);
                boot = connected.BootId;
            }
            else
            {
                // A prior run can have completed the enable reboot just before
                // the host stopped; a new boot ID proves it happened.
                connected = await IdentityForWriteAsync(ct);
                if (!SameDevice(connected, pending.Identity))
                    throw new InvalidDataException("После перезагрузки подключён другой модем.");
            }

            var afterConfig = await ReadConfig(ct);
            CheckKnownConfig(afterConfig, originalConfig, candidateConfig);
            if (!afterConfig.AsSpan().SequenceEqual(candidateConfig))
                throw new InvalidDataException("После перезагрузки разрешение записи не сохранилось.");
            current = await Snapshot(ct);
            CheckKnownPair(current, original, desired);
            if (!PairEqual(current, desired))
            {
                var plan = current[0].Concat(current[1]).Concat(desired[0]).Concat(desired[1]).ToArray();
                pending = pending with { Phase = "writing", WriteStartedAt = DateTimeOffset.UtcNow };
                await SaveJson(Pending, pending, ct);
                await Helper("zte_nv", "--apply-plan", plan, ct);
                current = await Snapshot(ct);
                if (!PairEqual(current, desired) || !(await ApiPair(ct)).SequenceEqual(desired.Select(item => ImeiCodec.DecodeNv550(item))))
                    throw new InvalidDataException("Проверка обоих IMEI после записи не прошла.");
            }
            pending = pending with { Phase = "written" };
            await SaveJson(Pending, pending, ct);
        }
        else if (!(await ApiPair(ct)).SequenceEqual(desired.Select(item => ImeiCodec.DecodeNv550(item))))
            throw new InvalidDataException("Текущие IMEI в API не совпадают с журналом.");

        if (!diskConfig.AsSpan().SequenceEqual(originalConfig))
        {
            pending = pending with { Phase = "restoring-config", ConfigMutationStartedAt = DateTimeOffset.UtcNow };
            await SaveJson(Pending, pending, ct);
            await Helper("zte_config", "--restore-original-config", configPlan, ct);
        }
        var restored = await ReadConfig(ct);
        if (!restored.AsSpan().SequenceEqual(originalConfig))
            throw new InvalidDataException("Исходный config не восстановлен.");

        if (pending.Phase != "final-reboot" || pending.FinalBootBefore is null)
        {
            pending = pending with { Phase = "final-reboot", FinalBootBefore = boot };
            await SaveJson(Pending, pending, ct);
        }
        if (boot == pending.FinalBootBefore)
        {
            connected = await RebootAsync(boot, pending.Identity, ct);
            boot = connected.BootId;
        }
        if (boot == pending.FinalBootBefore)
            throw new InvalidDataException("Заключительная перезагрузка не подтверждена.");

        var finalIdentity = await IdentityForWriteAsync(ct);
        if (!SameDevice(finalIdentity, pending.Identity) || finalIdentity.BootId == pending.FinalBootBefore)
            throw new InvalidDataException("После перезагрузки подключён другой модем или не изменился boot ID.");
        var final = await InspectCoreAsync(finalIdentity, ct);
        if (!PairEqual(final.Nv, desired))
            throw new InvalidDataException("IMEI после заключительной перезагрузки не совпали.");
        await Helper("zte_config", "--check-original", configPlan, ct);
        if (!(await ReadConfig(ct)).AsSpan().SequenceEqual(originalConfig))
            throw new InvalidDataException("После перезагрузки config не совпал с исходным.");

        var complete = pending with { Phase = "complete" };
        var resultPath = Path.Combine(storageRoot, "IMEIResults", pending.Id + ".json");
        await SaveJson(resultPath, new
        {
            complete.Id, complete.BackupId, complete.Phase, complete.Identity,
            Imei1 = final.Imeis[0], Imei2 = final.Imeis[1], BootId = final.Identity.BootId,
            Verified = "NV + API + original config after reboot",
        }, ct);
        File.Delete(Pending);
        return final;
    }

    private static void CheckKnownPair(byte[][] current, byte[][] original, byte[][] desired)
    {
        for (var i = 0; i < 2; i++)
            if (!current[i].AsSpan().SequenceEqual(original[i]) && !current[i].AsSpan().SequenceEqual(desired[i]))
                throw new InvalidDataException("Текущий NV не совпал ни с исходным, ни с целевым. Операция остановлена.");
    }

    private static void CheckKnownConfig(byte[] current, byte[] original, byte[] candidate)
    {
        if (!current.AsSpan().SequenceEqual(original) && !current.AsSpan().SequenceEqual(candidate))
            throw new InvalidDataException("Config изменился посторонним образом. Операция остановлена.");
    }

    private async Task<DeviceIdentity> RebootAsync(string priorBoot, DeviceIdentity expected, CancellationToken ct)
    {
        try
        {
            // Send once: SSH loss is expected during a successful reboot.
            await Raw("ubus call zwrt_mc.device.manager device_reboot '{\"moduleName\":\"web\"}'",
                timeout: TimeSpan.FromSeconds(15), ct: ct);
        }
        catch when (!ct.IsCancellationRequested) { }

        var deadline = DateTimeOffset.UtcNow.AddMinutes(4);
        while (DateTimeOffset.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromSeconds(3), ct);
            DeviceIdentity? current;
            try { current = await IdentityForWriteAsync(ct); }
            catch when (!ct.IsCancellationRequested) { continue; }
            if (current.BootId == priorBoot) continue;
            if (!SameDevice(current, expected))
                throw new InvalidDataException("После перезагрузки подключён другой модем.");
            if (lockToken is not { } token) throw new InvalidOperationException("Утерян токен блокировки IMEI.");
            await AcquireRemoteToken(token, ct);
            return current;
        }
        throw new TimeoutException("Перезагрузка пока не подтверждена. Дождитесь подключения и выберите «Продолжить»; запись не повторяется автоматически.");
    }

    private async Task<DeviceIdentity> IdentityForWriteAsync(CancellationToken ct)
    {
        // "Skip firmware check" permits only connection and read-only work.
        // Both binaries must match the reviewed B31 pair before every write or
        // resume step, including after a reboot.
        var identity = await IdentityAsync(ct);
        if (identity.FirmwareHash != FirmwareHash)
            throw new InvalidDataException("Запись IMEI разрешена только на проверенной прошивке MU5250 B31.");
        var routerLine = await Text("sha256sum /usr/bin/diag-router", ct);
        var fields = routerLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 2 || fields[1] != "/usr/bin/diag-router" || fields[0] != RouterHash)
            throw new InvalidDataException("Diag-router отличается от проверенной B31. Запись IMEI остановлена.");
        return identity;
    }
}
