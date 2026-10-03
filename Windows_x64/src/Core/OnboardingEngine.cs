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

public sealed record AdbAccessResult(string Serial, DeviceIdentity Identity, WebIdentity WebIdentity, bool AlreadyAvailable);

public sealed record OnboardingResult(string Cid, string FirmwareHash, string? Imei,
    string KeyPath, string KnownHostsPath, bool AlreadyConfigured, string? Profile = null);

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
    public string? AdbSerial { get; set; }
    public string? Cid { get; set; }
    public string? Profile { get; set; }
    public string? FirmwareHash { get; set; }
    public string? RouterHash { get; set; }
    public string? BootId { get; set; }
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
public sealed class OnboardingEngine
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

    public async Task<OnboardingResult> PrepareAsync(string webPassword,
        string agentPassword, string backupKeySuffix, CancellationToken ct = default)
    {
        if (webPassword.Contains('\0'))
            throw new ArgumentException("Недопустимый пароль Web.", nameof(webPassword));
        if (string.IsNullOrEmpty(agentPassword) || agentPassword.Contains('\0'))
            throw new ArgumentException("Введите отдельный пароль агента.", nameof(agentPassword));
        Directory.CreateDirectory(_storage);
        using var localLock = new FileStream(Path.Combine(_storage, "operation.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        if (File.Exists(Path.Combine(_storage, "imei-pending.json")) ||
            File.Exists(Path.Combine(_storage, "pending.json")) ||
            File.Exists(Path.Combine(_storage, "system-restore-pending.json")) ||
            File.Exists(Path.Combine(_storage, "adb-access-pending.json")))
            throw new InvalidOperationException("Сначала завершите незавершённую операцию с модемом.");

        var hashes = await VerifyAssetsAsync(ct).ConfigureAwait(false);
        _progress?.Invoke("Проверка Web и уже доступного root shell.");
        using var web = WebFactory?.Invoke() ?? new ModemWebClient(_host);
        WebIdentity? webIdentity = null;
        DeviceIdentity? existing = null;
        (string Serial, DeviceIdentity Identity)? match;
        if (string.IsNullOrEmpty(webPassword))
        {
            // Explicit root-USB preparation does not contact Web or manufacture
            // absent vendor identity fields. Each later read repeats USB proof.
            match = await FindMatchingAdbAsync(null, ct).ConfigureAwait(false);
            if (match is null) throw new InvalidOperationException("Для установки без Web нужен единственный root USB ADB. Сначала проверьте устройство.");
        }
        else
        {
            await web.LoginAsync(webPassword, ct).ConfigureAwait(false);
            webIdentity = await web.GetIdentityAsync(skipFirmwareCheck: true, ct: ct).ConfigureAwait(false);
            existing = await ProbeExistingSshAsync(webIdentity, ct).ConfigureAwait(false);
            match = existing is null ? await FindMatchingAdbAsync(webIdentity, ct).ConfigureAwait(false) : null;
        }
        var rootAlreadyAvailable = existing is not null || match is not null;
        // Unknown firmware is accepted only through an already working, matched
        // root shell. It never inherits the firmware-specific backup activation.
        if (!rootAlreadyAvailable && (webIdentity is null || !IsB31(webIdentity) && !IsAllowedB02(webIdentity)))
            throw new InvalidOperationException("Сначала нужен работающий root USB ADB или проверенный SSH. Способ включения доступа этой прошивки не подтверждён.");
        var genericAccess = rootAlreadyAvailable && InstallerProfile(webIdentity, existing ?? match!.Value.Identity) == "linux-arm64-access";
        var encrypted = genericAccess ? Array.Empty<byte>() : await web.DownloadFreshBackupAsync(ct).ConfigureAwait(false);
        if (webIdentity is not null && await web.GetIdentityAsync(skipFirmwareCheck: true, ct: ct).ConfigureAwait(false) != webIdentity)
            throw new InvalidDataException("Устройство изменилось во время предварительной проверки.");
        var backupDirectory = Path.Combine(_storage, "SetupBackups", Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(backupDirectory);
        if (!genericAccess) await WritePrivateAsync(Path.Combine(backupDirectory, "back_parameter.original"), encrypted, ct).ConfigureAwait(false);
        await WriteJsonAsync(Path.Combine(backupDirectory, "identity.json"), webIdentity, ct).ConfigureAwait(false);
        await WriteJsonAsync(Path.Combine(backupDirectory, "manifest.json"), new
        {
            encryptedSHA256 = genericAccess ? null : Sha(encrypted), suffixVerified = false,
            sourceBackupFile = genericAccess ? null : "back_parameter.original",
            accessBackup = genericAccess ? "remote-transaction-file-snapshots" : "encrypted-original-and-remote-file-snapshots",
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
                BackupDirectory = backupDirectory,
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

        // An already pinned, verified SSH/agent installation is preserved.
        if (existing is not null)
        {
            if (pending.InstallRequested && pending.Phase != "complete")
                await CommitIfReadyAsync(pending, existing, agentPassword, ct).ConfigureAwait(false);
            await FinishAsync(pending, ct).ConfigureAwait(false);
            return new OnboardingResult(existing.Cid, existing.FirmwareHash, webIdentity?.Imei,
                KeyPath, KnownHostsPath, true, InstallerProfile(webIdentity, existing));
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
        pending.Profile = profile;
        pending.FirmwareHash = identity.FirmwareHash;
        pending.RouterHash = identity.RouterHash;
        pending.BootId = identity.BootId;
        await SavePendingAsync(pending, ct).ConfigureAwait(false);

        if (!pending.CanStartInstallation)
            return await ResumeInstallationAsync(pending, serial, identity, webIdentity, agentPassword, ct)
                .ConfigureAwait(false);
        var installer = StrictUtf8.GetString(await File.ReadAllBytesAsync(
            Path.Combine(_resources, "Onboarding", "setup-agent.sh"), ct).ConfigureAwait(false));
        var policy = InstallerPolicy(identity, profile);
        var preflight = await AdbTextAsync(serial,
            "sh -c " + Quote(installer) + " -- " +
            string.Join(' ', new[] { "--preflight" }.Concat(policy).Select(Quote)),
            TimeSpan.FromSeconds(60), ct).ConfigureAwait(false);
        if (preflight != "INSTALL_PREFLIGHT " + profile + " imei_config=unknown")
            throw new InvalidDataException("Установщик не подтвердил предварительную проверку прошивки.");

        var publicKey = await CreateKeyAsync(ct).ConfigureAwait(false);
        var stage = "/data/local/tmp/zte-imei-setup-" + pending.Id;
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
            await PushStagedAsync(serial, KeyPath + ".pub", stage, "id_ed25519.pub", owner,
                Sha(publicKey), ct).ConfigureAwait(false);
            await PushStagedAsync(serial, credentialFile, stage, "start-agent.sh", owner,
                Sha(await File.ReadAllBytesAsync(credentialFile, ct).ConfigureAwait(false)), ct)
                .ConfigureAwait(false);
        }
        finally { try { File.Delete(credentialFile); } catch { } }

        pending.InstallRequested = true;
        pending.Phase = "install-requested";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
        await AdbTextAsync(serial, "set -eu; umask 077; set -C; printf '%s\\n' " +
            Quote(owner) + " > " + Quote(stage + "/.install-requested"), TimeSpan.FromSeconds(20), ct)
            .ConfigureAwait(false);
        var arguments = new[] { stage + "/setup-agent.sh", stage, identity.Cid, hashes["zte-agent"], hashes["dropbear"], Sha(publicKey) }.Concat(policy.Skip(1)).ToArray();
        var installOutput = await AdbTextAsync(serial, "sh " + string.Join(' ', arguments.Select(Quote)),
            TimeSpan.FromSeconds(100), ct).ConfigureAwait(false);
        await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "installation.log"),
            Encoding.UTF8.GetBytes(installOutput), ct).ConfigureAwait(false);
        var expectedJournal = "/data/local/tmp/zte-imei-installations/" + pending.Id;
        if (!installOutput.Split('\n').Contains("INSTALL_READY " + expectedJournal))
            throw new InvalidDataException("Установщик не подтвердил готовность.");
        pending.RemoteJournal = expectedJournal;
        pending.NewAgent = installOutput.Split('\n').Contains("INSTALL_AGENT new");
        pending.Phase = "ready";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);

        var verified = await PinAndVerifySshAsync(serial, identity, webIdentity, agentPassword, ct)
            .ConfigureAwait(false);
        await CommitIfReadyAsync(pending, verified, agentPassword, ct).ConfigureAwait(false);
        await FinishAsync(pending, ct).ConfigureAwait(false);
        await CleanupStageAsync(serial, stage, ct).ConfigureAwait(false);
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
        if (!_skipFirmwareCheck && !IsB31(webIdentity))
            throw new InvalidOperationException("Для включения ADB на этой прошивке включите «Пропустить проверку прошивки». Это не разрешает восстановление бэкапа B31 на другой прошивке.");
        if (expectedIdentity is not null && expectedImei is null)
            throw new InvalidDataException("Для включения ADB сначала подтвердите связь ожидаемого CID и IMEI через SSH.");
        if (pending is null)
        {
            var directory = Path.Combine(_storage, BackupFolder, Guid.NewGuid().ToString("D"));
            Directory.CreateDirectory(directory);
            pending = new OnboardingPending { Intent = "diagnostic-adb", Id = Guid.NewGuid().ToString("D"),
                WebIdentity = webIdentity, BackupDirectory = directory, Cid = expectedIdentity?.Cid, FirmwareHash = expectedIdentity?.FirmwareHash };
        }
        _progress?.Invoke("Диагностический ADB: сохраняется свежий бэкап перед включением доступа.");
        var encrypted = await web.DownloadFreshBackupAsync(ct).ConfigureAwait(false);
        if (await web.GetIdentityAsync(skipFirmwareCheck: true, ct).ConfigureAwait(false) != webIdentity)
            throw new InvalidDataException("Устройство изменилось во время подготовки бэкапа.");
        // A resumed request retains its original evidence; only verification is resumed.
        if (!pending.DirectAdbRequested && !pending.RestoreRequested)
        {
            await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "back_parameter.original"), encrypted, ct).ConfigureAwait(false);
            await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "identity.json"), webIdentity, ct).ConfigureAwait(false);
            await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "manifest.json"), new
            { encryptedSHA256 = Sha(encrypted), suffixVerified = false, sourceBackupFile = "back_parameter.original" }, ct).ConfigureAwait(false);
        }
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
        // Legacy methods still require their advertised capability; backup restore remains B31-only.
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
            { _progress?.Invoke("Список штатных USB-команд недоступен; проверяется известный профиль прошивки."); }
            if (advertised == true || advertised is null && IsLegacyUsbDebugFirmware(webIdentity))
            {
                _progress?.Invoke("Способ 1: штатное переключение USB в debug; запрос отправляется один раз.");
                if (await web.GetIdentityAsync(_diagnosticAccess || _skipFirmwareCheck, ct).ConfigureAwait(false) != webIdentity)
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
        // Decryption is needed only for the B31 restore method. An existing ADB
        // channel or a successful legacy debug switch does not depend on its key.
        if (match is null && IsB31(webIdentity) && !pending.RestoreRequested && !pending.InstallRequested && !pending.DiagnosticRebootRequested)
        {
            _progress?.Invoke("Способ 2: проверка бэкапа B31 для включения USB ADB через rc.local.");
            // A debug request can temporarily disconnect USB networking. Only a
            // fresh authenticated identity and backup authorize the next method.
            if (pending.DirectAdbRequested)
            {
                await web.LoginAsync(webPassword, ct).ConfigureAwait(false);
                if (await web.GetIdentityAsync(_skipFirmwareCheck, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось после переключения USB.");
                encrypted = await web.DownloadFreshBackupAsync(ct).ConfigureAwait(false);
                if (await web.GetIdentityAsync(_skipFirmwareCheck, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось при обновлении бэкапа.");
                await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "back_parameter.after-direct.original"), encrypted, ct).ConfigureAwait(false);
                await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "manifest.json"), new
                {
                    encryptedSHA256 = Sha(encrypted), suffixVerified = false,
                    sourceBackupFile = "back_parameter.after-direct.original",
                }, ct).ConfigureAwait(false);
            }
            if (string.IsNullOrEmpty(backupKeySuffix) || Encoding.UTF8.GetByteCount(backupKeySuffix) > 128 || backupKeySuffix.Contains('\0'))
                throw new ArgumentException("Для проверки бэкапа B31 введите Backup-key suffix вашей прошивки. В публичную сборку он не включён.", nameof(backupKeySuffix));
            var patch = BackupPatch.Prepare(encrypted, webIdentity.Imei, backupKeySuffix);
            await WriteJsonAsync(Path.Combine(pending.BackupDirectory, "manifest.json"), new
            {
                encryptedSHA256 = patch.OriginalHash, patchedSHA256 = patch.PatchedHash,
                suffixVerified = true, adbAlreadyEnabled = patch.AlreadyEnabled,
                sourceBackupFile = pending.DirectAdbRequested ? "back_parameter.after-direct.original" : "back_parameter.original",
            }, ct).ConfigureAwait(false);
            if (pending.CanRequestRestore(false, patch.AlreadyEnabled))
            {
                if (await web.GetIdentityAsync(_skipFirmwareCheck, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось перед включением ADB.");
                await WritePrivateAsync(Path.Combine(pending.BackupDirectory, "back_parameter.adb-only"),
                    patch.PatchedEncrypted, ct).ConfigureAwait(false);
                await web.UploadBackupAsync(patch.PatchedEncrypted, ct).ConfigureAwait(false);
                if (await web.GetIdentityAsync(_skipFirmwareCheck, ct).ConfigureAwait(false) != webIdentity)
                    throw new InvalidDataException("Устройство изменилось перед восстановлением веб-бэкапа.");
                try
                {
                    _progress?.Invoke("Восстановление ADB-only бэкапа B31: модем может перезагрузиться. Ожидается root USB ADB.");
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
                _progress?.Invoke("В бэкапе B31 уже есть включение ADB. Запрашивается одна штатная перезагрузка без восстановления бэкапа.");
                await pending.RequestDiagnosticRebootOnceAsync(value => SavePendingAsync(value, ct),
                    () => web.RebootDeviceAsync(ct)).ConfigureAwait(false);
            }
            else _progress?.Invoke("В rc.local уже есть включение ADB. Повторное восстановление не требуется; проверяются USB и драйвер.");
        }
        if (match is null && !IsB31(webIdentity) && !pending.DirectAdbRequested)
            throw new InvalidOperationException("Прошивка не объявляет штатный способ включения ADB; B31-восстановление к ней неприменимо. " + _lastAdbDiagnostic);
        return match ?? await WaitForAdbAsync(webIdentity, ct).ConfigureAwait(false);
    }

    private static bool IsB31(WebIdentity identity) => identity.Firmware == "CN_ZTE_MU5250V1.0.0B31" &&
        identity.Inner == "BD_CNMU5250V1.0.0B31";

    internal static bool IsLegacyUsbDebugFirmware(WebIdentity identity)
    {
        var match = Regex.Match(identity.Firmware, @"^CN_ZTE_MU5250V1\.0\.0B(\d{2})$", RegexOptions.CultureInvariant);
        return match.Success && int.TryParse(match.Groups[1].Value, out var version) && version is > 0 and <= 27 &&
            identity.Inner == "BD_CNMU5250V1.0.0B" + match.Groups[1].Value;
    }

    private bool IsAllowedB02(WebIdentity web) => _skipFirmwareCheck && web.Firmware == "STD_PL_MU5250V1.0.0B02" && web.Inner == "BD_STDPLMU5250V1.0.0B02";

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

    private async Task<DeviceIdentity?> ProbeExistingSshAsync(WebIdentity web, CancellationToken ct)
    {
        if (!File.Exists(KeyPath) || !File.Exists(KnownHostsPath)) return null;
        SshTransport ssh;
        try { ssh = new SshTransport(_host, 2222, KeyPath, KnownHostsPath); }
        catch (InvalidDataException) { throw; }
        RemoteResult reply;
        try { reply = await ssh.RunAsync(IdentityCommand(), timeout: TimeSpan.FromSeconds(15), ct: ct)
                .ConfigureAwait(false); }
        catch (SshTrustException) { throw; }
        catch (Exception error) when (error is SocketException or IOException or TimeoutException or Renci.SshNet.Common.SshAuthenticationException)
        { return null; }
        if (reply.ExitCode is 255 or -1) return null;
        if (!reply.Success) throw new InvalidDataException("SSH отвечает, но не подтвердил root и идентификацию.");
        var proof = ParseIdentity(reply.Stdout, web, requireInstallerRouter: false);
        var profile = InstallerProfile(web, proof);
        if (profile == "b31")
        {
            var state = await new ImeiEngine(ssh, _storage, _resources, _skipFirmwareCheck)
                .InspectAsync(ct).ConfigureAwait(false);
            if (state.Identity.Cid != proof.Cid || state.Imeis[0] != web!.Imei)
                throw new InvalidDataException("SSH-модем отличается от веб-устройства.");
        }
        await VerifyAgentReadyAsync(ssh, ct).ConfigureAwait(false);
        if(profile == "linux-arm64-access") await VerifyDiscoveryAgentAsync(ssh, ct).ConfigureAwait(false);
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

    private static string StagePreparationCommand(string stage, string owner) => $$"""
        set -eu
        umask 077
        stage={{Quote(stage)}}; owner={{Quote(owner)}}
        fail() { printf 'INSTALL_ERROR STAGE_%s\n' "$1" >&2; exit 1; }
        safe_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail DIRECTORY; mode=$(stat -c %a "$1"); case "$mode" in ''|*[!0-7]*) fail MODE;; esac; test "$((0$mode & 0022))" = 0 || fail MODE; }
        safe_dir /data
        for parent in /data/local /data/local/tmp; do
          if test ! -e "$parent" && test ! -L "$parent"; then mkdir -m 755 "$parent"; fi
          safe_dir "$parent"
        done
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

    private async Task<OnboardingResult> ResumeInstallationAsync(OnboardingPending pending,
        string serial, DeviceIdentity identity, WebIdentity? web, string agentPassword, CancellationToken ct)
    {
        var journal = "/data/local/tmp/zte-imei-installations/" + pending.Id;
        var state = await AdbTextAsync(serial, "cat " + Quote(journal + "/state"),
            TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        if (state is not ("ready" or "complete"))
            throw new InvalidOperationException("Предыдущая установка прервалась до готовности; сохранён удалённый журнал " + journal);
        if (!File.Exists(KeyPath)) throw new InvalidDataException("Отсутствует ключ незавершённой установки.");
        var verified = await PinAndVerifySshAsync(serial, identity, web, agentPassword, ct).ConfigureAwait(false);
        pending.RemoteJournal = journal;
        await CommitIfReadyAsync(pending, verified, agentPassword, ct).ConfigureAwait(false);
        await FinishAsync(pending, ct).ConfigureAwait(false);
        return new OnboardingResult(identity.Cid, identity.FirmwareHash, web?.Imei,
            KeyPath, KnownHostsPath, false, InstallerProfile(web, identity));
    }

    private async Task<DeviceIdentity> PinAndVerifySshAsync(string serial,
        DeviceIdentity device, WebIdentity? web, string agentPassword, CancellationToken ct)
    {
        if (await ReadAdbIdentityAsync(serial, web, ct).ConfigureAwait(false) != device)
            throw new InvalidDataException("CID изменился перед чтением SSH host key.");
        var raw = await AdbTextAsync(serial,
            "/data/bin/dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key",
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
        var ssh = new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        var reply = await ssh.RunAsync(web is null ? AccessIdentity.Command : IdentityCommand(), timeout: TimeSpan.FromSeconds(20), ct: ct)
            .ConfigureAwait(false);
        if (!reply.Success || (web is null ? AccessIdentity.Parse(reply.Stdout) : ParseIdentity(reply.Stdout, web, requireInstallerRouter: false)) != device)
            throw new InvalidDataException("SSH подключён к другому устройству после установки.");
        await VerifyAgentReadyAsync(ssh, ct).ConfigureAwait(false);
        if (InstallerProfile(web, device) == "b31")
        {
            var state = await new ImeiEngine(ssh, _storage, _resources, _skipFirmwareCheck)
                .InspectAsync(ct).ConfigureAwait(false);
            if (state.Identity.Cid != device.Cid || state.Imeis[0] != web!.Imei)
                throw new InvalidDataException("IMEI в NV и веб-интерфейсе различаются.");
        }
        else
        {
            if(InstallerProfile(web,device)=="linux-arm64-access")await VerifyDiscoveryAgentAsync(ssh,ct).ConfigureAwait(false);
            await AuthenticateAgentAsync(ssh, agentPassword, ct).ConfigureAwait(false);
        }
        return device;
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

    private async Task VerifyDiscoveryAgentAsync(SshTransport ssh,CancellationToken ct)
    {
        // Health is authenticated. Prove the running process mode without an
        // unauthenticated request; the separate login still verifies readiness.
        var reply=await ssh.RunAsync(DiscoveryAgentCommand(),timeout:TimeSpan.FromSeconds(20),ct:ct).ConfigureAwait(false);
        if(!reply.Success || !reply.Stdout.AsSpan().SequenceEqual("AGENT_DISCOVERY_READY"u8))
            throw new InvalidDataException("Пассивный режим агента не подтверждён; автоматическое продолжение запрещено.");
    }

    private static async Task VerifyAgentReadyAsync(SshTransport ssh, CancellationToken ct)
    {
        var reply = await ssh.RunAsync(
            "set -e; found=0; for p in $(pidof zte-agent); do if test \"$(readlink /proc/$p/exe)\" = /data/zte-agent; then found=1; fi; done; test \"$found\" = 1; printf AGENT_READY",
            timeout: TimeSpan.FromSeconds(15), ct: ct).ConfigureAwait(false);
        if (!reply.Success || StrictUtf8.GetString(reply.Stdout) != "AGENT_READY")
            throw new InvalidDataException("Агент установлен, но не запущен.");
    }

    private async Task CommitIfReadyAsync(OnboardingPending pending, DeviceIdentity device,
        string agentPassword, CancellationToken ct)
    {
        if (!pending.InstallRequested) return;
        var journal = "/data/local/tmp/zte-imei-installations/" + pending.Id;
        var stage = "/data/local/tmp/zte-imei-setup-" + pending.Id;
        var ssh = new SshTransport(_host, 2222, KeyPath, KnownHostsPath);
        if (pending.NewAgent is null)
        {
            var query = await ssh.RunAsync("if test -f " + Quote(journal + "/present/data_zte-agent") +
                "; then printf EXISTING; else printf NEW; fi", ct: ct).ConfigureAwait(false);
            if (!query.Success) throw new IOException("Не удалось определить состояние установленного агента.");
            pending.NewAgent = StrictUtf8.GetString(query.Stdout) == "NEW";
        }
        if (pending.NewAgent == true)
            await AuthenticateAgentAsync(ssh, agentPassword, ct).ConfigureAwait(false);
        var policy = InstallerPolicy(device, pending.Profile ?? "");
        var args = new[] { stage + "/setup-agent.sh", "--commit", journal }.Concat(policy).ToArray();
        var result = await ssh.RunAsync("sh " + string.Join(' ', args.Select(Quote)),
            timeout: TimeSpan.FromSeconds(40), ct: ct).ConfigureAwait(false);
        if (!result.Success || !StrictUtf8.GetString(result.Stdout).Contains("INSTALL_COMMITTED " + journal,
                StringComparison.Ordinal))
            throw new IOException("Установка готова, но журнал не удалось завершить.");
        pending.RemoteJournal = journal;
        pending.Phase = "complete";
        await SavePendingAsync(pending, ct).ConfigureAwait(false);
    }

    private async Task AuthenticateAgentAsync(SshTransport ssh, string password, CancellationToken ct)
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
                "id_ed25519.pub", "start-agent.sh", ".owner", ".install-requested" };
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
            pending.Phase is not ("prepared" or "restore-requested" or "install-requested" or "ready" or "complete" or "diagnostic-reboot-requested") ||
            (pending.RestoreRequested && pending.Phase == "prepared") ||
            (pending.InstallRequested && pending.Phase is "prepared" or "restore-requested") ||
            (!pending.InstallRequested && pending.Phase is "install-requested" or "ready" or "complete") ||
            !Path.GetFullPath(pending.BackupDirectory).StartsWith(
                Path.GetFullPath(Path.Combine(_storage, BackupFolder)) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Повреждён журнал незавершённой установки.");
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
