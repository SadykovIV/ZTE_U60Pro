using System.IO.Compression;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Research;

var passed=0;
void Check(bool condition,string name) { if(!condition)throw new Exception(name);Console.WriteLine("PASS "+name);passed++; }
var bundled=Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"../../../../Resources/FirmwareResearch/probes.json"));
var productionSpec=ResearchSpec.Load(bundled);Check(productionSpec.Probes.Length==46 && productionSpec.Observations?.Length==45 && productionSpec.Features.Length==19 && productionSpec.Revision==8 && productionSpec.Sha256==ResearchSpec.ExpectedSpecificationSha256,"production probe contract matches pinned digest");
var genericAccess=productionSpec.Features.Single(f=>f.Id=="generic-access");
Check(genericAccess.Profiles.Length==0 && genericAccess.Requirements.All(r=>r.Fact!="tool_ubus" && r.Probe!="ubus-inventory" && r.Probe!="firmware-hashes"),"generic access observation has no firmware or vendor API dependency");
Check(genericAccess.Requirements.Any(r=>r.Probe=="identity" && r.Fact=="root" && r.Expected=="1") && genericAccess.Requirements.Any(r=>r.Fact=="architecture" && r.Expected=="aarch64"),"generic access retains root and ARM64 prerequisites");
Check(productionSpec.Features.Single(f=>f.Id=="agent").Profiles.Length>0,"full agent updater remains independently firmware-scoped");
var tampered=Path.Combine(Path.GetTempPath(),"tampered-research-"+Guid.NewGuid().ToString("N")+".json");
try {File.WriteAllText(tampered,File.ReadAllText(bundled)+" ");try {ResearchSpec.Load(tampered);throw new Exception("tampered spec accepted");}catch(InvalidDataException) {Check(true,"modified probe commands rejected before execution");}}finally {File.Delete(tampered);}
var fingerprint=new string('a',64);var boot=new string('b',64);
ResearchCommandResult Ok(string value)=>new("success",0,value,"");
var text=new ResearchText("Проверка","Check");
var spec=new ResearchSpec(1,1,[new("b31","firmware","router","aarch64")],
 [new("fingerprint",text,"identity","fingerprint",10,16384),new("identity",text,"identity","identity",10,16384),new("firmware-hashes",text,"identity","hashes",10,16384),new("tools",text,"apps","tools",10,16384)],
 [new("imei",text,["b31"],[new("identity","root","1",text),new("tools","tool","1",text)],text),new("read",text,[],[new("identity","root","1",text)],text)]);
