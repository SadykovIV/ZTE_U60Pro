using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Threading;
using ZteImeiStudio.Windows;
using System.Reflection;
using System.Security.Cryptography;
using ZteImeiStudio.Windows.Research;
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
var serviceRoot=Path.Combine(Path.GetTempPath(),"zte-ssh-only-fixture-"+Guid.NewGuid());
try
{
 var factory=new NoNetworkResearchFactory();
 var service=new WindowsModemService(serviceRoot,Path.Combine(windowsRoot,"Resources"),()=>factory);
 foreach(var mode in new[]{"ADB","Автоматически","Web","SSH"})
 {
  var report=await service.CollectFirmwareResearchAsync(new Dictionary<string,string>{{"mode",mode}},null);
  Check(report.RequestedMode=="SSH"&&factory.AdbCalls==0,"public survey cannot select or fall back to "+mode);
 }
 _=await service.CollectPreparationResearchAsync(new Dictionary<string,string>(),null);
 Check(factory.AdbCalls==1,"explicit preparation survey retains bounded USB discovery");
 Set(service,"_snapshot",new DeviceSnapshot(true,"Synthetic old USB indicator",ConnectionMode:"ADB"));
 foreach(var operation in new[]{ModemOperation.RefreshDevice,ModemOperation.ReadImei,ModemOperation.RefreshTtl,ModemOperation.RefreshVpn,ModemOperation.RefreshLauncher,ModemOperation.RefreshAccess})
 {
  var reply=await service.RunAsync(new OperationRequest(operation));
  Check(!reply.Success&&reply.Message.Contains("SSH"),"ordinary "+operation+" refuses missing SSH without USB fallback");
 }
}
finally{if(Directory.Exists(serviceRoot))Directory.Delete(serviceRoot,true);}
Check(MainWindow.ConnectionBrowserUri("192.0.2.2",true).AbsoluteUri=="http://192.0.2.2:8080/","agent browser link targets dashboard8080, not API9090");
Check(MainWindow.ConnectionBrowserUri("192.0.2.2",false).AbsoluteUri=="http://192.0.2.2/","stock browser link targets HTTP root only");
try{_=MainWindow.ConnectionBrowserUri("192.0.2.2/secret?x=1",true);Check(false,"invalid browser host rejected");}catch(ArgumentException){Check(true,"invalid browser host rejected");}
using var session=HeadlessUnitTestSession.StartNew(typeof(TestApp));
await session.Dispatch(()=> {
 foreach(var language in new[]{"ru","en"}) {
  Localization.SetLanguage(language,persist:false);
  var modem=new FakeModem();var window=new MainWindow(modem,persistPreferences:false);window.Show();Pump();
  Set(window,"_snapshot",new DeviceSnapshot(true,"Подключено по SSH",ConnectionMode:"SSH"));Render(window);
  Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name=="CollectFirmwareResearch"),language+" research stays outside connection settings");
  Check(window.GetLogicalDescendants().OfType<Expander>().Any(e=>e.Name=="ConnectionMethods"),language+" connection contains compact methods disclosure");
  Check(window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name=="OpenModemWeb")&&window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name=="OpenAgentWeb"),language+" web interfaces are browser actions");
  Check(!window.GetLogicalDescendants().OfType<ComboBox>().Any(b=>b.Name=="ConnectionMode"),language+" normal connection exposes no ADB or Web management mode");
  Check(!FindButton(window,"Выполнить предварительную подготовку модема").IsEnabled,language+" new preparation disabled on working SSH");
  Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name=="EnableDiagnosticAdb"),language+" ADB has one checkbox and no legacy force button");
  Check(!window.GetLogicalDescendants().OfType<CheckBox>().Any(c=>c.Content?.ToString()==Localization.Translate("Пропустить проверку прошивки")),language+" universal initial access has no firmware-skip checkbox");
  using(var frame=window.CaptureRenderedFrame()??throw new Exception("Missing diagnostic frame"))frame.Save(Path.Combine(screenshots,language+"-diagnostic-connection.png"));
  var methods=window.GetLogicalDescendants().OfType<Expander>().Single(e=>e.Name=="ConnectionMethods");methods.IsExpanded=true;Pump();
  using(var frame=window.CaptureRenderedFrame()??throw new Exception("Missing methods frame"))frame.Save(Path.Combine(screenshots,language+"-connection-methods-expanded.png"));
  var secretFields=(Dictionary<string,TextBox>)Get(window,"_secretFields")!;
  Check(secretFields.TryGetValue("backup_key_suffix",out var suffixField) && suffixField.PasswordChar!='\0',language+" public backup suffix remains a hidden input");
  Check(suffixField!.Watermark==(language=="en"?"Leave empty to try the known format key":"Пусто — известный ключ формата"),language+" backup override clearly documents automatic B31 format");
  foreach(var topic in new[]{OperationHelpContent.DiagnosticAdb,OperationHelpContent.Preparation})
  {
   var body=Localization.Translate(topic.Sections.Single(section=>section.Body.StartsWith("Известный ключ формата используется как кандидат при пустом Backup-key suffix",StringComparison.Ordinal)).Body);
   Check(body.StartsWith(language=="en"?"The known format key is used as a candidate when Backup-key suffix is empty.":"Известный ключ формата используется как кандидат при пустом Backup-key suffix.",StringComparison.Ordinal),language+" runtime help documents automatic B31 suffix");
   Check(body.Contains(language=="en"?"without a fallback attempt":"без резервной попытки",StringComparison.Ordinal),language+" runtime help preserves explicit override failure boundary");
  }
  suffixField!.Text="synthetic-ui-backup-suffix";
  var adbState=window.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");
  Check(adbState.StyleKey==typeof(CheckBox),language+" ADB intent checkbox preserves standard checkbox indicator theme");
  Check(adbState.IsChecked is null&&!adbState.IsEnabled,language+" unknown ADB is neither off nor mutable");
  Set(window,"_terminal",new FakeTerminal());Render(window);
  Check(!((Dictionary<string,string>)Get(window,"_form")!).ContainsKey("backup_key_suffix") && ((Dictionary<string,TextBox>)Get(window,"_secretFields")!)["backup_key_suffix"].Text=="",language+" backup suffix clears when the page is rebuilt");
  Check(!window.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,language+" active interactive terminal blocks ADB checkbox");
  Set(window,"_terminal",null);
  Set(window,"_snapshot",new DeviceSnapshot(true,"Подключено по SSH",ConnectionMode:"SSH",PreparationPending:true));Render(window);
  Check(!window.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,language+" pending setup blocks competing diagnostic activation");

  Check(FindButton(window,"Выполнить предварительную подготовку модема").IsEnabled,language+" pending setup can resume over SSH");
  Set(window,"_snapshot",new DeviceSnapshot(false,"Нет подключения",AdbActivationPending:true));Render(window);
  Check(window.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,language+" diagnostic resume remains available through checkbox without live SSH");
  var info=window.GetLogicalDescendants().OfType<Button>().Single(b=>ToolTip.GetTip(b)?.ToString()==Localization.Translate("Подробно о включении диагностического ADB"));
  info.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();var dialog=window.OwnedWindows.Single();
  Check(dialog.GetLogicalDescendants().OfType<TextBlock>().Any(t=>t.Text==Localization.Translate("3. Продолжение после обрыва")),language+" force ADB info icon shows resume policy");
  if(language=="en")Check(dialog.GetLogicalDescendants().OfType<TextBlock>().All(t=>!(t.Text??"").Any(c=>c is >= '\u0400' and <= '\u04ff')),"Diagnostic ADB help fully translated");
  dialog.Close();Pump();
  NamedClick(window,"Section0-1");
  Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name is "DiscoverConnections" or "EnableDiagnosticAdb" or "DiagnosticAccess" or "RefreshAdbState"),language+" unified diagnostics contains no connection/ADB/access controls");
  Check(!window.GetLogicalDescendants().OfType<TextBox>().Any(),language+" diagnostics contains no editable connection fields");
  Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Content?.ToString()==Localization.Translate("Перезагрузить модем")),language+" diagnostics contains no reboot action");
  Check(window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name=="CollectFirmwareResearch"),language+" firmware research exists only in its diagnostic group");
  Set(window,"_terminal",new FakeTerminal());Render(window);
  typeof(MainWindow).GetMethod("SetBusy",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(window,[false]);
  Check(!window.GetLogicalDescendants().OfType<Button>().Single(b=>b.Name=="CollectFirmwareResearch").IsEnabled,language+" clearing busy never bypasses active terminal research guard");
  Set(window,"_terminal",null);Render(window);

  Check(FindButton(window,"Сохранить диагностический ZIP").IsEnabled,language+" local diagnostic export remains available without connection");
  Check(window.GetLogicalDescendants().OfType<Button>().Count(b=>b.Content?.ToString()==Localization.Translate("Сохранить диагностический ZIP"))==1&&!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Content?.ToString()==Localization.Translate("Экспортировать ZIP")),language+" diagnostics has one common ZIP export and no separate research export");
  using(var frame=window.CaptureRenderedFrame()??throw new Exception("Missing reports frame"))frame.Save(Path.Combine(screenshots,language+"-diagnostic-reports.png"));
  Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name?.StartsWith("DiagnosticsGroup")==true),language+" diagnostics has a single combined view");
  NamedClick(window,"Navigation6");
  var reboot=FindButton(window,"Перезагрузить модем");reboot.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();
  var confirmation=window.OwnedWindows.Single();
  confirmation.GetLogicalDescendants().OfType<Button>().Single(b=>b.Content?.ToString()==Localization.Translate("Отмена")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();
  Check(modem.Operations==0,language+" cancelled administration reboot and diagnostic navigation perform no modem operation");

  Check(window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Content?.ToString()==Localization.Translate("Журнал действий")),language+" action journal stays in administration");
  Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Content?.ToString()==Localization.Translate("Проверить доступы")),language+" access inspection moved without moving account management");
  NamedClick(window,"Section6-2");Check(FindButton(window,"Обновить журнал").IsEnabled,language+" administration journal remains available offline");
  NamedClick(window,"Navigation7");Check(!window.GetLogicalDescendants().OfType<Button>().Any(b=>b.Content?.ToString()==Localization.Translate("Диагностика")),language+" modem information has only information and memory");
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
 foreach(var language in new[]{"ru","en"}) {
  Localization.SetLanguage(language,persist:false);
  var checkModem=new FakeModem {AllowBackupCheck=true};var checkWindow=new MainWindow(checkModem,persistPreferences:false);checkWindow.Show();Pump();
  var checkButton=checkWindow.GetLogicalDescendants().OfType<Button>().Single(b=>b.Name=="VerifyBackupKey");
  Check(checkButton.Content?.ToString()==(language=="en"?"Check backup key":"Проверить ключ бэкапа"),language+" backup key action is localized");
  Check(!checkButton.IsEnabled&&checkModem.Operations==0,language+" backup check requires password and never runs on entry");
  var checkSecrets=(Dictionary<string,TextBox>)Get(checkWindow,"_secretFields")!;
  checkSecrets["web_password"].Text="synthetic-password";Pump();
  Check(checkButton.IsEnabled&&checkSecrets["agent_password"].Text=="",language+" Web password alone enables read-only key check");
  Set(checkWindow,"_snapshot",new DeviceSnapshot(false,"Нет подключения",PreparationPending:true,AdbActivationPending:true));
  typeof(MainWindow).GetMethod("UpdateDiagnosticAvailability",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(checkWindow,null);
  Check(checkButton.IsEnabled,language+" saved pending operations do not block separate read-only backup verification");
  Set(checkWindow,"_snapshot",new DeviceSnapshot(false,"Нет подключения"));
  NamedClick(checkWindow,"VerifyBackupKey");
  var request=checkModem.Requests.Single();
  Check(request.Operation==ModemOperation.VerifyBackupKey&&request.Parameters!.Keys.Order().SequenceEqual(new[]{"backup_key_suffix","host","web_password"}),language+" key check dispatches only its dedicated read-only request");
  Check(checkModem.Events.Count==0&&!((DeviceSnapshot)Get(checkWindow,"_snapshot")!).IsConnected,language+" key success creates no research/preparation/connection readiness");
  var checkStatus=checkWindow.GetLogicalDescendants().OfType<TextBlock>().Single(t=>t.Name=="BackupKeyCheckStatus").Text!;
  Check(checkStatus.Contains("FLY_CN_MU5250V1.0.0B13")&&checkStatus.Contains("BD_FLYMODEMMU5250V1.0.0B28")&&checkStatus.Contains(language=="en"?"does not authorize":"не разрешает"),language+" separate result shows observed versions and write boundary");
  Check(((Dictionary<string,TextBox>)Get(checkWindow,"_secretFields")!).Values.All(t=>string.IsNullOrEmpty(t.Text)),language+" read-only key check clears all password inputs");
  var help=Localization.Translate(OperationHelpContent.Preparation.Sections.Single(s=>s.Title=="Проверка ключа без подготовки доступа").Body);
  Check(help.Contains(language=="en"?"regardless of the firmware name":"независимо от имени прошивки")&& (language!="en"||!help.Any(c=>c is >= '\u0400' and <= '\u04ff')),language+" key-check help explains firmware-neutral candidate without restoring");
  var secretsAfter=(Dictionary<string,TextBox>)Get(checkWindow,"_secretFields")!;
  secretsAfter["backup_key_suffix"].Text="new-synthetic-override";Pump();
  Check(checkWindow.GetLogicalDescendants().OfType<TextBlock>().Single(t=>t.Name=="BackupKeyCheckStatus").Text==Localization.Translate("Ключ бэкапа ещё не проверен."),language+" changing manual override invalidates displayed key proof");
  secretsAfter["web_password"].Text="pw";checkModem.BackupCheckSuccess=false;NamedClick(checkWindow,"VerifyBackupKey");
  Check(checkWindow.GetLogicalDescendants().OfType<TextBlock>().Single(t=>t.Name=="BackupKeyCheckStatus").Text==Localization.Translate("Не удалось подтвердить ключ или формат архива бэкапа."),language+" failed check replaces previous success with neutral key/format error");
  Check(checkModem.Requests.All(r=>r.Operation==ModemOperation.VerifyBackupKey),language+" backup check never triggers ADB or install operations");
  checkWindow.Close();Pump();
 }
 Localization.SetLanguage("ru",persist:false);
 var discovery=new FakeModem {AllowPreparation=true};var first=new MainWindow(discovery,persistPreferences:false);first.Show();Pump();
 Check(!first.GetLogicalDescendants().OfType<Button>().Any(b=>b.Name=="CollectFirmwareResearch"),"connection no longer displays research but keeps preparation precondition");
 NamedClick(first,"Section0-1");NamedClick(first,"CollectFirmwareResearch");
 Check(discovery.ResearchParameters?["mode"]=="SSH","independent diagnostic survey is SSH-only before preparation");
 NamedClick(first,"Section0-0");
 FindButton(first,"Выполнить предварительную подготовку модема").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();
 Check(discovery.Events.SequenceEqual(new[]{"research","bootstrap-research","prepare"})&&discovery.ResearchParameters?["mode"]=="Автоматически","GUI uses explicit bootstrap survey before preparing SSH access");
 Check(((ResearchReport?)Get(first,"_researchReport"))?.BindingStrength=="transport-only","GUI retains incomplete survey rather than inventing full identity");
 first.Close();Pump();
 var persistedRoot=Path.Combine(Path.GetTempPath(),"zte-ui-connection-restart-"+Guid.NewGuid());Directory.CreateDirectory(persistedRoot);
 try
 {
  var savedKey=Path.Combine(persistedRoot,"key-path-only");var savedHosts=Path.Combine(persistedRoot,"known-hosts-path-only");
  File.WriteAllText(Path.Combine(persistedRoot,"connection.json"),System.Text.Json.JsonSerializer.Serialize(new {host="192.0.2.23",port=2223,key_path=savedKey,known_hosts_path=savedHosts}));
  var savedService=new WindowsModemService(persistedRoot,Path.Combine(windowsRoot,"Resources"));var settings=savedService.GetConnectionSettings();
  Check(settings.Host=="192.0.2.23"&&settings.Port==2223&&settings.Username=="root"&&settings.KeyPath==savedKey&&settings.KnownHostsPath==savedHosts,"service restores connection metadata without reading key contents");
  var restartedModem=new FakeModem{AllowDiagnostics=true,Settings=settings};var restarted=new MainWindow(restartedModem,persistPreferences:false);restarted.Show();Pump();
  NamedClick(restarted,"Section0-1");NamedClick(restarted,"CollectFirmwareResearch");
  Check(restartedModem.ResearchParameters?["host"]==settings.Host&&restartedModem.ResearchParameters?["port"]=="2223"&&restartedModem.ResearchParameters?["key_path"]==savedKey&&restartedModem.ResearchParameters?["known_hosts_path"]==savedHosts&&restartedModem.ResearchParameters?["mode"]=="SSH","fresh window diagnostic survey uses restored SSH settings after restart");
  NamedClick(restarted,"Section0-0");var updatedHost=restarted.GetLogicalDescendants().OfType<TextBox>().Single(t=>t.Watermark=="192.168.0.1");updatedHost.Text="192.0.2.24";
  var updatedKey=restarted.GetLogicalDescendants().OfType<TextBox>().Single(t=>t.Watermark==Localization.Translate("Использовать локальный ключ"));updatedKey.Text=Path.Combine(persistedRoot,"new-key-path-only");Pump();
  NamedClick(restarted,"Section0-1");NamedClick(restarted,"CollectFirmwareResearch");
  Check(restartedModem.ResearchParameters?["host"]=="192.0.2.24"&&restartedModem.ResearchParameters?["key_path"]==Path.Combine(persistedRoot,"new-key-path-only"),"current Connection edits override saved settings for subsequent survey");
  Check(restartedModem.Operations==0,"restoring settings and opening diagnostics never dispatches a modem operation");
  restarted.Close();Pump();
 }
 finally{Directory.Delete(persistedRoot,true);}
 var diagnostics=new FakeModem{AllowDiagnostics=true};var panel=new MainWindow(diagnostics,persistPreferences:false);panel.Show();Pump();
 var context=(Dictionary<string,string>)Get(panel,"_form")!;context["host"]="192.0.2.2";context["key_path"]="synthetic-key";context["known_hosts_path"]="synthetic-known-hosts";
 var diagnosticSecrets=(Dictionary<string,TextBox>)Get(panel,"_secretFields")!;
 diagnosticSecrets["web_password"].Text="synthetic-web";diagnosticSecrets["agent_password"].Text="synthetic-agent";diagnosticSecrets["backup_key_suffix"].Text="synthetic-suffix";
 NamedClick(panel,"DiscoverConnections");
 Check(diagnostics.Requests.Count==1&&diagnostics.Requests[0].Operation==ModemOperation.DiscoverConnections,"connection diagnostics uses its existing handler exactly once");
 Check(diagnostics.Requests[0].Parameters!["host"]=="192.0.2.2"&&diagnostics.Requests[0].Parameters!["key_path"]=="synthetic-key"&&!diagnostics.Requests[0].Parameters!.ContainsKey("web_password")&&!diagnostics.Requests[0].Parameters!.ContainsKey("agent_password"),"connection availability check sends no Web or agent credentials");
 var keyInput=panel.GetLogicalDescendants().OfType<TextBox>().Single(t=>t.Watermark==Localization.Translate("Использовать локальный ключ"));
 keyInput.Text="synthetic-other-key";Pump();
 Check(((TextBlock)Get(panel,"_diagnosticConnectionStatus")!).Text=="Состояние не проверено","changing SSH key invalidates visible connection status");
 typeof(MainWindow).GetMethod("RecordDiagnosticResult",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(panel,[ModemOperation.DiscoverConnections,new OperationResult(true,"Synthetic late response"),diagnostics.Requests[0].Parameters]);
 Check(((TextBlock)Get(panel,"_diagnosticConnectionStatus")!).Text=="Состояние не проверено","late result for old diagnostic context stays unverified");
 keyInput.Text="synthetic-key";Pump();
 var bootstrapBox=panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");
 Check(bootstrapBox.IsEnabled&&bootstrapBox.IsChecked is null,"valid disconnected bootstrap remains unknown and allows only explicit ON");
 var beforeBootstrap=diagnostics.Requests.Count;
 bootstrapBox.IsChecked=false;Pump();
 Check(diagnostics.Requests.Count==beforeBootstrap&&bootstrapBox.IsChecked is null,"unknown disconnected OFF cannot dispatch any operation");
 Toggle(bootstrapBox);
 Check(diagnostics.Requests.Count==beforeBootstrap+1,"first click from unknown dispatches exactly one bootstrap ON");
 Check(diagnostics.Requests.Last().Operation==ModemOperation.EnableDiagnosticAdb&&diagnostics.Requests.Last().Parameters!["backup_key_suffix"]=="synthetic-suffix"&&!diagnostics.Requests.Last().Parameters!.ContainsKey("agent_password"),"ADB action passes Web/suffix only with no agent-password dependency");
 Check(((Dictionary<string,TextBox>)Get(panel,"_secretFields")!).Values.All(v=>v.Text==""),"diagnostic activation clears all secret inputs");
 Render(panel);
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"missing bootstrap password blocks disconnected enable");
 var freshSecrets=(Dictionary<string,TextBox>)Get(panel,"_secretFields")!;
 freshSecrets["web_password"].Text="synthetic-web";
 var hostInput=panel.GetLogicalDescendants().OfType<TextBox>().Single(t=>t.Watermark=="192.168.0.1");hostInput.Text="bad-host";Pump();
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"invalid host blocks bootstrap checkbox");
 hostInput.Text="192.0.2.2";freshSecrets["web_password"].Text="bad\0password";Pump();
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"invalid password blocks bootstrap checkbox");
 freshSecrets["web_password"].Text="synthetic-web";
 typeof(MainWindow).GetMethod("SetBusy",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(panel,[true]);
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"busy blocks bootstrap checkbox");
 typeof(MainWindow).GetMethod("SetBusy",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(panel,[false]);
 Set(panel,"_terminal",new FakeTerminal());Render(panel);
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"terminal blocks disconnected bootstrap checkbox");
 Set(panel,"_terminal",null);Set(panel,"_snapshot",new DeviceSnapshot(false,"Synthetic pending",AdbActivationPending:true));Render(panel);
 var pendingBox=panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");
 Check(pendingBox.IsEnabled&&pendingBox.IsChecked is null,"legacy pending permits explicit resume with no password");
 beforeBootstrap=diagnostics.Requests.Count;Toggle(pendingBox);
 Check(diagnostics.Requests.Count==beforeBootstrap+1&&diagnostics.Requests.Last().Operation==ModemOperation.EnableDiagnosticAdb,"pending checkbox resumes existing diagnostic workflow once");
 Set(panel,"_snapshot",new DeviceSnapshot(true,"Synthetic SSH",ConnectionMode:"SSH",AdbActivationPending:true));Render(panel);
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"SSH pending disables mutation and permits only state recovery");
 NamedClick(panel,"RefreshAdbState");Check(diagnostics.Requests.Last().Operation==ModemOperation.RefreshAdbState,"SSH pending recovery uses state read workflow");
 Set(panel,"_snapshot",new DeviceSnapshot(true,"Synthetic SSH",Serial:"synthetic",IpAddress:"192.0.2.2",ConnectionMode:"SSH"));Render(panel);
 NamedClick(panel,"DiagnosticAccess");Check(diagnostics.Requests.Last().Operation==ModemOperation.RefreshAccess,"access inspection uses read-only handler without service mutation");
 Set(panel,"_snapshot",new DeviceSnapshot(true,"Synthetic SSH",ConnectionMode:"SSH",AdbEnabled:false,AdbControlSupported:true));Render(panel);
 var checkbox=panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");
 Check(checkbox.IsEnabled&&checkbox.IsChecked==false&&!checkbox.IsThreeState,"known supported ADB status permits binary checkbox action");
 var requestsBefore=diagnostics.Requests.Count;Render(panel);Check(diagnostics.Requests.Count==requestsBefore,"rendering known ADB state never changes it");
 checkbox=panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");checkbox.IsChecked=true;Pump();
 Check(diagnostics.Requests.Last().Operation==ModemOperation.SetAdbEnabled&&diagnostics.Requests.Last().Parameters!["enabled"]=="true","explicit checkbox dispatches one typed ADB intent");
 checkbox=panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");
 Check(!checkbox.IsEnabled&&checkbox.IsChecked is null,"unconfirmed mutation refresh cannot retain ADB authority");
 Set(panel,"_snapshot",new DeviceSnapshot(true,"Synthetic SSH",ConnectionMode:"SSH",AdbEnabled:true,AdbControlSupported:true));Render(panel);
 checkbox=panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled");checkbox.IsChecked=false;Pump();
 Check(diagnostics.Requests.Last().Operation==ModemOperation.SetAdbEnabled&&diagnostics.Requests.Last().Parameters!["enabled"]=="false","explicit off checkbox sends false only after known SSH state");
 Set(panel,"_snapshot",new DeviceSnapshot(true,"Synthetic SSH",ConnectionMode:"SSH",AdbEnabled:true,AdbControlSupported:true,PreparationPending:true));Render(panel);
 Check(!panel.GetLogicalDescendants().OfType<CheckBox>().Single(c=>c.Name=="AdbEnabled").IsEnabled,"pending preparation blocks runtime ADB toggle");

 NamedClick(panel,"Section0-1");
 NamedClick(panel,"CollectFirmwareResearch");
 Check(diagnostics.ResearchParameters?["host"]=="192.0.2.2"&&diagnostics.ResearchParameters?["mode"]=="SSH","general firmware survey uses SSH only");
 Check(panel.GetLogicalDescendants().OfType<Button>().Count(b=>b.Content?.ToString()=="Сохранить диагностический ZIP")==1&&!panel.GetLogicalDescendants().OfType<Button>().Any(b=>b.Content?.ToString()=="Экспортировать ZIP"),"saved survey uses one common diagnostic ZIP export after disconnected partial read");
 FindButton(panel,"Сохранить диагностический ZIP").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();
 Check(diagnostics.Requests.Last().Operation==ModemOperation.ExportDiagnostics,"reports exports application diagnostics through unchanged operation");
 Check(diagnostics.Requests.All(r=>r.Operation is ModemOperation.DiscoverConnections or ModemOperation.EnableDiagnosticAdb or ModemOperation.RefreshAccess or ModemOperation.ExportDiagnostics or ModemOperation.SetAdbEnabled or ModemOperation.RefreshAdbState),"navigation never dispatches install/reboot/profile or tool mutation");
 NamedClick(panel,"Section0-0");
 FindButton(panel,"Подключиться").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();
 Check(diagnostics.Requests.Last().Operation==ModemOperation.Connect&&!diagnostics.Requests.Last().Parameters!.ContainsKey("mode")&&!diagnostics.Requests.Last().Parameters!.ContainsKey("web_password")&&!diagnostics.Requests.Last().Parameters!.ContainsKey("agent_password"),"ordinary connection is SSH-only with no Web/agent auth parameters");
 NamedClick(panel,"Navigation5");Check(FindButton(panel,"Проверить утилиты").IsEnabled,"diagnostic utility maintenance remains in Applications");
 panel.Close();Pump();
},CancellationToken.None);
Check(before.AsSpan().SequenceEqual(SHA256.HashData(File.ReadAllBytes(lockPath))),"Windows publication lock unchanged");
static void Toggle(CheckBox checkbox){checkbox.GetType().GetMethod("Toggle",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(checkbox,null);Pump();}
static void NamedClick(Window w,string name){w.GetLogicalDescendants().OfType<Button>().Single(b=>b.Name==name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump();}
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
 public ConnectionSettingsSnapshot Settings=new(); public ConnectionSettingsSnapshot GetConnectionSettings()=>Settings;
 public int Operations{get;private set;} public bool AllowPreparation,AllowDiagnostics,AllowBackupCheck,BackupCheckSuccess=true;public List<string> Events=[];public List<OperationRequest> Requests=[];public IReadOnlyDictionary<string,string>? ResearchParameters;
 public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct=default)=>Task.FromResult(new DeviceSnapshot(false,"Нет подключения"));
 public Task<OperationResult> RunAsync(OperationRequest request,CancellationToken ct=default){Operations++;Requests.Add(request);if(AllowBackupCheck&&request.Operation==ModemOperation.VerifyBackupKey)return Task.FromResult(new OperationResult(BackupCheckSuccess,BackupCheckSuccess?"Ключ и формат бэкапа подтверждены. Это не разрешает восстановление или установку компонентов.":"Не удалось подтвердить ключ или формат архива бэкапа.",Values:BackupCheckSuccess?new Dictionary<string,string>{{"backup_firmware","FLY_CN_MU5250V1.0.0B13"},{"backup_inner","BD_FLYMODEMMU5250V1.0.0B28"},{"backup_entries","1"},{"backup_sha256",new string('a',64)}}:null));if(AllowDiagnostics&&request.Operation is ModemOperation.DiscoverConnections or ModemOperation.EnableDiagnosticAdb or ModemOperation.RefreshAccess or ModemOperation.ExportDiagnostics or ModemOperation.SetAdbEnabled or ModemOperation.RefreshAdbState or ModemOperation.Connect)return Task.FromResult(new OperationResult(false,"Synthetic diagnostic response; no device."));if(AllowPreparation&&request.Operation==ModemOperation.PrepareSsh){Events.Add("prepare");return Task.FromResult(new OperationResult(false,"Synthetic preflight refused; no writes."));}throw new Exception("Unexpected modem operation");}
 public Task<ResearchReport> CollectFirmwareResearchAsync(IReadOnlyDictionary<string,string> parameters,IProgress<ResearchProgress>? progress,CancellationToken ct=default){if(!AllowPreparation&&!AllowDiagnostics)throw new Exception("Unexpected research");ResearchParameters=parameters;Events.Add("research");return Task.FromResult(new ResearchReport(1,"fixture",DateTimeOffset.UtcNow,DateTimeOffset.UtcNow,"partial","ADB",null,"test",7,[],[],[],BindingStrength:"transport-only"));}
 public Task<ResearchReport> CollectPreparationResearchAsync(IReadOnlyDictionary<string,string> parameters,IProgress<ResearchProgress>? progress,CancellationToken ct=default){ResearchParameters=parameters;Events.Add("bootstrap-research");return Task.FromResult(new ResearchReport(1,"fixture",DateTimeOffset.UtcNow,DateTimeOffset.UtcNow,"partial","ADB",null,"test",7,[],[],[],BindingStrength:"transport-only"));}
 public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<BackupInfo>>([]);
 public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<ModemAppInfo>>([]);
 public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<LogEntry>>([]);
 public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct=default)=>throw new Exception("Unexpected terminal");
}

internal sealed class WaitingStream:MemoryStream
{
 public override async ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken ct=default){await Task.Delay(Timeout.Infinite,ct);return 0;}
}

internal sealed class NoNetworkResearchFactory:IResearchTransportFactory
{
 public int AdbCalls;
 public bool SshConfigured=>false;
 public IResearchShell OpenSsh()=>throw new Exception("Unexpected SSH transport");
 public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct){AdbCalls++;return Task.FromResult(new ResearchCommandResult("success",0,"List of devices attached\n",""));}
 public IResearchShell OpenAdb(string serial)=>throw new Exception("Unexpected USB shell");
 public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct)=>throw new Exception("Unexpected USB identity");
}
