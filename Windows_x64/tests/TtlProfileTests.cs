using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

static class TtlProfileTests
{
    static int checks;
    static void Check(bool value, string name) { if (!value) throw new Exception("FAIL " + name); Console.WriteLine("PASS " + name); checks++; }
    static async Task<int> Main(string[] args)
    {
        try { await Run(args[0]); Console.WriteLine("TOTAL " + checks + " PASS"); return 0; }
        catch (Exception e) { Console.WriteLine(e); return 1; }
    }
    static async Task Run(string root)
    {
        var resources = Path.GetFullPath("Windows_x64/Resources");
        DeviceFeatureService Service(Fake f, string name) => new(f, resources, Path.Combine(root, name));
        foreach (var firmware in new[] { "b28", "b31", "b04", "b04-image" })
        {
            var f = new Fake { Firmware = firmware }; var service = Service(f, firmware);
            var before = await service.GetTtlStatusAsync();
            Check(before.State == "disabled" && f.Installs == 0, firmware + " status does not install or apply defaults");
            var result = await service.SetTtlAsync(64, 1);
            Check(result.State == "configured" && result.Outbound == 64 && result.InboundIncrement == 1 && f.Installs == 1,
                firmware + " explicit install reaches the component helper without skipFirmwareCheck");
            Check(f.MeasuredReads >= 2, firmware + " mutation retains root/platform/device identity checks");
            var uploads = f.Uploads;
            result = await service.SetTtlAsync(65, null);
            Check(result.Outbound == 65 && result.InboundIncrement == null && f.Installs == 1 && f.Uploads == uploads,
                firmware + " existing helper applies an independent direction without reinstall");
            Check(f.Commands.Any(c => c.Contains(Fake.PreviousManagerHash) && c.Contains("case \"$manager_hash\"")),
                firmware + " accepts the previously shipped B31 helper hash");
            Check(f.Commands.Any(c => c.Contains("79d5a2e696613f966fe2dff3fe59a0366455fe16681284c65d8ddb36c5e35b5a") && c.Contains("case \"$manager_hash\"")),
                firmware + " accepts 1.24.18 B31/B28 helper hash");
            Check(f.Commands.Any(c => c.Contains("a70afc13c3645f64b5fd937162e7d403e133bcfa0a2da0e565d39a693f9ab488") && c.Contains("case \"$manager_hash\"")),
                firmware + " accepts 1.24.20 B31/B28/B04 helper hash");
            result = await service.SetTtlAsync(null, null);
            Check(result.State == "disabled" && f.Disables == 1, firmware + " explicit disable remains available");
        }
        var old = new Fake { Installed = true, ManagerHash = "a70afc13c3645f64b5fd937162e7d403e133bcfa0a2da0e565d39a693f9ab488" };
        var oldService = Service(old, "old");
        _ = await oldService.GetTtlStatusAsync();
        Check(old.Upgrades == 0 && old.Uploads == 0, "old helper refresh does not upgrade or upload");
        _ = await oldService.SetTtlAsync(65, 2);
        Check(old.Upgrades == 1 && old.Outbound == 65 && old.Uploads == 4, "explicit Apply upgrades a70af before settings change");
        _ = await oldService.SetTtlAsync(66, 2);
        Check(old.Upgrades == 1 && old.Uploads == 4 && old.Outbound == 66, "current helper not replaced again");
        foreach (var hash in new[] { "e4684cb0fa040de0525d0248897da01a5af2c4ee8509a851719afe9c970e9194", "a70afc13c3645f64b5fd937162e7d403e133bcfa0a2da0e565d39a693f9ab488", "79d5a2e696613f966fe2dff3fe59a0366455fe16681284c65d8ddb36c5e35b5a", Fake.PreviousManagerHash })
        {
            var legacy = new Fake { Installed = true, ManagerHash = hash };
            var legacyService = Service(legacy, "legacy-" + hash[..8]);
            _ = await legacyService.GetTtlStatusAsync();
            Check(legacy.Upgrades == 0 && legacy.Uploads == 0, "legacy status does not mutate " + hash[..8]);
            _ = await legacyService.SetTtlAsync(null, null);
            Check(legacy.Upgrades == 1 && legacy.Disables == 1, "explicit disable upgrades known previous manager " + hash[..8]);
        }
        var pending = new Fake { Installed = true, ManagerHash = "a70afc13c3645f64b5fd937162e7d403e133bcfa0a2da0e565d39a693f9ab488", FailUpgrade = true };
        try { await Service(pending, "pending").SetTtlAsync(65, 2); throw new Exception("pending accepted"); }
        catch (DeviceFeatureException e) { Check(e.Message.Contains("UPGRADE_PENDING") && pending.Outbound == null && pending.Attempts == 1, "upgrade failure blocks Apply"); }
        var platform = new Fake { PlatformFailure = true };
        try { await Service(platform, "platform").SetTtlAsync(64, 1); throw new Exception("platform accepted"); }
        catch (Exception e) when (e is DeviceFeatureException or InvalidDataException)
        { Check(platform.Uploads == 0 && platform.Installs == 0, "invalid platform stops before upload"); }
        var refusal = new Fake { HelperError = true };
        try { await Service(refusal, "refusal").SetTtlAsync(64, 1); throw new Exception("refusal accepted"); }
        catch (DeviceFeatureException e)
        { Check(e.Message.Contains("TTL_ERROR UNSUPPORTED_PROFILE") && refusal.Attempts == 1, "component-specific refusal is surfaced once without fallback"); }
        var drift = new Fake { Drift = true };
        try { await Service(drift, "drift").SetTtlAsync(64, 1); throw new Exception("drift accepted"); }
        catch (DeviceFeatureException)
        { Check(drift.MeasuredReads == 2, "changed modem identity prevents successful acknowledgement"); }
    }
    sealed class Fake : IRemoteShell
    {
        public const string PreviousManagerHash = "b6588072c82ddd7678093a29b983ec4417c6807562819e3bda69cd6534637b7c";
        public string Firmware = "b28";
        public string ManagerHash = "current";
        public bool FailUpgrade;
        public int Upgrades;
        public bool Installed, PlatformFailure, HelperError, Drift;
        public int MeasuredReads, Uploads, Installs, Disables, Attempts;
        public int? Outbound, Inbound;
        public List<string> Commands = [];
        const string Cid = "11111111111111111111111111111111", Boot = "11111111-1111-1111-1111-111111111111";
        static string Hash(byte[] b) => Convert.ToHexStringLower(SHA256.HashData(b));
        static RemoteResult Result(string s, int code = 0) => new(code, code == 0 ? Encoding.UTF8.GetBytes(s) : [], code == 0 ? [] : Encoding.UTF8.GetBytes(s));
        string Identity() => (Firmware == "b31" ? DeviceFeatureService.FirmwareHash : Firmware == "b04" ? "absent" : Firmware == "b04-image" ? "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81" : "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478") + "  /firmware/image/modem.b16\n" + DeviceFeatureService.RouterHash + "  /usr/bin/diag-router\n" + Cid + "\n" + (Drift && MeasuredReads > 1 ? "22222222-2222-2222-2222-222222222222" : Boot) + "\n";
        string Status() => "TTL_STATUS state=" + (Outbound == null && Inbound == null ? "disabled" : "configured") + " outbound=" + (Outbound?.ToString() ?? "off") + " inbound_inc=" + (Inbound?.ToString() ?? "off") + " capability=supported verification=" + (Outbound == null && Inbound == null ? "not-applicable" : "unverified") + " persistence=" + (Installed ? "boot" : "none") + "\n";
        public Task<RemoteResult> RunAsync(string command, byte[]? input = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            Commands.Add(command); ct.ThrowIfCancellationRequested(); RemoteResult result;
            if (command == AccessIdentity.Command) { MeasuredReads++; result = Result(PlatformFailure ? "PLATFORM" : Identity(), PlatformFailure ? 71 : 0); }
            else if (command.StartsWith("if test -e /data/zte-imei-ttl")) result = Result(Installed ? "installed" : "absent");
            else if (command.StartsWith("test -f /data/zte-imei-ttl/manager.sh")) result = Result(ManagerHash);
            else if (input is not null && command.Contains("cat > '")) { Uploads++; var path = Regex.Match(command, @"cat > '([^']+)'").Groups[1].Value; result = Result(Hash(input) + "  " + path); }
            else if (command.Contains("; sh ") && command.Contains("/manager.sh"))
            {
                var action = Regex.Match(command, @"(?:/manager.sh'? )(?<action>status|install|apply|disable|upgrade) ").Groups["action"].Value;
                if (action != "status") Attempts++;
                if (FailUpgrade && action == "upgrade") result = Result("TTL_ERROR UPGRADE_PENDING", 1);
                else if (HelperError && action != "status") result = Result("TTL_ERROR UNSUPPORTED_PROFILE", 1);
                else
                {
                    if (action is "install" or "apply")
                    {
                        var matches = Regex.Matches(command, "'([^']*)'");
                        var values = matches.Select(m => m.Groups[1].Value).ToArray();
                        Outbound = values[^2] == "off" ? null : int.Parse(values[^2]);
                        Inbound = values[^1] == "off" ? null : int.Parse(values[^1]);
                        if (action == "install") { Installed = true; Installs++; }
                    }
                    else if (action == "upgrade") { ManagerHash = "current"; Upgrades++; }
                    else if (action == "disable") { Outbound = Inbound = null; Disables++; }
                    else if (action != "status") throw new Exception("Unexpected helper action");
                    result = Result(Status());
                }
            }
            else if (command.Contains("/tmp/zte-imei-app.lock") || command.Contains("mkdir -m 700 '/tmp/") || command.Contains("; rmdir '/tmp/")) result = Result("");
            else throw new Exception("Unexpected synthetic command");
            return Task.FromResult(result);
        }
        public Task UploadAsync(string path, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("unexpected upload");
        public Task<byte[]> DownloadAsync(string path, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("unexpected download");
    }
}
