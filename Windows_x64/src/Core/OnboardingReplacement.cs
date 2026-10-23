using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Core;

internal sealed class CoreReplacementPending
{
    public int Schema { get; set; } = 1;
    public string Id { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; }
    public string KeyPath { get; set; } = "";
    public string KnownHostsPath { get; set; } = "";
    public string Cid { get; set; } = "";
    public string Firmware { get; set; } = "";
    public string Router { get; set; } = "";
    public string Boot { get; set; } = "";
    public bool PreserveSettings { get; set; }
    public string Phase { get; set; } = "prepared";
    public string AgentSha { get; set; } = "";
    public string InstallerSha { get; set; } = "";
    public string? PreviousSetupSha { get; set; }
    public string Stage => "/data/zte-imei-studio/stage-" + Id;
    public string Journal => "/data/zte-imei-studio/installations/" + Id;
    public DeviceIdentity Identity => new(Cid, Firmware, Boot, Router);
    public string[] Policy => [Cid, "linux-arm64-access", Firmware, Router, Boot];
}

public sealed partial class OnboardingEngine
{
    internal const string ReplacementPendingName = "core-replacement-pending.json";
    private string ReplacementPendingPath => Path.Combine(_storage, ReplacementPendingName);
    internal Func<CancellationToken, Task<byte[]>>? ReplacementPublicKey { get; init; }
    private string? _completedCoreReplacementId;
    private bool _replacementRequiresPhysicalUsb;
    internal string? ExpectedReplacementCid { get; set; }

