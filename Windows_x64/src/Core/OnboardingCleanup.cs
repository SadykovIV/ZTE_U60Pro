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
        var expected = new DeviceIdentity(pending.Cid, pending.FirmwareHash, pending.BootId, pending.RouterHash);
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != expected) throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        var command = "sh -s -- " + string.Join(' ', new[] { "status", "/data/zte-imei-studio/cleanup-" + pending.Id, pending.Id, pending.Cid, pending.BootId, pending.FirmwareHash, pending.RouterHash, pending.Token }.Select(Quote));
        var reply = await ssh.RunAsync(command, Encoding.UTF8.GetBytes(body), TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
        if (!reply.Success || reply.Stdout.Length > 512) throw new IOException(CleanupFailureMessage(reply));
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != expected) throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        var state = StrictUtf8.GetString(reply.Stdout).TrimEnd('\n');
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
        if (!Uuid(pending.Id) || !Uuid(pending.Token) || !Uuid(pending.BootId) ||
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
        var identity = new DeviceIdentity(pending.Cid, pending.FirmwareHash, pending.BootId, pending.RouterHash);
        async Task Identity()
        {
            if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != identity)
                throw new InvalidDataException("Устройство изменилось перед очисткой компонентов.");
        }
        string Command(string action, string? hash = null)
        {
            var args = new[] { action, "/data/zte-imei-studio/cleanup-" + pending.Id, pending.Id, pending.Cid,
                pending.BootId, pending.FirmwareHash, pending.RouterHash, pending.Token };
            return "sh -s -- " + string.Join(' ', (hash is null ? args : args.Append(hash)).Select(Quote));
        }
        async Task<string> Call(string action, int seconds, string? hash = null)
        {
            await Identity().ConfigureAwait(false);
            var reply = await ssh.RunAsync(Command(action, hash), Encoding.UTF8.GetBytes(body), timeout: TimeSpan.FromSeconds(seconds), ct: ct).ConfigureAwait(false);
            if (!reply.Success || reply.Stdout.Length > 512)
                throw new IOException(CleanupFailureMessage(reply));
            await Identity().ConfigureAwait(false);
            return StrictUtf8.GetString(reply.Stdout).TrimEnd('\n');
        }
        _progress?.Invoke("Проверяю компоненты перед очисткой…");
        var state = await Call("status", 30).ConfigureAwait(false);
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
            if (await Call("clean", 180, pending.ArchiveSha).ConfigureAwait(false) != "CLEAN_COMPLETE")
                throw new IOException("Очистка компонентов не подтверждена. Журнал сохранён; повторите подготовку для проверки состояния.");
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

    internal static string CleanupFailureMessage(RemoteResult reply)
    {
        const string unknown = "Очистка компонентов не подтверждена. Журнал сохранён; повторите подготовку для проверки состояния.";
        if (reply.ExitCode is < 1 or > 254 || reply.Stderr.Length > 4096) return unknown;
        var lines = Encoding.UTF8.GetString(reply.Stderr).Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var known = lines.Where(line => Regex.IsMatch(line, "^CLEAN_ERROR (BUSY|PENDING|VPN_CONFIGURATION|CHANGED|IDENTITY|RECOVERY_REQUIRED|STOP|VPN_RESTORE)$"))
            .Select(line => line[12..]).Distinct(StringComparer.Ordinal).ToArray();
        if (known.Length != 1) return unknown;
        return known[0] switch
        {
            "BUSY" or "PENDING" => "Другая операция модема ещё не завершена. Чистая установка сохранена для продолжения.",
            "VPN_CONFIGURATION" => "Сначала выключите Wi-Fi с VPN. Если он уже выключен, настройки VPN отличаются от установленных программой; очистка остановлена.",
            "CHANGED" or "IDENTITY" => "Состав компонентов или модем изменился. Очистка остановлена; копия и журнал сохранены.",
            _ => "Очистка прервана. Резервная копия и удалённые компоненты сохранены для восстановления; повторная подготовка не запускается."
        };
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
