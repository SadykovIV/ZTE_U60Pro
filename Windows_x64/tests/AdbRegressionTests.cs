using System.Text;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using System.Text.Json;

internal static class AdbRegressionTests
{
    public static async Task RunAsync()
    {
        static void Check(bool value, string name)
        {
            if (!value) throw new Exception(name);
            Console.WriteLine("PASS " + name);
        }
        static RemoteResult Reply(string text, int code = 0) => new(code, Encoding.UTF8.GetBytes(text), []);
        static AdbTransport Fake(string listing, string proof, int proofCode, List<string> calls) =>
            new((args, _, _) =>
            {
                var command = string.Join(' ', args);
                calls.Add(command);
                return Task.FromResult(command switch
                {
                    "devices -l" => Reply(listing),
                    "-d get-serialno" => Reply(proof, proofCode),
                    _ => throw new Exception("Unexpected ADB command: " + command),
                });
            });

        var calls = new List<string>();
        var windows = Fake("List of devices attached\r\nZTE123 device product:MU5250 model:MU5250 transport_id:1\r\n", "ZTE123\r\n", 0, calls);
        Check(await windows.SelectSingleUsbSerialAsync() == "ZTE123" && calls.SequenceEqual(["devices -l", "-d get-serialno"]),
            "Windows device without usb descriptor is accepted only after adb -d proof");

        calls.Clear();
        var unproved = await Fake("ZTE123 device transport_id:1\n", "OTHER\n", 0, calls).InspectUsbAsync();
        Check(unproved.ReadyDevices.Count == 0 && unproved.UnavailableReason.Contains("не подтвердил"),
            "Mismatched USB proof cannot authorize device");
        calls.Clear();
        var ambiguous = await Fake("ZTE123 device\nOTHER device\n", "", 1, calls).InspectUsbAsync();
        Check(ambiguous.ReadyDevices.Count == 0, "Ambiguous descriptor-free USB list cannot select a device");

        calls.Clear();
        var explicitUsb = await Fake("ZTE123 device usb:1-2 transport_id:1\n192.168.0.1:5555 device\nemulator-5554 device\n", "", 1, calls).InspectUsbAsync();
        Check(explicitUsb.ReadyDevices.Single().Serial == "ZTE123" && calls.Count == 1,
            "USB descriptor is supported while TCP and emulator entries are excluded");
        calls.Clear();
        var tcpOnly = await Fake("192.168.0.1:5555 device\nadb-test._adb-tls-connect._tcp device\nemulator-5554 device\n", "192.168.0.1:5555\n", 0, calls).InspectUsbAsync();
        Check(tcpOnly.ReadyDevices.Count == 0 && calls.Count == 1, "Network ADB is never promoted to USB");

        foreach (var state in new[] { "offline", "unauthorized", "no permissions" })
        {
            calls.Clear();
            var inventory = await Fake("ZTE123 " + state + " usb:1-2\n", "ZTE123\n", 0, calls).InspectUsbAsync();
            Check(inventory.ReadyDevices.Count == 0 && inventory.ObservedDevices.Single().State == state,
                "ADB " + state + " remains visible but cannot authorize a shell");
            Check(calls.Count == 1, "Status check does not reconnect or mutate " + state + " device");
        }
        try
        {
            AdbTransport.ParseDeviceList("ZTE123 device usb:1-2\nZTE123 offline usb:1-2\n");
            throw new Exception("Duplicate serial accepted");
        }
        catch (InvalidDataException) { Check(true, "Duplicate device states rejected"); }
        var failedList = new AdbTransport((_, _, _) => Task.FromResult(Reply("", 1)));
        try { await failedList.InspectUsbAsync(); throw new Exception("Failed enumeration was accepted as empty USB list"); }
        catch (IOException) { Check(true, "Failed local ADB enumeration stops discovery instead of authorizing activation"); }
        const string marker = "__ZTE_RESULT_0123456789ABCDEF0123456789ABCDEF__";
        Check(AdbTransport.DecodeShellResult(Reply("not root\n" + marker + "1\n"), marker).ExitCode == 1,
            "Successful local adb cannot hide remote shell failure");
        try
        {
            AdbTransport.DecodeShellResult(Reply("0\n"), marker);
            throw new Exception("Missing remote result accepted");
        }
        catch (InvalidDataException) { Check(true, "Unverified shell result is rejected"); }

        Check(ModemWebClient.AdvertisesUsbDebug(Encoding.UTF8.GetBytes("[{\"result\":{\"zwrt_bsp.usb\":{\"set\":{\"mode\":\"String\"}}}}]")),
            "Legacy USB method requires an advertised string mode parameter");
        foreach (var response in new[]
        {
            "[{\"result\":{\"zwrt_bsp.usb\":{\"list\":{}}}}]",
            "[{\"result\":{\"zwrt_bsp.usb\":{\"set\":{\"mode\":\"Integer\"}}}}]",
            "[{\"error\":{\"code\":-32601}}]",
            "[{\"result\":[0,{\"zwrt_bsp.usb\":{\"set\":{\"mode\":\"String\"}}}]}]",
        })
            Check(!ModemWebClient.AdvertisesUsbDebug(Encoding.UTF8.GetBytes(response)), "Unsupported USB introspection cannot enable debug");
        Check(OnboardingEngine.IsLegacyUsbDebugFirmware(new("", "CN_ZTE_MU5250V1.0.0B27", "BD_CNMU5250V1.0.0B27")),
            "Legacy CN B27 USB method fallback recognized");
        Check(!OnboardingEngine.IsLegacyUsbDebugFirmware(new("", "CN_ZTE_MU5250V1.0.0B31", "BD_CNMU5250V1.0.0B31")) &&
            !OnboardingEngine.IsLegacyUsbDebugFirmware(new("", "STD_PL_MU5250V1.0.0B02", "BD_STDPLMU5250V1.0.0B02")) &&
            !OnboardingEngine.IsLegacyUsbDebugFirmware(new("", "CN_ZTE_MU5250V1.0.0B27", "BD_CNMU5250V1.0.0B26")),
            "Unknown, B31 and mismatched firmware cannot use unconditional legacy fallback");
        var identity = new WebIdentity("353490068701222", "CN_ZTE_MU5250V1.0.0B27", "BD_CNMU5250V1.0.0B27");
        var proofBytes = Encoding.UTF8.GetBytes(ImeiEngine.FirmwareHash + "  /firmware/image/modem.b16\n" +
            new string('e', 64) + "  /usr/bin/diag-router\n" + new string('a', 32) + "\n" + Guid.NewGuid() + "\n" +
            JsonSerializer.Serialize(new { imei = identity.Imei, integrate_version = identity.Firmware, wa_inner_version = identity.Inner }));
        try { OnboardingEngine.ParseIdentity(proofBytes, identity); throw new Exception("Unknown router accepted"); }
        catch (InvalidOperationException)
        { Check(true, "Matching root shell with unsupported router stops preparation instead of triggering another ADB method"); }
        try { OnboardingEngine.ParseIdentity(proofBytes, identity with { Imei = "353490068701223" }); throw new Exception("Other modem accepted"); }
        catch (InvalidDataException)
        { Check(true, "An unrelated USB modem remains an identity mismatch"); }

        string? durable = null;
        var sent = 0;
        var pending = new OnboardingPending();
        await pending.RequestDirectAdbOnceAsync(state => { durable = JsonSerializer.Serialize(state); return Task.CompletedTask; },
            () =>
            {
                Check(durable is not null && JsonSerializer.Deserialize<OnboardingPending>(durable)!.DirectAdbRequested,
                    "Direct debug intent persisted before request");
                sent++;
                throw new TimeoutException("Synthetic USB network loss");
            });
        var resumed = JsonSerializer.Deserialize<OnboardingPending>(durable!)!;
        Check(resumed.DirectAdbOutcome == "uncertain" && !resumed.CanRequestDirectAdb && resumed.CanRequestRestore(false, false),
            "Uncertain direct debug is not repeated and does not pretend ADB is verified");
        try
        {
            await resumed.RequestDirectAdbOnceAsync(_ => Task.CompletedTask, () => { sent++; return Task.CompletedTask; });
            throw new Exception("Repeated direct debug request accepted");
        }
        catch (InvalidOperationException) { Check(sent == 1, "Restart cannot replay direct debug request"); }
        var restoring = new OnboardingPending { RestoreRequested = true };
        Check(!restoring.CanRequestDirectAdb, "Pending restore prevents falling back to a USB mutation");
        var rejected = new OnboardingPending();
        await rejected.RequestDirectAdbOnceAsync(_ => Task.CompletedTask,
            () => throw new ModemWebException(WebFailureKind.RpcRejected, "Synthetic method absent", 3));
        Check(rejected.DirectAdbOutcome == "rejected", "Explicit RPC rejection is distinct from uncertain delivery");
        Check(ModemWebClient.ReadUsbDebugCapability(Encoding.UTF8.GetBytes("[{\"result\":{}}]")) == false &&
            ModemWebClient.ReadUsbDebugCapability(Encoding.UTF8.GetBytes("[{\"error\":{\"code\":-32601}}]")) is null,
            "Absent USB method differs from unavailable introspection");
        var wire = new DebugWebTransport();
        using var web = new ModemWebClient("192.168.0.1", wire);
        await web.LoginAsync("synthetic-web-password");
        Check(await web.AdvertisesUsbDebugAsync() == true, "Authenticated uhttpd list protocol verified");
        await web.RequestUsbDebugAsync();
        Check(wire.RequestCount == 4, "Exactly one fixed USB debug request follows login and method discovery");
        foreach (var (payload, expected) in new[]
        {
            ("[{\"result\":[0,{\"status\":1}]}]", WebFailureKind.RpcRejected),
            ("[{\"result\":[0,{\"result\":\"error\"}]}]", WebFailureKind.MalformedResponse),
        })
        {
            using var rejectedWeb = new ModemWebClient("192.168.0.1", new DebugWebTransport(payload));
            await rejectedWeb.LoginAsync("synthetic-web-password");
            await rejectedWeb.AdvertisesUsbDebugAsync();
            try { await rejectedWeb.RequestUsbDebugAsync(); throw new Exception("Invalid USB acknowledgment accepted"); }
            catch (ModemWebException error) { Check(error.Kind == expected, "USB method result/status cannot falsely acknowledge a rejected request"); }
        }
    }