ResearchCommandResult Baseline(string command)=>command switch { "fingerprint"=>Ok($"FR_FACT cid_sha256={fingerprint}\nFR_FACT boot_sha256={boot}\n"),"identity"=>Ok("FR_FACT architecture=aarch64\nFR_FACT root=1\n"),"hashes"=>Ok("FR_FACT firmware_sha256=firmware\nFR_FACT router_sha256=router\n"),"tools"=>Ok("FR_FACT tool=1\n"),_=>Ok("0") };
async Task<ResearchReport> Run(FakeFactory factory,string mode="ADB",CancellationToken ct=default)=>await new FirmwareResearchEngine(spec,factory,new ResearchRedactor()).CollectAsync(mode,null,null,ct);
var factory=new FakeFactory(new FakeShell("ADB",Baseline));var report=await Run(factory);
Check(report.Profile=="b31" && report.Features.All(x=>x.State=="prerequisites_met"),"matched profile and conjunctive prerequisites");
Check(FirmwareResearchEngine.Evaluate(spec,report.Probes,"b02-experimental","complete")[0].State=="blocked","known unsupported firmware is blocked, not unknown");
var sentinelResults=report.Probes.Select(p=>p.Id=="tools"?p with {Facts=new Dictionary<string,string> { ["tool"]="not-assessed" }}:p).ToArray();
Check(FirmwareResearchEngine.Evaluate(spec,sentinelResults,"b31","complete")[0].State=="unknown","not-assessed sentinel is unknown");
var platformSpec=spec with {Features=[new("platform",text,[],[new("tools","absent","1",text,["macos"])],text)]};
Check(FirmwareResearchEngine.Evaluate(platformSpec,report.Probes,"b31","complete")[0].State=="prerequisites_met","macOS-only requirement does not block Windows");
Check(factory.Shell.Commands.Count==10,"fingerprints checked before and after each probe");
factory=new(new FakeShell("ADB",command=>command=="hashes"?Ok("FR_FACT firmware_sha256=unknown\nFR_FACT router_sha256=router\n"):Baseline(command)));
report=await Run(factory);Check(report.Profile is null && report.Features[0].State=="unknown" && report.Probes.Any(p=>p.Id=="tools"&&p.Status=="success"),"unknown firmware still collected; never marked compatible");
factory=new(new FakeShell("ADB",command=>command=="identity"?Ok("FR_FACT architecture=aarch64\nFR_FACT root=0\n"):Baseline(command)));
report=await Run(factory);Check(report.Features.All(x=>x.State=="blocked"),"non-root evidence blocks root prerequisites but permits read-only research");
factory=new(new FakeShell("ADB",command=>command=="tools"?new("failed",127,"","tool: not found"):Baseline(command)));
report=await Run(factory);Check(report.Features[0].State=="unknown" && report.Probes.Single(p=>p.Id=="tools").ExitCode==127,"missing command preserved as failure, not compatibility");
factory=new(new FakeShell("ADB",command=>command=="tools"?new("timeout",null,"partial","timeout"):Baseline(command)));
report=await Run(factory);Check(report.Probes.Single(p=>p.Id=="tools").Status=="timeout" && report.Features[0].State=="unknown","timeout and partial output kept");
factory=new(new FakeShell("ADB",Baseline)) {List="one device usb:1\ntwo device usb:2\n"};report=await Run(factory);
Check(factory.Opened==0 && report.Probes.Any(p=>p.Stderr.Contains("Multiple USB")),"multiple USB devices never select first");
factory=new(new FakeShell("ADB",Baseline)) {UsbSerial="different-usb"};report=await Run(factory);
Check(factory.Opened==0 && report.Probes.Any(p=>p.Stderr.Contains("not confirmed as the single USB")),"single serial requires adb USB selector proof");
var fingerprints=0;factory=new(new FakeShell("ADB",command=>command=="fingerprint" && ++fingerprints>2?Ok("FR_FACT cid_sha256="+new string('c',64)+"\n"):Baseline(command)));report=await Run(factory);
Check(report.Outcome=="device_changed" && report.Probes.Single(p=>p.Id=="tools").Status=="skipped" && report.Features.All(p=>p.State!="prerequisites_met"),"identity change stops collection and removes positive conclusions");
factory=new(new FakeShell("ADB",command=>command=="fingerprint"?new("failed",127,"","sha256sum missing"):Baseline(command)));report=await Run(factory);
Check(report.Outcome=="partial" && report.Probes.Single(p=>p.Id=="tools").Status=="success" && report.BindingStrength=="transport-only" && report.Features.All(x=>x.State!="prerequisites_met"),"missing fingerprint tool permits observations without authorization");
factory=new(new FakeShell("ADB",Baseline)) {SshConfigured=true,SshError=new SshTrustException("host key mismatch",new SocketException())};report=await Run(factory,"Автоматически");
Check(factory.ListCalls==0 && report.Probes.Any(p=>p.Stderr.Contains("host key mismatch")),"host-key mismatch stops before ADB fallback");
factory=new(new FakeShell("ADB",Baseline)) {SshConfigured=true,SshError=new InvalidDataException("invalid pinned key")};report=await Run(factory,"Автоматически");
Check(factory.ListCalls==0,"invalid pin does not fall back");
factory=new(new FakeShell("ADB",Baseline)) {SshConfigured=true,SshError=new SocketException((int)SocketError.ConnectionRefused)};report=await Run(factory,"Автоматически");
Check(factory.ListCalls==1 && report.Channel=="ADB","automatic fallback only for unavailable SSH");
factory=new(new FakeShell("ADB",Baseline)) {SshConfigured=true,SshError=new SocketException((int)SocketError.ConnectionRefused)};report=await Run(factory,"SSH");
Check(factory.ListCalls==0,"manual SSH never falls back");
factory=new(new FakeShell("ADB",Baseline)) {SshConfigured=true,SshResponse=new("timeout",null,"id output","command timeout",ConnectionEstablished:true)};report=await Run(factory,"Автоматически");
Check(factory.ListCalls==0,"SSH command timeout after connection never falls back");
factory=new(new FakeShell("ADB",Baseline)) {SshConfigured=true,SshError=new Renci.SshNet.Common.SshAuthenticationException("permission denied")};report=await Run(factory,"Автоматически");
Check(factory.ListCalls==0 && report.Probes.Any(p=>p.Stderr.Contains("permission denied")),"SSH authentication error preserved without fallback");
var cid="0123456789abcdef0123456789abcdef";var expectedCid=Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(cid+"\n")));
Check(FirmwareResearchEngine.HashSavedCid("  "+cid+"\n")==expectedCid,"saved CID uses sysfs newline hash");
factory=new(new FakeShell("ADB",Baseline));report=await new FirmwareResearchEngine(spec,factory,new ResearchRedactor()).CollectAsync("ADB",expectedCid,null,CancellationToken.None);
Check(report.Outcome=="device_changed" && report.Probes.Single(p=>p.Id=="tools").Status=="skipped","single USB is checked against saved identity");
factory=new(new FakeShell("ADB",Baseline)) {List="one device usb:1\ntwo device usb:2\n",CandidateShells=new Dictionary<string,IResearchShell> { ["one"]=new FakeShell("ADB",command=>command=="fingerprint"?Ok($"FR_FACT cid_sha256={expectedCid}\nFR_FACT boot_sha256={boot}\n"):Baseline(command)), ["two"]=new FakeShell("ADB",Baseline) }};
report=await new FirmwareResearchEngine(spec,factory,new ResearchRedactor()).CollectAsync("ADB",expectedCid,null,CancellationToken.None);
Check(report.Features.All(x=>x.State=="prerequisites_met") && report.Probes.Count(p=>p.Id.StartsWith("adb-candidate-"))==2,"multiple USB selected only by saved CID and candidates recorded");
using(var cancel=new CancellationTokenSource()) { factory=new(new FakeShell("ADB",command=> { if(command=="identity")cancel.Cancel();return Baseline(command); }));report=await Run(factory,ct:cancel.Token);Check(report.Outcome=="cancelled"&&report.Probes.Any(p=>p.Status=="skipped"),"cancel produces exportable partial snapshot"); }
var secret="my-private-password";var raw="{\"password\":\"my-private-password\",\"psk\":\"wifi pass\",\"token\":\"access-token\"}\nimei=123456789012345 imsi=1234567890123456\nSSID=SecretNetwork\nkey='secret key' cookie=abc\n-----BEGIN PRIVATE KEY-----\nVerySecret\n-----END PRIVATE KEY-----\nfe80::1234 1.2.3.4 aa:bb:cc:dd:ee:ff\nvless://secret-uuid@host.example:443#private\none device usb:1\n0123456789abcdef0123456789abcdef\nFR_FACT cid_sha256="+fingerprint;
var cleaned=new ResearchRedactor([secret]).Clean(raw);
Check(!new ResearchRedactor().Clean("{\"password\":\"unterminated secret with spaces").Contains("secret with spaces"),"truncated quoted secrets remain redacted");
Check(!new[]{secret,"wifi pass","access-token","123456789012345","SecretNetwork","secret key","VerySecret","1.2.3.4","aa:bb:cc:dd:ee:ff","secret-uuid","one device","0123456789abcdef0123456789abcdef"}.Any(cleaned.Contains) && cleaned.Contains(fingerprint),"redaction removes JSON/shell secrets, identities, VPN URLs and addresses but retains SHA256");
factory=new(new FakeShell("ADB",Baseline));report=await Run(factory);
var folder=Path.Combine(Path.GetTempPath(),"firmware-research-tests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);
try
{
 var json=Path.Combine(folder,"latest.json");ResearchReportFiles.Save(report,json);var loaded=ResearchReportFiles.Load(json)!;var zipPath=Path.Combine(folder,"report.zip");ResearchReportFiles.Export(loaded,zipPath);
 using var zip=ZipFile.OpenRead(zipPath);Check(zip.Entries.Any(e=>e.FullName=="REPORT_RU.md") && zip.Entries.Any(e=>e.FullName=="REPORT_EN.md") && zip.Entries.All(e=>!e.FullName.Contains("..")),"snapshot reload and bilingual ZIP structure");
 using var stream=zip.GetEntry("manifest.json")!.Open();using var manifest=JsonDocument.Parse(stream);
 foreach(var entry in manifest.RootElement.GetProperty("files").EnumerateArray()) { var file=zip.GetEntry(entry.GetProperty("path").GetString()!)!;using var data=file.Open();Check(Convert.ToHexStringLower(SHA256.HashData(data))==entry.GetProperty("sha256").GetString(),"ZIP checksum "+file.FullName); }
 File.WriteAllText(Path.Combine(folder,"unrelated-passwords.txt"),"not-in-zip");Check(!zip.Entries.Any(e=>e.Name=="unrelated-passwords.txt"),"ZIP never enumerates local storage");
 var oversized=Path.Combine(folder,"oversized");using(var big=File.Create(oversized))big.SetLength(8193);try {ResearchReportFiles.ReadBoundedFile(oversized,8192);throw new Exception("oversize accepted");}catch(InvalidDataException){Check(true,"local input is capped before allocation");}
 if(!OperatingSystem.IsWindows())
 {
   var link=Path.Combine(folder,"linked-report.json");File.CreateSymbolicLink(link,json);
   try {ResearchReportFiles.Load(link);throw new Exception("link accepted");}catch(InvalidDataException){Check(true,"report symlink rejected");}
   var adb=Path.Combine(folder,"fake-adb");File.WriteAllText(adb,"#!/bin/sh\n[ \"$1\" = '-s' ] || exit 9\neval \"$4\"\n");File.SetUnixFileMode(adb,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
   var failedAdb=Path.Combine(folder,"failed-adb");File.WriteAllText(failedAdb,"#!/bin/sh\necho 'device offline' >&2\nexit 1\n");File.SetUnixFileMode(failedAdb,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
   var noTransport=await new ResearchAdbShell(failedAdb,"usb123").ExecuteAsync("id",3,1024,CancellationToken.None);
   Check(noTransport.LocalExitCode==1 && noTransport.ExitCode is null && noTransport.Status=="failed" && noTransport.Stderr.Contains("device offline"),"local ADB failure has no invented remote exit status");
   var localAdb=new ResearchAdbShell(adb,"usb123");
   var failed=await localAdb.ExecuteAsync("printf partial; printf diagnostic >&2; exit 7",3,1024,CancellationToken.None);
   Check(failed.LocalExitCode==0 && failed.ExitCode==7 && failed.Stdout=="partial" && failed.Stderr=="diagnostic","ADB preserves local exit zero versus remote exit seven and stderr");
   var timed=await localAdb.ExecuteAsync("printf early; sleep 10",1,1024,CancellationToken.None);Check(timed.Status=="timeout" && timed.Stdout=="early","ADB timeout preserves bounded partial output");
   var inherited=await localAdb.ExecuteAsync("sleep 20 & fr_test_child=$!; printf '%s\\n' \"$fr_test_child\"",1,1024,CancellationToken.None);
   var childText=inherited.Stdout.Split('\n')[0].Trim();
   if(int.TryParse(childText,out var childPid)) { try { using var child=System.Diagnostics.Process.GetProcessById(childPid);child.Kill();await child.WaitForExitAsync(); }catch(ArgumentException) { } }
   Check(inherited.Status=="timeout" && inherited.Stderr.Contains("Incomplete capture"),"inherited child pipe after parent exit is timeout, never success");
   var truncated=await localAdb.ExecuteAsync("awk 'BEGIN{for(i=0;i<10000;i++)printf \"x\"}'",3,1024,CancellationToken.None);Check(truncated.Status=="truncated" && truncated.Stdout.Length==1024 && truncated.ExitCode==0,"ADB truncation retains remote result marker from tail");
 }

}
finally { Directory.Delete(folder,true); }
var capture=new ResearchCapture(4096);var captured=await capture.ReadAsync(new MemoryStream(new byte[65536]),CancellationToken.None);Check(capture.Truncated && captured.Text.Length==4096 && captured.Tail.Length==512,"capture retains bounded prefix and tail while draining");
Check(FirmwareResearchEngine.ParseAdb("emulator-5554 device\n192.168.1.1:5555 device\nusb123 device transport_id:1\nadb-test._adb-tls-connect._tcp device\nauth unauthorized\n").SequenceEqual(["usb123"]),"Windows USB descriptors accepted, TCP/emulator/unauthorized excluded");
Console.WriteLine($"{passed} research checks passed; no physical modem used.");

sealed class FakeShell(string channel,Func<string,ResearchCommandResult> execute):IResearchShell
{
 public string Channel=>channel;public List<string> Commands {get;}=[];
 public Task<ResearchCommandResult> ExecuteAsync(string command,int seconds,int maxBytes,CancellationToken ct) {ct.ThrowIfCancellationRequested();Commands.Add(command);return Task.FromResult(execute(command));}
}
sealed class FakeFactory(FakeShell shell):IResearchTransportFactory
{
 public bool SshConfigured {get;set;} public Exception? SshError {get;set;} public ResearchCommandResult? SshResponse {get;set;} public Dictionary<string,IResearchShell>? CandidateShells {get;set;}public int ListCalls,Opened;public string List="usb123 device transport_id:1\n";public string UsbSerial="usb123";public FakeShell Shell=>shell;
 public IResearchShell OpenSsh()=>SshError is not null?throw SshError:SshResponse is null?shell:new FakeShell("SSH",_=>SshResponse);
 public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct) {ListCalls++;return Task.FromResult(new ResearchCommandResult("success",0,List,""));}
 public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct)=>Task.FromResult(new ResearchCommandResult("success",0,UsbSerial,""));
 public IResearchShell OpenAdb(string serial) {Opened++;return CandidateShells?.GetValueOrDefault(serial)??shell;}
}
