using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class ReadyReinstallTests
{
    const string Cid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Boot="11111111-1111-1111-1111-111111111111";
    internal static async Task RunAsync()
    {
        var root=Path.Combine(Path.GetTempPath(),"zte-ready-reinstall-"+Guid.NewGuid());Directory.CreateDirectory(root);var count=0;
        void Check(bool ok,string label){if(!ok)throw new Exception("FAIL "+label);count++;Console.WriteLine("PASS "+label);}
        try
        {
            foreach(var scenario in new[]{"ready","complete","legacy-no-boot","proof-failed","commit-lost","identity-changed","boot-changed","local-journal-changed"})
            {
                var storage=Path.Combine(root,scenario);Directory.CreateDirectory(Path.Combine(storage,"SSH"));
                File.WriteAllText(Path.Combine(storage,"SSH/id_ed25519"),"synthetic");File.WriteAllText(Path.Combine(storage,"SSH/known_hosts"),"synthetic");
                var id=Guid.NewGuid().ToString();var backup=Path.Combine(storage,"SetupBackups",id);Directory.CreateDirectory(backup);
                var old=new OnboardingPending{Id=id,BackupDirectory=backup,IdentitySource="single-usb",Intent="linux-arm64-access",Cid=Cid,BootId=Boot,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,Profile="linux-arm64-access",InstallRequested=true,Phase=scenario=="complete"?"complete":"ready",RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id,NewAgent=false};
                if(scenario=="legacy-no-boot") {old.Profile="b31";old.Intent="preparation";old.IdentitySource="web-matched";old.WebIdentity=new WebIdentity("353490068701222","CN_ZTE_MU5250V1.0.0B31","BD_CNMU5250V1.0.0B31");old.BootId=null;}
                var path=Path.Combine(storage,"setup-pending.json");var original=JsonSerializer.SerializeToUtf8Bytes(old);File.WriteAllBytes(path,original);
                var ssh=new PriorShell(old,scenario,path);var preflight=0;var uploads=0;
                var adb=new AdbTransport((args,stream,_,_)=>
                {
                    if(args[0]=="devices")return Task.FromResult(Reply("fixture device usb:1\n"));
                    if(args[0]=="-d")return Task.FromResult(Reply("fixture\n"));
                    if(args.Contains("push")){uploads++;throw new Exception("Unexpected upload");}
                    var command=stream?.OriginalCommand??args[^1];var marker=stream?.Result??Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix=stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n";
                    if(command.Contains("'--preflight'"))
                    {
                        preflight++;Check(command.Contains(" -- '--reinstall' '--preflight' "),"new transaction after ready reconciliation requires reinstall");
                        return Task.FromResult(Reply(prefix+"\n"+marker+"71\n"));
                    }
                    if(!command.Contains("observed_hash()"))throw new Exception("Unexpected ADB mutation");
                    return Task.FromResult(Reply(prefix+Identity()+"\n"+marker+"0\n"));
                },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",storage,Path.GetFullPath("Windows_x64/Resources"),adb){InstalledSshFactory=()=>ssh,WebFactory=()=>new ModemWebClient("192.0.2.1",new NoWeb())};
                try{await engine.PrepareAsync("","synthetic-new-password","",cleanComponents:true);throw new Exception("Unexpected success");}catch(Exception error) when(error is IOException or InvalidDataException){}
                var success=scenario is "ready" or "complete" or "legacy-no-boot";
                var current=File.ReadAllBytes(path);
                Check(preflight==(success?1:0)&&uploads==0&&ssh.AuthCalls==0,"old-ready reconciliation never authenticates old credentials, reapplies old setup or uploads: "+scenario);
                if(success)
                {
                    var next=JsonSerializer.Deserialize<OnboardingPending>(current)!;
                    Check(next.Id!=old.Id&&next.ForceReinstall&&next.CleanComponents&&!next.InstallRequested,"verified old ready produces a distinct durable forced clean transaction");
                    Check(File.ReadAllBytes(Path.Combine(backup,"setup-before-clean-reinstall.json")).AsSpan().SequenceEqual(original)&&File.Exists(Path.Combine(backup,"setup-result.json")),"old journal and completion receipt remain archived before fresh preparation");
                }
                else Check((scenario=="local-journal-changed"?Encoding.UTF8.GetString(current).EndsWith(" "):current.AsSpan().SequenceEqual(original))&&!File.Exists(Path.Combine(backup,"setup-result.json")),"uncertain old-ready result preserves pending and prevents new preparation: "+scenario);
            }
            if(!OperatingSystem.IsWindows())await ShellProofs(root,Check);
        }
        finally{Directory.Delete(root,true);}
        Console.WriteLine($"RESULT {count} ready reinstall checks; no device");
    }
    [System.Runtime.Versioning.UnsupportedOSPlatform("windows")]
    static async Task ShellProofs(string root,Action<bool,string> check)
    {
        foreach(var scenario in new[]{"same","rc775","before-changed","after-changed","mapped-changed","missing-manifest","script-changed","extra-target","wrong-owner","unsafe-stage","no-process","duplicate-process","unknown-phase"})
        {
            var dir=Path.Combine(root,"shell-"+scenario);var id=Guid.NewGuid().ToString();var data=Path.Combine(dir,"data");var anchor=Path.Combine(data,"zte-imei-studio");var journal=Path.Combine(anchor,"installations",id);var stage=Path.Combine(anchor,"stage-"+id);
            var targets=new[]{"data/zte-agent","data/zte-imei-studio/bin/dropbear","data/zte-imei-studio/bin/dropbearkey","etc/dropbear/authorized_keys","etc/dropbear/dropbear_ed25519_host_key","etc/dropbear/dropbear_rsa_host_key","data/zte-imei-studio/start_zte_agent.sh","data/zte-imei-studio/start_zte_imei_studio.sh","etc/rc.local"};
            void Put(string path,string value){Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,value);File.SetUnixFileMode(path,(UnixFileMode)Convert.ToInt32("600",8));}
            string Hash(string path)=>Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
            foreach(var t in targets)Put(Path.Combine(dir,t),"synthetic "+t);
            var device=new DeviceIdentity(Cid,ImeiEngine.FirmwareHash,Boot,ImeiEngine.RouterHash);
            var pending=new OnboardingPending{Id=id,Profile="b31",InstallRequested=true,RemoteStage="/data/zte-imei-studio/stage-"+id,RemoteJournal="/data/zte-imei-studio/installations/"+id};
            var owner=string.Join(' ',new[]{id}.Concat(OnboardingEngine.InstallerPolicy(device,"b31")));
            Put(Path.Combine(stage,".owner"),scenario=="wrong-owner"?"foreign":owner);Put(Path.Combine(stage,".install-requested"),owner);Put(Path.Combine(stage,"setup-agent.sh"),"synthetic original script");
            Put(Path.Combine(journal,"cid"),Cid);Put(Path.Combine(journal,"profile.identity"),"b31 "+device.FirmwareHash+" "+device.RouterHash);Put(Path.Combine(journal,"state"),scenario=="unknown-phase"?"changing":"ready");
            var before=Path.Combine(journal,"before/etc_rc.local");Put(before,"synthetic previous rc.local");Put(Path.Combine(journal,"before.sha256"),Hash(before)+"  "+before+"\n");
            var after=targets.Select(t=>Path.Combine(dir,t)).Concat(new[]{Path.Combine(journal,"cid"),Path.Combine(journal,"profile.identity")});Put(Path.Combine(journal,"after.sha256"),string.Concat(after.Select(p=>Hash(p)+"  "+p+"\n")));
            Put(Path.Combine(dir,"live-cid"),Cid);Put(Path.Combine(dir,"live-boot"),Boot);Put(Path.Combine(dir,"proc/100/exe"),File.ReadAllText(Path.Combine(data,"zte-agent")));
            foreach(var folder in Directory.GetDirectories(dir,"*",SearchOption.AllDirectories).Append(dir))File.SetUnixFileMode(folder,(UnixFileMode)Convert.ToInt32("700",8));
            if(scenario=="rc775"){File.SetUnixFileMode(before,(UnixFileMode)Convert.ToInt32("775",8));File.SetUnixFileMode(Path.Combine(dir,"etc/rc.local"),(UnixFileMode)Convert.ToInt32("775",8));}
            if(scenario=="before-changed")Put(before,"changed");
            if(scenario=="after-changed")Put(Path.Combine(data,"zte-agent"),"changed");
            if(scenario=="mapped-changed")Put(Path.Combine(dir,"proc/100/exe"),"changed");
            if(scenario=="missing-manifest")File.Delete(Path.Combine(journal,"before.sha256"));
            if(scenario=="extra-target")File.AppendAllText(Path.Combine(journal,"after.sha256"),new string('a',64)+"  /private/unapproved\n");
            if(scenario=="unsafe-stage")File.SetUnixFileMode(stage,(UnixFileMode)Convert.ToInt32("777",8));
            var expectedInstallerHash=Hash(Path.Combine(stage,"setup-agent.sh"));
            if(scenario=="script-changed")Put(Path.Combine(stage,"setup-agent.sh"),"unknown revision");
            var body=OnboardingEngine.PriorReadyProofCommand(pending,device,expectedInstallerHash).Replace("/data/",data+"/",StringComparison.Ordinal).Replace("/data ",data+" ",StringComparison.Ordinal).Replace("/etc/",Path.Combine(dir,"etc")+"/",StringComparison.Ordinal).Replace(" /etc;", " "+Path.Combine(dir,"etc")+";",StringComparison.Ordinal).Replace("/proc/$pid/exe",Path.Combine(dir,"proc/$pid/exe"),StringComparison.Ordinal).Replace("/sys/block/mmcblk0/device/cid",Path.Combine(dir,"live-cid"),StringComparison.Ordinal).Replace("/proc/sys/kernel/random/boot_id",Path.Combine(dir,"live-boot"),StringComparison.Ordinal);
            var shims="stat() { case \"$2\" in %u) printf '0\\n';; %a) /usr/bin/stat -f %Lp \"$3\";; %u:%h) printf '0:'; /usr/bin/stat -f %l \"$3\";; *) exit 88;; esac; };\nsha256sum() { /usr/bin/shasum -a 256 \"$@\"; };\npidof() { printf '"+(scenario=="no-process"?"":scenario=="duplicate-process"?"100 100":"100")+"'; };\nreadlink() { printf '%s' '"+Path.Combine(data,"zte-agent")+"'; };\n";
            var start=new ProcessStartInfo("/bin/sh"){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};start.ArgumentList.Add("-c");start.ArgumentList.Add(shims+body);
            using var child=Process.Start(start)!;var stdout=child.StandardOutput.ReadToEndAsync();var stderr=child.StandardError.ReadToEndAsync();await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));var output=await stdout;_ = await stderr;
            check(scenario is "same" or "rc775"?child.ExitCode==0&&output=="INSTALL_PRIOR_READY_VERIFIED\n":child.ExitCode!=0&&output=="","actual readonly old-journal manifest and mapped process proof: "+scenario);
        }
    }
    static string Identity(string? boot=null)=>ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+(boot??Boot);
    static RemoteResult Reply(string s)=>new(0,Encoding.UTF8.GetBytes(s),[]);
    sealed class PriorShell(OnboardingPending old,string scenario,string pendingPath):IRemoteShell
    {
        internal int AuthCalls,IdentityCalls;
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            if(command==AccessIdentity.Command){IdentityCalls++;var text=Identity(scenario=="boot-changed"&&IdentityCalls>1?"22222222-2222-2222-2222-222222222222":null);if(scenario=="identity-changed")text=text.Replace(Cid,new string('b',32));return Task.FromResult(Reply(text));}
            if(command=="sh -s --"&&stdin is not null&&Encoding.UTF8.GetString(stdin).Contains("INSTALL_PRIOR_READY_VERIFIED"))return Task.FromResult(scenario=="proof-failed"?new RemoteResult(71,[],[]):Reply("INSTALL_PRIOR_READY_VERIFIED\n"));
            if(command.Contains("'--commit'")){if(scenario=="local-journal-changed")File.AppendAllText(pendingPath," ");return Task.FromResult(scenario=="commit-lost"?new RemoteResult(255,[],[]):Reply("INSTALL_COMMITTED "+old.RemoteJournal+"\n"));}
            if(command.Contains("/api/auth/login"))AuthCalls++;
            throw new Exception("Unexpected old-ready action");
        }
        public Task UploadAsync(string p,byte[] d,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string p,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
    sealed class NoWeb:IWebTransport{public Task<WebReply> RequestAsync(string path,byte[]? data=null,string? contentType=null,string? cookie=null,CancellationToken ct=default)=>throw new Exception("Unexpected Web request");}
}
