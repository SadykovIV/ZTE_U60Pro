using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class CoreReplacementTests
{
    private const string Cid="0123456789abcdef0123456789abcdef", Boot="12345678-1234-1234-1234-123456789abc";
    private static string Sha(byte[] bytes)=>Convert.ToHexStringLower(SHA256.HashData(bytes));
    internal static async Task RunAsync()
    {
        var passed=0;
        void Check(bool value,string message){if(!value)throw new Exception(message);passed++;Console.WriteLine("PASS "+message);}
        foreach(var mode in new[]{"prepare","install","lost","dashboard","old-pending","foreign","busy","settings","lost-missing","bundle-ready","bundle-complete","reboot-complete","old-prepared","old-clean-complete","cleanup-reboot","dead","dead-unproven"})
        {
            var root=Path.Combine(Path.GetTempPath(),"zte-core-replacement-"+Guid.NewGuid());Directory.CreateDirectory(root);
            try
            {
                var resources=Path.Combine(root,"resources");Directory.CreateDirectory(Path.Combine(resources,"Onboarding"));Directory.CreateDirectory(Path.Combine(resources,"HostTools"));
                var hashes=new Dictionary<string,string>();
                foreach(var name in new[]{"adb.exe","zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh"})
                {
                    var bytes=name=="zte-agent"?await File.ReadAllBytesAsync("Windows_x64/Resources/Onboarding/zte-agent"):Encoding.UTF8.GetBytes("synthetic-"+name);
                    hashes[name]=Sha(bytes);await File.WriteAllBytesAsync(Path.Combine(resources,"Onboarding",name),bytes);
                }
                await File.WriteAllTextAsync(Path.Combine(resources,"Onboarding/SHA256.json"),JsonSerializer.Serialize(hashes));
                File.Copy("Windows_x64/Resources/HostTools/zte-timeout",Path.Combine(resources,"HostTools/zte-timeout"));
                Directory.CreateDirectory(Path.Combine(resources,"Tools/OpenSSH"));
                File.Copy("Windows_x64/Resources/Tools/adb.exe",Path.Combine(resources,"Tools/adb.exe"));
                File.Copy("Windows_x64/Resources/Tools/OpenSSH/ssh-keygen.exe",Path.Combine(resources,"Tools/OpenSSH/ssh-keygen.exe"));
                Directory.CreateDirectory(Path.Combine(root,"SSH"));
                var key=Path.Combine(root,"SSH/id_ed25519");var hosts=Path.Combine(root,"SSH/known_hosts");
                await File.WriteAllTextAsync(key,"synthetic key");await File.WriteAllTextAsync(hosts,"[192.0.2.1]:2222 ssh-ed25519 synthetic\n");
                var shell=new Shell{Lost=mode is "lost" or "lost-missing" or "bundle-ready",Busy=mode=="busy",SettingsMissing=mode=="settings"};var adbCalls=0;var webCalls=0;
                var adb=new AdbTransport((_,_,_,_)=>{adbCalls++;throw new Exception("Unexpected USB");},Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",root,resources,adb){ExistingKeyPath=key,ExistingKnownHostsPath=hosts,ExistingPort=2222,
                    ExistingSshFactory=()=>shell,WebFactory=()=>{webCalls++;throw new Exception("Unexpected Web");},
                    ReplacementPublicKey=_=>Task.FromResult(Encoding.UTF8.GetBytes("ssh-ed25519 synthetic\n"))};
                byte[]? old=null;
                if(mode is "old-pending" or "foreign" or "old-prepared" or "old-clean-complete" or "cleanup-reboot")
                {
                    var id=Guid.NewGuid().ToString("D");var backup=Path.Combine(root,"SetupBackups",id);Directory.CreateDirectory(backup);
                    var pending=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=mode=="foreign"?new string('f',32):Cid,
                        BootId=Boot,FirmwareHash="absent",RouterHash="absent",Profile="linux-arm64-access",InstallRequested=true,Phase="install-requested",
                        RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
                    if(mode=="old-prepared") { pending.InstallRequested=false;pending.Phase="prepared";pending.RemoteStage=null;pending.RemoteJournal=null; }
                    if(mode=="old-clean-complete") { pending.Phase="complete";pending.CleanComponents=true;pending.ForceReinstall=true; }
                    if(mode=="cleanup-reboot") {
                        pending.Phase="complete";pending.CleanComponents=true;pending.ForceReinstall=true;
                        var cleanup=new ComponentCleanupPending{Id=id,Cid=Cid,BootId=Boot,FirmwareHash="absent",RouterHash="absent",Host="192.0.2.1",Port=2222,KeyPath=key,KnownHostsPath=hosts,BackupDirectory=backup,SetupReceipt=Path.Combine(backup,"setup-result.json"),Profile="linux-arm64-access",Token=Guid.NewGuid().ToString("D"),Phase="prepared"};
                        await File.WriteAllTextAsync(Path.Combine(root,"component-cleanup-pending.json"),JsonSerializer.Serialize(cleanup));
                        shell.CurrentBoot="22345678-1234-1234-1234-123456789abc";
                    }
                    old=JsonSerializer.SerializeToUtf8Bytes(pending);await File.WriteAllBytesAsync(Path.Combine(root,"setup-pending.json"),old);
                }
                var preserve=mode!="prepare";var failed=false;
                try{await engine.ReplaceCoreAsync("",preserve?"":"TEST_PASSWORD","",preserveSettings:preserve);}
                catch(Exception e)when(e is IOException or InvalidDataException){if(mode is not ("lost" or "foreign" or "busy" or "settings" or "lost-missing" or "bundle-ready"))throw;failed=true;}
                Check(failed==(mode is "lost" or "foreign" or "busy" or "settings" or "lost-missing" or "bundle-ready"),"replacement result "+mode);
                if(mode is "lost" or "dashboard" or "settings" or "lost-missing" or "bundle-ready" or "bundle-complete" or "reboot-complete" or "dead" or "dead-unproven")
                {
                    if(mode=="lost-missing")shell.State="MISSING";
                    if(mode.StartsWith("bundle-",StringComparison.Ordinal)) {
                        var path=Path.Combine(root,OnboardingEngine.ReplacementPendingName);
                        var oldPlan=JsonSerializer.Deserialize<CoreReplacementPending>(await File.ReadAllTextAsync(path))!;
                        oldPlan.AgentSha=new string('b',64);shell.AgentSha=oldPlan.AgentSha;
                        await File.WriteAllTextAsync(path,JsonSerializer.Serialize(oldPlan));
                    }
                    if(mode is "dead" or "dead-unproven") {shell.Dead=true;shell.Unproven=mode=="dead-unproven";}
                    if(mode=="reboot-complete")shell.CurrentBoot="22345678-1234-1234-1234-123456789abc";
                    try { await engine.ReplaceCoreAsync("",mode=="settings"?"TEST_PASSWORD":"","",preserveSettings:mode!="settings");Check(mode!="dead-unproven","only proven absence permits repair "+mode); }
                    catch(InvalidDataException) when(mode=="dead-unproven") { }
                    Check(shell.Installs==((mode=="lost-missing"||mode.StartsWith("bundle-",StringComparison.Ordinal)||mode=="dead")?2:1)&&shell.Commits==(mode.StartsWith("bundle-",StringComparison.Ordinal)||mode=="dead"?2:1),"uncertain reply or dashboard retry never replays core "+mode);
                }
                if(mode=="dead-unproven") {
                    Check(shell.Installs==1&&shell.Commits==1&&File.Exists(Path.Combine(root,OnboardingEngine.ReplacementPendingName)),"unproven absence preserves completed operation without replay");
                }
                else if(mode is "foreign" or "busy")
                {
                    Check(shell.Installs==0&&shell.Uploads==0,"refusal precedes staging "+mode);
                    if(old is not null)Check((await File.ReadAllBytesAsync(Path.Combine(root,"setup-pending.json"))).SequenceEqual(old),"foreign dispatched journal retained exactly");
                }
                else
                {
                    var path=Path.Combine(root,OnboardingEngine.ReplacementPendingName);
                    var plan=JsonSerializer.Deserialize<CoreReplacementPending>(await File.ReadAllTextAsync(path))!;
                    Check(plan.Phase=="complete"&&shell.Installs==((mode=="lost-missing"||mode.StartsWith("bundle-",StringComparison.Ordinal)||mode=="dead")?2:1)&&shell.Commits==(mode.StartsWith("bundle-",StringComparison.Ordinal)||mode=="dead"?2:1),"core completion remains durable until dashboard acknowledgement "+mode);
                    Check(shell.Authentications==(!preserve||mode=="settings"?1:0),"credentials remain on-device for bundled replacement "+mode);
                    Check(shell.Commands.All(x=>!x.Contains("TEST_PASSWORD")&&!x.Contains("clean-components.sh")&&!x.Contains("--clean-reinstall")),"replacement never sends secrets or removes optional components "+mode);
                    if(mode=="old-clean-complete")Check(!File.Exists(Path.Combine(root,OnboardingEngine.CleanupPendingName)),"legacy completed clean flag cannot create an optional cleanup intent");
                    if(old is not null && mode!="cleanup-reboot")Check((await File.ReadAllBytesAsync(Path.Combine(root,"CoreReplacementBackups",plan.Id,"previous-setup.json"))).SequenceEqual(old)&&!File.Exists(Path.Combine(root,"setup-pending.json")),"old dispatched journal archived only after replacement commit");
                    if(mode=="cleanup-reboot")Check(!File.Exists(Path.Combine(root,"component-cleanup-pending.json")) && Directory.GetFiles(Path.Combine(root,"SetupBackups"),"cleanup-before-reset-*.json",SearchOption.AllDirectories).Length==1 && Directory.GetFiles(Path.Combine(root,"SetupBackups"),"previous-setup-before-replacement.json",SearchOption.AllDirectories).Length==1,"reboot cleanup retires only host journals and retains exact setup backup");
                    var features=new ZteImeiStudio.Windows.Features.DeviceFeatureService(shell,resources,root);
                    var blocked=false;try{await features.MutateAsync((_,_)=>Task.FromResult(true),CancellationToken.None);}catch(ZteImeiStudio.Windows.Features.DeviceFeatureException){blocked=true;}
                    Check(blocked,"ordinary mutation blocked while replacement awaits final acknowledgement "+mode);
                    await engine.AcknowledgeCoreReplacementAsync();Check(!File.Exists(path),"acknowledged replacement clears its own pending "+mode);
                }
                Check(adbCalls==0&&webCalls==0,"verified SSH replacement uses no Web or USB "+mode);
            }
            finally{Directory.Delete(root,true);}
        }
        Console.WriteLine($"RESULT {passed} core replacement checks; no device");
    }
    private sealed class Shell:IRemoteShell
    {
        internal List<string> Commands=[];internal int Installs,Commits,Authentications,Uploads;internal bool Lost,Busy,SettingsMissing,Dead,Unproven;internal string CurrentBoot=Boot,State="ready",AgentSha=AgentPackage.Sha256;private string journal="";
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            Commands.Add(command);var text="";
            if(command==AccessIdentity.Command)text="absent  /firmware/image/modem.b16\nabsent  /usr/bin/diag-router\n"+Cid+"\n"+CurrentBoot+"\n";
            else if(command.Contains("'--preflight'"))
            {
                if(SettingsMissing){SettingsMissing=false;return Task.FromResult(new RemoteResult(1,[],Encoding.UTF8.GetBytes("INSTALL_ERROR AGENT_SETTINGS_REQUIRED\n")));}
                if(Busy)return Task.FromResult(new RemoteResult(1,[],Encoding.UTF8.GetBytes("INSTALL_ERROR CORE_RECOVERY_BUSY\nPRIVATE\n")));
                text="INSTALL_PREFLIGHT linux-arm64-access imei_config=unknown\n";
            }
            else if(command.Contains("INSTALL_STAGE_READY"))text="INSTALL_STAGE_READY\n";
            else if(stdin is not null&&command.Contains("; sha256sum '"))
            {Uploads++;var target=Regex.Match(command,@"; sha256sum '([^']+)'$").Groups[1].Value;text=Sha(stdin)+"  "+target+"\n";}
            else if(command.Contains("ZTE_INSTALL_STATE_PROBE"))text="INSTALL_STATE "+State+"\n";
            else if(command.Contains("'--commit'")){Commits++;text="INSTALL_COMMITTED "+journal+"\n";}
            else if(command.Contains("/setup-agent.sh' "))
            {
                Installs++;AgentSha=AgentPackage.Sha256;Dead=false;var stage=Regex.Match(command,@"'/data/zte-imei-studio/stage-([a-f0-9-]+)/setup-agent.sh'").Groups[1].Value;
                journal="/data/zte-imei-studio/installations/"+stage;
                if(Lost){Lost=false;return Task.FromResult(new RemoteResult(255,[],Encoding.UTF8.GetBytes("PRIVATE lost reply")));}
                text="INSTALL_READY "+journal+"\n";
            }
            else if(command.Contains("AGENT_ACCESS_ABSENT")) {
                if(Unproven)return Task.FromResult(new RemoteResult(73,[],[]));
                text="AGENT_ACCESS_ABSENT "+AgentSha+"\n";
            }
            else if(command.Contains("AGENT_ACCESS_PROOF")) {
                if(Dead)return Task.FromResult(new RemoteResult(71,[],[]));
                text="AGENT_ACCESS_PROOF "+AgentSha+" 123 456\n";
            }
            else if(command.Contains("/api/auth/login")){Authentications++;text="{\"ok\":true,\"data\":{\"token\":\"synthetic\"}}";}
            else if(command.Contains("/.install-requested'")){}
            else throw new Exception("Unexpected SSH command");
            return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(text),[]));
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload API");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected secret download");
    }
}
