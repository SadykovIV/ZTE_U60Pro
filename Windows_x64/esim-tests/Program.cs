using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Threading;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Esim;

var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../"));
var resultDir = Path.Combine(root, "esim-tests/results"); Directory.CreateDirectory(resultDir);
var caPath = Path.Combine(root, "Resources/Esim/gsma-rsp-roots.pem");
if (args.Contains("--tls-smoke"))
{
    // Deliberately no activation, EID, operator session, profile URL or body.
    using var relay = new EsimHttpRelay(caPath);
    using var payload = JsonDocument.Parse("{\"url\":\"https://rsp.invigo.com/\",\"tx\":\"\",\"headers\":[]}");
    var response = await relay.SendAsync(payload.RootElement, CancellationToken.None);
    var metadata = new { host = "rsp.invigo.com", method = "POST", requestBytes = 0, status = response.Code, responseBytes = response.Hex.Length / 2, verifiedTls = response.Code != 0, runtime = System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier };
    var json = JsonSerializer.Serialize(metadata); Console.WriteLine(json); File.WriteAllText(Path.Combine(resultDir, "tls-smoke.json"), json + "\n");
    return response.Code == 0 ? 1 : 0;
}
var passed = new List<string>();
void Pass(string name) { passed.Add(name); Console.WriteLine("PASS " + name); }
void Check(bool value, string name) { if (!value) { Console.WriteLine("FAIL " + name); throw new Exception(name); } }
void Reject(Action action, string name) { try { action(); } catch { return; } throw new Exception("accepted " + name); }
async Task RejectAsync(Func<Task> action, string name) { try { await action(); } catch { return; } throw new Exception("accepted " + name); }
var before = Fixture.Snapshot;
var list = new EsimRequest { Operation = "list" };
var download = new EsimRequest { Operation = "download", ExpectedSnapshot = before, ActivationCode = "LPA:1$example.com$synthetic-test", ConfirmationCode = "1234" };
var enable = new EsimRequest { Operation = "enable", ExpectedSnapshot = before, Iccid = Fixture.Disabled.Iccid };
var delete = new EsimRequest { Operation = "delete", ExpectedSnapshot = before, Iccid = Fixture.Disabled.Iccid, ConfirmDelete = true };
foreach (var request in new[] { list, download, enable, delete })
{
    EsimValidation.Request(request);
    using var doc = JsonDocument.Parse(JsonSerializer.Serialize(request));
    var obj = doc.RootElement;
    Check(obj.GetProperty("protocol").GetInt32() == 1 && obj.GetProperty("operation").GetString() == request.Operation, "wire operation");
    Check(obj.TryGetProperty("confirm_delete", out var value) == (request.Operation == "delete"), "confirm_delete omitted except delete");
    if (request.Operation == "list") Check(obj.EnumerateObject().Count() == 2, "list has only two keys");
    else
    {
        var profile = obj.GetProperty("expected_snapshot").GetProperty("profiles")[0];
        Check(profile.EnumerateObject().Count() == 7 && !profile.TryGetProperty("DisplayName", out _), "strict backend profile schema");
    }
    File.WriteAllText(Path.Combine(resultDir, "synthetic-request-" + request.Operation + ".json"), JsonSerializer.Serialize(request));
}
Pass("four request envelopes match strict backend fields");

