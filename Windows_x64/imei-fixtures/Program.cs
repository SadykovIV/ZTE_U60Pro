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
    await B04Read(Path.Combine(temporary, "b04"));
    await PendingDiagnosticAdb(Path.Combine(temporary, "diagnostic-adb"));
    await SingleWorkflow(Path.Combine(temporary, "single"));
    Console.WriteLine("IMEI transaction fixtures: 8 groups passed");
}
finally { Directory.Delete(temporary, recursive: true); }

static string Imei(int serial)
{
    var stem = "00440000" + serial.ToString("D6");
    return Enumerable.Range(0, 10).Select(n => stem + n).First(ImeiCodec.IsValid);
}

static (ImeiEngine engine, SimulatedModem modem, string storage) Make(string root, bool unreviewed = false, bool unreviewedRouter = false, bool skipFirmwareCheck = false)
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
    return (new ImeiEngine(modem, storage, Path.Combine(root, "Resources"), skipFirmwareCheck: skipFirmwareCheck), modem, storage);
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

static async Task B04Read(string root)
{
    foreach (var count in new[] { 1, 2 })
    {
        var (engine, modem, storage) = Make(root + count);
        modem.MissingFirmware = true;
        if (count == 1) modem.Nv = [modem.Nv[0]];
        var read = await engine.InspectAsync();
        Assert(read.Identity.FirmwareHash == "absent" && read.Imeis.SequenceEqual(modem.Imeis()), "B04 independent NV read");
        var result = count == 1 ? await engine.ApplyAsync(Imei(200), null) : await engine.ApplyAsync(Imei(200), Imei(201));
        Assert(result.Identity.FirmwareHash == "absent" && result.Imeis.Length == count && modem.Config.SequenceEqual(modem.OriginalConfig), "Absent image keeps actual contracts and config restore");
        var backup = Directory.GetDirectories(Path.Combine(storage, "Backups", "IMEI")).Single();
        var saved = JsonSerializer.Deserialize<ImeiBackupManifest>(File.ReadAllBytes(Path.Combine(backup, "manifest.json")))!;
        Assert(saved.Identity.FirmwareHash == "absent", "Explicit absence remains in backup identity");
        modem.MissingFirmware = false;
        var writes = modem.WriteCalls;
        await Throws<InvalidDataException>(() => engine.RestoreAsync(Path.GetFileName(backup)));
        Assert(modem.WriteCalls == writes, "Image appearing after backup refuses restore before mutation");
    }
    var (invalid, unsafeModem, _) = Make(root + "invalid");
    unsafeModem.MissingFirmware = true; unsafeModem.Config[499] ^= 1;
    await Throws<InvalidDataException>(() => invalid.ApplyAsync(Imei(200), Imei(201)));
    Assert(unsafeModem.WriteCalls == 0 && unsafeModem.EnableCalls == 0, "Absent image cannot bypass malformed EFS");
    Console.WriteLine("PASS B04 absent-image single/pair transactions, unchanged config, bound restore and EFS refusal");
}

