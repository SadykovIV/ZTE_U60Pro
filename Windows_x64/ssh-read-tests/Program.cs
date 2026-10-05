using System.Text;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Core;

var passed=0;
void Need(bool ok,string text){if(!ok)throw new Exception(text);}
void Keys(string storage)
{
    Directory.CreateDirectory(Path.Combine(storage,"SSH"));
    File.WriteAllText(Path.Combine(storage,"SSH","id_ed25519"),"synthetic-unusable-private-key");
    var blob=new byte[51]; blob[3]=11; "ssh-ed25519"u8.CopyTo(blob.AsSpan(4)); blob[18]=32;
    File.WriteAllText(Path.Combine(storage,"SSH","known_hosts"),"[192.0.2.1]:2222 ssh-ed25519 "+Convert.ToBase64String(blob)+"\n");
}
foreach(var uid in new[]{"0","1000"})
{
    var storage=Path.Combine(Path.GetTempPath(),"zte-ssh-read-"+Guid.NewGuid());
    try
    {
        Keys(storage);
        var remote=new Remote(uid);
        var service=new WindowsModemService(storage,Path.GetFullPath("Windows_x64/Resources")){SshFactory=()=>remote};
        var connected=await service.RunAsync(new(ModemOperation.Connect,new Dictionary<string,string>{{"host","192.0.2.1"}}));
        Need(connected.Success,connected.Message);
        var state=await service.GetDeviceSnapshotAsync();
        Need(state.IsConnected&&state.Serial is null&&state.Imei is null&&state.ConnectionMode=="SSH","Read fabricated device identity");
        Need(state.Details?.GetValueOrDefault("Ядро")=="fixture-kernel","Missing ubus prevented generic system facts");
        var refresh=await service.RunAsync(new(ModemOperation.RefreshDevice));Need(refresh.Success,refresh.Message);
        var reuse=await service.RunAsync(new(ModemOperation.PrepareSsh));Need(reuse.Success,reuse.Message);
        Need(remote.Writes==0&&remote.Commands.All(x=>x==SshReadProof.Command||x=="ubus call system board"||x=="uname -s; uname -r; uname -m"),"Ordinary SSH requested agent/ADB/NV/lock");
        Console.WriteLine("PASS service Connect/Info/Prepare without CID agent curl password uid="+uid);passed++;
        var calls=remote.Commands.Count;
        var changed=await service.RunAsync(new(ModemOperation.PrepareSsh,new Dictionary<string,string>{{"host","192.0.2.2"}}));
        Need(!changed.Success&&remote.Commands.Count==calls,"Preparation reused SSH for a different selected endpoint");
        File.WriteAllText(Path.Combine(storage,"setup-pending.json"),"{}");
        var pending=await service.RunAsync(new(ModemOperation.PrepareSsh));
        Need(!pending.Success&&remote.Commands.Count==calls,"Working SSH bypassed pending setup");
        Console.WriteLine("PASS selected endpoint and pending setup are preserved uid="+uid);passed++;
    }
    finally{Directory.Delete(storage,true);}
}
{
    var storage=Path.Combine(Path.GetTempPath(),"zte-ssh-drift-"+Guid.NewGuid());
    try
    {
        Keys(storage);
        var service=new WindowsModemService(storage,Path.GetFullPath("Windows_x64/Resources")){SshFactory=()=>new Remote("0"){ChangeBoot=true}};
        var result=await service.RunAsync(new(ModemOperation.Connect,new Dictionary<string,string>{{"host","192.0.2.1"}}));
        Need(!result.Success&&!(await service.GetDeviceSnapshotAsync()).IsConnected,"Drift left connected permissions");
        Console.WriteLine("PASS changed boot refuses Connect without stale permission");passed++;
    }
    finally{Directory.Delete(storage,true);}
}
{
    var storage=Path.Combine(Path.GetTempPath(),"zte-ssh-retry-"+Guid.NewGuid());
    try
    {
        Keys(storage);
        var remote=new Remote("0"){FailNext=true};
        var service=new WindowsModemService(storage,Path.GetFullPath("Windows_x64/Resources")){SshFactory=()=>remote};
        var request=new OperationRequest(ModemOperation.Connect,new Dictionary<string,string>{{"host","192.0.2.1"}});
        Need(!(await service.RunAsync(request)).Success&&!(await service.GetDeviceSnapshotAsync()).IsConnected,"Failed connection left stale readiness");
        Need((await service.RunAsync(request)).Success&&(await service.GetDeviceSnapshotAsync()).IsConnected,"Same service could not retry SSH without restart");
        remote.FailNext=true;
        Need(!(await service.RunAsync(new(ModemOperation.RefreshDevice))).Success,"Synthetic read failure was hidden");
        Need((await service.RunAsync(new(ModemOperation.RefreshDevice))).Success,"Read failure retained service busy lock");
        File.WriteAllText(Path.Combine(storage,"setup-pending.json"),"{}");
        Need((await service.GetDeviceSnapshotAsync()).PreparationPending,"New pending setup did not appear without restart");
        File.Delete(Path.Combine(storage,"setup-pending.json"));
        Need(!(await service.GetDeviceSnapshotAsync()).PreparationPending&&remote.Writes==0,"Resolved pending setup remained latched or retry wrote to device");
        Console.WriteLine("PASS same service retries failed SSH and reads live pending state without writes");passed++;
    }
    finally{Directory.Delete(storage,true);}
}
Console.WriteLine($"RESULT {passed} service groups passed; no device");
sealed class Remote(string uid):IRemoteShell
{
    public List<string> Commands=[];public int Writes;public bool ChangeBoot,FailNext;private int reads;
    public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
    {
        if(FailNext){FailNext=false;throw new IOException("Synthetic SSH unavailable");}
        Commands.Add(command);if(stdin is not null||timeout is null||timeout>TimeSpan.FromSeconds(30))throw new Exception("Unexpected input/unbounded call");
        if(command==SshReadProof.Command){reads++;var boot=ChangeBoot&&reads>1?"22222222-2222-2222-2222-222222222222":"11111111-1111-1111-1111-111111111111";return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes("ZTE_SSH_READ_V1\n"+uid+"\nLinux\narmv7l\n?\n"+boot+"\n?\nabsent\n"),[]));}
        if(command=="ubus call system board")return Task.FromResult(new RemoteResult(127,[],[]));
        if(command=="uname -s; uname -r; uname -m")return Task.FromResult(new RemoteResult(0,"Linux\nfixture-kernel\narmv7l\n"u8.ToArray(),[]));
        throw new Exception("Unexpected operation");
    }
    public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default){Writes++;throw new Exception("Unexpected upload");}
    public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
}