foreach (var code in new[] { "LPA:1$localhost$x", "LPA:1$example.123$x", "LPA:1$127.0.0.1$x", "LPA:1$example.com:443$x", "LPA:1$example.com?$x", "LPA:1$example.com$секрет", "LPA:1$example.com$" }) Check(!EsimValidation.ActivationCodeValid(code), "activation rejects malformed host/input");
Reject(() => EsimValidation.Request(new() { Operation = "download", ExpectedSnapshot = before, ActivationCode = download.ActivationCode, ConfirmationCode = "-option" }), "confirmation option");
Reject(() => EsimValidation.Request(new() { Operation = "delete", ExpectedSnapshot = before, Iccid = Fixture.Active.Iccid, ConfirmDelete = true }), "active deletion");
Reject(() => EsimValidation.Snapshot(before with { Profiles = [Fixture.Active, Fixture.Active] }), "duplicate ICCID");
Reject(() => EsimValidation.Snapshot(before with { Profiles = [Fixture.Active with { Enabled = false }] }), "state mismatch");
Pass("activation, confirmation and inventory preflight reject malformed values");
Check(EsimValidation.ComposeManual(" example.com "," match-123 ")=="LPA:1$example.com$match-123","manual plain address");
Check(EsimValidation.ComposeManual("https://example.com:443/","match-123")=="LPA:1$example.com$match-123","manual HTTPS root normalization");
foreach(var address in new[]{"", "http://example.com/", "https://example.com/path", "https://example.com/?query", "https://user@example.com/", "https://example.com:444/", "example.com$injected", "example.com/#x", "example.com:443"}) Check(EsimValidation.ComposeManual(address,"match")==null,"manual rejects address injection: "+address);
foreach(var matching in new[]{"", " ", "x$y", "x y", "x\ny", "секрет", new string('x',512)}) Check(EsimValidation.ComposeManual("example.com",matching)==null,"manual rejects matching ID injection/overflow");
Pass("manual SM-DP+ and Matching ID composition and malformed inputs");

async Task<(EsimResult Result, string Sent, string[] Progress)> Session(EsimRequest request, string frames, int exit = 0)
{
    using var output = new MemoryStream(Encoding.UTF8.GetBytes(frames)); using var input = new MemoryStream();
    var stages = new List<string>();
    var result = await EsimProtocol.ExchangeAsync(output, input, request, (payload, _) =>
    {
        using var http = EsimHttpRelay.BuildRequest(payload);
        Check(http.Method == HttpMethod.Post, "relay POST");
        return Task.FromResult((200, "7B7D"));
    }, new ImmediateProgress(stages.Add), CancellationToken.None);
    return (EsimProtocol.Completed(result, exit), Encoding.UTF8.GetString(input.ToArray()), stages.ToArray());
}
string Final(EsimSnapshot snapshot, bool changed, bool pending = false, bool verified = false) => JsonSerializer.Serialize(new { type = "result", ok = true, snapshot, changed, notifications_pending = pending, modem_verified = verified, radio_restored = verified }) + "\n";
string Progress(string stage) => JsonSerializer.Serialize(new { type = "progress", stage }) + "\n";
string Http(ulong id) => JsonSerializer.Serialize(new { type = "http", id, payload = new { url = "https://example.com/es9plus", tx = "7B7D", headers = new[] { "Content-Type: application/json", "User-Agent: lpac", "X-Admin-Protocol: gsma/rsp/v2.2.0" } } }) + "\n";
var listed = await Session(list, Progress("reading_profiles") + Final(before, false));
Check(listed.Result.Snapshot?.Profiles.Count == 2 && listed.Progress.SequenceEqual(["reading_profiles"]), "list profiles/progress");
var added = before with { Profiles = [..before.Profiles, Fixture.Added] };
var installed = await Session(download, Progress("downloading") + Http(1) + Final(added, true, true));
using (var wire = JsonDocument.Parse(installed.Sent.Split('\n')[1])) Check(wire.RootElement.GetProperty("id").GetInt32() == 1 && wire.RootElement.GetProperty("rcode").GetInt32() == 200 && wire.RootElement.GetProperty("rx").GetString() == "7B7D", "HTTP response correlation");
Check(installed.Result.NotificationsPending, "notification outcome");
await Session(enable, Progress("enabling") + Http(1) + Final(before with { Profiles = [Fixture.Active with { State = "disabled", Enabled = false }, Fixture.Disabled with { State = "enabled", Enabled = true }] }, true, verified: true));
await Session(delete, Progress("deleting") + Final(before with { Profiles = [Fixture.Active] }, true));
Pass("fake RPC list/download/enable/delete, progress and private HTTP flow");

