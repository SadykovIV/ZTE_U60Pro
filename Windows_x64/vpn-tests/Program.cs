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
// Pinned from the preserved 1.24.18 release, not the mutable current bundle.
const string release12418Agent = "e258b90032b3b3cb2af7e434f4c2cb83e01777aaf08f0d9b2e3c0c73bbd42ca6";
// Measured final 1.24.22 source/resource bytes in windows-artifact-audit/windows-artifact-audit.json.
const string release12422Helper = "b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a";
const string release12420Helper = "fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48";
const string release12418Helper = "b2c3fcfafeccd50fa3000ad5f8f66f1e42ff157b295cdda11dddd31571612af7";
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
    await Test("Prior 1.24.18 agent remains an explicitly supported upgrade source", () =>
    {
        Check(AgentPackage.SupportedUpgradeHashes.Contains(release12418Agent));
        Check(AgentPackage.VersionForHash(release12418Agent) == "2.9.0-esim.8" && AgentPackage.SupportsVpn(release12418Agent));
        return Task.CompletedTask;
    });
    await Test("Prior 1.24.20 agent remains recognized and upgradeable", () =>
    {
        const string prior = "0ab7839ccd1b5930d8dcc74665f1ccfc30d0ad74746f73130760da66343c6659";
        Check(AgentPackage.VersionForHash(prior) == "2.9.0-esim.9");
        Check(AgentPackage.SupportsVpn(prior) && AgentPackage.SupportedUpgradeHashes.Contains(prior));
        Check(prior != AgentPackage.Sha256 && AgentPackage.VersionForHash(AgentPackage.Sha256) == AgentPackage.Version);
        return Task.CompletedTask;
    });
    await Test("Known .10/.11/.12 agents retain exact version labels after a new package pin", () =>
    {
        foreach (var (hash, version) in new[] {
            ("59af7b0b45ff2f0d280b6998fb573bd88f2b0d9c28017d8e6f2860b6c29bcbbd", "2.9.0-esim.10"),
            ("8f17bc22c09e2e5315b61a583cf8a6cd8b6ecfda42009c395a6db57b1ab6b12a", "2.9.0-esim.11"),
            ("58343b20c918d6a329b60a73e9f2328803ce44008a949799b645a2f95108c20c", "2.9.0-esim.12") })
        {
            Check(AgentPackage.VersionForHash(hash) == version && AgentPackage.SupportedUpgradeHashes.Contains(hash));
            var status = new AgentInstallationStatus(hash, true, true, false, null);
            Check(status.Version == version && !status.IsCurrent);
        }
        Check(AgentPackage.VersionForHash(AgentPackage.Sha256) == AgentPackage.Version);
        Check(new AgentInstallationStatus(AgentPackage.Sha256, true, true, false, null).IsCurrent);
        Check(AgentPackage.VersionForHash(new string('f', 64)) is null && !AgentPackage.SupportedUpgradeHashes.Contains(new string('f', 64)));
        return Task.CompletedTask;
    });
    foreach (var helper in new[] { release12422Helper, release12420Helper, release12418Helper, "f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c", "7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb", previousHelper, "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4", "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca" })
        await Test("Pinned historical controller status-only " + helper[..8], async () =>
        {
            var shell = new Shell { Helper = helper, Agent = previousAgent };
            var state = await Service(shell).GetVpnStatusAsync();
            Check(state.Installed && !state.HelperReady && !state.AgentReady && state.Configured && state.Enabled && state.Profiles.Count == 1);
            Check(shell.Requests.SequenceEqual(new[] { "status" }));
            Check(shell.Commands.Single(c => c.EndsWith("/vpnctl request")).Contains(helper, StringComparison.Ordinal));
            await Rejected(() => Service(shell).SetVpnEnabledAsync(true));
            Check(shell.Requests.All(x => x == "status") && shell.Uploads == 0);
        });
    if (args.Contains("--historical-status-only"))
    {
        Console.WriteLine($"Historical VPN status: {passed} passed, {failed} failed; synthetic transports only");
        if (failed != 0) Environment.ExitCode = 1;
        return;
    }
    await Test("Unknown controller never executes", async () =>
    {
        var shell = new Shell { Helper = new string('f', 64) };
        Check(!(await Service(shell).GetVpnStatusAsync()).HelperReady && shell.Requests.Count == 0);
    });
    await Test("Prior 1.24.21 controller remains readable after a package update", async () =>
    {
        const string previous = "82a8b6655ff6cd43938ffe3735e8841599ef6116bf33079d8d203db9415ca3f2";
        var shell = new Shell { Helper = previous };
        var status = await Service(shell).GetVpnStatusAsync();
        Check(status.Installed && status.HelperReady == (Shell.CurrentHelper == previous));
        Check(shell.Requests.SequenceEqual(new[] { "status" }));
        if (Shell.CurrentHelper != previous) {
            await Rejected(() => Service(shell).SetVpnEnabledAsync(true));
            Check(shell.Requests.All(x => x == "status"));
        }
    });
    await Test("Current controller stays ready", async () =>
    {
        var shell = new Shell();
        Check(Shell.CurrentHelper != release12420Helper && Shell.CurrentHelper != release12418Helper);
        Check((await Service(shell).GetVpnStatusAsync()).HelperReady && shell.Requests.SequenceEqual(new[] { "status" }));
    });
    await Test("Prior 1.24.18 controller upgrades without replacing its agent or losing profiles", async () =>
    {
        var shell = new Shell { Agent = release12418Agent, Helper = release12418Helper };
        var before = await Service(shell).GetVpnStatusAsync();
        Check(before.Installed && !before.HelperReady && before.Profiles.Count == 1);
        var after = await Service(shell).InstallVpnAsync();
        Check(after.HelperReady && after.Profiles.SequenceEqual(before.Profiles));
        Check(shell.InstallCalls == 1 && shell.Preflights == 0 && shell.Agent == release12418Agent);
        Check(!shell.Commands.Any(c => c.Contains("update-agent.sh") || c.Contains("install-launcher.sh")));
    });
    await Test("Prior 1.24.20 controller upgrades without replacing its agent or losing profiles", async () =>
    {
        Check(release12420Helper != Shell.CurrentHelper);
        var shell = new Shell { Agent = release12418Agent, Helper = release12420Helper };
        var before = await Service(shell).GetVpnStatusAsync();
        Check(before.Installed && !before.HelperReady && before.Profiles.Count == 1);
        var after = await Service(shell).InstallVpnAsync();
        Check(after.HelperReady && after.Profiles.SequenceEqual(before.Profiles));
        Check(shell.InstallCalls == 1 && shell.Preflights == 0 && shell.Agent == release12418Agent);
        Check(!shell.Commands.Any(c => c.Contains("update-agent.sh") || c.Contains("install-launcher.sh")));
    });
    await Test("Prior 1.24.22 controller status and explicit upgrade preserve its active profiles", async () =>
    {
        Check(release12422Helper != Shell.CurrentHelper);
        var shell = new Shell { Agent = release12418Agent, Helper = release12422Helper };
        var before = await Service(shell).GetVpnStatusAsync();
        Check(before.Installed && !before.HelperReady && before.Enabled && before.Profiles.Count == 1);
        Check(shell.Requests.SequenceEqual(new[] { "status" }) && shell.Uploads == 0);
        var after = await Service(shell).InstallVpnAsync();
        Check(after.HelperReady && after.Profiles.SequenceEqual(before.Profiles));
        Check(after.Enabled == before.Enabled && after.ActiveProfile == before.ActiveProfile);
        Check(shell.InstallCalls == 1 && shell.Preflights == 0 && shell.Agent == release12418Agent);
        Check(!shell.Commands.Any(c => c.Contains("update-agent.sh") || c.Contains("install-launcher.sh")));
    });
    foreach (var firmware in new[] {
        "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263",
        "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478",
        "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81"
    }) await Test("Controller upgrade stages every runtime file before installation: " + firmware[..8], async () =>
    {
        var shell = new Shell { Firmware = firmware, Helper = release12422Helper };
        var before = await Service(shell).GetVpnStatusAsync();
        var after = await Service(shell).InstallVpnAsync();
        string[] required = ["upgrade-controller.sh", "vpnctl", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft"];
        Check(shell.StagedFiles.Keys.Order().SequenceEqual(required.Order()));
        foreach (var name in required)
            Check(shell.StagedFiles[name].AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine("Windows_x64/Resources/VPN", name))));
        Check(shell.UploadsAtInstall == required.Length && shell.InstallCalls == 1);
        Check(after.Profiles.SequenceEqual(before.Profiles) && after.ActiveProfile == before.ActiveProfile && after.Enabled == before.Enabled);
        Check(shell.Commands.Any(c => c.Contains("rm -f") && required.All(name => c.Contains("/" + name + "'", StringComparison.Ordinal))));
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
    foreach (var agent in new[] { previousAgent, new string('f', 64), "missing" })
        await Test("VPN installation does not require agent " + agent[..Math.Min(8, agent.Length)], async () =>
        {
            var shell = new Shell { Agent = agent };
            var status = await Service(shell).InstallVpnAsync();
            Check(status.HelperReady && shell.Preflights == 0 && shell.InstallCalls == 1);
            Check(!shell.Commands.Any(c => c.Contains("update-agent.sh") || c.Contains("install-launcher.sh")));
        });
    await Test("B28 VPN install reaches its component installer without global B31 permission", async () =>
    {
        var shell = new Shell { Firmware = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478" };
        var status = await Service(shell).InstallVpnAsync();
        Check(status.HelperReady && shell.InstallCalls == 1 && shell.Preflights == 0);
        Check(shell.Commands.Contains(AccessIdentity.Command));
    });
    await Test("B28 Wi-Fi configuration reaches the pinned helper without global B31 permission", async () =>
    {
        var shell = new Shell { Firmware = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478", WifiMode = true };
        var status = await Service(shell).ConfigureVpnWifiAsync("Synthetic", VpnPasswordMode.Main);
        Check(status.DesiredSsid == "Synthetic" && shell.Requests.Contains("configure_wifi"));
        Check(shell.Commands.Contains(AccessIdentity.Command));
    });
    await Test("Fresh installer errors expose exact phases without private output", () =>
    {
        var method = typeof(DeviceFeatureService).GetMethod("InstallerFailure", BindingFlags.Static | BindingFlags.NonPublic)!;
        string Message(string error, int exit = 1) => (string)method.Invoke(null, ["vpn_components", new RemoteResult(exit, [], Encoding.UTF8.GetBytes(error))])!;
        foreach (var code in new[] { "INVALID_STAGE", "PLATFORM", "UNSAFE_STAGE", "ALREADY_PRESENT", "UNSUPPORTED_FIRMWARE", "RUNTIME_TOOLS", "TUN_UNAVAILABLE", "LUA_MODULES", "NO_SPACE", "PAYLOAD", "WRITE", "INTEGRITY", "SERVICE" })
        {
            var message = Message("PRIVATE credential\nVPN_INSTALL_ERROR " + code + "\n");
            Check(message.Contains("VPN_INSTALL_" + code) && !message.Contains("PRIVATE"));
        }
        foreach (var error in new[] { "VPN_INSTALL_ERROR PRIVATE", "prefix VPN_INSTALL_ERROR PAYLOAD", "VPN_INSTALL_ERROR PAYLOAD PRIVATE", "VPN_INSTALL_ERROR PAYLOAD\nVPN_INSTALL_ERROR SERVICE" })
            Check(Message(error).Contains("installer_failed") && !Message(error).Contains("PRIVATE"));
        foreach (var exit in new[] { -1, 255 }) Check(Message("VPN_INSTALL_ERROR PAYLOAD", exit).Contains("transport_unknown"));
        return Task.CompletedTask;
    });
    await Test("Unknown firmware is refused by the VPN component installer", async () =>
    {
        var shell = new Shell { Firmware = new string('f', 64) };
        var error = await Rejected(() => Service(shell).InstallVpnAsync());
        Check(error.Contains("VPN_INSTALL_UNSUPPORTED_FIRMWARE") && shell.InstallCalls == 1);
    });
    await Test("Existing pending journal refuses before all remote calls", async () =>
    {
        var pending = Path.Combine(storage, "component-cleanup-pending.json");
        await File.WriteAllTextAsync(pending, "{}");
        try { var shell = new Shell(); await Rejected(() => Service(shell).InstallVpnAsync()); Check(shell.Commands.Count == 0); }
        finally { File.Delete(pending); }
    });
    await Test("VPN guard failure preserves established SSH snapshot and transport", async () =>
    {
        // Construct only the state needed by the actual service dispatch. Avoid its
        // constructor reading the user's saved connection or creating an SSH client.
        var service = new WindowsModemService(storage, Path.GetFullPath("Windows_x64/Resources"));
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
    await Test("Profile lifecycle uses private SSH stdin with no running agent or duplicate modem lock", async () =>
    {
        var shell = new Shell { Agent = "missing", ProfileMode = true };
        var service = Service(shell);
        const string uri = "vless://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@example.test:443?security=tls#PRIVATE_CANARY";
        var imported = await service.ImportVpnProfileAsync(uri, "Test");
        Check(imported.Profiles.Count == 1 && !imported.Enabled);
        var id = imported.Profiles[0].Id;
        Check((await service.RenameVpnProfileAsync(id, " Renamed ")).Profiles[0].Name == "Renamed");
        Check((await service.ActivateVpnProfileAsync(id)).ActiveProfile == id);
        Check(!(await service.SetVpnEnabledAsync(false)).Enabled);
        Check((await service.SetVpnEnabledAsync(true)).Enabled);
        shell.ProfileState["active_profile"] = "22222222-2222-2222-2222-222222222222";
        Check((await service.DeleteVpnProfileAsync(id)).Profiles.Count == 0);
        Check(shell.Bodies.Single(x => x.GetProperty("action").GetString() == "import").GetProperty("uri").GetString() == uri);
        Check(!shell.Commands.Any(c => c.Contains("PRIVATE_CANARY") || c.Contains("example.test") || c.Contains("mkdir /tmp/zte-imei-app.lock")));
        Check(shell.Commands.Where(c => c.EndsWith("/vpnctl request") && c.Contains("boot_id")).Count() == 6);
        var privacy = new ZteImeiStudio.Windows.Diagnostics.DiagnosticPrivacy();
        privacy.RememberParameters(new Dictionary<string,string> { ["vpn_secret_uri"] = uri });
        Check(!privacy.Clean(uri).Contains("PRIVATE_CANARY"));
    });
    await Test("Desktop service dispatches profile actions and refreshes snapshot without logging URI", async () =>
    {
        var shell = new Shell { Agent = "missing", ProfileMode = true };
        var service = new WindowsModemService(storage, Path.GetFullPath("Windows_x64/Resources"));
        void Set(string name, object value) => typeof(WindowsModemService).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(service, value);
        Set("_ssh", System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(SshTransport)));
        Set("_imei", System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(ImeiEngine)));
        Set("_features", Service(shell));
        Set("_snapshot", new DeviceSnapshot(true, "SSH", ConnectionMode: "SSH"));
        var uri = "vless://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@example.test:443#PRIVATE_DISPATCH";
        var result = await service.RunAsync(new(ModemOperation.ImportVpnProfile, new Dictionary<string,string> { ["vpn_secret_uri"] = uri, ["vpn_profile_name"] = "Dispatch" }));
        Check(result.Success);
        var snapshot = await service.GetDeviceSnapshotAsync();
        var id = snapshot.VpnPage!.ProfileDetails!.Single().Id;
        Check(snapshot.VpnPage.ComponentsReady && snapshot.Agent is null);
        foreach (var (operation, extraKey, extraValue) in new[] {
            (ModemOperation.RenameVpnProfile, "vpn_profile_name", "Renamed"),
            (ModemOperation.ActivateVpnProfile, "unused", ""),
            (ModemOperation.SetVpnEnabled, "vpn_enabled", "false") })
        {
            result = await service.RunAsync(new(operation, new Dictionary<string,string> { ["vpn_profile_id"] = id, [extraKey] = extraValue }));
            Check(result.Success);
        }
        snapshot = await service.GetDeviceSnapshotAsync();
        Check(snapshot.VpnPage!.ActiveProfile == "Renamed" && !snapshot.VpnPage.Enabled);
        shell.ProfileState["active_profile"] = "22222222-2222-2222-2222-222222222222";
        Check((await service.RunAsync(new(ModemOperation.DeleteVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = id }))).Success);
        Check((await service.GetDeviceSnapshotAsync()).VpnPage!.Profiles.Count == 0);
        Check(!(await service.GetLogsAsync()).Any(x => x.Message.Contains("PRIVATE_DISPATCH") || x.Message.Contains(uri)));
        foreach (var file in Directory.EnumerateFiles(storage, "*.jsonl", SearchOption.AllDirectories))
            Check(!(await File.ReadAllTextAsync(file)).Contains("PRIVATE_DISPATCH"));
    });
    await Test("IKEv2 save uses private stdin, preserves an empty edit password and does not activate", async () =>
    {
        const string certificate = "-----BEGIN CERTIFICATE-----\nZml4dHVyZQ==\n-----END CERTIFICATE-----";
        var config = new VpnIkev2Configuration("vpn.example.com", "", "fixture", "PRIVATE_IKEV2_CANARY", certificate);
        var shell = new Shell { ProfileMode = true }; var service = Service(shell);
        var created = await service.SaveVpnIkev2Async(null, "IKEv2", config);
        var id = created.Profiles.Single().Id;
        Check(!created.Enabled && created.ActiveProfile == "" && created.Profiles.Single().Protocol == "ikev2");
        var create = shell.Bodies.Single(x => x.GetProperty("action").GetString() == "save_ikev2");
        Check(!create.TryGetProperty("id", out _) && create.GetProperty("ikev2").GetProperty("server_id").GetString() == "vpn.example.com");
        Check(create.GetProperty("ikev2").GetProperty("dns").GetString() == "10.0.2.1");
        Check(create.GetProperty("ikev2").GetProperty("password").GetString() == config.Password && !config.ToString().Contains(config.Password));
        var edited = await service.SaveVpnIkev2Async(id, "Updated", config with { Password = "" });
        Check(edited.Profiles.Single().Id == id && edited.Profiles.Single().Name == "Updated" && !edited.Enabled);
        Check(!shell.Bodies.Last(x => x.GetProperty("action").GetString() == "save_ikev2").GetProperty("ikev2").TryGetProperty("password", out _));
        Check(shell.Commands.All(command => !command.Contains("PRIVATE_IKEV2_CANARY") && !command.Contains(certificate)));
        var invalid = new Shell(); var invalidService = Service(invalid);
        foreach (var value in new[] { config with { Password = "" }, config with { Dns = "8.8.8.8" }, config with { Dns = "10.00.2.1" }, config with { ServerId = "%any" }, config with { CaCertificate = new string('A',65537) } })
            await Rejected(() => invalidService.SaveVpnIkev2Async(null, "IKEv2", value));
        Check(invalid.Commands.Count == 0);
        var ignored = new Shell { ProfileMode = true, IgnoreProfileMutation = true };
        await Rejected(() => Service(ignored).SaveVpnIkev2Async(null, "IKEv2", config));
    });
    await Test("IKEv2 details reject a returned password", async () =>
    {
        const string id = "11111111-1111-1111-1111-111111111111";
        var proxy = new Dictionary<string,object> { ["type"] = "ikev2", ["server"] = "vpn.example.com", ["server_id"] = "vpn.example.com", ["username"] = "fixture", ["dns"] = "10.0.2.1", ["password_set"] = true, ["ca_certificate"] = "-----BEGIN CERTIFICATE-----\nZml4dHVyZQ==\n-----END CERTIFICATE-----" };
        RemoteResult Reply() => Shell.Reply(JsonSerializer.Serialize(new { ok = true, data = new { profile = new { id, name = "IKEv2", protocol = "ikev2", proxy } } }));
        var shell = new Shell { RequestReply = Reply() };
        Check((await Service(shell).GetVpnIkev2Async(id)).Configuration.Password == "");
        proxy["password"] = "PRIVATE_IKEV2_CANARY"; shell.RequestReply = Reply();
        await Rejected(() => Service(shell).GetVpnIkev2Async(id));
    });
    await Test("Profile validation rejects unsupported input before SSH", async () =>
    {
        var shell = new Shell(); var service = Service(shell);
        await Rejected(() => service.ImportVpnProfileAsync("mixed-port: 7890"));
        await Rejected(() => service.ImportVpnProfileAsync("vless://first\nvless://second"));
        await Rejected(() => service.RenameVpnProfileAsync("../profile", "name"));
        await Rejected(() => service.RenameVpnProfileAsync("11111111-1111-1111-1111-111111111111", "\n"));
        Check(shell.Commands.Count == 0);
    });
    await Test("A successful command without changed state is not import success", async () =>
    {
        var shell = new Shell { ProfileMode = true, IgnoreProfileMutation = true };
        Check((await Rejected(() => Service(shell).ImportVpnProfileAsync("vless://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@example.test:443"))).Contains("не подтвердил"));
        Check(shell.Requests.Count(x => x == "import") == 1);
    });
    foreach (var code in new[] { "VPN_BUSY", "VPN_ACTIVE_PROFILE_DELETE", "VPN_SUBSCRIPTION_FILE_REFERENCE" })
        await Test("Profile refusal is specific and never retried: " + code, async () =>
        {
            var shell = new Shell { ProfileMode = true, MutationError = code };
            Check((await Rejected(() => Service(shell).DeleteVpnProfileAsync("11111111-1111-1111-1111-111111111111"))).Contains(code));
            Check(shell.Requests.Count(x => x == "delete") == 1);
        });
    await Test("AWG import uses SSH stdin and preserves exact multiline configuration", async () =>
    {
        const string config = "# synthetic\n[Interface]\nPrivateKey = PRIVATE_KEY\n[Peer]\nPublicKey = PRIVATE_PUBLIC\n";
        var shell = new Shell { ProfileMode = true };
        var result = await Service(shell).ImportVpnConfigAsync(config, "AWG fixture");
        Check(result.Profiles.Single().Protocol == "amneziawg3.1");
        Check(shell.Bodies.Single(x => x.GetProperty("action").GetString() == "import_config").GetProperty("config").GetString() == config);
        Check(shell.Commands.All(x => !x.Contains("PRIVATE", StringComparison.Ordinal)));
        await Rejected(() => Service(shell).ImportVpnConfigAsync("PostUp = command"));
    });
    await Test("Subscription metadata and active update reach desktop status, detach retains profiles", async () =>
    {
        var shell = new Shell { ProfileMode = true };
        const string id = "11111111-1111-1111-1111-111111111111";
        shell.ProfileState["profiles"] = JsonNode.Parse("[{\"id\":\"" + id + "\",\"name\":\"AWG\",\"active\":true,\"protocol\":\"amneziawg3.1\",\"transport\":\"udp\",\"subscription_id\":\"" + id + "\",\"update_available\":true,\"removed_from_subscription\":true,\"warnings\":[\"VPN_INSECURE_TLS\",\"VPN_IPV6_GUEST_DISABLED\",\"VPN_SPX_PRESERVED\",\"NAME_TRUNCATED\",\"PRIVATE_UNKNOWN\",\"VPN_INSECURE_TLS\"]}]");
        shell.ProfileState["active_profile"] = id;
        shell.ProfileState["subscriptions"] = JsonNode.Parse("[{\"id\":\"" + id + "\",\"name\":\"Feed\",\"host\":\"example.test\",\"updated_at\":123,\"profile_count\":1}]");
        var service = Service(shell);
        var status = await service.GetVpnStatusAsync();
        Check(status.Profiles.Single().UpdateAvailable && status.Profiles.Single().RemovedFromSubscription);
        Check(status.Profiles.Single().Warnings!.SequenceEqual(new[] { "VPN_INSECURE_TLS", "VPN_IPV6_GUEST_DISABLED", "VPN_SPX_PRESERVED", "NAME_TRUNCATED" }));

        Check(status.Subscriptions!.Single().Host == "example.test" && status.Subscriptions.Single().ProfileCount == 1);
        Check(!(await service.ActivateVpnProfileAsync(id)).Profiles.Single().UpdateAvailable);
        var detached = await service.DeleteVpnSubscriptionAsync(id);
        Check(detached.Subscriptions!.Count == 0 && detached.Profiles.Count == 1);
    });
    await Test("Import summary from mutation survives a subsequent status without last_import", async () =>
    {
        var shell = new Shell { ProfileMode = true, MutationSummary = JsonNode.Parse("{\"added\":2,\"updated\":3,\"removed\":4,\"duplicates\":5,\"retained_active\":1,\"skipped\":[{\"index\":6,\"code\":\"VPN_SUBSCRIPTION_ENTRY\"}]}") };
        var status = await Service(shell).ImportVpnConfigAsync("[Interface]\nPrivateKey = PRIVATE", "Fixture");
        Check(status.LastImport is { Added: 2, Updated: 3, Removed: 4, Duplicates: 5, RetainedActive: 1 });
        Check(status.LastImport!.Skipped.Single().Index == 6 && status.LastImport.Skipped.Single().Code == "VPN_SUBSCRIPTION_ENTRY");
    });
    await Test("Subscription download preserves UA order and private URL without logging", async () =>
    {
        var calls = new List<string>();
        var handler = new SubscriptionHttp(request => {
            calls.Add(request.Headers.UserAgent.ToString());
            Check(request.RequestUri!.Query == "?token=PRIVATE");
            return new(System.Net.HttpStatusCode.OK) { Content = new StringContent(request.Headers.UserAgent.ToString() == "clash.meta" ? "proxies: []" : "BASE64") };
        });
        var docs = await VpnSubscriptionClient.FetchAsync("https://example.test/?token=PRIVATE", CancellationToken.None, handler);
        Check(docs.SequenceEqual(new[] { "proxies: []", "BASE64" }));
        Check(calls.Order().SequenceEqual(new[] { "Happ/1.0", "clash.meta" }.Order()));
    });
    await Test("Subscription download follows HTTPS redirects and accepts a fallback response", async () =>
    {
        var handler = new SubscriptionHttp(request => request.RequestUri!.AbsolutePath == "/first"
            ? new(System.Net.HttpStatusCode.Redirect) { Headers = { Location = new Uri("/second", UriKind.Relative) } }
            : request.Headers.UserAgent.ToString() == "clash.meta" ? new(System.Net.HttpStatusCode.NotFound)
            : new(System.Net.HttpStatusCode.OK) { Content = new StringContent("fallback") });
        var docs = await VpnSubscriptionClient.FetchAsync("https://example.test/first", CancellationToken.None, handler);
        Check(docs.SequenceEqual(new[] { "fallback" }));
    });
    await Test("Subscription download refuses insecure redirects and keeps errors private", async () =>
    {
        var calls = 0;
        var handler = new SubscriptionHttp(request => { calls++; return new(System.Net.HttpStatusCode.Redirect) { Headers = { Location = new Uri("http://example.test/PRIVATE") } }; });
        var message = await Rejected(() => VpnSubscriptionClient.FetchAsync("https://example.test/PRIVATE", CancellationToken.None, handler));
        Check(message.Contains("VPN_SUBSCRIPTION_FETCH") && calls == 2);
        foreach (var url in new[] { "http://example.test/PRIVATE", "https://user:PRIVATE@example.test", "https://example.test/#PRIVATE", "https://example.test/\nPRIVATE" })
            Check((await Rejected(() => VpnSubscriptionClient.FetchAsync(url, CancellationToken.None))).Contains("VPN_SUBSCRIPTION_URL"));
    });
    await Test("Subscription bytes are bounded and invalid UTF8 is refused", async () =>
    {
        var large = new byte[VpnSubscriptionClient.MaximumBytes + 1];
        foreach (var bytes in new[] { large, new byte[] { 0xff } })
            Check((await Rejected(() => VpnSubscriptionClient.FetchAsync("https://example.test/", CancellationToken.None,
                new SubscriptionHttp(_ => new(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) })))).Contains("VPN_SUBSCRIPTION_FETCH"));
        var docs = await VpnSubscriptionClient.FetchAsync("https://example.test/", CancellationToken.None,
            new SubscriptionHttp(_ => new(System.Net.HttpStatusCode.OK) { Content = new StringContent("same") }));
        Check(docs.Length == 1);
    });
    await Test("Subscription cancellation propagates and new credential formats are redacted", async () =>
    {
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { await VpnSubscriptionClient.FetchAsync("https://example.test/", cancelled.Token, new SubscriptionHttp(_ => throw new OperationCanceledException())); throw new Exception("Expected cancellation"); }
        catch (OperationCanceledException) { }
        var privacy = new ZteImeiStudio.Windows.Diagnostics.DiagnosticPrivacy();
        Check(!privacy.Clean("hy2://fixture-key-value@example.test:443").Contains("fixture-key-value"));
        Check(!privacy.Clean("HeaderProtectionKey = PRIVATE").Contains("PRIVATE"));
        Check(!privacy.Clean("PresharedKey = PRIVATE").Contains("PRIVATE"));
        Check(!privacy.Clean("\"source_config\": \"PRIVATE\\nNEXTSECRET\"").Contains("PRIVATE"));
        Check(!privacy.Clean("\"source_config\": \"PRIVATE\\nNEXTSECRET\"").Contains("NEXTSECRET"));
        privacy.RememberParameters(new Dictionary<string,string> { ["source_config"] = "key-part\nconfig-part", ["PresharedKey"] = "psk-fixture" });
        Check(!privacy.Clean("value key-part\nconfig-part").Contains("config-part"));
        Check(!privacy.Clean("status psk-fixture").Contains("psk-fixture"));
        privacy.RememberParameters(new Dictionary<string,string> { ["vpn_subscription_url"] = "PRIVATE" });
        Check(!privacy.Clean("status PRIVATE").Contains("PRIVATE"));
    });
    using var session = HeadlessUnitTestSession.StartNew(typeof(TestApp));
    await Test("VPN profile controls work without agent and retain active-delete rule after busy reset", async () =>
    {
        await session.Dispatch(() =>
        {
            var window = new MainWindow(new FakeModem(), persistPreferences: false); window.Show(); Dispatcher.UIThread.RunJobs();
            typeof(MainWindow).GetField("_snapshot", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window,
                new DeviceSnapshot(true, "SSH", ConnectionMode: "SSH", Agent: null,
                    VpnPage: new VpnPageSnapshot(true, true, true, false, false, "Fixture", ["Active"], "Active", [new VpnProfileSnapshot("11111111-1111-1111-1111-111111111111", "Active", "tcp", true)], true)));
            window.GetLogicalDescendants().OfType<Button>().Single(b => b.Name == "Navigation4").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Dispatcher.UIThread.RunJobs();
            Button Find(string title) => window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate(title));
            Check(Find("Импортировать профиль").IsEnabled && Find("Переименовать").IsEnabled && Find("Включить Wi-Fi с VPN").IsEnabled);
            Check(!Find("Удалить профиль").IsEnabled && !Find("Сделать активным").IsEnabled);
            var busy = typeof(MainWindow).GetMethod("SetBusy", BindingFlags.NonPublic | BindingFlags.Instance)!;
            busy.Invoke(window, [true]); busy.Invoke(window, [false]);
            Check(!Find("Удалить профиль").IsEnabled && !Find("Сделать активным").IsEnabled && Find("Импортировать профиль").IsEnabled);
            window.Close(); Dispatcher.UIThread.RunJobs();
        }, CancellationToken.None);
    });
    await Test("IKEv2 UI exposes masked credentials, split DNS and explicit reconnect after MFA timeout", async () =>
    {
        await session.Dispatch(() =>
        {
            var window = new MainWindow(new FakeModem(), persistPreferences: false); window.Show(); Dispatcher.UIThread.RunJobs();
            foreach (var state in new[] { "waiting", "disconnected" })
            {
                typeof(MainWindow).GetField("_snapshot", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window,
                    new DeviceSnapshot(true, "SSH", ConnectionMode: "SSH", VpnPage: new VpnPageSnapshot(true, true, true, true, true, "Fixture", ["IKEv2"], "IKEv2",
                        [new VpnProfileSnapshot("11111111-1111-1111-1111-111111111111", "IKEv2", "", true, "ikev2")], true, Ikev2State: state)));
                window.GetLogicalDescendants().OfType<Button>().Single(b => b.Name == "Navigation4").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                typeof(MainWindow).GetMethod("RenderPage", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(window, null);
                Dispatcher.UIThread.RunJobs();
                Button Find(string title) => window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate(title));
                Check(Find("Переподключить IKEv2").IsEnabled && Find("Редактировать IKEv2").IsEnabled && Find("Сохранить IKEv2").IsEnabled);
                var fields = window.GetLogicalDescendants().OfType<TextBox>().Where(field => field.Tag is string).ToDictionary(field => (string)field.Tag!);
                Check(fields["vpn_ikev2_password"].PasswordChar == '●' && fields["vpn_ikev2_password"].Text == "");
                Check(fields["vpn_ikev2_dns"].Text == "10.0.2.1" && fields["vpn_ikev2_ca"].AcceptsReturn);
                Check(fields["vpn_ikev2_name"].Text == "UserGate");
                var texts = string.Join("\n", window.GetLogicalDescendants().OfType<TextBlock>().Select(b => b.Text));
                Check(texts.Contains(Localization.Translate(state == "waiting" ? "Ожидание подключения IKEv2: подтвердите PUSH в приложении MFA." : "IKEv2 не подключён: частные сети и DNS недоступны. Публичные IPv4 доступны через LTE, если адрес уже известен.")));
            }
            window.Close(); Dispatcher.UIThread.RunJobs();
        }, CancellationToken.None);
    });
    await Test("Unified VPN UI allows pending active updates and subscription actions without agent", async () =>
    {
        await session.Dispatch(() =>
        {
            var window = new MainWindow(new FakeModem(), persistPreferences: false); window.Show(); Dispatcher.UIThread.RunJobs();
            typeof(MainWindow).GetField("_snapshot", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window,
                new DeviceSnapshot(true, "SSH", ConnectionMode: "SSH", Agent: null,
                    VpnPage: new VpnPageSnapshot(true, true, true, true, true, "Fixture", ["AWG"], "AWG",
                        [new VpnProfileSnapshot("11111111-1111-1111-1111-111111111111", "AWG", "udp", true, "amneziawg3.1", UpdateAvailable: true)], true,
                        [new VpnSubscription("22222222-2222-2222-2222-222222222222", "Example feed", "example.test", "123", 43)],
                        new VpnImportSummary(43, 0, 0, 0, 1, []))));
            window.GetLogicalDescendants().OfType<Button>().Single(b => b.Name == "Navigation4").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Dispatcher.UIThread.RunJobs();
            Button Find(string title) => window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate(title));
            Check(Find("Применить обновление").IsEnabled && !Find("Удалить профиль").IsEnabled);
            Check(Find("Добавить подписку").IsEnabled && Find("Обновить подписку").IsEnabled && Find("Удалить подписку").IsEnabled);
            var texts = string.Join("\n", window.GetLogicalDescendants().OfType<TextBlock>().Select(b => b.Text));
            Check(texts.Contains("AWG 3.1") && texts.Contains("example.test") && texts.Contains("43"));
            var busy = typeof(MainWindow).GetMethod("SetBusy", BindingFlags.NonPublic | BindingFlags.Instance)!;
            busy.Invoke(window, [true]); Check(!Find("Применить обновление").IsEnabled && !Find("Обновить подписку").IsEnabled);
            busy.Invoke(window, [false]); Check(Find("Применить обновление").IsEnabled && !Find("Удалить профиль").IsEnabled);
            if (args.Contains("--render-vpn"))
            {
                var output = "/Users/isadykov/Desktop/ZTE/evidence/vpn-multiprotocol-20261013/ui/windows-preview";
                Directory.CreateDirectory(output); window.Width = 1280; window.Height = 1100;
                foreach (var language in new[] { "ru", "en" })
                {
                    window.GetLogicalDescendants().OfType<ComboBox>().Single(x => x.Name == "LanguagePicker").SelectedIndex = language == "ru" ? 0 : 1;
                    Dispatcher.UIThread.RunJobs(); AvaloniaHeadlessPlatform.ForceRenderTimerTick(); Dispatcher.UIThread.RunJobs();
                    var scroll = window.GetLogicalDescendants().OfType<ScrollViewer>().First(x => x.Content is StackPanel panel && panel.Children.OfType<Border>().Any());
                    foreach (var offset in new[] { 0, 900 })
                    {
                        scroll.Offset = new Vector(0, offset); Dispatcher.UIThread.RunJobs();
                        AvaloniaHeadlessPlatform.ForceRenderTimerTick(); Dispatcher.UIThread.RunJobs();
                        using var image = window.CaptureRenderedFrame() ?? throw new Exception("Missing VPN preview frame");
                        image.Save(Path.Combine(output, language + "-vpn-" + offset + ".png"));
                    }
                }
                Localization.SetLanguage("ru", persist: false);
            }
            window.Close(); Dispatcher.UIThread.RunJobs();
        }, CancellationToken.None);
    });
    await Test("SPX and shortened-name warnings stay informative and do not block VPN controls", async () =>
    {
        await session.Dispatch(() =>
        {
            foreach (var language in new[] { "ru", "en" })
            {
                Localization.SetLanguage(language, persist: false);
                var window = new MainWindow(new FakeModem(), persistPreferences: false); window.Show(); Dispatcher.UIThread.RunJobs();
                typeof(MainWindow).GetField("_snapshot", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window,
                    new DeviceSnapshot(true, "SSH", ConnectionMode: "SSH", Agent: null,
                        VpnPage: new VpnPageSnapshot(true, true, true, false, false, "Fixture", ["Active"], "Active",
                            [new VpnProfileSnapshot("11111111-1111-1111-1111-111111111111", "Active", "tcp", true,
                                Warnings: ["VPN_SPX_PRESERVED", "NAME_TRUNCATED", "PRIVATE_UNKNOWN"])], true)));
                window.GetLogicalDescendants().OfType<Button>().Single(b => b.Name == "Navigation4").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Dispatcher.UIThread.RunJobs();
                var texts = window.GetLogicalDescendants().OfType<TextBlock>().Select(b => b.Text).ToArray();
                Check(texts.Contains(language == "ru" ? "Параметр spx сохранён в исходной ссылке, но не используется этим ядром VPN." : "The spx parameter is preserved in the source link but is not used by this VPN core."));
                Check(texts.Contains(language == "ru" ? "Название профиля сокращено до 64 символов." : "The profile name was shortened to 64 characters."));
                Check(!texts.Any(t => t?.Contains("Не удалось", StringComparison.Ordinal) == true || t?.Contains("PRIVATE_UNKNOWN", StringComparison.Ordinal) == true));
                Button Find(string title) => window.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == Localization.Translate(title));
                Check(Find("Включить Wi-Fi с VPN").IsEnabled && Find("Импортировать профиль").IsEnabled && Find("Переименовать").IsEnabled);
                Check(!Find("Удалить профиль").IsEnabled && !Find("Сделать активным").IsEnabled);
                window.Close(); Dispatcher.UIThread.RunJobs();
            }
            Localization.SetLanguage("ru", persist: false);
        }, CancellationToken.None);
    });
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
    internal static readonly string CurrentHelper = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes("Windows_x64/Resources/VPN/vpnctl")));
    internal string Agent = AgentPackage.Sha256, Helper = CurrentHelper;
    internal string Firmware = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
    internal RemoteResult? RequestReply;
    internal bool ProfileMode, IgnoreProfileMutation, WifiMode;
    private string WifiSsid = "ZTE-VPN";
    internal string? MutationError;
    internal JsonNode? MutationSummary;
    internal List<JsonElement> Bodies = [];
    internal JsonObject ProfileState = JsonNode.Parse("{\"schema_version\":1,\"configured\":false,\"enabled\":false,\"core_running\":false,\"settings_supported\":true,\"profiles\":[],\"active_profile\":\"\"}")!.AsObject();
    internal List<string> Requests = [], Commands = [];
    internal int Uploads, Preflights, InstallCalls;
    internal int UploadsAtInstall;
    internal Dictionary<string, byte[]> StagedFiles = new(StringComparer.Ordinal);
    internal static RemoteResult Reply(string text = "", int code = 0) => new(code, Encoding.UTF8.GetBytes(text), []);
    public Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        Commands.Add(command);
        if (command == AccessIdentity.Command || command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router", StringComparison.Ordinal))
            return Task.FromResult(Reply(Firmware + "  /firmware/image/modem.b16\n55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f  /usr/bin/diag-router\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n11111111-1111-1111-1111-111111111111"));
        if (command.Contains("for f in /data/zte-vpn/vpnctl", StringComparison.Ordinal))
            return Task.FromResult(Reply("PRESENT\n" + Helper + "\nHELPER_LAYOUT_READY"));
        if (command.EndsWith("/vpnctl request", StringComparison.Ordinal))
        {
            using var doc = JsonDocument.Parse(stdin!); var body = doc.RootElement; var action = body.GetProperty("action").GetString()!;
            Requests.Add(action); Bodies.Add(body.Clone());
            if (RequestReply is not null) return Task.FromResult(RequestReply);
            if (WifiMode)
            {
                if (action == "configure_wifi")
                {
                    if (!body.TryGetProperty("lock_token", out _)) throw new Exception("Missing borrowed lock");
                    WifiSsid = body.GetProperty("ssid").GetString()!;
                }
                return Task.FromResult(Reply(JsonSerializer.Serialize(new { ok = true, data = new { schema_version = 1, configured = false, enabled = false, core_running = false, settings_supported = true, profiles = Array.Empty<object>(), active_profile = "", desired_ssid = WifiSsid, password_mode = "main" } })));
            }
            if (ProfileMode)
            {
                if (action != "status" && (!command.Contains("/proc/sys/kernel/random/boot_id") || body.TryGetProperty("lock_token", out _))) throw new Exception("Missing identity guard or duplicate lock");
                if (action != "status" && MutationError is not null) return Task.FromResult(Reply(JsonSerializer.Serialize(new { ok = false, code = MutationError }), 1));
                if (!IgnoreProfileMutation)
                {
                    var profiles = ProfileState["profiles"]!.AsArray();
                    var id = body.TryGetProperty("id", out var idValue) ? idValue.GetString() : "";
                    switch (action)
                    {
                        case "save_ikev2":
                            if (string.IsNullOrEmpty(id)) profiles.Add(new JsonObject { ["id"] = "11111111-1111-1111-1111-111111111111", ["name"] = body.GetProperty("name").GetString(), ["transport"] = "", ["protocol"] = "ikev2", ["active"] = false });
                            else foreach (var p in profiles.Where(p => p!["id"]!.GetValue<string>() == id)) p!["name"] = body.GetProperty("name").GetString();
                            break;
                        case "import_config": profiles.Add(new JsonObject { ["id"] = "11111111-1111-1111-1111-111111111111", ["name"] = body.GetProperty("name").GetString() ?? "Imported", ["transport"] = "udp", ["protocol"] = "amneziawg3.1", ["active"] = false }); break;
                        case "subscription_delete": ProfileState["subscriptions"] = new JsonArray(); break;
                        case "import": profiles.Add(new JsonObject { ["id"] = "11111111-1111-1111-1111-111111111111", ["name"] = body.GetProperty("name").GetString() ?? "Imported", ["transport"] = "tcp", ["active"] = false }); break;
                        case "rename": foreach (var p in profiles.Where(p => p!["id"]!.GetValue<string>() == id)) p!["name"] = body.GetProperty("name").GetString(); break;
                        case "activate": foreach (var p in profiles) { p!["active"] = p["id"]!.GetValue<string>() == id; if (p["id"]!.GetValue<string>() == id) p["update_available"] = false; } ProfileState["active_profile"] = id; ProfileState["enabled"] = true; ProfileState["configured"] = true; break;
                        case "delete": foreach (var p in profiles.Where(p => p!["id"]!.GetValue<string>() == id).ToArray()) profiles.Remove(p); break;
                        case "set_enabled": ProfileState["enabled"] = body.GetProperty("enabled").GetBoolean(); break;
                    }
                }
                var replyState = ProfileState.DeepClone();
                if (action != "status" && MutationSummary is not null) replyState["last_import"] = MutationSummary.DeepClone();
                return Task.FromResult(Reply(new JsonObject { ["ok"] = true, ["data"] = replyState }.ToJsonString()));
            }
            return Task.FromResult(Reply("{\"ok\":true,\"data\":{\"schema_version\":1,\"configured\":true,\"enabled\":true,\"core_running\":false,\"profiles\":[{\"id\":\"fixture\",\"name\":\"Synthetic\",\"transport\":\"vless\",\"active\":true}]}}"));
        }
        if (command.Contains("for c in lua nft", StringComparison.Ordinal)) return Task.FromResult(Reply());
        if (command.StartsWith("if test -e /data/zte-vpn", StringComparison.Ordinal)) return Task.FromResult(Reply("PRESENT"));
        if (command.Contains("echo SAFE", StringComparison.Ordinal)) return Task.FromResult(Reply("SAFE"));
        if (command.Contains("sha256sum /data/zte-agent", StringComparison.Ordinal)) return Task.FromResult(Reply(Agent));
        if (command.Contains("cat > ", StringComparison.Ordinal)) {
            Uploads++;
            var path = System.Text.RegularExpressions.Regex.Match(command, "cat > '([^']+)'").Groups[1].Value;
            StagedFiles.Add(Path.GetFileName(path), stdin!.ToArray());
            return Task.FromResult(Reply(Convert.ToHexStringLower(SHA256.HashData(stdin!)) + "  staged"));
        }
        if (command.Contains("update-agent.sh", StringComparison.Ordinal) && command.EndsWith(" preflight", StringComparison.Ordinal))
        { Preflights++; return Task.FromResult(new RemoteResult(1, [], Encoding.UTF8.GetBytes("PRIVATE preflight text"))); }
        if (command.Contains("upgrade-controller.sh", StringComparison.Ordinal) && command.Contains("sh ", StringComparison.Ordinal)) {
            InstallCalls++;
            UploadsAtInstall = Uploads;
            if (Firmware == new string('f', 64)) return Task.FromResult(new RemoteResult(1, [], Encoding.UTF8.GetBytes("VPN_INSTALL_ERROR UNSUPPORTED_FIRMWARE\n")));
            Helper = CurrentHelper;
            return Task.FromResult(Reply("VPN_CONTROLLER_UPDATED"));
        }
        if (command.Contains("sh ", StringComparison.Ordinal)) { InstallCalls++; throw new Exception("Unexpected installation"); }
        if (command.Contains("mkdir", StringComparison.Ordinal) || command.Contains("rmdir", StringComparison.Ordinal)) return Task.FromResult(Reply());
        throw new Exception("Unexpected fake command");
    }
    public Task UploadAsync(string path, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("Unexpected upload API");
    public Task<byte[]> DownloadAsync(string path, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("Unexpected download");
}
sealed class TestApp : Application
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<TestApp>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
    public override void Initialize() => App.ConfigureTheme(this);
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

sealed class SubscriptionHttp(Func<HttpRequestMessage, HttpResponseMessage> reply) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(reply(request));
}
