using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class AccessAgentReuseTests
{
    private const string Cid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string Boot="11111111-1111-1111-1111-111111111111";
    private static readonly WebIdentity B31=new("353490068701222","CN_ZTE_MU5250V1.0.0B31","BD_CNMU5250V1.0.0B31");
    private static void Need(bool value){if(!value)throw new Exception("Assertion failed");}
    private static RemoteResult Reply(string value,int code=0)=>new(code,Encoding.UTF8.GetBytes(value),[]);
    internal static async Task RunAsync()
    {
        var root=Path.Combine(Path.GetTempPath(),"zte-access-reuse-"+Guid.NewGuid());Directory.CreateDirectory(root);
        var passed=0;var failed=0;
        async Task Test(string name,Func<Task> work){try{await work();Console.WriteLine("PASS "+name);passed++;}catch(Exception error){Console.WriteLine("FAIL "+name+" ("+error.GetType().Name+")");failed++;}}
        try
        {
            foreach(var scenario in new[]{"previous","previous-public","latest","unknown-hash","mapped-mismatch","wrong-password","changed-boot","changed-process","changed-hash","generic-old","duplicate-process","no-cid-nonroot","no-metadata"})
                await Test("PrepareAsync existing reuse "+scenario,async()=>
                {
                    var storage=Path.Combine(root,scenario);Directory.CreateDirectory(Path.Combine(storage,"SSH"));File.WriteAllText(Path.Combine(storage,"SSH","id_ed25519"),"synthetic-key");File.WriteAllText(Path.Combine(storage,"SSH","known_hosts"),"synthetic-host");
                    var wire=new Web();var remote=new Remote(scenario);var adbCalls=0;
                    var adb=new AdbTransport((_,_,_)=>{adbCalls++;throw new Exception("Unexpected ADB/install fallback");});
                    var engine=new OnboardingEngine("192.168.0.1",storage,Path.GetFullPath("Windows_x64/Resources"),adb)
                        {WebFactory=()=>new ModemWebClient("192.168.0.1",wire),ExistingSshFactory=()=>remote};
                    var success=scenario!="changed-boot";
                    try
                    {
                        var result=await engine.PrepareAsync("","","");
                        Need(success && result.AlreadyConfigured && result.AccessOnly && result.Profile=="read-only-ssh" && result.Cid==(scenario is "no-cid-nonroot" or "no-metadata"?null:Cid));
                        Need(result.ReusedAgentVersion is null);
                        Need(remote.AuthCalls==0 && remote.ProofCalls==0 && remote.IdentityCalls==2 && wire.Calls==0);
                    }
                    catch(InvalidDataException){Need(!success);}
                    Need(adbCalls==0 && wire.Backups==0 && remote.Uploads==0 && !Directory.Exists(Path.Combine(storage,"SetupBackups")) && !File.Exists(Path.Combine(storage,"setup-pending.json")));
                    Need(remote.Commands.All(x=>!x.Contains("diag-router -",StringComparison.Ordinal)&&!x.Contains("dd ",StringComparison.Ordinal)&&!x.Contains("setup-agent",StringComparison.Ordinal)));
                    Need(remote.PasswordOnlyInStdin);
                    if(scenario is "unknown-hash" or "mapped-mismatch" or "generic-old" or "duplicate-process")Need(remote.AuthCalls==0);
                });
            await Test("PrepareAsync sole USB can reuse exact B31 without Web or uploads",async()=>
            {
                var storage=Path.Combine(root,"usb");Directory.CreateDirectory(Path.Combine(storage,"SSH"));File.WriteAllText(Path.Combine(storage,"SSH","id_ed25519"),"synthetic-key");File.WriteAllText(Path.Combine(storage,"SSH","known_hosts"),"synthetic-host");
                var remote=new Remote("previous");var web=new Web{Forbidden=true};var identities=0;
                var adb=new AdbTransport((arguments,_,_)=>
                {
                    if(arguments[0]=="devices")return Task.FromResult(Reply("one device usb:1\n"));
                    if(arguments[0]=="-d")return Task.FromResult(Reply("one\n"));
                    Need(arguments[0]=="-s"&&arguments[2]=="shell"&&arguments[3].Contains("observed_hash()",StringComparison.Ordinal));identities++;
                    var marker=Regex.Match(arguments[3],"__ZTE_RESULT_[A-F0-9]{32}__").Value;return Task.FromResult(Reply(Remote.Identity(false,false)+"\n"+marker+"0\n"));
                });
                var engine=new OnboardingEngine("192.168.0.1",storage,Path.GetFullPath("Windows_x64/Resources"),adb){ExistingSshFactory=()=>remote,WebFactory=()=>new ModemWebClient("192.168.0.1",web)};
                var result=await engine.PrepareAsync("","synthetic-agent-password","");Need(result.AlreadyConfigured&&result.AccessOnly&&identities==0&&remote.IdentityCalls==2&&web.Calls==0);
            });
            await Test("SSH reuse preserves selected custom key paths and port without agent assets",async()=>
            {
                var storage=Path.Combine(root,"custom");Directory.CreateDirectory(storage);
                var key=Path.Combine(storage,"custom-key");var hosts=Path.Combine(storage,"custom-hosts");File.WriteAllText(key,"fixture");File.WriteAllText(hosts,"fixture");
                var remote=new Remote("no-cid-nonroot");
                var engine=new OnboardingEngine("192.0.2.1",storage,Path.Combine(root,"absent-resources"),new AdbTransport((_,_,_)=>throw new Exception("Unexpected USB")))
                    {ExistingKeyPath=key,ExistingKnownHostsPath=hosts,ExistingPort=2200,ExistingSshFactory=()=>remote};
                var result=await engine.PrepareAsync("","","");Need(result.KeyPath==key&&result.KnownHostsPath==hosts&&result.Port==2200&&result.Cid is null&&result.ReusedAgentVersion is null&&remote.AuthCalls==0);
            });
            await Test("Actual readonly shell does not require modem files root or ARM64",async()=>
            {
                var info=new ProcessStartInfo("/bin/sh"){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};info.ArgumentList.Add("-c");info.ArgumentList.Add(SshReadProof.Command);
                using var process=Process.Start(info)!;var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));_ = await stderr;
                Need(process.ExitCode==0);var proof=SshReadProof.Parse(Encoding.UTF8.GetBytes(await stdout));Need(proof.System=="Darwin"&&proof.Cid is null&&proof.BootId is null);
            });
            await Test("Pending setup blocks early reuse before SSH/agent proof",async()=>
            {
                var storage=Path.Combine(root,"pending");Directory.CreateDirectory(storage);File.WriteAllText(Path.Combine(storage,"setup-pending.json"),"{}");var calls=0;
                var engine=new OnboardingEngine("192.168.0.1",storage,Path.GetFullPath("Windows_x64/Resources"),new AdbTransport((_,_,_)=>{calls++;throw new Exception("Unexpected ADB");}))
                    {ExistingSshFactory=()=>{calls++;throw new Exception("Unexpected SSH");},WebFactory=()=>{calls++;throw new Exception("Unexpected Web");}};
                try{await engine.PrepareAsync("pw","agent","");throw new Exception("Pending accepted");}catch(InvalidDataException){Need(calls==0);}
            });
            await Test("Valid unfinished setup cannot bypass resume through trusted previous agent",async()=>
            {
                var storage=Path.Combine(root,"valid-pending");var backup=Path.Combine(storage,"SetupBackups",Guid.NewGuid().ToString());Directory.CreateDirectory(backup);
                var pending=new OnboardingPending{Id=Guid.NewGuid().ToString(),WebIdentity=B31,IdentitySource="web-matched",BackupDirectory=backup,Profile="b31",Cid=Cid,FirmwareHash=ImeiEngine.FirmwareHash,RouterHash=ImeiEngine.RouterHash,BootId=Boot};
                File.WriteAllText(Path.Combine(storage,"setup-pending.json"),JsonSerializer.Serialize(pending));var sshCalls=0;var adbCalls=0;var wire=new Web();
                var engine=new OnboardingEngine("192.168.0.1",storage,Path.GetFullPath("Windows_x64/Resources"),new AdbTransport((_,_,_)=>{adbCalls++;throw new IOException("synthetic unavailable ADB");}))
                    {ExistingSshFactory=()=>{sshCalls++;return new Remote("previous");},WebFactory=()=>new ModemWebClient("192.168.0.1",wire)};
                try{await engine.PrepareAsync("pw","agent","");throw new Exception("Unexpected early ready");}catch(IOException){Need(sshCalls==0&&adbCalls==1&&wire.Backups==0&&File.Exists(Path.Combine(storage,"setup-pending.json")));}
            });
            if(!OperatingSystem.IsWindows())
                foreach(var state in new[]{"good","mapped-different","unknown-disk","duplicate","bound","bound-legacy-mode","bound-missing","bound-wrong","bound-duplicate"})
                    await Test("Actual shell proof enforces disk/mapped PID "+state,async()=>
                    {
                        var directory=Path.Combine(root,"shell-"+state);Directory.CreateDirectory(directory);var agent=Path.Combine(directory,"agent");File.WriteAllText(agent,"synthetic");
                        foreach(var pid in new[]{"42","43"}){var proc=Path.Combine(directory,"proc",pid);Directory.CreateDirectory(proc);File.CreateSymbolicLink(Path.Combine(proc,"exe"),agent);File.WriteAllText(Path.Combine(proc,"stat"),pid+" (zte-agent) S "+string.Join(" ",Enumerable.Repeat("0",18))+" 456\n");}
                        string Q(string value)=>"'"+value.Replace("'","'\\''",StringComparison.Ordinal)+"'";
                        var disk=state=="unknown-disk"?new string('f',64):AccessAgentReusePolicy.PreviousB31Sha256;var mapped=state=="mapped-different"?AgentPackage.Sha256:disk;
                        var functions="pidof() { printf '%s\\n' '"+(state=="duplicate"?"42 43":"42")+"'; }; sha256sum() { case \"$1\" in */proc/*) printf '%s  file\\n' "+Q(mapped)+";; *) printf '%s  file\\n' "+Q(disk)+";; esac; };\n";
                        var address=state=="bound-wrong"?"192.0.2.2":"192.0.2.1";
                        var environment=state=="bound-missing"?"":"ZTE_AGENT_BIND="+address+":9090\0";
                        if(state=="bound-legacy-mode")environment+="ZTE_AGENT_MODE=discovery\0";
                        if(state=="bound-duplicate")environment+=environment;
                        File.WriteAllText(Path.Combine(directory,"proc","42","environ"),environment+"SYNTHETIC_SECRET=never-output\0");
                        var body=AccessAgentReusePolicy.Command(true).Replace("/data/zte-agent",agent,StringComparison.Ordinal).Replace("/proc/",directory+"/proc/",StringComparison.Ordinal);
                        var start=new ProcessStartInfo("/bin/sh"){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true};start.ArgumentList.Add("-c");start.ArgumentList.Add(functions+body);
                        using var process=Process.Start(start)!;var output=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();
                        Need(state is "good" or "bound" or "bound-legacy-mode" or "bound-missing" or "bound-wrong" or "bound-duplicate"?process.ExitCode==0&&output=="AGENT_ACCESS_PROOF "+disk+" 42 456\n":process.ExitCode==71&&output=="");
                        Need(!output.Contains("never-output",StringComparison.Ordinal));
                    });
            await Test("Generic, resumed and new setup policies reject historical agent",async()=>
            {
                var identity=new DeviceIdentity(Cid,ImeiEngine.FirmwareHash,Boot,ImeiEngine.RouterHash);
                Need(AccessAgentReusePolicy.AllowsPrevious(identity,"b31",true));
                Need(!AccessAgentReusePolicy.AllowsPrevious(identity,"b31",false)&&!AccessAgentReusePolicy.AllowsPrevious(identity,"linux-arm64-access",true));
                Need(!AccessAgentReusePolicy.AllowsPrevious(identity with{RouterHash=new string('f',64)},"b31",true));
                try{await AccessAgentReusePolicy.ReadAsync(new Remote("previous"),false,CancellationToken.None);throw new Exception("Old new-install agent accepted");}catch(InvalidDataException){ }
                Need(!AccessAgentReusePolicy.Command(false).Contains(AccessAgentReusePolicy.PreviousB31Sha256,StringComparison.Ordinal));
            });
            await Test("Service reuse returns before dashboard install; feature gates preserved",()=>
            {
                var text=File.ReadAllText("Windows_x64/src/WindowsModemService.Administration.cs");
                var check=text.IndexOf("if (setup.AlreadyConfigured)",StringComparison.Ordinal);var dashboard=text.IndexOf("InstallDashboardForCurrentAgentAsync",StringComparison.Ordinal);
                Need(check>=0&&check<dashboard&&text[check..dashboard].Contains("return ",StringComparison.Ordinal));
                Need(text.Contains("[\"access_only\"] = setup.AccessOnly || setup.Profile == \"linux-arm64-access\"",StringComparison.Ordinal));return Task.CompletedTask;
            });
        }
        finally{Directory.Delete(root,true);}
        Console.WriteLine($"Access reuse: {passed} passed, {failed} failed; synthetic transports only");if(failed!=0)throw new Exception("Access reuse regression");
    }
    private sealed class Remote(string scenario):IRemoteShell
    {
        public List<string> Commands {get;}=[];public int AuthCalls,ProofCalls,IdentityCalls,Uploads;public bool PasswordOnlyInStdin=true;
        internal static string Identity(bool web,bool unknown,bool changed=false)=>
            (unknown?new string('c',64):ImeiEngine.FirmwareHash)+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+(changed?"22222222-2222-2222-2222-222222222222":Boot)+"\n"+
            (web?JsonSerializer.Serialize(new{imei=B31.Imei,integrate_version=B31.Firmware,wa_inner_version=B31.Inner}):"");
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            Commands.Add(command);Need(!command.Contains("synthetic-agent-password",StringComparison.Ordinal));
            if(command==SshReadProof.Command)
            {
                IdentityCalls++;
                var missing=scenario is "no-cid-nonroot" or "no-metadata";
                var value=scenario=="no-metadata"?"ZTE_SSH_READ_V1\n?\n?\n?\n?\n?\n?\n?\n":
                    "ZTE_SSH_READ_V1\n"+(missing?"1000":"0")+"\nLinux\n"+(missing?"armv7l":"aarch64")+"\n"+(missing?"?":Cid)+"\n"+(scenario=="changed-boot"&&IdentityCalls>1?"22222222-2222-2222-2222-222222222222":Boot)+"\n"+(missing?"?":ImeiEngine.FirmwareHash)+"\n"+(missing?"absent":ImeiEngine.RouterHash)+"\n";
                return Task.FromResult(Reply(value));
            }
            if(command.Contains("observed_hash()",StringComparison.Ordinal)){IdentityCalls++;return Task.FromResult(Reply(Identity(command.Contains("ubus",StringComparison.Ordinal),scenario=="generic-old",scenario=="changed-boot"&&IdentityCalls>1)));}
            if(command.Contains("AGENT_ACCESS_PROOF",StringComparison.Ordinal))
            {
                ProofCalls++;Need(command.Contains("sha256sum /data/zte-agent",StringComparison.Ordinal)&&command.Contains("sha256sum /proc/$p/exe",StringComparison.Ordinal));
                Need(command.Contains("test \"$mapped\" = \"$disk\"",StringComparison.Ordinal));
                if(scenario is "mapped-mismatch" or "duplicate-process")return Task.FromResult(Reply("",71));
                var hash=scenario=="latest"?AgentPackage.Sha256:scenario=="previous-public"?AccessAgentReusePolicy.PreviousPublicB31Sha256:scenario=="unknown-hash"?new string('f',64):scenario=="changed-hash"&&ProofCalls>1?AgentPackage.Sha256:AccessAgentReusePolicy.PreviousB31Sha256;
                return Task.FromResult(Reply("AGENT_ACCESS_PROOF "+hash+" "+(scenario=="changed-process"&&ProofCalls>1?"124":"123")+" 456\n"));
            }
            if(command.Contains("/api/auth/login",StringComparison.Ordinal))
            {
                AuthCalls++;PasswordOnlyInStdin&=stdin is not null&&JsonDocument.Parse(stdin).RootElement.GetProperty("password").GetString()=="synthetic-agent-password";
                return Task.FromResult(scenario=="wrong-password"?Reply("",22):Reply("{\"ok\":true,\"data\":{\"token\":\"synthetic-token\"}}"));
            }
            throw new Exception("Unexpected remote operation");
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default){Uploads++;throw new Exception("Unexpected upload");}
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
    private sealed class Web:IWebTransport
    {
        public int Calls,Backups;public bool Forbidden;
        public Task<WebReply> RequestAsync(string path,byte[]? data=null,string? contentType=null,string? cookie=null,CancellationToken ct=default)
        {
            Calls++;if(Forbidden)throw new Exception("Unexpected Web call");if(path!="/ubus/"){Backups++;throw new Exception("Unexpected backup/download");}
            using var doc=JsonDocument.Parse(data!);var method=doc.RootElement[0].GetProperty("params")[2].GetString();var headers=new Dictionary<string,string[]>();object reply;
            switch(method)
            {
                case "web_login_info":reply=new{zte_web_sault="synthetic"};break;
                case "web_login":reply=new{result=0,ubus_rpc_session="11111111111111111111111111111111"};headers["Set-Cookie"]=["webtoken=synthetic-cookie; Path=/"];break;
                case "device_info":reply=new{imei=B31.Imei,integrate_version=B31.Firmware,wa_inner_version=B31.Inner};break;
                default:Backups++;throw new Exception("Unexpected Web mutation");
            }
            return Task.FromResult(new WebReply(JsonSerializer.SerializeToUtf8Bytes(new[]{new{result=new object[]{0,reply}}}),headers));
        }
    }
}
