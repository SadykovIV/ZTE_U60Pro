using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Core;

internal sealed class ComponentCleanupPending
{
    public string Id { get; set; } = "";
    public string Cid { get; set; } = "";
    public string BootId { get; set; } = "";
    // BootId remains the immutable remote transaction/setup owner identity.
    public string? AcceptedBootId { get; set; }
    public string FirmwareHash { get; set; } = "";
    public string RouterHash { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 2222;
    public string KeyPath { get; set; } = "";
    public string KnownHostsPath { get; set; } = "";
    public string BackupDirectory { get; set; } = "";
    public string SetupReceipt { get; set; } = "";
    public string Profile { get; set; } = "";
    public string Token { get; set; } = "";
    public string Phase { get; set; } = "prepared";
    public string? ArchiveSha { get; set; }
    public long ArchiveBytes { get; set; }
    public string? CancelledFromPhase { get; set; }
    public string? CancellationStatus { get; set; }
}

public sealed partial class OnboardingEngine
{
    internal const string CleanupPendingName = "component-cleanup-pending.json";
    private const long CleanupArchiveLimit = 16L * 1024 * 1024 * 1024;
    private string CleanupPendingPath => Path.Combine(_storage, CleanupPendingName);
    internal Func<IRemoteShell>? CleanupSshFactory { get; init; }
    internal Func<IRemoteShell, string, byte[], string, long, CancellationToken, Task<RemoteFileResult>>? CleanupStream { get; init; }

    internal async Task<ComponentCleanupPending?> LoadUndispatchedCleanupRecoveryAsync(CancellationToken ct = default)
    {
        RejectReparsePoint(CleanupPendingPath);
        if (!File.Exists(CleanupPendingPath))
        {
            if (Directory.Exists(CleanupPendingPath)) throw new InvalidDataException("Повреждён журнал очистки компонентов.");
            return null;
        }
        if (new FileInfo(CleanupPendingPath).Length is < 1 or > 65536) throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        var plan = JsonSerializer.Deserialize<ComponentCleanupPending>(await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false))
            ?? throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        ValidateCleanupPending(plan);
        return plan.Phase is "prepared" or "backup-verified" ? plan : null;
    }