await RejectAsync(() => Session(list, "{broken\n"), "malformed JSON");
await RejectAsync(() => Session(list, Final(before, false) + Final(before, false)), "duplicate final");
await RejectAsync(() => Session(list, Progress("reading_profiles")), "missing final");
await RejectAsync(() => Session(list, Final(before, false).TrimEnd()), "truncated final newline");
await RejectAsync(() => Session(list, Final(before, false), 7), "nonzero process exit");
await RejectAsync(() => Session(list, Http(1) + Final(before, false)), "HTTP in read-only request");
await RejectAsync(() => Session(download, Http(1) + Http(1) + Final(added, true)), "reused HTTP id");
await RejectAsync(() => Session(download, Progress("private operator error") + Final(added, true)), "non-allowlisted progress");
await RejectAsync(() => Session(download, Final(added with { Eid = new string('8',32) }, true)), "stale EID");
await RejectAsync(() => Session(download, Final(before, true)), "download without new profile");
await RejectAsync(() => Session(enable, Final(before, true)), "enable without transition");
await RejectAsync(() => Session(enable, Final(before with { Profiles = [Fixture.Active, Fixture.Disabled with { State="enabled", Enabled=true }] }, true)), "two enabled profiles");
await RejectAsync(() => Session(delete, Final(before with { Profiles = [] }, true)), "delete changed other profile");
await RejectAsync(() => Session(download, new string('x', EsimValidation.MaximumLineBytes + 1) + "\n"), "oversized line");
var failed = await Session(download, "{\"type\":\"result\",\"ok\":false,\"error\":\"private-value-never-displayed\"}\n");
Check(!failed.Result.Ok && failed.Result.Error == "operation_failed", "untrusted error not retained");
Pass("malformed/truncated/duplicate/exit/stale/postcondition failures never confirm mutation");

foreach (var url in new[] { "http://example.com/", "https://127.0.0.1/", "https://[::1]/", "https://localhost/", "https://example.123/", "https://user@example.com/", "https://example.com:444/", "https://example.com/#a", "https://example.com/\n", "https://éxample.com/" }) Check(!EsimHttpRelay.ValidUrl(url, out _), "unsafe URL rejected");
Check(EsimHttpRelay.ValidUrl("https://example.com:443/path?value=1", out _), "valid DNS HTTPS");
foreach (var header in new[] { "Authorization: secret", "Content-Type: x\r\nHost: attacker.example", "Cookie: private" })
{
    using var payload = JsonDocument.Parse(JsonSerializer.Serialize(new { url = "https://example.com/", tx = "", headers = new[] { header } }));
    Reject(() => EsimHttpRelay.BuildRequest(payload.RootElement), "forbidden header");
}
using (var cert = X509Certificate2.CreateFromPem(File.ReadAllText(caPath)))
{
    Check(!EsimHttpRelay.VerifyServer("rsp.invigo.com", cert, null, SslPolicyErrors.RemoteCertificateNameMismatch, cert), "hostname mismatch cannot fallback");
    using var untrusted=X509CertificateLoader.LoadCertificateFromFile(Path.Combine(root,"esim-tests/fixtures/untrusted-test-ca.der"));
    Check(!EsimHttpRelay.VerifyServer("other.example", cert, null, SslPolicyErrors.RemoteCertificateChainErrors, untrusted), "unapproved CA cannot extend trust");
    Check(!EsimHttpRelay.VerifyServer("rsp.invigo.com", null, null, SslPolicyErrors.None, cert), "missing certificate");
    Check(EsimHttpRelay.VerifyServer("other.example", cert, null, SslPolicyErrors.None, cert), "system verified route retained");
}
using(var relay=new EsimHttpRelay(caPath)) { }
Pass("HTTPS domain/header policy, hostname refusal and pinned root bundle");
var fixtures = Path.GetFullPath(Path.Combine(root, "esim-tests/fixtures"));
Check(EsimQr.Read(Path.Combine(fixtures, "single-qr.png")) == "LPA:1$example.com$synthetic-test", "real synthetic QR decode");
Reject(() => EsimQr.Read(Path.Combine(fixtures, "multiple-qr.png")), "multiple QR");
Reject(() => EsimQr.Read(Path.Combine(fixtures, "non-esim-qr.png")), "non eSIM QR");
Pass("native QR decoder single/multiple/non-eSIM fixtures");

