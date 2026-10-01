using System.Text;
using System.Text.Json;
using System.Reflection;
using System.Security.Cryptography;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Threading;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Features;

var root=Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"../../../../../"));
var results=Path.Combine(root,"card-recovery-pages-tests/results");Directory.CreateDirectory(results);
var passed=new List<string>();
void Check(bool value,string label){if(!value)throw new Exception(label);passed.Add(label);Console.WriteLine("PASS "+label);}
void Reject(Action action,string label){try{action();}catch{Check(true,label);return;}throw new Exception("accepted "+label);}
foreach(var ids in new[]{Array.Empty<string>(),new[]{"esim"},new[]{"vpn","info"},new[]{"esim","vpn","info"}}){var encoded=new LauncherPages(ids).Encode();var decoded=LauncherPages.Decode(encoded);Check(decoded.Order.SequenceEqual(ids)&&!decoded.UsesDefault,"exact page roundtrip count="+ids.Length);}
IEnumerable<string[]> Orders(string[] prefix){yield return prefix;if(prefix.Length==3)yield break;foreach(var next in LauncherPages.Ids.Except(prefix))foreach(var order in Orders(prefix.Append(next).ToArray()))yield return order;}
foreach(var order in Orders([]))Check(LauncherPages.Decode(new LauncherPages(order).Encode()).Order.SequenceEqual(order),"all subset permutations: "+string.Join(',',order));
Check(LauncherPages.Default.UsesDefault&&LauncherPages.Default.Order.SequenceEqual(new[]{"info","vpn","esim"}),"missing configuration defaults to all three pages");
Check(Encoding.ASCII.GetString(new LauncherPages([]).Encode())=="ZTE_LAUNCHER_PAGES_V1\n","header only means zero additional pages");
foreach(var bad in new[]{"","ZTE_LAUNCHER_PAGES_V1","ZTE_LAUNCHER_PAGES_V1\ninfo","ZTE_LAUNCHER_PAGES_V1\ninfo\ninfo\n","ZTE_LAUNCHER_PAGES_V1\nunknown\n","ZTE_LAUNCHER_PAGES_V1\n\n","ZTE_LAUNCHER_PAGES_V1\r\ninfo\r\n","ZTE_LAUNCHER_PAGES_V1\ninfo \n","ZTE_LAUNCHER_PAGES_V1\nINFO\n","ZTE_LAUNCHER_PAGES_V1\ninfo\0\n",new string('a',129)})Reject(()=>LauncherPages.Decode(Encoding.UTF8.GetBytes(bad)),"malformed page grammar rejected #"+passed.Count);
Reject(()=>new LauncherPages(new[]{"info","vpn","esim","info"}).Encode(),"duplicate/too many outbound pages refused");
Reject(()=>new LauncherPages(new[]{"info;reboot"}).Encode(),"shell-shaped outbound page refused");
Check(ZteImeiStudio.Windows.Core.AgentPackage.Version == "2.7.0-esim.8" && Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(root,"Resources/Onboarding/zte-agent")))) == ZteImeiStudio.Windows.Core.AgentPackage.Sha256, "public rebuilt agent matches packaged bytes");
Check(ZteImeiStudio.Windows.Core.AgentPackage.VersionForHash("6168ae6c539bb3ca7136eb40a1d4cae03d75aa18900be105f2ff2d5016da4b5c") == "2.7.0-esim.7", "previous released .7 remains recognized");
await PageInstallerTests.Run(root,Check);
using var session=HeadlessUnitTestSession.StartNew(typeof(SmokeApp));
await session.Dispatch(()=>
{
 void Pump(){Dispatcher.UIThread.RunJobs();AvaloniaHeadlessPlatform.ForceRenderTimerTick();Dispatcher.UIThread.RunJobs();}
 T Find<T>(Window w,string name)where T:Control=>w.GetLogicalDescendants().OfType<T>().Single(x=>x.Name==name);
 void Click(Window w,string name){var b=Find<Button>(w,name);Check(b.IsEnabled,"button enabled "+name);b.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();}
 void Capture(Window w,string name){Pump();Thread.Sleep(100);Pump();using var f=w.CaptureRenderedFrame()??throw new Exception("no frame");f.Save(Path.Combine(results,name));}
 foreach(var language in new[]{"ru","en"})
 {
  Localization.SetLanguage(language,persist:false);var fake=new FakeModem();var window=new MainWindow(fake,persistPreferences:false);window.Show();Pump();Click(window,"Navigation1");
  var form=(Dictionary<string,string>)typeof(MainWindow).GetField("_form",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(window)!;
  Check(Find<CheckBox>(window,"LauncherPage-vpn").IsChecked==true&&Find<CheckBox>(window,"LauncherPage-info").IsChecked==true&&Find<CheckBox>(window,"LauncherPage-esim").IsChecked==false,"checkboxes reflect saved subset: "+language);
  Find<CheckBox>(window,"LauncherPage-esim").IsChecked=true;Click(window,"LauncherPageUp-esim");Click(window,"LauncherPageUp-esim");Find<CheckBox>(window,"LauncherPage-info").IsChecked=false;Pump();
  Check(form["pages"]=="esim,vpn","enabled subset retains requested order: "+language);
  form["style"]="tiles";form["metrics"]="draft-metrics";form["metric_order"]="draft-order";
  Capture(window,language+"-selection.png");Click(window,"LauncherApplyPages");
  Check(fake.Operations.Last().Operation==ModemOperation.ApplyLauncherPages&&fake.Operations.Last().Parameters!["pages"]=="esim,vpn","apply passes exact page selection without installer: "+language);
  Check(form["style"]=="tiles"&&form["metrics"]=="draft-metrics"&&form["metric_order"]=="draft-order","page apply preserves unsaved metric draft: "+language);
  foreach(var id in LauncherPages.Ids)Find<CheckBox>(window,"LauncherPage-"+id).IsChecked=false;
  Click(window,"LauncherInstallPages");Check(fake.Operations.Last().Operation==ModemOperation.InstallLauncher&&fake.Operations.Last().Parameters!["pages"]=="","install supports only two stock pages: "+language);
  Capture(window,language+"-stock-only.png");
  Find<CheckBox>(window,"LauncherPage-info").IsChecked=true;Pump();
  Click(window,"Navigation8");Click(window,"EsimInstallLauncherPage");Check(fake.Operations.Last().Operation==ModemOperation.InstallEsimLauncher&&form["pages"]=="info","dedicated eSIM install preserves unrelated unsaved page draft: "+language);
  Click(window,"Navigation1");Check(Find<CheckBox>(window,"LauncherPage-info").IsChecked==true&&Find<CheckBox>(window,"LauncherPage-esim").IsChecked==false,"draft remains visible after returning to page editor: "+language);
  window.Close();Pump();Check(!window.IsVisible,"headless window shutdown: "+language);
 }
 Localization.SetLanguage("ru",persist:false);
 var setupFake=new FakeModem{Connected=false};var setup=new MainWindow(setupFake,persistPreferences:false);setup.Show();Pump();
 var secrets=(Dictionary<string,TextBox>)typeof(MainWindow).GetField("_secretFields",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(setup)!;
 var setupForm=(Dictionary<string,string>)typeof(MainWindow).GetField("_form",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(setup)!;
 var suffix=secrets["backup_key_suffix"];Check(suffix.PasswordChar=='●'&&!setupForm.ContainsKey("backup_key_suffix"),"public backup suffix is masked and absent from saved form");
 secrets["web_password"].Text="synthetic-web";secrets["agent_password"].Text="synthetic-agent";suffix.Text="test-only-backup-key-suffix";
 setup.GetLogicalDescendants().OfType<Button>().Single(b=>b.Content?.ToString()=="Выполнить предварительную подготовку модема").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();
 Check(setupFake.Operations.Single(r=>r.Operation==ModemOperation.PrepareSsh).Parameters!["backup_key_suffix"]=="test-only-backup-key-suffix","public preparation sends exact test-only suffix");
 Check(suffix.Text==""&&!setupForm.ContainsKey("backup_key_suffix"),"public preparation clears suffix without persisting it");setup.Close();Pump();
},CancellationToken.None);
string Sha(string p)=>Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(p)));
var sourceHashes=Directory.EnumerateFiles(Path.Combine(root,"src"),"*.cs",SearchOption.AllDirectories).Where(p=>!Path.GetRelativePath(Path.Combine(root,"src"),p).Split(Path.DirectorySeparatorChar).Any(x=>x is "bin" or "obj")).Order().ToDictionary(p=>Path.GetRelativePath(root,p),Sha);
File.WriteAllText(Path.Combine(results,"test-result.json"),JsonSerializer.Serialize(new{ok=true,noDevice=true,checks=passed,actualWindowsRuntime=false,sourceHashes,testHashes=new[]{"Program.cs","PageInstallerTests.cs","PageTests.csproj"}.ToDictionary(name=>name,name=>Sha(Path.Combine(root,"card-recovery-pages-tests",name))),assemblySha256=Sha(typeof(MainWindow).Assembly.Location)},new JsonSerializerOptions{WriteIndented=true})+"\n");
public sealed class SmokeApp:Application{public static AppBuilder BuildAvaloniaApp()=>AppBuilder.Configure<SmokeApp>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions{UseHeadlessDrawing=false});public override void Initialize()=>App.ConfigureTheme(this);}
sealed class FakeModem:IModemService
{
 public bool Connected=true;public List<OperationRequest> Operations=[];public string Pages="vpn,info";
 public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct=default)=>Task.FromResult(new DeviceSnapshot(Connected,"Подключено",Serial:"synthetic-device",IpAddress:"192.0.2.1",ConnectionMode:"SSH",Launcher:"ready",LauncherStyle:"list",LauncherMetrics:"cpu",LauncherMetricOrder:"cpu,battery",LauncherPages:Pages));
 public Task<OperationResult> RunAsync(OperationRequest r,CancellationToken ct=default){Operations.Add(r);if(r.Operation is ModemOperation.InstallLauncher or ModemOperation.ApplyLauncherPages)Pages=r.Parameters!["pages"];if(r.Operation==ModemOperation.InstallEsimLauncher)Pages=string.Join(',',Pages.Split(',',StringSplitOptions.RemoveEmptyEntries).Append("esim").Distinct());return Task.FromResult(new OperationResult(true,"Состояние обновлено."));}
 public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<BackupInfo>>([]);
 public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<ModemAppInfo>>([]);
 public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<LogEntry>>([]);
 public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct=default)=>throw new NotSupportedException();
}
