using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;
using ZteImeiStudio.Windows.Diagnostics;

static class FirmwareSupportTests
{
    static int passed;
    static void Check(bool value,string name) {if(!value)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);passed++;}
    static readonly byte[] Helper=Encoding.UTF8.GetBytes("#!/bin/sh\n# "+new string('x',24000)+"\n");
    static async Task Main(string[] args)
    {
        var root=Path.GetFullPath(args[0]);Directory.CreateDirectory(root);
        var remote=new Fake();
        var result=await Capture("valid",remote);
        Check(result.Complete&&result.CapturedFiles==4,"required four files complete without optional originals");
        using(var zip=ZipFile.OpenRead(result.Path))
        {
            Check(zip.Entries.Count==7,"only fixed binaries, metadata, README and cleaned activity exported");
            using var source=zip.GetEntry("files/zte_topsw_devui")!.Open();using var bytes=new MemoryStream();source.CopyTo(bytes);
            Check(bytes.ToArray().SequenceEqual(remote.Data["ui"]),"binary NUL, invalid UTF8, CR and LF preserved exactly");
            var text=Text(zip,"manifest.json");
            Check(!text.Contains(Fake.Boot)&&!text.Contains(Fake.Cid)&&!text.Contains("192.0.2.1")&&!text.Contains("pid"),"manifest exports no CID, boot, host or process identifiers");
            Check(text.Contains("discovery")&&text.Contains("401")&&Text(zip,"README.txt").Contains("401 means authentication"),"discovery and HTTP401 are observations, not failed installation claims");
            Check(!zip.Entries.Any(e=>e.FullName.Contains("research")||e.FullName.Contains("startup")||e.FullName.Contains("config")),"no cached research, startup or configuration payload included");
        }
        Check(remote.Commands.All(c=>c.Length<4096)&&remote.Inputs.All(b=>b.SequenceEqual(Helper))&&remote.Uploads==0,"all helper invocations short stdin commands with no upload or remote staging");
        Check(remote.IdentityReads==2&&remote.Inspects==2,"one before/after quick identity and one before/after fixed inspection");
        foreach(var state in new[]{"missing","not_assessed","symlink","not_regular","unreadable","empty"})
        {
            var partial=await Capture(state,new Fake{State=state});
            Check(!partial.Complete&&partial.CapturedFiles==3,"required "+state+" publishes explicit incomplete evidence");
            using var zip=ZipFile.OpenRead(partial.Path);Check(!zip.Entries.Any(e=>e.FullName=="files/English.ini")&&Text(zip,"manifest.json").Contains("incomplete"),"unavailable "+state+" bytes never read or fabricated");
        }
        var noIdentity=await Capture("no-cid-nonroot",new Fake{NoCid=true,NoAgent=true,Uid="1000",Architecture="armv7l"});
        Check(noIdentity.Complete,"unknown firmware, no CID, nonroot and nonARM64 do not block read-only capture");
        using(var zip=ZipFile.OpenRead(noIdentity.Path))Check(Text(zip,"manifest.json").Contains("partial")&&Text(zip,"manifest.json").Contains("\"identityStable\": false"),"missing CID retains honest partial binding without claiming full identity stability");
        Check((await Capture("runtime-change",new Fake{Failure="runtime-change"})).Complete,"runtime agent mode and HTTP state may vary while stable facts remain equal");
        var oversized=await Capture("oversize",new Fake{Failure="oversize"});
        using(var zip=ZipFile.OpenRead(oversized.Path))Check(!oversized.Complete&&oversized.CapturedFiles==3&&Text(zip,"manifest.json").Contains("over_limit"),"over-limit file is omitted with explicit incomplete metadata without exceeding transfer budget");
        foreach(var failure in new[]{"exit","receipt","hash","size","truncated","drift","boot","private-stderr","duplicate-fact","duplicate-file","unknown-fact","unknown-mode","missing-trailer","failed-inspect","fact-uid","fact-os","fact-architecture","fact-firmware","fact-inner","fact-openwrt_version","fact-target"})
        {
            var name="fail-"+failure;var fake=new Fake{Failure=failure};
            try {await Capture(name,fake);Check(false,"refuse "+failure);}
            catch(InvalidDataException error){Check(error.Message==FirmwareSupportCollector.Failed&&!File.Exists(Path.Combine(root,name+".zip")),"refuse "+failure+" with fixed error and no published ZIP");}
        }
        using(var cancelled=new CancellationTokenSource())
        {
            var fake=new Fake{Cancel=cancelled};
            try {await Capture("cancelled",fake,cancelled.Token);Check(false,"cancel capture");}
            catch(OperationCanceledException){Check(!File.Exists(Path.Combine(root,"cancelled.zip")),"cancellation has no partial ZIP and no replay");}
            Check(fake.Transfers==1,"cancellation never replays file transfer");
        }
        try
        {
            var fake=new Fake();
            await FirmwareSupportCollector.CollectAsync(fake,fake.Proof(),fake.Stream,Helper,"192.0.2.1",Path.Combine(root,"selection-drift.zip"),Path.Combine(root,"work"),new Dictionary<string,byte[]>(),"test",default,()=>throw new InvalidDataException("Changed selection"));
            Check(false,"selection change before publication refuses");
        }
        catch(InvalidDataException){Check(!File.Exists(Path.Combine(root,"selection-drift.zip")),"selection change during ZIP work refuses atomic publication");}
        var originalHash=FirmwareSupportCollector.Sha(File.ReadAllBytes(result.Path));
        try {await Capture("valid",new Fake());Check(false,"existing destination refused");}
        catch(InvalidDataException){Check(FirmwareSupportCollector.Sha(File.ReadAllBytes(result.Path))==originalHash,"existing destination is preserved");}
        Check(!Directory.EnumerateFiles(root,"*.partial",SearchOption.AllDirectories).Any()&&!Directory.EnumerateDirectories(root,"capture-*",SearchOption.AllDirectories).Any(),"private temporary payloads are cleaned after success, refusal and cancellation");
        var noResearch=Path.Combine(root,"no-old-research");Directory.CreateDirectory(Path.Combine(noResearch,"FirmwareResearch"));
        File.WriteAllText(Path.Combine(noResearch,"FirmwareResearch/latest.json"),"PRIVATE_OLD_RESEARCH");
        var activityZip=Path.Combine(root,"activity-only.zip");
        DiagnosticsExporter.Export(noResearch,activityZip,new("SSH",null,null,"1.24.10"),[new(DateTimeOffset.UtcNow,"info","Safe action")],new DiagnosticPrivacy(),includeResearch:false);
        using(var zip=ZipFile.OpenRead(activityZip))Check(!zip.Entries.Any(e=>e.FullName.StartsWith("firmware-research/"))&&!Text(zip,"manifest.json").Contains("malformed"),"activity reuse explicitly skips cached research parsing");
        if(args.Contains("--resources"))
        {
            var resources=Path.GetFullPath("Windows_x64/Resources");
            var sourceHelper=FirmwareSupportCollector.LoadHelper(resources);
            Check(FirmwareSupportCollector.Sha(sourceHelper)==FirmwareSupportCollector.ExpectedHelperSha256,"actual bundled helper and single-file manifest match compiled pin");
            foreach(var partial in new[]{false,true})
            {
                var serviceRoot=Path.Combine(root,"service-"+partial);var fake=new Fake{NoCid=true,Uid="1000",Architecture="armv7l",State=partial?"unreadable":null};
                var service=new WindowsModemService(serviceRoot,resources){FirmwareSupportStream=fake.Stream};
                void Set(string name,object value)=>typeof(WindowsModemService).GetField(name,BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(service,value);
                Set("_sshRead",fake);Set("_connectionProof",fake.Proof());Set("_host","192.0.2.1");Set("_snapshot",new DeviceSnapshot(true,"Synthetic selected SSH",ConnectionMode:"SSH"));
                File.WriteAllText(Path.Combine(serviceRoot,AdbToggleTransaction.PendingName),"unrelated pending marker");
                File.WriteAllText(Path.Combine(serviceRoot,"setup-pending.json"),"unrelated pending marker");
                var destination=Path.Combine(root,"service-"+partial+".zip");
                var request=new OperationRequest(ModemOperation.CollectFirmwareAdaptation,new Dictionary<string,string>{{"host","192.0.2.1"},{"port","2222"},{"destination",destination}});
                var reply=await service.RunAsync(request);
                Check(reply.Success==!partial && reply.Values?["capture_outcome"]==(partial?"incomplete":"complete")&&File.Exists(destination),"actual service returns honest outcome without root/FW/agent or unrelated pending gates: "+partial);
                Check(fake.Uploads==0&&fake.Inputs.All(x=>x.SequenceEqual(sourceHelper)),"actual service uses only pinned stdin helper and zero uploads: "+partial);
                var calls=fake.Commands.Count;
                var changed=await service.RunAsync(request with {Parameters=new Dictionary<string,string>{{"host","192.0.2.2"},{"destination",Path.Combine(root,"wrong-host.zip")}}});
                Check(!changed.Success&&fake.Commands.Count==calls,"changed selected host refused before remote capture: "+partial);
                changed=await service.RunAsync(request with {Parameters=new Dictionary<string,string>{{"port","22"},{"destination",Path.Combine(root,"wrong-port.zip")}}});
                Check(!changed.Success&&fake.Commands.Count==calls,"changed selected port refused before remote capture: "+partial);
                using var zip=ZipFile.OpenRead(destination);
                Check(zip.Entries.Any(e=>e.FullName=="activity/operation-traces.jsonl")&&!zip.Entries.Any(e=>e.FullName.StartsWith("firmware-research/")),"actual service includes sanitized action trace without cached survey: "+partial);
            }
            var tampered=Path.Combine(root,"tampered-resources/FirmwareSupport");Directory.CreateDirectory(tampered);
            File.WriteAllBytes(Path.Combine(tampered,"collect.sh"),sourceHelper.Concat(new byte[]{10}).ToArray());
            File.Copy(Path.Combine(resources,"FirmwareSupport/SHA256.json"),Path.Combine(tampered,"SHA256.json"));
            var invalidService=new WindowsModemService(Path.Combine(root,"invalid-service"),Path.GetDirectoryName(tampered)!){FirmwareSupportStream=new Fake().Stream};
            var invalidFake=new Fake();
            foreach(var pair in new Dictionary<string,object>{{"_sshRead",invalidFake},{"_connectionProof",invalidFake.Proof()},{"_snapshot",new DeviceSnapshot(true,"Synthetic SSH",ConnectionMode:"SSH")}})
                typeof(WindowsModemService).GetField(pair.Key,BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(invalidService,pair.Value);
            var invalid=await invalidService.RunAsync(new(ModemOperation.CollectFirmwareAdaptation,new Dictionary<string,string>{{"destination",Path.Combine(root,"tampered.zip")}}));
            Check(!invalid.Success&&invalidFake.Commands.Count==0&&!File.Exists(Path.Combine(root,"tampered.zip")),"tampered helper fails before SSH and cannot publish ZIP");
        }
        Console.WriteLine($"Firmware support: {passed} PASS");

        async Task<FirmwareSupportResult> Capture(string name,Fake fake,CancellationToken ct=default)=>await FirmwareSupportCollector.CollectAsync(fake,fake.Proof(),fake.Stream,Helper,"192.0.2.1",Path.Combine(root,name+".zip"),Path.Combine(root,"work"),new Dictionary<string,byte[]>{{"current-session.jsonl","{\"message\":\"Safe synthetic action\"}\n"u8.ToArray()}},"1.24.10-test",ct);
    }
    static string Text(ZipArchive zip,string name){using var stream=zip.GetEntry(name)!.Open();using var reader=new StreamReader(stream);return reader.ReadToEnd();}
    sealed class Fake:IRemoteShell
    {
        public const string Boot="11111111-1111-1111-1111-111111111111",Cid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        public string? Failure,State;public bool NoCid,NoAgent;public string Uid="0",Architecture="aarch64";public int IdentityReads,Inspects,Transfers,Uploads;
        public CancellationTokenSource? Cancel;
        public List<string> Commands=[];public List<byte[]> Inputs=[];
        public Dictionary<string,byte[]> Data=FirmwareSupportCollector.Inputs.Where(x=>x.Required).ToDictionary(x=>x.Id,x=>new byte[]{0,255,13,10,13,0,65,66,67,(byte)x.Id.Length});
        public SshReadProof Proof()=>new(Uid,"Linux",Architecture,NoCid?null:Cid,Boot,null,null);
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            ct.ThrowIfCancellationRequested();Commands.Add(command);
            if(command==SshReadProof.SessionCommand)
            {
                IdentityReads++;
                var boot=Failure=="boot"&&IdentityReads==2?"22222222-2222-2222-2222-222222222222":Boot;
                return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes("ZTE_SSH_READ_V1\n"+Uid+"\nLinux\n"+Architecture+"\n"+(NoCid?"?":Cid)+"\n"+boot+"\n?\n?\n"),[]));
            }
            if(command!="sh -s -- inspect '192.0.2.1'"||stdin is null)throw new Exception("Unexpected command");
            Inputs.Add(stdin);Inspects++;
            var facts=new Dictionary<string,string>{["uid"]=Uid,["os"]="Linux",["architecture"]=Architecture,["firmware"]="FLY_CN_MU5250V1.0.0B13",["inner"]="BD_FLYMODEMMU5250V1.0.0B28",["openwrt_version"]="23.05.4",["target"]="qualcomm/arm64",["agent_present"]="1",["agent_sha256"]=new string('b',64),["agent_running_count"]="1",["agent_mode"]=Failure=="unknown-mode"?"PRIVATE_MODE_CANARY":"discovery",["agent_mapped_matches_disk"]="yes",["http_health_status"]="401",["http_capabilities_status"]="401",["http_dashboard_status"]="403",["ui_mounts"]="0"};
            if(Inspects==2&&Failure=="runtime-change"){facts["agent_mode"]="normal";facts["http_health_status"]="200";}
            if(NoAgent){facts["agent_present"]="0";facts["agent_sha256"]="not_assessed";facts["agent_running_count"]="0";facts["agent_mode"]="not_assessed";facts["agent_mapped_matches_disk"]="not_assessed";foreach(var key in new[]{"http_health_status","http_capabilities_status","http_dashboard_status"})facts[key]="000";}
            if(Inspects==2&&Failure?.StartsWith("fact-",StringComparison.Ordinal)==true)facts[Failure[5..]]=Failure=="fact-uid"?"1001":"changed";
            if(Failure=="unknown-fact")facts["password"]="PRIVATE_PASSWORD_CANARY";
            var lines=new List<string>{"FIRMWARE_SUPPORT_V1"};
            lines.AddRange(facts.Select(x=>"FACT\t"+x.Key+"\t"+Convert.ToBase64String(Encoding.UTF8.GetBytes(x.Value))));
            foreach(var input in FirmwareSupportCollector.Inputs)
            {
                if(!input.Required||input.Id=="english"&&State is not null){lines.Add("FILE\t"+input.Id+"\t"+(input.Required?State:"missing")+"\t-\t-\t-\t-\t-");continue;}
                var size=Failure=="oversize"&&input.Id=="init"?input.Limit+1:Data[input.Id].LongLength;
                var hash=Failure=="drift"&&Inspects==2&&input.Id=="ui"?new string('c',64):FirmwareSupportCollector.Sha(Data[input.Id]);
                lines.Add("FILE\t"+input.Id+"\tpresent\t"+size+"\t"+hash+"\t0\t775\t1");
            }
            if(Failure=="duplicate-fact")lines.Add(lines[1]);
            if(Failure=="duplicate-file")lines.Add(lines[^1]);
            if(Failure!="missing-trailer")lines.Add("FIRMWARE_SUPPORT_END");
            return Task.FromResult(new RemoteResult(Failure=="failed-inspect"?1:0,Encoding.UTF8.GetBytes(string.Join('\n',lines)+"\n"),[]));
        }
        public async Task<RemoteFileResult> Stream(string command,string path,long maximum,TimeSpan timeout,CancellationToken ct,byte[] input)
        {
            ct.ThrowIfCancellationRequested();Commands.Add(command);Inputs.Add(input);Transfers++;
            var fields=command.Split(' ');if(fields.Length!=7||fields[3]!="file")throw new Exception("Unexpected file command");
            var data=Data[fields[4]];var hash=FirmwareSupportCollector.Sha(data);
            await File.WriteAllBytesAsync(path,Failure=="truncated"?data[..^1]:data,ct);
            Cancel?.Cancel();
            var receipt="BACKUP_RESULT sha256="+hash+" bytes="+data.Length+"\n";
            if(Failure=="receipt")receipt+="EXTRA\n";
            if(Failure=="private-stderr")receipt="PRIVATE_PASSWORD_CANARY";
            return new(Failure=="exit"?1:0,Failure=="size"?data.Length+1:data.Length,Failure=="hash"?new string('d',64):hash,Encoding.UTF8.GetBytes(receipt));
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default){Uploads++;throw new Exception("Unexpected upload");}
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
}
