using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Threading;
using ZteImeiStudio.Windows;
using System.Reflection;
using System.Security.Cryptography;
var windowsRoot=Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"../../../../"));
var lockPath=Path.Combine(windowsRoot,"src","packages.lock.json");
var screenshots=Path.Combine(Path.GetTempPath(),"zte-diagnostic-terminal-ui");Directory.CreateDirectory(screenshots);
var before=SHA256.HashData(File.ReadAllBytes(lockPath));
// A terminal owns its operation lock until disconnect or stream EOF. These
// streams are in-memory fakes; no SSH client or modem is created.
var leaseRoot=Path.Combine(Path.GetTempPath(),"zte-terminal-lock-"+Guid.NewGuid());Directory.CreateDirectory(leaseRoot);
try
{
 var leasePath=Path.Combine(leaseRoot,"operation.lock");
 FileStream Lease()=>new(leasePath,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
 bool Available(){try{using var lease=Lease();return true;}catch(IOException){return false;}}
 var disconnected=0;
 var terminal=new TerminalSession(new WaitingStream(),()=>true,()=>disconnected++,"",Lease());
 Check(!Available(),"Open terminal holds the local operation lock");
 await terminal.DisposeAsync();
 Check(Available() && disconnected==1,"Terminal disconnect releases its lock and client exactly once");
 await terminal.DisposeAsync();Check(disconnected==1,"Repeated terminal disposal is safe");
 var eof=new TerminalSession(new MemoryStream(),()=>true,()=>{},"",Lease());
 for(var i=0;i<100 && !Available();i++)await Task.Delay(10);
 Check(Available() && !eof.IsConnected,"Terminal EOF releases the lock and clears connection state");
 await eof.DisposeAsync();
 var reconnected=new TerminalSession(new WaitingStream(),()=>true,()=>{},"",Lease());
 Check(!Available(),"Terminal can reconnect and own a fresh lock");await reconnected.DisposeAsync();
}
finally{Directory.Delete(leaseRoot,true);}
using var session=HeadlessUnitTestSession.StartNew(typeof(TestApp));
await session.Dispatch(()=> {
 foreach(var language in new[]{"ru","en"}) {
  Localization.SetLanguage(language,persist:false);
  var modem=new FakeModem();var window=new MainWindow(modem,persistPreferences:false);window.Show();Pump();
  Set(window,"_snapshot",new DeviceSnapshot(true,"Подключено по SSH",ConnectionMode:"SSH"));Render(window);
  var secretFields=(Dictionary<string,TextBox>)Get(window,"_secretFields")!;
  Check(secretFields.TryGetValue("backup_key_suffix",out var suffixField) && suffixField.PasswordChar!='\0',language+" public backup suffix remains a hidden input");
  suffixField!.Text="synthetic-ui-backup-suffix";
  var force=FindButton(window,"Принудительно включить ADB");
  Check(force.IsEnabled,language+" force ADB remains available with connected SSH and no agent password");
  Check(!FindButton(window,"Выполнить предварительную подготовку модема").IsEnabled,language+" new preparation disabled on working SSH");
  Set(window,"_terminal",new FakeTerminal());Render(window);
  Check(!((Dictionary<string,string>)Get(window,"_form")!).ContainsKey("backup_key_suffix") && ((Dictionary<string,TextBox>)Get(window,"_secretFields")!)["backup_key_suffix"].Text=="",language+" backup suffix clears when the page is rebuilt");
  Check(!FindButton(window,"Принудительно включить ADB").IsEnabled,language+" active interactive terminal blocks force ADB");
  Set(window,"_terminal",null);
  Set(window,"_snapshot",new DeviceSnapshot(true,"Подключено по SSH",ConnectionMode:"SSH",PreparationPending:true));Render(window);
  Check(FindButton(window,"Выполнить предварительную подготовку модема").IsEnabled && !FindButton(window,"Принудительно включить ADB").IsEnabled,language+" pending setup can resume over SSH and blocks competing diagnostic activation");
  Set(window,"_snapshot",new DeviceSnapshot(false,"Нет подключения",AdbActivationPending:true));Render(window);
  Check(FindButton(window,"Продолжить включение ADB").IsEnabled,language+" diagnostic resume remains available without live SSH");
  var info=window.GetLogicalDescendants().OfType<Button>().Single(b=>ToolTip.GetTip(b)?.ToString()==Localization.Translate("Подробно о включении диагностического ADB"));
  info.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();var dialog=window.OwnedWindows.Single();
  Check(dialog.GetLogicalDescendants().OfType<TextBlock>().Any(t=>t.Text==Localization.Translate("3. Продолжение после обрыва")),language+" force ADB info icon shows resume policy");
  if(language=="en")Check(dialog.GetLogicalDescendants().OfType<TextBlock>().All(t=>!(t.Text??"").Any(c=>c is >= '\u0400' and <= '\u04ff')),"Diagnostic ADB help fully translated");
  dialog.Close();Pump();
  Set(window,"_snapshot",new DeviceSnapshot(true,"Подключено по SSH",ConnectionMode:"SSH"));
  Set(window,"_page",5);((int[])Get(window,"_sections")!)[5]=2;Set(window,"_terminalAutoAttempted",true);
  Set(window,"_terminalText",string.Join('\n',Enumerable.Range(1,160).Select(i=>"row "+i.ToString("D3")+" "+new string('x',130))));Render(window);
  var viewport=window.GetLogicalDescendants().OfType<ScrollViewer>().Single(s=>s.Name=="TerminalViewport");
  var output=window.GetLogicalDescendants().OfType<SelectableTextBlock>().Single(t=>t.Name=="TerminalOutput");
  Check(viewport.Extent.Height>viewport.Viewport.Height,"Terminal has a real scrollable content extent");
  Check(Math.Abs(viewport.Offset.Y-(viewport.Extent.Height-viewport.Viewport.Height))<1,"Terminal opens with the complete last row inside viewport");
  var input=window.GetLogicalDescendants().OfType<TextBox>().Single(t=>t.Name=="TerminalInput");
  Check(input.Bounds.Height>0,"Terminal input occupies its own measured row");
  var bottom=output.TranslatePoint(new Point(0,output.Bounds.Height),viewport)!.Value.Y;
  Check(bottom<=viewport.Viewport.Height+1,"Last text baseline cannot be clipped below the scrolling viewport");
  viewport.Offset=new Vector(0,0);Pump();
  typeof(MainWindow).GetMethod("TerminalOutputReceived",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(window,new object?[]{null,new TerminalDataEventArgs("\nnew row 161")});Pump();
  Check(viewport.Offset.Y==0,"Incoming terminal text preserves manual scrollback");
  viewport.ScrollToEnd();Pump();
  typeof(MainWindow).GetMethod("TerminalOutputReceived",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(window,new object?[]{null,new TerminalDataEventArgs("\nnew row 162")});Pump();
  Check(Math.Abs(viewport.Offset.Y-(viewport.Extent.Height-viewport.Viewport.Height))<1,"Tail-follow waits for layout and shows new final row");
  window.Width=920;window.Height=700;Pump();
  Check(viewport.Viewport.Height>0 && viewport.Extent.Width>viewport.Viewport.Width,"Narrow terminal has a measured viewport and horizontal scroll");
  Check(Math.Abs(viewport.Offset.Y-(viewport.Extent.Height-viewport.Viewport.Height))<1,"Resize keeps the complete final row above the horizontal scrollbar");
  input.BringIntoView();Pump();
  using(var frame=window.CaptureRenderedFrame()??throw new Exception("Missing frame"))frame.Save(Path.Combine(screenshots,language+"-terminal.png"));
  Check(modem.Operations==0,"UI checks performed without modem operations");window.Close();Pump();
 }
 Localization.SetLanguage("ru",persist:false);
},CancellationToken.None);
Check(before.AsSpan().SequenceEqual(SHA256.HashData(File.ReadAllBytes(lockPath))),"Windows publication lock unchanged");
static Button FindButton(Window w,string value)=>w.GetLogicalDescendants().OfType<Button>().Single(b=>b.Content?.ToString()==Localization.Translate(value));
static object? Get(object target,string name)=>target.GetType().GetField(name,BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(target);
static void Set(object target,string name,object? value)=>target.GetType().GetField(name,BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(target,value);
static void Render(MainWindow w){typeof(MainWindow).GetMethod("RenderPage",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(w,null);Pump();}
static void Check(bool value,string text){if(!value){Console.WriteLine("FAIL "+text);Environment.Exit(1);return;}Console.WriteLine("PASS "+text);}
static void Pump(){for(int i=0;i<4;i++){Dispatcher.UIThread.RunJobs();AvaloniaHeadlessPlatform.ForceRenderTimerTick();Dispatcher.UIThread.RunJobs();}}
public sealed class TestApp:Application {
 public static AppBuilder BuildAvaloniaApp()=>AppBuilder.Configure<TestApp>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions{UseHeadlessDrawing=false});
 public override void Initialize()=>App.ConfigureTheme(this);
}
internal sealed class FakeTerminal:ITerminalSession {
 public event EventHandler<TerminalDataEventArgs>? OutputReceived{add{}remove{}}
 public bool IsConnected=>true;
 public Task SendAsync(string text,CancellationToken ct=default)=>Task.CompletedTask;
 public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
}
internal sealed class FakeModem:IModemService {
 public int Operations{get;private set;}
 public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct=default)=>Task.FromResult(new DeviceSnapshot(false,"Нет подключения"));
 public Task<OperationResult> RunAsync(OperationRequest request,CancellationToken ct=default){Operations++;throw new Exception("Unexpected modem operation");}
 public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<BackupInfo>>([]);
 public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<ModemAppInfo>>([]);
 public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<LogEntry>>([]);
 public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct=default)=>throw new Exception("Unexpected terminal");
}

internal sealed class WaitingStream:MemoryStream
{
 public override async ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken ct=default){await Task.Delay(Timeout.Infinite,ct);return 0;}
}
