#!/usr/bin/env python3
"""Exercise the real preparation service body with fault-injected I/O boundaries.

No application hooks or modem transports are added. Production method text is
compiled unchanged, apart from making the private method callable by the test.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
source = repo / 'Windows_x64/src/WindowsModemService.Administration.cs'
original = source.read_bytes()
text = original.decode()
begin = text.index('    private partial async Task<string> PrepareSshAsync(')
end = text.index('    private void AdoptCancelledCleanupConnection(', begin)
method = text[begin:end].replace('private partial async Task<string>', 'public async Task<string>', 1)
out = repo / '.build/windows-preparation-flow'
out.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix='flow-', dir=out))
program = r'''
using System.Text;
using System.Text.Json;

sealed class Result
{
    public bool CleanupCancelled, ComponentsCleaned, AlreadyConfigured, AccessOnly;
    public string KeyPath = "key", KnownHostsPath = "hosts", Profile = "b31", FirmwareHash = "firmware", CleanupId = "cleanup";
    public int Port = 2222;
}
sealed class Scenario(string name, string directory)
{
    public static Scenario Current = null!;
    public string Name = name, Directory = directory;
    public Result Setup = new();
    public List<string> Events = [];
    public CancellationTokenSource Cancellation = new();
    public bool FailConnect, FailAck, FailAdb, AdbPending, CancelAdb, FailDashboard, FailCoreAck;
}
static class AdbToggleTransaction { public const string PendingName = "adb-toggle-pending.json"; }
sealed class OnboardingEngine
{
    public OnboardingEngine(string host, string storage, string resources, object adb, bool skip, Action<string> progress) { }
    public string ExistingKeyPath = "", ExistingKnownHostsPath = "";
    public string? ExpectedReplacementCid;
    public int ExistingPort;
    public Func<object>? ExistingSshFactory;
    public Task<Result> ReplaceCoreAsync(string web, string agent, string suffix, CancellationToken ct)
    {
        var s = Scenario.Current; s.Events.Add("prepare");
        File.WriteAllText(Path.Combine(s.Directory,"core-replacement-pending.json"),"complete");
        if (s.Setup.ComponentsCleaned) File.WriteAllText(Path.Combine(s.Directory, "component-cleanup-pending.json"), "verified receipt");
        return Task.FromResult(s.Setup);
    }
    public Task<string?> CompletedCoreReplacementIdAsync(CancellationToken ct) => Task.FromResult<string?>("synthetic-complete");
    public Task AcknowledgeCoreReplacementAsync(CancellationToken ct) {
        var s=Scenario.Current;s.Events.Add("core-ack");
        if(s.FailCoreAck)throw new IOException("core receipt not saved");
        File.Delete(Path.Combine(s.Directory,"core-replacement-pending.json"));return Task.CompletedTask;
    }
    public Task AcknowledgeComponentCleanupAsync(string id, CancellationToken ct)
    {
        var s = Scenario.Current; s.Events.Add("ack");
        if (s.FailAck) throw new IOException("backup verification failed");
        File.Delete(Path.Combine(s.Directory, "component-cleanup-pending.json")); return Task.CompletedTask;
    }
}
sealed class DeviceFeatureService
{
    public const string FirmwareHash = "firmware";
    public string? CompletedCoreReplacementId;
    public Task<bool> InstallDashboardForCurrentAgentAsync(CancellationToken ct)
    {
        var s = Scenario.Current; s.Events.Add("dashboard");
        if (File.Exists(Path.Combine(s.Directory, AdbToggleTransaction.PendingName))) throw new Exception("Dashboard reached with uncertain ADB");
        if (s.FailDashboard) throw new IOException("dashboard failed");
        return Task.FromResult(true);
    }
}
sealed class WindowsModemService
{
    private string _host = "192.0.2.1", _keyPath = "key", _knownHostsPath = "hosts", _resources = "resources";
    private readonly string _storage;
    private int _port = 2222;
    private bool _skipFirmwareCheck = false;
    private object _adb = new(), _ssh = null!, _sshRead = null!;
    private DeviceFeatureService _features = new();
    private sealed class Snapshot { public string? Serial = null; }
    private Snapshot _snapshot = new();
    private string KeyPath => _keyPath;
    private string KnownHostsPath => _knownHostsPath;
    public WindowsModemService(string storage) => _storage = storage;
    private static string Param(IReadOnlyDictionary<string,string>? values, string name, string fallback = "") => values?.GetValueOrDefault(name) ?? fallback;
    private void Log(string level, string message) { }
    private void AdoptCancelledCleanupConnection(string host, Result setup) => Scenario.Current.Events.Add("adopt-cancelled");
    private Task<string> ConnectAsync(IReadOnlyDictionary<string,string> connection, CancellationToken ct)
    {
        var s = Scenario.Current; s.Events.Add("connect");
        if (s.FailConnect) throw new IOException("SSH failed");
        return Task.FromResult("SSH authenticated");
    }
    private Task<string> SetAdbEnabledAsync(IReadOnlyDictionary<string,string> desired, CancellationToken ct)
    {
        var s = Scenario.Current; s.Events.Add("adb");
        if (desired["enabled"] != "false") throw new Exception("Unexpected ADB enable");
        if (File.Exists(Path.Combine(s.Directory, "component-cleanup-pending.json"))) throw new Exception("Cleanup not acknowledged before ADB");
        if (s.AdbPending) File.WriteAllText(Path.Combine(s.Directory, AdbToggleTransaction.PendingName), "uncertain dispatch");
        if (s.CancelAdb) { s.Cancellation.Cancel(); ct.ThrowIfCancellationRequested(); }
        if (s.FailAdb) throw new IOException("ADB control unavailable");
        return Task.FromResult("off");
    }
METHOD
}
static class Program
{
    static async Task Main(string[] args)
    {
        foreach (var name in new[] { "fresh", "generic", "already-ready", "clean", "cancelled", "connect-failed", "ack-failed", "adb-warning", "adb-pending", "clean-adb-pending", "adb-cancelled", "dashboard-failed", "core-ack-failed" })
        {
            var folder = Path.Combine(args[0], name); Directory.CreateDirectory(folder);
            var s = Scenario.Current = new Scenario(name, folder);
            s.Setup.ComponentsCleaned = name is "clean" or "ack-failed" or "clean-adb-pending";
            s.Setup.CleanupCancelled = name == "cancelled";
            s.Setup.AlreadyConfigured = name == "already-ready";
            if (name == "generic") s.Setup.Profile = "linux-arm64-access";
            s.FailConnect = name == "connect-failed"; s.FailAck = name == "ack-failed";
            s.FailAdb = name is "adb-warning" or "adb-pending" or "clean-adb-pending";
            s.AdbPending = name is "adb-pending" or "clean-adb-pending";
            s.FailCoreAck=name=="core-ack-failed";s.CancelAdb = name == "adb-cancelled"; s.FailDashboard = name == "dashboard-failed";
            string? result = null; Exception? failure = null;
            try { result = await new WindowsModemService(folder).PrepareSshAsync(null, s.Cancellation.Token); }
            catch (Exception error) { failure = error; }
            var expected = name switch {
                "cancelled" => "prepare,adopt-cancelled",
                "connect-failed" => "prepare,connect",
                "ack-failed" => "prepare,connect,ack",
                "clean" or "clean-adb-pending" => "prepare,connect,ack,dashboard,core-ack,adb",
                "already-ready" => "prepare,connect",
                "dashboard-failed" => "prepare,connect,dashboard",
                "core-ack-failed" => "prepare,connect,dashboard,core-ack",
                _ => "prepare,connect,dashboard,core-ack,adb",
            };
            if (string.Join(',', s.Events) != expected) throw new Exception(name + ": unexpected service order " + string.Join(',', s.Events));
            var shouldFail = name is "connect-failed" or "ack-failed" or "adb-cancelled" or "dashboard-failed" or "core-ack-failed";
            if ((failure is not null) != shouldFail) throw new Exception(name + ": wrong completion outcome");
            if ((s.FailDashboard || s.FailCoreAck) && !File.Exists(Path.Combine(folder,"core-replacement-pending.json"))) throw new Exception(name+": core receipt lost before dashboard acknowledgement");
            if (s.FailAdb && result?.Contains("Отключение ADB не подтверждено") != true) throw new Exception(name + ": lost ADB warning");
            if (s.AdbPending && (!File.Exists(Path.Combine(folder, AdbToggleTransaction.PendingName)) || result?.Contains("Проверить состояние ADB") != true)) throw new Exception(name + ": unknown dispatch lost recovery instructions");
            Console.WriteLine("PASS actual preparation service flow: " + name);
        }
    }
}
'''.replace('METHOD', method)
(stage / 'Program.cs').write_text(program)
(stage / 'Flow.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NuGetAudit>false</NuGetAudit></PropertyGroup></Project>''')
command = [shutil.which('dotnet'), 'run', '--project', str(stage / 'Flow.csproj'), '--', str(stage / 'fixture')]
result = subprocess.run(command, cwd=repo, capture_output=True, text=True)
(stage / 'test.log').write_text(result.stdout + result.stderr)
receipt = {'success': result.returncode == 0 and source.read_bytes() == original,
           'exitCode': result.returncode, 'sourceSha256': hashlib.sha256(original).hexdigest(),
           'sourcesUnchanged': source.read_bytes() == original,
           'passedScenarios': sum(line.startswith('PASS ') for line in result.stdout.splitlines()), 'deviceAccess': False}
(stage / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({**receipt, 'receipt': str(stage / 'receipt.json')}))
if not receipt['success']: print(result.stdout + result.stderr)
raise SystemExit(0 if receipt['success'] else 1)
