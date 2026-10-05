using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class ForcePreparationTests
{
    private const string Cid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",Boot="11111111-1111-1111-1111-111111111111";
    internal static async Task RunAsync()
    {
        var root=Path.Combine(Path.GetTempPath(),"zte-force-prepare-"+Guid.NewGuid());Directory.CreateDirectory(root);var passed=0;
        void Check(bool ok,string label){if(!ok)throw new Exception("FAIL "+label);passed++;Console.WriteLine("PASS "+label);}
        try
        {
            foreach(var saved in new bool?[]{null,false,true})
            {
                var folder=Path.Combine(root,Guid.NewGuid().ToString());Directory.CreateDirectory(Path.Combine(folder,"SSH"));
                File.WriteAllText(Path.Combine(folder,"SSH/id_ed25519"),"synthetic");File.WriteAllText(Path.Combine(folder,"SSH/known_hosts"),"synthetic");
                var backup=Path.Combine(folder,"SetupBackups",Guid.NewGuid().ToString());Directory.CreateDirectory(backup);
                if(saved is not null)await File.WriteAllTextAsync(Path.Combine(folder,"setup-pending.json"),JsonSerializer.Serialize(new OnboardingPending
                {Id=Guid.NewGuid().ToString(),BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Profile="linux-arm64-access",ForceReinstall=saved.Value}));
                var ssh=new ReadySsh();var preflight=0;var uploads=0;var requested=saved!=true;var expected=saved??requested;
                var adb=new AdbTransport((args,stream,_,_)=>
                {
                    if(args[0]=="devices")return Task.FromResult(Reply("fixture device usb:1\n"));
                    if(args[0]=="-d")return Task.FromResult(Reply("fixture\n"));
                    if(args.Contains("push")){uploads++;throw new Exception("Unexpected upload");}
                    var command=stream?.OriginalCommand??args[^1];var marker=stream?.Result??Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix=stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n";
                    if(command.Contains("'--preflight'"))
                    {
                        preflight++;
                        Check(command.Contains(" -- '--reinstall' '--preflight' ")==expected,"actual preflight uses persisted force intent before the original arguments");
                        return Task.FromResult(Reply(prefix+"\n"+marker+"71\n"));
                    }
                    if(!command.Contains("observed_hash()"))throw new Exception("Unexpected non-read command");
                    return Task.FromResult(Reply(prefix+ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+Boot+"\n"+marker+"0\n"));
                },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",folder,Path.GetFullPath("Windows_x64/Resources"),adb){ExistingSshFactory=()=>ssh,WebFactory=()=>new ModemWebClient("192.0.2.1",new NoWeb())};
                try{await engine.PrepareAsync("","synthetic-new-password","",forceReinstall:requested);}catch(IOException){}
                Check(preflight==1&&ssh.Calls==0&&uploads==0,"explicit force/new or saved intent reaches measured preflight without SSH reuse, Web or uploads");
                var pending=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(Path.Combine(folder,"setup-pending.json")))!;
                Check(pending.ForceReinstall==expected&&!pending.InstallRequested,"force intent is durable before dispatch and cannot override an existing journal");
                Check(OnboardingEngine.InstallerArguments(pending,new[]{"stage","cid","agent-sha","dropbear-sha","key-sha","profile"}).SequenceEqual((expected?new[]{"--reinstall"}:Array.Empty<string>()).Concat(new[]{"stage","cid","agent-sha","dropbear-sha","key-sha","profile"})),"normal apply keeps its original CLI arguments behind the optional leading flag");
            }
            foreach(var scenario in new[]{"pending","rollback-unknown","rollback-confirmed","ordinary-rollback"})
            {
                var folder=Path.Combine(root,Guid.NewGuid().ToString());Directory.CreateDirectory(folder);
                var id=Guid.NewGuid().ToString();var backup=Path.Combine(folder,"SetupBackups",id);Directory.CreateDirectory(backup);
                File.WriteAllText(Path.Combine(backup,"original-encrypted.fixture"),"synthetic-preserved");
                var journal="/data/zte-imei-studio/installations/"+id;
                var pending=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Profile="linux-arm64-access",ForceReinstall=scenario!="ordinary-rollback",InstallRequested=true,Phase="install-requested",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal=journal};
                var pendingPath=Path.Combine(folder,"setup-pending.json");await File.WriteAllTextAsync(pendingPath,JsonSerializer.Serialize(pending));
                var preflights=0;var uploads=0;var verifications=0;var ssh=new ReadySsh();
                var adb=new AdbTransport((args,stream,_,_)=>
                {
                    if(args[0]=="devices")return Task.FromResult(Reply("fixture device usb:1\n"));
                    if(args[0]=="-d")return Task.FromResult(Reply("fixture\n"));
                    if(args.Contains("push")){uploads++;throw new Exception("Unexpected upload");}
                    var command=stream?.OriginalCommand??args[^1];var marker=stream?.Result??Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix=stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n";string body;var code=0;
                    if(command.Contains(" -- '--preflight' ")||command.Contains(" -- '--reinstall' ")){preflights++;throw new Exception("Replay attempted");}
                    if(command.Contains(" -- '--verify-rollback' ")){verifications++;Check(!command.Contains(" -- '--reinstall' "),"rollback verification never receives a mutation flag");body="INSTALL_ROLLBACK_VERIFIED "+journal;if(scenario=="rollback-unknown"){body="unverified";code=71;}}
                    else if(command.Contains("cat '"+journal+"/state'"))body=scenario=="pending"?"pending":"rolled-back";
                    else if(command.Contains("observed_hash()"))body=ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+Boot;
                    else throw new Exception("Unexpected resume operation");
                    return Task.FromResult(Reply(prefix+body+"\n"+marker+code+"\n"));
                },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",folder,Path.GetFullPath("Windows_x64/Resources"),adb){ExistingSshFactory=()=>ssh,WebFactory=()=>new ModemWebClient("192.0.2.1",new NoWeb())};
                try{await engine.PrepareAsync("","synthetic-new-password","",forceReinstall:true);throw new Exception("Unexpected success");}catch(InvalidOperationException){}
                var verified=scenario=="rollback-confirmed";
                Check(File.Exists(pendingPath)!=verified&&File.Exists(Path.Combine(backup,"setup-rolled-back-"+id+".json"))==verified,"only verified forced rollback archives the pending journal: "+scenario);
                Check(preflights==0&&uploads==0&&ssh.Calls==0&&verifications==(scenario is "rollback-confirmed" or "rollback-unknown"?1:0),"pending intent never replays install or relies on bare rollback state: "+scenario);
                Check(File.ReadAllText(Path.Combine(backup,"original-encrypted.fixture"))=="synthetic-preserved","rollback handling preserves prior backups: "+scenario);
                Check(File.Exists(Path.Combine(backup,"rollback-verification.txt"))==verified,"only verified rollback saves a private proof: "+scenario);
            }
        }
        finally{Directory.Delete(root,true);}
        Console.WriteLine($"RESULT {passed} force preparation checks; no device");
    }
    private static RemoteResult Reply(string text)=>new(0,Encoding.UTF8.GetBytes(text),[]);
    private sealed class ReadySsh:IRemoteShell
    {
        public int Calls;
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {Calls++;return Task.FromResult(Reply("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n"+Cid+"\n"+Boot+"\n"+ImeiEngine.FirmwareHash+"\n"+ImeiEngine.RouterHash+"\n"));}
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
    private sealed class NoWeb:IWebTransport
    {
        public Task<WebReply> RequestAsync(string path,byte[]? data=null,string? contentType=null,string? cookie=null,CancellationToken ct=default)=>throw new Exception("Unexpected Web request");
    }
}