    public async Task<OnboardingResult> ReplaceCoreAsync(string webPassword, string agentPassword,
        string backupKeySuffix, CancellationToken ct = default, bool preserveSettings = false)
    {
        // Only a separately recorded cleanup may be resumed. A legacy setup
        // flag without that intent must not create a new optional-data deletion.
        if (File.Exists(CleanupPendingPath) || Directory.Exists(CleanupPendingPath))
        {
            OnboardingResult old;
            var cleanup = await LoadUndispatchedCleanupRecoveryAsync(ct).ConfigureAwait(false);
            if(ExpectedReplacementCid is not null) {
                var recordedCid=File.Exists(CleanupPendingPath)
                    ? JsonSerializer.Deserialize<ComponentCleanupPending>(await File.ReadAllBytesAsync(CleanupPendingPath,ct).ConfigureAwait(false))?.Cid
                    : (await LoadPendingAsync(ct).ConfigureAwait(false))?.Cid;
                if(recordedCid!=ExpectedReplacementCid)throw new InvalidDataException("Предыдущая подготовка относится к другому модему.");
            }
            if (cleanup is not null && await RetireUndispatchedCleanupForReplacementAsync(cleanup,ct).ConfigureAwait(false))
                old = new OnboardingResult(cleanup.Cid,cleanup.FirmwareHash,null,cleanup.KeyPath,cleanup.KnownHostsPath,false,cleanup.Profile,AccessOnly:true,Port:cleanup.Port);
            else if (cleanup is not null)
                old = await CancelComponentCleanupAsync(ct).ConfigureAwait(false);
            else
            {
                old = await PrepareAsync(webPassword, agentPassword, backupKeySuffix, ct).ConfigureAwait(false);
                if (old.ComponentsCleaned) await AcknowledgeComponentCleanupAsync(old.CleanupId!, ct).ConfigureAwait(false);
            }
            if (ExpectedReplacementCid is not null && old.Cid != ExpectedReplacementCid) throw new InvalidDataException("Предыдущая подготовка относится к другому модему.");
            ExpectedReplacementCid=old.Cid;
            if (ExistingPort!=old.Port || ReuseKeyPath!=old.KeyPath || ReuseKnownHostsPath!=old.KnownHostsPath) ExistingSshFactory=null;
            ExistingPort=old.Port;ExistingKeyPath=old.KeyPath;ExistingKnownHostsPath=old.KnownHostsPath;
        }
        Directory.CreateDirectory(_storage);
        OnboardingResult? result;
        using (var localLock = new FileStream(Path.Combine(_storage, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            if (File.Exists(Path.Combine(_storage, "system-restore-pending.json")))
                throw new InvalidOperationException("Сначала завершите восстановление полного образа модема.");
            result = await ReplaceCoreOverSshAsync(agentPassword, preserveSettings, ct).ConfigureAwait(false);
        }
        if (result is not null) return result;
        await ReplaceLegacyUsbJournalAsync(ct).ConfigureAwait(false);
        result = await PrepareAsync(webPassword, agentPassword, backupKeySuffix, ct, forceReinstall: true).ConfigureAwait(false);
        var installed = InstalledSshFactory?.Invoke() ?? new SshTransport(_host,result.Port,result.KeyPath,result.KnownHostsPath);
        var proof = await AccessIdentity.ReadAsync(installed,ct).ConfigureAwait(false);
        if (proof.Cid!=result.Cid || proof.FirmwareHash!=result.FirmwareHash) throw new InvalidDataException("Устройство изменилось после подготовки.");
        var hashes=await VerifyAssetsAsync(ct).ConfigureAwait(false);
        var completed=new CoreReplacementPending{Id=Guid.NewGuid().ToString("D"),Host=_host,Port=result.Port,KeyPath=result.KeyPath,KnownHostsPath=result.KnownHostsPath,
            Cid=proof.Cid,Firmware=proof.FirmwareHash,Router=proof.RouterHash,Boot=proof.BootId,PreserveSettings=true,Phase="complete",AgentSha=hashes["zte-agent"],InstallerSha=hashes["setup-agent.sh"]};
        Directory.CreateDirectory(Path.Combine(_storage,"CoreReplacementBackups",completed.Id));
        await WriteJsonAsync(ReplacementPendingPath,completed,ct).ConfigureAwait(false);
        _completedCoreReplacementId=completed.Id;
        return result;
    }

    internal async Task AcknowledgeCoreReplacementAsync(CancellationToken ct = default)
    {
        if (!File.Exists(ReplacementPendingPath)) return;
        var plan = await ReadCoreReplacementAsync(ct).ConfigureAwait(false);
        if (plan.Phase != "complete") throw new InvalidDataException("Замена основных файлов ещё не подтверждена.");
        await WriteJsonAsync(Path.Combine(_storage, "CoreReplacementBackups", plan.Id, "replacement-result.json"), plan, ct).ConfigureAwait(false);
        File.Delete(ReplacementPendingPath);
    }

    internal async Task<string?> CompletedCoreReplacementIdAsync(CancellationToken ct = default)
    {
        if (!File.Exists(ReplacementPendingPath)) return null;
        var plan = await ReadCoreReplacementAsync(ct).ConfigureAwait(false);
        if (plan.Phase != "complete") throw new InvalidDataException("Замена основных файлов ещё не подтверждена.");
        return plan.Id;
    }

    private async Task<CoreReplacementPending> ReadCoreReplacementAsync(CancellationToken ct)
    {
        RejectReparsePoint(ReplacementPendingPath);
        if (new FileInfo(ReplacementPendingPath).Length is < 1 or > 65536) throw new InvalidDataException("Повреждён журнал замены.");
        var plan = JsonSerializer.Deserialize<CoreReplacementPending>(await File.ReadAllBytesAsync(ReplacementPendingPath, ct).ConfigureAwait(false))
            ?? throw new InvalidDataException("Повреждён журнал замены.");
        static bool Uuid(string value) => Guid.TryParseExact(value, "D", out var id) && value == id.ToString("D");
        static bool Hash(string value) => value.Length==64 && Regex.IsMatch(value, "^[a-f0-9]{64}$");
        if (plan.Schema != 1 || !Uuid(plan.Id) || !Uuid(plan.Boot) || !Regex.IsMatch(plan.Cid, "^[a-f0-9]{32}$") ||
            !Hash(plan.AgentSha) || !Hash(plan.InstallerSha) || plan.PreviousSetupSha is not null && !Hash(plan.PreviousSetupSha) ||
            new[]{plan.Firmware,plan.Router}.Any(x => x != "absent" && !Hash(x)) ||
            plan.Phase is not ("prepared" or "install-requested" or "ready" or "complete") ||
            plan.Host != _host || (_completedCoreReplacementId!=plan.Id && (plan.Port != ExistingPort || plan.KeyPath != ReuseKeyPath || plan.KnownHostsPath != ReuseKnownHostsPath)))
            throw new InvalidDataException("Журнал замены относится к другому подключению или повреждён.");
        return plan;
    }

    private async Task ReplaceLegacyUsbJournalAsync(CancellationToken ct)
    {
        using var localLock=new FileStream(Path.Combine(_storage,"operation.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        var old=await LoadPendingAsync(ct).ConfigureAwait(false);
        if(old is not { InstallRequested:true })return;
        var original=await File.ReadAllBytesAsync(PendingPath,ct).ConfigureAwait(false);
        await VerifyAssetsAsync(ct).ConfigureAwait(false);
        var found=await FindMatchingAdbAsync(null,ct).ConfigureAwait(false) ?? throw new InvalidDataException("Для продолжения подготовки подключите единственный модем с root USB ADB.");
        await VerifySingleUsbAsync(found.Serial,ct).ConfigureAwait(false);
        var proof=found.Identity;
        if(proof.Cid!=old.Cid || proof.FirmwareHash!=old.FirmwareHash || proof.RouterHash!=old.RouterHash || await ReadAdbIdentityAsync(found.Serial,null,ct).ConfigureAwait(false)!=proof)
            throw new InvalidDataException("USB относится к другому модему; прежний журнал сохранён.");
        var id=Guid.NewGuid().ToString("D");var directory=Path.Combine(_storage,"SetupBackups",id);Directory.CreateDirectory(directory);
        await WritePrivateAsync(Path.Combine(directory,"previous-setup-before-replacement.json"),original,ct).ConfigureAwait(false);
        var profile=InstallerProfile(null,proof);
        var fresh=new OnboardingPending{Id=id,Intent=profile=="linux-arm64-access"?"linux-arm64-access":"preparation",IdentitySource="single-usb",BackupDirectory=directory,Phase="prepared",ForceReinstall=true,CleanComponents=false,
            Cid=proof.Cid,FirmwareHash=proof.FirmwareHash,RouterHash=proof.RouterHash,BootId=proof.BootId,Profile=profile,AdbSerial=found.Serial};
        if(!(await File.ReadAllBytesAsync(PendingPath,ct).ConfigureAwait(false)).AsSpan().SequenceEqual(original))throw new InvalidDataException("Предыдущий журнал изменился.");
        await WriteJsonAsync(PendingPath,fresh,ct).ConfigureAwait(false);ExpectedReplacementCid=proof.Cid;
    }

    private async Task<bool> RetireUndispatchedCleanupForReplacementAsync(ComponentCleanupPending plan,CancellationToken ct)
    {
        using var localLock=new FileStream(Path.Combine(_storage,"operation.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        if(ExpectedReplacementCid is not null && plan.Cid!=ExpectedReplacementCid)throw new InvalidDataException("Предыдущая установка относится к другому модему.");
        var ssh=CleanupSshFactory?.Invoke() ?? ExistingSshFactory?.Invoke() ?? new SshTransport(plan.Host,plan.Port,plan.KeyPath,plan.KnownHostsPath);
        RemoteResult? first=null;
        try { first=await ssh.RunAsync(AccessIdentity.Command,timeout:TimeSpan.FromSeconds(20),ct:ct).ConfigureAwait(false); }
        catch(Exception e) when(!ct.IsCancellationRequested && e is IOException or SocketException or TimeoutException or SshTrustException) { }
        DeviceIdentity proof;
        if(first?.Success==true) {
            proof=AccessIdentity.Parse(first.Stdout);
            if(await AccessIdentity.ReadAsync(ssh,ct).ConfigureAwait(false)!=proof)throw new InvalidDataException("Идентичность модема изменилась.");
        } else {
            await VerifyAssetsAsync(ct).ConfigureAwait(false);
            var found=await FindMatchingAdbAsync(null,ct).ConfigureAwait(false) ?? throw new InvalidDataException("Для продолжения подготовки подключите единственный модем с root USB ADB.");
            await VerifySingleUsbAsync(found.Serial,ct).ConfigureAwait(false);proof=found.Identity;
            if(await ReadAdbIdentityAsync(found.Serial,null,ct).ConfigureAwait(false)!=proof)throw new InvalidDataException("Идентичность USB-модема изменилась.");
        }
        if(proof.Cid!=plan.Cid || proof.FirmwareHash!=plan.FirmwareHash || proof.RouterHash!=plan.RouterHash)throw new InvalidDataException("После перезагрузки обнаружено другое устройство; журнал сохранён.");
        if(proof.BootId==(plan.AcceptedBootId??plan.BootId))return false;
        Directory.CreateDirectory(plan.BackupDirectory);
        // Retire completed setup first so an interruption cannot schedule its old cleanup again.
        if(File.Exists(PendingPath)) {
            ValidateCleanupSetup(await LoadPendingAsync(ct).ConfigureAwait(false),plan);
            var bytes=await File.ReadAllBytesAsync(PendingPath,ct).ConfigureAwait(false);
            await WritePrivateAsync(Path.Combine(plan.BackupDirectory,"previous-setup-before-replacement.json"),bytes,ct).ConfigureAwait(false);
            if(!(await File.ReadAllBytesAsync(PendingPath,ct).ConfigureAwait(false)).AsSpan().SequenceEqual(bytes))throw new InvalidDataException("Предыдущий журнал изменился.");
            File.Delete(PendingPath);
        }
        return await ArchiveUndispatchedCleanupAfterRebootAsync(proof,ct).ConfigureAwait(false);
    }

    private async Task<OnboardingResult?> ReplaceCoreOverSshAsync(string agentPassword, bool preserveSettings, CancellationToken ct)
    {
        var saved = File.Exists(ReplacementPendingPath) ? await ReadCoreReplacementAsync(ct).ConfigureAwait(false) : null;
        if (saved is null && !preserveSettings && (!File.Exists(ReuseKeyPath) || !File.Exists(ReuseKnownHostsPath))) return null;
        if (saved is null && !preserveSettings)
        {
            var pins = await File.ReadAllLinesAsync(ReuseKnownHostsPath,ct).ConfigureAwait(false);
            var expectedHost="["+_host+"]:"+ExistingPort;
            if (!pins.Any(line=>line.Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() is { } hosts &&
                (hosts.StartsWith("|1|",StringComparison.Ordinal)||hosts.Split(',').Contains(expectedHost)||ExistingPort==22&&hosts.Split(',').Contains(_host)))) return null;
        }
        var ssh = ExistingSshFactory?.Invoke() ?? new SshTransport(_host, ExistingPort, ReuseKeyPath, ReuseKnownHostsPath);
        RemoteResult answer;
        try { answer = await ssh.RunAsync(AccessIdentity.Command, timeout: TimeSpan.FromSeconds(20), ct: ct).ConfigureAwait(false); }
        catch (SshTrustException) when (saved is null && !preserveSettings && ExpectedReplacementCid is { } cid && Regex.IsMatch(cid,"^[0-9a-f]{32}$")) { _replacementRequiresPhysicalUsb=true; return null; }
        catch (SshTrustException) { throw; }
        catch (Exception error) when (saved is null && !preserveSettings && error is SocketException or IOException or TimeoutException) { return null; }
        if (answer.ExitCode is -1 or 255 && saved is null && !preserveSettings) return null;
        if (!answer.Success) throw new InvalidDataException("SSH не подтвердил устройство перед заменой компонентов.");
        var identity = AccessIdentity.Parse(answer.Stdout);
        if (ExpectedReplacementCid is not null && identity.Cid != ExpectedReplacementCid) throw new InvalidDataException("SSH относится к другому модему.");
        if (await AccessIdentity.ReadAsync(ssh, ct).ConfigureAwait(false) != identity) throw new InvalidDataException("Устройство изменилось перед заменой.");
        var hashes = await VerifyAssetsAsync(ct).ConfigureAwait(false);
        var previous = await LoadPendingAsync(ct).ConfigureAwait(false);
        byte[]? previousBytes = null;
        if (previous is not null)
        {
            if (!previous.InstallRequested && (previous.Phase is not ("prepared" or "adb-ready") || previous.RestoreRequested || previous.DiagnosticRebootRequested || previous.DirectAdbRequested || previous.DirectAdbOutcome is not null || previous.Intent is not ("preparation" or "linux-arm64-access"))) return null;
            if (previous.Cid != identity.Cid || previous.FirmwareHash != identity.FirmwareHash || previous.RouterHash != identity.RouterHash)
                throw new InvalidDataException("Предыдущая установка относится к другому устройству; журнал сохранён.");
            previousBytes = await File.ReadAllBytesAsync(PendingPath, ct).ConfigureAwait(false);
        }
        var plan = saved ?? new CoreReplacementPending {
            Id = Guid.NewGuid().ToString("D"), Host = _host, Port = ExistingPort, KeyPath = ReuseKeyPath, KnownHostsPath = ReuseKnownHostsPath,
            Cid = identity.Cid, Firmware = identity.FirmwareHash, Router = identity.RouterHash, Boot = identity.BootId,
            PreserveSettings = preserveSettings, AgentSha = hashes["zte-agent"], InstallerSha = hashes["setup-agent.sh"],
            PreviousSetupSha = previousBytes is null ? null : Sha(previousBytes)
        };
        if (plan.Cid != identity.Cid || plan.Firmware != identity.FirmwareHash || plan.Router != identity.RouterHash)
            throw new InvalidDataException("Устройство изменилось; журнал замены сохранён.");
        if (plan.Boot != identity.BootId)
        {
            var old = Path.Combine(_storage,"CoreReplacementBackups",plan.Id); Directory.CreateDirectory(old);
            await WriteJsonAsync(Path.Combine(old,"before-reboot.json"),plan,ct).ConfigureAwait(false);
            plan.Boot = identity.BootId;
            if(plan.Phase!="complete") {
                plan.Id=Guid.NewGuid().ToString("D");plan.Phase="prepared";
                plan.AgentSha=hashes["zte-agent"];plan.InstallerSha=hashes["setup-agent.sh"];
            }
            await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
        }
        if (plan.Phase=="prepared" && (plan.AgentSha!=hashes["zte-agent"] || plan.InstallerSha!=hashes["setup-agent.sh"] || plan.PreserveSettings&&!preserveSettings))
        {
            var old=Path.Combine(_storage,"CoreReplacementBackups",plan.Id);Directory.CreateDirectory(old);
            await WriteJsonAsync(Path.Combine(old,"before-replacement.json"),plan,ct).ConfigureAwait(false);
            plan.Id=Guid.NewGuid().ToString("D");plan.AgentSha=hashes["zte-agent"];plan.InstallerSha=hashes["setup-agent.sh"];
            plan.PreserveSettings=preserveSettings;
        }
        var directory = Path.Combine(_storage,"CoreReplacementBackups",plan.Id); Directory.CreateDirectory(directory);
        if (previousBytes is not null)
        {
            if (plan.PreviousSetupSha != Sha(previousBytes)) throw new InvalidDataException("Предыдущий журнал изменился; замена остановлена.");
            await WritePrivateAsync(Path.Combine(directory,"previous-setup.json"),previousBytes,ct).ConfigureAwait(false);
        }
        async Task Observe()
        {
            if (await AccessIdentity.ReadAsync(ssh,ct).ConfigureAwait(false) != plan.Identity)
                throw new InvalidDataException("Устройство или загрузка изменились; журнал замены сохранён.");
        }
        async Task<string> Fixed(string command, byte[]? input = null, int seconds = 60)
        {
            var result = await ssh.RunAsync(command,input,TimeSpan.FromSeconds(seconds),ct).ConfigureAwait(false);
            if (!result.Success)
            {
                var codes = Encoding.UTF8.GetString(result.Stderr.AsSpan(0,Math.Min(result.Stderr.Length,16384))).Split('\n').Where(x=>x.StartsWith("INSTALL_ERROR ",StringComparison.Ordinal)).ToArray();
                var code = codes.Length==1 ? codes[0][14..].TrimEnd('\r') : "COMMAND_FAILED";
                if (!Regex.IsMatch(code,"^[A-Z][A-Z0-9_]{0,79}$")) code="COMMAND_FAILED";
                if (code=="AGENT_SETTINGS_REQUIRED") throw new IOException("Не удалось сохранить прежний пароль агента [AGENT_SETTINGS_REQUIRED]. Введите новый пароль в поле подготовки модема и выполните подготовку.");
                throw new IOException("Замена компонентов не подтверждена ["+code+"]. Журнал сохранён.");
            }
            return StrictUtf8.GetString(result.Stdout).TrimEnd('\r','\n');
        }
        var owner = string.Join(' ',new[]{plan.Id}.Concat(plan.Policy));
        var preserve = plan.PreserveSettings ? new[]{"--preserve-agent-settings"} : [];
        if (plan.Phase == "prepared")
        {
            if (plan.AgentSha != hashes["zte-agent"] || plan.InstallerSha != hashes["setup-agent.sh"])
                throw new InvalidDataException("Комплект замены изменился; журнал сохранён.");
            if (!plan.PreserveSettings && (string.IsNullOrEmpty(agentPassword) || agentPassword.Contains('\0')))
                throw new ArgumentException("Введите отдельный пароль агента для установки.",nameof(agentPassword));
            var startup = AgentStartup(plan.PreserveSettings ? "preserved-on-device" : agentPassword,"linux-arm64-access",_host);
            // Preflight may normalize private directories and archive stale owned journals.
            await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
            var preflight = await Fixed("sh -s -- "+string.Join(' ',preserve.Concat(new[]{"--preflight"}).Concat(plan.Policy).Select(Quote)),
                await File.ReadAllBytesAsync(Path.Combine(_resources,"Onboarding/setup-agent.sh"),ct).ConfigureAwait(false)).ConfigureAwait(false);
            if (preflight != "INSTALL_PREFLIGHT linux-arm64-access imei_config=unknown") throw new InvalidDataException("Предварительная проверка замены не подтверждена.");
            var publicKey = ReplacementPublicKey is null ? await CreateKeyAsync(ct).ConfigureAwait(false) : await ReplacementPublicKey(ct).ConfigureAwait(false);
            await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
            await Observe().ConfigureAwait(false);
            if (await Fixed(StagePreparationCommand(plan.Stage,owner)).ConfigureAwait(false) != "INSTALL_STAGE_READY") throw new InvalidDataException("Не подтверждён каталог замены.");
            var files = new Dictionary<string,byte[]>();
            foreach (var name in new[]{"zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh"})
                files[name]=await File.ReadAllBytesAsync(Path.Combine(_resources,"Onboarding",name),ct).ConfigureAwait(false);
            files["start-agent.sh"]=startup;files["id_ed25519.pub"]=publicKey;
            await VerifyGenericTimeoutAsync(ct).ConfigureAwait(false);
            files["zte-timeout"]=await File.ReadAllBytesAsync(Path.Combine(_resources,"HostTools/zte-timeout"),ct).ConfigureAwait(false);
            foreach (var (name,bytes) in files.OrderBy(x=>x.Key,StringComparer.Ordinal))
            {
                var target=plan.Stage+"/"+name;
                var incoming=plan.Stage+"/incoming-"+Guid.NewGuid().ToString("D");
                var command="set -eu; umask 077; test \"$(cat "+Quote(plan.Stage+"/.owner")+")\" = "+Quote(owner)+"; test ! -e "+Quote(plan.Stage+"/.install-requested")+"; test ! -L "+Quote(plan.Stage+"/.install-requested")+"; test ! -L "+Quote(target)+"; if test -e "+Quote(target)+"; then test -f "+Quote(target)+"; test \"$(stat -c %u:%h "+Quote(target)+")\" = 0:1; fi; (set -C; cat > "+Quote(incoming)+"); chmod 600 "+Quote(incoming)+"; test \"$(sha256sum "+Quote(incoming)+" | cut -d ' ' -f1)\" = "+Quote(Sha(bytes))+"; mv "+Quote(incoming)+" "+Quote(target)+"; sha256sum "+Quote(target);
                var output=await Fixed(command,bytes,120).ConfigureAwait(false);
                if (!output.StartsWith(Sha(bytes)+"  "+target,StringComparison.Ordinal)) throw new InvalidDataException("Переданный компонент замены повреждён.");
            }
            await Observe().ConfigureAwait(false);
            plan.Phase="install-requested";await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
            await Fixed("set -eu; umask 077; set -C; printf '%s\\n' "+Quote(owner)+" > "+Quote(plan.Stage+"/.install-requested")).ConfigureAwait(false);
            var args=preserve.Concat(new[]{plan.Stage,plan.Cid,plan.AgentSha,hashes["dropbear"],Sha(publicKey)}).Concat(plan.Policy.Skip(1));
            var receipt=await Fixed("set -eu; test \"$(sha256sum "+Quote(plan.Stage+"/setup-agent.sh")+" | cut -d ' ' -f1)\" = "+Quote(plan.InstallerSha)+"; sh "+Quote(plan.Stage+"/setup-agent.sh")+" "+string.Join(' ',args.Select(Quote)),seconds:180).ConfigureAwait(false);
            if (!receipt.Split('\n').Contains("INSTALL_READY "+plan.Journal)) throw new InvalidDataException("Готовность замены не подтверждена.");
            plan.Phase="ready";await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
        }
        if (plan.Phase=="install-requested")
        {
            var state=await Fixed(InstallationStateCommand(plan.Journal+"/state"),seconds:20).ConfigureAwait(false);
            if (state is "INSTALL_STATE MISSING" or "INSTALL_STATE preparing" or "INSTALL_STATE pending" or "INSTALL_STATE rolled-back")
            {
                await Observe().ConfigureAwait(false);
                await WriteJsonAsync(Path.Combine(directory,"before-recovery.json"),plan,ct).ConfigureAwait(false);
                plan.Id=Guid.NewGuid().ToString("D");plan.Phase="prepared";plan.AgentSha=hashes["zte-agent"];plan.InstallerSha=hashes["setup-agent.sh"];
                await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
                return await ReplaceCoreOverSshAsync(agentPassword,plan.PreserveSettings,ct).ConfigureAwait(false);
            }
            if (state is not ("INSTALL_STATE ready" or "INSTALL_STATE complete")) throw new InvalidDataException("Прерванная замена ещё не подтверждена; журнал и копия сохранены.");
            plan.Phase=state=="INSTALL_STATE complete"?"complete":"ready";await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
        }
        await Observe().ConfigureAwait(false);
        if(plan.Phase=="complete") {
            var probe=await ssh.RunAsync(AccessAgentReusePolicy.Command(false).Replace(AgentPackage.Sha256,plan.AgentSha,StringComparison.Ordinal),timeout:TimeSpan.FromSeconds(20),ct:ct).ConfigureAwait(false);
            if(probe.ExitCode==71) {
                var absence=await ssh.RunAsync(AccessAgentReusePolicy.AbsenceCommand(plan.AgentSha),timeout:TimeSpan.FromSeconds(30),ct:ct).ConfigureAwait(false);
                if(!absence.Success || !absence.Stdout.AsSpan().SequenceEqual(Encoding.UTF8.GetBytes("AGENT_ACCESS_ABSENT "+plan.AgentSha+"\n")))throw new InvalidDataException("Отсутствие завершённого агента не подтверждено; журнал сохранён.");
                await Observe().ConfigureAwait(false);await WriteJsonAsync(Path.Combine(directory,"before-agent-restart.json"),plan,ct).ConfigureAwait(false);
                plan.Id=Guid.NewGuid().ToString("D");plan.Phase="prepared";plan.PreserveSettings=preserveSettings;plan.AgentSha=hashes["zte-agent"];plan.InstallerSha=hashes["setup-agent.sh"];
                await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
                return await ReplaceCoreOverSshAsync(agentPassword,preserveSettings,ct).ConfigureAwait(false);
            }
            if(!probe.Success)throw new InvalidDataException("Не подтверждён процесс завершённого агента; журнал сохранён.");
        }
        var process=await AccessAgentReusePolicy.ReadExpectedAsync(ssh,plan.AgentSha,ct).ConfigureAwait(false);
        if (process.Sha256!=plan.AgentSha) throw new InvalidDataException("Процесс нового агента не подтверждён.");
        if (!plan.PreserveSettings && plan.AgentSha==hashes["zte-agent"] && plan.Phase!="complete") await AuthenticateAgentAsync(ssh,agentPassword,ct).ConfigureAwait(false);
        if (plan.Phase=="ready")
        {
            var command="set -eu; test \"$(sha256sum "+Quote(plan.Stage+"/setup-agent.sh")+" | cut -d ' ' -f1)\" = "+Quote(plan.InstallerSha)+"; sh "+Quote(plan.Stage+"/setup-agent.sh")+" "+string.Join(' ',new[]{"--commit",plan.Journal}.Concat(plan.Policy).Select(Quote));
            var receipt=await Fixed(command).ConfigureAwait(false);
            if (!receipt.Split('\n').Contains("INSTALL_COMMITTED "+plan.Journal)) throw new InvalidDataException("Завершение замены не подтверждено.");
            await Observe().ConfigureAwait(false);plan.Phase="complete";await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
        }
        if (plan.PreviousSetupSha is not null && File.Exists(PendingPath))
        {
            if (Sha(await File.ReadAllBytesAsync(PendingPath,ct).ConfigureAwait(false))!=plan.PreviousSetupSha) throw new InvalidDataException("Предыдущий журнал изменился; он сохранён.");
            File.Delete(PendingPath);
        }
        if (plan.AgentSha!=hashes["zte-agent"] || plan.InstallerSha!=hashes["setup-agent.sh"])
        {
            await WriteJsonAsync(Path.Combine(directory,"replacement-result.json"),plan,ct).ConfigureAwait(false);
            plan.Id=Guid.NewGuid().ToString("D");plan.Phase="prepared";plan.AgentSha=hashes["zte-agent"];plan.InstallerSha=hashes["setup-agent.sh"];
            plan.PreserveSettings=preserveSettings;plan.PreviousSetupSha=null;
            await WriteJsonAsync(ReplacementPendingPath,plan,ct).ConfigureAwait(false);
            return await ReplaceCoreOverSshAsync(agentPassword,preserveSettings,ct).ConfigureAwait(false);
        }
        _completedCoreReplacementId=plan.Id;
        return new OnboardingResult(plan.Cid,plan.Firmware,null,plan.KeyPath,plan.KnownHostsPath,false,"linux-arm64-access",AccessOnly:true,Port:plan.Port);
    }
}
