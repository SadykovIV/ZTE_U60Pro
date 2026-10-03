using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

var temporary = Path.Combine(Path.GetTempPath(), "zte-imei-fixture-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temporary);
try
{
    await ApplyAndRestore(Path.Combine(temporary, "apply"));
    await InterruptedWrite(Path.Combine(temporary, "write"));
    await InterruptedConfig(Path.Combine(temporary, "config"));
    await InterruptedConfigRestore(Path.Combine(temporary, "config-restore"));
    await FirmwareGate(Path.Combine(temporary, "firmware"));
    await PendingDiagnosticAdb(Path.Combine(temporary, "diagnostic-adb"));
    Console.WriteLine("IMEI transaction fixtures: 6 passed");
}
finally { Directory.Delete(temporary, recursive: true); }

static string Imei(int serial)
{
    var stem = "00440000" + serial.ToString("D6");
    return Enumerable.Range(0, 10).Select(n => stem + n).First(ImeiCodec.IsValid);
}

static (ImeiEngine engine, SimulatedModem modem, string storage) Make(string root, bool unreviewed = false, bool unreviewedRouter = false)
{
    var resources = Path.Combine(root, "Resources", "Helpers");
    var storage = Path.Combine(root, "Data");
    Directory.CreateDirectory(resources);
    Directory.CreateDirectory(storage);
    var manifest = new Dictionary<string, string>();
    foreach (var name in new[] { "zte_nv", "zte_config", "zte_config_read" })
    {
        var content = Encoding.ASCII.GetBytes("fixture-" + name);
        File.WriteAllBytes(Path.Combine(resources, name), content);
        manifest[name] = VerifiedHash.Sha256(content);
    }
    File.WriteAllText(Path.Combine(resources, "helpers.json"), JsonSerializer.Serialize(manifest));
    var modem = new SimulatedModem(Imei(100), Imei(101), unreviewed, unreviewedRouter);
    return (new ImeiEngine(modem, storage, Path.Combine(root, "Resources"), skipFirmwareCheck: true), modem, storage);
}

static async Task ApplyAndRestore(string root)
{
    var (engine, modem, storage) = Make(root);
    var original = modem.Imeis();
    var first = Imei(200); var second = ImeiCodec.Second(first);
    var result = await engine.ApplyAsync(first, second);
    Assert(result.Imeis.SequenceEqual([first, second]), "write result");
    Assert(modem.Config.SequenceEqual(modem.OriginalConfig), "original config restored");
    Assert(!engine.HasPendingTransaction, "write journal removed");
    var backup = Directory.GetDirectories(Path.Combine(storage, "Backups", "IMEI")).Single();
    var restored = await engine.RestoreAsync(Path.GetFileName(backup));
    Assert(restored.Imeis.SequenceEqual(original), "backup restored both slots");
    Assert(!engine.HasPendingTransaction, "restore journal removed");
    Console.WriteLine("PASS apply + backup restore");
}

static async Task InterruptedWrite(string root)
{
    var (engine, modem, storage) = Make(root);
    modem.FailWriteOnce = true;
    var first = Imei(200); var second = ImeiCodec.Second(first);
    await Throws<TimeoutException>(() => engine.ApplyAsync(first, second));
    Assert(engine.HasPendingTransaction && modem.WriteCalls == 1, "ambiguous write persisted");
    await Throws<InvalidOperationException>(() => engine.ResumeAsync());
    Assert(modem.WriteCalls == 1, "immediate resume did not repeat write");
    Age(storage, p => p with { WriteStartedAt = DateTimeOffset.UtcNow.AddSeconds(-200) });
    await Throws<InvalidOperationException>(() => engine.ResumeAsync());
    Assert(modem.WriteCalls == 1, "resume before helper deadline did not repeat write");
    Age(storage, p => p with { WriteStartedAt = DateTimeOffset.UtcNow.AddMinutes(-10) });
    var completed = await engine.ResumeAsync();
    Assert(completed.Imeis.SequenceEqual([first, second]), "mixed pair reconciled");
    Assert(modem.WriteCalls == 2 && !engine.HasPendingTransaction, "explicit resume completed once");
    Console.WriteLine("PASS ambiguous NV write + explicit resume");
}

static async Task InterruptedConfig(string root)
{
    var (engine, modem, storage) = Make(root);
    modem.FailEnableOnce = true;
    var first = Imei(200);
    await Throws<TimeoutException>(() => engine.ApplyAsync(first, ImeiCodec.Second(first)));
    await Throws<InvalidOperationException>(() => engine.ResumeAsync());
    Assert(modem.EnableCalls == 1, "immediate resume did not repeat config enable");
    Age(storage, p => p with { ConfigMutationStartedAt = DateTimeOffset.UtcNow.AddSeconds(-200) });
    await Throws<InvalidOperationException>(() => engine.ResumeAsync());
    Assert(modem.EnableCalls == 1, "resume before helper deadline did not repeat config enable");
    Age(storage, p => p with { ConfigMutationStartedAt = DateTimeOffset.UtcNow.AddMinutes(-10) });
    _ = await engine.ResumeAsync();
    Assert(modem.EnableCalls == 1, "candidate config was verified without second enable");
    Console.WriteLine("PASS ambiguous config enable + cooling barrier");
}

static async Task FirmwareGate(string root)
{
    var (engine, modem, _) = Make(root, unreviewed: true);
    var first = Imei(200);
    await Throws<InvalidDataException>(() => engine.ApplyAsync(first, ImeiCodec.Second(first)));
    Assert(modem.EnableCalls == 0 && modem.WriteCalls == 0 && !engine.HasPendingTransaction,
        "B02-like firmware blocked before mutation");
    var (routerEngine, routerModem, _) = Make(root + "-router", unreviewedRouter: true);
    await Throws<InvalidDataException>(() => routerEngine.ApplyAsync(first, ImeiCodec.Second(first)));
    Assert(routerModem.EnableCalls == 0 && routerModem.WriteCalls == 0 && !routerEngine.HasPendingTransaction,
        "unreviewed diag-router blocked before mutation");
    Console.WriteLine("PASS exact B31 write gate");
}

static async Task InterruptedConfigRestore(string root)
{
    var (engine, modem, storage) = Make(root);
    modem.FailRestoreOnce = true;
    var first = Imei(200);
    await Throws<TimeoutException>(() => engine.ApplyAsync(first, ImeiCodec.Second(first)));
    await Throws<InvalidOperationException>(() => engine.ResumeAsync());
    Assert(modem.RestoreCalls == 1, "immediate resume did not repeat config restore");
    Age(storage, p => p with { ConfigMutationStartedAt = DateTimeOffset.UtcNow.AddSeconds(-200) });
    await Throws<InvalidOperationException>(() => engine.ResumeAsync());
    Assert(modem.RestoreCalls == 1, "resume before helper deadline did not repeat config restore");
    Age(storage, p => p with { ConfigMutationStartedAt = DateTimeOffset.UtcNow.AddMinutes(-10) });
    _ = await engine.ResumeAsync();
    Assert(modem.RestoreCalls == 1, "verified original config was not restored twice");
    Console.WriteLine("PASS ambiguous config restore + cooling barrier");
}

static async Task PendingDiagnosticAdb(string root)
{
    var (engine,modem,storage)=Make(root);
    File.WriteAllText(Path.Combine(storage,"adb-access-pending.json"),"{}");
    await Throws<InvalidOperationException>(()=>engine.ApplyAsync(Imei(200),Imei(201)));
    Assert(modem.EnableCalls==0 && modem.WriteCalls==0 && modem.RestoreCalls==0,
        "pending diagnostic ADB prevents a new IMEI transaction");
    File.WriteAllText(Path.Combine(storage,"imei-pending.json"),"{}");
    await Throws<InvalidOperationException>(()=>engine.ResumeAsync());
    Assert(modem.EnableCalls==0 && modem.WriteCalls==0 && modem.RestoreCalls==0,
        "pending diagnostic ADB prevents IMEI resume before any write");
}

static void Age(string storage, Func<ImeiPending, ImeiPending> edit)
{
    var path = Path.Combine(storage, "imei-pending.json");
    var pending = JsonSerializer.Deserialize<ImeiPending>(File.ReadAllText(path))!;
    File.WriteAllText(path, JsonSerializer.Serialize(edit(pending)));
}

static async Task Throws<T>(Func<Task> action) where T : Exception
{
    try { await action(); }
    catch (T) { return; }
    throw new Exception("Expected " + typeof(T).Name);
}

static void Assert(bool condition, string name)
{
    if (!condition) throw new Exception("Fixture failed: " + name);
}

namespace ZteImeiStudio.Transport
{
    public sealed record RemoteResult(int ExitCode, byte[] Stdout, byte[] Stderr);
    public interface IRemoteShell
    {
        Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default);
        Task UploadAsync(string remotePath, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default);
        Task<byte[]> DownloadAsync(string remotePath, TimeSpan? timeout = null, CancellationToken ct = default);
    }

    public sealed class SimulatedModem : IRemoteShell
    {
        private const string Cid = "0123456789abcdef0123456789abcdef";
        private readonly Dictionary<string, byte[]> _files = new();
        private readonly bool _unreviewed;
        private readonly bool _unreviewedRouter;
        private string _boot = Guid.NewGuid().ToString();
        private string? _owner;
        private byte[]? _plan;
        public byte[][] Nv { get; }
        public byte[] OriginalConfig { get; }
        public byte[] Config { get; private set; }
        public bool FailWriteOnce { get; set; }
        public bool FailEnableOnce { get; set; }
        public bool FailRestoreOnce { get; set; }
        public int WriteCalls { get; private set; }
        public int EnableCalls { get; private set; }
        public int RestoreCalls { get; private set; }

        public SimulatedModem(string first, string second, bool unreviewed, bool unreviewedRouter)
        {
            _unreviewed = unreviewed;
            _unreviewedRouter = unreviewedRouter;
            Nv = [NewNv(first, 0), NewNv(second, 1)];
            OriginalConfig = NewConfig();
            Config = OriginalConfig.ToArray();
        }
        public string[] Imeis() => Nv.Select(bytes => ImeiCodec.DecodeNv550(bytes)).ToArray();
        public Task UploadAsync(string remotePath, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default)
        { _files[remotePath] = data; return Task.CompletedTask; }
        public Task<byte[]> DownloadAsync(string remotePath, TimeSpan? timeout = null, CancellationToken ct = default)
            => Task.FromResult(_files[remotePath]);

        public Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (command.StartsWith("sha256sum /firmware/image/modem.b16", StringComparison.Ordinal))
                return Output(($"{(_unreviewed ? new string('0', 64) : ImeiEngine.FirmwareHash)}  /firmware/image/modem.b16\n" +
                    $"{(_unreviewedRouter ? new string('0', 64) : ImeiEngine.RouterHash)}  /usr/bin/diag-router\n{Cid}\n{_boot}\n"));
            if (command == "sha256sum /usr/bin/diag-router")
                return Output($"{(_unreviewedRouter ? new string('0', 64) : ImeiEngine.RouterHash)}  /usr/bin/diag-router\n");
            if (command.StartsWith("umask 077; if mkdir /tmp/zte-imei-app.lock", StringComparison.Ordinal))
            {
                var token = Regex.Match(command, "printf '%s' '([^']+)'").Groups[1].Value;
                if (_owner is not null && _owner != token) return Task.FromResult(new RemoteResult(1, [], []));
                _owner = token; return Output("");
            }
            if (command.StartsWith("test \"$(cat /tmp/zte-imei-app.lock/owner", StringComparison.Ordinal))
            {
                if (_owner is null || !command.Contains("'" + _owner + "'", StringComparison.Ordinal))
                    return Task.FromResult(new RemoteResult(1, [], []));
                _owner = null; return Output("");
            }
            if (command.StartsWith("ubus call zwrt_mc.device.manager device_reboot", StringComparison.Ordinal))
            { _boot = Guid.NewGuid().ToString(); _owner = null; return Output(""); }
            if (command.StartsWith("ubus call zwrt_zte_mdm.api get_imei", StringComparison.Ordinal))
                return Output(JsonSerializer.Serialize(new { imei = Imeis()[command.EndsWith("get_imei2", StringComparison.Ordinal) ? 1 : 0] }));
            if (command.StartsWith("umask 077; mkdir '/tmp/zte-imei-", StringComparison.Ordinal) ||
                command.StartsWith("rm -f ", StringComparison.Ordinal)) return Output("");
            if (command.Contains("cat > ", StringComparison.Ordinal) && stdin is not null)
            {
                var path = Regex.Match(command, "cat > '([^']+)'").Groups[1].Value;
                if (path.Length == 0) throw new Exception("Fixture upload path missing.");
                _files[path] = stdin;
                if (path.EndsWith("/plan", StringComparison.Ordinal)) _plan = stdin;
                return Output(VerifiedHash.Sha256(stdin) + "  " + path + "\n");
            }
            if (command.Contains("'--snapshot'", StringComparison.Ordinal))
                return Output($"APP_NV index=0 data={Convert.ToHexString(Nv[0])}\nAPP_NV index=1 data={Convert.ToHexString(Nv[1])}\n");
            if (command.Contains("'--read-config'", StringComparison.Ordinal))
                return Output($"EFS_DATA_HEX offset=0 length={Config.Length} data={Convert.ToHexString(Config)}\n" +
                    "EFS_FILE_COMPLETE path=/config length=15073 sha256=fixture\n");
            if (command.Contains("'--enable-flag'", StringComparison.Ordinal))
            {
                EnableCalls++; Config = _plan![ConfigCodec.Length..].ToArray();
                if (FailEnableOnce) { FailEnableOnce = false; throw new TimeoutException("Ambiguous fixture enable."); }
                return Output("CONFIG_TARGET_VERIFIED\n");
            }
            if (command.Contains("'--apply-plan'", StringComparison.Ordinal))
            {
                WriteCalls++;
                var plan = _plan!;
                if (plan.Length != 512 || !Nv[0].SequenceEqual(plan[..128]) || !Nv[1].SequenceEqual(plan[128..256]))
                    throw new InvalidDataException("Fixture plan mismatch.");
                Nv[0] = plan[256..384].ToArray();
                if (FailWriteOnce) { FailWriteOnce = false; throw new TimeoutException("Ambiguous fixture write."); }
                Nv[1] = plan[384..512].ToArray();
                return Output("PAIR_TARGET_VERIFIED\n");
            }
            if (command.Contains("'--restore-original-config'", StringComparison.Ordinal))
            {
                RestoreCalls++; Config = _plan![..ConfigCodec.Length].ToArray();
                if (FailRestoreOnce) { FailRestoreOnce = false; throw new TimeoutException("Ambiguous fixture config restore."); }
                return Output("CONFIG_TARGET_VERIFIED\n");
            }
            if (command.Contains("'--check-original'", StringComparison.Ordinal))
                return Config.SequenceEqual(_plan![..ConfigCodec.Length]) ? Output("CONFIG_TARGET_VERIFIED\n") :
                    Task.FromResult(new RemoteResult(1, [], Encoding.UTF8.GetBytes("config mismatch")));
            throw new NotSupportedException("Unexpected fixture command: " + command);
        }
        private static Task<RemoteResult> Output(string value) =>
            Task.FromResult(new RemoteResult(0, Encoding.UTF8.GetBytes(value), []));

        private static byte[] NewNv(string imei, int slot)
        {
            var bytes = Enumerable.Range(0, 128).Select(i => (byte)(17 * i + 19 * slot)).ToArray();
            bytes[0] = 8; bytes[1] = (byte)(((imei[0] - '0') << 4) | 10);
            for (var i = 0; i < 7; i++)
                bytes[2 + i] = (byte)((imei[1 + 2 * i] - '0') | ((imei[2 + 2 * i] - '0') << 4));
            return bytes;
        }
        private static byte[] NewConfig()
        {
            var bytes = new byte[ConfigCodec.Length];
            BinaryPrimitives.WriteUInt32LittleEndian(bytes, 0x78563412);
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), 249);
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), ConfigCodec.Length);
            var offset = 16;
            for (var i = 0; i < 249; i++)
            {
                var length = i < 4 ? 93 : i == 4 ? 95 : i == 5 ? 17 : i == 248 ? 291 : 59;
                var record = bytes.AsSpan(offset, length);
                BinaryPrimitives.WriteUInt32LittleEndian(record, (uint)(i == 5 ? 102 : 1000 + i));
                BinaryPrimitives.WriteUInt32LittleEndian(record[4..], (uint)length);
                BinaryPrimitives.WriteUInt32LittleEndian(record[8..], 0x18080820);
                for (var j = 16; j < length; j++) record[j] = (byte)(i + 7 * j);
                offset += length;
            }
            if (offset != bytes.Length - 4) throw new Exception("Fixture config length incorrect.");
            bytes[499] = 0;
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(bytes.Length - 4), 0x21436587);
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(12), ConfigCodec.Crc(bytes));
            if (ConfigCodec.Validate(bytes) != 0) throw new Exception("Fixture config invalid.");
            return bytes;
        }
    }
}
