using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class ComponentCleanupTests
{
    private const string Cid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Boot="11111111-1111-1111-1111-111111111111";
    private static readonly byte[] Archive=Encoding.UTF8.GetBytes("synthetic component archive");
    private static string Sha(byte[] data)=>Convert.ToHexStringLower(SHA256.HashData(data));
    internal static async Task RunAsync()
    {
        var root=Path.Combine(Path.GetTempPath(),"zte-component-cleanup-test-"+Guid.NewGuid());Directory.CreateDirectory(root);var passed=0;
        void Check(bool ok,string label){if(!ok)throw new Exception("FAIL "+label);passed++;Console.WriteLine("PASS "+label);}
        try
        {
            foreach(var scenario in new[]{"prepared","verified","same-boot","wrong-cid","wrong-firmware","wrong-router","wrong-host","corrupt-backup","dispatched","complete","foreign-setup"})
            {
                var storage=Path.Combine(root,"reset-"+scenario);var id=Guid.NewGuid().ToString();var backup=Path.Combine(storage,"SetupBackups",id);Directory.CreateDirectory(backup);
                var pending=new ComponentCleanupPending{Id=id,Cid=Cid,BootId=Boot,FirmwareHash="absent",RouterHash=ImeiEngine.RouterHash,Host=scenario=="wrong-host"?"192.0.2.2":"192.0.2.1",KeyPath=Path.Combine(storage,"SSH/id_ed25519"),KnownHostsPath=Path.Combine(storage,"SSH/known_hosts"),BackupDirectory=backup,SetupReceipt=Path.Combine(backup,"setup-result.json"),Profile="linux-arm64-access",Token=Guid.NewGuid().ToString()};
                if(scenario is "verified" or "corrupt-backup" or "dispatched" or "complete")
                {
                    pending.Phase=scenario=="dispatched"?"clean-requested":scenario=="complete"?"complete":"backup-verified";
                    pending.ArchiveSha=Sha(Archive);pending.ArchiveBytes=Archive.Length;
                    await File.WriteAllBytesAsync(Path.Combine(backup,"components.tar"),scenario=="corrupt-backup"?Encoding.UTF8.GetBytes("corrupt"):Archive);
                }
                var path=Path.Combine(storage,OnboardingEngine.CleanupPendingName);var original=Encoding.UTF8.GetBytes(JsonSerializer.Serialize(pending));await File.WriteAllBytesAsync(path,original);
                if(scenario=="foreign-setup")await File.WriteAllTextAsync(Path.Combine(storage,"setup-pending.json"),"{}");
                var proof=new DeviceIdentity(scenario=="wrong-cid"?new string('b',32):Cid,scenario=="wrong-firmware"?new string('c',64):"absent",scenario=="same-boot"?Boot:"22222222-2222-2222-2222-222222222222",scenario=="wrong-router"?new string('d',64):ImeiEngine.RouterHash);
                var calls=0;var engine=new OnboardingEngine("192.0.2.1",storage,"unused",new AdbTransport((_,_,_)=>{calls++;throw new Exception("Unexpected ADB");})){WebFactory=()=>{calls++;throw new Exception("Unexpected Web");},CleanupSshFactory=()=>{calls++;throw new Exception("Unexpected SSH");}};
                var retired=false;
                try
                {
                    var eligible=await engine.LoadUndispatchedCleanupRecoveryAsync();
                    Check((eligible is not null)==(scenario is not ("dispatched" or "complete")),"Only predispatch cleanup is eligible for reset retirement: "+scenario);
                    retired=await engine.ArchiveUndispatchedCleanupAfterRebootAsync(proof);
                }
                catch(Exception e)when(e is InvalidDataException or IOException or JsonException){}
                var allowed=scenario is "prepared" or "verified";
                Check(retired==allowed&&File.Exists(path)==!allowed,"Only same-device new boot retires undispatched cleanup: "+scenario);
                var histories=Directory.GetFiles(backup,"cleanup-before-reset-*.json");
                Check(histories.Length==(allowed?1:0)&&File.ReadAllBytes(allowed?histories[0]:path).SequenceEqual(original),"Exact cleanup journal retained: "+scenario);
                if(pending.ArchiveSha is not null)Check(File.ReadAllBytes(Path.Combine(backup,"components.tar")).SequenceEqual(scenario=="corrupt-backup"?Encoding.UTF8.GetBytes("corrupt"):Archive),"Downloaded archive untouched: "+scenario);
                Check(calls==0,"Reset retirement uses supplied identity and never contacts the modem: "+scenario);
            }
            foreach(var scenario in new[]{"committed-before-intent","fresh","partial-prepare","verified","interrupted-clean","complete","remote-regressed","unrequested-complete","lost-clean-reply","lost-clean-pending","lost-clean-status-failed","clean-timeout","clean-protocol","clean-service","clean-changed-boot","clean-tampered-backup","reboot-verified","reboot-interrupted","reboot-complete","reboot-no-archive","reboot-lost","reboot-wrong-receipt","reboot-tampered-backup","reboot-changed-again","accepted-boot-prepared-error","accepted-boot-verified-error","wrong-device","wrong-host","wrong-stream","stream-changed","bad-local-file","tampered-backup","remote-hash-changed","cancelled-stream","invalid-status","missing-backup","bad-setup"})
            {
                var storage=Path.Combine(root,scenario);var resources=Path.Combine(storage,"resources");Directory.CreateDirectory(Path.Combine(resources,"Onboarding"));
                var helper=Encoding.UTF8.GetBytes("#!/bin/sh\n# synthetic pinned cleanup helper\n");
                await File.WriteAllBytesAsync(Path.Combine(resources,"Onboarding/clean-components.sh"),helper);
                await File.WriteAllTextAsync(Path.Combine(resources,"Onboarding/SHA256.json"),JsonSerializer.Serialize(new Dictionary<string,string>{{"clean-components.sh",Sha(helper)}}));
                var id=Guid.NewGuid().ToString();var backup=Path.Combine(storage,"SetupBackups",id);Directory.CreateDirectory(backup);Directory.CreateDirectory(Path.Combine(storage,"SSH"));
                var setup=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Profile="linux-arm64-access",ForceReinstall=true,CleanComponents=true,InstallRequested=true,Phase=scenario=="bad-setup"?"ready":"complete",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                var pending=new ComponentCleanupPending{Id=id,Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Host=scenario=="wrong-host"?"192.0.2.2":"192.0.2.1",KeyPath=Path.Combine(storage,"SSH/id_ed25519"),KnownHostsPath=Path.Combine(storage,"SSH/known_hosts"),BackupDirectory=backup,SetupReceipt=Path.Combine(backup,"setup-result.json"),Profile="linux-arm64-access",Token=Guid.NewGuid().ToString()};
                var acceptedBootError=scenario.StartsWith("accepted-boot-",StringComparison.Ordinal);
                if(acceptedBootError)pending.AcceptedBootId="22222222-2222-2222-2222-222222222222";
                var priorBackup=(scenario.StartsWith("reboot-",StringComparison.Ordinal)&&scenario!="reboot-no-archive")||scenario is "verified" or "interrupted-clean" or "complete" or "tampered-backup" or "remote-hash-changed" or "remote-regressed" or "unrequested-complete" or "accepted-boot-verified-error";
                if(priorBackup){pending.ArchiveSha=Sha(Archive);pending.ArchiveBytes=Archive.Length;pending.Phase=scenario=="remote-regressed"?"complete":scenario is "interrupted-clean" or "complete" or "reboot-interrupted" or "reboot-complete"?"clean-requested":"backup-verified";await File.WriteAllBytesAsync(Path.Combine(backup,"components.tar"),scenario is "tampered-backup" or "reboot-tampered-backup"?Encoding.UTF8.GetBytes("changed") : Archive);}
                var setupPath=Path.Combine(storage,"setup-pending.json");var cleanupPath=Path.Combine(storage,OnboardingEngine.CleanupPendingName);
                await File.WriteAllTextAsync(setupPath,JsonSerializer.Serialize(setup));if(scenario!="committed-before-intent")await File.WriteAllTextAsync(cleanupPath,JsonSerializer.Serialize(pending));
                var originalCleanup=acceptedBootError?await File.ReadAllBytesAsync(cleanupPath):null;
                var shell=new CleanupShell{State=scenario switch{"partial-prepare"=>"CLEAN_INCOMPLETE","remote-hash-changed"=>"CLEAN_PREPARED "+new string('f',64)+" "+Archive.Length,"verified" or "tampered-backup" or "remote-regressed"=>"CLEAN_PREPARED "+Sha(Archive)+" "+Archive.Length,"interrupted-clean"=>"CLEAN_PENDING "+Sha(Archive)+" "+Archive.Length,"complete" or "unrequested-complete" or "missing-backup"=>"CLEAN_COMPLETE","invalid-status"=>"PRIVATE status",_=>"CLEAN_ABSENT"},WrongDevice=scenario=="wrong-device",CleanMode=scenario};
                if(scenario.StartsWith("reboot-",StringComparison.Ordinal))
                {
                    shell.CurrentBoot="22222222-2222-2222-2222-222222222222";
                    shell.State=scenario=="reboot-no-archive"?"CLEAN_ABSENT":scenario=="reboot-complete"?"CLEAN_COMPLETE":scenario=="reboot-interrupted"?"CLEAN_PENDING "+Sha(Archive)+" "+Archive.Length:"CLEAN_PREPARED "+Sha(Archive)+" "+Archive.Length;
                }
                if(acceptedBootError)shell.CurrentBoot=pending.AcceptedBootId!;
                if(scenario=="clean-tampered-backup")shell.OnClean=()=>File.WriteAllText(Path.Combine(backup,"components.tar"),"changed");
                var adbCalls=0;var webCalls=0;var streams=0;
                var adb=new AdbTransport((_,_,_,_)=>{adbCalls++;throw new Exception("Unexpected ADB call");},Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",storage,resources,adb){CleanupSshFactory=()=>shell,WebFactory=()=>{webCalls++;throw new Exception("Unexpected Web call");},CleanupStream=async(_,command,input,path,bytes,ct)=>
                {
                    if(scenario=="cancelled-stream")throw new OperationCanceledException();
                    streams++;Check(command.StartsWith("sh -s -- 'stream' ")&&input.SequenceEqual(helper)&&!command.Contains("synthetic pinned")&&bytes==Archive.Length,"stream uses fixed helper action and reported byte limit: "+scenario);
                    await File.WriteAllBytesAsync(path,scenario=="bad-local-file"?Encoding.UTF8.GetBytes("corrupt") : Archive,ct);
                    if(scenario=="stream-changed")return new RemoteFileResult(1,0,"",Encoding.UTF8.GetBytes("PRIVATE\nCLEAN_ERROR CHANGED\n"));
                    return new RemoteFileResult(0,Archive.Length,scenario=="wrong-stream"?new string('f',64):Sha(Archive),Encoding.UTF8.GetBytes("BACKUP_RESULT sha256="+Sha(Archive)+" bytes="+Archive.Length+"\n"));
                }};
                OnboardingResult? result=null;string? error=null;
                try{result=await engine.PrepareAsync("","","",forceReinstall:false,cleanComponents:scenario=="verified"||acceptedBootError);}catch(Exception e) when(e is IOException or InvalidDataException or InvalidOperationException or OperationCanceledException){error=e.Message;}
                var success=scenario is "committed-before-intent" or "fresh" or "partial-prepare" or "verified" or "interrupted-clean" or "complete" or "lost-clean-reply" or "clean-timeout" or "clean-protocol" or "reboot-verified" or "reboot-interrupted" or "reboot-complete" or "reboot-no-archive";
                Check((result?.ComponentsCleaned==true)==success,"explicit cleanup result: "+scenario);
                if(success)
                {
                    Check(File.Exists(cleanupPath)&&File.Exists(setupPath),"completed cleanup remains pending until connection acknowledgement: "+scenario);
                    if(scenario=="complete")
                    {
                        var again=await engine.PrepareAsync("","","",forceReinstall:true,cleanComponents:true);
                        Check(again.ComponentsCleaned&&shell.Actions.All(x=>x=="status"),"lost final response resumes read-only without forced preparation");
                    }
                    await engine.AcknowledgeComponentCleanupAsync(result!.CleanupId!);
                }
                Check(shell.LockTokens.Count==shell.Actions.Count,"every helper invocation uses a distinct token for stale-lock recovery: "+scenario);
                Check(adbCalls==0&&webCalls==0,"cleanup resume never replays Web, ADB or forced preparation: "+scenario);
                Check(File.Exists(cleanupPath)==!success&&File.Exists(setupPath)==!success,"pending guards clear only after complete proof: "+scenario);
                Check(error is null||!error.Contains("PRIVATE"),"cleanup errors do not expose remote data: "+scenario);
                if(success)Check(await File.ReadAllBytesAsync(Path.Combine(backup,"components.tar")).ContinueWith(t=>t.Result.SequenceEqual(Archive))&&File.Exists(Path.Combine(backup,"component-cleanup-result.json")),"local verified backup and cleanup receipt retained: "+scenario);
                if(scenario is "remote-regressed" or "unrequested-complete" or "wrong-device" or "wrong-host" or "wrong-stream" or "bad-local-file" or "tampered-backup" or "remote-hash-changed" or "cancelled-stream" or "invalid-status" or "missing-backup" or "bad-setup")Check(shell.Actions.All(x=>x!="clean"),"no deletion without matching identity, archive and receipt: "+scenario);
                if(priorBackup)Check(streams==0,"verified local backup is reused without overwriting: "+scenario);
                if(acceptedBootError)
                {
                    Check(error is not null&&error.Contains("[SERVICE]")&&!error.Contains("Восстановление доступа")&&shell.Actions.SequenceEqual(new[]{"status"}),"component refusal on accepted boot stays in cleanup without USB reset fallback: "+scenario);
                    Check((await File.ReadAllBytesAsync(cleanupPath)).SequenceEqual(originalCleanup!)&&streams==0,"accepted boot and original owner journal remain byte-exact after refusal: "+scenario);
                    if(priorBackup)Check((await File.ReadAllBytesAsync(Path.Combine(backup,"components.tar"))).SequenceEqual(Archive),"accepted-boot refusal retains verified archive unchanged");
                }
                if(scenario.StartsWith("reboot-",StringComparison.Ordinal))
                {
                    if(scenario=="reboot-tampered-backup")Check(shell.Actions.Count==0,"corrupt archive prevents reboot metadata changes");
                    else Check(shell.Actions.Count(x=>x=="rebind")==1,"explicit reboot continuation attempts one metadata bind: "+scenario);
                    if(success)Check(JsonSerializer.Deserialize<ComponentCleanupPending>(await File.ReadAllTextAsync(Path.Combine(backup,"component-cleanup-result.json"))) is {AcceptedBootId:"22222222-2222-2222-2222-222222222222",BootId:Boot},"new boot saved without rewriting original setup owner: "+scenario);
                    else Check(JsonSerializer.Deserialize<ComponentCleanupPending>(await File.ReadAllTextAsync(cleanupPath))!.AcceptedBootId is null&&shell.Actions.All(x=>x!="clean"),"failed reboot proof retains original host state and never cleans: "+scenario);
                }
                if(scenario=="complete")Check(shell.Actions.All(x=>x=="status"),"terminal cleanup retry is read-only");
                if(scenario is "lost-clean-reply" or "clean-timeout" or "clean-protocol" or "lost-clean-pending" or "lost-clean-status-failed")
                    Check(shell.Actions.Count(x=>x=="clean")==1&&shell.Actions.Count(x=>x=="status")==2,"uncertain clean gets one bounded read-only status and no second mutation: "+scenario);
                if(scenario=="stream-changed")Check(error!.Contains("[CHANGED]")&&error.Contains("сохранение копии")&&shell.Actions.All(x=>x!="clean"),"stream refusal preserves fixed stage/code before mutation");
                if(scenario=="clean-service")Check(error!.Contains("[SERVICE]")&&shell.Actions.Count(x=>x=="status")==1,"explicit helper refusal retains fixed code without an outcome query");
                if(scenario is "clean-changed-boot" or "clean-tampered-backup")Check(!success&&File.Exists(cleanupPath),"fresh identity and local archive remain required after clean: "+scenario);
                if(scenario=="reboot-lost")
                {
                    shell.CleanMode="";shell.CurrentBoot="33333333-3333-3333-3333-333333333333";
                    var retry=await engine.PrepareAsync("","","",forceReinstall:true,cleanComponents:true);
                    var rebound=JsonSerializer.Deserialize<ComponentCleanupPending>(await File.ReadAllTextAsync(cleanupPath))!;
                    Check(retry.ComponentsCleaned&&rebound.AcceptedBootId==shell.CurrentBoot&&rebound.BootId==Boot&&shell.Actions.Count(x=>x=="rebind")==2&&shell.Actions.Count(x=>x=="clean")==1&&streams==0,"dropped rebind receipt then another reboot resumes original archive and owner");
                    await engine.AcknowledgeComponentCleanupAsync(retry.CleanupId!);
                }
                if(scenario=="lost-clean-status-failed")
                {
                    shell.CleanMode="";
                    var retry=await engine.PrepareAsync("","","",forceReinstall:true,cleanComponents:true);
                    Check(File.Exists(cleanupPath),"cleanup pending survives an unacknowledged completed retry");
                    await engine.AcknowledgeComponentCleanupAsync(retry.CleanupId!);
                    Check(retry.ComponentsCleaned&&shell.Actions.Count(x=>x=="clean")==1&&!File.Exists(cleanupPath)&&streams==1,"next explicit retry checks complete status without repeating clean or forced setup");
                }
            }
            foreach(var scenario in new[]{"absent","incomplete","prepared","verified","verified-absent","interrupted-cancel","invalid-cancel-proof","pending","complete","requested","unknown","changed-boot","changed-hash"})
            {
                var storage=Path.Combine(root,"cancel-"+scenario);var resources=Path.Combine(storage,"resources");Directory.CreateDirectory(Path.Combine(resources,"Onboarding"));
                var helper=Encoding.UTF8.GetBytes("#!/bin/sh\n# synthetic pinned cleanup helper\n");
                await File.WriteAllBytesAsync(Path.Combine(resources,"Onboarding/clean-components.sh"),helper);
                await File.WriteAllTextAsync(Path.Combine(resources,"Onboarding/SHA256.json"),JsonSerializer.Serialize(new Dictionary<string,string>{{"clean-components.sh",Sha(helper)}}));
                var id=Guid.NewGuid().ToString();var backup=Path.Combine(storage,"SetupBackups",id);Directory.CreateDirectory(backup);
                var setup=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Profile="linux-arm64-access",ForceReinstall=true,CleanComponents=true,InstallRequested=true,Phase="complete",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                var pending=new ComponentCleanupPending{Id=id,Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Host="192.0.2.1",KeyPath=Path.Combine(storage,"SSH/id_ed25519"),KnownHostsPath=Path.Combine(storage,"SSH/known_hosts"),BackupDirectory=backup,SetupReceipt=Path.Combine(backup,"setup-result.json"),Profile="linux-arm64-access",Token=Guid.NewGuid().ToString()};
                if(scenario is "verified" or "verified-absent" or "requested" or "changed-hash") {pending.ArchiveSha=Sha(Archive);pending.ArchiveBytes=Archive.Length;pending.Phase=scenario=="requested"?"clean-requested":"backup-verified";}
                if(scenario is "interrupted-cancel" or "invalid-cancel-proof") {pending.Phase="cancelled";pending.CancelledFromPhase="prepared";pending.CancellationStatus=scenario=="interrupted-cancel"?"CLEAN_ABSENT":"CLEAN_PENDING "+Sha(Archive)+" "+Archive.Length;}
                await File.WriteAllBytesAsync(Path.Combine(backup,"components.tar"),Archive);
                var setupPath=Path.Combine(storage,"setup-pending.json");var cleanupPath=Path.Combine(storage,OnboardingEngine.CleanupPendingName);
                await File.WriteAllTextAsync(setupPath,JsonSerializer.Serialize(setup));await File.WriteAllTextAsync(cleanupPath,JsonSerializer.Serialize(pending));
                var shell=new CleanupShell{WrongBoot=scenario=="changed-boot",State=scenario switch{"absent" or "verified-absent"=>"CLEAN_ABSENT","incomplete"=>"CLEAN_INCOMPLETE","pending"=>"CLEAN_PENDING "+Sha(Archive)+" "+Archive.Length,"complete"=>"CLEAN_COMPLETE","unknown"=>"PRIVATE unknown","changed-hash"=>"CLEAN_PREPARED "+new string('f',64)+" "+Archive.Length,_=>"CLEAN_PREPARED "+Sha(Archive)+" "+Archive.Length}};
                var engine=new OnboardingEngine("192.0.2.1",storage,resources,new AdbTransport((_,_,_)=>throw new Exception("Unexpected ADB"))){CleanupSshFactory=()=>shell};
                var cancelled=false; OnboardingResult? cancellationResult=null;
                try{if(scenario is "interrupted-cancel" or "invalid-cancel-proof"){cancellationResult=await engine.PrepareAsync("","","",forceReinstall:true,cleanComponents:true);cancelled=cancellationResult.CleanupCancelled;}else{cancellationResult=await engine.CancelComponentCleanupAsync();cancelled=cancellationResult.CleanupCancelled;}}catch(Exception e)when(e is InvalidDataException or InvalidOperationException or IOException){}
                var allowed=scenario is "absent" or "incomplete" or "prepared" or "verified" or "interrupted-cancel";
                Check(cancelled==allowed&&File.Exists(cleanupPath)==!allowed&&File.Exists(setupPath)==!allowed,"cancellation is allowed only before clean dispatch with fresh proof: "+scenario);
                if(allowed)Check(cancellationResult is {Port:2222,CleanupCancelled:true}&&cancellationResult.KeyPath==pending.KeyPath&&cancellationResult.KnownHostsPath==pending.KnownHostsPath&&File.Exists(Path.Combine(storage,"connection.json")),"confirmed cancellation returns and durably saves prepared connection metadata: "+scenario);
                if(scenario is "interrupted-cancel" or "invalid-cancel-proof")Check(shell.Actions.Count==0&&shell.IdentityReads==0,"durable cancelled state never replays SSH, force or cleanup: "+scenario);
                Check(shell.Actions.All(x=>x=="status")&&File.ReadAllBytes(Path.Combine(backup,"components.tar")).SequenceEqual(Archive),"cancellation never deletes or changes remote components or local backup: "+scenario);
                Check(File.Exists(Path.Combine(backup,"component-cleanup-cancelled.json"))==allowed&&File.Exists(Path.Combine(backup,"component-cleanup-cancellation-proof.json"))==allowed,"cancellation archives intent and fixed receipt before clearing guard: "+scenario);
            }
            var inputBytes=Encoding.UTF8.GetBytes("#!/bin/sh\n#"+new string('a',22000)+"\nprintf done\n");
            var stdinTarget=new InputCapture();await SshTransport.WriteInputAsync(stdinTarget,inputBytes,CancellationToken.None);
            Check(stdinTarget.Bytes.SequenceEqual(inputBytes)&&stdinTarget.Disposed,"streaming transport sends complete helper bytes and closes stdin for EOF");
            var emptyTarget=new InputCapture();await SshTransport.WriteInputAsync(emptyTarget,null,CancellationToken.None);
            Check(emptyTarget.Disposed&&emptyTarget.Bytes.Length==0,"existing stream callers retain empty stdin/EOF behavior");
            var cancelledTarget=new InputCapture();using(var cancellation=new CancellationTokenSource()){cancellation.Cancel();try{await SshTransport.WriteInputAsync(cancelledTarget,inputBytes,cancellation.Token);}catch(OperationCanceledException){}}
            Check(cancelledTarget.Disposed&&cancelledTarget.Bytes.Length==0,"stream stdin cancellation closes the channel without replay");
            foreach(var mode in new[]{"missing","wrong-hash","embedded-nul"})
            {
                var folder=Path.Combine(root,"helper-"+mode);var resources=Path.Combine(folder,"resources");Directory.CreateDirectory(Path.Combine(resources,"Onboarding"));
                var helper=Encoding.UTF8.GetBytes(mode=="embedded-nul"?"#!/bin/sh\0":"#!/bin/sh\n");
                if(mode!="missing")await File.WriteAllBytesAsync(Path.Combine(resources,"Onboarding/clean-components.sh"),helper);
                await File.WriteAllTextAsync(Path.Combine(resources,"Onboarding/SHA256.json"),JsonSerializer.Serialize(new Dictionary<string,string>{{"clean-components.sh",mode=="wrong-hash"?new string('f',64):Sha(helper)}}));
                var calls=0;
                var adb=new AdbTransport((_,_,_,_)=>{calls++;throw new Exception("Unexpected ADB");},Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",folder,resources,adb){WebFactory=()=>{calls++;throw new Exception("Unexpected Web");}};
                var rejected=false;
                try{await engine.PrepareAsync("","synthetic-password","",cleanComponents:true);}catch(Exception e)when(e is IOException or InvalidDataException){rejected=true;}
                Check(rejected&&calls==0&&!File.Exists(Path.Combine(folder,"setup-pending.json")),"invalid bundled cleanup helper refuses before forced preparation: "+mode);
            }
            var bundledHelper=await File.ReadAllTextAsync("Windows_x64/Resources/Onboarding/clean-components.sh");
            var producerCodes=Regex.Matches(bundledHelper,@"(?:\bfail |\bclean_stage=|CLEAN_ERROR )([A-Z][A-Z0-9_]*)\b").Select(m=>m.Groups[1].Value).Distinct().ToArray();
            Check(producerCodes.Length>20,"producer error-code parity fixture reads actual bundled helper");
            foreach(var code in producerCodes)Check(OnboardingEngine.CleanupErrorCodes.Contains(code),"bundled helper fixed code has a host diagnostic: "+code);
            foreach(var code in new[]{"SERVICE","PATH","OWNER","CHANGED","VPN_INTEGRITY","PENDING_AGENT"})
            {
                var message=OnboardingEngine.CleanupFailureMessage(new RemoteResult(1,[],Encoding.UTF8.GetBytes("CLEAN_ERROR "+code)));
                Check(message.Contains("диагностический отчёт")&&!message.Contains("продолжите"),"permanent guard does not prescribe a futile retry: "+code);
            }
            foreach(var code in OnboardingEngine.CleanupErrorCodes)
            {
                var text=OnboardingEngine.CleanupFailureMessage(new RemoteResult(1,[],Encoding.UTF8.GetBytes("PRIVATE detail\nCLEAN_ERROR "+code+"\n")),"prepare");
                Check(!text.Contains("PRIVATE")&&text.Contains("["+code+"]")&&text.Contains("подготовка копии"),"every fixed cleanup reason preserves stage and code without raw data: "+code);
            }
            foreach(var raw in new[]{"CLEAN_ERROR PRIVATE","prefix CLEAN_ERROR BUSY","CLEAN_ERROR BUSY suffix","CLEAN_ERROR BUSY\nCLEAN_ERROR CHANGED","CLEAN_ERROR BUSY\nCLEAN_ERROR BUSY","CLEAN_ERROR BUSY\nCLEAN_ERROR PRIVATE"})
                Check(OnboardingEngine.CleanupFailureMessage(new RemoteResult(1,[],Encoding.UTF8.GetBytes(raw))).Contains("[REMOTE_FAILURE]"),"malformed or contradictory cleanup error stays unknown");
            Check(OnboardingEngine.CleanupFailureMessage(new RemoteResult(255,[],Encoding.UTF8.GetBytes("CLEAN_ERROR BUSY"))).Contains("[TRANSPORT]"),"lost transport completion cannot become a controller error");
            foreach(var raw in new[]{Encoding.UTF8.GetBytes("CLEAN_COMPLETE\nPRIVATE"),Encoding.UTF8.GetBytes("CLEAN_COMPLETE\n\n"),Encoding.UTF8.GetBytes(" CLEAN_COMPLETE"),Encoding.UTF8.GetBytes("CLEAN_COMPLETE\0"),new byte[]{255},Encoding.UTF8.GetBytes("CLEAN_COMPLETE"+new string(' ',513)),Encoding.UTF8.GetBytes("CLEAN_PREPARED "+Sha(Archive)+" 17179869185"),Encoding.UTF8.GetBytes("CLEAN_PREPARED "+Sha(Archive)+" 01")})
            {
                var rejected=false;try{OnboardingEngine.ParseCleanupReply(new RemoteResult(0,raw,[]),"status");}catch(IOException e){rejected=e.Message.Contains("[PROTOCOL]")&&!e.Message.Contains("PRIVATE");}
                Check(rejected,"invalid successful receipt is a bounded fixed protocol failure");
            }
            foreach(var ending in new[]{"","\n","\r\n"})Check(OnboardingEngine.ParseCleanupReply(new RemoteResult(0,Encoding.UTF8.GetBytes("CLEAN_COMPLETE"+ending),[]),"clean")=="CLEAN_COMPLETE","single complete receipt accepts exact LF/CRLF grammar");
            var guardedStorage=Path.Combine(root,"guard");Directory.CreateDirectory(guardedStorage);
            await File.WriteAllTextAsync(Path.Combine(guardedStorage,OnboardingEngine.CleanupPendingName),"synthetic pending");
            var guardedShell=new GuardShell();var features=new ZteImeiStudio.Windows.Features.DeviceFeatureService(guardedShell,"unused",guardedStorage);
            var blocked=false;
            try{await features.MutateAsync((_,_)=>Task.FromResult(true),CancellationToken.None);}catch(ZteImeiStudio.Windows.Features.DeviceFeatureException e){blocked=e.Message=="Сначала завершите очистку компонентов программы в подготовке модема.";}
            Check(blocked&&guardedShell.Calls==0,"cleanup pending blocks ordinary mutations before remote lock or writes");
            await features.ReadIdentityAsync();
            Check(guardedShell.Calls==1,"cleanup pending does not block identity reads");
        }
        finally{Directory.Delete(root,true);}
        Console.WriteLine($"RESULT {passed} component cleanup checks; no device");
    }
    private sealed class InputCapture:MemoryStream
    {
        internal bool Disposed;internal byte[] Bytes=[];
        protected override void Dispose(bool disposing){Bytes=ToArray();Disposed=true;base.Dispose(disposing);}
    }
    private sealed class GuardShell:IRemoteShell
    {
        internal int Calls;
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {Calls++;return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+Boot+"\n"),[]));}
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
    private sealed class CleanupShell:IRemoteShell
    {
        internal int IdentityReads;internal string State="CLEAN_ABSENT";internal bool WrongBoot,WrongDevice;internal string CurrentBoot=Boot;internal string CleanMode="";internal Action? OnClean;internal List<string> Actions=[];internal HashSet<string> LockTokens=[];
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            string output;
            if(command==AccessIdentity.Command){IdentityReads++;output=ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+(WrongDevice?new string('b',32):Cid)+"\n"+(WrongBoot?"22222222-2222-2222-2222-222222222222":CurrentBoot)+"\n";}
            else
            {
                if(!command.StartsWith("sh -s -- ")||Encoding.UTF8.GetByteCount(command)>1024||stdin is null||!Encoding.UTF8.GetString(stdin).Contains("synthetic pinned cleanup helper"))throw new Exception("Helper must travel over stdin with a short command");
                var arguments=Regex.Matches(command,"'([^']*)'").Select(m=>m.Groups[1].Value).ToArray();
                if(arguments.Length<8||!Guid.TryParseExact(arguments[7],"D",out _)||!LockTokens.Add(arguments[7]))throw new Exception("Cleanup invocation reused its stale lock token");
                var action=Regex.Match(command," -- '([a-z]+)' ").Groups[1].Value;Actions.Add(action);
                if(action is "status" or "rebind" && timeout?.TotalSeconds!=300)throw new Exception("Archive readback requires bounded 300-second budget");
                if(action=="status")
                {
                    if(CleanMode.StartsWith("accepted-boot-",StringComparison.Ordinal))return Task.FromResult(new RemoteResult(1,[],Encoding.UTF8.GetBytes("CLEAN_ERROR SERVICE\n")));
                    if(CleanMode=="lost-clean-status-failed"&&Actions.Contains("clean"))return Task.FromResult(new RemoteResult(255,[],Encoding.UTF8.GetBytes("PRIVATE status failure")));
                    output=State;
                }
                else if(action=="prepare")output=State="CLEAN_PREPARED "+Sha(Archive)+" "+Archive.Length;
                else if(action=="rebind")
                {
                    if(arguments[4]!=Boot||arguments.Length!=10||arguments[9]!=CurrentBoot||arguments[8]!=(State is "CLEAN_ABSENT" or "CLEAN_INCOMPLETE"?"none":Sha(Archive)))throw new Exception("Rebind lost original owner/archive proof");
                    if(CleanMode=="reboot-lost")return Task.FromResult(new RemoteResult(255,[],Encoding.UTF8.GetBytes("PRIVATE lost rebind")));
                    output="CLEAN_REBOUND "+CurrentBoot+" "+(State is "CLEAN_ABSENT" or "CLEAN_INCOMPLETE"?"none 0":(CleanMode=="reboot-wrong-receipt"?new string('f',64):Sha(Archive))+" "+Archive.Length);
                    if(CleanMode=="reboot-changed-again")CurrentBoot="33333333-3333-3333-3333-333333333333";
                }
                else if(action=="clean")
                {
                    if(!command.EndsWith("'"+Sha(Archive)+"'",StringComparison.Ordinal))throw new Exception("Missing archive authorization");
                    output=State="CLEAN_COMPLETE";
                    OnClean?.Invoke();
                    if(CleanMode=="clean-changed-boot")WrongBoot=true;
                    if(CleanMode=="clean-service")return Task.FromResult(new RemoteResult(1,[],Encoding.UTF8.GetBytes("CLEAN_ERROR SERVICE\nPRIVATE")));
                    if(CleanMode=="clean-timeout")throw new TimeoutException("PRIVATE timeout");
                    if(CleanMode=="clean-protocol")return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes("PRIVATE receipt"),[]));
                    if(CleanMode=="lost-clean-pending")State="CLEAN_PENDING "+Sha(Archive)+" "+Archive.Length;
                    if(CleanMode.StartsWith("lost-clean-",StringComparison.Ordinal))return Task.FromResult(new RemoteResult(255,[],Encoding.UTF8.GetBytes("PRIVATE lost reply")));
                }
                else throw new Exception("Unexpected helper action");
            }
            return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(output+"\n"),[]));
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Expected bounded streaming");
    }
}
