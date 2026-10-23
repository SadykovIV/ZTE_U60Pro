using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

internal static class DiagnosticAdbTests
{
    private static readonly WebIdentity B31 = new("353490068701222", "CN_ZTE_MU5250V1.0.0B31", "BD_CNMU5250V1.0.0B31");
    private const string Cid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Boot = "10000000-0000-0000-0000-000000000001";
    private static void Check(bool value,string name) { if(!value)throw new Exception(name); Console.WriteLine("PASS "+name); }
    public static async Task RunAsync(byte[] original,byte[] enabled,string testSuffix,bool knownFormatOnly=false)
    {
        var resources=Path.GetFullPath("Windows_x64/Resources");
        var root=Path.Combine(Path.GetTempPath(),"zte-diagnostic-adb-tests-"+Guid.NewGuid()); Directory.CreateDirectory(root);
        int index=0;
        (OnboardingEngine Engine,string Storage,Wire Web,Func<OnboardingEngine> Restart) Setup(bool ready=true,WebIdentity? identity=null,bool skip=false,
            IRemoteShell? replacementSsh=null,string? expectedReplacementCid=null)
        {
            var storage=Path.Combine(root,(index++).ToString());Directory.CreateDirectory(storage);
            var wire=new Wire(identity??B31,original) { Ready=ready };
            var adb=new AdbTransport((args,stream,_,_)=>
            {
                if(args.SequenceEqual(new[]{"devices","-l"}))
                {
                    wire.InventoryCount++;
                    if(wire.InventoryFailure)throw new IOException("synthetic inventory failure");
                    return Task.FromResult(Reply(wire.Ready?"ZTE device usb:1-2\n":"List of devices attached\n"));
                }
                if(args.SequenceEqual(new[]{"-d","get-serialno"}))return Task.FromResult(Reply("ZTE\n"));
                var command=stream?.OriginalCommand??args[^1];
                if(wire.CleanRecovery && command.Contains(" -- '--clean-reinstall' '--recover-owned' ",StringComparison.Ordinal))
                {
                    var arguments=Regex.Match(command,@" -- '--clean-reinstall' '--recover-owned' '([0-9a-f-]{36})' '([0-9a-f]{32})' 'linux-arm64-access' ");
                    if(!arguments.Success || !Guid.TryParseExact(arguments.Groups[1].Value,"D",out _) || arguments.Groups[2].Value!=wire.DeviceCid)
                        throw new Exception("Unexpected owned recovery arguments");
                    wire.RecoveryArchives++;
                    var marker=stream?.Result??Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    return Task.FromResult(Reply((stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n")+"INSTALL_RECOVERY_ARCHIVED /data/zte-imei-studio/installations/"+arguments.Groups[1].Value+"\n"+marker+"0\n"));
                }
                if(wire.CleanRecovery && command.Contains("'--preflight'",StringComparison.Ordinal))
                {
                    wire.RecoveryPreflights++;
                    throw new ReachedInstallerBoundary();
                }
                if(wire.StopAtPreflight && args.Count==4 && args[0]=="-s" && args[2]=="shell" && command.Contains("--preflight"))throw new ReachedInstallerBoundary();
                if(args.Count==4 && args[0]=="-s" && args[2]=="shell" && command.Contains("test \"$(id -u)\" = 0"))
                {
                    wire.ShellCount++;
                    var marker=stream?.Result??Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var boot=wire.ChangeBoot && wire.ShellCount>1?"20000000-0000-0000-0000-000000000002":Boot;
                    var proof=wire.ObservedFirmware+"  /firmware/image/modem.b16\n"+(wire.StopAfterAdb?ImeiEngine.RouterHash:new string('e',64))+"  /usr/bin/diag-router\n"+wire.DeviceCid+"\n"+boot+"\n"+(command.Contains("ubus call",StringComparison.Ordinal)?JsonSerializer.Serialize(new {imei=wire.Identity.Imei,integrate_version=wire.Identity.Firmware,wa_inner_version=wire.Identity.Inner}):"");
                    return Task.FromResult(Reply((stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n")+proof+"\n"+marker+"0\n"));
                }
                throw new Exception("Diagnostic path attempted a non-identity ADB command: "+string.Join(' ',args));
            },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
            OnboardingEngine CreateEngine()=>new OnboardingEngine("192.168.0.1",storage,resources,adb,skip,progress: message => { if(wire.StopAfterAdb && !wire.StopAtPreflight && message.StartsWith("USB ADB подтверждён:",StringComparison.Ordinal)) throw new ReachedInstallerBoundary(); }) {
                WebFactory=()=>new ModemWebClient("192.168.0.1",wire),
                ExistingSshFactory=replacementSsh is null?null:()=>replacementSsh,
                CleanupSshFactory=replacementSsh is null?null:()=>replacementSsh,
                ExpectedReplacementCid=expectedReplacementCid,
            };
            return (CreateEngine(),storage,wire,CreateEngine);
        }
        async Task Pending(string storage,bool reboot=false,string? firmware=null)
        {
            var dir=Path.Combine(storage,"ADBAccessBackups",Guid.NewGuid().ToString());Directory.CreateDirectory(dir);
            var p=new OnboardingPending {Intent="diagnostic-adb",Id=Guid.NewGuid().ToString(),WebIdentity=B31,BackupDirectory=dir,
                RestoreRequested=!reboot,DiagnosticRebootRequested=reboot,Phase=reboot?"diagnostic-reboot-requested":"restore-requested",Cid=Cid,FirmwareHash=firmware};
            await File.WriteAllTextAsync(Path.Combine(storage,"adb-access-pending.json"),JsonSerializer.Serialize(p));
        }
        try
        {
            foreach (var mode in new[]{"prepare","diagnostic"})
            {
                var activeNvScenario=Setup(true);
                using var activeImei=new FileStream(Path.Combine(activeNvScenario.Storage,"imei-operation.lock"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None);
                await Reject(async()=> { if(mode=="prepare") await activeNvScenario.Engine.PrepareAsync("pw","synthetic-password",testSuffix); else await activeNvScenario.Engine.EnableDiagnosticAdbAsync("pw",testSuffix); },"Active IMEI lock blocks access changes: "+mode);
                Check(activeNvScenario.Web.Requests==0&&activeNvScenario.Web.InventoryCount==0,"Active IMEI operation refused before transports: "+mode);
            }
            var builtin=OnboardingEngine.ResolveBackupKeySuffix(B31, "");
            var knownBackup=File.ReadAllBytes("Windows_x64/tests/fixtures/b31-auto-backup.synthetic.bin");
            var automatic=Setup(false);automatic.Web.Backup=knownBackup;automatic.Web.StopAfterAdb=true;
            foreach(var savedNvJournal in new[]{"imei-pending.json","pending.json"}) File.WriteAllText(Path.Combine(automatic.Storage,savedNvJournal),"saved NV recovery untouched");
            automatic.Web.VerifyUpload=bytes => Check(BackupPatch.Prepare(bytes,B31.Imei,builtin).AlreadyEnabled,"Automatic B31 backup upload passed unchanged codec validation");
            try { await automatic.Engine.PrepareAsync("pw","synthetic-agent-password",""); throw new Exception("Expected fixture boundary"); }
            catch(ReachedInstallerBoundary) { }
            Check(automatic.Web.Uploads==1 && automatic.Web.Restores==1 && automatic.Web.Reboots==0 && automatic.Web.ShellCount>0,"PrepareAsync empty B31 override reaches installer boundary after one verified restore");
            Check(new[]{"imei-pending.json","pending.json"}.All(journal=>File.ReadAllText(Path.Combine(automatic.Storage,journal))=="saved NV recovery untouched"),"SSH bootstrap preserves saved IMEI recovery journals");
            Check(!Directory.Exists(Path.Combine(automatic.Storage,"SSH")),"Automatic backup path fixture stops before SSH key or installer writes");
            var journalText=File.ReadAllText(Path.Combine(automatic.Storage,"setup-pending.json"));
            Check(!journalText.Contains(builtin,StringComparison.Ordinal) && !journalText.Contains("suffix",StringComparison.OrdinalIgnoreCase),"Resolved suffix is not persisted in the preparation journal");
            automatic.Web.FailEveryRequest=true;automatic.Web.StopAtPreflight=true;
            var callsBeforeResume=automatic.Web.Requests;
            try { await automatic.Engine.PrepareAsync("","synthetic-agent-password",""); throw new Exception("Expected fixture boundary"); }
            catch(ReachedInstallerBoundary) { }
            Check(automatic.Web.Requests==callsBeforeResume,"Saved restored identity binds ready USB resume without a Web password or HTTP calls");
            var restoredPending=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(Path.Combine(automatic.Storage,"setup-pending.json")))!;
            Check(automatic.Web.Uploads==1&&automatic.Web.Restores==1&&restoredPending.RestoreRequested&&!restoredPending.InstallRequested&&restoredPending.Phase=="adb-ready"&&OnboardingEngine.InstallationPaths(restoredPending).Stage.StartsWith("/data/zte-imei-studio/stage-",StringComparison.Ordinal),"Retry after restore selects private layout without replaying upload or restore");
            automatic.Web.DeviceCid=new string('b',32);
            await Reject(()=>automatic.Engine.PrepareAsync("","synthetic-agent-password",""),"Saved restoration refuses a changed USB CID before preflight");
            automatic.Web.DeviceCid=Cid;automatic.Web.Ready=false;
            await Reject(()=>automatic.Engine.PrepareAsync("","synthetic-agent-password",""),"Missing ready USB requires explicit Web credentials to resume");
            Check(automatic.Web.Requests==callsBeforeResume&&automatic.Web.Uploads==1&&automatic.Web.Restores==1,"Rejected restored resumes neither contact Web nor replay writes");
            foreach(var invalidOverride in new[]{"wrong-synthetic-suffix"," ",new string('x',129),"invalid\0suffix"})
            {
                var wrong=Setup(false);wrong.Web.Backup=knownBackup;
                await Reject(()=>wrong.Engine.PrepareAsync("pw","synthetic-agent-password",invalidOverride),"PrepareAsync wrong or invalid explicit override refuses automatic fallback");
                Check(wrong.Web.Uploads==0 && wrong.Web.Restores==0 && wrong.Web.Reboots==0,"Invalid explicit override refuses backup writes");
            }
            var diagnosticAutomatic=Setup(false);diagnosticAutomatic.Web.Backup=knownBackup;
            foreach(var savedNvJournal in new[]{"imei-pending.json","pending.json"}) File.WriteAllText(Path.Combine(diagnosticAutomatic.Storage,savedNvJournal),"saved NV recovery untouched");
            await diagnosticAutomatic.Engine.EnableDiagnosticAdbAsync("pw","");
            Check(new[]{"imei-pending.json","pending.json"}.All(journal=>File.ReadAllText(Path.Combine(diagnosticAutomatic.Storage,journal))=="saved NV recovery untouched"),"Diagnostic ADB preserves saved IMEI recovery journals");
            Check(diagnosticAutomatic.Web.Uploads==1 && diagnosticAutomatic.Web.Restores==1 && diagnosticAutomatic.Web.Reboots==0,"Diagnostic ADB empty override also uses one verified B31 backup restore");
            Check(!Directory.Exists(Path.Combine(diagnosticAutomatic.Storage,"SSH")) && !File.Exists(Path.Combine(diagnosticAutomatic.Storage,"setup-pending.json")),"Automatic diagnostic ADB does not install SSH or create preparation intent");
            var explicitValid=Setup(false);explicitValid.Web.StopAfterAdb=true;
            try { await explicitValid.Engine.PrepareAsync("pw","synthetic-agent-password",testSuffix); throw new Exception("Expected fixture boundary"); }
            catch(ReachedInstallerBoundary) { }
            Check(explicitValid.Web.Uploads==1 && explicitValid.Web.Restores==1,"PrepareAsync valid explicit override remains authoritative");
            foreach(var identity in new[]{new WebIdentity(B31.Imei,"FLY_CN_MU5250V1.0.0B13","BD_FLYMODEMMU5250V1.0.0B28"),new WebIdentity(B31.Imei,"OTHER_FW","OTHER_INNER")})
            {
                var other=Setup(false,identity);other.Web.Backup=knownBackup;other.Web.StopAfterAdb=true;
                try { await other.Engine.PrepareAsync("pw","synthetic-agent-password",""); throw new Exception("Expected fixture boundary"); }
                catch(ReachedInstallerBoundary) { }
                Check(other.Web.DebugRequests==0 && other.Web.Uploads==1 && other.Web.Restores==1 && other.Web.Reboots==0,"Unlisted firmware with explicit-absent USB method reaches validated backup restore once");
                Check(OnboardingEngine.ResolveBackupKeySuffix(identity,"")==builtin,"Known suffix is a candidate independent of firmware name");
            }
            var unlistedDirect=Setup(false,new(B31.Imei,"FLY_CN_MU5250V1.0.0B13","BD_FLYMODEMMU5250V1.0.0B28"));
            unlistedDirect.Web.UnknownIntrospection=true;unlistedDirect.Web.Backup="not-a-backup"u8.ToArray();
            unlistedDirect.Web.StopAfterAdb=true;
            try { await unlistedDirect.Engine.PrepareAsync("pw","synthetic-agent-password","wrong-unused-suffix"); throw new Exception("Expected fixture boundary"); }
            catch(ReachedInstallerBoundary) { }
            Check(unlistedDirect.Web.DebugRequests==1 && unlistedDirect.Web.Backups==0 && unlistedDirect.Web.Uploads==0 && unlistedDirect.Web.Restores==0,"Unknown introspection permits one known debug request on unlisted firmware without key dependency");
            var existingRoot=Setup(true);existingRoot.Web.StopAfterAdb=true;
            try { await existingRoot.Engine.PrepareAsync("pw","synthetic-agent-password","wrong-unused-suffix"); throw new Exception("Expected fixture boundary"); }
            catch(ReachedInstallerBoundary) { }
            Check(existingRoot.Web.Backups==0&&existingRoot.Web.DebugRequests==0&&existingRoot.Web.Uploads==0,"Existing bound root USB skips Web backup and activation");
            var unsupportedTemplate=Setup(false,new(B31.Imei,"UNLISTED_FW","UNLISTED_INNER"));
            var originalPlain=BackupCipher.Decrypt(knownBackup,B31.Imei+builtin);
            var originalArchive=BackupPatch.Inspect(originalPlain);
            var unsupportedInner=BackupGzip.Compress(originalArchive.Inner.Replace(new Dictionary<string,byte[]>{{BackupPatch.RcPath,"#!/bin/sh\n# /sys/class/android_usb/android0/usb_op\nexit 0\n"u8.ToArray()}}));
            var unsupportedOuter=BackupGzip.Compress(originalArchive.Outer.Replace(new Dictionary<string,byte[]>{{"tmp/back_parameter_r1.tgz",unsupportedInner},{"tmp/back_parameter_r.md5",Encoding.ASCII.GetBytes(Convert.ToHexString(System.Security.Cryptography.MD5.HashData(unsupportedInner)).ToLowerInvariant()+"\n")}}));
            unsupportedTemplate.Web.Backup=BackupCipher.Encrypt(unsupportedOuter,B31.Imei+builtin);
            await unsupportedTemplate.Engine.VerifyBackupKeyAsync("pw");
            await Reject(()=>unsupportedTemplate.Engine.PrepareAsync("pw","synthetic-agent-password",""),"Successful key/format check cannot authorize unsupported boot template");
            Check(unsupportedTemplate.Web.Uploads==0&&unsupportedTemplate.Web.Restores==0&&unsupportedTemplate.Web.Reboots==0,"Unsupported rc.local fails before upload or restore");
            var corrupt=Setup(false);corrupt.Web.Backup=knownBackup.ToArray();corrupt.Web.Backup[^1]^=1;
            await Reject(()=>corrupt.Engine.PrepareAsync("pw","synthetic-agent-password",""),"Automatic suffix does not accept a corrupted encrypted backup");
            Check(corrupt.Web.Uploads==0 && corrupt.Web.Restores==0 && corrupt.Web.Reboots==0,"Invalid automatic backup refuses all backup writes");
            foreach(var scenario in new[]{"direct","backup","interrupted-direct","wrong-cid","single-usb"})
            {
                var recovery=Setup(false);recovery.Web.CleanRecovery=true;recovery.Web.ObservedFirmware="absent";
                recovery.Web.Advertise=scenario!="backup";recovery.Web.Backup=knownBackup;
                var id=Guid.NewGuid().ToString();var directory=Path.Combine(recovery.Storage,"SetupBackups",id);Directory.CreateDirectory(directory);
                var saved=new OnboardingPending {Id=id,Intent="linux-arm64-access",IdentitySource=scenario=="single-usb"?"single-usb":"web-matched",WebIdentity=scenario=="single-usb"?null:B31,BackupDirectory=directory,
                    Cid=Cid,FirmwareHash="absent",RouterHash=new string('e',64),BootId="22222222-2222-2222-2222-222222222222",Profile="linux-arm64-access",AdbSerial="ZTE",
                    InstallRequested=true,Phase="install-requested",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                var path=Path.Combine(recovery.Storage,"setup-pending.json");var old=JsonSerializer.Serialize(saved);await File.WriteAllTextAsync(path,old);
                var intact=false;recovery.Web.OnActivation=()=>
                {
                    intact=File.ReadAllText(path)==old;
                    if(scenario=="wrong-cid")recovery.Web.DeviceCid=new string('b',32);
                    if(scenario=="interrupted-direct")throw new ReachedInstallerBoundary();
                };
                try{await recovery.Engine.PrepareAsync("pw","synthetic-new-password","",cleanComponents:true);throw new Exception("Expected boundary");}
                catch(ReachedInstallerBoundary){}
                catch(InvalidDataException) when(scenario=="wrong-cid"){}
                if(scenario=="interrupted-direct")
                {
                    Check(File.ReadAllText(path)==old&&File.Exists(Path.Combine(recovery.Storage,"adb-access-pending.json")),"Interrupted ADB activation preserves both durable intents");
                    recovery.Web.OnActivation=null;
                    try{await recovery.Engine.PrepareAsync("pw","synthetic-new-password","",cleanComponents:true);throw new Exception("Expected boundary");}
                    catch(ReachedInstallerBoundary){}
                }
                Check(intact,"Old dispatched intent remains exact during Web ADB recovery: "+scenario);
                if(scenario=="wrong-cid")Check(File.ReadAllText(path)==old&&recovery.Web.RecoveryPreflights==0&&recovery.Web.RecoveryArchives==0,"Wrong recovered USB CID never archives old installation");
                else
                {
                    var next=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(path))!;
                    Check(next.Id!=id&&!next.InstallRequested&&next.CleanComponents&&recovery.Web.RecoveryPreflights==1&&recovery.Web.RecoveryArchives==1,"Disabled ADB recovery reaches a fresh clean installer preflight after exact archive receipt: "+scenario);
                    Check(!File.Exists(Path.Combine(recovery.Storage,"adb-access-pending.json")),"Verified ADB activation closes its separate journal: "+scenario);
                }
                Check(recovery.Web.DebugRequests==(scenario=="backup"?0:1)&&recovery.Web.Restores==(scenario=="backup"?1:0),"Clean recovery sends each activation only once: "+scenario);
            }
            foreach(var scenario in new[]{"same-cid","wrong-cid","wrong-cid-web","no-usb-web","unknown-cid"})
            {
                var pinShell=new PinMismatchShell();
                var recovery=Setup(ready:scenario!="no-usb-web",replacementSsh:pinShell,expectedReplacementCid:scenario=="unknown-cid"?null:Cid);
                Directory.CreateDirectory(Path.Combine(recovery.Storage,"SSH"));
                await File.WriteAllTextAsync(Path.Combine(recovery.Storage,"SSH/id_ed25519"),"synthetic key");
                await File.WriteAllTextAsync(Path.Combine(recovery.Storage,"SSH/known_hosts"),"[192.168.0.1]:2222 ssh-ed25519 synthetic\n");
                recovery.Web.StopAtPreflight=true;
                if(scenario.StartsWith("wrong-cid",StringComparison.Ordinal))recovery.Web.DeviceCid=new string('b',32);
                var reached=false;
                try { await recovery.Engine.ReplaceCoreAsync(scenario.EndsWith("-web",StringComparison.Ordinal)?"web-password":"","synthetic-agent-password",testSuffix);throw new Exception("Expected fixture boundary/refusal"); }
                catch(ReachedInstallerBoundary) { reached=true; }
                catch(SshTrustException) when(scenario=="unknown-cid") { }
                catch(InvalidOperationException error) when(scenario.StartsWith("wrong-cid",StringComparison.Ordinal)&&error.Message.Contains("другому модему",StringComparison.Ordinal)) { }
                catch(InvalidOperationException error) when(scenario=="no-usb-web"&&error.Message.Contains("USB",StringComparison.Ordinal)) { }
                Check(reached==(scenario=="same-cid"),"Changed SSH pin requires matching measured USB CID before preflight: "+scenario);
                Check(pinShell.Calls==1&&recovery.Web.Mutations==0,"Changed SSH pin did not trigger Web writes: "+scenario);
                Check(scenario=="unknown-cid"?recovery.Web.InventoryCount==0:scenario=="no-usb-web"?recovery.Web.InventoryCount>0&&recovery.Web.ShellCount==0:recovery.Web.ShellCount>0,"Known hardware identity is required before changed-pin USB fallback: "+scenario);
            }
            foreach(var pin in new[]{"missing","empty","other-host"})
            {
                var missingPinShell=new NeverShell();var recovery=Setup(replacementSsh:missingPinShell);recovery.Web.StopAtPreflight=true;
                Directory.CreateDirectory(Path.Combine(recovery.Storage,"SSH"));
                await File.WriteAllTextAsync(Path.Combine(recovery.Storage,"SSH/id_ed25519"),"synthetic key");
                if(pin!="missing")await File.WriteAllTextAsync(Path.Combine(recovery.Storage,"SSH/known_hosts"),pin=="empty"?"":"[192.0.2.2]:2222 ssh-ed25519 synthetic\n");
                try { await recovery.Engine.ReplaceCoreAsync("","synthetic-agent-password",testSuffix);throw new Exception("Expected installer boundary"); }
                catch(ReachedInstallerBoundary) { }
                Check(missingPinShell.Calls==0&&recovery.Web.ShellCount>0&&recovery.Web.Mutations==0,"Missing selected host pin uses measured USB bootstrap: "+pin);
            }
            foreach(var scenario in new[]{"new-boot","same-boot","wrong-cid","foreign-setup","foreign-plan","dispatched"})
            {
                var offlineShell=new UnavailableReadShell();var recovery=Setup(replacementSsh:offlineShell,expectedReplacementCid:Cid);
                recovery.Web.StopAtPreflight=true;
                if(scenario=="wrong-cid"||scenario=="foreign-plan")recovery.Web.DeviceCid=new string('b',32);
                var id=Guid.NewGuid().ToString("D");var oldBoot=scenario=="same-boot"?Boot:"11111111-1111-1111-1111-111111111111";
                var backup=Path.Combine(recovery.Storage,"SetupBackups",id);Directory.CreateDirectory(backup);Directory.CreateDirectory(Path.Combine(recovery.Storage,"SSH"));
                var key=Path.Combine(recovery.Storage,"SSH/id_ed25519");var hosts=Path.Combine(recovery.Storage,"SSH/known_hosts");
                await File.WriteAllTextAsync(key,"synthetic key");await File.WriteAllTextAsync(hosts,"[192.168.0.1]:2222 ssh-ed25519 synthetic\n");
                var setup=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=oldBoot,
                    FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=new string('e',64),Profile="linux-arm64-access",ForceReinstall=true,CleanComponents=true,
                    InstallRequested=true,Phase="complete",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                if(scenario=="foreign-setup")setup.Cid=new string('c',32);
                if(scenario=="foreign-plan")setup.Cid=new string('b',32);
                var setupPath=Path.Combine(recovery.Storage,"setup-pending.json");var receipt=Path.Combine(backup,"setup-result.json");
                var setupBytes=JsonSerializer.SerializeToUtf8Bytes(setup);await File.WriteAllBytesAsync(setupPath,setupBytes);await File.WriteAllBytesAsync(receipt,setupBytes);
                var plan=new ComponentCleanupPending{Id=id,Cid=Cid,BootId=oldBoot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=new string('e',64),Host="192.168.0.1",
                    KeyPath=key,KnownHostsPath=hosts,BackupDirectory=backup,SetupReceipt=receipt,Profile="linux-arm64-access",Token=Guid.NewGuid().ToString("D")};
                if(scenario=="foreign-plan")plan.Cid=new string('b',32);
                if(scenario=="dispatched")
                {
                    var archive=Encoding.UTF8.GetBytes("synthetic preserved components");await File.WriteAllBytesAsync(Path.Combine(backup,"components.tar"),archive);
                    plan.Phase="clean-requested";plan.ArchiveSha=VerifiedHash.Sha256(archive);plan.ArchiveBytes=archive.Length;
                }
                var pending=Path.Combine(recovery.Storage,OnboardingEngine.CleanupPendingName);var originalIntent=JsonSerializer.SerializeToUtf8Bytes(plan);
                await File.WriteAllBytesAsync(pending,originalIntent);
                var reached=false;
                try{await recovery.Engine.ReplaceCoreAsync("web-password","synthetic-agent-password",testSuffix);throw new Exception("Expected preflight/refusal boundary");}
                catch(ReachedInstallerBoundary){reached=true;}
                catch(Exception error) when(scenario!="new-boot"&&(error is IOException or InvalidDataException or InvalidOperationException)){}
                Check(reached==(scenario=="new-boot"),"Only undispatched same-device new USB boot can replace stale cleanup: "+scenario);
                Check(recovery.Web.Mutations==0&&offlineShell.Commands.All(command=>!command.Contains(" -- 'clean' ",StringComparison.Ordinal)),"Old cleanup recovery dispatches no cleanup/Web writes: "+scenario);
                if(scenario=="new-boot")
                {
                    var histories=Directory.GetFiles(backup,"cleanup-before-reset-*.json");
                    Check(!File.Exists(pending)&&histories.Length==1&&File.ReadAllBytes(histories[0]).SequenceEqual(originalIntent),"Retired cleanup retains exact old intent");
                    Check(File.ReadAllBytes(receipt).SequenceEqual(setupBytes),"Retiring stale cleanup preserves completed setup receipt");
                }
                else Check(File.ReadAllBytes(pending).SequenceEqual(originalIntent)&&File.ReadAllBytes(setupPath).SequenceEqual(setupBytes),"Rejected stale cleanup recovery preserves durable intents: "+scenario);
            }
            foreach(var scenario in new[]{"same-cid","completed-clean-setup","wrong-cid","changed-proof","stale-firmware","foreign-journal"})
            {
                var expectedPreflight=scenario is "same-cid" or "completed-clean-setup";
                var oldSetupShell=new UnavailableReadShell();var recovery=Setup(replacementSsh:oldSetupShell,expectedReplacementCid:Cid);
                recovery.Web.StopAtPreflight=true;
                if(scenario=="wrong-cid"||scenario=="foreign-journal")recovery.Web.DeviceCid=new string('b',32);
                if(scenario=="changed-proof")recovery.Web.ChangeBoot=true;
                var id=Guid.NewGuid().ToString("D");var backup=Path.Combine(recovery.Storage,"SetupBackups",id);Directory.CreateDirectory(backup);
                Directory.CreateDirectory(Path.Combine(recovery.Storage,"SSH"));
                await File.WriteAllTextAsync(Path.Combine(recovery.Storage,"SSH/id_ed25519"),"synthetic key");
                await File.WriteAllTextAsync(Path.Combine(recovery.Storage,"SSH/known_hosts"),"[192.168.0.1]:2222 ssh-ed25519 synthetic\n");
                var previous=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,
                    BootId="11111111-1111-1111-1111-111111111111",FirmwareHash=scenario=="stale-firmware"?new string('f',64):ImeiEngine.FirmwareHash,RouterHash=new string('e',64),Profile="linux-arm64-access",
                    InstallRequested=true,Phase="install-requested",AdbSerial="ZTE",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                if(scenario=="completed-clean-setup"){previous.Phase="complete";previous.CleanComponents=true;previous.ForceReinstall=true;}
                var pendingPath=Path.Combine(recovery.Storage,"setup-pending.json");var originalSetup=JsonSerializer.SerializeToUtf8Bytes(previous);
                if(scenario=="foreign-journal"){previous.Cid=new string('b',32);originalSetup=JsonSerializer.SerializeToUtf8Bytes(previous);}
                await File.WriteAllBytesAsync(pendingPath,originalSetup);
                var reached=false;
                try{await recovery.Engine.ReplaceCoreAsync("web-password","synthetic-agent-password",testSuffix);throw new Exception("Expected preflight/refusal boundary");}
                catch(ReachedInstallerBoundary){reached=true;}
                catch(Exception error) when(!expectedPreflight&&(error is IOException or InvalidDataException or InvalidOperationException)){}
                Check(reached==expectedPreflight,"Dispatched setup replacement requires two bound USB proofs: "+scenario);
                Check(recovery.Web.Mutations==0&&recovery.Web.RecoveryArchives==0&&oldSetupShell.Commands.All(command=>command==AccessIdentity.Command),"Fresh replacement never executes previous helper or Web activation: "+scenario);
                if(expectedPreflight)
                {
                    var next=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(pendingPath))!;
                    Check(next.Id!=id&&!next.InstallRequested&&next.Cid==Cid&&next.FirmwareHash==ImeiEngine.FirmwareHash&&next.RouterHash==new string('e',64)&&next.BootId==Boot,
                        "New undispatched setup uses current measured USB identity");
                    Check(Directory.EnumerateFiles(recovery.Storage,"*.json",SearchOption.AllDirectories).Where(path=>path!=pendingPath).Any(path=>File.ReadAllBytes(path).SequenceEqual(originalSetup)),"Superseded dispatched setup retains exact original JSON");
                    try{await recovery.Restart().ReplaceCoreAsync("web-password","synthetic-agent-password",testSuffix);throw new Exception("Expected resumed preflight boundary");}
                    catch(ReachedInstallerBoundary){}
                    var resumed=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(pendingPath))!;
                    Check(resumed.Id==next.Id&&!resumed.InstallRequested&&recovery.Web.Mutations==0,"Fresh USB-only replacement intent resumes after host restart with entered Web password");
                }
                else Check(File.ReadAllBytes(pendingPath).SequenceEqual(originalSetup),"Rejected old setup replacement preserves original intent: "+scenario);
            }
            if(knownFormatOnly)return;
            var current=Setup(identity:new(B31.Imei,"CN_ZTE_MU5250V1.0.0B27","BD_CNMU5250V1.0.0B27"));
            var result=await current.Engine.EnableDiagnosticAdbAsync("web-password");
            Check(result.AlreadyAvailable && current.Web.ShellCount==2 && current.Web.InventoryCount==2 && current.Web.Backups==0 && current.Web.Mutations==0,
                "Diagnostic ADB accepts existing root on unlisted router without installer, backup or mutation; verifies twice");
            Check(!Directory.Exists(Path.Combine(current.Storage,"SSH")) && !File.Exists(Path.Combine(current.Storage,"setup-pending.json")),"Diagnostic ADB creates no SSH keys or preparation journal");
            var swapped=Setup();swapped.Web.ChangeBoot=true;
            await Reject(()=>swapped.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Final boot change blocks diagnostic success");
            Check(swapped.Web.Mutations==0,"Final identity mismatch does not mutate modem");
            foreach(var reboot in new[]{false,true})
            {
                var resume=Setup();await Pending(resume.Storage,reboot);resume.Web.FailEveryRequest=true;
                await resume.Engine.EnableDiagnosticAdbAsync("");
                Check(resume.Web.Requests==0 && resume.Web.ShellCount==2 && !File.Exists(Path.Combine(resume.Storage,"adb-access-pending.json")),
                    (reboot?"Reboot":"Restore")+" resume completes through USB without any Web request or replay");
            }
            var changed=Setup();await Pending(changed.Storage,firmware:new string('b',64));changed.Web.FailEveryRequest=true;
            await Reject(()=>changed.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Saved diagnostic firmware hash binds resume");
            Check(File.Exists(Path.Combine(changed.Storage,"adb-access-pending.json")),"Failed identity confirmation preserves pending journal");
            var blocked=Setup();File.WriteAllText(Path.Combine(blocked.Storage,"setup-pending.json"),"{}");
            await Reject(()=>blocked.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Pending setup blocks diagnostic ADB before transport requests");
            Check(blocked.Web.Requests==0,"Competing setup performs no Web calls");
            var inverse=Setup();await Pending(inverse.Storage);
            await Reject(()=>inverse.Engine.PrepareAsync("pw","agent-password",testSuffix),"Pending diagnostic ADB blocks regular setup");
            var inventory=Setup(ready:false);inventory.Web.InventoryFailure=true;
            await Reject(()=>inventory.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Initial ADB inventory failure stops activation");
            Check(inventory.Web.Backups==0 && inventory.Web.Mutations==0,"Inventory failure cannot trigger USB/restore/reboot");
            var unlisted=Setup(false,new(B31.Imei,"UNLISTED_FW","UNLISTED_INNER"));unlisted.Web.Backup=knownBackup;
            await unlisted.Engine.EnableDiagnosticAdbAsync("pw", "");
            Check(unlisted.Web.Restores==1&&unlisted.Web.Uploads==1&&unlisted.Web.DebugRequests==0,"Diagnostic ADB fallback validates unknown firmware archive without skip checkbox");
            var busy=Setup();using(var file=new FileStream(Path.Combine(busy.Storage,"operation.lock"),FileMode.Create,FileAccess.ReadWrite,FileShare.None))
            {
                await Reject(()=>busy.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Active terminal/operation lock blocks diagnostic activation");
                Check(busy.Web.Requests==0,"Busy operation lock stops before Web");
            }
            var imeiBusy=Setup();using(var file=new FileStream(Path.Combine(imeiBusy.Storage,"imei-operation.lock"),FileMode.Create,FileAccess.ReadWrite,FileShare.None))
            {
                await Reject(()=>imeiBusy.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Active IMEI lock blocks diagnostic activation");
                Check(imeiBusy.Web.Requests==0,"IMEI lock stops diagnostic activation before Web");
            }
            foreach (var suffix in new[] { "", "wrong-synthetic-suffix" })
            {
                var noKey=Setup(false);noKey.Web.Backup=enabled;
                await Reject(()=>noKey.Engine.EnableDiagnosticAdbAsync("pw",suffix),"Unmatched automatic format or wrong explicit suffix stops B31 activation");
                Check(noKey.Web.Reboots==0 && noKey.Web.Restores==0 && noKey.Web.Uploads==0,"Invalid suffix cannot authorize B31 reboot or restore");
                Check(!File.ReadAllText(Path.Combine(noKey.Storage,"adb-access-pending.json")).Contains("suffix",StringComparison.OrdinalIgnoreCase),"Backup suffix is never written to the pending journal");
            }
            var rebootCase=Setup(false);rebootCase.Web.Backup=enabled;rebootCase.Web.LoseRebootAcknowledgement=true;
            await rebootCase.Engine.EnableDiagnosticAdbAsync("pw", testSuffix);
            Check(rebootCase.Web.Reboots==1 && rebootCase.Web.Restores==0 && rebootCase.Web.Uploads==0 && rebootCase.Web.ShellCount==2,
                "B31 already-enabled backup triggers exactly one stock reboot, no restore; lost acknowledgement still verifies ADB");
            var interrupted=Setup(false);interrupted.Web.Backup=enabled;interrupted.Web.CancelReboot=true;
            await Reject(()=>interrupted.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Interrupted diagnostic reboot retains intent");
            var journal=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllText(Path.Combine(interrupted.Storage,"adb-access-pending.json")))!;
            Check(journal.DiagnosticRebootRequested && journal.Phase=="diagnostic-reboot-requested","Diagnostic reboot intent is durable before cancellation");
            interrupted.Web.Ready=true;interrupted.Web.FailEveryRequest=true;var count=interrupted.Web.Requests;
            await interrupted.Engine.EnableDiagnosticAdbAsync("");
            Check(interrupted.Web.Reboots==1 && interrupted.Web.Requests==count,"Interrupted reboot resumes read-only without Web or duplicate reboot");
            var restore=Setup(false);await restore.Engine.EnableDiagnosticAdbAsync("pw", testSuffix);
            Check(restore.Web.Restores==1 && restore.Web.Reboots==0 && restore.Web.Uploads==1,"B31 missing boot line uses one verified upload/restore only");
            var direct=Setup(false,new(B31.Imei,"CN_ZTE_MU5250V1.0.0B27","BD_CNMU5250V1.0.0B27"),true);direct.Web.Advertise=true;
            await direct.Engine.EnableDiagnosticAdbAsync("pw");
            Check(direct.Web.DebugRequests==1 && direct.Web.Restores==0 && direct.Web.Reboots==0,"Advertised legacy diagnostic method succeeds without B31 restore or installer");
            var guardStorage=Path.Combine(root,"guard");Directory.CreateDirectory(guardStorage);File.WriteAllText(Path.Combine(guardStorage,"adb-access-pending.json"),"{}");
            var shell=new NeverShell();var features=new DeviceFeatureService(shell,resources,guardStorage);
            await Reject(()=>features.MutateAsync((_,_)=>Task.FromResult(1),CancellationToken.None),"Feature writes reject pending diagnostic journal before remote commands");
            Check(shell.Calls==0,"Pending diagnostic guard prevents device commands");
        }
        finally {Directory.Delete(root,true);}
    }
    private static async Task Reject(Func<Task> action,string name) {try {await action();}catch {Check(true,name);return;}throw new Exception("Unexpectedly accepted: "+name);}
    private static RemoteResult Reply(string text)=>new(0,Encoding.UTF8.GetBytes(text),[]);
    private sealed class NeverShell:IRemoteShell
    {
        public int Calls;
        public Task UploadAsync(string path,byte[] bytes,TimeSpan? timeout=null,CancellationToken ct=default) => throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default) => throw new Exception("Unexpected download");
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default) {Calls++;throw new Exception("Unexpected remote command");}
    }
    private sealed class PinMismatchShell:IRemoteShell
    {
        public int Calls;
        public Task UploadAsync(string path,byte[] bytes,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            Calls++;
            if(command!=AccessIdentity.Command)throw new Exception("Unexpected command after SSH pin rejection");
            throw new SshTrustException("Synthetic changed pinned SSH key",new IOException("synthetic"));
        }
    }
    private sealed class UnavailableReadShell:IRemoteShell
    {
        public List<string> Commands=[];
        public Task UploadAsync(string path,byte[] bytes,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {Commands.Add(command);return Task.FromResult(new RemoteResult(255,[],Encoding.UTF8.GetBytes("Connection refused")));}
    }
    private sealed class ReachedInstallerBoundary:Exception { }
    private sealed class Wire(WebIdentity identity,byte[] original):IWebTransport
    {
        public WebIdentity Identity=identity;
        public string DeviceCid=Cid,ObservedFirmware=ImeiEngine.FirmwareHash;
        public bool CleanRecovery;public int RecoveryPreflights,RecoveryArchives;public Action? OnActivation;
        public byte[] Backup=original;
        public bool Ready,ChangeBoot,InventoryFailure,FailEveryRequest,Advertise,LoseRebootAcknowledgement,CancelReboot,StopAfterAdb,StopAtPreflight,UnknownIntrospection;
        public Action<byte[]>? VerifyUpload;
        public int Requests,InventoryCount,ShellCount,Backups,Reboots,Restores,Uploads,DebugRequests;
        public int Mutations=>Backups+Reboots+Restores+Uploads+DebugRequests;
        public Task<WebReply> RequestAsync(string path,byte[]? data=null,string? contentType=null,string? cookie=null,CancellationToken ct=default)
        {
            Requests++;if(FailEveryRequest)throw new Exception("Resume unexpectedly contacted Web");
            var headers=new Dictionary<string,string[]>();
            if(path=="/backup/back_parameter")return Task.FromResult(new WebReply(Backup,headers));
            if(path!="/ubus/")
            {
                Uploads++; var start=data!.AsSpan().IndexOf("Salted__"u8);var boundary=contentType!.Split("boundary=")[1];
                var trailer=Encoding.UTF8.GetByteCount("\r\n--"+boundary+"--\r\n");
                VerifyUpload?.Invoke(data![start..^trailer]);
                return Json(JsonSerializer.Serialize(new {sha256sum=VerifiedHash.Sha256(data![start..^trailer])}));
            }
            using var doc=JsonDocument.Parse(data!);var request=doc.RootElement[0];
            if(request.GetProperty("method").GetString()=="list")return Json(UnknownIntrospection?"[{\"error\":{\"code\":-32601}}]":Advertise?"[{\"result\":{\"zwrt_bsp.usb\":{\"set\":{\"mode\":\"string\"}}}}]":"[{\"result\":{\"zwrt_bsp.usb\":{\"list\":{}}}}]");
            var p=request.GetProperty("params");var method=p[2].GetString();object reply=new{};
            switch(method)
            {
                case "web_login_info":reply=new {zte_web_sault="synthetic"};break;
                case "web_login":reply=new {result=0,ubus_rpc_session="11111111111111111111111111111111"};headers["Set-Cookie"]=["webtoken=synthetic-cookie; Path=/"];break;
                case "device_info":reply=new {imei=Identity.Imei,integrate_version=Identity.Firmware,wa_inner_version=Identity.Inner};break;
                case "device_backup_proc":Backups++;break;
                case "set":DebugRequests++;Ready=true;OnActivation?.Invoke();break;
                case "device_restore_proc":Restores++;Ready=true;OnActivation?.Invoke();break;
                case "device_reboot":
                    if(p[1].GetString()!="zwrt_mc.device.manager" || p[3].GetProperty("moduleName").GetString()!="web" || p[3].EnumerateObject().Count()!=1)throw new Exception("Bad reboot request");
                    Reboots++;if(CancelReboot)throw new OperationCanceledException();Ready=true;
                    if(LoseRebootAcknowledgement)throw new IOException("Lost reboot acknowledgement");break;
                default:throw new Exception("Unexpected method "+method);
            }
            return Task.FromResult(new WebReply(JsonSerializer.SerializeToUtf8Bytes(new[]{new{result=new object[]{0,reply}}}),headers));
            Task<WebReply> Json(string value)=>Task.FromResult(new WebReply(Encoding.UTF8.GetBytes(value),headers));
        }
    }
}
