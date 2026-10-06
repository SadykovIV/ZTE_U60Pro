using System.Diagnostics;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Core;

public sealed record BackupKeyVerification(string Firmware, string InnerVersion, int Entries, string EncryptedSha256, string Directory);

public sealed record AdbAccessResult(string Serial, DeviceIdentity Identity, WebIdentity WebIdentity, bool AlreadyAvailable);

public sealed record OnboardingResult(string? Cid, string? FirmwareHash, string? Imei,
    string KeyPath, string KnownHostsPath, bool AlreadyConfigured, string? Profile = null, bool AccessOnly = false, string? ReusedAgentVersion = null, int Port = 2222, bool ComponentsCleaned = false, string? CleanupId = null, bool CleanupCancelled = false);

internal sealed class OnboardingPending
{
    public string Intent { get; set; } = "preparation";
    public string Id { get; set; } = "";
    public WebIdentity? WebIdentity { get; set; }
    public string IdentitySource { get; set; } = "web-matched";
    public string BackupDirectory { get; set; } = "";
    public string Phase { get; set; } = "prepared";
    public bool RestoreRequested { get; set; }
    public bool DiagnosticRebootRequested { get; set; }
    public bool DirectAdbRequested { get; set; }
    public string? DirectAdbOutcome { get; set; }
    public bool InstallRequested { get; set; }
    public bool ForceReinstall { get; set; }
    public bool CleanComponents { get; set; }
    public string? AdbSerial { get; set; }
    public string? Cid { get; set; }
    public string? Profile { get; set; }
    public string? FirmwareHash { get; set; }
    public string? RouterHash { get; set; }
    public string? BootId { get; set; }
    public string? RemoteStage { get; set; }
    public string? RemoteJournal { get; set; }
    public bool? NewAgent { get; set; }

    public bool CanRequestRestore(bool adbMatched, bool backupAlreadyEnablesAdb) =>
        !adbMatched && !backupAlreadyEnablesAdb && !RestoreRequested && !InstallRequested && !DiagnosticRebootRequested;

    public bool CanStartInstallation => !InstallRequested;
    public bool CanRequestDirectAdb => !DirectAdbRequested && !RestoreRequested && !InstallRequested && !DiagnosticRebootRequested;

    public async Task RequestDirectAdbOnceAsync(Func<OnboardingPending, Task> persist, Func<Task> send)
    {
        if (!CanRequestDirectAdb) throw new InvalidOperationException("Запрос включения ADB уже отправлялся; повтор запрещён.");
        DirectAdbRequested = true;
        DirectAdbOutcome = "requested";
        await persist(this).ConfigureAwait(false);
        try { await send().ConfigureAwait(false); DirectAdbOutcome = "accepted"; }
        catch (ModemWebException error) when (error.Kind == WebFailureKind.RpcRejected)
        { DirectAdbOutcome = "rejected"; }
        catch (Exception error) when (error is HttpRequestException or TimeoutException || error is IOException)
        { DirectAdbOutcome = "uncertain"; }
        await persist(this).ConfigureAwait(false);
    }

    public async Task RequestDiagnosticRebootOnceAsync(Func<OnboardingPending,Task> persist, Func<Task> send)
    {
        if (Intent != "diagnostic-adb" || DiagnosticRebootRequested || RestoreRequested || InstallRequested)
            throw new InvalidOperationException("Диагностическая перезагрузка уже запрошена или несовместима с текущей операцией.");
        DiagnosticRebootRequested = true;
        Phase = "diagnostic-reboot-requested";
        await persist(this).ConfigureAwait(false);
        try { await send().ConfigureAwait(false); }
        catch (Exception error) when (error is HttpRequestException or TimeoutException || error is IOException and not ModemWebException)
        { /* A lost acknowledgement cannot authorize another reboot. */ }
    }

    public async Task RequestRestoreOnceAsync(Func<OnboardingPending, Task> persist,
        Func<Task> send)
    {
        if (RestoreRequested || InstallRequested || DiagnosticRebootRequested)
            throw new InvalidOperationException("Восстановление уже запрошено; повторная отправка запрещена.");
        RestoreRequested = true;
        Phase = "restore-requested";
        await persist(this).ConfigureAwait(false);
        try { await send().ConfigureAwait(false); }
        catch (Exception error) when (error is HttpRequestException or TimeoutException ||
            error is IOException and not ModemWebException)
        {
            throw new RestoreDeliveryUncertainException(error);
        }
    }
}

internal sealed class RestoreDeliveryUncertainException(Exception inner)
    : IOException("Связь прервалась при запросе восстановления; запрос не будет повторён.", inner);

