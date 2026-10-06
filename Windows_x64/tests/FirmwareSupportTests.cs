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
using ZteImeiStudio.Windows.Research;

static class FirmwareSupportTests
{
    static int passed;
    static void Check(bool value,string name) {if(!value)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);passed++;}
    static readonly byte[] Helper=Encoding.UTF8.GetBytes("#!/bin/sh\n# "+new string('x',24000)+"\n");
    static async Task<int> Main(string[] args)
    { try { await Run(args);return 0; } catch(Exception error) { Console.Error.WriteLine(error);return 1; } }
    static async Task Run(string[] args)
    {
        var root=Path.GetFullPath(args[0]);Directory.CreateDirectory(root);
        var remote=new Fake();
        var result=await Capture("valid",remote);
        Check(result.Complete&&result.CapturedFiles==4,"required four files complete without optional originals");
        using(var zip=ZipFile.OpenRead(result.Path))
        {
            Check(zip.Entries.Any(e=>e.FullName=="research/report.json") && zip.Entries.All(e=>e.FullName is "manifest.json" or "README.txt" || e.FullName.StartsWith("files/") || e.FullName.StartsWith("activity/") || e.FullName.StartsWith("research/")),"fixed files and fresh research share one archive");
            CheckPayloads(zip);
            using var source=zip.GetEntry("files/zte_topsw_devui")!.Open();using var bytes=new MemoryStream();source.CopyTo(bytes);
            Check(bytes.ToArray().SequenceEqual(remote.Data["ui"]),"binary NUL, invalid UTF8, CR and LF preserved exactly");
            var text=Text(zip,"manifest.json");
            Check(!text.Contains(Fake.Boot)&&!text.Contains(Fake.Cid)&&!text.Contains("192.0.2.1")&&!text.Contains("pid"),"manifest exports no CID, boot, host or process identifiers");
            Check(text.Contains("discovery")&&text.Contains("401")&&Text(zip,"README.txt").Contains("401 means authentication"),"discovery and HTTP401 are observations, not failed installation claims");
            Check(!zip.Entries.Any(e=>e.FullName.Contains("startup")||e.FullName.Contains("config")),"no startup or configuration payload included");
        }
        Check(remote.Commands.All(c=>c.Length<4096)&&remote.Inputs.All(b=>b.SequenceEqual(Helper))&&remote.Uploads==0,"all helper invocations short stdin commands with no upload or remote staging");
        Check(remote.IdentityReads==2&&remote.Inspects==2,"one before/after quick identity and one before/after fixed inspection");
        foreach(var state in new[]{"missing","not_assessed","symlink","not_regular","unreadable","empty"})
        {
            var partial=await Capture(state,new Fake{State=state});
            Check(!partial.Complete&&partial.CapturedFiles==3,"required "+state+" publishes explicit incomplete evidence");
            using var zip=ZipFile.OpenRead(partial.Path);Check(!zip.Entries.Any(e=>e.FullName=="files/English.ini")&&Text(zip,"manifest.json").Contains("incomplete"),"unavailable "+state+" bytes never read or fabricated");
        }
        var withFonts=new Fake{IncludeFonts=true};var fontsResult=await Capture("optional-fonts",withFonts);
        using(var zip=ZipFile.OpenRead(fontsResult.Path))
        {
            Check(fontsResult.Complete&&fontsResult.CapturedFiles==7&&zip.Entries.Count(e=>e.FullName.StartsWith("fonts/"))==3,"three optional vendor font files are captured without becoming required");
            foreach(var font in FirmwareSupportCollector.Inputs.Where(i=>i.Id.StartsWith("font_")))
            {using var input=zip.GetEntry(font.ArchivePath)!.Open();using var bytes=new MemoryStream();input.CopyTo(bytes);Check(bytes.ToArray().SequenceEqual(withFonts.Data[font.Id]),"font bytes remain unchanged: "+font.Id);}
            CheckPayloads(zip);
        }
        var oversizedFont=await Capture("optional-font-over-limit",new Fake{IncludeFonts=true,Failure="oversize-font"});
        using(var zip=ZipFile.OpenRead(oversizedFont.Path))Check(oversizedFont.Complete&&oversizedFont.CapturedFiles==6&&!zip.Entries.Any(e=>e.FullName=="fonts/ZTEZhengYuan.ttf"),"an unavailable oversized optional font is omitted without claiming a required-file failure");
        var noIdentity=await Capture("no-cid-nonroot",new Fake{NoCid=true,NoAgent=true,Uid="1000",Architecture="armv7l"});
        Check(!noIdentity.Complete&&noIdentity.CapturedFiles==4,"unknown firmware, no CID, nonroot and nonARM64 still publish honest incomplete read-only observations");
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
            var resources=Path.GetFullPath(args.FirstOrDefault(x=>x.StartsWith("--resources-root="))?[17..]??"Windows_x64/Resources");
            var sourceHelper=FirmwareSupportCollector.LoadHelper(resources);
            Check(FirmwareSupportCollector.Sha(sourceHelper)==FirmwareSupportCollector.ExpectedHelperSha256,"actual bundled helper and single-file manifest match compiled pin");
            var combinedRoot=Path.Combine(root,"combined-fresh");
            var combinedFake=new Fake();var researchFake=new Survey(ResearchSpec.Load(Path.Combine(resources,"FirmwareResearch/probes.json")),combinedFake);
            var combinedService=new WindowsModemService(combinedRoot,resources,()=>researchFake){FirmwareSupportStream=combinedFake.Stream};
            BindService(combinedService,combinedFake);
            ((DiagnosticPrivacy)typeof(WindowsModemService).GetField("_diagnosticPrivacy",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(combinedService)!).Remember(["UNLABELED_KNOWN_SECRET_CANARY"]);
            Directory.CreateDirectory(Path.Combine(combinedRoot,"FirmwareResearch"));
            File.WriteAllText(Path.Combine(combinedRoot,"FirmwareResearch/latest.json"),"PRIVATE_STALE_RESEARCH_CANARY");
            var combinedPath=Path.Combine(root,"combined-fresh.zip");
            var combinedReply=await combinedService.RunAsync(new(ModemOperation.CollectFirmwareAdaptation,new Dictionary<string,string>{{"destination",combinedPath}}));
            using(var combinedZip=ZipFile.OpenRead(combinedPath))
                Check(combinedReply.Success && combinedZip.GetEntry("research/report.json") is not null && researchFake.Calls>0,"actual adaptation runs fresh full research and includes its payload instead of the stale cache");
            using(var combinedZip=ZipFile.OpenRead(combinedPath))
            {
                var report=Text(combinedZip,"research/report.json");
                Check(!report.Contains("PRIVATE_STALE_RESEARCH_CANARY")&&report.Contains("synthetic_fresh")&&researchFake.Calls>=researchFake.Spec.Probes.Length,"fresh current specification is executed rather than cached latest.json");
                CheckPayloads(combinedZip);
                Check(researchFake.FirstTransferCount==4&&researchFake.LastInspectCount==1&&combinedFake.Inspects==2,"full survey occurs after file transfer and before final inspection");
                Check(!report.Contains("UNLABELED_KNOWN_SECRET_CANARY")&&!report.Contains("PRIVATE_PASSWORD_CANARY")&&!report.Contains("PRIVATE_PEM_CANARY")&&!report.Contains("PRIVATE_LPA_CANARY")&&!report.Contains(Fake.Cid)&&!report.Contains(Fake.Boot)&&report.Contains(new string('e',64)),"fresh survey redacts credentials/identifiers and preserves benign binary SHA256");
                Check(Text(combinedZip,"manifest.json").Contains("\"identityVerified\": true"),"complete research records matching selected CID and boot proof");
            }
            foreach(var failure in new[]{"partial","probe-timeout","mixed-cid","mixed-boot","mid-boot","mixed-uid","mixed-os","mixed-arch","connection","trust","initial-timeout","selection","cancel"})
            {
                var scenarioRoot=Path.Combine(root,"combined-"+failure);var scenarioFake=new Fake();
                using var cancellation=new CancellationTokenSource();
                var survey=new Survey(researchFake.Spec,scenarioFake){Failure=failure,Cancel=failure=="cancel"?cancellation:null};
                var service=new WindowsModemService(scenarioRoot,resources,()=>survey){FirmwareSupportStream=scenarioFake.Stream};BindService(service,scenarioFake);
                if(failure=="selection")survey.OnCall=()=>typeof(WindowsModemService).GetField("_host",BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(service,"192.0.2.2");
                var path=Path.Combine(root,"combined-"+failure+".zip");
                var reply=await service.RunAsync(new(ModemOperation.CollectFirmwareAdaptation,new Dictionary<string,string>{{"destination",path}}),cancellation.Token);
                Check(!reply.Success && File.Exists(path)==(failure is "partial" or "probe-timeout"),"combined "+failure+" yields "+(failure is "partial" or "probe-timeout"?"an incomplete technical report":"no published ZIP"));
                if(failure is "partial" or "probe-timeout") {using var zip=ZipFile.OpenRead(path);using var report=JsonDocument.Parse(Text(zip,"research/report.json"));Check(report.RootElement.GetProperty("outcome").GetString()=="partial","partial research outcome remains explicit");CheckPayloads(zip);}
                Check(survey.AdbCalls==0&&scenarioFake.Uploads==0,"combined "+failure+" has no ADB fallback or uploads");
            }
            foreach(var partial in new[]{false,true})
            {
                var serviceRoot=Path.Combine(root,"service-"+partial);var fake=new Fake{NoCid=true,Uid="1000",Architecture="armv7l",State=partial?"unreadable":null};
                var service=new WindowsModemService(serviceRoot,resources,()=>new Survey(ResearchSpec.Load(Path.Combine(resources,"FirmwareResearch/probes.json")),fake)){FirmwareSupportStream=fake.Stream};
                void Set(string name,object value)=>typeof(WindowsModemService).GetField(name,BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(service,value);
                Set("_sshRead",fake);Set("_connectionProof",fake.Proof());Set("_host","192.0.2.1");Set("_snapshot",new DeviceSnapshot(true,"Synthetic selected SSH",ConnectionMode:"SSH"));
                File.WriteAllText(Path.Combine(serviceRoot,AdbToggleTransaction.PendingName),"unrelated pending marker");
                File.WriteAllText(Path.Combine(serviceRoot,"setup-pending.json"),"unrelated pending marker");
                var destination=Path.Combine(root,"service-"+partial+".zip");
                var request=new OperationRequest(ModemOperation.CollectFirmwareAdaptation,new Dictionary<string,string>{{"host","192.0.2.1"},{"port","2222"},{"destination",destination}});
                var reply=await service.RunAsync(request);
                Check(!reply.Success && reply.Values?["capture_outcome"]=="incomplete"&&File.Exists(destination),"actual service returns honest outcome without root/FW/agent or unrelated pending gates: "+partial);
                Check(fake.Uploads==0&&fake.Inputs.All(x=>x.SequenceEqual(sourceHelper)),"actual service uses only pinned stdin helper and zero uploads: "+partial);
                var calls=fake.Commands.Count;
                var changed=await service.RunAsync(request with {Parameters=new Dictionary<string,string>{{"host","192.0.2.2"},{"destination",Path.Combine(root,"wrong-host.zip")}}});
                Check(!changed.Success&&fake.Commands.Count==calls,"changed selected host refused before remote capture: "+partial);
                changed=await service.RunAsync(request with {Parameters=new Dictionary<string,string>{{"port","22"},{"destination",Path.Combine(root,"wrong-port.zip")}}});
                Check(!changed.Success&&fake.Commands.Count==calls,"changed selected port refused before remote capture: "+partial);
                using var zip=ZipFile.OpenRead(destination);
                Check(zip.Entries.Any(e=>e.FullName=="activity/operation-traces.jsonl")&&zip.Entries.Any(e=>e.FullName=="research/report.json")&&!zip.Entries.Any(e=>e.FullName.StartsWith("firmware-research/")),"actual service includes sanitized action trace plus fresh survey without cached survey: "+partial);
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

        async Task<FirmwareSupportResult> Capture(string name,Fake fake,CancellationToken ct=default)=>await FirmwareSupportCollector.CollectAsync(fake,fake.Proof(),fake.Stream,Helper,"192.0.2.1",Path.Combine(root,name+".zip"),Path.Combine(root,"work"),new Dictionary<string,byte[]>{{"current-session.jsonl","{\"message\":\"Safe synthetic action\"}\n"u8.ToArray()}},"1.24.10-test",ct,collectResearch:(proof,token)=>new FirmwareResearchEngine(TinySpec,new Survey(TinySpec,fake),new ResearchRedactor()).CollectAsync("SSH",proof.Cid is null?null:FirmwareResearchEngine.HashSavedCid(proof.Cid),null,token,boundBootHash:proof.BootId is null?null:FirmwareResearchEngine.HashSavedCid(proof.BootId),enforceTimeLimit:false));
    }
    static string Text(ZipArchive zip,string name){using var stream=zip.GetEntry(name)!.Open();using var reader=new StreamReader(stream);return reader.ReadToEnd();}
    static void BindService(WindowsModemService service,Fake fake)
    {
        foreach(var pair in new Dictionary<string,object>{{"_sshRead",fake},{"_connectionProof",fake.Proof()},{"_host","192.0.2.1"},{"_snapshot",new DeviceSnapshot(true,"Synthetic selected SSH",ConnectionMode:"SSH")}})
            typeof(WindowsModemService).GetField(pair.Key,BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(service,pair.Value);
    }
    static readonly ResearchText ProbeTitle=new("Проверка","Check");
    static readonly ResearchSpec TinySpec=new(1,1,[],[new("fingerprint",ProbeTitle,"identity","fingerprint",10,16384),new("identity",ProbeTitle,"identity","identity",10,16384),new("tools",ProbeTitle,"tools","tools",10,16384)],[]);
    static void CheckPayloads(ZipArchive zip)
    {
        using var manifest=JsonDocument.Parse(Text(zip,"manifest.json"));
        var payloads=manifest.RootElement.GetProperty("payloads").EnumerateArray().ToArray();
        Check(payloads.Length==zip.Entries.Count-1 && payloads.All(p=>{
            var entry=zip.GetEntry(p.GetProperty("path").GetString()!)!;using var input=entry.Open();
            return entry.Length==p.GetProperty("bytes").GetInt64()&&Convert.ToHexStringLower(SHA256.HashData(input))==p.GetProperty("sha256").GetString();}),"outer manifest covers every binary, fresh research and activity payload with exact bytes/SHA256");
        using var inner=JsonDocument.Parse(Text(zip,"research/manifest.json"));
        Check(inner.RootElement.GetProperty("files").EnumerateArray().All(p=>{
            var entry=zip.GetEntry("research/"+p.GetProperty("path").GetString())!;using var input=entry.Open();
            return entry.Length==p.GetProperty("bytes").GetInt64()&&Convert.ToHexStringLower(SHA256.HashData(input))==p.GetProperty("sha256").GetString();}),"nested research manifest retains exact sanitized payload hashes");
    }
    sealed class Survey(ResearchSpec spec,Fake target):IResearchTransportFactory,IResearchShell
    {
        public ResearchSpec Spec=>spec;public int Calls,AdbCalls,FirstTransferCount=-1,LastInspectCount;
        public string? Failure;public Action? OnCall;public CancellationTokenSource? Cancel;
        public string Channel=>"SSH";public bool SshConfigured=>true;
        public IResearchShell OpenSsh()=>this;
        public Task<ResearchCommandResult> ExecuteAsync(string command,int seconds,int maxBytes,CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();Calls++;if(FirstTransferCount<0)FirstTransferCount=target.Transfers;LastInspectCount=target.Inspects;
            OnCall?.Invoke();
            if(Failure=="trust")throw new SshTrustException("Synthetic rejected trust",new IOException());
            if(Failure=="connection")throw new IOException("Synthetic connection lost");
            if(Failure=="initial-timeout")return Task.FromResult(new ResearchCommandResult("timeout",null,"","",ConnectionEstablished:false));
            Cancel?.Cancel();ct.ThrowIfCancellationRequested();
            if(Failure=="partial"&&command==spec.Probes.Last().Command)return Task.FromResult(new ResearchCommandResult("failed",127,"","Missing synthetic optional tool"));
            if(Failure=="probe-timeout"&&command==spec.Probes.Last().Command)return Task.FromResult(new ResearchCommandResult("timeout",null,"partial technical data","",ConnectionEstablished:true));
            var value=command==spec.Probes.Single(p=>p.Id=="fingerprint").Command?
                "FR_FACT cid_sha256="+(target.NoCid?"not-assessed":FirmwareResearchEngine.HashSavedCid(Failure=="mixed-cid"?new string('c',32):Fake.Cid))+"\nFR_FACT boot_sha256="+FirmwareResearchEngine.HashSavedCid(Failure=="mixed-boot"||Failure=="mid-boot"&&Calls>4?"22222222-2222-2222-2222-222222222222":Fake.Boot)+"\n":
                command==spec.Probes.Single(p=>p.Id=="identity").Command?
                "FR_FACT uid="+(Failure=="mixed-uid"?"1001":target.Uid)+"\nFR_FACT operating_system="+(Failure=="mixed-os"?"OtherOS":"Linux")+"\nFR_FACT architecture="+(Failure=="mixed-arch"?"armv7l":target.Architecture)+"\n":
                "UNLABELED_KNOWN_SECRET_CANARY\nFR_FACT synthetic_fresh=1\nFR_FACT binary_sha256="+new string('e',64)+"\npassword=PRIVATE_PASSWORD_CANARY\nLPA:1$PRIVATE_LPA_CANARY\n-----BEGIN PRIVATE KEY-----\nPRIVATE_PEM_CANARY\n-----END PRIVATE KEY-----\n";
            return Task.FromResult(new ResearchCommandResult("success",0,value,""));
        }
        public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct){AdbCalls++;throw new Exception("No ADB allowed");}
        public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct){AdbCalls++;throw new Exception("No ADB allowed");}
        public IResearchShell OpenAdb(string serial){AdbCalls++;throw new Exception("No ADB allowed");}
    }
    sealed class Fake:IRemoteShell
    {
        public const string Boot="11111111-1111-1111-1111-111111111111",Cid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        public string? Failure,State;public bool NoCid,NoAgent,IncludeFonts;public string Uid="0",Architecture="aarch64";public int IdentityReads,Inspects,Transfers,Uploads;
        public CancellationTokenSource? Cancel;
        public List<string> Commands=[];public List<byte[]> Inputs=[];
        public Dictionary<string,byte[]> Data=FirmwareSupportCollector.Inputs.Where(x=>x.Required||x.Id.StartsWith("font_")).ToDictionary(x=>x.Id,x=>new byte[]{0,255,13,10,13,0,65,66,67,(byte)x.Id.Length});
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
                if(!input.Required&&!(IncludeFonts&&input.Id.StartsWith("font_"))||input.Id=="english"&&State is not null){lines.Add("FILE\t"+input.Id+"\t"+(input.Required?State:"missing")+"\t-\t-\t-\t-\t-");continue;}
                var size=(Failure=="oversize"&&input.Id=="init"||Failure=="oversize-font"&&input.Id=="font_zhengyuan")?input.Limit+1:Data[input.Id].LongLength;
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