    private sealed class DebugWebTransport(string debugReply = "[{\"result\":[0,{}]}]") : IWebTransport
    {
        public int RequestCount { get; private set; }
        public Task<WebReply> RequestAsync(string path, byte[]? data = null, string? contentType = null,
            string? cookie = null, CancellationToken ct = default)
        {
            if (path != "/ubus/" || data is null || contentType != "application/json") throw new Exception("Unexpected web request");
            using var document = JsonDocument.Parse(data);
            var request = document.RootElement[0];
            var method = request.GetProperty("method").GetString();
            var parameters = request.GetProperty("params");
            string reply;
            var headers = new Dictionary<string, string[]>();
            switch (++RequestCount)
            {
                case 1:
                    if (method != "call" || parameters[2].GetString() != "web_login_info") throw new Exception("Missing login challenge");
                    reply = "[{\"result\":[0,{\"zte_web_sault\":\"synthetic-salt\"}]}]";
                    break;
                case 2:
                    if (method != "call" || parameters[2].GetString() != "web_login") throw new Exception("Missing web login");
                    reply = "[{\"result\":[0,{\"result\":0,\"ubus_rpc_session\":\"11111111111111111111111111111111\"}]}]";
                    headers["Set-Cookie"] = ["webtoken=synthetic-cookie; Path=/"];
                    break;
                case 3:
                    if (method != "list" || parameters.GetArrayLength() != 1 || parameters[0].GetString() != "zwrt_bsp.usb" || cookie != "synthetic-cookie")
                        throw new Exception("uhttpd list must contain only object name and retain login cookie");
                    reply = "[{\"result\":{\"zwrt_bsp.usb\":{\"set\":{\"mode\":\"String\"}}}}]";
                    break;
                case 4:
                    if (method != "call" || parameters.GetArrayLength() != 4 || parameters[0].GetString() != "11111111111111111111111111111111" ||
                        parameters[1].GetString() != "zwrt_bsp.usb" || parameters[2].GetString() != "set" ||
                        parameters[3].GetProperty("mode").GetString() != "debug" || parameters[3].EnumerateObject().Count() != 1)
                        throw new Exception("USB request must be fixed authenticated set mode debug");
                    reply = debugReply;
                    break;
                default: throw new Exception("Unexpected repeated web mutation");
            }
            return Task.FromResult(new WebReply(Encoding.UTF8.GetBytes(reply), headers));
        }
    }
}