    // Caller holds operation.lock and supplies freshly repeated USB identity.
    // No component command is dispatched and existing archives stay untouched.
    internal async Task<bool> ArchiveUndispatchedCleanupAfterRebootAsync(DeviceIdentity proof, CancellationToken ct = default)
    {
        var plan = await LoadUndispatchedCleanupRecoveryAsync(ct).ConfigureAwait(false);
        if (plan is null) return false;
        var original = await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false);
        var current = JsonSerializer.Deserialize<ComponentCleanupPending>(original);
        if (current is null || JsonSerializer.Serialize(current) != JsonSerializer.Serialize(plan))
            throw new InvalidDataException("Журнал очистки изменился; он сохранён для проверки.");
        if (proof.Cid != plan.Cid || proof.FirmwareHash != plan.FirmwareHash || proof.RouterHash != plan.RouterHash ||
            !Guid.TryParseExact(proof.BootId, "D", out var boot) || proof.BootId != boot.ToString("D"))
            throw new InvalidDataException("После перезагрузки обнаружено другое устройство или прошивка; журнал очистки сохранён.");
        if (proof.BootId == (plan.AcceptedBootId ?? plan.BootId)) return false;
        var setup = File.Exists(PendingPath) ? await LoadPendingAsync(ct).ConfigureAwait(false) : null;
        if (setup is not null) ValidateCleanupSetup(setup, plan);
        if (plan.ArchiveSha is not null && !await CleanupArchiveMatchesAsync(Path.Combine(plan.BackupDirectory, "components.tar"), plan.ArchiveSha, plan.ArchiveBytes, ct).ConfigureAwait(false))
            throw new InvalidDataException("Копия компонентов повреждена; журнал очистки сохранён.");
        Directory.CreateDirectory(plan.BackupDirectory);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(plan.BackupDirectory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        RejectReparsePoint(CleanupPendingPath);
        if (!(await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false)).AsSpan().SequenceEqual(original))
            throw new InvalidDataException("Журнал очистки изменился; он сохранён для проверки.");
        File.Move(CleanupPendingPath, Path.Combine(plan.BackupDirectory, "cleanup-before-reset-" + Guid.NewGuid().ToString("D") + ".json"));
        return true;
    }

    internal static bool HasComponentCleanupPending(string storage)
    {
        var path = Path.Combine(storage, CleanupPendingName);
        if (File.Exists(path) || Directory.Exists(path)) return true;
        try
        {
            var setupPath = Path.Combine(storage, "setup-pending.json");
            RejectReparsePoint(setupPath);
            if (!File.Exists(setupPath) || new FileInfo(setupPath).Length is < 1 or > 65536) return false;
            var setup = JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(setupPath));
            return setup is { Phase: "complete", InstallRequested: true, ForceReinstall: true, CleanComponents: true };
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or JsonException) { return false; }
    }

    internal async Task<OnboardingResult> CancelComponentCleanupAsync(CancellationToken ct = default)
    {
        using var localLock = new FileStream(Path.Combine(_storage, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        RejectReparsePoint(CleanupPendingPath);
        var original = await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false);
        if (original.Length is < 1 or > 65536) throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        var pending = JsonSerializer.Deserialize<ComponentCleanupPending>(original) ?? throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        ValidateCleanupPending(pending);
        if (pending.Phase == "cancelled") { await FinishCancellationAsync(pending, ct).ConfigureAwait(false); return CancelledCleanupResult(pending); }
        if (pending.Phase is not ("prepared" or "backup-verified")) throw new InvalidOperationException("Отмена недоступна: удаление уже запрошено или его результат неизвестен. Журнал сохранён.");
        var setup = File.Exists(PendingPath) ? await LoadPendingAsync(ct).ConfigureAwait(false) : null;
        if (setup is not null) ValidateCleanupSetup(setup, pending);
        else
        {
            RejectReparsePoint(pending.SetupReceipt);
            if (new FileInfo(pending.SetupReceipt).Length is < 1 or > 65536) throw new InvalidDataException("Не подтверждён результат подготовки перед очисткой.");
            ValidateCleanupSetup(JsonSerializer.Deserialize<OnboardingPending>(await File.ReadAllBytesAsync(pending.SetupReceipt, ct).ConfigureAwait(false)), pending);
        }
        var body = await ReadCleanupHelperAsync(ct).ConfigureAwait(false);
        var ssh = CleanupSshFactory?.Invoke() ?? new SshTransport(pending.Host, pending.Port, pending.KeyPath, pending.KnownHostsPath);
        var expected = new DeviceIdentity(pending.Cid, pending.FirmwareHash, pending.AcceptedBootId ?? pending.BootId, pending.RouterHash);
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != expected) throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        var command = "sh -s -- " + string.Join(' ', new[] { "status", "/data/zte-imei-studio/cleanup-" + pending.Id, pending.Id, pending.Cid, pending.BootId, pending.FirmwareHash, pending.RouterHash, Guid.NewGuid().ToString("D") }.Select(Quote));
        var reply = await RunCleanupCommandAsync(ssh, command, body, "status", 300, ct).ConfigureAwait(false);
        var state = ParseCleanupReply(reply, "status");
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != expected) throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        if (!CancellationStateAllowed(pending, state))
            throw new InvalidOperationException("Отмена недоступна: удаление уже запрошено или его результат неизвестен. Журнал сохранён.");
        if (!(await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false)).AsSpan().SequenceEqual(original))
            throw new InvalidDataException("Журнал очистки изменился; он сохранён для проверки.");
        // Persist the terminal cancellation and its proof together, before any
        // receipt or journal deletion. A crash can only finalize cancellation.
        pending.CancelledFromPhase = pending.Phase;
        pending.CancellationStatus = state;
        pending.Phase = "cancelled";
        await WriteJsonAsync(CleanupPendingPath, pending, ct).ConfigureAwait(false);
        await FinishCancellationAsync(pending, ct).ConfigureAwait(false);
        return CancelledCleanupResult(pending);
    }

    private static OnboardingResult CancelledCleanupResult(ComponentCleanupPending pending) =>
        new(pending.Cid, pending.FirmwareHash, null, pending.KeyPath, pending.KnownHostsPath,
            false, pending.Profile, Port: pending.Port, CleanupCancelled: true);

    private static bool CancellationStateAllowed(ComponentCleanupPending pending, string state)
    {
        if (state is "CLEAN_ABSENT" or "CLEAN_INCOMPLETE") return pending.ArchiveSha is null;
        var prepared = Regex.Match(state, "^CLEAN_PREPARED ([0-9a-f]{64}) ([1-9][0-9]*)$");
        return prepared.Success && long.TryParse(prepared.Groups[2].Value, out var size) && size <= CleanupArchiveLimit &&
            (pending.ArchiveSha is null || (pending.ArchiveSha == prepared.Groups[1].Value && pending.ArchiveBytes == size));
    }

    private async Task FinishCancellationAsync(ComponentCleanupPending pending, CancellationToken ct)
    {
        ValidateCleanupPending(pending);
        if (pending.Phase != "cancelled") throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        var original = await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false);
        var setup = File.Exists(PendingPath) ? await LoadPendingAsync(ct).ConfigureAwait(false) : null;
        if (setup is not null) ValidateCleanupSetup(setup, pending);
        else
        {
            RejectReparsePoint(pending.SetupReceipt);
            if (new FileInfo(pending.SetupReceipt).Length is < 1 or > 65536) throw new InvalidDataException("Не подтверждён результат подготовки перед очисткой.");
            ValidateCleanupSetup(JsonSerializer.Deserialize<OnboardingPending>(await File.ReadAllBytesAsync(pending.SetupReceipt, ct).ConfigureAwait(false)), pending);
        }
        await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "component-cleanup-cancelled.json"), pending, ct).ConfigureAwait(false);
        await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "component-cleanup-cancellation-proof.json"), new { id = pending.Id, state = pending.CancellationStatus, readOnly = true }, ct).ConfigureAwait(false);
        if (!(await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false)).AsSpan().SequenceEqual(original))
            throw new InvalidDataException("Журнал очистки изменился; он сохранён для проверки.");
        // Preserve the already committed SSH endpoint before clearing either
        // journal. A crash cannot return the application to legacy port/key data.
        // This is metadata only; no connection or credential content is saved.
        await WriteJsonAsync(Path.Combine(_storage, "connection.json"), new {
            host = pending.Host, port = pending.Port, key_path = pending.KeyPath,
            known_hosts_path = pending.KnownHostsPath
        }, ct).ConfigureAwait(false);
        if (setup is not null) await FinishAsync(setup, ct).ConfigureAwait(false);
        File.Delete(CleanupPendingPath);
    }

    private async Task<OnboardingResult> ResumeCommittedCleanupAsync(OnboardingPending setup, CancellationToken ct)
    {
        // Commit is already durable. Recover a crash before saving the separate
        // cleanup intent through the saved SSH credentials, without ADB or auth.
        var expected = new DeviceIdentity(setup.Cid ?? "", setup.FirmwareHash ?? "", setup.BootId ?? "", setup.RouterHash ?? "");
        var ssh = CleanupSshFactory?.Invoke() ?? new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != expected)
            throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        await SaveComponentCleanupIntentAsync(setup, expected, ct).ConfigureAwait(false);
        return await ResumeComponentCleanupAsync(ct).ConfigureAwait(false);
    }

    private async Task SaveComponentCleanupIntentAsync(OnboardingPending setup, DeviceIdentity identity, CancellationToken ct)
    {
        if (!setup.ForceReinstall || !setup.CleanComponents || setup.Phase != "complete" || !setup.InstallRequested)
            throw new InvalidDataException("Очистка требует завершённой принудительной подготовки.");
        if (File.Exists(CleanupPendingPath)) throw new InvalidDataException("Сначала завершите очистку компонентов программы.");
        var pending = new ComponentCleanupPending
        {
            Id = setup.Id, Cid = identity.Cid, BootId = identity.BootId,
            FirmwareHash = identity.FirmwareHash, RouterHash = identity.RouterHash,
            Host = _host, KeyPath = KeyPath, KnownHostsPath = KnownHostsPath,
            BackupDirectory = setup.BackupDirectory, SetupReceipt = Path.Combine(setup.BackupDirectory, "setup-result.json"),
            Profile = setup.Profile ?? "", Token = Guid.NewGuid().ToString("D")
        };
        ValidateCleanupPending(pending);
        // Persist before removing setup-pending, so a restart cannot repeat force preparation.
        await WriteJsonAsync(CleanupPendingPath, pending, ct).ConfigureAwait(false);
    }

    private void ValidateCleanupPending(ComponentCleanupPending pending)
    {
        static bool Uuid(string value) => Guid.TryParseExact(value, "D", out var id) && value == id.ToString("D");
        var backupRoot = Path.GetFullPath(Path.Combine(_storage, "SetupBackups")) + Path.DirectorySeparatorChar;
        if (!Uuid(pending.Id) || !Uuid(pending.Token) || !Uuid(pending.BootId) || (pending.AcceptedBootId is not null && !Uuid(pending.AcceptedBootId)) ||
            !Regex.IsMatch(pending.Cid, "^[0-9a-f]{32}$") ||
            !Regex.IsMatch(pending.FirmwareHash, "^(?:absent|[0-9a-f]{64})$") ||
            !Regex.IsMatch(pending.RouterHash, "^(?:absent|[0-9a-f]{64})$") ||
            pending.Host != _host || pending.Port != 2222 || pending.KeyPath != KeyPath || pending.KnownHostsPath != KnownHostsPath ||
            pending.Profile is not ("b31" or "b02" or "linux-arm64-access") ||
            pending.Phase is not ("prepared" or "backup-verified" or "clean-requested" or "complete" or "cancelled") ||
            !Path.GetFullPath(pending.BackupDirectory).StartsWith(backupRoot, StringComparison.OrdinalIgnoreCase) ||
            pending.SetupReceipt != Path.Combine(pending.BackupDirectory, "setup-result.json") ||
            (pending.ArchiveSha is not null && (!Regex.IsMatch(pending.ArchiveSha, "^[0-9a-f]{64}$") || pending.ArchiveBytes is < 1 or > CleanupArchiveLimit)) ||
            (pending.ArchiveSha is null && (pending.ArchiveBytes != 0 || (pending.Phase == "cancelled" ? pending.CancelledFromPhase : pending.Phase) != "prepared")) ||
            (pending.Phase == "cancelled" ? pending.CancelledFromPhase is not ("prepared" or "backup-verified") || pending.CancellationStatus is null || !CancellationStateAllowed(pending, pending.CancellationStatus)
                : pending.CancelledFromPhase is not null || pending.CancellationStatus is not null))
            throw new InvalidDataException("Повреждён журнал очистки компонентов или выбрано другое подключение.");
        var directory = Path.GetFullPath(pending.BackupDirectory);
        while (directory.StartsWith(backupRoot, StringComparison.OrdinalIgnoreCase))
        {
            RejectReparsePoint(directory);
            directory = Path.GetDirectoryName(directory)!;
        }
        RejectReparsePoint(Path.GetFullPath(Path.Combine(_storage, "SetupBackups")));
    }

    private async Task<OnboardingResult> ResumeComponentCleanupAsync(CancellationToken ct)
    {
        RejectReparsePoint(CleanupPendingPath);
        if (new FileInfo(CleanupPendingPath).Length is < 1 or > 65536)
            throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        var pending = JsonSerializer.Deserialize<ComponentCleanupPending>(await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false))
            ?? throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        ValidateCleanupPending(pending);
        // A crash between the two local writes may leave both journals. Only the
        // already committed setup may be finalized here; no installer is dispatched.
        if (File.Exists(PendingPath))
        {
            var setup = await LoadPendingAsync(ct).ConfigureAwait(false);
            ValidateCleanupSetup(setup, pending);
            await WriteJsonAsync(pending.SetupReceipt, setup!, ct).ConfigureAwait(false);
        }
        RejectReparsePoint(pending.SetupReceipt);
        if (new FileInfo(pending.SetupReceipt).Length is < 1 or > 65536)
            throw new InvalidDataException("Не подтверждён результат подготовки перед очисткой.");
        ValidateCleanupSetup(JsonSerializer.Deserialize<OnboardingPending>(await File.ReadAllBytesAsync(pending.SetupReceipt, ct).ConfigureAwait(false)), pending);
        if (pending.Phase == "cancelled")
        {
            await FinishCancellationAsync(pending, ct).ConfigureAwait(false);
            return CancelledCleanupResult(pending);
        }
        var body = await ReadCleanupHelperAsync(ct).ConfigureAwait(false);
        var ssh = CleanupSshFactory?.Invoke() ?? new SshTransport(pending.Host, pending.Port, pending.KeyPath, pending.KnownHostsPath);
        var identity = new DeviceIdentity(pending.Cid, pending.FirmwareHash, pending.AcceptedBootId ?? pending.BootId, pending.RouterHash);
        async Task Identity()
        {
            if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != identity)
                throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        }
        string Command(string action, string? hash = null)
        {
            // Never reuse the interrupted command's lock token: its presence in
            // our own argv would make a provably stale lock look live forever.
            var args = new[] { action, "/data/zte-imei-studio/cleanup-" + pending.Id, pending.Id, pending.Cid,
                pending.BootId, pending.FirmwareHash, pending.RouterHash, Guid.NewGuid().ToString("D") };
            return "sh -s -- " + string.Join(' ', (hash is null ? args : args.Append(hash)).Select(Quote));
        }
        var observed = await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false);
        if (observed.Cid != identity.Cid || observed.FirmwareHash != identity.FirmwareHash || observed.RouterHash != identity.RouterHash)
            throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        if (observed.BootId != identity.BootId)
        {
            // Explicit continuation may bind a new boot to the original owner,
            // but only the helper's separate metadata action can authorize it.
            if (pending.ArchiveSha is not null && !await CleanupArchiveMatchesAsync(Path.Combine(pending.BackupDirectory, "components.tar"), pending.ArchiveSha, pending.ArchiveBytes, ct).ConfigureAwait(false))
                throw new InvalidDataException("Локальная резервная копия компонентов не подтверждена; журнал сохранён.");
            _progress?.Invoke("Подтверждаю продолжение чистой установки после перезагрузки…");
            var reply = await RunCleanupCommandAsync(ssh, Command("rebind", pending.ArchiveSha ?? "none") + " " + Quote(observed.BootId), body, "rebind", 300, ct).ConfigureAwait(false);
            var fields = ParseCleanupReply(reply, "rebind").Split(' ');
            if (fields[1] != observed.BootId || (pending.ArchiveSha is not null && (fields[2] != pending.ArchiveSha || fields[3] != pending.ArchiveBytes.ToString(System.Globalization.CultureInfo.InvariantCulture))))
                throw new InvalidDataException("Удалённый журнал очистки изменён; автоматическое продолжение остановлено.");
            if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != observed)
                throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
            // A lost reply leaves the old host state intact. Repeating rebind is
            // safe because the helper retains the original owner and archive.
            pending.AcceptedBootId = observed.BootId;
            await WriteJsonAsync(CleanupPendingPath, pending, ct).ConfigureAwait(false);
            identity = observed;
        }
        async Task<string> Call(string action, int seconds, string? hash = null)
        {
            await Identity().ConfigureAwait(false);
            var reply = await RunCleanupCommandAsync(ssh, Command(action, hash), body, action, seconds, ct).ConfigureAwait(false);
            var receipt = ParseCleanupReply(reply, action);
            await Identity().ConfigureAwait(false);
            return receipt;
        }
        _progress?.Invoke("Проверяю компоненты перед очисткой…");
        var state = await Call("status", 300).ConfigureAwait(false);
        if ((pending.Phase == "complete" && state != "CLEAN_COMPLETE") ||
            (state == "CLEAN_COMPLETE" && pending.Phase is not ("clean-requested" or "complete")))
            throw new InvalidDataException("Удалённый журнал очистки изменён; автоматическое продолжение остановлено.");
        if (state is "CLEAN_ABSENT" or "CLEAN_INCOMPLETE")
        {
            if (pending.Phase != "prepared" || pending.ArchiveSha is not null)
                throw new InvalidDataException("Удалённый журнал очистки изменён; автоматическое продолжение остановлено.");
            state = await Call("prepare", 300).ConfigureAwait(false);
        }
        var archive = Path.Combine(pending.BackupDirectory, "components.tar");
        if (state != "CLEAN_COMPLETE")
        {
            var fields = Regex.Match(state, "^CLEAN_(PREPARED|PENDING) ([0-9a-f]{64}) ([1-9][0-9]*)$");
            if (!fields.Success || !long.TryParse(fields.Groups[3].Value, out var bytes) || bytes > CleanupArchiveLimit ||
                (fields.Groups[1].Value == "PENDING" && pending.Phase != "clean-requested"))
                throw new InvalidDataException("Не подтверждена резервная копия компонентов.");
            var sha = fields.Groups[2].Value;
            if (pending.ArchiveSha is not null && (pending.ArchiveSha != sha || pending.ArchiveBytes != bytes))
                throw new InvalidDataException("Резервная копия компонентов изменилась; удаление остановлено.");
            if (pending.ArchiveSha is null)
            {
                var free = new DriveInfo(Path.GetPathRoot(archive)!).AvailableFreeSpace;
                if (free < checked(bytes + 64L * 1024 * 1024)) throw new IOException("Недостаточно места для резервной копии компонентов.");
                if (OperatingSystem.IsWindows()) ProtectPrivateDirectory(pending.BackupDirectory);
                else File.SetUnixFileMode(pending.BackupDirectory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                var partial = archive + ".partial-" + Guid.NewGuid().ToString("N");
                try
                {
                    await Identity().ConfigureAwait(false);
                    _progress?.Invoke("Сохраняю резервную копию компонентов на компьютер…");
                    var streamed = CleanupStream is not null
                        ? await CleanupStream(ssh, Command("stream"), Encoding.UTF8.GetBytes(body), partial, bytes, ct).ConfigureAwait(false)
                        : await ((SshTransport)ssh).RunToFileAsync(Command("stream"), partial, bytes, TimeSpan.FromSeconds(300), ct, stdin: Encoding.UTF8.GetBytes(body)).ConfigureAwait(false);
                    ProtectPrivateFile(partial);
                    if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(partial, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    await Identity().ConfigureAwait(false);
                    if (!streamed.Success)
                        throw new CleanupReplyException("stream", CleanupFailureCode(new RemoteResult(streamed.ExitCode, [], streamed.Stderr)));
                    var receipt = StrictUtf8.GetString(streamed.Stderr).TrimEnd('\n');
                    if (!streamed.Success || streamed.Bytes != bytes || streamed.Sha256 != sha || receipt != $"BACKUP_RESULT sha256={sha} bytes={bytes}" ||
                        !await CleanupArchiveMatchesAsync(partial, sha, bytes, ct).ConfigureAwait(false))
                        throw new InvalidDataException("Локальная резервная копия компонентов не прошла проверку; удаление не выполнялось.");
                    RejectReparsePoint(archive);
                    if (File.Exists(archive))
                    {
                        if (!await CleanupArchiveMatchesAsync(archive, sha, bytes, ct).ConfigureAwait(false))
                            throw new InvalidDataException("Существующая резервная копия компонентов отличается.");
                        File.Delete(partial);
                    }
                    else File.Move(partial, archive);
                }
                finally { if (File.Exists(partial)) File.Delete(partial); }
                pending.ArchiveSha = sha; pending.ArchiveBytes = bytes; pending.Phase = "backup-verified";
                await WriteJsonAsync(CleanupPendingPath, pending, ct).ConfigureAwait(false);
            }
            if (!await CleanupArchiveMatchesAsync(archive, pending.ArchiveSha!, pending.ArchiveBytes, ct).ConfigureAwait(false))
                throw new InvalidDataException("Локальная резервная копия компонентов не подтверждена; очистка остановлена.");
            _progress?.Invoke("Резервная копия компонентов проверена: " + archive);
            pending.Phase = "clean-requested";
            await WriteJsonAsync(CleanupPendingPath, pending, ct).ConfigureAwait(false);
            // One dispatch per explicit operation. A later operation checks status
            // and resumes this same cleanup transaction, never forced preparation.
            _progress?.Invoke("Очищаю проверенные данные агента, VPN и дополнительных страниц…");
            try { await Call("clean", 180, pending.ArchiveSha).ConfigureAwait(false); }
            catch (CleanupReplyException failure) when (failure.OutcomeUnknown)
            {
                // The command may have committed before SSH lost its reply. One
                // identity-bound read-only check may confirm that same operation;
                // never dispatch clean or prepare again in this invocation.
                var reconciled = false;
                try { reconciled = await Call("status", 300).ConfigureAwait(false) == "CLEAN_COMPLETE"; }
                catch (CleanupReplyException) { }
                if (!reconciled) throw;
            }
        }
        if (pending.ArchiveSha is null || !await CleanupArchiveMatchesAsync(archive, pending.ArchiveSha, pending.ArchiveBytes, ct).ConfigureAwait(false))
            throw new InvalidDataException("Локальная резервная копия компонентов не подтверждена; журнал сохранён.");
        _progress?.Invoke("Очистка подтверждена; резервная копия компонентов сохранена на компьютере.");
        pending.Phase = "complete";
        await WriteJsonAsync(CleanupPendingPath, pending, ct).ConfigureAwait(false);
        await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "component-cleanup-result.json"), pending, ct).ConfigureAwait(false);
        // The service acknowledges only after it has saved and connected with
        // these SSH settings. A lost result must not repeat forced preparation.
        return new OnboardingResult(pending.Cid, pending.FirmwareHash, null, pending.KeyPath, pending.KnownHostsPath,
            false, pending.Profile, Port: pending.Port, ComponentsCleaned: true, CleanupId: pending.Id);
    }

    internal async Task AcknowledgeComponentCleanupAsync(string id, CancellationToken ct = default)
    {
        using var localLock = new FileStream(Path.Combine(_storage, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        RejectReparsePoint(CleanupPendingPath);
        var original = await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false);
        if (original.Length is < 1 or > 65536) throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        var pending = JsonSerializer.Deserialize<ComponentCleanupPending>(original)
            ?? throw new InvalidDataException("Повреждён журнал очистки компонентов.");
        ValidateCleanupPending(pending);
        if (pending.Id != id || pending.Phase != "complete" || pending.ArchiveSha is null ||
            !await CleanupArchiveMatchesAsync(Path.Combine(pending.BackupDirectory, "components.tar"), pending.ArchiveSha, pending.ArchiveBytes, ct).ConfigureAwait(false))
            throw new InvalidDataException("Локальная резервная копия компонентов не подтверждена; журнал сохранён.");
        if (File.Exists(PendingPath))
        {
            var setup = await LoadPendingAsync(ct).ConfigureAwait(false);
            ValidateCleanupSetup(setup, pending);
            await FinishAsync(setup!, ct).ConfigureAwait(false);
        }
        var current = await File.ReadAllBytesAsync(CleanupPendingPath, ct).ConfigureAwait(false);
        if (!original.AsSpan().SequenceEqual(current))
            throw new InvalidDataException("Журнал очистки изменился; он сохранён для проверки.");
        File.Delete(CleanupPendingPath);
    }

    internal static readonly IReadOnlySet<string> CleanupErrorCodes = new HashSet<string>(StringComparer.Ordinal)
    {
        "ARCHIVE", "BACKUP_NOT_VERIFIED", "BUSY", "CHANGED", "IDENTITY", "LAYOUT", "MOUNT", "OWNER", "PATH", "PENDING",
        "PLATFORM", "PROCESS", "RECOVERY_REQUIRED", "SERVICE", "SNAPSHOT", "STARTUP", "STOP", "SYMLINK", "TRANSACTION",
        "VPN_BACKUP", "VPN_CONFIGURATION", "VPN_INTEGRITY", "VPN_NETWORK", "VPN_RESTORE",
        "PENDING_AGENT", "PENDING_FOREIGN", "PENDING_LIVE", "PENDING_OWNER", "IKE_RESTORE", "VPN_PLAN", "WRITE",
        "CLEAN", "LOCK", "MOVE", "PLAN", "PREPARE", "RESTORE"
    };

    private sealed class CleanupReplyException(string action, string code, bool outcomeUnknown = false)
        : IOException(CleanupDiagnostic(action, code))
    {
        internal bool OutcomeUnknown { get; } = outcomeUnknown;
    }

    private static string CleanupDiagnostic(string action, string code)
    {
        var stage = action switch { "status" => "проверка состояния", "prepare" => "подготовка копии", "stream" => "сохранение копии", "rebind" => "подтверждение новой загрузки", _ => "очистка" };
        var reason = code switch
        {
            "BUSY" or "PENDING" or "PENDING_FOREIGN" or "PENDING_LIVE" or "LOCK" => "Другая операция модема ещё не завершена.",
            "SERVICE" or "VPN_INTEGRITY" or "STARTUP" => "Не подтверждена установленная версия компонентов или их запуска.",
            "VPN_CONFIGURATION" or "VPN_NETWORK" or "VPN_PLAN" => "Настройки VPN не соответствуют подтверждённой установке.",
            "VPN_BACKUP" or "ARCHIVE" or "BACKUP_NOT_VERIFIED" or "SNAPSHOT" => "Не подтверждена резервная копия компонентов.",
            "CHANGED" or "IDENTITY" => "Состав компонентов или модем изменился.",
            "LAYOUT" or "MOUNT" or "OWNER" or "PATH" or "SYMLINK" => "Не подтверждены расположение или принадлежность файлов компонентов.",
            "PLATFORM" => "Не подтверждены необходимые возможности прошивки.",
            "PROCESS" or "STOP" => "Не подтверждена остановка процессов компонентов.",
            "RECOVERY_REQUIRED" or "TRANSACTION" or "VPN_RESTORE" or "IKE_RESTORE" or "PENDING_AGENT" or "PENDING_OWNER" => "Не завершено восстановление сохранённой операции.",
            "CLEAN" or "MOVE" or "PLAN" or "PREPARE" or "RESTORE" or "WRITE" => "Инструмент очистки прервался на сохранённом этапе.",
            "TRANSPORT" => "SSH не подтвердил результат команды. Проверьте подключение к модему.",
            "TIMEOUT" => "Истекло время ожидания ответа модема.",
            "PROTOCOL" => "Ответ инструмента очистки имеет неподтверждённый формат.",
            _ => "Инструмент очистки завершился без подтверждённого кода причины."
        };
        var retry = code is "BUSY" or "PENDING" or "PENDING_FOREIGN" or "PENDING_LIVE" or "LOCK" or "STOP" or "PROCESS" or "VPN_RESTORE" or "IKE_RESTORE" or "CLEAN" or "MOVE" or "PLAN" or "PREPARE" or "RESTORE" or "WRITE" or "TRANSPORT" or "TIMEOUT" or "PROTOCOL" or "REMOTE_FAILURE";
        var next = retry ? "Журнал сохранён; продолжите чистую установку для проверки состояния." : "Журнал сохранён. Сохраните диагностический отчёт с этим кодом.";
        return $"Чистая установка: {stage} [{code}]. {reason} {next}";
    }

    private static string CleanupFailureCode(RemoteResult reply)
    {
        if (reply.ExitCode is < 0 or > 254) return "TRANSPORT";
        if (reply.ExitCode == 0) return "PROTOCOL";
        if (reply.Stderr.Length > 4096) return "REMOTE_FAILURE";
        string text;
        try { text = StrictUtf8.GetString(reply.Stderr); }
        catch (DecoderFallbackException) { return "REMOTE_FAILURE"; }
        var codes = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n')
            .Where(line => line.StartsWith("CLEAN_ERROR ", StringComparison.Ordinal)).ToArray();
        return codes.Length == 1 && CleanupErrorCodes.Contains(codes[0][12..]) ? codes[0][12..] : "REMOTE_FAILURE";
    }

    internal static string CleanupFailureMessage(RemoteResult reply, string action = "clean") => CleanupDiagnostic(action, CleanupFailureCode(reply));

    internal static string ParseCleanupReply(RemoteResult reply, string action)
    {
        if (!reply.Success)
        {
            var code = CleanupFailureCode(reply);
            throw new CleanupReplyException(action, code, code == "TRANSPORT");
        }
        string text;
        try { text = reply.Stdout.Length <= 512 ? StrictUtf8.GetString(reply.Stdout) : ""; }
        catch (DecoderFallbackException) { text = ""; }
        // Accept exactly one receipt, optionally terminated by LF or CRLF.
        if (text.EndsWith("\r\n", StringComparison.Ordinal)) text = text[..^2];
        else if (text.EndsWith('\n')) text = text[..^1];
        var valid = action != "rebind" && text == "CLEAN_COMPLETE";
        if (action == "rebind")
        {
            var match = Regex.Match(text, @"\ACLEAN_REBOUND ([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}) (none|[0-9a-f]{64}) (0|[1-9][0-9]*)\z");
            valid = match.Success && long.TryParse(match.Groups[3].Value, out var bytes) && bytes <= CleanupArchiveLimit &&
                (match.Groups[2].Value == "none" ? bytes == 0 : bytes > 0);
        }
        if (action == "status" && text is "CLEAN_ABSENT" or "CLEAN_INCOMPLETE") valid = true;
        if (action is "status" or "prepare")
        {
            var match = Regex.Match(text, @"\ACLEAN_(PREPARED|PENDING) ([0-9a-f]{64}) ([1-9][0-9]*)\z");
            valid |= match.Success && (action == "status" || match.Groups[1].Value == "PREPARED") &&
                long.TryParse(match.Groups[3].Value, out var bytes) && bytes <= CleanupArchiveLimit;
        }
        if (!valid) throw new CleanupReplyException(action, "PROTOCOL", true);
        return text;
    }

    private static async Task<RemoteResult> RunCleanupCommandAsync(IRemoteShell ssh, string command, string body, string action, int seconds, CancellationToken ct)
    {
        try { return await ssh.RunAsync(command, Encoding.UTF8.GetBytes(body), TimeSpan.FromSeconds(seconds), ct).ConfigureAwait(false); }
        catch (TimeoutException) { throw new CleanupReplyException(action, "TIMEOUT", true); }
        catch (Exception e) when (e is not SshTrustException && (e is IOException or System.Net.Sockets.SocketException or Renci.SshNet.Common.SshException))
        { throw new CleanupReplyException(action, "TRANSPORT", true); }
    }

    private async Task<string> ReadCleanupHelperAsync(CancellationToken ct)
    {
        var hashes = JsonSerializer.Deserialize<Dictionary<string, string>>(await File.ReadAllBytesAsync(Path.Combine(_resources, "Onboarding", "SHA256.json"), ct).ConfigureAwait(false));
        var helper = await File.ReadAllBytesAsync(Path.Combine(_resources, "Onboarding", "clean-components.sh"), ct).ConfigureAwait(false);
        if (helper.Length is < 1 or > 65536 || helper.Contains((byte)0) || hashes?.GetValueOrDefault("clean-components.sh") != Sha(helper))
            throw new InvalidDataException("Повреждён встроенный инструмент очистки компонентов.");
        return StrictUtf8.GetString(helper);
    }

    private static void ValidateCleanupSetup(OnboardingPending? setup, ComponentCleanupPending cleanup)
    {
        if (setup is null || setup.Id != cleanup.Id || setup.Phase != "complete" || !setup.InstallRequested || !setup.ForceReinstall || !setup.CleanComponents ||
            setup.Cid != cleanup.Cid || setup.BootId != cleanup.BootId || setup.FirmwareHash != cleanup.FirmwareHash || setup.RouterHash != cleanup.RouterHash ||
            setup.Profile != cleanup.Profile || setup.BackupDirectory != cleanup.BackupDirectory)
            throw new InvalidDataException("Не подтверждён результат подготовки перед очисткой.");
    }

    private static async Task<bool> CleanupArchiveMatchesAsync(string path, string sha, long bytes, CancellationToken ct)
    {
        RejectReparsePoint(path);
        if (!File.Exists(path) || new FileInfo(path).Length != bytes) return false;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.Asynchronous);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false)) == sha;
    }
}
