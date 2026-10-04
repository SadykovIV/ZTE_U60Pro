using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Threading;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

const string previousAgent = "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19";
const string previousHelper = "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231";
var storage = Path.Combine(Path.GetTempPath(), "zte-vpn-fixtures-" + Guid.NewGuid());
Directory.CreateDirectory(storage);
int passed = 0, failed = 0;
void Check(bool value) { if (!value) throw new Exception("Assertion failed"); }
async Task Test(string name, Func<Task> work)
{
    try { await work(); Console.WriteLine("PASS " + name); passed++; }
    catch (Exception e) { Console.WriteLine("FAIL " + name + " (" + e.GetType().Name + ")"); failed++; }
}
DeviceFeatureService Service(Shell shell) => new(shell, Path.GetFullPath("Windows_x64/Resources"), storage);
async Task<string> Rejected(Func<Task> work)
{
    try { await work(); }
    catch (DeviceFeatureException e) { Check(!e.Message.Contains("PRIVATE", StringComparison.Ordinal)); return e.Message; }
    throw new Exception("Expected a fixed feature error");
}
try
{
    await Test("Frozen local .8 is recognized and explicitly upgradeable", () =>
    {
        Check(AgentPackage.VersionForHash(previousAgent) == "2.7.0-esim.8");
        Check(AgentPackage.SupportsVpn(previousAgent) && AgentPackage.SupportedUpgradeHashes.Contains(previousAgent));
        Check(!AgentPackage.SupportedUpgradeHashes.Contains(new string('f', 64)));
        return Task.CompletedTask;
    });
    foreach (var helper in new[] { previousHelper, "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4", "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca" })
        await Test("Pinned historical controller status-only " + helper[..8], async () =>
        {
            var shell = new Shell { Helper = helper, Agent = previousAgent };
            var state = await Service(shell).GetVpnStatusAsync();
            Check(state.Installed && !state.HelperReady && state.AgentReady && state.Configured && state.Enabled && state.Profiles.Count == 1);
            Check(shell.Requests.SequenceEqual(new[] { "status" }));
            Check(shell.Commands.Single(c => c.EndsWith("/vpnctl request")).Contains(helper, StringComparison.Ordinal));
            await Rejected(() => Service(shell).SetVpnEnabledAsync(true));
            Check(shell.Requests.All(x => x == "status") && shell.Uploads == 0);
        });
    await Test("Unknown controller never executes", async () =>
    {
        var shell = new Shell { Helper = new string('f', 64) };
        Check(!(await Service(shell).GetVpnStatusAsync()).HelperReady && shell.Requests.Count == 0);
    });
    await Test("Current controller stays ready", async () =>
    {
        var shell = new Shell();
        Check((await Service(shell).GetVpnStatusAsync()).HelperReady && shell.Requests.SequenceEqual(new[] { "status" }));
    });
    await Test("Guard rejection is classified before hostile JSON or stderr", async () =>
    {
        var shell = new Shell { RequestReply = new(72, Encoding.UTF8.GetBytes("PRIVATE invalid json"), Encoding.UTF8.GetBytes("VPN_GUARD_REFUSED\n")) };
        var error = await Rejected(() => Service(shell).GetVpnStatusAsync());
        Check(error.Contains("VPN_GUARD_REFUSED", StringComparison.Ordinal) && shell.Requests.Count == 1);
    });
    await Test("Nonzero controller response is not parsed or leaked", async () =>
    {
        var shell = new Shell { RequestReply = new(7, Encoding.UTF8.GetBytes("PRIVATE invalid json"), Encoding.UTF8.GetBytes("PRIVATE stderr secret")) };
        var error = await Rejected(() => Service(shell).GetVpnStatusAsync());
        Check(error.Contains("VPN_CONTROLLER_FAILED", StringComparison.Ordinal) && shell.Requests.Count == 1);
    });
    foreach (var exit in new[] { 0, 1 })
        await Test("Known structured refusal survives exit " + exit + " without raw details", async () =>
        {
            var shell = new Shell { RequestReply = Shell.Reply("{\"ok\":false,\"code\":\"VPN_BUSY\",\"detail\":\"PRIVATE\"}", exit) };
            Check((await Rejected(() => Service(shell).GetVpnStatusAsync())).Contains("VPN_BUSY", StringComparison.Ordinal));
            shell = new Shell { RequestReply = Shell.Reply("{\"ok\":false,\"code\":\"VPN_PRIVATE_TOKEN\"}", exit) };
            Check((await Rejected(() => Service(shell).GetVpnStatusAsync())).Contains("VPN_CONTROLLER_FAILED", StringComparison.Ordinal));
        });
    await Test("Actual emitted guard rejects unsafe layout or hash before executing controller", async () =>
    {
        var shell = new Shell(); await Service(shell).GetVpnStatusAsync();
        var dir = Path.Combine(storage, "controller"); Directory.CreateDirectory(dir);
        var marker = Path.Combine(storage, "controller-executed");
        var controller = Path.Combine(dir, "vpnctl");
        await File.WriteAllTextAsync(controller, "#!/bin/sh\nprintf executed > '" + marker + "'\n");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(controller, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var command = shell.Commands.Single(c => c.EndsWith("/vpnctl request", StringComparison.Ordinal)).Replace("/data/zte-vpn", dir, StringComparison.Ordinal);
        foreach (var scenario in new[] { "good", "mode", "hash", "file-link", "directory-link" })
        {
            File.Delete(marker);
            var realFile = controller + ".real"; var alias = dir + "-link";
            if (scenario == "file-link") { File.Move(controller, realFile); File.CreateSymbolicLink(controller, realFile); }
            if (scenario == "directory-link") Directory.CreateSymbolicLink(alias, dir);
            var body = scenario == "directory-link" ? command.Replace(dir, alias, StringComparison.Ordinal) : command;
            var functions = "stat() { printf '%s\\n' '" + (scenario == "mode" ? "0:777" : "0:700") + "'; }; sha256sum() { printf '%s  fixture\\n' '" + (scenario == "hash" ? new string('f', 64) : shell.Helper) + "'; }; ";
            var start = new System.Diagnostics.ProcessStartInfo("/bin/sh") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
            start.ArgumentList.Add("-c"); start.ArgumentList.Add(functions + body);
            using var process = System.Diagnostics.Process.Start(start)!;
            var output = await process.StandardOutput.ReadToEndAsync(); var error = await process.StandardError.ReadToEndAsync(); await process.WaitForExitAsync();
            Check(scenario == "good" ? process.ExitCode == 0 && File.Exists(marker) : process.ExitCode == 72 && !File.Exists(marker) && output.Length == 0 && error == "VPN_GUARD_REFUSED\n");
            if (scenario == "file-link") { File.Delete(controller); File.Move(realFile, controller); }
            if (scenario == "directory-link") Directory.Delete(alias);
        }
    });
    foreach (var payload in new[] { "", "PRIVATE invalid json", "[]", "{\"ok\":true,\"data\":[]}", "{\"ok\":true,\"data\":{\"schema_version\":\"PRIVATE\"}}", "{\"ok\":false,\"code\":\"PRIVATE\"}" })
        await Test("Malformed/rejected controller reply remains fixed " + payload.Length, async () =>
        {
            var shell = new Shell { RequestReply = Shell.Reply(payload) };
            await Rejected(() => Service(shell).GetVpnStatusAsync());
            Check(shell.Requests.Count == 1);
        });
    foreach (var field in new[] { "enabled", "configured", "core_running", "profiles", "settings_supported", "active", "missing-enabled" })
        await Test("Invalid status field refuses before Wi-Fi mutation: " + field, async () =>
        {
            var data = JsonNode.Parse("{\"schema_version\":1,\"configured\":true,\"enabled\":false,\"core_running\":false,\"settings_supported\":true,\"profiles\":[{\"id\":\"fixture\",\"name\":\"Synthetic\",\"transport\":\"vless\",\"active\":true}]}")!.AsObject();
            if (field == "missing-enabled") data.Remove("enabled");
            else if (field == "active") data["profiles"]![0]!["active"] = "PRIVATE";
            else data[field] = "PRIVATE";
            var shell = new Shell { RequestReply = Shell.Reply(new JsonObject { ["ok"] = true, ["data"] = data }.ToJsonString()) };
            Check((await Rejected(() => Service(shell).ConfigureVpnWifiAsync("Synthetic", VpnPasswordMode.Main))).Contains("VPN_REPLY_INVALID", StringComparison.Ordinal));
            Check(shell.Commands.Count == 2 && shell.Requests.SequenceEqual(new[] { "status" }) && shell.Uploads == 0);
        });
    await Test("Historical agent can reach readonly update preflight despite old controller", async () =>
    {
        var shell = new Shell { Agent = previousAgent, Helper = previousHelper };
        await Rejected(() => Service(shell).InstallVpnAsync());
        Check(shell.Preflights == 1 && shell.Uploads > 0 && shell.InstallCalls == 0 && shell.Commands.Any(c => c.Contains("rm -f", StringComparison.Ordinal)));
    });
    await Test("Unknown agent refuses before staging or controller update", async () =>
    {
        var shell = new Shell { Agent = new string('f', 64) };
        await Rejected(() => Service(shell).InstallVpnAsync());
        Check(shell.Preflights == 0 && shell.Uploads == 0 && shell.InstallCalls == 0);
    });
    await Test("Unknown firmware refuses mutation before remote lock", async () =>
    {
        var shell = new Shell { Firmware = new string('f', 64) };
        await Rejected(() => Service(shell).InstallVpnAsync());
        Check(shell.Commands.Count == 1 && shell.Uploads == 0);
    });
    await Test("Existing pending journal refuses before all remote calls", async () =>
    {
        var pending = Path.Combine(storage, "setup-pending.json");
        await File.WriteAllTextAsync(pending, "{}");
        try { var shell = new Shell(); await Rejected(() => Service(shell).InstallVpnAsync()); Check(shell.Commands.Count == 0); }
        finally { File.Delete(pending); }
    });
    await Test("VPN guard failure preserves established SSH snapshot and transport", async () =>
    {
        // Construct only the state needed by the actual service dispatch. Avoid its
        // constructor reading the user's saved connection or creating an SSH client.
        var service = (WindowsModemService)System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(WindowsModemService));
        var ssh = (SshTransport)System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(SshTransport));
        void Set(string name, object value) => typeof(WindowsModemService).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(service, value);
        Set("_operation", new SemaphoreSlim(1, 1)); Set("_logs", new List<LogEntry>()); Set("_storage", storage);
        Set("_ssh", ssh); Set("_imei", System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(ImeiEngine)));
        Set("_features", Service(new Shell { RequestReply = new(72, [], Encoding.UTF8.GetBytes("VPN_GUARD_REFUSED\n")) }));
        Set("_snapshot", new DeviceSnapshot(true, "Подключено по SSH", ConnectionMode: "SSH"));
        var result = await service.RunAsync(new OperationRequest(ModemOperation.RefreshVpn));
        var snapshot = await service.GetDeviceSnapshotAsync();
        Check(!result.Success && result.Message.Contains("VPN_GUARD_REFUSED", StringComparison.Ordinal));
        Check(snapshot.IsConnected && snapshot.ConnectionMode == "SSH" && ReferenceEquals(ssh, typeof(WindowsModemService).GetField("_ssh", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(service)));
    });
    using var session = HeadlessUnitTestSession.StartNew(typeof(TestApp));
    await Test("VPN navigation and component update remain available with old status", async () =>
    {
        await session.Dispatch(() =>
        {
            var window = new MainWindow(new FakeModem(), persistPreferences: false); window.Show(); Dispatcher.UIThread.RunJobs();
            typeof(MainWindow).GetField("_snapshot", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window,
                new DeviceSnapshot(true, "Подключено по SSH", ConnectionMode: "SSH", Agent: "2.7.0-esim.8", Vpn: "Требует обновления"));
            var nav = window.GetLogicalDescendants().OfType<Button>().Single(b => b.Name == "Navigation4");
            Check(nav.IsEnabled); nav.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Dispatcher.UIThread.RunJobs();
            var update = window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate("Установить / обновить"));
            Check(update.IsEnabled); window.Close(); Dispatcher.UIThread.RunJobs();
        }, CancellationToken.None);
    });
}
finally { Directory.Delete(storage, true); }
Console.WriteLine($"VPN regression: {passed} passed, {failed} failed; local synthetic transports only");
if (failed != 0) Environment.ExitCode = 1;