using var session = HeadlessUnitTestSession.StartNew(typeof(SmokeApp));
await session.Dispatch(() =>
{
    void Pump() { Dispatcher.UIThread.RunJobs(); AvaloniaHeadlessPlatform.ForceRenderTimerTick(); Dispatcher.UIThread.RunJobs(); }
    T Find<T>(Window window, string name) where T : Control => window.GetLogicalDescendants().OfType<T>().Single(x => x.Name == name);
    void Click(Window window, string name) { var button = Find<Button>(window, name); Check(button.IsEnabled, "button enabled " + name); button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump(); }
    void Capture(Window window, string name) { Pump(); Thread.Sleep(200); Pump(); using var frame = window.CaptureRenderedFrame() ?? throw new Exception("no frame"); frame.Save(Path.Combine(resultDir, name)); }
    bool Label(Window window, string text) => window.GetLogicalDescendants().OfType<TextBlock>().Any(x => x.Text == text);
    foreach (var language in new[] { "ru", "en" })
    {
        Localization.SetLanguage(language, persist:false);
        var fake = new FakeModem(); var window = new MainWindow(fake, persistPreferences:false);
        try
        {
        window.Show(); Pump();
        Check(fake.Requests.Count == 0, "startup never checks the card");
        Click(window,"Navigation1");
        Click(window,"RefreshPage");
        Check(fake.Requests.Count == 0, "header refresh outside information/eSIM never checks the card");
        Click(window,"Navigation8"); Check(!Find<Button>(window,"EsimDelete").IsEnabled, "writes require fresh read");
        Check(fake.Requests.Count == 0, "opening the page never issues a background card request");
        Check(Find<TextBlock>(window,"EsimCardType").Text == Localization.Translate("Карта ещё не проверена."), "card starts unassessed");
        Check(Find<Button>(window,"EsimRead").Content?.ToString() == Localization.Translate("Проверить карту и профили"), "explicit card-check action");
        Click(window,"RefreshPage");
        Check(fake.Requests.Count == 1 && fake.Requests[0].Operation == "list", "explicit eSIM header refresh checks card and profiles once");
        Check(Find<TextBlock>(window,"EsimCardType").Text == Localization.Translate("Карта: eUICC подтверждена"), "accepted legacy snapshot confirms type");
        Check(Label(window, Localization.Translate("Физическая eUICC")), "localized eSIM heading");
        if(language=="en") Check(Label(window,"Physical eUICC profiles"),"English page subtitle");
        var profiles = Find<ListBox>(window,"EsimProfiles");
        Check(profiles.ItemCount == 2, "active and disabled profile visible");
        var rows = profiles.Items.Cast<string>().ToArray();
        Check(rows[0].Contains(Localization.Translate("Активный")) && rows[1].Contains(Localization.Translate("Отключён")) && rows.All(x => !x.Contains(Fixture.Active.Iccid) && !x.Contains(Fixture.Disabled.Iccid)), "masked localized profile rows");
        profiles.SelectedIndex=0; Pump(); Check(!Find<Button>(window,"EsimDelete").IsEnabled && Find<Button>(window,"EsimEnable").IsEnabled, "active target can reread but cannot delete");
        profiles.SelectedIndex=1; Pump(); Check(Find<Button>(window,"EsimDelete").IsEnabled && Find<Button>(window,"EsimEnable").IsEnabled, "disabled target controls enabled");
        Capture(window,language+"-esim.png");
        Click(window,"EsimDelete"); var dialog=window.OwnedWindows.Single();
        Check(dialog.Title==Localization.Translate("Удалить профиль eSIM без возможности отмены?"),"irreversible confirmation title");
        Capture(dialog,language+"-delete-confirmation.png");
        dialog.GetLogicalDescendants().OfType<Button>().Single(b=>b.Content?.ToString()==Localization.Translate("Отмена")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
        Check(fake.Requests.Count==1,"cancel never mutates");
        Click(window,"EsimDelete"); dialog=window.OwnedWindows.Single();
        dialog.GetLogicalDescendants().OfType<Button>().Single(b=>b.Content?.ToString()==Localization.Translate("Продолжить")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
        Check(fake.Requests.Last().Operation=="delete" && fake.Requests.Last().ConfirmDelete && fake.Requests.Last().Iccid==Fixture.Disabled.Iccid,"confirmed exact selected deletion");
        Check(Find<ListBox>(window,"EsimProfiles").ItemCount==1,"post-delete refresh");
        fake.Current=Fixture.Snapshot; Click(window,"EsimRead"); Find<ListBox>(window,"EsimProfiles").SelectedIndex=1; Pump();
        Click(window,"EsimEnable"); Check(fake.Requests.Last().Operation=="enable", "enable selected disabled profile");
        Find<ComboBox>(window,"EsimInputMode").SelectedIndex=1; Pump();
        var address=Find<TextBox>(window,"EsimSmdpAddress"); var matching=Find<TextBox>(window,"EsimMatchingId");
        Check(address.IsVisible && matching.IsVisible && !Find<TextBox>(window,"EsimActivationCode").IsVisible,"manual fields and explicit input source");
        address.Text="https://example.com:443/"; matching.Text="manual-synthetic"; Pump();
        Check(Find<Button>(window,"EsimDownload").IsEnabled,"manual valid download enabled");
        Capture(window,language+"-esim-manual.png");
        fake.Pending=new(TaskCreationOptions.RunContinuationsAsynchronously);
        var code=Find<TextBox>(window,"EsimActivationCode"); var confirmation=Find<TextBox>(window,"EsimConfirmationCode");
        code.Text="LPA:1$ignored.example$hidden-input"; confirmation.Text="synthetic-confirmation"; Pump();
        Click(window,"EsimDownload");
        Check(code.Text=="" && confirmation.Text=="" && address.Text=="" && matching.Text=="" && !Find<Button>(window,"EsimRead").IsEnabled,"all secrets clear immediately and busy disables operations");
        Check(!Find<Button>(window,"RefreshPage").IsEnabled,"busy disables header refresh");
        int requestsWhileBusy = fake.Requests.Count;
        Find<Button>(window,"RefreshPage").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
        Check(fake.Requests.Count == requestsWhileBusy,"busy header handler cannot add a card request");
        Check(fake.Requests.Last().ActivationCode=="LPA:1$example.com$manual-synthetic","manual selection determines exact request; hidden full code ignored");
        fake.Pending.SetResult(new(false,null,false,false));
        for(int i=0;i<20;i++){ Thread.Sleep(10); Pump(); }
        Check(!Find<Button>(window,"EsimEnable").IsEnabled && !Find<Button>(window,"EsimDelete").IsEnabled,"uncertain result clears authorization");
        Check(Find<TextBlock>(window,"EsimCardType").Text == Localization.Translate("Карта: тип не определён. Повторите проверку."), "failure clears positive card type");
        Check(Find<ListBox>(window,"EsimProfiles").ItemCount == 0, "failed operation clears stale profile snapshot");
        Check(Find<Button>(window,"EsimRead").IsEnabled,"read available after uncertainty");
        fake.Pending = null;
        int requestsBeforeInformation = fake.Requests.Count;
        Click(window,"Navigation7");
        Check(fake.Requests.Count == requestsBeforeInformation,"opening information never checks the card");
        Check(Find<TextBlock>(window,"InformationCardType").Text == Localization.Translate("Карта: тип не определён. Повторите проверку."),"information reflects failed card check as unknown");
        Click(window,"RefreshPage");
        Check(fake.Requests.Count == requestsBeforeInformation + 1 && fake.Requests.Last().Operation == "list","explicit information header refresh checks card once");
        Check(Find<TextBlock>(window,"InformationCardType").Text == Localization.Translate("Карта: eUICC подтверждена"),"information shows validated card type");
        window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate("Память")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
        window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate("Обновить")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
        Check(fake.Requests.Count == requestsBeforeInformation + 2,"explicit RefreshDevice action checks card once after success");
        fake.RefreshSuccess = false;
        window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate("Обновить")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
        Check(fake.Requests.Count == requestsBeforeInformation + 2,"failed information refresh never starts a card check");
        fake.RefreshSuccess = true;
        Click(window,"Navigation8");
        var closingAddress=Find<TextBox>(window,"EsimSmdpAddress"); var closingMatching=Find<TextBox>(window,"EsimMatchingId"); var closingConfirmation=Find<TextBox>(window,"EsimConfirmationCode");
        closingAddress.Text="example.com"; closingMatching.Text="unsubmitted-test"; closingConfirmation.Text="confirmation-test";
        window.Close(); Pump();
        Check(closingAddress.Text=="" && closingMatching.Text=="" && closingConfirmation.Text=="","window close clears unsubmitted eSIM fields");
        }
        finally { window.Close(); Pump(); }
    }
    Localization.SetLanguage("ru",persist:false);
},CancellationToken.None);
Pass("RU/EN real eSIM UI: masked active/disabled rows, confirmation, enable, secret clearing, uncertainty");
File.WriteAllText(Path.Combine(resultDir,"test-result.json"),JsonSerializer.Serialize(new { schemaVersion=1, ok=true, groups=passed, noDevice=true, runtime=System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier, actualWindowsRuntime=false },new JsonSerializerOptions{WriteIndented=true})+"\n");
return 0;

sealed class ImmediateProgress(Action<string> action) : IProgress<string> { public void Report(string value)=>action(value); }
public sealed class SmokeApp : Application
{
    public static AppBuilder BuildAvaloniaApp()=>AppBuilder.Configure<SmokeApp>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions{UseHeadlessDrawing=false});
    public override void Initialize()=>App.ConfigureTheme(this);
}
static class Fixture
{
    public static readonly EsimProfile Active=new("8900000000000000001","A0000005591010FFFFFFFF890000000001","enabled",true,null,"Example operator","Travel active");
    public static readonly EsimProfile Disabled=new("8900000000000000002","A0000005591010FFFFFFFF890000000002","disabled",false,null,"Example operator","Travel spare");
    public static readonly EsimProfile Added=new("8900000000000000003","A0000005591010FFFFFFFF890000000003","disabled",false,null,"Example operator","New profile");
    public static EsimSnapshot Snapshot=>new(true,new string('9',32),[Active,Disabled]);
}
sealed class FakeModem : IModemService
{
    public EsimSnapshot Current=Fixture.Snapshot;
    public List<EsimRequest> Requests=[];
    public bool RefreshSuccess = true;
    public TaskCompletionSource<EsimResult>? Pending;
    public Task<EsimResult> RunEsimAsync(EsimRequest request,IProgress<string>? progress,CancellationToken ct=default)
    {
        Requests.Add(request); progress?.Report("verifying");
        if(Pending is not null)return Pending.Task;
        if(request.Operation=="delete")Current=Current with{Profiles=Current.Profiles.Where(p=>p.Iccid!=request.Iccid).ToArray()};
        if(request.Operation=="enable")Current=Current with{Profiles=Current.Profiles.Select(p=>p with{State=p.Iccid==request.Iccid?"enabled":"disabled",Enabled=p.Iccid==request.Iccid}).ToArray()};
        return Task.FromResult(new EsimResult(true,Current,request.Operation!="list",false, ModemVerified:request.Operation=="enable", RadioRestored:request.Operation=="enable"));
    }
    public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct=default)=>Task.FromResult(new DeviceSnapshot(true,"Подключено",Model:"ZTE U60 Pro",Firmware:"MU5250 B31",Serial:"synthetic-device",IpAddress:"192.168.0.1",ConnectionMode:"SSH"));
    public Task<OperationResult> RunAsync(OperationRequest request,CancellationToken ct=default)=>Task.FromResult(new OperationResult(RefreshSuccess,"Состояние обновлено."));
    public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<BackupInfo>>([]);
    public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<ModemAppInfo>>([]);
    public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<LogEntry>>([]);
    public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct=default)=>throw new NotSupportedException();
}
