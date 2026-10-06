using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

static class GenericLinuxFeaturesTests
{
    static int checks;
    static void Check(bool value,string name) { if(!value)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);checks++; }
    static async Task<int> Main(string[] args)
    {
        try { await Run(args[0]);Console.WriteLine("TOTAL "+checks+" PASS");return 0; }
        catch(Exception e) { Console.WriteLine(e);return 1; }
    }
    static async Task Run(string root)
    {
        var resources=Path.GetFullPath("Windows_x64/Resources");
        DeviceFeatureService Service(Fake f,string name) => new(f,resources,Path.Combine(root,name));
        foreach(var firmware in new[]{"b28","absent","b31"})
        {
            var f=new Fake{Firmware=firmware};var s=Service(f,firmware);
            var access=await s.GetAccessStatusAsync("192.0.2.1");
            Check(access.Services.Count==6&&f.Uploads==0&&f.Actions==0&&f.StrictReads==0&&f.MeasuredReads==2,firmware+" access status uses measured identity and writes nothing");
            await s.CreateSshAccountAsync("modemadmin","Synthetic123!","192.0.2.1");
            Check(f.Account&&f.Actions==1&&f.PasswordOnStdin&&f.StrictReads==0,firmware+" SSH create keeps stdin password and component checks");
            await s.DeleteSshAccountAsync("modemadmin","192.0.2.1");
            Check(!f.Account&&f.Actions==2,firmware+" owned SSH deletion remains available");
            await s.ChangeAccessServiceAsync("agent","stop","192.0.2.1");
            Check(!f.AgentRunning&&f.Actions==3,firmware+" owned service change uses measured policy");
            var d=new Fake{Firmware=firmware};var tools=Service(d,firmware+"-tools");
            await tools.GetDiagnosticToolsStatusAsync();
            Check(d.Actions==0&&d.StrictReads==0,firmware+" diagnostic inspect does not require B31");
            await tools.InstallDiagnosticToolsAsync("htop");await tools.RemoveDiagnosticToolsAsync("htop");await tools.RollbackDiagnosticToolsAsync();
            Check(d.Actions==3&&d.StrictReads==0,firmware+" diagnostic install remove rollback use pinned managers");
        }
        foreach(var operation in new[]{"access","tools"})
        {
            var f=new Fake{PlatformFailure=true};var s=Service(f,"platform-"+operation);
            try { if(operation=="access")await s.CreateSshAccountAsync("modemadmin","Synthetic123!","192.0.2.1");else await s.InstallDiagnosticToolsAsync();throw new Exception("platform accepted"); }
            catch(Exception e) when(e is DeviceFeatureException or InvalidDataException) { Check(f.Uploads==0&&f.Actions==0,"failed platform proof stops "+operation+" before staging"); }
            var changed=new Fake{Drift=true};var read=Service(changed,"drift-"+operation);
            try { if(operation=="access")await read.GetAccessStatusAsync("192.0.2.1");else await read.GetDiagnosticToolsStatusAsync();throw new Exception("drift accepted"); }
            catch(DeviceFeatureException) { Check(changed.Actions==0,"changed boot invalidates "+operation+" status"); }
        }
        var pendingPath=Path.Combine(root,"pending");Directory.CreateDirectory(pendingPath);
        File.WriteAllText(Path.Combine(pendingPath,"pending.json"),"synthetic");File.WriteAllText(Path.Combine(pendingPath,"setup-pending.json"),"synthetic");
        var pending=new Fake();var independent=new DeviceFeatureService(pending,resources,pendingPath);
        await independent.GetAccessStatusAsync("192.0.2.1");await independent.GetDiagnosticToolsStatusAsync();
        await independent.CreateSshAccountAsync("modemadmin","Synthetic123!","192.0.2.1");
        Check(pending.Actions==1,"unrelated IMEI/setup journals do not block independent Linux features");
        File.WriteAllText(Path.Combine(pendingPath,"component-cleanup-pending.json"),"synthetic");var blocked=new Fake();
        try{await new DeviceFeatureService(blocked,resources,pendingPath).InstallDiagnosticToolsAsync();throw new Exception("cleanup accepted");}catch(DeviceFeatureException){Check(blocked.Commands==0,"component cleanup still blocks mutation before transport");}
        var failure=new Fake{HelperError=true};try{await Service(failure,"helper-failure").InstallDiagnosticToolsAsync();throw new Exception("helper refusal accepted");}catch(DeviceFeatureException){Check(failure.Actions==1,"native package ABI refusal is preserved without retry");}
        var remotePending=new Fake{AccountPending=true};try{await Service(remotePending,"remote-pending").CreateSshAccountAsync("modemadmin","Synthetic123!","192.0.2.1");throw new Exception("remote pending accepted");}catch(DeviceFeatureException){Check(remotePending.Uploads==0&&remotePending.Actions==0,"account transaction pending still blocks before upload");}
        var protectedService=new Fake();try{await Service(protectedService,"protected").ChangeAccessServiceAsync("managementSSH","stop","192.0.2.1");throw new Exception("protected service accepted");}catch(DeviceFeatureException){Check(protectedService.Commands==0,"protected management endpoint remains read-only");}
    }
    sealed class Fake:IRemoteShell
    {
        public string Firmware="b28";
        public bool PlatformFailure,Drift,Account,AccountPending,AgentRunning=true,PasswordOnStdin,HelperError;
        public int Commands,StrictReads,MeasuredReads,Uploads,Actions;
        const string Cid="11111111111111111111111111111111",Boot="11111111-1111-1111-1111-111111111111";
        static string Hash(byte[] b)=>Convert.ToHexStringLower(SHA256.HashData(b));
        static RemoteResult Result(string s,int code=0)=>new(code,code==0?Encoding.UTF8.GetBytes(s):[],code==0?[]:Encoding.UTF8.GetBytes(s));
        string Identity()=> (Firmware=="b31"?DeviceFeatureService.FirmwareHash:Firmware=="absent"?"absent":new string('a',64))+"  /firmware/image/modem.b16\n"+(Firmware=="b31"?DeviceFeatureService.RouterHash:Firmware=="absent"?"absent":new string('b',64))+"  /usr/bin/diag-router\n"+Cid+"\n"+(Drift&&MeasuredReads>1?"22222222-2222-2222-2222-222222222222":Boot)+"\n";
        string Accounts()=>"SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING "+(AccountPending?"1":"0")+"\nSSH_USERS_RECOVERY "+(AccountPending?"unknown":"none")+"\n"+(Account?"SSH_ACCOUNT modemadmin 50000 /data/zte-imei-admin/homes/modemadmin 1\n":"")+"SSH_USERS_LISTENER "+(Account?"1":"0")+"\n";
        string Access()=>"ACCESS_SCHEMA 1\nACCESS_SERVICE stockWeb running readonly\nACCESS_SERVICE dashboard stopped control\nACCESS_SERVICE agent "+(AgentRunning?"running":"stopped")+" control\nACCESS_SERVICE managementSSH running protected\nACCESS_SERVICE userSSH stopped control\nACCESS_SERVICE adb unknown readonly\n";
        const string Diagnostics="ZTE_DIAG_TOOLS_V2\nactive=none\nprevious=unset\nrunning=0\nfree_kib=100000\nselected=none\nprevious_selected=unset\n";
        public Task<RemoteResult> RunAsync(string command,byte[]? input=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            Commands++;ct.ThrowIfCancellationRequested();
            RemoteResult result;
            if(command==AccessIdentity.Command){MeasuredReads++;result=Result(PlatformFailure?"PLATFORM":Identity(),PlatformFailure?71:0);}
            else if(command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router")){StrictReads++;result=Result(Identity());}
            else if(command.StartsWith("sh -s -- status")){if(input is null)throw new Exception("missing status source");result=Result(Access());}
            else if(command.Contains("SSH_USERS_SCHEMA"))result=Result(Accounts());
            else if(input is not null&&command.Contains("cat > '")){Uploads++;var p=Regex.Match(command,@"cat > '([^']+)'").Groups[1].Value;result=Result(Hash(input)+"  "+p);}
            else if(command.Contains("; sh ")&&command.Contains("/create-ssh-user.sh'")){Actions++;PasswordOnStdin=input is not null&&Encoding.UTF8.GetString(input)=="Synthetic123!\n"&&!command.Contains("Synthetic123!");Account=true;result=Result("");}
            else if(command.Contains("/delete-ssh-user.sh' 'delete'" )||command.Contains("/delete-ssh-user.sh' delete ")){Actions++;Account=false;result=Result("");}
            else if(command.Contains("/access-services.sh' action ")){Actions++;AgentRunning=false;result=Result(Access());}
            else if(command.Contains("; sh '")&&command.Contains("/manager.sh'")){if(!command.EndsWith("'inspect'"))Actions++;result=HelperError?Result("DIAG_ERROR UNSUPPORTED_PLATFORM",1):Result(Diagnostics);}
            else if(command.Contains("/tmp/zte-imei-app.lock")||command.Contains("mkdir -m 700 '/tmp/")||command.Contains("; rmdir '/tmp/"))result=Result("");
            else throw new Exception("Unexpected synthetic command");
            return Task.FromResult(result);
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("unexpected download");
    }
}