sealed class Shell : IRemoteShell
{
    internal string Agent = AgentPackage.Sha256, Helper = "a388d8fa771b3e4bb46d500202ff750df410b4e6608d0f4902288b6aad16d731";
    internal string Firmware = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
    internal RemoteResult? RequestReply;
    internal List<string> Requests = [], Commands = [];
    internal int Uploads, Preflights, InstallCalls;
    internal static RemoteResult Reply(string text = "", int code = 0) => new(code, Encoding.UTF8.GetBytes(text), []);
    public Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        Commands.Add(command);
        if (command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router", StringComparison.Ordinal))
            return Task.FromResult(Reply(Firmware + "  /firmware/image/modem.b16\n55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f  /usr/bin/diag-router\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n11111111-1111-1111-1111-111111111111"));
        if (command.Contains("for f in /data/zte-vpn/vpnctl", StringComparison.Ordinal))
            return Task.FromResult(Reply("PRESENT\n" + Helper + "\n" + Agent + "\nmissing\nmissing"));
        if (command.EndsWith("/vpnctl request", StringComparison.Ordinal))
        {
            using var doc = JsonDocument.Parse(stdin!); Requests.Add(doc.RootElement.GetProperty("action").GetString()!);
            return Task.FromResult(RequestReply ?? Reply("{\"ok\":true,\"data\":{\"schema_version\":1,\"configured\":true,\"enabled\":true,\"core_running\":false,\"profiles\":[{\"id\":\"fixture\",\"name\":\"Synthetic\",\"transport\":\"vless\",\"active\":true}]}}"));
        }
        if (command.Contains("for c in lua nft", StringComparison.Ordinal)) return Task.FromResult(Reply());
        if (command.StartsWith("if test -e /data/zte-vpn", StringComparison.Ordinal)) return Task.FromResult(Reply("PRESENT"));
        if (command.Contains("echo SAFE", StringComparison.Ordinal)) return Task.FromResult(Reply("SAFE"));
        if (command.Contains("sha256sum /data/zte-agent", StringComparison.Ordinal)) return Task.FromResult(Reply(Agent));
        if (command.Contains("cat > ", StringComparison.Ordinal)) { Uploads++; return Task.FromResult(Reply(Convert.ToHexStringLower(SHA256.HashData(stdin!)) + "  staged")); }
        if (command.Contains("update-agent.sh", StringComparison.Ordinal) && command.EndsWith(" preflight", StringComparison.Ordinal))
        { Preflights++; return Task.FromResult(new RemoteResult(1, [], Encoding.UTF8.GetBytes("PRIVATE preflight text"))); }
        if (command.Contains("sh ", StringComparison.Ordinal)) { InstallCalls++; throw new Exception("Unexpected installation"); }
        if (command.Contains("mkdir", StringComparison.Ordinal) || command.Contains("rmdir", StringComparison.Ordinal)) return Task.FromResult(Reply());
        throw new Exception("Unexpected fake command");
    }
    public Task UploadAsync(string path, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("Unexpected upload API");
    public Task<byte[]> DownloadAsync(string path, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("Unexpected download");
}
sealed class TestApp : Application
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<TestApp>().UseHeadless(new AvaloniaHeadlessPlatformOptions());
}
sealed class FakeModem : IModemService
{
    public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct = default) => Task.FromResult(new DeviceSnapshot(false, "Нет подключения"));
    public Task<OperationResult> RunAsync(OperationRequest request, CancellationToken ct = default) => Task.FromResult(new OperationResult(false, "Synthetic only"));
    public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<BackupInfo>>([]);
    public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<ModemAppInfo>>([]);
    public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<LogEntry>>([]);
    public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct = default) => throw new Exception("No terminal");
}
