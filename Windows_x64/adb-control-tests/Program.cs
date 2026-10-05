using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

internal sealed class FakeShell : IRemoteShell
{
    public int IdentityReads;
    public bool Changed, Fail;
    public string Reply = "ZTE_ADB_STATE_V1\nlinked=1\nready=1\nbound=1\ndaemon=1\n";
    public List<string> Calls = [];
    public Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); Calls.Add(command);
        if (stdin is not null) throw new Exception("Unexpected stdin");
        if (command == AccessIdentity.Command)
        {
            IdentityReads++;
            var boot = Changed && IdentityReads > 1 ? "11111111-1111-1111-1111-111111111111" : "00000000-0000-0000-0000-000000000001";
            return Task.FromResult(new RemoteResult(0, Encoding.UTF8.GetBytes("absent  /firmware/image/modem.b16\nabsent  /usr/bin/diag-router\n0123456789abcdef0123456789abcdef\n" + boot + "\n"), []));
        }
        if (command != AdbControlProtocol.Command) throw new Exception("Unexpected command");
        return Task.FromResult(new RemoteResult(Fail ? 71 : 0, Encoding.UTF8.GetBytes(Reply), Encoding.UTF8.GetBytes("PRIVATE-STDERR-CANARY")));
    }
    public Task UploadAsync(string path, byte[] bytes, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("No upload allowed");
    public Task<byte[]> DownloadAsync(string path, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("No download allowed");
}
internal static class Program
{
    public static async Task Main(string[] args)
    {
        int passed=0;
        void Check(bool yes,string name){if(!yes)throw new Exception(name);Console.WriteLine("PASS "+name);passed++;}
        AdbControlStatus Parse(string text)=>AdbControlProtocol.Parse(Encoding.UTF8.GetBytes(text));
        string Wire(string a="1",string b="1",string c="1",string d="1")=>$"ZTE_ADB_STATE_V1\nlinked={a}\nready={b}\nbound={c}\ndaemon={d}\n";
        Check(Parse(Wire()).Enabled==true && !Parse(Wire()).SupportsChange,"complete observations enable status only");
        Check(Parse(Wire("0","unknown","unknown","unknown")).Enabled==false,"confirmed composition without ADB is off");
        Check(Parse(Wire("1","0","1","0")).Enabled==false,"inactive FFS and no daemon is off");
        foreach(var text in new[]{Wire("1","unknown"),Wire("1","0","1","1"),Wire("1","1","unknown"),Wire("unknown"),Wire("1","1","1","0")})
            Check(Parse(text).Enabled is null,"partial or contradictory status is unknown");
        foreach(var text in new[]{Wire()+"private=x\n",Wire().Replace("ready=1","linked=1"),Wire("true"),Wire().TrimEnd(),"\0"+Wire(),new string('x',257)})
        {try{Parse(text);throw new Exception("accepted malformed");}catch(InvalidDataException){Check(true,"strict schema rejects malformed");}}
        foreach(var eol in new[]{"\r\n","\r\r\n"})Check(Parse(Wire().Replace("\n",eol)).Enabled==true,"canonical CR framing handled");
        var root=args.Single();Directory.CreateDirectory(root);
        var fake=new FakeShell();var feature=new DeviceFeatureService(fake,root,root);
        Check((await feature.GetAdbControlStatusAsync()).Enabled==true&&fake.IdentityReads==2,"unknown firmware allowed for read only with fresh binding");
        fake=new(){Changed=true};feature=new(fake,root,root);
        try{await feature.GetAdbControlStatusAsync();throw new Exception("identity drift accepted");}catch(DeviceFeatureException){Check(true,"changed boot refuses observation");}
        fake=new(){Fail=true};feature=new(fake,root,root);
        try{await feature.GetAdbControlStatusAsync();throw new Exception("failure accepted");}catch(DeviceFeatureException e){Check(!e.Message.Contains("CANARY"),"failed read no raw error export");}
        foreach(var enable in new[]{true,false})
        {fake=new();feature=new(fake,root,root);try{await feature.SetAdbEnabledAsync(enable);throw new Exception("write accepted");}catch(DeviceFeatureException){Check(fake.Calls.Count==0,"missing pinned component refuses before remote staging");}}
        var service=new WindowsModemService(root,root);
        void Field(string name,object? value)=>typeof(WindowsModemService).GetField(name,BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(service,value);
        fake=new();Field("_features",new DeviceFeatureService(fake,root,root));Field("_imei",new ImeiEngine(fake,root,root));
        // Inert object proves that no SshTransport method is invoked by this
        // fixture: all permitted I/O goes through FakeShell above.
        Field("_ssh",RuntimeHelpers.GetUninitializedObject(typeof(SshTransport)));
        var refresh=await service.RunAsync(new(ModemOperation.RefreshAdbState));
        Check(refresh.Success&&(await service.GetDeviceSnapshotAsync()).AdbEnabled==true,"actual service refresh updates nullable state");
        var bootstrap=await service.RunAsync(new(ModemOperation.EnableDiagnosticAdb,new Dictionary<string,string>{{"web_password","PRIVATE-BOOTSTRAP-CANARY"}}));
        Check(!bootstrap.Success&&bootstrap.Message.Contains("SSH уже подключён")&&!Directory.EnumerateFiles(root,"*pending*",SearchOption.AllDirectories).Any(),"legacy route with SSH refuses without Web/bootstrap or journal mutation");
        foreach(var input in new string?[]{null,"False","0"," true"})
        {var n=fake.Calls.Count;var result=await service.RunAsync(new(ModemOperation.SetAdbEnabled,input is null?null:new Dictionary<string,string>{{"enabled",input}}));Check(!result.Success&&fake.Calls.Count==n,"malformed desired state rejects before remote I/O");}
        fake.Fail=true;var fail=await service.RunAsync(new(ModemOperation.RefreshAdbState));
        Check(!fail.Success&&(await service.GetDeviceSnapshotAsync()).AdbEnabled is null,"failed refresh clears stale checked state");
        Check(!AdbControlProtocol.Command.Contains("usb_op")&&!AdbControlProtocol.Command.Contains("kill")&&!AdbControlProtocol.Command.Contains("/etc/init.d"),"status excludes unsafe USB and daemon controls");
        File.WriteAllText(Path.Combine(root,AdbToggleTransaction.PendingName),"synthetic-pending");
        var remoteCalls=fake.Calls.Count;
        var pendingImei=await service.RunAsync(new(ModemOperation.ReadImei));
        Check(!pendingImei.Success&&fake.Calls.Count==remoteCalls,"pending runtime toggle blocks ordinary operation before remote I/O");
        var require=typeof(WindowsModemService).GetMethod("RequireSsh",BindingFlags.Instance|BindingFlags.NonPublic)!;
        try{require.Invoke(service,[false]);throw new Exception("direct SSH manager gate accepted pending");}
        catch(TargetInvocationException e) when(e.InnerException is InvalidOperationException){Check(true,"direct eSIM/terminal SSH gate also refuses pending runtime toggle");}
        File.Delete(Path.Combine(root,AdbToggleTransaction.PendingName));
        await TransactionTests.Run(root, Check);
        await BootstrapTimeoutTests.Run(root, Check);
        Console.WriteLine($"{passed} assertions PASS; no modem access");
    }
}
