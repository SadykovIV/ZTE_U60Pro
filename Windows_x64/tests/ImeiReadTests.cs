using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class ImeiReadTests
{
    private const string Primary = "353490068701222", Secondary = "353490068701230";
    private const string B04 = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
    private static int checks;
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; Console.WriteLine("PASS IMEI read: " + message); }
    private static async Task Reject(Func<Task> action, string message) { try { await action(); } catch (Exception error) when (error is IOException or InvalidDataException) { Check(true, message); return; } throw new Exception(message); }
    public static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "zte-imei-read-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "Resources", "Helpers"));
        var bytes = Encoding.UTF8.GetBytes("Synthetic helper");
        await File.WriteAllBytesAsync(Path.Combine(root,"Resources","Helpers","zte_nv"), bytes);
        await File.WriteAllTextAsync(Path.Combine(root,"Resources","Helpers","helpers.json"), JsonSerializer.Serialize(new Dictionary<string,string> { ["zte_nv"] = VerifiedHash.Sha256(bytes) }));
        try
        {
            for (var index = 0; index < 3; index++)
            {
                var shell = new Fake { Firmware = index == 0 ? ImeiEngine.FirmwareHash : index == 1 ? B04 : "absent", Inactive = index != 0 };
                var engine = new ImeiEngine(shell, Path.Combine(root, "state" + index), Path.Combine(root, "Resources"), true);
                var state = await engine.ReadImeiAsync();
                Check(state.Primary == Primary && state.Secondary == (shell.Inactive ? null : Secondary), "pair/primary returned without duplication");
                Check(state.Identity.FirmwareHash == shell.Firmware && shell.Reads == 1 && shell.IdentityReads == 2, "actual firmware and before/after identity retained");
                Check(shell.SecondaryApiReads == (shell.Inactive ? 0 : 1), "only readable IMEIs compared with API");
                Check(shell.Snapshots == 0 && shell.ConfigReads == 0, "display read does not request backup or config");
                if (shell.Inactive)
                {
                    Check(state.Detail.Contains("статус 5"), "inactive NV explicitly explained");
                    await Reject(async () => { await engine.InspectAsync(); }, "snapshot rejects a failed helper response");
                    await Reject(async () => { await engine.CreateBackupAsync(); }, "backup rejects a failed helper response");
                    Check(shell.ConfigReads == 0, "failed snapshot does not continue to EFS backup");
                }
            }
            var good = "APP_IMEI index=0 value=" + Primary + "\n";
            foreach (var invalid in new[] { good, good + good, good + "APP_IMEI index=1 state=not-active nv_status=4\n", good + "APP_IMEI index=1 value=bad\n", good + "APP_IMEI index=1 value=" + Secondary + " extra=1\n" })
            {
                var fake = new Fake { Output = invalid };
                await Reject(async () => { await new ImeiEngine(fake, Path.Combine(root,Guid.NewGuid().ToString("N")), Path.Combine(root,"Resources")).ReadImeiAsync(); }, "malformed or ambiguous display output rejected");
            }
            foreach (var fault in new[] { "api", "cid", "boot", "firmware", "router" })
            {
                var fake = new Fake { Fault = fault };
                await Reject(async () => { await new ImeiEngine(fake, Path.Combine(root,Guid.NewGuid().ToString("N")), Path.Combine(root,"Resources")).ReadImeiAsync(); }, "API/device identity drift rejected: " + fault);
            }
            Console.WriteLine($"IMEI_READ_TESTS_PASS checks={checks}; no modem access");
        }
        finally { Directory.Delete(root, true); }
    }
    private sealed class Fake : IRemoteShell
    {
        public string Firmware = B04;
        public string? Output, Fault;
        public bool Inactive;
        public int Reads, Snapshots, ConfigReads, SecondaryApiReads, IdentityReads;
        public Task<RemoteResult> RunAsync(string command, byte[]? input = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            RemoteResult Reply(string value, int status = 0) => new(status, Encoding.UTF8.GetBytes(value), []);
            if (command == AccessIdentity.Command)
            {
                IdentityReads++;
                var changed = IdentityReads > 1;
                var cid = new string(changed && Fault == "cid" ? '2' : '1', 32);
                var boot = changed && Fault == "boot" ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111";
                var firmware = changed && Fault == "firmware" ? new string('f',64) : Firmware;
                var router = Fault == "router" ? new string('a',64) : ImeiEngine.RouterHash;
                return Task.FromResult(Reply($"{firmware}  /firmware/image/modem.b16\n{router}  /usr/bin/diag-router\n{cid}\n{boot}\n"));
            }
            if (command.Contains("'--read-imei'")) { Reads++; return Task.FromResult(Reply(Output ?? "APP_IMEI index=0 value=" + Primary + "\n" + (Inactive ? "APP_IMEI index=1 state=not-active nv_status=5\n" : "APP_IMEI index=1 value=" + Secondary + "\n"))); }
            if (command.Contains("'--snapshot-available'")) { Snapshots++; return Task.FromResult(Reply("PAIR_REQUEST label=read_index1 status=5\n",20)); }
            if (command.Contains("'--read-config'")) { ConfigReads++; throw new Exception("Unexpected config read"); }
            if (command.StartsWith("ubus call zwrt_zte_mdm.api get_imei", StringComparison.Ordinal))
            {
                var secondary = command.EndsWith("get_imei2", StringComparison.Ordinal); if (secondary) SecondaryApiReads++;
                return Task.FromResult(Reply(JsonSerializer.Serialize(new { imei = Fault == "api" ? Secondary : secondary ? Secondary : Primary })));
            }
            if (input is not null && command.StartsWith("umask 077; cat > ", StringComparison.Ordinal))
            { var path = Regex.Match(command, "cat > '([^']+)'").Groups[1].Value; return Task.FromResult(Reply(VerifiedHash.Sha256(input) + "  " + path)); }
            if (command.Contains("/tmp/zte-imei-app.lock") || command.StartsWith("umask 077; mkdir '/tmp/zte-imei-", StringComparison.Ordinal) || command.StartsWith("rm -f '/tmp/zte-imei-", StringComparison.Ordinal)) return Task.FromResult(Reply(""));
            throw new Exception("Unexpected IMEI read command: " + command);
        }
        public Task UploadAsync(string path, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path, TimeSpan? timeout = null, CancellationToken ct = default) => throw new Exception("Unexpected download");
    }
}
