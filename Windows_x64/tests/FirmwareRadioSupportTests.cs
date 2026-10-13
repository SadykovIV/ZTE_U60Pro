using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Diagnostics;
static class RadioTests {
 const string Qmi="""{"schema":1,"observations":{"slot_status":{"status":"observed","slots":[{"physical_index":2,"is_euicc":true,"eid_length":16,"eid":"SECRET"}]}},"identifiers_exported":false,"radio_reset":false,"slot_switch":false,"apdu_performed":false,"profile_mutation":false,"provisioning_proven":false,"password":"PRIVATE"}""";
 static void Check(bool v,string label){if(!v)throw new Exception(label);Console.WriteLine("PASS "+label);}
 static async Task Main(string[] args) {
  var s=FirmwareRadioSupport.Output(new(0,Encoding.UTF8.GetBytes(Qmi),[]),"");Check(!s.Contains("SECRET")&&!s.Contains("PRIVATE")&&s.Contains("is_euicc"),"QMI schema projects only numeric and boolean card observations");
  var c="SUPPORT_NV_V1\nSUPPORT_NV_RESULT outcome=20 released=1 deinit=1 writes=0\nPAIR_REQUEST label=read_index0 send=0 length=138 status=0 diag_error=-1 verified=1\nSUPPORT_NV_SECRET password=PRIVATE\nEFS_DATA_HEX data=PRIVATE\n";
  s=FirmwareRadioSupport.Output(new(20,Encoding.UTF8.GetBytes(c),Encoding.UTF8.GetBytes("PRIVATE")),"SUPPORT_NV_V1");Check(!s.Contains("PRIVATE")&&s.Contains("PAIR_REQUEST")&&s.Contains("exit_code=20"),"DIAG schemas preserve known codes without raw bytes");
  Check(FirmwareRadioSupport.Output(new(0,Encoding.UTF8.GetBytes(Qmi.Replace("\"radio_reset\":false","\"radio_reset\":true")),[]),"").Contains("invalid_output"),"mutating report refused");
  var wire=new Wire();var result=await FirmwareRadioSupport.CollectAsync(args[0],wire,true,default);Check(result.Count==3&&Encoding.UTF8.GetString(result["zte-support-nv.txt"]).Contains("not_assessed"),"probe timeout retained as unavailable without losing next reports");
  Check(!result.Values.Any(b=>Encoding.UTF8.GetString(b).Contains("PRIVATE")),"private transport errors omitted");Check(wire.Commands.Count(x=>x.StartsWith("test "))==3&&wire.Commands[^1].StartsWith("rm -f "),"all reads run once and stage cleaned");
  var skip=new Wire();await FirmwareRadioSupport.CollectAsync(args[0],skip,false,default);Check(skip.Commands.Count==0,"nonroot tools skipped");
  using var ct=new CancellationTokenSource();ct.Cancel();var cancel=new Wire();try{await FirmwareRadioSupport.CollectAsync(args[0],cancel,true,ct.Token);throw new Exception("not cancelled");}catch(OperationCanceledException){Check(cancel.Commands[^1].StartsWith("rm -f "),"cancellation cleans its own stage");}
 }
 class Wire:IRemoteShell {
  public List<string> Commands=[];
  public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default){Commands.Add(command);
   if(command.StartsWith("cat > ")){var path=command.Split('\'')[1];return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(FirmwareSupportCollector.Sha(stdin!)+"  "+path+"\n"),[]));}
   if(command.StartsWith("test ")){if(command.EndsWith("--inspect-nv550"))throw new OperationCanceledException("PRIVATE_TIMEOUT");var text=command.EndsWith("--inspect-current-card")?Qmi:"SUPPORT_CONFIG_V1\nSUPPORT_CONFIG_RESULT outcome=0 file_closed=1 released=1 deinit=1 writes=0\n";return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(text),[]));}
   return Task.FromResult(new RemoteResult(0,[],[]));
  }
 }
}
namespace ZteImeiStudio.Transport {public sealed record RemoteResult(int ExitCode,byte[] Stdout,byte[] Stderr){public bool Success=>ExitCode==0;} public interface IRemoteShell {Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default);}}
namespace ZteImeiStudio.Windows.Core {internal static class VerifiedHash {public static string ShellQuote(string s)=>"'"+s.Replace("'","'\\''")+"'";}}
namespace ZteImeiStudio.Windows.Diagnostics {internal static class FirmwareSupportCollector {public const string Failed="Capture failed";public static string Sha(byte[] b)=>Convert.ToHexStringLower(SHA256.HashData(b));}}
