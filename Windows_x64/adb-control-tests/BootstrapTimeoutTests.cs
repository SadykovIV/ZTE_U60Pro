using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class BootstrapTimeoutTests
{
    internal static async Task Run(string fixture, Action<bool, string> check)
    {
        var resources = Path.Combine(fixture, "timeout-resources");
        var calls = new List<string>();
        var adb = new AdbTransport((args, _, _) =>
        {
            if (args[2] == "push") { calls.Add("push"); return Task.FromResult(new RemoteResult(0, [], [])); }
            var command = args[^1]; calls.Add(command);
            var marker = Regex.Match(command, "__ZTE_RESULT_[A-F0-9]{32}__").Value;
            return Task.FromResult(new RemoteResult(0, Encoding.UTF8.GetBytes("\n" + marker + "0\n"), []));
        });
        var engine = new OnboardingEngine("192.0.2.1", Path.Combine(fixture, "timeout-storage"), resources, adb);
        await engine.VerifyGenericTimeoutAsync(default);
        check(calls.Count == 0, "bundled timeout hash verified locally without modem timeout dependency");
        await engine.StageGenericTimeoutAsync("synthetic", "/data/local/tmp/zte-imei-setup-00000000-0000-0000-0000-000000000001", "synthetic-owner", default);
        check(calls.Count == 2 && calls[0] == "push" && calls[1].Contains("/zte-timeout") && calls[1].Contains(OnboardingEngine.GenericTimeoutSha256) && calls[1].Contains(".install-requested"), "timeout transfer retains exact remote hash/owner and pre-dispatch guard");
        var path = Path.Combine(resources, "HostTools", "zte-timeout");
        var original = File.ReadAllBytes(path); File.WriteAllBytes(path, "synthetic-invalid"u8.ToArray());
        try
        {
            var before = calls.Count;
            try { await engine.StageGenericTimeoutAsync("synthetic", "/data/local/tmp/zte-imei-setup-00000000-0000-0000-0000-000000000001", "synthetic-owner", default); throw new Exception("bad timeout accepted"); }
            catch (InvalidDataException) { check(calls.Count == before, "changed timeout rejects before any upload or install"); }
        }
        finally { File.WriteAllBytes(path, original); }
    }
}
