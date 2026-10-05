using System.Text;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

internal sealed class TransactionShell : IRemoteShell
{
    internal bool Original, Desired, Applied, Acked, Removed, UnknownFirmware, WrongReadback;
    internal bool LostDispatch, LostAck, ChangedBoot, FailCleanup, PrivateFailure, CapabilityMissing, StageAbsent, ForeignLock;
    internal int Applies, Acks, Cancels, ResultReads;
    internal string ResultPhase = "awaiting-ack";
    internal string PrepareReply = "ADB_PREPARED";
    internal CancellationTokenSource? CancelOnPrepare;
    internal List<string> Commands = [];
    internal Action? BeforePrepare;
    private static RemoteResult Reply(string value, int code = 0) => new(code, Encoding.ASCII.GetBytes(value + "\n"), Encoding.ASCII.GetBytes("PRIVATE-ADB-STDERR-CANARY"));
    public Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); Commands.Add(command);
        if (command == AccessIdentity.Command)
        {
            var firmware = UnknownFirmware ? new string('a', 64) : DeviceFeatureService.FirmwareHash;
            var boot = ChangedBoot && Applied ? "11111111-1111-1111-1111-111111111111" : "00000000-0000-0000-0000-000000000001";
            return Task.FromResult(Reply(firmware + "  /firmware/image/modem.b16\n" + DeviceFeatureService.RouterHash + "  /usr/bin/diag-router\n0123456789abcdef0123456789abcdef\n" + boot));
        }
        if (command == AdbControlProtocol.Command)
        {
            var state = Acked && !WrongReadback ? Desired : Original;
            return Task.FromResult(Reply("ZTE_ADB_STATE_V1\nlinked=" + (state ? "1" : "0") + "\nready=1\nbound=1\ndaemon=1"));
        }
        if (command == AdbToggleTransaction.CapabilityCommand)
        { if (command.Contains("setsid") || !command.Contains("sort pidof nohup sleep")) throw new Exception("unsupported launch dependency"); return Task.FromResult(Reply("ADB_CONTROL_CAPABLE", CapabilityMissing ? 71 : 0)); }
        if (command.Contains("ADB_STAGE_ABSENT")) return Task.FromResult(Reply("ADB_STAGE_ABSENT", StageAbsent && !ForeignLock ? 0 : 71));
        if (command.Contains("ADB_STAGED"))
        {
            if (stdin is null || !command.Contains("mkdir -m 700") || !command.Contains(AdbToggleTransaction.ScriptSha256)) throw new Exception("missing stage proof");
            return Task.FromResult(Reply("ADB_STAGED"));
        }
        if (command.Contains("'prepare'"))
        { BeforePrepare?.Invoke(); CancelOnPrepare?.Cancel(); return Task.FromResult(Reply(PrepareReply)); }
        if (command.Contains("'apply'"))
        {
            Applies++; Applied = true;
            if (!command.Contains("nohup /bin/sh") || command.Contains("setsid") || command.Contains("zte-timeout") || !command.Contains("</dev/null") || !command.Contains("2>&1") || !command.Contains("umask 077")) throw new Exception("not detached");
            if (LostDispatch) throw new IOException("PRIVATE-ADB-DISPATCH-CANARY");
            return Task.FromResult(Reply("ADB_DISPATCHED"));
        }
        if (command.Contains("'result'"))
        {
            ResultReads++;
            if (StageAbsent) return Task.FromResult(Reply("no stage", 71));
            if (PrivateFailure) throw new IOException("PRIVATE-ADB-RESULT-CANARY");
            return Task.FromResult(Reply("ADB_PHASE=" + (Acked ? "committed" : ResultPhase)));
        }
        if (command.Contains("'ack'"))
        { Acks++; Acked = true; if (LostAck) throw new IOException("PRIVATE-ADB-ACK-CANARY"); return Task.FromResult(Reply("ADB_ACKNOWLEDGED")); }
        if (command.Contains("'cancel'"))
        { Cancels++; if (StageAbsent) return Task.FromResult(Reply("no stage", 71)); ResultPhase = "cancelled"; return Task.FromResult(Reply("ADB_CANCELLED")); }
        if (command.Contains("ADB_STAGE_REMOVED"))
        { if (command.Contains("rm -rf") || command.Contains("zte-imei-app.lock")) throw new Exception("unsafe cleanup"); Removed = !FailCleanup; return Task.FromResult(Reply("ADB_STAGE_REMOVED", FailCleanup ? 71 : 0)); }
        throw new Exception("Unexpected fake command");
    }
    public Task UploadAsync(string p, byte[] d, TimeSpan? t = null, CancellationToken ct = default) => throw new Exception("Unexpected upload");
    public Task<byte[]> DownloadAsync(string p, TimeSpan? t = null, CancellationToken ct = default) => throw new Exception("Unexpected download");
}
internal static class TransactionTests
{
    internal static async Task Run(string fixture, Action<bool, string> check)
    {
        var resources = Path.Combine(fixture, "transaction-resources");
        string Store() { var path = Path.Combine(fixture, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path); return path; }
        AdbToggleTransaction Create(TransactionShell fake, string store) => new(fake, resources, store, TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(1));
        bool Pending(string store) => File.Exists(Path.Combine(store, AdbToggleTransaction.PendingName));
        async Task Refuse(Func<Task> action, string name)
        { try { await action(); throw new Exception("accepted " + name); } catch (DeviceFeatureException error) { check(!error.Message.Contains("PRIVATE") && !error.Message.Contains("0123456789"), name + " fixed error privacy"); } }
        foreach (var caseName in new[] { "absent", "foreign-lock", "dispatched", "changed-boot" })
        {
            var fake = new TransactionShell { StageAbsent = true, ForeignLock = caseName == "foreign-lock", Applied = caseName == "changed-boot", ChangedBoot = caseName == "changed-boot" }; var store = Store();
            var data = new { Schema = 1, Token = Guid.NewGuid().ToString("D"), Cid = "0123456789abcdef0123456789abcdef", Boot = "00000000-0000-0000-0000-000000000001", Firmware = DeviceFeatureService.FirmwareHash, Router = DeviceFeatureService.RouterHash, Desired = true, Original = false, Phase = caseName == "dispatched" ? "dispatched" : "preparing" };
            File.WriteAllText(Path.Combine(store, AdbToggleTransaction.PendingName), System.Text.Json.JsonSerializer.Serialize(data));
            if (caseName == "absent")
            {
                check((await Create(fake, store).ReadAsync(default)).Enabled == false && !Pending(store) && fake.Cancels == 0 && fake.Applies == 0 && !fake.Removed, "undispatched absent stage and absent lock clear only local journal after fresh binding");
            }
            else
            {
                await Refuse(async () => { await Create(fake, store).ReadAsync(default); }, "absent recovery " + caseName);
                check(Pending(store) && fake.Applies == 0 && !fake.Removed, "absent recovery preserves pending for " + caseName);
                if (caseName == "dispatched") check(!fake.Commands.Any(c => c.Contains("ADB_STAGE_ABSENT")) && fake.Cancels == 0, "unknown dispatch never uses absent-stage cancellation");
            }
        }
        foreach (var desired in new[] { false, true })
        {
            var fake = new TransactionShell { Original = !desired, Desired = desired }; var store = Store();
            fake.BeforePrepare = () => check(Pending(store), "journal durable before prepare");
            var result = await Create(fake, store).SetAsync(desired, default);
            check(result.Enabled == desired && result.SupportsChange && fake.Applies == 1 && fake.Acks == 1 && fake.Cancels == 0 && fake.Removed && !Pending(store), "one detached apply/ACK and exact verified final " + desired);
        }
        foreach (var lost in new[] { "dispatch", "ack" })
        {
            var fake = new TransactionShell { Desired = true, LostDispatch = lost == "dispatch", LostAck = lost == "ack" }; var store = Store();
            check((await Create(fake, store).SetAsync(true, default)).Enabled == true && fake.Applies == 1 && fake.Acks == 1 && !Pending(store), "lost " + lost + " reply never replays mutation");
        }
        {
            var fake = new TransactionShell { Original = true, Desired = true, PrepareReply = "ADB_UNCHANGED" }; var store = Store();
            check((await Create(fake, store).SetAsync(true, default)).Enabled == true && fake.Applies == 0 && fake.Acks == 0 && fake.Removed && !Pending(store), "unchanged prepare needs no apply or ACK");
        }
        {
            var fake = new TransactionShell { Desired = true, CapabilityMissing = true }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, "missing required launch tool");
            check(!Pending(store) && fake.Applies == 0 && !fake.Commands.Any(c => c.Contains("ADB_STAGED")), "missing tool refuses before journal/stage creation");
        }
        {
            var fake = new TransactionShell { UnknownFirmware = true }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, "unknown firmware");
            check(!Pending(store) && fake.Commands.Count == 1 && fake.Applies == 0, "unknown firmware no staging or journal");
        }
        foreach (var phase in new[] { "rollback-unknown", "cleanup-unknown", "garbage", "changing" })
        {
            var fake = new TransactionShell { Desired = true, ResultPhase = phase }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, phase);
            check(Pending(store) && fake.Applies == 1 && fake.Acks == 0 && fake.Cancels == 0 && !fake.Removed, phase + " retains stage/pending and no replay");
        }
        {
            var fake = new TransactionShell { Desired = true, ResultPhase = "rolled-back" }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, "verified rollback");
            check(!Pending(store) && fake.Removed && fake.Applies == 1 && fake.Acks == 0, "verified rollback cleans only stage after original observation");
        }
        foreach (var failure in new[] { "identity", "cleanup", "readback", "private" })
        {
            var fake = new TransactionShell { Desired = true, ChangedBoot = failure == "identity", FailCleanup = failure == "cleanup", WrongReadback = failure == "readback", PrivateFailure = failure == "private" }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, failure);
            check(Pending(store) && fake.Applies == 1 && fake.Cancels == 0 && !fake.Removed, failure + " cannot authorize success/cleanup");
            if (failure == "identity") check(fake.Acks == 0, "changed boot prevents ACK");
        }
        {
            using var cancel = new CancellationTokenSource();
            var fake = new TransactionShell { Desired = true, CancelOnPrepare = cancel, ResultPhase = "prepared" }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, cancel.Token); }, "pre-dispatch cancellation");
            check(fake.Applies == 0 && fake.Cancels == 1 && fake.Removed && !Pending(store), "cancel only confirmed prepared without dispatch");
        }
        {
            var fake = new TransactionShell { Desired = true, ResultPhase = "cleanup-unknown" }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, "create recovery fixture");
            fake.ResultPhase = "committed"; fake.Original = true;
            check((await Create(fake, store).ReadAsync(default)).Enabled == true && fake.Applies == 1 && fake.Acks == 0 && fake.Removed && !Pending(store), "reconnect terminal status never applies/ACKs again");
        }
        {
            var fake = new TransactionShell { Desired = true, ResultPhase = "cleanup-unknown" }; var store = Store();
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, "create pending fixture");
            fake.ResultPhase = "prepared";
            await Refuse(async () => { await Create(fake, store).ReadAsync(default); }, "reconnect prepared");
            check(Pending(store) && fake.Applies == 1 && fake.Acks == 0 && fake.Cancels == 0 && !fake.Removed, "read-only reconnect preserves incomplete transaction");
            var count = fake.Commands.Count;
            await Refuse(async () => { await Create(fake, store).SetAsync(true, default); }, "pending blocks second intent");
            check(fake.Commands.Count == count, "pending refusal before remote I/O");
        }
    }
}