/// <summary>
/// Measured root-access preparation and B31/B02 activation with a durable local journal. A restore request
/// and an installer request are never automatically repeated after uncertainty.
/// Passwords and the agent token never enter the journal or ordinary logs.
/// </summary>
public sealed partial class OnboardingEngine
{
    private const string B02FirmwareHash = "7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e";
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly Regex HashLinePattern = new("^[0-9a-f]{64}$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex InstallErrorPattern = new(@"(?:^|\n)INSTALL_ERROR ([A-Z][A-Z0-9_]{0,79})(?:\r?\n|$)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private readonly string _host;
    private readonly string _storage;
    private readonly string _resources;
    private readonly AdbTransport _adb;
    private readonly bool _skipFirmwareCheck;
    private readonly Action<string>? _progress;
    private string _lastAdbDiagnostic = "USB ADB не обнаружен.";
    private bool _diagnosticAccess;
    private bool _genericAccess;
    internal Func<ModemWebClient>? WebFactory { get; init; }
    internal Func<IRemoteShell>? ExistingSshFactory { get; init; }
    internal Func<IRemoteShell>? InstalledSshFactory { get; init; }
    internal string? ExistingKeyPath { get; init; }
    internal string? ExistingKnownHostsPath { get; init; }
    internal int ExistingPort { get; init; } = 2222;
    private string ReuseKeyPath => ExistingKeyPath ?? KeyPath;
    private string ReuseKnownHostsPath => ExistingKnownHostsPath ?? KnownHostsPath;
    private string BackupFolder => _diagnosticAccess ? "ADBAccessBackups" : "SetupBackups";
    private string PendingPath => Path.Combine(_storage, _diagnosticAccess ? "adb-access-pending.json" : "setup-pending.json");
    private string KeyPath => Path.Combine(_storage, "SSH", "id_ed25519");
    private string KnownHostsPath => Path.Combine(_storage, "SSH", "known_hosts");

    public OnboardingEngine(string host, string storageRoot, string resourcesRoot,
        AdbTransport adb, bool skipFirmwareCheck = false, Action<string>? progress = null)
    {
        WebTransport.ValidateIpv4(host);
        _host = host;
        _storage = Path.GetFullPath(storageRoot);
        _resources = Path.GetFullPath(resourcesRoot);
        _adb = adb;
        _skipFirmwareCheck = skipFirmwareCheck;
        _progress = progress;
    }

    public async Task<BackupKeyVerification> VerifyBackupKeyAsync(string webPassword, string manualOverride = "", CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(webPassword) || webPassword.Contains('\0'))
            throw new ArgumentException("Для проверки ключа бэкапа введите пароль Web.");
        var suffix = string.IsNullOrEmpty(manualOverride) ? KnownB31BackupSuffix : manualOverride;
        if (Encoding.UTF8.GetByteCount(suffix) > 128 || suffix.Contains('\0'))
            throw new ArgumentException("Некорректный Backup-key suffix.");
        Directory.CreateDirectory(_storage);
        using var localLock = new FileStream(Path.Combine(_storage,"operation.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        using var web = WebFactory?.Invoke() ?? new ModemWebClient(_host);
        await web.LoginAsync(webPassword,ct).ConfigureAwait(false);
        var identity = await web.GetIdentityAsync(skipFirmwareCheck:true,ct:ct).ConfigureAwait(false);
        var encrypted = await web.DownloadFreshBackupAsync(ct).ConfigureAwait(false);
        if (await web.GetIdentityAsync(skipFirmwareCheck:true,ct:ct).ConfigureAwait(false) != identity)
            throw new InvalidDataException("Устройство изменилось во время проверки бэкапа.");
        var directory = Path.Combine(_storage,"BackupKeyChecks",Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(directory);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(directory,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        await WritePrivateAsync(Path.Combine(directory,"back_parameter.original"),encrypted,ct).ConfigureAwait(false);
        await WriteJsonAsync(Path.Combine(directory,"identity.json"),identity,ct).ConfigureAwait(false);
        var hash = Sha(encrypted);
        await WriteJsonAsync(Path.Combine(directory,"manifest.json"),new { encryptedSHA256=hash,readOnly=true,formatVerified=false },ct).ConfigureAwait(false);
        int entries;
        try
        {
            var plain = BackupCipher.Decrypt(encrypted,identity.Imei+suffix);
            entries = BackupPatch.Inspect(plain).Inner.Members.Count;
        }
        catch (InvalidDataException)
        {
            // A format/key mismatch is not proof of firmware incompatibility.
            throw new InvalidDataException("Не удалось подтвердить ключ или формат архива бэкапа.");
        }
        var result = new BackupKeyVerification(ReportVersion(identity.Firmware),ReportVersion(identity.Inner),entries,hash,directory);
        await WriteJsonAsync(Path.Combine(directory,"manifest.json"),new { encryptedSHA256=hash,readOnly=true,formatVerified=true,entries=result.Entries },ct).ConfigureAwait(false);
        _progress?.Invoke($"Проверка бэкапа: {result.Firmware} / {result.InnerVersion}; entries={result.Entries}; SHA256={hash}");
        return result;
    }

    private static string ReportVersion(string value) => new(value.Select(c => char.IsControl(c) ? ' ' : c).ToArray());

    public async Task<OnboardingResult> PrepareAsync(string webPassword,
        string agentPassword, string backupKeySuffix, CancellationToken ct = default, bool forceReinstall = false, bool cleanComponents = false)
    {
        if (webPassword.Contains('\0'))
            throw new ArgumentException("Недопустимый пароль Web.", nameof(webPassword));
        Directory.CreateDirectory(_storage);
        using var localLock = new FileStream(Path.Combine(_storage, "operation.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        if (File.Exists(Path.Combine(_storage, "imei-pending.json")) ||
            File.Exists(Path.Combine(_storage, "pending.json")) ||
            File.Exists(Path.Combine(_storage, "system-restore-pending.json")) ||
            File.Exists(Path.Combine(_storage, "adb-access-pending.json")))
            throw new InvalidOperationException("Сначала завершите незавершённую операцию с модемом.");

        RejectReparsePoint(CleanupPendingPath);
        if (File.Exists(CleanupPendingPath) || Directory.Exists(CleanupPendingPath))
            return await ResumeComponentCleanupAsync(ct).ConfigureAwait(false);
        var savedPending = await LoadPendingAsync(ct).ConfigureAwait(false);
        if (cleanComponents && savedPending is { InstallRequested: true, CleanComponents: false, Phase: "ready" or "complete" })
        {
            if (string.IsNullOrEmpty(agentPassword) || agentPassword.Contains('\0'))
                throw new ArgumentException("Введите отдельный пароль агента для установки.", nameof(agentPassword));
            await FinishPriorReadyForReinstallAsync(savedPending, ct).ConfigureAwait(false);
            savedPending = null;
        }
        if (cleanComponents && savedPending is { CleanComponents: false })
            throw new InvalidDataException("Незавершённая подготовка ещё не готова к чистой переустановке.");
        cleanComponents = savedPending?.CleanComponents ?? cleanComponents;
        forceReinstall = savedPending?.ForceReinstall ?? (forceReinstall || cleanComponents);
        if (cleanComponents) _ = await ReadCleanupHelperAsync(ct).ConfigureAwait(false);
        if (savedPending is { Phase: "complete", InstallRequested: true, ForceReinstall: true, CleanComponents: true })
            return await ResumeCommittedCleanupAsync(savedPending, ct).ConfigureAwait(false);
        if(savedPending is null && !forceReinstall && await ProbeReadOnlySshAsync(ct).ConfigureAwait(false) is SshReadProof existingSsh)
            return new OnboardingResult(existingSsh.Cid,existingSsh.FirmwareHash,null,ReuseKeyPath,ReuseKnownHostsPath,true,"read-only-ssh",AccessOnly:true,Port:ExistingPort);
        var hashes = await VerifyAssetsAsync(ct).ConfigureAwait(false);
        _progress?.Invoke("Проверка Web и уже доступного root shell.");
        using var web = WebFactory?.Invoke() ?? new ModemWebClient(_host);
        WebIdentity? webIdentity = null;
        DeviceIdentity? existing = null;
        (string Serial, DeviceIdentity Identity)? match = null;
        var restoredUsbResume = false;
        if (savedPending is { RestoreRequested: true, InstallRequested: false, IdentitySource: "web-matched", WebIdentity: not null })
        {
            // A saved restoration can hand off through freshly matched USB without Web credentials.
            // No host/IP relationship is inferred from the old journal.
            match = await FindMatchingAdbAsync(savedPending.WebIdentity, ct).ConfigureAwait(false);
            restoredUsbResume = match is not null;
            if (!restoredUsbResume && string.IsNullOrEmpty(webPassword))
                throw new InvalidOperationException("Введите пароль штатного веб-интерфейса.");
        }
        if (restoredUsbResume)
            webIdentity = savedPending!.WebIdentity;
        else if (string.IsNullOrEmpty(webPassword))
        {
            // Explicit root-USB preparation does not contact Web or manufacture
            // absent vendor identity fields. Each later read repeats USB proof.
            match = await FindMatchingAdbAsync(null, ct).ConfigureAwait(false);
            if (match is null) throw new InvalidOperationException("Для установки без Web нужен единственный root USB ADB. Сначала проверьте устройство.");
            if (savedPending is null && !forceReinstall) existing = await ProbeExistingSshAsync(null, match.Value.Identity, agentPassword, ct).ConfigureAwait(false);
        }
        else
        {
            await web.LoginAsync(webPassword, ct).ConfigureAwait(false);
            webIdentity = await web.GetIdentityAsync(skipFirmwareCheck: true, ct: ct).ConfigureAwait(false);
            if (savedPending is null && !forceReinstall) existing = await ProbeExistingSshAsync(webIdentity, null, agentPassword, ct).ConfigureAwait(false);
            match = existing is null ? await FindMatchingAdbAsync(webIdentity, ct).ConfigureAwait(false) : null;
        }
        if (existing is not null && savedPending is null)
        {
            if (webIdentity is not null && await web.GetIdentityAsync(skipFirmwareCheck: true, ct: ct).ConfigureAwait(false) != webIdentity)
                throw new InvalidDataException("Устройство изменилось во время подтверждения доступа.");
            if (webIdentity is null && await ReadAdbIdentityAsync(match!.Value.Serial, null, ct).ConfigureAwait(false) != existing)
                throw new InvalidDataException("USB и SSH больше не подтверждают одно устройство.");
            var reusedProfile = ExistingAccessProfile(webIdentity, existing);
            _progress?.Invoke("Доступ SSH подтверждён. Существующий агент сохранён; функции модема отдельно не проверялись.");
            return new OnboardingResult(existing.Cid, existing.FirmwareHash, webIdentity?.Imei,
                KeyPath, KnownHostsPath, true, reusedProfile, AccessOnly: true);
        }
        if (string.IsNullOrEmpty(agentPassword) || agentPassword.Contains('\0'))
            throw new ArgumentException("Введите отдельный пароль агента для установки.", nameof(agentPassword));
        var rootAlreadyAvailable = existing is not null || match is not null;
        var genericAccess = rootAlreadyAvailable && InstallerProfile(webIdentity, existing ?? match!.Value.Identity) == "linux-arm64-access";
        var encrypted = Array.Empty<byte>();
        if (!restoredUsbResume && webIdentity is not null && await web.GetIdentityAsync(skipFirmwareCheck: true, ct: ct).ConfigureAwait(false) != webIdentity)
            throw new InvalidDataException("Устройство изменилось во время предварительной проверки.");
        var backupDirectory = Path.Combine(_storage, "SetupBackups", Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(backupDirectory);
        await WriteJsonAsync(Path.Combine(backupDirectory, "identity.json"), webIdentity, ct).ConfigureAwait(false);
        await WriteJsonAsync(Path.Combine(backupDirectory, "manifest.json"), new
        {
            suffixVerified = false, accessBackup = "fresh-encrypted-backup-if-restore-required",
        }, ct).ConfigureAwait(false);

        var pending = await LoadPendingAsync(ct).ConfigureAwait(false);
        if (pending is null)
        {
            pending = new OnboardingPending
            {
                Id = Guid.NewGuid().ToString("D"), WebIdentity = webIdentity,
                Intent = genericAccess ? "linux-arm64-access" : "preparation",
                IdentitySource = webIdentity is null ? "single-usb" : "web-matched",
                Cid = match?.Identity.Cid, BootId = match?.Identity.BootId,
                FirmwareHash = match?.Identity.FirmwareHash, RouterHash = match?.Identity.RouterHash,
                Profile = genericAccess ? "linux-arm64-access" : null,
                BackupDirectory = backupDirectory, ForceReinstall = forceReinstall, CleanComponents = cleanComponents,
            };
            await SavePendingAsync(pending, ct).ConfigureAwait(false);
        }
        else
        {
            if (pending.WebIdentity != webIdentity || pending.IdentitySource != (webIdentity is null ? "single-usb" : "web-matched") || !Guid.TryParse(pending.Id, out _))
                throw new InvalidDataException("Незавершённая настройка относится к другому устройству.");
            if (!pending.RestoreRequested && !pending.InstallRequested && !pending.DiagnosticRebootRequested)
            {
                pending.BackupDirectory = backupDirectory;
                await SavePendingAsync(pending, ct).ConfigureAwait(false);
            }
        }

        _progress?.Invoke("Проверка уже работающего USB ADB: транспорт, root и идентичность модема.");
        if (match is null)
            match = await EnsureAdbAsync(web, webIdentity ?? throw new InvalidDataException("Web identity is required for activation."), encrypted, pending, match, webPassword, backupKeySuffix, ct).ConfigureAwait(false);
        var (serial, identity) = match.Value;
        _progress?.Invoke("USB ADB подтверждён: root, ARM64 и идентичность модема совпали. Проверяется профиль установщика.");
        var profile = InstallerProfile(webIdentity, identity);
        _genericAccess = profile == "linux-arm64-access";
        if (_genericAccess) await VerifySingleUsbAsync(serial, ct).ConfigureAwait(false);
        if (pending.Cid is not null && pending.Cid != identity.Cid ||
            pending.FirmwareHash is not null && pending.FirmwareHash != identity.FirmwareHash ||
            pending.Profile is not null && pending.Profile != profile ||
            pending.RouterHash is not null && pending.RouterHash != identity.RouterHash ||
            profile == "linux-arm64-access" && pending.BootId is not null && pending.BootId != identity.BootId)
            throw new InvalidDataException("Устройство или профиль незавершённой установки изменился.");
        pending.Cid = identity.Cid;
        pending.AdbSerial = serial;
        pending.Intent = _genericAccess ? "linux-arm64-access" : "preparation";
        pending.Profile = profile;
        pending.FirmwareHash = identity.FirmwareHash;
        pending.RouterHash = identity.RouterHash;
        pending.BootId = identity.BootId;
        if (!pending.InstallRequested) pending.Phase = "adb-ready";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);

        if (!pending.CanStartInstallation)
            return await ResumeInstallationAsync(pending, serial, identity, webIdentity, agentPassword, ct)
                .ConfigureAwait(false);
        if (_genericAccess)
            await VerifyGenericTimeoutAsync(ct).ConfigureAwait(false);
        var installer = StrictUtf8.GetString(await File.ReadAllBytesAsync(
            Path.Combine(_resources, "Onboarding", "setup-agent.sh"), ct).ConfigureAwait(false));
        var policy = InstallerPolicy(identity, profile);
        var preflight = await AdbTextAsync(serial,
            "sh -c " + Quote(installer) + " -- " +
            string.Join(' ', InstallerArguments(pending, new[] { "--preflight" }.Concat(policy)).Select(Quote)),
            TimeSpan.FromSeconds(60), ct).ConfigureAwait(false);
        if (preflight != "INSTALL_PREFLIGHT " + profile + " imei_config=unknown")
            throw new InvalidDataException("Установщик не подтвердил предварительную проверку прошивки.");

        var publicKey = await CreateKeyAsync(ct).ConfigureAwait(false);
        var paths = InstallationPaths(pending);
        var stage = paths.Stage;
        var owner = string.Join(' ', new[] { pending.Id }.Concat(policy));
        if (await ReadAdbIdentityAsync(serial, webIdentity, ct).ConfigureAwait(false) != identity)
            throw new InvalidDataException("CID изменился перед передачей установщика.");
        if (await AdbTextAsync(serial, StagePreparationCommand(stage, owner),
                TimeSpan.FromSeconds(40), ct).ConfigureAwait(false) != "INSTALL_STAGE_READY")
            throw new InvalidDataException("Не подтверждён приватный каталог установки.");
        var credentialFile = Path.Combine(_storage, "SetupBackups", "credential-" + Guid.NewGuid().ToString("N"));
        try
        {
            await WritePrivateAsync(credentialFile, AgentStartup(agentPassword, profile, _host), ct).ConfigureAwait(false);
            foreach (var name in new[] { "zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh" })
                await PushStagedAsync(serial, Path.Combine(_resources, "Onboarding", name), stage,
                    name, owner, hashes[name], ct).ConfigureAwait(false);
            if (_genericAccess)
                await StageGenericTimeoutAsync(serial, stage, owner, ct).ConfigureAwait(false);
            await PushStagedAsync(serial, KeyPath + ".pub", stage, "id_ed25519.pub", owner,
                Sha(publicKey), ct).ConfigureAwait(false);
            await PushStagedAsync(serial, credentialFile, stage, "start-agent.sh", owner,
                Sha(await File.ReadAllBytesAsync(credentialFile, ct).ConfigureAwait(false)), ct)
                .ConfigureAwait(false);
        }
        finally { try { File.Delete(credentialFile); } catch { } }

        pending.RemoteStage = paths.Stage;
        pending.RemoteJournal = paths.Journal;
        pending.InstallRequested = true;
        pending.Phase = "install-requested";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
        await AdbTextAsync(serial, "set -eu; umask 077; set -C; printf '%s\\n' " +
            Quote(owner) + " > " + Quote(stage + "/.install-requested"), TimeSpan.FromSeconds(20), ct)
            .ConfigureAwait(false);
        var arguments = new[] { stage + "/setup-agent.sh" }.Concat(InstallerArguments(pending,
            new[] { stage, identity.Cid, hashes["zte-agent"], hashes["dropbear"], Sha(publicKey) }.Concat(policy.Skip(1)))).ToArray();
        string installOutput;
        try
        {
            installOutput = await AdbTextAsync(serial, "sh " + string.Join(' ', arguments.Select(Quote)),
                TimeSpan.FromSeconds(100), ct).ConfigureAwait(false);
        }
        catch (Exception) when (pending.ForceReinstall && !ct.IsCancellationRequested)
        {
            if (await ArchiveVerifiedRollbackAsync(pending, serial, identity, webIdentity, ct).ConfigureAwait(false))
                throw new InvalidOperationException(RollbackVerifiedMessage);
            throw;
        }
        await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "installation.log"),
            Encoding.UTF8.GetBytes(installOutput), ct).ConfigureAwait(false);
        var expectedJournal = paths.Journal;
        if (!installOutput.Split('\n').Contains("INSTALL_READY " + expectedJournal))
            throw new InvalidDataException("Установщик не подтвердил готовность.");
        pending.RemoteJournal = expectedJournal;
        pending.NewAgent = CredentialOrigin(installOutput);
        pending.Phase = "ready";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);

        var verified = await PinAndVerifySshAsync(pending, serial, identity, webIdentity, agentPassword, ct)
            .ConfigureAwait(false);
        await CommitIfReadyAsync(pending, verified, agentPassword, ct).ConfigureAwait(false);
        if (pending.CleanComponents) await SaveComponentCleanupIntentAsync(pending, verified, ct).ConfigureAwait(false);
        else await FinishAsync(pending, ct).ConfigureAwait(false);
        await CleanupStageAsync(serial, stage, ct).ConfigureAwait(false);
        if (pending.CleanComponents) return await ResumeComponentCleanupAsync(ct).ConfigureAwait(false);
        return new OnboardingResult(identity.Cid, identity.FirmwareHash, webIdentity?.Imei,
            KeyPath, KnownHostsPath, false, InstallerProfile(webIdentity, identity));
    }

    public Task<AdbAccessResult> EnableDiagnosticAdbAsync(string webPassword, string backupKeySuffix = "",
        DeviceIdentity? expectedIdentity = null, string? expectedImei = null, CancellationToken ct = default)
    {
        var diagnostic = new OnboardingEngine(_host, _storage, _resources, _adb, skipFirmwareCheck: _skipFirmwareCheck, progress: _progress)
        { _diagnosticAccess = true, WebFactory = WebFactory };
        return diagnostic.EnableDiagnosticAdbCoreAsync(webPassword, backupKeySuffix, expectedIdentity, expectedImei, ct);
    }

    private async Task<AdbAccessResult> EnableDiagnosticAdbCoreAsync(string webPassword, string backupKeySuffix,
        DeviceIdentity? expectedIdentity, string? expectedImei, CancellationToken ct)
    {
        if ((string.IsNullOrEmpty(webPassword) && !File.Exists(PendingPath)) || webPassword.Contains('\0'))
            throw new ArgumentException("Введите пароль штатного веб-интерфейса.", nameof(webPassword));
        Directory.CreateDirectory(_storage);
        using var localLock = new FileStream(Path.Combine(_storage, "operation.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        using var imeiLock = new FileStream(Path.Combine(_storage,"imei-operation.lock"),
            FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        foreach (var competing in new[] { "setup-pending.json", "imei-pending.json", "pending.json", "system-restore-pending.json" })
            if (File.Exists(Path.Combine(_storage, competing)))
                throw new InvalidOperationException("Сначала завершите незавершённую подготовку или восстановление модема.");
        await VerifyToolHashAsync(Path.Combine(_resources, "Tools", "adb.exe"),
            "b4a6b455702684652cccf7b46258b29e653538904359a58fd4931cf3ef286b3f", ct).ConfigureAwait(false);
        var pending = await LoadPendingAsync(ct).ConfigureAwait(false);
        using var web = WebFactory?.Invoke() ?? new ModemWebClient(_host);
        WebIdentity webIdentity;
        if (pending?.RestoreRequested == true || pending?.DirectAdbRequested == true || pending?.DiagnosticRebootRequested == true)
        {
            // Restore is already committed locally. Resume observation only, even
            // if rebooting firmware has not brought the Web service back yet.
            webIdentity = pending.WebIdentity ?? throw new InvalidDataException("Diagnostic journal has no Web identity.");
            _progress?.Invoke("Продолжение проверки ADB после восстановления: повторная отправка не выполняется.");
        }
        else
        {
            _progress?.Invoke("Диагностический ADB: вход в Web и сверка модема.");
            await web.LoginAsync(webPassword, ct).ConfigureAwait(false);
            webIdentity = await web.GetIdentityAsync(skipFirmwareCheck: true, ct).ConfigureAwait(false);
        }
        if (expectedImei is not null && expectedImei != webIdentity.Imei || pending is not null && pending.WebIdentity != webIdentity)
            throw new InvalidDataException("Web относится к другому модему; включение ADB остановлено.");
        void CheckIdentity(DeviceIdentity identity)
        {
            if (expectedIdentity is not null && (identity.Cid != expectedIdentity.Cid || identity.FirmwareHash != expectedIdentity.FirmwareHash) ||
                pending?.Cid is not null && identity.Cid != pending.Cid ||
                pending?.FirmwareHash is not null && identity.FirmwareHash != pending.FirmwareHash)
                throw new InvalidDataException("CID или прошивка диагностического ADB не совпали с ожидаемым модемом.");
        }
        async Task ConfirmAsync((string Serial, DeviceIdentity Identity) found)
        {
            CheckIdentity(found.Identity);
            var confirmed = await FindMatchingAdbAsync(webIdentity, ct).ConfigureAwait(false);
            if (confirmed is null || confirmed.Value != found)
                throw new InvalidDataException("USB, CID или boot ID изменились при окончательной проверке ADB.");
            CheckIdentity(confirmed.Value.Identity);
            if (pending is not null)
            {
                pending.Cid = found.Identity.Cid;
                pending.FirmwareHash = found.Identity.FirmwareHash;
                pending.AdbSerial = found.Serial;
                pending.Phase = "adb-ready";
                await FinishAsync(pending, ct).ConfigureAwait(false);
            }
        }
        var match = await FindMatchingAdbAsync(webIdentity, ct).ConfigureAwait(false);
        if (match is not null)
        {
            await ConfirmAsync(match.Value).ConfigureAwait(false);
            _progress?.Invoke("Диагностический root ADB уже доступен. Изменения модема не требуются.");
            return new AdbAccessResult(match.Value.Serial, match.Value.Identity, webIdentity, true);
        }
        if (pending?.RestoreRequested == true || pending?.DiagnosticRebootRequested == true)
        {
            match = await WaitForAdbAsync(webIdentity, ct).ConfigureAwait(false);
            await ConfirmAsync(match.Value).ConfigureAwait(false);
            return new AdbAccessResult(match.Value.Serial, match.Value.Identity, webIdentity, false);
        }
        var directAlreadyWaited = false;
        if (pending?.DirectAdbRequested == true)
        {
            match = await TryWaitForAdbAsync(webIdentity, TimeSpan.FromSeconds(90), ct).ConfigureAwait(false);
            if (match is not null)
            {
                await ConfirmAsync(match.Value).ConfigureAwait(false);
                return new AdbAccessResult(match.Value.Serial, match.Value.Identity, webIdentity, false);
            }
            directAlreadyWaited = true;
            await web.LoginAsync(webPassword, ct).ConfigureAwait(false);
            if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                throw new InvalidDataException("Устройство изменилось после переключения USB.");
        }
        if (expectedIdentity is not null && expectedImei is null)
            throw new InvalidDataException("Для включения ADB сначала подтвердите связь ожидаемого CID и IMEI через SSH.");
        if (pending is null)
        {
            var directory = Path.Combine(_storage, BackupFolder, Guid.NewGuid().ToString("D"));
            Directory.CreateDirectory(directory);
            pending = new OnboardingPending { Intent = "diagnostic-adb", Id = Guid.NewGuid().ToString("D"),
                WebIdentity = webIdentity, BackupDirectory = directory, Cid = expectedIdentity?.Cid, FirmwareHash = expectedIdentity?.FirmwareHash };
        }
        var encrypted = Array.Empty<byte>();
        await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "identity.json"), webIdentity, ct).ConfigureAwait(false);
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
        // One known USB method precedes backup-template validation; neither method depends on a version name.
        match = await EnsureAdbAsync(web, webIdentity, encrypted, pending, match, webPassword, backupKeySuffix, ct, directAlreadyWaited).ConfigureAwait(false);
        await ConfirmAsync(match.Value).ConfigureAwait(false);
        _progress?.Invoke("Диагностический root ADB подтверждён. Агент и SSH не изменялись.");
        return new AdbAccessResult(match.Value.Serial, match.Value.Identity, webIdentity, false);
    }

    private async Task<(string Serial, DeviceIdentity Identity)> EnsureAdbAsync(
        ModemWebClient web, WebIdentity webIdentity, byte[] encrypted, OnboardingPending pending,
        (string Serial, DeviceIdentity Identity)? match, string webPassword, string backupKeySuffix, CancellationToken ct, bool directAlreadyWaited = false)
    {
        if (match is null && pending.CanRequestDirectAdb)
        {
            bool? advertised = null;
            try { advertised = await web.AdvertisesUsbDebugAsync(ct).ConfigureAwait(false); }
            catch (Exception error) when (error is HttpRequestException or IOException or TimeoutException)
            { _progress?.Invoke("Список штатных USB-команд недоступен; будет проверена одна известная команда USB debug."); }
            if (advertised != false)
            {
                _progress?.Invoke("Способ 1: штатное переключение USB в debug; запрос отправляется один раз.");
                if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось перед переключением USB.");
                await pending.RequestDirectAdbOnceAsync(value => SavePendingAsync(value, ct),
                    () => web.RequestUsbDebugAsync(ct)).ConfigureAwait(false);
                _progress?.Invoke(pending.DirectAdbOutcome switch
                {
                    "accepted" => "USB debug: запрос принят. Проверяется появление root ADB.",
                    "rejected" => "USB debug: модем отклонил запрос. Проверяется фактическое состояние ADB.",
                    _ => "USB debug: ответ не подтверждён. Запрос не повторяется; проверяется состояние ADB.",
                });
            }
            else _progress?.Invoke("Способ 1 пропущен: прошивка не объявляет штатное переключение USB в debug.");
        }
        if (match is null && !directAlreadyWaited && pending.DirectAdbRequested && !pending.RestoreRequested && !pending.InstallRequested && !pending.DiagnosticRebootRequested)
            match = await TryWaitForAdbAsync(webIdentity, TimeSpan.FromSeconds(90), ct).ConfigureAwait(false);
        // Only a fully validated archive/template may reach restore. A working ADB
        // channel or successful debug switch does not depend on a backup key.
        if (match is null && !pending.RestoreRequested && !pending.InstallRequested && !pending.DiagnosticRebootRequested)
        {
            _progress?.Invoke("Способ 2: проверка ключа, структуры бэкапа и шаблона rc.local для включения USB ADB.");
            // A fresh authenticated identity and encrypted backup are needed only
            // when the previous methods did not produce a bound root channel.
            if (pending.DirectAdbRequested) await web.LoginAsync(webPassword, ct).ConfigureAwait(false);
            if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                throw new InvalidDataException("Устройство изменилось перед получением бэкапа.");
            encrypted = await web.DownloadFreshBackupAsync(ct).ConfigureAwait(false);
            if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                throw new InvalidDataException("Устройство изменилось при обновлении бэкапа.");
            var sourceBackup = pending.DirectAdbRequested ? "back_parameter.after-direct.original" : "back_parameter.original";
            await WritePrivateAsync(Path.Combine(pending.BackupDirectory, sourceBackup), encrypted, ct).ConfigureAwait(false);
            await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "manifest.json"), new
            {
                encryptedSHA256 = Sha(encrypted), suffixVerified = false,
                sourceBackupFile = sourceBackup,
            }, ct).ConfigureAwait(false);
            var resolvedSuffix = ResolveBackupKeySuffix(webIdentity, backupKeySuffix);
            var patch = BackupPatch.Prepare(encrypted, webIdentity.Imei, resolvedSuffix);
            await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "manifest.json"), new
            {
                encryptedSHA256 = patch.OriginalHash, patchedSHA256 = patch.PatchedHash,
                suffixVerified = true, adbAlreadyEnabled = patch.AlreadyEnabled,
                sourceBackupFile = pending.DirectAdbRequested ? "back_parameter.after-direct.original" : "back_parameter.original",
            }, ct).ConfigureAwait(false);
            if (pending.CanRequestRestore(false, patch.AlreadyEnabled))
            {
                if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось перед включением ADB.");
                await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "back_parameter.adb-only"),
                    patch.PatchedEncrypted, ct).ConfigureAwait(false);
                await web.UploadBackupAsync(patch.PatchedEncrypted, ct).ConfigureAwait(false);
                if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось перед восстановлением веб-бэкапа.");
                try
                {
                    _progress?.Invoke("Восстановление проверенного ADB-only бэкапа: модем может перезагрузиться. Ожидается root USB ADB.");
                    await pending.RequestRestoreOnceAsync(
                        value => SavePendingAsync(value, ct),
                        () => web.RestoreBackupAsync(ct)).ConfigureAwait(false);
                }
                catch (RestoreDeliveryUncertainException)
                {
                    // A disconnected HTTP request may already have started restore.
                    // Wait for ADB; do not submit the same restore again.
                }
            }
            else if (_diagnosticAccess && patch.AlreadyEnabled && !pending.DiagnosticRebootRequested)
            {
                if (await web.GetIdentityAsync(true, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось перед диагностической перезагрузкой.");
                _progress?.Invoke("В проверенном бэкапе уже есть включение ADB. Запрашивается одна штатная перезагрузка без восстановления бэкапа.");
                await pending.RequestDiagnosticRebootOnceAsync(value => SavePendingAsync(value, ct),
                    () => web.RebootDeviceAsync(ct)).ConfigureAwait(false);
            }
            else _progress?.Invoke("В rc.local уже есть включение ADB. Повторное восстановление не требуется; проверяются USB и драйвер.");
        }
        return match ?? await WaitForAdbAsync(webIdentity, ct).ConfigureAwait(false);
    }

    // Known firmware-family candidate; only full archive/template validation authorizes a restore.
    private const string KnownB31BackupSuffix = "zteSDX75*11Mbb2@1";
    internal static string ResolveBackupKeySuffix(WebIdentity identity, string supplied)
    {
        if (!string.IsNullOrEmpty(supplied)) return supplied;
        return KnownB31BackupSuffix;
    }

    private static bool IsB31(WebIdentity identity) => identity.Firmware == "CN_ZTE_MU5250V1.0.0B31" &&
        identity.Inner == "BD_CNMU5250V1.0.0B31";

    internal static string[] InstallerPolicy(DeviceIdentity device, string profile) =>
        profile == "linux-arm64-access" ? [device.Cid, profile, device.FirmwareHash, device.RouterHash, device.BootId] : [device.Cid, profile, device.FirmwareHash, device.RouterHash];

    internal string InstallerProfile(WebIdentity? web, DeviceIdentity device)
    {
        if (web is not null && IsB31(web) && device.FirmwareHash == ImeiEngine.FirmwareHash && device.RouterHash == ImeiEngine.RouterHash) return "b31";
        if (web is not null && _skipFirmwareCheck && web.Firmware == "STD_PL_MU5250V1.0.0B02" &&
            web.Inner == "BD_STDPLMU5250V1.0.0B02" && device.FirmwareHash == B02FirmwareHash && device.RouterHash == ImeiEngine.RouterHash)
            return "b02-experimental";
        return "linux-arm64-access";
    }

    internal const string GenericTimeoutSha256 = "6e81024c273080294a251ae38572f1ef0cb496fbd16c7009c6a4ae1c07fb55ff";
    internal async Task VerifyGenericTimeoutAsync(CancellationToken ct)
    {
        var path = Path.Combine(_resources, "HostTools", "zte-timeout");
        RejectReparsePoint(path);
        var bytes = await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false);
        if (Sha(bytes) != GenericTimeoutSha256)
            throw new InvalidDataException("Повреждён компонент ограниченного ожидания установщика.");
    }

    internal async Task StageGenericTimeoutAsync(string serial, string stage, string owner, CancellationToken ct)
    {
        // Verify again immediately before transfer; remote staging verifies the
        // same digest before installer dispatch, even if the local file changes.
        await VerifyGenericTimeoutAsync(ct).ConfigureAwait(false);
        await PushStagedAsync(serial, Path.Combine(_resources, "HostTools", "zte-timeout"), stage,
            "zte-timeout", owner, GenericTimeoutSha256, ct).ConfigureAwait(false);
    }

    private async Task<Dictionary<string, string>> VerifyAssetsAsync(CancellationToken ct)
    {
        var basePath = Path.Combine(_resources, "Onboarding");
        var hashPath = Path.Combine(basePath, "SHA256.json");
        var hashes = JsonSerializer.Deserialize<Dictionary<string, string>>(
            await File.ReadAllBytesAsync(hashPath, ct).ConfigureAwait(false))
            ?? throw new InvalidDataException("Манифест компонентов настройки пуст.");
        var required = new[] { "zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh" };
        // The release also ships provenance and license files. Only these four
        // executable/setup components are uploaded by onboarding.
        if (!required.All(hashes.ContainsKey))
            throw new InvalidDataException("Неполный манифест компонентов настройки.");
        if (hashes["zte-agent"] != AgentPackage.Sha256)
            throw new InvalidDataException("Комплект настройки содержит другую сборку агента.");
        foreach (var name in required)
        {
            var bytes = await File.ReadAllBytesAsync(Path.Combine(basePath, name), ct).ConfigureAwait(false);
            if (Sha(bytes) != hashes[name]) throw new InvalidDataException("Повреждён компонент настройки: " + name);
            if (name == "zte-agent") AgentPackage.VerifyPayload(bytes);
        }
        await VerifyToolHashAsync(Path.Combine(_resources, "Tools", "adb.exe"),
            "b4a6b455702684652cccf7b46258b29e653538904359a58fd4931cf3ef286b3f", ct)
            .ConfigureAwait(false);
        await VerifyToolHashAsync(Path.Combine(_resources, "Tools", "OpenSSH", "ssh-keygen.exe"),
            "b51fdd26be0f7c83398d18e5354a0acb0406a9de25516791758fe63bbe3ae870", ct)
            .ConfigureAwait(false);
        return hashes;
    }

    private static async Task VerifyToolHashAsync(string path, string expected, CancellationToken ct)
    {
        var bytes = await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false);
        if (Sha(bytes) != expected) throw new InvalidDataException("Повреждён встроенный инструмент: " + Path.GetFileName(path));
    }

    private string ExistingAccessProfile(WebIdentity? web, DeviceIdentity device) =>
        web is null && device.FirmwareHash == ImeiEngine.FirmwareHash && device.RouterHash == ImeiEngine.RouterHash
            ? "b31" : InstallerProfile(web, device);

    private async Task<SshReadProof?> ProbeReadOnlySshAsync(CancellationToken ct)
    {
        if(!File.Exists(ReuseKeyPath)||!File.Exists(ReuseKnownHostsPath))return null;
        var ssh=ExistingSshFactory?.Invoke()??new SshTransport(_host,ExistingPort,ReuseKeyPath,ReuseKnownHostsPath);
        RemoteResult first;
        try{first=await ssh.RunAsync(SshReadProof.Command,timeout:TimeSpan.FromSeconds(15),ct:ct).ConfigureAwait(false);}
        catch(SshTrustException){throw;}
        catch(Exception error)when(error is SocketException or IOException or TimeoutException){return null;}
        if(first.ExitCode is 255 or -1)return null;
        if(!first.Success)throw new InvalidDataException("Не удалось проверить существующий сеанс SSH.");
        var proof=SshReadProof.Parse(first.Stdout);
        proof.Verify(await SshReadProof.ReadAsync(ssh,ct).ConfigureAwait(false));
        _progress?.Invoke("SSH проверен. Установка агента доступна отдельно.");
        return proof;
    }

    private async Task<DeviceIdentity?> ProbeExistingSshAsync(WebIdentity? web, DeviceIdentity? usbIdentity,
        string agentPassword, CancellationToken ct)
    {
        if (!File.Exists(KeyPath) || !File.Exists(KnownHostsPath)) return null;
        var ssh = ExistingSshFactory?.Invoke() ?? new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        var identityCommand = web is null ? AccessIdentity.Command : IdentityCommand();
        RemoteResult reply;
        try { reply = await ssh.RunAsync(identityCommand, timeout: TimeSpan.FromSeconds(15), ct: ct).ConfigureAwait(false); }
        catch (SshTrustException) { throw; }
        catch (Exception error) when (error is SocketException or IOException or TimeoutException) { return null; }
        if (reply.ExitCode is 255 or -1) return null;
        if (!reply.Success) throw new InvalidDataException("SSH отвечает, но не подтвердил root и идентификацию.");
        var proof = web is null ? AccessIdentity.Parse(reply.Stdout) : ParseIdentity(reply.Stdout, web, requireInstallerRouter: false);
        if (usbIdentity is not null && usbIdentity != proof)
            throw new InvalidDataException("USB и SSH относятся к разным устройствам.");
        var after = await ssh.RunAsync(identityCommand, timeout: TimeSpan.FromSeconds(20), ct: ct).ConfigureAwait(false);
        if (!after.Success || (web is null ? AccessIdentity.Parse(after.Stdout) : ParseIdentity(after.Stdout, web, requireInstallerRouter: false)) != proof)
            throw new InvalidDataException("Идентичность SSH-модема изменилась во время входа.");
        return proof;
    }

    internal async Task<(string Serial, DeviceIdentity Identity)?> FindMatchingAdbAsync(
        WebIdentity? web, CancellationToken ct, bool tolerateDiscoveryFailure = false)
    {
        IReadOnlyList<AdbDevice> devices;
        try
        {
            var inventory = await _adb.InspectUsbAsync(ct).ConfigureAwait(false);
            devices = inventory.ReadyDevices;
            _lastAdbDiagnostic = inventory.UnavailableReason;
        }
        catch (Exception error) when (tolerateDiscoveryFailure && (error is TimeoutException || error is IOException and not FileNotFoundException))
        { _lastAdbDiagnostic = error.Message; return null; }
        if (web is null && devices.Count != 1)
            throw new InvalidOperationException("Для установки без Web оставьте единственное USB ADB-устройство.");
        var matches = new List<(string, DeviceIdentity)>();
        foreach (var device in devices)
        {
            try
            {
                var identity = await ReadAdbIdentityAsync(device.Serial, web, ct).ConfigureAwait(false);
                matches.Add((device.Serial, identity));
            }
            catch (Exception error) when (error is IOException or InvalidDataException or TimeoutException or JsonException)
            { _lastAdbDiagnostic = "USB ADB найден, но root и идентичность нужного модема не подтверждены: " + error.Message; }
        }
        if (matches.Count > 1)
            throw new InvalidOperationException("Несколько USB-модемов совпали с ожидаемым устройством.");
        return matches.Count == 1 ? matches[0] : null;
    }

    private async Task<(string Serial, DeviceIdentity Identity)> WaitForAdbAsync(
        WebIdentity web, CancellationToken ct)
    {
        var match = await TryWaitForAdbAsync(web, TimeSpan.FromMinutes(4), ct).ConfigureAwait(false);
        return match ?? throw new TimeoutException(_lastAdbDiagnostic + " Включение ADB и восстановление не повторяются автоматически; исправьте подключение и продолжите подготовку.");
    }

    private async Task<(string Serial, DeviceIdentity Identity)?> TryWaitForAdbAsync(
        WebIdentity web, TimeSpan timeout, CancellationToken ct)
    {
        var timer = Stopwatch.StartNew();
        var lastProgress = TimeSpan.MinValue;
        string? previous = null;
        while (timer.Elapsed < timeout)
        {
            var match = await FindMatchingAdbAsync(web, ct, tolerateDiscoveryFailure: true).ConfigureAwait(false);
            if (match is not null) return match.Value;
            if (previous != _lastAdbDiagnostic || timer.Elapsed - lastProgress >= TimeSpan.FromSeconds(15))
            {
                _progress?.Invoke("Ожидание USB ADB: " + _lastAdbDiagnostic);
                previous = _lastAdbDiagnostic;
                lastProgress = timer.Elapsed;
            }
            await Task.Delay(TimeSpan.FromSeconds(3), ct).ConfigureAwait(false);
        }
        return null;
    }

    private async Task<DeviceIdentity> ReadAdbIdentityAsync(string serial,
        WebIdentity? web, CancellationToken ct)
    {
        if (web is null || _genericAccess) await VerifySingleUsbAsync(serial, ct).ConfigureAwait(false);
        var reply = await _adb.ShellAsync(serial, web is null ? AccessIdentity.Command : IdentityCommand(), TimeSpan.FromSeconds(20), ct)
            .ConfigureAwait(false);
        if (!reply.Success) throw new InvalidDataException("USB ADB не подтвердил root и идентификацию модема.");
        return web is null ? AccessIdentity.Parse(reply.Stdout) : ParseIdentity(reply.Stdout, web, requireInstallerRouter: false);
    }

    private async Task VerifySingleUsbAsync(string expectedSerial, CancellationToken ct)
    {
        var selected = await _adb.SelectSingleUsbSerialAsync(ct).ConfigureAwait(false);
        var proof = await _adb.RunAsync(["-d", "get-serialno"], TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);
        if (selected != expectedSerial || !proof.Success || proof.Stdout.Length > 1024 || StrictUtf8.GetString(proof.Stdout).Trim() != expectedSerial)
            throw new InvalidDataException("Выбранное единственное USB-устройство изменилось.");
    }

    private static string IdentityCommand() => AccessIdentity.Command + "\nubus call zwrt_web device_info '{}'";

    internal static DeviceIdentity ParseIdentity(byte[] bytes, WebIdentity web, bool requireInstallerRouter = true)
    {
        if (bytes.Length > 65536) throw new InvalidDataException("Слишком большой ответ идентификации.");
        var lines = AdbShellOutput.NormalizeText(StrictUtf8.GetString(bytes)).Split('\n');
        if (lines.Length < 5) throw new InvalidDataException("Неполная идентификация модема.");
        var measured = AccessIdentity.Parse(Encoding.UTF8.GetBytes(string.Join('\n', lines.Take(4))));
        using var document = JsonDocument.Parse(string.Join('\n', lines.Skip(4)));
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            root.GetProperty("imei").GetString() != web.Imei ||
            root.GetProperty("integrate_version").GetString() != web.Firmware ||
            root.GetProperty("wa_inner_version").GetString() != web.Inner)
            throw new InvalidDataException("USB/SSH и Web относятся к разным устройствам.");
        if (requireInstallerRouter && (measured.RouterHash != ImeiEngine.RouterHash || measured.FirmwareHash == "absent"))
            throw new InvalidOperationException("Этот профиль требует подтверждённый diag-router; допуск к доступу проверяется отдельно.");
        return measured;
    }

    private async Task<string> AdbTextAsync(string serial, string command,
        TimeSpan timeout, CancellationToken ct)
    {
        var reply = await _adb.ShellAsync(serial, command, timeout, ct).ConfigureAwait(false);
        if (!reply.Success)
        {
            // Never show raw ADB output: installer scripts may handle credentials.
            // Only known, bounded diagnostics are classified for the UI.
            var diagnostic = Encoding.UTF8.GetString(reply.Stderr.AsSpan(0, Math.Min(reply.Stderr.Length, 16 * 1024))) +
                "\n" + Encoding.UTF8.GetString(reply.Stdout.AsSpan(0, Math.Min(reply.Stdout.Length, 16 * 1024)));
            var install = InstallErrorPattern.Match(AdbShellOutput.NormalizeText(diagnostic));
            if (install.Success)
                throw new IOException("Установщик модема остановлен: " + install.Groups[1].Value +
                    " (код " + reply.ExitCode + ").");
            if (diagnostic.Contains("FIRMWARE_MISMATCH", StringComparison.Ordinal))
                throw new InvalidDataException("Прошивка модема не соответствует выбранному профилю.");
            if (diagnostic.Contains("mkdir:", StringComparison.Ordinal) &&
                diagnostic.Contains("No such file or directory", StringComparison.Ordinal))
                throw new IOException("Не удалось создать каталог установки на модеме: отсутствует родительский каталог.");
            throw new IOException("Модем отклонил ADB-команду; код " + reply.ExitCode + ".");
        }
        return AdbShellOutput.NormalizeText(StrictUtf8.GetString(reply.Stdout)).Trim();
    }

    private static string Quote(string text) => "'" + text.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
    private static string Sha(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    internal static byte[] AgentStartup(string password, string profile = "b31", string host = "192.168.0.1")
    {
        WebTransport.ValidateIpv4(host);
        var text = "#!/bin/sh\nexport ZTE_AGENT_PASSWORD=" + Quote(password) +
            (profile == "linux-arm64-access" ? "\nexport ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND=" + Quote(host + ":9090") : "\nunset ZTE_AGENT_MODE\nunset ZTE_AGENT_BIND") +
            "\nunset ZTE_AGENT_PIN\ntrap '' HUP\n" +
            "nohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &\n";
        return Encoding.UTF8.GetBytes(text);
    }

    internal static (string Stage, string Journal, string DropbearKey) InstallationPaths(OnboardingPending pending)
    {
        if (!Guid.TryParseExact(pending.Id, "D", out _)) throw new InvalidDataException("Повреждён журнал незавершённой установки.");
        var currentStage = "/data/zte-imei-studio/stage-" + pending.Id;
        var currentJournal = "/data/zte-imei-studio/installations/" + pending.Id;
        var legacyStage = "/data/local/tmp/zte-imei-setup-" + pending.Id;
        var legacyJournal = "/data/local/tmp/zte-imei-installations/" + pending.Id;
        if (!pending.InstallRequested)
        {
            if (pending.RemoteStage is not null || pending.RemoteJournal is not null)
                throw new InvalidDataException("Повреждён журнал незавершённой установки.");
            return (currentStage, currentJournal, "/data/zte-imei-studio/bin/dropbearkey");
        }
        // Old pending files did not contain RemoteStage. Never move/replay an already requested install.
        var legacy = pending.RemoteStage is null || pending.RemoteStage == legacyStage;
        var stage = legacy ? legacyStage : currentStage;
        var journal = legacy ? legacyJournal : currentJournal;
        if ((pending.RemoteStage is not null && pending.RemoteStage != stage) ||
            (pending.RemoteJournal is not null && pending.RemoteJournal != journal))
            throw new InvalidDataException("Повреждён журнал незавершённой установки.");
        return (stage, journal, legacy ? "/data/bin/dropbearkey" : "/data/zte-imei-studio/bin/dropbearkey");
    }

    private static string StagePreparationCommand(string stage, string owner) => $$"""
        set -eu
        umask 077
        stage={{Quote(stage)}}; owner={{Quote(owner)}}
        fail() { printf 'INSTALL_ERROR STAGE_%s\n' "$1" >&2; exit 1; }
        safe_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail DIRECTORY; mode=$(stat -c %a "$1"); case "$mode" in ''|*[!0-7]*) fail MODE;; esac; test "$((0$mode & 0022))" = 0 || fail MODE; }
        safe_dir /data
        anchor=/data/zte-imei-studio
        if test ! -e "$anchor" && test ! -L "$anchor"; then mkdir -m 700 "$anchor"; fi
        safe_dir "$anchor"
        test "$(stat -c %a "$anchor")" = 700 || fail MODE
        if test ! -e "$stage" && test ! -L "$stage"; then
          mkdir -m 700 "$stage"
          printf '%s\n' "$owner" > "$stage/.owner"
        fi
        safe_dir "$stage"
        test "$(stat -c %a "$stage")" = 700 || fail MODE
        test -f "$stage/.owner" && test ! -L "$stage/.owner" && test "$(stat -c %u:%a:%h "$stage/.owner")" = 0:600:1 || fail OWNER_FILE
        test "$(cat "$stage/.owner")" = "$owner" || fail OWNER
        test ! -e "$stage/.install-requested" && test ! -L "$stage/.install-requested" || fail INSTALL_REQUESTED
        printf 'INSTALL_STAGE_READY\n'
        """;

    private async Task PushStagedAsync(string serial, string local, string stage,
        string name, string owner, string expectedHash, CancellationToken ct)
    {
        var incoming = stage + "/incoming-" + Guid.NewGuid().ToString("D");
        var destination = stage + "/" + name;
        await _adb.PushAsync(serial, local, incoming, TimeSpan.FromSeconds(90), ct).ConfigureAwait(false);
        var command = "set -eu; test -d " + Quote(stage) + "; test ! -L " + Quote(stage) +
            "; test \"$(cat " + Quote(stage + "/.owner") + ")\" = " + Quote(owner) +
            "; test ! -e " + Quote(stage + "/.install-requested") +
            "; test -f " + Quote(incoming) + "; test ! -L " + Quote(incoming) +
            "; test \"$(stat -c %h " + Quote(incoming) + ")\" = 1; " +
            "test \"$(sha256sum " + Quote(incoming) + " | cut -d ' ' -f1)\" = " + Quote(expectedHash) +
            "; test ! -L " + Quote(destination) +
            "; if test -e " + Quote(destination) + "; then test -f " + Quote(destination) +
            "; test \"$(stat -c %h " + Quote(destination) + ")\" = 1; fi; mv " +
            Quote(incoming) + " " + Quote(destination);
        await AdbTextAsync(serial, command, TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
    }

    private async Task<byte[]> CreateKeyAsync(CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(KeyPath)!);
        RejectReparsePoint(Path.GetDirectoryName(KeyPath)!);
        if (OperatingSystem.IsWindows()) ProtectPrivateDirectory(Path.GetDirectoryName(KeyPath)!);
        RejectReparsePoint(KeyPath);
        RejectReparsePoint(KeyPath + ".pub");
        var keygen = Path.Combine(_resources, "Tools", "OpenSSH", "ssh-keygen.exe");
        if (!File.Exists(KeyPath))
        {
            if (File.Exists(KeyPath + ".pub"))
                throw new InvalidDataException("Найдена неполная пара SSH-ключей; она не перезаписана.");
            await RunKeygenAsync(keygen, ["-q", "-t", "ed25519", "-N", "", "-C", "ZTE IMEI Studio", "-f", KeyPath], ct)
                .ConfigureAwait(false);
        }
        ProtectPrivateFile(KeyPath);
        var output = await RunKeygenAsync(keygen, ["-y", "-f", KeyPath], ct).ConfigureAwait(false);
        var fields = StrictUtf8.GetString(output).Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 2 || fields[0] != "ssh-ed25519" || !ValidEd25519Key(fields[1]))
            throw new InvalidDataException("Собственный SSH-ключ приложения имеет неверный формат.");
        var publicKey = Encoding.UTF8.GetBytes("ssh-ed25519 " + fields[1] + " ZTE IMEI Studio\n");
        await WritePrivateAsync(KeyPath + ".pub", publicKey, ct).ConfigureAwait(false);
        return publicKey;
    }

    private static async Task<byte[]> RunKeygenAsync(string executable,
        IReadOnlyList<string> arguments, CancellationToken ct)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Не удалось запустить встроенный ssh-keygen.");
        process.StandardInput.Close();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            using var output = new MemoryStream();
            var copy = process.StandardOutput.BaseStream.CopyToAsync(output, timeout.Token);
            var drain = process.StandardError.BaseStream.CopyToAsync(Stream.Null, timeout.Token);
            await Task.WhenAll(copy, drain, process.WaitForExitAsync(timeout.Token)).ConfigureAwait(false);
            if (process.ExitCode != 0 || output.Length > 4096)
                throw new IOException("Не удалось создать или прочитать SSH-ключ приложения.");
            return output.ToArray();
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            throw;
        }
    }

    internal static IEnumerable<string> InstallerArguments(OnboardingPending pending, IEnumerable<string> arguments) =>
        (pending.ForceReinstall ? new[] { "--reinstall" } : Array.Empty<string>()).Concat(arguments);

    private const string RollbackVerifiedMessage = "Предыдущая принудительная подготовка отменена; исходное состояние подтверждено. Повторите подготовку, чтобы начать новую попытку.";

    private async Task<bool> ArchiveVerifiedRollbackAsync(OnboardingPending pending, string serial,
        DeviceIdentity identity, WebIdentity? web, CancellationToken ct)
    {
        if (!pending.ForceReinstall || !pending.InstallRequested) return false;
        var paths = InstallationPaths(pending);
        if (!paths.Journal.StartsWith("/data/zte-imei-studio/installations/", StringComparison.Ordinal)) return false;
        try
        {
            var original = await File.ReadAllBytesAsync(PendingPath, ct).ConfigureAwait(false);
            if (await ReadAdbIdentityAsync(serial, web, ct).ConfigureAwait(false) != identity) return false;
            var hashes = await VerifyAssetsAsync(ct).ConfigureAwait(false);
            var bytes = await File.ReadAllBytesAsync(Path.Combine(_resources,"Onboarding","setup-agent.sh"), ct).ConfigureAwait(false);
            if (Sha(bytes) != hashes["setup-agent.sh"]) return false;
            var arguments = new[] { "--verify-rollback", paths.Journal }.Concat(InstallerPolicy(identity, pending.Profile ?? ""));
            var proof = await AdbTextAsync(serial, "sh -c " + Quote(StrictUtf8.GetString(bytes)) + " -- " +
                string.Join(' ', arguments.Select(Quote)), TimeSpan.FromSeconds(40), ct).ConfigureAwait(false);
            if (proof != "INSTALL_ROLLBACK_VERIFIED " + paths.Journal) return false;
            var current = await File.ReadAllBytesAsync(PendingPath, ct).ConfigureAwait(false);
            if (!original.AsSpan().SequenceEqual(current)) return false;
            // Preserve the original host journal and all backups. Only a verified
            // rollback closes this intent; a new apply requires another user action.
            await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "rollback-verification.txt"),
                Encoding.UTF8.GetBytes(proof + "\n"), ct).ConfigureAwait(false);
            File.Move(PendingPath, Path.Combine(pending.BackupDirectory,"setup-rolled-back-" + pending.Id + ".json"));
            return true;
        }
        catch (Exception) when (!ct.IsCancellationRequested) { return false; }
    }

    private async Task<OnboardingResult> ResumeInstallationAsync(OnboardingPending pending,
        string serial, DeviceIdentity identity, WebIdentity? web, string agentPassword, CancellationToken ct)
    {
        var journal = InstallationPaths(pending).Journal;
        var state = await AdbTextAsync(serial, "cat " + Quote(journal + "/state"),
            TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        if (state == "rolled-back" && await ArchiveVerifiedRollbackAsync(pending, serial, identity, web, ct).ConfigureAwait(false))
            throw new InvalidOperationException(RollbackVerifiedMessage);
        if (state is not ("ready" or "complete"))
            throw new InvalidOperationException("Предыдущая установка прервалась до готовности; сохранён удалённый журнал " + journal);
        if (!File.Exists(KeyPath)) throw new InvalidDataException("Отсутствует ключ незавершённой установки.");
        var verified = await PinAndVerifySshAsync(pending, serial, identity, web, agentPassword, ct).ConfigureAwait(false);
        pending.RemoteJournal = journal;
        await CommitIfReadyAsync(pending, verified, agentPassword, ct).ConfigureAwait(false);
        if (pending.CleanComponents) await SaveComponentCleanupIntentAsync(pending, verified, ct).ConfigureAwait(false);
        else await FinishAsync(pending, ct).ConfigureAwait(false);
        if (pending.CleanComponents) return await ResumeComponentCleanupAsync(ct).ConfigureAwait(false);
        return new OnboardingResult(identity.Cid, identity.FirmwareHash, web?.Imei,
            KeyPath, KnownHostsPath, false, InstallerProfile(web, identity));
    }

    private async Task<DeviceIdentity> PinAndVerifySshAsync(OnboardingPending pending, string serial,
        DeviceIdentity device, WebIdentity? web, string agentPassword, CancellationToken ct)
    {
        if (await ReadAdbIdentityAsync(serial, web, ct).ConfigureAwait(false) != device)
            throw new InvalidDataException("CID изменился перед чтением SSH host key.");
        var raw = await AdbTextAsync(serial,
            Quote(InstallationPaths(pending).DropbearKey) + " -y -f /etc/dropbear/dropbear_ed25519_host_key",
            TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        var hostKeys = raw.Split('\n').Select(line => line.Trim()).Where(line =>
            line.StartsWith("ssh-ed25519 ", StringComparison.Ordinal)).ToArray();
        if (hostKeys.Length != 1) throw new InvalidDataException("Не получен однозначный SSH host key через USB.");
        var fields = hostKeys[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 2 || !ValidEd25519Key(fields[1]))
            throw new InvalidDataException("Неверный SSH host key модема.");
        if (await ReadAdbIdentityAsync(serial, web, ct).ConfigureAwait(false) != device)
            throw new InvalidDataException("CID изменился при чтении SSH host key.");
        await WritePrivateAsync(KnownHostsPath,
            Encoding.ASCII.GetBytes("[" + _host + "]:2222 ssh-ed25519 " + fields[1] + "\n"), ct)
            .ConfigureAwait(false);
        IRemoteShell ssh = InstalledSshFactory?.Invoke() ?? new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        var reply = await ssh.RunAsync(web is null ? AccessIdentity.Command : IdentityCommand(), timeout: TimeSpan.FromSeconds(20), ct: ct)
            .ConfigureAwait(false);
        if (!reply.Success || (web is null ? AccessIdentity.Parse(reply.Stdout) : ParseIdentity(reply.Stdout, web, requireInstallerRouter: false)) != device)
            throw new InvalidDataException("SSH подключён к другому устройству после установки.");
        await VerifyAgentReadyAsync(ssh, ct).ConfigureAwait(false);
        if (InstallerProfile(web,device)=="linux-arm64-access") await VerifyDiscoveryAgentAsync(ssh,ct).ConfigureAwait(false);
        await AuthenticateAgentAsync(ssh, agentPassword, ct).ConfigureAwait(false);
        return device;
    }

    internal static bool? CredentialOrigin(string output)
    {
        var lines = output.Split('\n').Where(line => line.StartsWith("INSTALL_AGENT ", StringComparison.Ordinal)).ToArray();
        return lines.Length == 1 ? lines[0] switch { "INSTALL_AGENT new" => true, "INSTALL_AGENT preserved" => false, _ => null } : null;
    }

    private static bool ValidEd25519Key(string base64)
    {
        try
        {
            var data = Convert.FromBase64String(base64);
            return data.Length == 51 && data.AsSpan(0, 4).SequenceEqual(new byte[] { 0, 0, 0, 11 }) &&
                data.AsSpan(4, 11).SequenceEqual("ssh-ed25519"u8) &&
                data.AsSpan(15, 4).SequenceEqual(new byte[] { 0, 0, 0, 32 });
        }
        catch (FormatException) { return false; }
    }

    internal string DiscoveryAgentCommand() => """
        set -eu
        test "$(sha256sum /data/zte-agent | cut -d ' ' -f1)" = EXPECTED_AGENT
        found=0
        for p in $(pidof zte-agent); do
          case "$p" in ''|*[!0-9]*) exit 71;; esac
          if test "$(readlink /proc/$p/exe)" = /data/zte-agent; then
            test "$(sha256sum /proc/$p/exe | cut -d ' ' -f1)" = EXPECTED_AGENT
            test "$(tr '\000' '\n' < /proc/$p/environ | sed -n '/^ZTE_AGENT_MODE=/p')" = ZTE_AGENT_MODE=discovery
            test "$(tr '\000' '\n' < /proc/$p/environ | sed -n '/^ZTE_AGENT_BIND=/p')" = EXPECTED_BIND
            found=$((found+1))
          fi
        done
        test "$found" = 1
        printf AGENT_DISCOVERY_READY
        """.Replace("EXPECTED_AGENT",Quote(AgentPackage.Sha256),StringComparison.Ordinal)
            .Replace("EXPECTED_BIND",Quote("ZTE_AGENT_BIND="+_host+":9090"),StringComparison.Ordinal);

    private async Task VerifyDiscoveryAgentAsync(IRemoteShell ssh,CancellationToken ct)
    {
        // Health is authenticated. Prove the running process mode without an
        // unauthenticated request; the separate login still verifies readiness.
        var reply=await ssh.RunAsync(DiscoveryAgentCommand(),timeout:TimeSpan.FromSeconds(20),ct:ct).ConfigureAwait(false);
        if(!reply.Success || !reply.Stdout.AsSpan().SequenceEqual("AGENT_DISCOVERY_READY"u8))
            throw new InvalidDataException("Пассивный режим агента не подтверждён; автоматическое продолжение запрещено.");
    }

    private static async Task VerifyAgentReadyAsync(IRemoteShell ssh, CancellationToken ct)
    {
        // Newly installed or resumed setups never inherit historical-build reuse.
        await AccessAgentReusePolicy.ReadAsync(ssh, allowPrevious: false, ct).ConfigureAwait(false);
    }

    private async Task FinishPriorReadyForReinstallAsync(OnboardingPending pending, CancellationToken ct)
    {
        if (!pending.InstallRequested || pending.CleanComponents || pending.Phase is not ("ready" or "complete"))
            throw new InvalidDataException("Незавершённая подготовка ещё не готова к чистой переустановке.");
        var original = await File.ReadAllBytesAsync(PendingPath, ct).ConfigureAwait(false);
        var trustedInstaller = (await VerifyAssetsAsync(ct).ConfigureAwait(false))["setup-agent.sh"];
        IRemoteShell ssh = InstalledSshFactory?.Invoke() ?? new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        var device = await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false);
        if (device.Cid != pending.Cid || device.FirmwareHash != pending.FirmwareHash || device.RouterHash != pending.RouterHash ||
            (pending.Profile == "linux-arm64-access" && device.BootId != pending.BootId))
            throw new InvalidDataException("Устройство или профиль незавершённой установки изменился.");
        var proof = await ssh.RunAsync("sh -s --", Encoding.UTF8.GetBytes(PriorReadyProofCommand(pending, device, trustedInstaller)), TimeSpan.FromSeconds(40), ct).ConfigureAwait(false);
        if (!proof.Success && StrictUtf8.GetString(proof.Stderr).Split('\n').Contains("INSTALL_PRIOR_SCRIPT_CHANGED", StringComparer.Ordinal))
            throw new InvalidDataException("Сценарий предыдущей подготовки отличается от проверенной версии. Журнал сохранён; новая установка не запускалась.");
        if (!proof.Success || !proof.Stdout.AsSpan().SequenceEqual("INSTALL_PRIOR_READY_VERIFIED\n"u8))
            throw new InvalidDataException("Не подтверждены файлы и резервная копия предыдущей подготовки. Журнал сохранён.");
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != device)
            throw new InvalidDataException("Модем или его загрузка изменились во время операции. Обновите состояние.");
        var commit = await ssh.RunAsync(CommitCommand(pending, device), timeout: TimeSpan.FromSeconds(40), ct: ct).ConfigureAwait(false);
        var expected = "INSTALL_COMMITTED " + InstallationPaths(pending).Journal;
        if (!commit.Success || StrictUtf8.GetString(commit.Stdout).Split('\n').Count(line => line == expected) != 1)
            throw new IOException("Предыдущую подготовку не удалось завершить; новая установка не запускалась.");
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != device ||
            !(await File.ReadAllBytesAsync(PendingPath, ct).ConfigureAwait(false)).AsSpan().SequenceEqual(original))
            throw new InvalidDataException("Модем или журнал подготовки изменился. Новая установка не запускалась.");
        await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "setup-before-clean-reinstall.json"), original, ct).ConfigureAwait(false);
        pending.Phase = "complete";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
        await FinishAsync(pending, ct).ConfigureAwait(false);
        _progress?.Invoke("Предыдущая подготовка завершена по журналу. Начинается чистая установка с новым паролем.");
    }

    internal static string PriorReadyProofCommand(OnboardingPending pending, DeviceIdentity device, string installerHash)
    {
        if (!HashLinePattern.IsMatch(installerHash)) throw new InvalidDataException("Повреждён компонент настройки: setup-agent.sh");
        var paths = InstallationPaths(pending);
        var legacy = paths.Stage.StartsWith("/data/local/tmp/", StringComparison.Ordinal);
        var startupRoot = legacy ? "data/local/tmp" : "data/zte-imei-studio";
        var binRoot = legacy ? "data/bin" : "data/zte-imei-studio/bin";
        var targets = new[] { "data/zte-agent", binRoot + "/dropbear", binRoot + "/dropbearkey", "etc/dropbear/authorized_keys",
            "etc/dropbear/dropbear_ed25519_host_key", "etc/dropbear/dropbear_rsa_host_key", startupRoot + "/start_zte_agent.sh",
            startupRoot + "/start_zte_imei_studio.sh", "etc/rc.local" };
        var parents = legacy ? "/data /data/local /data/local/tmp /data/local/tmp/zte-imei-installations" : "/data /data/zte-imei-studio /data/zte-imei-studio/installations";
        var policy = string.Join(' ', InstallerPolicy(device, pending.Profile ?? "").Skip(1));
        var owner = string.Join(' ', new[] { pending.Id }.Concat(InstallerPolicy(device, pending.Profile ?? "")));
        var beforePaths = Quote(string.Join('|', targets.Select(target => paths.Journal + "/before/" + target.Replace('/', '_'))));
        var afterPaths = Quote(string.Join('|', targets.Select(target => "/" + target).Concat(new[] { paths.Journal + "/cid", paths.Journal + "/profile.identity" })));
        return $$"""
        set -eu
        fail() { exit 71; }
        safe_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail; mode=$(stat -c %a "$1"); case "$mode" in ''|*[!0-7]*) fail;; esac; test "$((0$mode & 0022))" = 0 || fail; }
        plain_file() { test -f "$1" && test ! -L "$1" && test "$(stat -c %u:%h "$1")" = 0:1 || fail; }
        safe_file() { plain_file "$1"; mode=$(stat -c %a "$1"); case "$mode" in ''|*[!0-7]*) fail;; esac; test "$((0$mode & 0022))" = 0 || fail; }
        for path in {{parents}} /etc; do safe_dir "$path"; done
        journal={{Quote(paths.Journal)}}; stage={{Quote(paths.Stage)}}
        safe_dir "$journal"; test "$(stat -c %a "$journal")" = 700
        safe_dir "$stage"; test "$(stat -c %a "$stage")" = 700
        for name in .owner .install-requested setup-agent.sh; do safe_file "$stage/$name"; done
        test "$(sha256sum "$stage/setup-agent.sh" | cut -d ' ' -f1)" = {{Quote(installerHash)}} || { printf 'INSTALL_PRIOR_SCRIPT_CHANGED\n' >&2; exit 71; }
        test "$(cat "$stage/.owner")" = {{Quote(owner)}}
        test "$(cat "$stage/.install-requested")" = {{Quote(owner)}}
        for name in cid profile.identity state before.sha256 after.sha256; do safe_file "$journal/$name"; done
        test "$(cat "$journal/cid")" = {{Quote(device.Cid)}}
        test "$(cat "$journal/profile.identity")" = {{Quote(policy)}}
        case "$(cat "$journal/state")" in ready|complete) ;; *) fail;; esac
        test "$(cat /sys/block/mmcblk0/device/cid)" = {{Quote(device.Cid)}}
        test "$(cat /proc/sys/kernel/random/boot_id)" = {{Quote(device.BootId)}}
        safe_dir "$journal/before"
        before_paths={{beforePaths}}
        after_paths={{afterPaths}}
        awk -v allowed="$before_paths" 'BEGIN{n=split(allowed,a,"[|]");for(i=1;i<=n;i++)want[a[i]]=1} NF!=2 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || !want[$2] || seen[$2]++ {bad=1} END{exit bad}' "$journal/before.sha256"
        awk -v allowed="$after_paths" 'BEGIN{n=split(allowed,a,"[|]");for(i=1;i<=n;i++)want[a[i]]=1} NF!=2 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || !want[$2] || seen[$2]++ {bad=1} END{if(NR!=n)bad=1;exit bad}' "$journal/after.sha256"
        for manifest in before.sha256 after.sha256; do
          while read -r hash path; do
            case "$path" in /etc/rc.local|"$journal/before/etc_rc.local") plain_file "$path";; *) safe_file "$path";; esac
          done < "$journal/$manifest"
          if test -s "$journal/$manifest"; then sha256sum -c "$journal/$manifest" >/dev/null 2>&1; fi
        done
        expected=$(awk '$2=="/data/zte-agent"{print $1}' "$journal/after.sha256")
        found=0
        for pid in $(pidof zte-agent); do
          case "$pid" in ''|*[!0-9]*) fail;; esac
          test "$(readlink "/proc/$pid/exe")" = /data/zte-agent || fail
          test "$(sha256sum "/proc/$pid/exe" | cut -d ' ' -f1)" = "$expected" || fail
          found=$((found+1))
        done
        test "$found" = 1
        printf 'INSTALL_PRIOR_READY_VERIFIED\n'
        """;
    }

    private async Task CommitIfReadyAsync(OnboardingPending pending, DeviceIdentity device,
        string agentPassword, CancellationToken ct)
    {
        if (!pending.InstallRequested) return;
        var paths = InstallationPaths(pending);
        var journal = paths.Journal;
        IRemoteShell ssh = InstalledSshFactory?.Invoke() ?? new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        await AuthenticateAgentAsync(ssh, agentPassword, ct).ConfigureAwait(false);
        var result = await ssh.RunAsync(CommitCommand(pending, device),
            timeout: TimeSpan.FromSeconds(40), ct: ct).ConfigureAwait(false);
        if (!result.Success || !StrictUtf8.GetString(result.Stdout).Contains("INSTALL_COMMITTED " + journal,
                StringComparison.Ordinal))
            throw new IOException("Установка готова, но журнал не удалось завершить.");
        pending.RemoteJournal = journal;
        pending.Phase = "complete";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
    }

    internal static string CommitCommand(OnboardingPending pending, DeviceIdentity device)
    {
        var paths = InstallationPaths(pending);
        var policy = InstallerPolicy(device, pending.Profile ?? "");
        var args = new[] { paths.Stage + "/setup-agent.sh", "--commit", paths.Journal }.Concat(policy).ToArray();
        if (!paths.Stage.StartsWith("/data/local/tmp/zte-imei-setup-", StringComparison.Ordinal))
            return "sh " + string.Join(' ', args.Select(Quote));
        var owner = string.Join(' ', new[] { pending.Id }.Concat(policy));
        var commitArgs = string.Join(' ', new[] { "--commit", paths.Journal }.Concat(policy).Select(Quote));
        return $$"""
            set -eu
            fail() { printf 'INSTALL_ERROR COMMIT_STAGE_UNSAFE\n' >&2; exit 1; }
            safe_dir() {
              test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail
              mode=$(stat -c %a "$1") || fail
              case "$mode" in ''|*[!0-7]*) fail;; esac
              test "$((0$mode & 0022))" = 0 || fail
            }
            safe_file() {
              test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 && test "$(stat -c %h "$1")" = 1 || fail
            }
            for parent in /data /data/local /data/local/tmp; do safe_dir "$parent"; done
            stage={{Quote(paths.Stage)}}; owner={{Quote(owner)}}
            safe_dir "$stage"
            test "$(stat -c %a "$stage")" = 700 || fail
            for name in .owner .install-requested; do
              file="$stage/$name"; safe_file "$file"
              test "$(stat -c %a "$file")" = 600 && test "$(stat -c %s "$file")" = {{Encoding.UTF8.GetByteCount(owner) + 1}} && test "$(cat "$file")" = "$owner" || fail
            done
            script="$stage/setup-agent.sh"; safe_file "$script"
            case "$(stat -c %a "$script")" in 600|700) ;; *) fail;; esac
            original=$(stat -c %d:%i:%u:%a:%h "$script") || fail
            exec 9<"$script" || fail
            test "$(stat -Lc %d:%i:%u:%a:%h /proc/self/fd/9)" = "$original" && test ! -L "$script" && test "$(stat -c %d:%i:%u:%a:%h "$script")" = "$original" || fail
            sh /proc/self/fd/9 {{commitArgs}}
            """;
    }

    private async Task AuthenticateAgentAsync(IRemoteShell ssh, string password, CancellationToken ct)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(new { password });
        var request = "/usr/bin/curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 " +
            "-H 'Content-Type: application/json' --data-binary @- " +
            Quote("http://" + _host + ":9090/api/auth/login");
        var reply = await ssh.RunAsync(request, body, TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        if (!reply.Success) throw new InvalidDataException("Агент не подтвердил вход заданным паролем.");
        using var document = JsonDocument.Parse(reply.Stdout);
        var root = document.RootElement;
        if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True ||
            !root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object ||
            !data.TryGetProperty("token", out var token) || token.ValueKind != JsonValueKind.String ||
            string.IsNullOrEmpty(token.GetString()))
            throw new InvalidDataException("Агент не подтвердил вход заданным паролем.");
    }

    private async Task CleanupStageAsync(string serial, string stage, CancellationToken ct)
    {
        try
        {
            var names = new[] { "zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh",
                "id_ed25519.pub", "start-agent.sh", "zte-timeout", "legacy-agent.private.sh", ".owner", ".install-requested" };
            await AdbTextAsync(serial, "rm -f " + string.Join(' ', names.Select(n => Quote(stage + "/" + n))) +
                "; rmdir " + Quote(stage), TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        }
        catch { /* The successful installation journal remains authoritative. */ }
    }

    private async Task<OnboardingPending?> LoadPendingAsync(CancellationToken ct)
    {
        if (!File.Exists(PendingPath)) return null;
        var pending = JsonSerializer.Deserialize<OnboardingPending>(
            await File.ReadAllBytesAsync(PendingPath, ct).ConfigureAwait(false));
        if (pending is null || !Guid.TryParse(pending.Id, out _) ||
            (pending.CleanComponents && (!pending.ForceReinstall || _diagnosticAccess)) ||
            (pending.IdentitySource is not ("single-usb" or "web-matched")) ||
            (pending.IdentitySource == "web-matched" && pending.WebIdentity is null) ||
            (pending.IdentitySource == "single-usb" && (pending.WebIdentity is not null || _diagnosticAccess || pending.RestoreRequested || pending.DirectAdbRequested || pending.DiagnosticRebootRequested || pending.Profile != "linux-arm64-access" || pending.Cid is null || !Regex.IsMatch(pending.Cid,"^[0-9a-f]{32}$") || !Guid.TryParseExact(pending.BootId,"D",out _))) ||
            pending.Intent != (_diagnosticAccess ? "diagnostic-adb" : pending.Profile == "linux-arm64-access" ? "linux-arm64-access" : "preparation") ||
            (_diagnosticAccess && pending.InstallRequested) ||
            (pending.DiagnosticRebootRequested && (!_diagnosticAccess || pending.RestoreRequested || pending.InstallRequested || pending.Phase != "diagnostic-reboot-requested")) ||
            (!pending.DiagnosticRebootRequested && pending.Phase == "diagnostic-reboot-requested") ||
            string.IsNullOrEmpty(pending.BackupDirectory) ||
            (pending.DirectAdbOutcome is not (null or "requested" or "accepted" or "rejected" or "uncertain")) ||
            (!pending.DirectAdbRequested && pending.DirectAdbOutcome is not null) ||
            (pending.DirectAdbRequested && pending.DirectAdbOutcome is null) ||
            pending.Phase is not ("prepared" or "restore-requested" or "adb-ready" or "install-requested" or "ready" or "complete" or "diagnostic-reboot-requested") ||
            (pending.Phase == "adb-ready" && (_diagnosticAccess || pending.InstallRequested || pending.Cid is null || pending.AdbSerial is null || pending.Profile is null || pending.FirmwareHash is null || pending.RouterHash is null || pending.BootId is null)) ||
            (pending.RestoreRequested && pending.Phase == "prepared") ||
            (pending.InstallRequested && pending.Phase is "prepared" or "restore-requested") ||
            (!pending.InstallRequested && pending.Phase is "install-requested" or "ready" or "complete") ||
            !Path.GetFullPath(pending.BackupDirectory).StartsWith(
                Path.GetFullPath(Path.Combine(_storage, BackupFolder)) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Повреждён журнал незавершённой установки.");
        _ = InstallationPaths(pending);
        return pending;
    }

    private Task SavePendingAsync(OnboardingPending pending, CancellationToken ct) =>
        WriteJsonAsync(PendingPath, pending, ct);

    private async Task FinishAsync(OnboardingPending pending, CancellationToken ct)
    {
        await WriteJsonAsync(Path.Combine(pending.BackupDirectory, _diagnosticAccess ? "adb-access-result.json" : "setup-result.json"), pending, ct)
            .ConfigureAwait(false);
        File.Delete(PendingPath);
    }

    private static Task WriteJsonAsync<T>(string path, T value, CancellationToken ct) =>
        WritePrivateAsync(path, JsonSerializer.SerializeToUtf8Bytes(value,
            new JsonSerializerOptions { WriteIndented = true }), ct);

    private static async Task WritePrivateAsync(string path, byte[] data, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        RejectReparsePoint(Path.GetDirectoryName(path)!);
        RejectReparsePoint(path);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var output = OperatingSystem.IsWindows()
                ? FileSystemAclExtensions.Create(new FileInfo(temporary), FileMode.CreateNew,
                    FileSystemRights.FullControl, FileShare.None, 64 * 1024,
                    FileOptions.WriteThrough, PrivateFileSecurity())
                : new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, 64 * 1024, FileOptions.WriteThrough))
            {
                await output.WriteAsync(data, ct).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }
            RejectReparsePoint(path);
            File.Move(temporary, path, overwrite: true);
        }
        finally { try { File.Delete(temporary); } catch { } }
    }

    [SupportedOSPlatform("windows")]
    private static FileSecurity PrivateFileSecurity()
    {
        var user = WindowsIdentity.GetCurrent().User ??
            throw new IOException("Не удалось определить текущего пользователя Windows.");
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            AccessControlType.Allow));
        return security;
    }

    private static void ProtectPrivateFile(string path)
    {
        if (OperatingSystem.IsWindows())
            FileSystemAclExtensions.SetAccessControl(new FileInfo(path), PrivateFileSecurity());
    }

    [SupportedOSPlatform("windows")]
    private static void ProtectPrivateDirectory(string path)
    {
        var user = WindowsIdentity.GetCurrent().User ??
            throw new IOException("Не удалось определить текущего пользователя Windows.");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None, AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(path), security);
    }

    private static void RejectReparsePoint(string path)
    {
        try
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Символическая ссылка в каталоге локальных данных не допускается.");
        }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
    }
}
