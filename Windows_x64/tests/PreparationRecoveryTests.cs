using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class PreparationRecoveryTests
{
    private const string Cid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Boot = "11111111-1111-1111-1111-111111111111";
    private static readonly WebIdentity B31 = new("353490068701222", "CN_ZTE_MU5250V1.0.0B31", "BD_CNMU5250V1.0.0B31");
    private sealed class Boundary : Exception { }
    private sealed class FailingWeb(Exception error, bool authenticated = false) : IWebTransport
    {
        internal int Calls;
        public Task<WebReply> RequestAsync(string path, byte[]? data = null, string? contentType = null, string? cookie = null, CancellationToken ct = default)
        {
            Calls++;
            if (authenticated && Calls <= 2)
            {
                object value = Calls == 1 ? new { zte_web_sault = "fixture-salt" } : (object)new { result = 0, ubus_rpc_session = "1234567890abcdef1234567890abcdef" };
                return Task.FromResult(new WebReply(JsonSerializer.SerializeToUtf8Bytes(new[] { new { result = new object[] { 0, value } } }),
                    new Dictionary<string,string[]> { ["Set-Cookie"] = ["webtoken=fixture; Path=/"] }));
            }
            throw error;
        }
    }
    internal static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "zte-preparation-recovery-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        var passed = 0;
        void Check(bool ok, string text) { if (!ok) throw new Exception("FAIL " + text); passed++; Console.WriteLine("PASS " + text); }
        try
        {
            foreach (var scenario in new[] { "socket", "timeout", "http", "saved-identity", "no-usb", "multiple-usb", "wrong-usb", "wrong-password", "http-forbidden", "malformed", "post-login-missing-info", "cancelled" })
            {
                var folder = Path.Combine(root, scenario); Directory.CreateDirectory(folder);
                var backup = Path.Combine(folder, "SetupBackups", Guid.NewGuid().ToString()); Directory.CreateDirectory(backup);
                if (scenario is "saved-identity" or "wrong-usb")
                    await File.WriteAllTextAsync(Path.Combine(folder, "setup-pending.json"), JsonSerializer.Serialize(new OnboardingPending
                    {
                        Id = Guid.NewGuid().ToString(), WebIdentity = B31, IdentitySource = "web-matched", BackupDirectory = backup,
                        Cid = Cid, FirmwareHash = ImeiEngine.FirmwareHash, RouterHash = ImeiEngine.RouterHash, BootId = Boot, Profile = "b31",
                    }));
                Exception failure = scenario switch
                {
                    "timeout" => new TimeoutException("fixture"),
                    "http" => new ModemWebException(WebFailureKind.Transport, "fixture", 503),
                    "wrong-password" => new ModemWebException(WebFailureKind.InvalidPassword, "fixture"),
                    "http-forbidden" => new ModemWebException(WebFailureKind.Transport, "fixture", 403),
                    "malformed" or "post-login-missing-info" => new ModemWebException(WebFailureKind.MalformedResponse, "fixture"),
                    "cancelled" => new OperationCanceledException(),
                    _ => new HttpRequestException("fixture", new SocketException((int)SocketError.AccessDenied)),
                };
                var web = new FailingWeb(failure, scenario == "post-login-missing-info"); var adbCalls = 0; var nonReadCommands = 0; var log = new List<string>();
                var adb = new AdbTransport((arguments, stream, _, _) =>
                {
                    adbCalls++;
                    if (arguments[0] == "devices") return Task.FromResult(Reply(scenario == "no-usb" ? "List of devices attached\n" : scenario == "multiple-usb" ? "one device usb:1\ntwo device usb:2\n" : "one device usb:1\n"));
                    if (arguments[0] == "-d") return Task.FromResult(Reply("one\n"));
                    var command = stream?.OriginalCommand ?? arguments[^1];
                    if (!command.Contains("observed_hash()", StringComparison.Ordinal)) { nonReadCommands++; throw new Exception("Unexpected mutation"); }
                    var marker = stream?.Result ?? Regex.Match(command, "__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix = stream is null ? "" : "\n" + stream.Ready + "\n\n" + stream.Begin + "\n";
                    var identity = (scenario == "post-login-missing-info" ? "absent" : ImeiEngine.FirmwareHash) + "  /firmware/image/modem.b16\n" + ImeiEngine.RouterHash + "  /usr/bin/diag-router\n" + (scenario == "wrong-usb" ? new string('b', 32) : Cid) + "\n" + Boot;
                    if (command.Contains("ubus call", StringComparison.Ordinal)) identity += "\n" + JsonSerializer.Serialize(new { imei = B31.Imei, integrate_version = B31.Firmware, wa_inner_version = B31.Inner });
                    return Task.FromResult(Reply(prefix + identity + "\n" + marker + "0\n"));
                }, Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine = new OnboardingEngine("192.0.2.1", folder, Path.GetFullPath("Windows_x64/Resources"), adb, progress: message =>
                {
                    log.Add(message);
                    if (message.StartsWith("USB ADB подтверждён:", StringComparison.Ordinal) && scenario != "wrong-usb") throw new Boundary();
                }) { WebFactory = () => new ModemWebClient("192.0.2.1", web) };
                var reached = false; Exception? actual = null;
                try { await engine.PrepareAsync("synthetic-password", "synthetic-agent-password", "", forceReinstall: true); }
                catch (Boundary) { reached = true; }
                catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException or OperationCanceledException) { actual = error; }
                var shouldReach = scenario is "socket" or "timeout" or "http" or "saved-identity" or "post-login-missing-info";
                Check(reached == shouldReach, "Web unavailable preparation boundary: " + scenario + (reached == shouldReach ? "" : " actual=" + actual?.ToString() + " calls=" + web.Calls));
                Check(nonReadCommands == 0 && web.Calls == (scenario == "post-login-missing-info" ? 3 : 1) && !Directory.Exists(Path.Combine(folder, "SSH")), "No premature installer, keygen or Web retry: " + scenario);
                if (scenario is "wrong-password" or "http-forbidden" or "malformed" or "cancelled")
                    Check(adbCalls == 0 && ReferenceEquals(actual, failure), "Authentication, malformed replies and cancellation do not become USB fallback: " + scenario);
                if (shouldReach)
                {
                    var saved = JsonSerializer.Deserialize<OnboardingPending>(await File.ReadAllTextAsync(Path.Combine(folder, "setup-pending.json")))!;
                    Check(saved.IdentitySource == (scenario == "saved-identity" ? "web-matched" : "single-usb") && saved.WebIdentity == (scenario == "saved-identity" ? B31 : null), "Independent USB preserves identity provenance: " + scenario);
                }
                if (scenario == "no-usb") Check(actual?.Message.Contains("брандмауэр", StringComparison.Ordinal) == true && actual.Message.Contains("USB", StringComparison.Ordinal), "Combined Web firewall and USB failure identifies both unavailable methods");
                Check(!string.Join('\n', log).Contains("synthetic-password", StringComparison.Ordinal), "Progress does not disclose Web password: " + scenario);
            }
            foreach (var scenario in new[] { "not-started", "uncertain", "changed-cid", "changed-after-proof", "malformed-proof" })
            {
                var folder = Path.Combine(root, "resume-" + scenario); Directory.CreateDirectory(folder);
                var id = Guid.NewGuid().ToString();
                var backup = Path.Combine(folder, "SetupBackups", id); Directory.CreateDirectory(backup);
                await File.WriteAllTextAsync(Path.Combine(backup, "original.fixture"), "preserved");
                var pendingPath = Path.Combine(folder, "setup-pending.json");
                var stage = "/data/zte-imei-studio/stage-" + id;
                var old = new OnboardingPending
                {
                    Id = id, WebIdentity = B31, IdentitySource = "web-matched", BackupDirectory = backup, Cid = Cid,
                    FirmwareHash = ImeiEngine.FirmwareHash, RouterHash = ImeiEngine.RouterHash, BootId = Boot, Profile = "b31",
                    InstallRequested = true, Phase = "install-requested", RemoteStage = stage,
                    RemoteJournal = "/data/zte-imei-studio/installations/" + id,
                };
                var original = JsonSerializer.Serialize(old); await File.WriteAllTextAsync(pendingPath, original);
                var verification = 0; var reads = 0; var mutations = 0; var reached = false;
                var adb = new AdbTransport((arguments, stream, _, _) =>
                {
                    if (arguments[0] == "devices") return Task.FromResult(Reply("one device usb:1\n"));
                    if (arguments[0] == "-d") return Task.FromResult(Reply("one\n"));
                    var command = stream?.OriginalCommand ?? arguments[^1];
                    var marker = stream?.Result ?? Regex.Match(command, "__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix = stream is null ? "" : "\n" + stream.Ready + "\n\n" + stream.Begin + "\n";
                    string body; var code = 0;
                    if (command.Contains(" -- '--verify-not-started' ", StringComparison.Ordinal))
                    {
                        verification++;
                        Check(command.StartsWith("sh -c ", StringComparison.Ordinal) && command.Contains("INSTALL_NOT_STARTED", StringComparison.Ordinal), "Recovery executes current bundled verification helper, not staged installer: " + scenario);
                        body = scenario == "malformed-proof" ? "unverified" : "INSTALL_NOT_STARTED " + stage;
                        if (scenario == "uncertain") code = 1;
                    }
                    else if (command.Contains("observed_hash()", StringComparison.Ordinal))
                    {
                        reads++;
                        body = ImeiEngine.FirmwareHash + "  /firmware/image/modem.b16\n" + ImeiEngine.RouterHash + "  /usr/bin/diag-router\n" +
                            (scenario == "changed-cid" || scenario == "changed-after-proof" && reads > 1 ? new string('b', 32) : Cid) + "\n" + Boot;
                        if (command.Contains("ubus call", StringComparison.Ordinal)) body += "\n" + JsonSerializer.Serialize(new { imei = B31.Imei, integrate_version = B31.Firmware, wa_inner_version = B31.Inner });
                    }
                    else if(command.Contains(" -- '--clean-reinstall' '--recover-owned' ",StringComparison.Ordinal))
                    { body="INSTALL_ERROR CLEAN_RECOVERY_UNPROVEN";code=1; }
                    else { mutations++; throw new Exception("Unexpected mutation during intent verification"); }
                    return Task.FromResult(Reply(prefix + body + "\n" + marker + code + "\n"));
                }, Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var wire = new FailingWeb(new HttpRequestException("fixture"));
                var engine = new OnboardingEngine("192.0.2.1", folder, Path.GetFullPath("Windows_x64/Resources"), adb, progress: text =>
                {
                    if (text.StartsWith("USB ADB подтверждён:", StringComparison.Ordinal)) throw new Boundary();
                }) { WebFactory = () => new ModemWebClient("192.0.2.1", wire) };
                try { await engine.PrepareAsync("synthetic-password", "synthetic-agent-password", "", forceReinstall: true, cleanComponents: true); }
                catch (Boundary) { reached = true; }
                catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException) { }
                var recovered = scenario == "not-started";
                Check(reached == recovered && verification == (scenario == "changed-cid" ? 0 : 1), "Only exact unstarted proof resumes requested clean reinstall: " + scenario);
                Check(File.Exists(Path.Combine(backup, "setup-not-started-" + id + ".json")) == recovered && File.Exists(Path.Combine(backup, "not-started-verification.txt")) == recovered, "Only verified unstarted intent is archived with proof: " + scenario);
                Check(mutations == 0 && await File.ReadAllTextAsync(Path.Combine(backup, "original.fixture")) == "preserved", "Recovery preserves backups and performs no remote mutations: " + scenario);
                if (recovered)
                {
                    var next = JsonSerializer.Deserialize<OnboardingPending>(await File.ReadAllTextAsync(pendingPath))!;
                    Check(next.Id != id && next.ForceReinstall && next.CleanComponents && !next.InstallRequested, "New attempt honors explicit force and clean options after stale intent is proven unstarted");
                }
                else Check(await File.ReadAllTextAsync(pendingPath) == original, "Unknown or changed-device pending intent stays byte-identical: " + scenario);
            }
            foreach (var state in new[] { "MISSING", "UNREADABLE", "UNEXPECTED_TYPE", "EMPTY", "INVALID_CONTENT", "malformed", "forged", "transport" })
            {
                var folder = Path.Combine(root, "state-diagnostic-" + state); Directory.CreateDirectory(folder);
                var id = Guid.NewGuid().ToString(); var backup = Path.Combine(folder, "SetupBackups", id); Directory.CreateDirectory(backup);
                var path = Path.Combine(folder, "setup-pending.json");
                var pending = new OnboardingPending { Id=id, WebIdentity=B31, IdentitySource="web-matched", BackupDirectory=backup,
                    Cid=Cid, FirmwareHash=ImeiEngine.FirmwareHash, RouterHash=ImeiEngine.RouterHash, BootId=Boot, AdbSerial="one", Profile="b31",
                    Intent="preparation", InstallRequested=true, Phase="install-requested", RemoteStage="/data/zte-imei-studio/stage-"+id,
                    RemoteJournal="/data/zte-imei-studio/installations/"+id };
                var original = JsonSerializer.Serialize(pending); await File.WriteAllTextAsync(path, original);
                await File.WriteAllTextAsync(Path.Combine(backup, "original.fixture"), "preserved");
                var verification=0; var stateReads=0; var mutations=0;
                var adb = new AdbTransport((arguments, stream, _, _) =>
                {
                    if (arguments[0]=="devices") return Task.FromResult(Reply("one device usb:1\n"));
                    if (arguments[0]=="-d") return Task.FromResult(Reply("one\n"));
                    var command=stream?.OriginalCommand ?? arguments[^1];
                    var marker=stream?.Result ?? Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix=stream is null ? "" : "\n"+stream.Ready+"\n\n"+stream.Begin+"\n";
                    string body; var code=0;
                    if (command.Contains("'--verify-not-started'")) { verification++;body="INSTALL_ERROR RECOVERY_PENDING_OWN_LOCK\nsynthetic-private-content";code=1; }
                    else if (command.Contains("ZTE_INSTALL_STATE_PROBE")) { stateReads++;body=state=="malformed"?"synthetic-private-content":state=="forged"?"INSTALL_STATE ready\nsynthetic-private-content":"INSTALL_STATE "+state;code=state=="transport"?1:0; }
                    else if (command.Contains("observed_hash()")) {
                        body=ImeiEngine.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+Boot;
                        if(command.Contains("ubus call"))body+="\n"+JsonSerializer.Serialize(new{imei=B31.Imei,integrate_version=B31.Firmware,wa_inner_version=B31.Inner});
                    } else { mutations++;throw new Exception("Unexpected mutation during recovery diagnosis"); }
                    return Task.FromResult(Reply(prefix+body+"\n"+marker+code+"\n"));
                },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",folder,Path.GetFullPath("Windows_x64/Resources"),adb)
                    {WebFactory=()=>new ModemWebClient("192.0.2.1",new FailingWeb(new HttpRequestException("fixture")))};
                string failure="";
                try { await engine.PrepareAsync("synthetic-password","synthetic-agent-password",""); }
                catch (IOException error) { failure=error.Message; }
                var expected=state is "malformed" or "forged"?"PROBE_INVALID":state=="transport"?"PROBE_FAILED":state;
                Check(failure.Contains("STATE_"+expected)&&failure.Contains("RECOVERY_PENDING_OWN_LOCK"),"Both recovery diagnostic stages remain visible: "+state);
                Check(!failure.Contains("synthetic-private-content"),"Recovery errors contain no arbitrary output: "+state);
                Check(verification==1&&stateReads==1&&mutations==0&&!Directory.Exists(Path.Combine(folder,"SSH")),"State diagnostics are read-only with no installer replay: "+state);
                Check(await File.ReadAllTextAsync(path)==original&&await File.ReadAllTextAsync(Path.Combine(backup,"original.fixture"))=="preserved", "Failed diagnosis preserves pending bytes and backup: "+state);
            }
            foreach (var scenario in new[] { "before-dispatch", "dispatched-reset", "same-boot-dispatched", "native-b31-dispatched", "wrong-receipt-dispatched", "changed-proof-dispatched", "local-changed-dispatched", "lost-reply-dispatched", "wrong-cid", "changed-second-read", "cleanup-timeout", "cleanup-socket" })
            {
                var folder = Path.Combine(root, "reset-" + scenario); Directory.CreateDirectory(folder);
                var id = Guid.NewGuid().ToString(); var backup = Path.Combine(folder,"SetupBackups",id); Directory.CreateDirectory(backup);
                var dispatched = scenario.Contains("dispatched",StringComparison.Ordinal) || scenario.StartsWith("cleanup-",StringComparison.Ordinal);
                var old = new OnboardingPending { Id=id, BackupDirectory=backup, IdentitySource="single-usb", Intent="linux-arm64-access",
                    Cid=Cid, FirmwareHash="absent", RouterHash=ImeiEngine.RouterHash, Profile="linux-arm64-access", AdbSerial="one",
                    BootId=scenario=="same-boot-dispatched"?Boot:"22222222-2222-2222-2222-222222222222", Phase=scenario.StartsWith("cleanup-",StringComparison.Ordinal)?"complete":dispatched?"install-requested":"adb-ready", InstallRequested=dispatched, ForceReinstall=scenario.StartsWith("cleanup-",StringComparison.Ordinal), CleanComponents=scenario.StartsWith("cleanup-",StringComparison.Ordinal) };
                if (dispatched) { old.RemoteStage="/data/zte-imei-studio/stage-"+id; old.RemoteJournal="/data/zte-imei-studio/installations/"+id; }
                if (scenario=="native-b31-dispatched") { old.WebIdentity=B31;old.IdentitySource="web-matched";old.Intent="preparation";old.Profile="b31";old.FirmwareHash=ImeiEngine.FirmwareHash;old.BootId=Boot; }
                var path=Path.Combine(folder,"setup-pending.json"); var original=JsonSerializer.Serialize(old); await File.WriteAllTextAsync(path,original);
                if(scenario.StartsWith("cleanup-",StringComparison.Ordinal))
                {
                    old.RemoteStage="/data/zte-imei-studio/stage-"+id;old.RemoteJournal="/data/zte-imei-studio/installations/"+id;
                    original=JsonSerializer.Serialize(old);await File.WriteAllTextAsync(path,original);
                    var plan=new ComponentCleanupPending {Id=id,Cid=Cid,BootId=old.BootId!,FirmwareHash="absent",RouterHash=ImeiEngine.RouterHash,Host="192.0.2.1",KeyPath=Path.Combine(folder,"SSH/id_ed25519"),KnownHostsPath=Path.Combine(folder,"SSH/known_hosts"),BackupDirectory=backup,SetupReceipt=Path.Combine(backup,"setup-result.json"),Profile="linux-arm64-access",Token=Guid.NewGuid().ToString()};
                    await File.WriteAllTextAsync(Path.Combine(folder,OnboardingEngine.CleanupPendingName),JsonSerializer.Serialize(plan));
                }
                var reads=0;var preflights=0;var boundary=false;var recoveryCalls=0;var changedAfterProof=false;string? changedLocal=null;
                var adb=new AdbTransport((arguments,stream,_,_)=>
                {
                    if(arguments[0]=="devices")return Task.FromResult(Reply("one device usb:1\n"));
                    if(arguments[0]=="-d")return Task.FromResult(Reply("one\n"));
                    var command=stream?.OriginalCommand??arguments[^1];var marker=stream?.Result??Regex.Match(command,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    var prefix=stream is null?"":"\n"+stream.Ready+"\n\n"+stream.Begin+"\n";string body;var code=0;
                    if(command.Contains("'--recover-owned'",StringComparison.Ordinal))
                    {
                        recoveryCalls++;Check(command.Contains(" -- '--clean-reinstall' '--recover-owned' '"+id+"' ",StringComparison.Ordinal),"Recovery is bound to exact pending ID: "+scenario);
                        body="INSTALL_RECOVERY_ARCHIVED /data/zte-imei-studio/installations/"+(scenario=="wrong-receipt-dispatched"?Guid.NewGuid().ToString():id);
                        changedAfterProof=scenario=="changed-proof-dispatched";
                        if(scenario=="local-changed-dispatched") {changedLocal=original+"\n";File.WriteAllText(path,changedLocal);}
                        if(scenario=="lost-reply-dispatched"&&recoveryCalls==1)throw new IOException("synthetic lost receipt");
                    }
                    else if(command.Contains("'--preflight'",StringComparison.Ordinal))
                    {
                        preflights++;Check(command.Contains(" -- '--clean-reinstall' '--preflight' ",StringComparison.Ordinal),"New attempt uses explicit clean helper: "+scenario);
                        throw new Boundary();
                    }
                    else if(command.Contains("'--verify-not-started'",StringComparison.Ordinal)){body="INSTALL_ERROR INSTALLATION_STARTED";code=1;}
                    else if(command.Contains("observed_hash()",StringComparison.Ordinal))
                    {
                        reads++;body=old.FirmwareHash+"  /firmware/image/modem.b16\n"+ImeiEngine.RouterHash+"  /usr/bin/diag-router\n"+
                            (scenario=="wrong-cid"||scenario=="changed-second-read"&&reads>1||changedAfterProof?new string('b',32):Cid)+"\n"+Boot;
                        if(command.Contains("ubus call",StringComparison.Ordinal))body+="\n"+JsonSerializer.Serialize(new {imei=B31.Imei,integrate_version=B31.Firmware,wa_inner_version=B31.Inner});
                    }
                    else throw new Exception("Unexpected reset mutation: "+command);
                    return Task.FromResult(Reply(prefix+body+"\n"+marker+code+"\n"));
                },Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh"));
                var engine=new OnboardingEngine("192.0.2.1",folder,Path.GetFullPath("Windows_x64/Resources"),adb){WebFactory=()=>new ModemWebClient("192.0.2.1",new FailingWeb(new HttpRequestException("fixture"))),CleanupSshFactory=()=>new ResetSshFailure(scenario=="cleanup-timeout"?new TimeoutException("SSH fixture timeout"):new SocketException((int)SocketError.ConnectionRefused))};
                try{await engine.PrepareAsync("","synthetic-new-password","",cleanComponents:true);}
                catch(Boundary){boundary=true;}
                catch(Exception error) when(error is IOException or InvalidDataException or InvalidOperationException){}
                if(scenario=="lost-reply-dispatched")
                {
                    Check(await File.ReadAllTextAsync(path)==original,"Lost receipt preserves pending intent");
                    try{await engine.PrepareAsync("","synthetic-new-password","",cleanComponents:true);}
                    catch(Boundary){boundary=true;}
                }
                var accepted=scenario is "before-dispatch" or "dispatched-reset" or "same-boot-dispatched" or "native-b31-dispatched" or "lost-reply-dispatched" or "cleanup-timeout" or "cleanup-socket";
                Check(boundary==accepted,"Only same-device reset resumes clean setup: "+scenario);
                if(accepted)
                {
                    var next=JsonSerializer.Deserialize<OnboardingPending>(await File.ReadAllTextAsync(path))!;
                    Check(next.Id!=id&&next.BootId==Boot&&next.CleanComponents&&next.ForceReinstall&&!next.InstallRequested,"New reset attempt owns fresh stage and explicit clean mode: "+scenario);
                    var histories=Directory.GetFiles(backup,"setup-before-*.json");Check(histories.Length==1&&await File.ReadAllTextAsync(histories[0])==original,"Reset keeps exact old local journal: "+scenario);
                }
                else Check(await File.ReadAllTextAsync(path)==(changedLocal??original)&&preflights==0,"Unverified archival retains local journal and does not install: "+scenario);
            }
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine($"RESULT {passed} preparation recovery checks; synthetic transports, no device");
    }
    private sealed class ResetSshFailure(Exception error) : IRemoteShell
    {
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)=>throw error;
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw error;
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw error;
    }
    private static RemoteResult Reply(string value) => new(0, Encoding.UTF8.GetBytes(value), []);
}
