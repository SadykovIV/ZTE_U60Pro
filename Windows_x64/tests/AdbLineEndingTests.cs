using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Research;

internal static class AdbLineEndingTests
{
    private const string Marker = "__ZTE_RESULT_0123456789ABCDEF0123456789ABCDEF__";
    private const string ResearchMarker = "__FR_RESULT_0123456789abcdef0123456789abcdef__";
    private static RemoteResult Reply(string text, int localCode = 0) => new(localCode, Encoding.UTF8.GetBytes(text), []);
    private static void Need(bool value) { if (!value) throw new Exception("Assertion failed"); }
    private static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
    private static Task<ResearchCommandResult> ResearchReply(string output, string marker = ResearchMarker, int maxBytes = 4096, int localCode = 0) =>
        ResearchAdbShell.RunAsync("/bin/sh", ["-c", "printf '%s' " + Quote(output) + "; exit " + localCode], 3, maxBytes, marker, CancellationToken.None);

    public static async Task RunAsync(string? exportFixturePath = null)
    {
        var failures = new List<string>(); var passed = 0;
        async Task Test(string name, Func<Task> body)
        {
            try { await body(); Console.WriteLine("PASS " + name); passed++; }
            catch (Exception e) { Console.WriteLine("FAIL " + name + " (" + e.GetType().Name + ")"); failures.Add(name); }
        }
        Task Sync(Action body) { body(); return Task.CompletedTask; }
        foreach (var (ending, name) in new[] { ("\n", "LF"), ("\r\n", "CRLF"), ("\r\r\n", "CRCRLF") })
        {
            await Test("ADB marker " + name + " preserves payload bytes", () => Sync(() =>
            {
                byte[] payload = [0, 255, 13, 10, 13, 13, 10, 42, 13];
                var raw = payload.Concat(Encoding.ASCII.GetBytes(ending + Marker + "7" + ending)).ToArray();
                var result = AdbTransport.DecodeShellResult(new(0, raw, [99]), Marker);
                Need(result.ExitCode == 7 && result.Stdout.SequenceEqual(payload) && result.Stderr.SequenceEqual(new byte[] { 99 }));
            }));
            await Test("Identity " + name + " passes exact firmware/router checks", () => Sync(() =>
            {
                var web = new WebIdentity("353490068701222", "CN_ZTE_MU5250V1.0.0B31", "BD_CNMU5250V1.0.0B31");
                var text = ImeiEngine.FirmwareHash + "  /firmware/image/modem.b16" + ending + ImeiEngine.RouterHash + "  /usr/bin/diag-router" + ending +
                    new string('a', 32) + ending + "10000000-0000-0000-0000-000000000001" + ending +
                    JsonSerializer.Serialize(new { imei = web.Imei, integrate_version = web.Firmware, wa_inner_version = web.Inner });
                var proof = OnboardingEngine.ParseIdentity(Encoding.UTF8.GetBytes(text), web);
                Need(proof.FirmwareHash == ImeiEngine.FirmwareHash && proof.Cid == new string('a', 32));
            }));
            await Test("FR_FACT " + name + " preserves exact values", () => Sync(() =>
            {
                var facts = FirmwareResearchEngine.Facts(new("success", 0, "FR_FACT architecture=aarch64" + ending + "FR_FACT root=1" + ending, ""));
                Need(facts.GetValueOrDefault("architecture") == "aarch64" && facts.GetValueOrDefault("root") == "1");
            }));
            if (!OperatingSystem.IsWindows())
                await Test("Research marker " + name + " retains remote nonzero", async () =>
                {
                    var result = await ResearchReply("partial" + ending + ResearchMarker + "7" + ending);
                    Need(result.Status == "failed" && result.ExitCode == 7 && result.LocalExitCode == 0 && result.Stdout == "partial");
                });
        }
        foreach (var suffix in new[] { "0\r\r\r\n", "00\n", "256\n", "-1\n", "0\nextra", "0\n\n", "0", "0 \n" })
            await Test("Malformed completion rejected " + Convert.ToHexString(Encoding.ASCII.GetBytes(suffix)), () => Sync(() =>
            {
                try { AdbTransport.DecodeShellResult(Reply("\n" + Marker + suffix), Marker); }
                catch (InvalidDataException) { return; }
                throw new Exception("Accepted malformed completion");
            }));
        foreach (var raw in new[] { "output", "\n" + Marker + "0\n\n" + Marker + "0\n", "prefix" + Marker + "0\n" })
            await Test("Missing duplicate or embedded completion rejected " + raw.Length, () => Sync(() =>
            {
                try { AdbTransport.DecodeShellResult(Reply(raw), Marker); }
                catch (InvalidDataException) { return; }
                throw new Exception("Accepted unverified completion");
            }));
        await Test("Local ADB failure cannot authorize valid remote marker", () => Sync(() =>
        {
            try { AdbTransport.DecodeShellResult(Reply("\n" + Marker + "0\n", 1), Marker); }
            catch (IOException) { return; }
            throw new Exception("Accepted local failure");
        }));
        await Test("Marker delimiter must match footer EOL exactly", () => Sync(() =>
        {
            foreach (var prefix in new[] { "\n", "\r\n", "\rX\n" })
            {
                try { AdbTransport.DecodeShellResult(Reply(prefix + Marker + "0\r\r\n"), Marker); }
                catch (InvalidDataException) { continue; }
                throw new Exception("Accepted shorter or malformed delimiter");
            }
        }));
        await Test("Remote status 255 is preserved", () => Sync(() =>
            Need(AdbTransport.DecodeShellResult(Reply("\r\r\n" + Marker + "255\r\r\n"), Marker).ExitCode == 255)));
        await Test("Text parsing does not accept isolated or excessive CR", () => Sync(() =>
        {
            foreach (var ending in new[] { "\r", "\r\r\r\n" })
                Need(FirmwareResearchEngine.Facts(new("success", 0, "FR_FACT root=1" + ending, "")).Count == 0);
        }));
        await Test("Installer multiline CRCRLF receipts become canonical text", async () =>
        {
            var adb = new AdbTransport((args, _, _) =>
            {
                var marker = Regex.Match(args[3], "__ZTE_RESULT_[A-F0-9]{32}__").Value;
                return Task.FromResult(Reply("INSTALL_READY synthetic\r\r\nINSTALL_AGENT new\r\r\n\n" + marker + "0\n"));
            });
            var engine = new OnboardingEngine("192.0.2.1", Path.GetTempPath(), Path.GetTempPath(), adb);
            var method = typeof(OnboardingEngine).GetMethod("AdbTextAsync", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var output = await (Task<string>)method.Invoke(engine, ["synthetic", "synthetic-read", TimeSpan.FromSeconds(1), CancellationToken.None])!;
            Need(output.Split('\n').SequenceEqual(["INSTALL_READY synthetic", "INSTALL_AGENT new"]));
        });
        await Test("Failed or incomplete facts cannot authorize capabilities", () => Sync(() =>
        {
            foreach (var value in new ResearchCommandResult[] { new("failed", 7, "FR_FACT root=1\n", ""), new("failed", null, "FR_FACT root=1\n", ""), new("truncated", 0, "FR_FACT root=1\n", "", true) })
                Need(FirmwareResearchEngine.Facts(value).Count == 0);
        }));
        if (!OperatingSystem.IsWindows())
        {
            foreach (var output in new[] { "FR_FACT root=1\r\r\n", "\n" + ResearchMarker + "0", "\n" + ResearchMarker + "0\n\n" + ResearchMarker + "0\n", "\n" + ResearchMarker + "0\r\r\r\n" })
                await Test("Research rejects missing truncated duplicate or malformed completion " + output.Length, async () =>
                {
                    var result = await ResearchReply(output);
                    Need(result.Status == "failed" && result.ExitCode is null && FirmwareResearchEngine.Facts(result).Count == 0);
                });
            await Test("Research detects duplicate marker outside retained tail", async () =>
            {
                var result = await ResearchReply("\n" + ResearchMarker + "0\n" + new string('x', 8192) + "\n" + ResearchMarker + "0\n", maxBytes: 64);
                Need(result.Status == "failed" && result.ExitCode is null);
            });
            await Test("Research truncation retains authenticated completion but no capability facts", async () =>
            {
                var result = await ResearchReply("FR_FACT root=1\r\r\n" + new string('x', 8192) + "\r\r\n" + ResearchMarker + "0\r\r\n", maxBytes: 64);
                Need(result.Status == "truncated" && result.ExitCode == 0 && result.Truncated && FirmwareResearchEngine.Facts(result).Count == 0);
            });
            if (exportFixturePath is not null)
            {
                using var document = JsonDocument.Parse(await File.ReadAllBytesAsync(exportFixturePath));
                foreach (var fixture in document.RootElement.EnumerateArray())
                {
                    var id = fixture.GetProperty("id").GetString()!;
                    await Test("Sanitized ZIP " + fixture.GetProperty("zip").GetString() + " " + id, async () =>
                    {
                        var result = await ResearchReply(fixture.GetProperty("stdout").GetString()!, fixture.GetProperty("marker").GetString()!);
                        var facts = FirmwareResearchEngine.Facts(result);
                        Need(result.Status == "success" && result.ExitCode == 0 && result.LocalExitCode == 0);
                        Need(id == "identity" ? facts.GetValueOrDefault("architecture") == "aarch64" && facts.GetValueOrDefault("root") == "1" : facts.ContainsKey("cid_sha256") && facts.ContainsKey("boot_sha256"));
                    });
                }
            }
            await Test("Research engine advances beyond CRCRLF fingerprint and identity", async () =>
            {
                var label = new ResearchText("Fixture", "Fixture");
                var spec = new ResearchSpec(1, 1, [new("fixture", "firmware", "router", "aarch64")],
                    [new("fingerprint", label, "identity", "fingerprint", 3, 4096), new("identity", label, "identity", "identity", 3, 4096), new("firmware-hashes", label, "identity", "hashes", 3, 4096), new("tools", label, "apps", "tools", 3, 4096)],
                    [new("read", label, ["fixture"], [new("identity", "root", "1", label), new("tools", "tool", "1", label)], label)]);
                var factory = new FixtureFactory();
                var report = await new FirmwareResearchEngine(spec, factory, new ResearchRedactor()).CollectAsync("ADB", null, null, CancellationToken.None);
                Need(report.Profile == "fixture" && report.Probes.Any(x => x.Id == "tools" && x.Status == "success") && report.Features.Single().State == "prerequisites_met");
            });
        }
        Console.WriteLine($"ADB line-ending checks: {passed} passed, {failures.Count} failed; no modem used.");
        if (failures.Count != 0) throw new Exception("ADB line-ending regression failures: " + failures.Count);
    }

    private sealed class FixtureFactory : IResearchTransportFactory, IResearchShell
    {
        public bool SshConfigured => false;
        public string Channel => "ADB";
        public IResearchShell OpenSsh() => throw new Exception("Unexpected SSH");
        public IResearchShell OpenAdb(string serial) => this;
        public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct) => Task.FromResult(new ResearchCommandResult("success", null, "synthetic device usb:1\n", "", LocalExitCode: 0));
        public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct) => Task.FromResult(new ResearchCommandResult("success", null, "synthetic\n", "", LocalExitCode: 0));
        public Task<ResearchCommandResult> ExecuteAsync(string command, int seconds, int maxBytes, CancellationToken ct)
        {
            var text = command switch
            {
                "identity" => "FR_FACT architecture=aarch64\nFR_FACT root=1\n",
                "hashes" => "FR_FACT firmware_sha256=firmware\nFR_FACT router_sha256=router\n",
                "tools" => "FR_FACT tool=1\n",
                _ => "FR_FACT cid_sha256=" + new string('a', 64) + "\nFR_FACT boot_sha256=" + new string('b', 64) + "\n",
            };
            return ResearchReply((text + "\n" + ResearchMarker + "0\n").Replace("\n", "\r\r\n", StringComparison.Ordinal));
        }
    }
}
