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
            foreach(var scenario in new[]{"committed-before-intent","fresh","partial-prepare","verified","interrupted-clean","complete","remote-regressed","unrequested-complete","lost-clean-reply","wrong-boot","wrong-host","wrong-stream","bad-local-file","tampered-backup","remote-hash-changed","cancelled-stream","invalid-status","missing-backup","bad-setup"})
            {
                var storage=Path.Combine(root,scenario);var resources=Path.Combine(storage,"resources");Directory.CreateDirectory(Path.Combine(resources,"Onboarding"));
                var helper=Encoding.UTF8.GetBytes("#!/bin/sh\n# synthetic pinned cleanup helper\n");
                await File.WriteAllBytesAsync(Path.Combine(resources,"Onboarding/clean-components.sh"),helper);
                await File.WriteAllTextAsync(Path.Combine(resources,"Onboarding/SHA256.json"),JsonSerializer.Serialize(new Dictionary<string,string>{{"clean-components.sh",Sha(helper)}}));
                var id=Guid.NewGuid().ToString();var backup=Path.Combine(storage,"SetupBackups",id);Directory.CreateDirectory(backup);Directory.CreateDirectory(Path.Combine(storage,"SSH"));
                var setup=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Profile="linux-arm64-access",ForceReinstall=true,CleanComponents=true,InstallRequested=true,Phase=scenario=="bad-setup"?"ready":"complete",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                var pending=new ComponentCleanupPending{Id=id,Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Host=scenario=="wrong-host"?"192.0.2.2":"192.0.2.1",KeyPath=Path.Combine(storage,"SSH/id_ed25519"),KnownHostsPath=Path.Combine(storage,"SSH/known_hosts"),BackupDirectory=backup,SetupReceipt=Path.Combine(backup,"setup-result.json"),Profile="linux-arm64-access",Token=Guid.NewGuid().ToString()};
                var priorBackup=scenario is "verified" or "interrupted-clean" or "complete" or "tampered-backup" or "remote-hash-changed" or "remote-regressed" or "unrequested-complete";
                if(priorBackup){pending.ArchiveSha=Sha(Archive);pending.ArchiveBytes=Archive.Length;pending.Phase=scenario=="remote-regressed"?"complete":scenario is "interrupted-clean" or "complete"?"clean-requested":"backup-verified";await File.WriteAllBytesAsync(Path.Combine(backup,"components.tar"),scenario=="tampered-backup"?Encoding.UTF8.GetBytes("changed") : Archive);}
                var setupPath=Path.Combine(storage,"setup-pending.json");var cleanupPath=Path.Combine(storage,OnboardingEngine.CleanupPendingName);
                await File.WriteAllTextAsync(setupPath,JsonSerializer.Serialize(setup));if(scenario!="committed-before-intent")await File.WriteAllTextAsync(cleanupPath,JsonSerializer.Serialize(pending));
                var shell=new CleanupShell{State=scenario switch{"partial-prepare"=>"CLEAN_INCOMPLETE","remote-hash-changed"=>"CLEAN_PREPARED "+new string('f',64)+" "+Archive.Length,"verified" or "tampered-backup" or "remote-regressed"=>"CLEAN_PREPARED "+Sha(Archive)+" "+Archive.Length,"interrupted-clean"=>"CLEAN_PENDING "+Sha(Archive)+" "+Archive.Length,"complete" or "unrequested-complete" or "missing-backup"=>"CLEAN_COMPLETE","invalid-status"=>"PRIVATE status",_=>"CLEAN_ABSENT"},WrongBoot=scenario=="wrong-boot",LoseCleanReply=scenario=="lost-clean-reply"};
                var adbCalls=0;var webCalls=0;var streams=0;
                var adb=new AdbTransport((_,_,_,_)=>{adbCalls++;throw new Exception("Unexpected ADB call");},Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",storage,resources,adb){CleanupSshFactory=()=>shell,WebFactory=()=>{webCalls++;throw new Exception("Unexpected Web call");},CleanupStream=async(_,command,input,path,bytes,ct)=>
                {
                    if(scenario=="cancelled-stream")throw new OperationCanceledException();
                    streams++;Check(command.StartsWith("sh -s -- 'stream' ")&&input.SequenceEqual(helper)&&!command.Contains("synthetic pinned")&&bytes==Archive.Length,"stream uses fixed helper action and reported byte limit: "+scenario);
                    await File.WriteAllBytesAsync(path,scenario=="bad-local-file"?Encoding.UTF8.GetBytes("corrupt") : Archive,ct);
                    return new RemoteFileResult(0,Archive.Length,scenario=="wrong-stream"?new string('f',64):Sha(Archive),Encoding.UTF8.GetBytes("BACKUP_RESULT sha256="+Sha(Archive)+" bytes="+Archive.Length+"\n"));
                }};
                OnboardingResult? result=null;string? error=null;
                try{result=await engine.PrepareAsync("","","",forceReinstall:false,cleanComponents:false);}catch(Exception e) when(e is IOException or InvalidDataException or InvalidOperationException or OperationCanceledException){error=e.Message;}
                var success=scenario is "committed-before-intent" or "fresh" or "partial-prepare" or "verified" or "interrupted-clean" or "complete";
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
                Check(adbCalls==0&&webCalls==0,"cleanup resume never replays Web, ADB or forced preparation: "+scenario);
                Check(File.Exists(cleanupPath)==!success&&File.Exists(setupPath)==!success,"pending guards clear only after complete proof: "+scenario);
                Check(error is null||!error.Contains("PRIVATE"),"cleanup errors do not expose remote data: "+scenario);
                if(success)Check(await File.ReadAllBytesAsync(Path.Combine(backup,"components.tar")).ContinueWith(t=>t.Result.SequenceEqual(Archive))&&File.Exists(Path.Combine(backup,"component-cleanup-result.json")),"local verified backup and cleanup receipt retained: "+scenario);
                if(scenario is "remote-regressed" or "unrequested-complete" or "wrong-boot" or "wrong-host" or "wrong-stream" or "bad-local-file" or "tampered-backup" or "remote-hash-changed" or "cancelled-stream" or "invalid-status" or "missing-backup" or "bad-setup")Check(shell.Actions.All(x=>x!="clean"),"no deletion without matching identity, archive and receipt: "+scenario);
                if(priorBackup)Check(streams==0,"verified local backup is reused without overwriting: "+scenario);
                if(scenario=="complete")Check(shell.Actions.All(x=>x=="status"),"terminal cleanup retry is read-only");
                if(scenario=="lost-clean-reply")
                {
                    Check(shell.Actions.Count(x=>x=="clean")==1,"unknown clean outcome is not retried in the same operation");
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
            foreach(var code in new[]{"BUSY","PENDING","VPN_CONFIGURATION","CHANGED","IDENTITY","RECOVERY_REQUIRED","STOP","VPN_RESTORE"})
            {
                var text=OnboardingEngine.CleanupFailureMessage(new RemoteResult(1,[],Encoding.UTF8.GetBytes("PRIVATE detail\nCLEAN_ERROR "+code+"\n")));
                Check(!text.Contains("PRIVATE")&&!text.StartsWith("Очистка компонентов не подтверждена."),"fixed cleanup error preserves known reason without raw data: "+code);
            }
            foreach(var raw in new[]{"CLEAN_ERROR PRIVATE","prefix CLEAN_ERROR BUSY","CLEAN_ERROR BUSY suffix","CLEAN_ERROR BUSY\nCLEAN_ERROR CHANGED"})
                Check(OnboardingEngine.CleanupFailureMessage(new RemoteResult(1,[],Encoding.UTF8.GetBytes(raw))).StartsWith("Очистка компонентов не подтверждена."),"malformed or contradictory cleanup error stays unknown");
            Check(OnboardingEngine.CleanupFailureMessage(new RemoteResult(255,[],Encoding.UTF8.GetBytes("CLEAN_ERROR BUSY"))).StartsWith("Очистка компонентов не подтверждена."),"lost transport completion cannot become a controller error");
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
        internal int IdentityReads;internal string State="CLEAN_ABSENT";internal bool WrongBoot,LoseCleanReply;internal List<string> Actions=[];
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            string output;
            if(command==AccessIdentity.Command){IdentityReads++;output=ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+(WrongBoot?"22222222-2222-2222-2222-222222222222":Boot)+"\n";}
            else
            {
                if(!command.StartsWith("sh -s -- ")||Encoding.UTF8.GetByteCount(command)>1024||stdin is null||!Encoding.UTF8.GetString(stdin).Contains("synthetic pinned cleanup helper"))throw new Exception("Helper must travel over stdin with a short command");
                var action=Regex.Match(command," -- '([a-z]+)' ").Groups[1].Value;Actions.Add(action);
                if(action=="status")output=State;
                else if(action=="prepare")output=State="CLEAN_PREPARED "+Sha(Archive)+" "+Archive.Length;
                else if(action=="clean")
                {
                    if(!command.EndsWith("'"+Sha(Archive)+"'",StringComparison.Ordinal))throw new Exception("Missing archive authorization");
                    output=State="CLEAN_COMPLETE";
                    if(LoseCleanReply){LoseCleanReply=false;return Task.FromResult(new RemoteResult(255,[],Encoding.UTF8.GetBytes("PRIVATE lost reply")));}
                }
                else throw new Exception("Unexpected helper action");
            }
            return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(output+"\n"),[]));
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Expected bounded streaming");
    }
}