static async Task FirmwareGate(string root)
{
    var (engine, modem, _) = Make(root, unreviewed: true);
    var first = Imei(200);
    var result = await engine.ApplyAsync(first, ImeiCodec.Second(first));
    Assert(result.Imeis.SequenceEqual(new[]{first,ImeiCodec.Second(first)}) && result.Identity.FirmwareHash == new string('0',64),
        "actual supported formats do not require a firmware-name override");
    var (routerEngine, routerModem, _) = Make(root + "-router", unreviewedRouter: true);
    await Throws<InvalidDataException>(() => routerEngine.ApplyAsync(first, ImeiCodec.Second(first)));
    Assert(routerModem.EnableCalls == 0 && routerModem.WriteCalls == 0 && !routerEngine.HasPendingTransaction,
        "unreviewed diag-router blocked before mutation");
    Console.WriteLine("PASS actual data contracts + exact router ABI gate");
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

static async Task SingleWorkflow(string root)
{
    var (engine,modem,storage) = Make(root);
    modem.Nv = [modem.Nv[0]];modem.Firmware="c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
    await Throws<ArgumentException>(() => engine.ApplyAsync(Imei(200),Imei(201)));
    var original=modem.Imeis();
    var result=await engine.ApplyAsync(Imei(200),null);
    Assert(result.Imeis.SequenceEqual(new[]{Imei(200)}) && modem.Nv.Length==1,"single result");
    var backup=Directory.GetDirectories(Path.Combine(storage,"Backups","IMEI")).Single();
    var manifest=JsonSerializer.Deserialize<ImeiBackupManifest>(File.ReadAllText(Path.Combine(backup,"manifest.json")))!;
    Assert(manifest.Schema==2 && manifest.Hashes.Count==2 && !File.Exists(Path.Combine(backup,"nv1.bin")),"single backup structure");
    var restored=await engine.RestoreAsync(Path.GetFileName(backup));
    Assert(restored.Imeis.SequenceEqual(original) && modem.Nv.Length==1,"single restore");
    var (b28,m28,_)=Make(root+"-b28");m28.Firmware="5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478";
    Assert((await b28.ApplyAsync(Imei(200),Imei(201))).Imeis.SequenceEqual(new[]{Imei(200),Imei(201)}),"B28 pair workflow rejected");
    var (badConfig,cm,_)=Make(root+"-bad-config");cm.Config[499]^=1;
    await Throws<InvalidDataException>(()=>badConfig.ApplyAsync(Imei(200),Imei(201)));Assert(cm.WriteCalls==0 && cm.EnableCalls==0,"bad config writes");
    var (interrupted,im,isRoot)=Make(root+"-interrupted");im.Nv=[im.Nv[0]];im.FailWriteOnce=true;
    await Throws<TimeoutException>(()=>interrupted.ApplyAsync(Imei(200),null));
    await Throws<InvalidOperationException>(()=>interrupted.ResumeAsync());
    Age(isRoot,p=>p with {WriteStartedAt=DateTimeOffset.UtcNow.AddMinutes(-10)});
    Assert((await interrupted.ResumeAsync()).Imeis.SequenceEqual(new[]{Imei(200)}) && im.WriteCalls==1,"single acklost resume repeated");
    var (drift,dm,_)=Make(root+"-drift");dm.Nv=[dm.Nv[0]];dm.ActivateOnBoot=true;
    await Throws<InvalidDataException>(()=>drift.ApplyAsync(Imei(200),null));Assert(dm.WriteCalls==0,"topology drift writes");
    var (oldPair,pm,ps)=Make(root+"-legacy");
    var pairBackup=await oldPair.CreateBackupAsync();pm.Nv=[pm.Nv[0]];
    await Throws<InvalidDataException>(()=>oldPair.RestoreAsync(Path.GetFileName(pairBackup)));
    Assert(pm.WriteCalls==0 && pm.EnableCalls==0,"legacy pair restored onto single modem");
    var (bad,bm,_)=Make(root+"-bad");bm.Nv=[bm.Nv[0]];
    foreach(var marker in new[]{"", "APP_NV_TOPOLOGY count=1 secondary=active\n", "APP_NV_TOPOLOGY count=2 secondary=active\n"}) {
        bm.SnapshotOverride=$"APP_NV index=0 data={Convert.ToHexString(bm.Nv[0])}\n"+marker;
        await Throws<InvalidDataException>(()=>bad.InspectAsync());
    }
    Assert(bm.WriteCalls==0 && bm.EnableCalls==0,"bad topology writes");
    Console.WriteLine("PASS single backup/apply/restore, actual B28/B04 contracts, no duplication, acklost resume, topology drift");
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
    public sealed record RemoteResult(int ExitCode, byte[] Stdout, byte[] Stderr) { public bool Success => ExitCode == 0; }
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
        public byte[][] Nv { get; set; }
        public bool ActivateOnBoot { get; set; }
        public string? SnapshotOverride { get; set; }
        public string Firmware { get; set; } = ImeiEngine.FirmwareHash;
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
        public bool MissingFirmware { get; set; }
        public string[] Imeis() => Nv.Select(bytes => ImeiCodec.DecodeNv550(bytes)).ToArray();
        public Task UploadAsync(string remotePath, byte[] data, TimeSpan? timeout = null, CancellationToken ct = default)
        { _files[remotePath] = data; return Task.CompletedTask; }
        public Task<byte[]> DownloadAsync(string remotePath, TimeSpan? timeout = null, CancellationToken ct = default)
            => Task.FromResult(_files[remotePath]);

        public Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (command == AccessIdentity.Command || command.StartsWith("sha256sum /firmware/image/modem.b16", StringComparison.Ordinal))
                return Output(($"{(MissingFirmware ? "absent" : _unreviewed ? new string('0', 64) : Firmware)}  /firmware/image/modem.b16\n" +
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
            { _boot = Guid.NewGuid().ToString(); _owner = null; if (ActivateOnBoot && Nv.Length == 1) Nv = [Nv[0], NewNv("004400000001016", 1)]; return Output(""); }
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
            if (command.Contains("'--snapshot-available'", StringComparison.Ordinal))
                return Output(SnapshotOverride ?? (string.Concat(Nv.Select((value,index) => $"APP_NV index={index} data={Convert.ToHexString(value)}\n")) + $"APP_NV_TOPOLOGY count={Nv.Length} secondary={(Nv.Length == 1 ? "not-active-status5" : "active")}\n"));
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
                var count = Nv.Length;
                if (plan.Length != count*256 || !Nv.SelectMany(x => x).SequenceEqual(plan[..(count*128)]))
                    throw new InvalidDataException("Fixture plan mismatch.");
                Nv[0] = plan[(count*128)..((count+1)*128)].ToArray();
                if (FailWriteOnce) { FailWriteOnce = false; throw new TimeoutException("Ambiguous fixture write."); }
                if (count == 2) Nv[1] = plan[384..512].ToArray();
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
