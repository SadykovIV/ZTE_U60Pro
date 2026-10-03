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
    public static async Task RunAsync(byte[] original,byte[] enabled,string testSuffix)
    {
        var resources=Path.GetFullPath("Windows_x64/Resources");
        var root=Path.Combine(Path.GetTempPath(),"zte-diagnostic-adb-tests-"+Guid.NewGuid()); Directory.CreateDirectory(root);
        int index=0;
        (OnboardingEngine Engine,string Storage,Wire Web) Setup(bool ready=true,WebIdentity? identity=null,bool skip=false)
        {
            var storage=Path.Combine(root,(index++).ToString());Directory.CreateDirectory(storage);
            var wire=new Wire(identity??B31,original) { Ready=ready };
            var adb=new AdbTransport((args,_,_)=>
            {
                if(args.SequenceEqual(new[]{"devices","-l"}))
                {
                    wire.InventoryCount++;
                    if(wire.InventoryFailure)throw new IOException("synthetic inventory failure");
                    return Task.FromResult(Reply(wire.Ready?"ZTE device usb:1-2\n":"List of devices attached\n"));
                }
                if(args.Count==4 && args[0]=="-s" && args[2]=="shell" && args[3].Contains("test \"$(id -u)\" = 0"))
                {
                    wire.ShellCount++;
                    var marker=Regex.Match(args[3],"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var boot=wire.ChangeBoot && wire.ShellCount>1?"20000000-0000-0000-0000-000000000002":Boot;
                    var proof=ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+new string('e',64)+"  /usr/bin/diag-router\n"+Cid+"\n"+boot+"\n"+JsonSerializer.Serialize(new {imei=wire.Identity.Imei,integrate_version=wire.Identity.Firmware,wa_inner_version=wire.Identity.Inner});
                    return Task.FromResult(Reply(proof+"\n"+marker+"0\n"));
                }
                throw new Exception("Diagnostic path attempted a non-identity ADB command: "+string.Join(' ',args));
            });
            return (new OnboardingEngine("192.168.0.1",storage,resources,adb,skip) {WebFactory=()=>new ModemWebClient("192.168.0.1",wire)},storage,wire);
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
            var unsupported=Setup(false,new(B31.Imei,"CN_ZTE_MU5250V1.0.0B27","BD_CNMU5250V1.0.0B27"));
            await Reject(()=>unsupported.Engine.EnableDiagnosticAdbAsync("pw", testSuffix),"Non-B31 new diagnostic activation requires firmware override");
            Check(unsupported.Web.Mutations==0 && unsupported.Web.Backups==0,"Firmware override gate precedes backup and USB mutation");
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
                await Reject(()=>noKey.Engine.EnableDiagnosticAdbAsync("pw",suffix),"Missing/wrong public suffix stops B31 activation");
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
    private sealed class Wire(WebIdentity identity,byte[] original):IWebTransport
    {
        public WebIdentity Identity=identity;
        public byte[] Backup=original;
        public bool Ready,ChangeBoot,InventoryFailure,FailEveryRequest,Advertise,LoseRebootAcknowledgement,CancelReboot;
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
                return Json(JsonSerializer.Serialize(new {sha256sum=VerifiedHash.Sha256(data![start..^trailer])}));
            }
            using var doc=JsonDocument.Parse(data!);var request=doc.RootElement[0];
            if(request.GetProperty("method").GetString()=="list")return Json(Advertise?"[{\"result\":{\"zwrt_bsp.usb\":{\"set\":{\"mode\":\"string\"}}}}]":"[{\"result\":{\"zwrt_bsp.usb\":{\"list\":{}}}}]");
            var p=request.GetProperty("params");var method=p[2].GetString();object reply=new{};
            switch(method)
            {
                case "web_login_info":reply=new {zte_web_sault="synthetic"};break;
                case "web_login":reply=new {result=0,ubus_rpc_session="11111111111111111111111111111111"};headers["Set-Cookie"]=["webtoken=synthetic-cookie; Path=/"];break;
                case "device_info":reply=new {imei=Identity.Imei,integrate_version=Identity.Firmware,wa_inner_version=Identity.Inner};break;
                case "device_backup_proc":Backups++;break;
                case "set":DebugRequests++;Ready=true;break;
                case "device_restore_proc":Restores++;Ready=true;break;
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
