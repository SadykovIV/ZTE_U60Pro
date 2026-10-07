using System.Text.Json;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Research;
using ZteImeiStudio.Windows.Core;

internal static class UniversalDiscoveryTests
{
    internal static async Task RunAsync()
    {
        var passed=0; var failed=0;
        void Check(bool value,string name) { Console.WriteLine((value?"PASS ":"FAIL ")+name); if(value)passed++;else failed++; }
        ResearchCommandResult Ok(string s)=>new("success",0,s,"");
        var text=new ResearchText("Проверка","Check");
        var spec=new ResearchSpec(1,1,[],[
            new("fingerprint",text,"identity","fingerprint",1,1024),
            new("identity",text,"identity","identity",1,1024),
            new("tools",text,"tools","tools",1,1024)],
            [new("access",text,[],[new("identity","root","1",text)],text)]);
        async Task<ResearchReport> Run(Func<string,ResearchCommandResult> reply)=>await new FirmwareResearchEngine(spec,new Factory(new Shell(reply)),new ResearchRedactor()).CollectAsync("ADB",null,null,CancellationToken.None);
        foreach(var missing in new[]{"all","cid","boot","tool"})
        {
            var report=await Run(c=>c=="fingerprint"?missing=="tool"?new("failed",127,"",""):Ok("FR_FACT cid_sha256="+(missing is "all" or "cid"?"missing":new string('a',64))+"\nFR_FACT boot_sha256="+(missing is "all" or "boot"?"missing":new string('b',64))+"\n"):c=="identity"?Ok("FR_FACT root=1\nFR_FACT architecture=aarch64\n"):Ok("FR_FACT tool=1\n"));
            Check(report.Probes.Single(p=>p.Id=="tools").Status=="success","missing "+missing+" still collects independent tool evidence");
            var json=JsonSerializer.SerializeToElement(report,ResearchSpec.Json);
            Check(json.TryGetProperty("bindingStrength",out var binding)&&binding.GetString()==(missing is "cid" or "boot"?"partial":"transport-only"),"missing "+missing+" binding is explicit");
            Check(report.Features.All(f=>f.State!="prerequisites_met"),"missing "+missing+" cannot grant capability");
        }
        var reads=0;var changed=await Run(c=>c=="fingerprint"?Ok("FR_FACT boot_sha256="+new string(++reads>=3?'c':'b',64)+"\n"):Ok("FR_FACT root=1\n"));
        Check(changed.Outcome=="device_changed"&&changed.Probes.Single(p=>p.Id=="tools").Status=="skipped","partial known boot change stops collection");
        var method=typeof(ImeiEngine).GetMethod("MeasuredIdentityAsync");
        Check(method is not null,"access-only measured identity API exists");
        var cid=new string('a',32); var boot="11111111-1111-1111-1111-111111111111";
        var measuredText=new string('c',64)+"  /firmware/image/modem.b16\n"+new string('d',64)+"  /usr/bin/diag-router\n"+cid+"\n"+boot+"\n";
        var measuredShell=new Remote(0,measuredText);
        var imei=new ImeiEngine(measuredShell,"unused","unused");
        var measured=await imei.MeasuredIdentityAsync();
        Check(measured.Cid==cid && measured.RouterHash==new string('d',64),"unknown firmware/router measured for access");
        Check(measuredShell.Commands.Count==1 && !measuredShell.Commands[0].Contains("ubus") && !Regex.IsMatch(measuredShell.Commands[0],@"(?m)^\s*/usr/bin/diag-router(?:\s|$)"),"measurement does not invoke vendor API or DIAG");
        async Task Reject(Func<Task> work,string name) { try { await work();Check(false,name); }catch(InvalidDataException) {Check(true,name);} }
        await Reject(()=>imei.IdentityAsync(),"actual IMEI identity still rejects unknown firmware/router");
        foreach(var cause in new[]{"non-root","non-Linux","non-ARM64","missing-tool"})
            await Reject(()=>new ImeiEngine(new Remote(1,measuredText),"unused","unused").MeasuredIdentityAsync(),cause+" failed remote identity cannot authorize access");
        foreach(var broken in new[]{measuredText.Replace(cid,"missing"),measuredText.Replace(boot,"missing"),measuredText.Replace(new string('c',64),"unknown"),measuredText+"garbage\n"})
            await Reject(()=>new ImeiEngine(new Remote(0,broken),"unused","unused").MeasuredIdentityAsync(),"malformed/incomplete measured identity rejected");
        await Reject(()=>new ImeiEngine(new Remote(0,measuredText.Replace(boot,"AAAAAAAA-1111-1111-1111-111111111111")),"unused","unused").MeasuredIdentityAsync(),"noncanonical uppercase boot UUID rejected before installer");
        var absent=AccessIdentity.Parse(Encoding.UTF8.GetBytes(measuredText.Replace(new string('c',64),"absent").Replace(new string('d',64),"absent")));
        Check(absent.FirmwareHash=="absent"&&absent.RouterHash=="absent","proven absent files represented separately from unknown");
        var calls=new List<string>();
        var multiple=false;var remoteCode=0;
        var adb=new AdbTransport((arguments,_,_)=>
        {
            calls.Add(string.Join(" ",arguments));
            if(arguments[0]=="devices")return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(multiple?"one device usb:1\ntwo device usb:2\n":"one device usb:1\n"),[]));
            if(arguments[0]=="-d")return Task.FromResult(new RemoteResult(0,"one\n"u8.ToArray(),[]));
            var marker=Regex.Match(arguments[^1],@"__ZTE_RESULT_[A-F0-9]{32}__").Value;
            return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(measuredText+"\n"+marker+remoteCode+"\n"),[]));
        });
        var onboarding=new OnboardingEngine("192.168.0.1","unused","unused",adb);
        var matched=await onboarding.FindMatchingAdbAsync(null,CancellationToken.None);
        Check(matched?.Identity==measured && calls.Any(x=>x=="-d get-serialno") && calls.All(x=>!x.Contains("ubus")&&!x.Contains("push")),"single USB bootstrap measures root identity without Web/NV/uploads");
        multiple=true;var count=calls.Count;
        try {await onboarding.FindMatchingAdbAsync(null,CancellationToken.None);Check(false,"multiple USB refused");}catch(InvalidOperationException) {Check(calls.Skip(count).All(x=>!x.Contains("shell")),"multiple USB refused before shell/install");}
        multiple=false;remoteCode=1;
        Check(await onboarding.FindMatchingAdbAsync(null,CancellationToken.None) is null,"non-root USB cannot select installer target");
        Check(onboarding.InstallerProfile(null,measured)=="linux-arm64-access","missing Web selects generic profile only");
        Check(onboarding.InstallerProfile(null,new DeviceIdentity(cid,ImeiEngine.FirmwareHash,boot,ImeiEngine.RouterHash))=="linux-arm64-access","known B31 hashes without Web still select generic access and skip Web backup branch");
        var bootstrapStorage=Path.Combine(Path.GetTempPath(),"zte-access-bootstrap-"+Guid.NewGuid());
        Directory.CreateDirectory(bootstrapStorage);
        try
        {
            var noWeb=new NoWeb();var preflightCalls=0;var unexpectedCommands=0;
            var bootstrapAdb=new AdbTransport((arguments,stream,_,_)=>
            {
                if(arguments[0]=="devices")return Task.FromResult(new RemoteResult(0,"one device usb:1\n"u8.ToArray(),[]));
                if(arguments[0]=="-d")return Task.FromResult(new RemoteResult(0,"one\n"u8.ToArray(),[]));
                if(arguments[0]!="-s" || arguments[2]!="shell") {unexpectedCommands++;throw new Exception("Unexpected bootstrap write");}
                var command=stream?.OriginalCommand??arguments[^1];var marker=stream?.Result??Regex.Match(command,@"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                if(command.Contains("'--preflight'")) {preflightCalls++;return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes((stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n")+"\n"+marker+"71\n"),[]));}
                if(!command.Contains("observed_hash()")) {unexpectedCommands++;throw new Exception("Unexpected bootstrap command");}
                return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(measuredText.Replace(new string('c',64),ImeiEngine.FirmwareHash).Replace(new string('d',64),ImeiEngine.RouterHash)+"\n"+marker+"0\n"),[]));
            },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
            var bootstrap=new OnboardingEngine("192.168.0.1",bootstrapStorage,Path.GetFullPath("Windows_x64/Resources"),bootstrapAdb) {WebFactory=()=>new ModemWebClient("192.168.0.1",noWeb)};
            try {await bootstrap.PrepareAsync("","synthetic-agent-password","");Check(false,"no-Web bootstrap fixture stops at preflight");}
            catch(IOException) {Check(preflightCalls==1 && noWeb.Calls==0 && unexpectedCommands==0,"known B31 root USB reaches generic preflight with no Web calls or uploads");}
        }
        finally {Directory.Delete(bootstrapStorage,true);}
        Check(OnboardingEngine.InstallerPolicy(measured,"linux-arm64-access").SequenceEqual(new[]{cid,"linux-arm64-access",measured.FirmwareHash,measured.RouterHash,boot}),"generic policy includes observed hashes and boot last");
        Check(OnboardingEngine.InstallerPolicy(measured,"b31").Length==4,"legacy CLI arity remains unchanged");
        var startup=Encoding.UTF8.GetString(OnboardingEngine.AgentStartup("synthetic-secret","linux-arm64-access"));
        Check(!startup.Contains("ZTE_AGENT_MODE") && !Encoding.UTF8.GetString(OnboardingEngine.AgentStartup("synthetic-secret")).Contains("ZTE_AGENT_MODE"),"neither generic nor B31 startup configures a global agent mode");
        Check(!Encoding.UTF8.GetString(OnboardingEngine.AgentStartup("synthetic-secret")).Contains("ZTE_AGENT_BIND"),"B31 keeps automatic LAN binding");
        Check(Encoding.UTF8.GetString(OnboardingEngine.AgentStartup("synthetic-secret","linux-arm64-access","192.168.5.1")).Contains("export ZTE_AGENT_BIND='192.168.5.1:9090'"),"generic agent binds explicitly selected modem IPv4");
        try {OnboardingEngine.AgentStartup("synthetic-secret","linux-arm64-access","1.2.3.4;bad");Check(false,"invalid agent bind refused");}catch(ArgumentException) {Check(true,"invalid agent bind refused");}
        var observations=FirmwareResearchEngine.Observe(spec with {Observations=[new("root",text,"identity","root"),new("absent",text,"identity","absent"),new("bad",text,"tools","tool")]},[
            new("identity",text,"identity","","success",0,"","",0,DateTimeOffset.UtcNow,false,new Dictionary<string,string>{{"root","0"},{"absent","missing"}}),
            new("tools",text,"tools","","failed",1,"","",0,DateTimeOffset.UtcNow,false,new Dictionary<string,string>{{"tool","1"}})]);
        Check(observations[0].Status=="known"&&observations[0].Value=="0"&&observations[1].Status=="absent"&&observations[2].Status=="not-assessed"&&observations[2].Value is null,"observations preserve zero and distinguish absent from failed");
        Console.WriteLine($"{passed} passed; {failed} failed; no device used.");
        if(failed>0)throw new Exception("Universal discovery regression failures");
    }
    private sealed class Remote(int code,string output):IRemoteShell
    {
        public List<string> Commands {get;}=[];
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default) {Commands.Add(command);return Task.FromResult(new RemoteResult(code,Encoding.UTF8.GetBytes(output),[]));}
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
    private sealed class NoWeb:IWebTransport
    {
        public int Calls;
        public Task<WebReply> RequestAsync(string path,byte[]? data=null,string? contentType=null,string? cookie=null,CancellationToken ct=default)
        {Calls++;throw new Exception("Root USB access unexpectedly contacted Web");}
    }
    private sealed class Shell(Func<string,ResearchCommandResult> reply):IResearchShell
    { public string Channel=>"ADB";public Task<ResearchCommandResult> ExecuteAsync(string command,int seconds,int maxBytes,CancellationToken ct)=>Task.FromResult(reply(command)); }
    private sealed class Factory(Shell shell):IResearchTransportFactory
    { public bool SshConfigured=>false;public IResearchShell OpenSsh()=>throw new Exception("No SSH fallback");public IResearchShell OpenAdb(string serial)=>shell;public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct)=>Task.FromResult(new ResearchCommandResult("success",0,"synthetic-usb device usb:1\n",""));public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct)=>Task.FromResult(new ResearchCommandResult("success",0,"synthetic-usb\n","")); }
}
