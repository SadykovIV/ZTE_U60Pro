using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Esim;
using ZteImeiStudio.Transport;

// Source-linked production orchestration; fake SSH never connects or reads device data.
int checks=0;
void Check(bool value,string name){if(!value)throw new Exception(name);checks++;}
var directory=Path.Combine(Path.GetTempPath(),"zte-esim-service-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(Path.Combine(directory,"Esim"));
var payload="synthetic-agent"u8.ToArray();
File.WriteAllBytes(Path.Combine(directory,"Esim/zte-agent-esim"),payload);
var pin=Convert.ToHexStringLower(SHA256.HashData(payload));
File.WriteAllText(Path.Combine(directory,"Esim/SHA256.json"),JsonSerializer.Serialize(new Dictionary<string,string>{{"zte-agent-esim",pin}}));
const string ordinary="{\"type\":\"result\",\"ok\":true,\"changed\":false,\"notifications_pending\":false,\"card\":{\"kind\":\"ordinary_sim\",\"management\":\"unavailable\",\"reason\":\"isdr_not_found\",\"cleanup_confirmed\":true}}\n";
var empty=new EsimSnapshot(true,new string('9',32),[]);
string Euicc(EsimSnapshot snapshot,bool changed=false)=>JsonSerializer.Serialize(new{type="result",ok=true,snapshot,changed,notifications_pending=false})+"\n";
async Task Reject(WindowsModemService service,EsimRequest request,string name,string? code=null){try{await service.RunEsimAsync(request,null);throw new Exception("accepted "+name);}catch(EsimException e){Check(code is null||e.Code==code,name);}}
try{
 foreach(var boot in new[]{"unavailable","01234567-89ab-cdef-0123-456789abcdef"}){
  var shell=new SshTransport(ordinary){Boot=boot};var service=new WindowsModemService(directory,shell);
  var result=await service.RunEsimAsync(new(){Operation="list"},null);
  Check(result.Ok&&result.Card?.Kind=="ordinary_sim"&&result.Snapshot is null,"ordinary list without CA/CID/firmware");
  Check(shell.PrivateCalls==1&&shell.StageCalls==1&&shell.CleanupCalls==1&&shell.BootReads==2,"one RPC with continuity and cleanup");
  Check(shell.Commands.All(x=>!x.Contains("mmc")&&!x.Contains("diag-router")&&!x.Contains("modem.b16")&&!x.Contains("zte-imei-app.lock")),"no unrelated identity/global-lock commands");
  Check(service.Logs.All(x=>!x.Contains(boot)&&!x.Contains("999999")),"journal excludes identifiers");
 }
 var goodShell=new SshTransport(Euicc(empty));var good=new WindowsModemService(directory,goodShell);
 var observed=await good.RunEsimAsync(new(){Operation="list"},null); Check(observed.Snapshot?.Eid==empty.Eid&&observed.Snapshot.Profiles.Count==0,"eUICC list without certificate bundle");
 var changed=new SshTransport(ordinary){AfterBoot="11111111-1111-1111-1111-111111111111"};await Reject(new(directory,changed),new(){Operation="list"},"changed boot refuses accepted result","identity_changed");Check(changed.CleanupCalls==1,"changed boot still cleans stage");
 var changedTarget=new SshTransport(ordinary);var changing=new WindowsModemService(directory,changedTarget);changedTarget.AfterRpc=()=>changing.ChangeTarget();await Reject(changing,new(){Operation="list"},"changed selected target refused","identity_changed");
 var badExit=new SshTransport(ordinary){Exit=1};await Reject(new(directory,badExit),new(){Operation="list"},"nonzero agent exit refused","agent_exit_failed");Check(badExit.CleanupCalls==1,"failed process still cleans temporary stage");
 var badCleanup=new SshTransport(ordinary){CleanupExit=1};await Reject(new(directory,badCleanup),new(){Operation="list"},"cleanup failure refuses ordinary proof","temporary_cleanup_failed");
 var forbiddenHttp=new SshTransport("{\"type\":\"http\",\"id\":1,\"payload\":{}}\n");await Reject(new(directory,forbiddenHttp),new(){Operation="list"},"list never initializes HTTP or reads CA");
 var wrongCard=new SshTransport(Euicc(empty with{Eid=new string('8',32)},true));await Reject(new(directory,wrongCard),new(){Operation="download",ExpectedSnapshot=empty,ActivationCode="LPA:1$example.com$test"},"mutation still requires same EID");
 var notEuicc=new SshTransport(ordinary);await Reject(new(directory,notEuicc),new(){Operation="download",ExpectedSnapshot=empty,ActivationCode="LPA:1$example.com$test"},"ordinary cannot satisfy mutation");
 var invalid=new SshTransport(ordinary);await Reject(new(directory,invalid),new(){Operation="download",ActivationCode="LPA:1$example.com$test"},"mutation still requires expected inventory");Check(invalid.StageCalls==0&&invalid.PrivateCalls==0,"invalid request never stages or starts backend");
 File.WriteAllBytes(Path.Combine(directory,"Esim/zte-agent-esim"),"tampered"u8.ToArray());var tampered=new SshTransport(ordinary);await Reject(new(directory,tampered),new(){Operation="list"},"pinned payload verification remains mandatory");Check(tampered.StageCalls==0&&tampered.PrivateCalls==0,"tampered payload never uploaded");
 Console.WriteLine(JsonSerializer.Serialize(new{ok=true,checks,noDevice=true,noNetwork=true}));
}finally{Directory.Delete(directory,true);}

namespace ZteImeiStudio.Windows{
 public sealed partial class WindowsModemService{
  private readonly SemaphoreSlim _operation=new(1,1);private readonly string _resources;private SshTransport? _ssh;
  private readonly Privacy _diagnosticPrivacy=new();private Snapshot _snapshot=new(true,"SSH");
  private string _host="192.0.2.1",_keyPath="synthetic",_knownHostsPath="synthetic";private int _port=2222;
  public List<string> Logs=[];private void Log(string level,string message)=>Logs.Add(message);
  public WindowsModemService(string resources,SshTransport shell){_resources=resources;_ssh=shell;}
  public void ChangeTarget()=>_host="192.0.2.2";
  private sealed record Snapshot(bool IsConnected,string ConnectionMode);
  private sealed class Privacy{public void Remember(IEnumerable<string?> values){}}
 }
}
namespace ZteImeiStudio.Windows.Core{
 // The real payload hash is independently pinned in resource fixtures; here the
 // synthetic payload lets the production service exercise its manifest check.
 public static class AgentPackage{public static void VerifyPayload(byte[] value){if(!value.SequenceEqual("synthetic-agent"u8.ToArray()))throw new EsimException();}}
}
namespace ZteImeiStudio.Transport{
 public sealed record RemoteResult(int ExitCode,byte[] Stdout,byte[] Stderr){public bool Success=>ExitCode==0;}
 public sealed class SshTransport(string frames){
  public List<string> Commands=[];public int PrivateCalls,StageCalls,CleanupCalls,BootReads,Exit,CleanupExit;public string Boot="unavailable";public string? AfterBoot;public Action? AfterRpc;
  public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default){
   Commands.Add(command);
   if(command==EsimReadBinding.Command){BootReads++;return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes((BootReads>1?AfterBoot??Boot:Boot)+"\n"),[]));}
   if(stdin is not null){StageCalls++;return Task.FromResult(new RemoteResult(0,[],[]));}
   CleanupCalls++;return Task.FromResult(new RemoteResult(CleanupExit,[],[]));
  }
  public async Task<(T Value,int ExitCode)> RunPrivateAsync<T>(string command,Func<Stream,Stream,CancellationToken,Task<T>> exchange,CancellationToken ct){PrivateCalls++;using var output=new MemoryStream(Encoding.UTF8.GetBytes(frames));using var input=new MemoryStream();var value=await exchange(output,input,ct);AfterRpc?.Invoke();return(value,Exit);}
 }
}
