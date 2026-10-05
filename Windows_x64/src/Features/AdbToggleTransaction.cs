using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using AccessDeviceIdentity = ZteImeiStudio.Windows.Core.DeviceIdentity;

namespace ZteImeiStudio.Windows.Features;

// The shell owns rollback and the common device lock. Losing an SSH reply never
// permits a second apply, an inferred success, or removal of an unknown stage.
internal sealed class AdbToggleTransaction(IRemoteShell shell, string resources, string storage,
    TimeSpan? waitBudget = null, TimeSpan? pollInterval = null)
{
    internal const string ScriptSha256 = "4e24dd2e15fa567c8a22efaafdc0f01345fb226c2b1fef7f921ec77d67ebe2f7";
    internal const string PendingName = "adb-toggle-pending.json";
    internal const string Unknown = "Результат переключения ADB не подтверждён. Подключитесь по SSH и обновите состояние ADB. Повторное переключение заблокировано.";
    internal const string CapabilityCommand = "set -eu; test \"$(id -u)\" = 0; for tool in sh stat readlink sha256sum cut awk sed sort pidof nohup sleep cat mv rm rmdir mkdir ln id uname; do command -v \"$tool\" >/dev/null || exit 71; done; test ! -L /sbin/adbd; test \"$(sha256sum /sbin/adbd | cut -d ' ' -f 1)\" = 6d42bf97ae1f761ba3c5a0ee48deb84db0b19e4766b6b538b71741743d5b3f90; printf 'ADB_CONTROL_CAPABLE\\n'";
    private string PendingPath => Path.Combine(storage, PendingName);
    private sealed record Pending(int Schema, string Token, string Cid, string Boot, string Firmware, string Router, bool Desired, bool Original, string Phase)
    {
        internal string Stage => "/tmp/zte-adb-toggle-" + Token;
        internal AccessDeviceIdentity Identity => new(Cid, Firmware, Boot, Router);
    }
    private static DeviceFeatureException Failure(string message = Unknown) => new(message);
    private static string Q(string value) => DeviceFeatureService.Quote(value);
    private static bool Exact(RemoteResult result, string line) => result.Success && result.Stdout.AsSpan().SequenceEqual(Encoding.ASCII.GetBytes(line + "\n"));
    private static bool Known(AccessDeviceIdentity identity) => identity.FirmwareHash == DeviceFeatureService.FirmwareHash && identity.RouterHash == DeviceFeatureService.RouterHash;

    private async Task<byte[]> Script(CancellationToken ct)
    {
        var path = Path.Combine(resources, "Onboarding", "adb-toggle.sh");
        var data = await File.ReadAllBytesAsync(path, ct);
        var manifest = JsonSerializer.Deserialize<Dictionary<string, string>>(await File.ReadAllBytesAsync(Path.Combine(resources, "Onboarding", "SHA256.json"), ct));
        if (data.Length is < 1 or > 65536 || Convert.ToHexStringLower(SHA256.HashData(data)) != ScriptSha256 || manifest?.GetValueOrDefault("adb-toggle.sh") != ScriptSha256)
            throw Failure("Компонент переключения ADB не подтверждён. Настройки модема не изменены.");
        return data;
    }
    private async Task<AdbControlStatus> Observe(CancellationToken ct, AccessDeviceIdentity? expected = null)
    {
        var before = await AccessIdentity.ReadAsync(shell, ct);
        if (expected is not null && before != expected) throw Failure();
        var result = await shell.RunAsync(AdbControlProtocol.Command, timeout: TimeSpan.FromSeconds(15), ct: ct);
        if (await AccessIdentity.ReadAsync(shell, ct) != before || !result.Success) throw Failure("Не удалось подтвердить состояние ADB через SSH.");
        var state = AdbControlProtocol.Parse(result.Stdout);
        if (!Known(before) || !state.ReadyForChange) return state;
        try { _ = await Script(ct); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or DeviceFeatureException) { return state; }
        var capability = await shell.RunAsync(CapabilityCommand, timeout: TimeSpan.FromSeconds(10), ct: ct);
        if (await AccessIdentity.ReadAsync(shell, ct) != before) throw Failure();
        return state with { SupportsChange = Exact(capability, "ADB_CONTROL_CAPABLE") };
    }
    public async Task<AdbControlStatus> ReadAsync(CancellationToken ct)
    {
        try { return await ReadCoreAsync(ct); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        { throw Failure(); }
    }
    private async Task<AdbControlStatus> ReadCoreAsync(CancellationToken ct)
    {
        if (File.Exists(PendingPath) || Directory.Exists(PendingPath))
        {
            // A persisted pre-dispatch intent may cancel preparation only. Once
            // dispatch is recorded, reconnect is result-only: never ACK/apply.
            var pending = Load();
            await Bound(pending, ct);
            if (pending.Phase != "dispatched" && await RecoverAbsentStage(pending, ct))
                return await Observe(ct, pending.Identity);
            if (pending.Phase != "dispatched")
                _ = await Call(pending, "cancel", ct);
            var phase = Phase(await Call(pending, "result", ct));
            if (phase is not ("committed" or "rolled-back" or "cancelled")) throw Failure();
            var state = await Observe(ct, pending.Identity);
            if (state.Enabled != (phase == "committed" ? pending.Desired : pending.Original)) throw Failure();
            await Cleanup(pending, ct);
            File.Delete(PendingPath);
            return state;
        }
        return await Observe(ct);
    }
    public async Task<AdbControlStatus> SetAsync(bool desired, CancellationToken ct)
    {
        if (File.Exists(PendingPath) || Directory.Exists(PendingPath)) throw Failure();
        byte[] script;
        try { script = await Script(ct); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        { throw Failure("Компонент переключения ADB не подтверждён. Настройки модема не изменены."); }
        // Pin failure precedes any remote staging.
        var identity = await AccessIdentity.ReadAsync(shell, ct);
        if (!Known(identity)) throw Failure("Переключение ADB поддерживается только на проверенной прошивке B31.");
        var state = await Observe(ct, identity);
        if (!state.SupportsChange || state.Enabled is null) throw Failure("Безопасное переключение ADB для этой конфигурации не подтверждено.");
        var pending = new Pending(1, Guid.NewGuid().ToString("D"), identity.Cid, identity.BootId, identity.FirmwareHash, identity.RouterHash, desired, state.Enabled.Value, "preparing");
        Directory.CreateDirectory(storage);
        Save(pending, create: true);
        var dispatched = false;
        try
        {
            await Bound(pending, ct);
            var stage = Q(pending.Stage); var path = Q(pending.Stage + "/adb-toggle.sh");
            var upload = await shell.RunAsync("set -eu; umask 077; test ! -L /tmp; test \"$(stat -c %u /tmp)\" = 0; mkdir -m 700 " + stage + "; cat > " + path + "; chmod 600 " + path + "; test \"$(sha256sum " + path + " | cut -d ' ' -f 1)\" = " + Q(ScriptSha256) + "; printf 'ADB_STAGED\\n'", script, TimeSpan.FromSeconds(30), ct);
            if (!Exact(upload, "ADB_STAGED")) throw Failure();
            var prepared = await Call(pending, "prepare", ct);
            if (Exact(prepared, "ADB_UNCHANGED"))
            {
                var same = await Observe(ct, identity);
                if (same.Enabled != desired) throw Failure();
                await Cleanup(pending, ct);
                File.Delete(PendingPath); return same;
            }
            if (!Exact(prepared, "ADB_PREPARED")) throw Failure();
            pending = pending with { Phase = "prepared" }; Save(pending);
            ct.ThrowIfCancellationRequested();
            // Persist before dispatch; missing SSH reply is an unknown dispatch,
            // never grounds to replay apply or invoke pre-dispatch cancellation.
            pending = pending with { Phase = "dispatched" }; Save(pending); dispatched = true;
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(waitBudget ?? TimeSpan.FromSeconds(90));
            try
            {
                _ = await shell.RunAsync("set -eu; umask 077; " + ScriptGuard(pending) + "nohup /bin/sh " + Arguments(pending, "apply") + " </dev/null >" + Q(pending.Stage + "/worker.log") + " 2>&1 &\nprintf 'ADB_DISPATCHED\\n'", timeout: TimeSpan.FromSeconds(10), ct: deadline.Token);
            }
            catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException) { /* Poll, never resend. */ }
            var acknowledged = false;
            while (!deadline.IsCancellationRequested)
            {
                try
                {
                    await Bound(pending, deadline.Token);
                    var phase = Phase(await Call(pending, "result", deadline.Token));
                    if (phase == "awaiting-ack" && !acknowledged)
                    {
                        await Bound(pending, deadline.Token);
                        acknowledged = true;
                        // A lost ACK reply is not retried; the worker decides.
                        _ = await Call(pending, "ack", deadline.Token);
                    }
                    else if (phase is "committed" or "rolled-back" or "cancelled")
                    {
                        var final = await Observe(deadline.Token, identity);
                        if (final.Enabled != (phase == "committed" ? desired : pending.Original)) throw Failure();
                        await Cleanup(pending, deadline.Token);
                        File.Delete(PendingPath);
                        if (phase != "committed") throw Failure("Переключение ADB отменено; прежнее состояние USB восстановлено.");
                        return final;
                    }
                    else if (phase is "rollback-unknown" or "cleanup-unknown") throw Failure();
                }
                catch (Exception error) when (error is IOException or TimeoutException) { /* Read-only reconnect after USB rebind. */ }
                await Task.Delay(pollInterval ?? TimeSpan.FromSeconds(1), deadline.Token);
            }
            throw Failure();
        }
        catch (Exception error)
        {
            var preparationCleared = false;
            if (!dispatched)
            {
                // Cancellation is legal only with proof that apply was never sent.
                try
                {
                    using var cleanupDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                    await Bound(pending, cleanupDeadline.Token);
                    if (await RecoverAbsentStage(pending, cleanupDeadline.Token)) preparationCleared = true;
                    else if (Exact(await Call(pending, "cancel", cleanupDeadline.Token), "ADB_CANCELLED") && Phase(await Call(pending, "result", cleanupDeadline.Token)) == "cancelled")
                    { await Cleanup(pending, cleanupDeadline.Token); File.Delete(PendingPath); preparationCleared = true; }
                }
                catch { /* Unknown ownership/staging stays recorded for inspection. */ }
            }
            if (preparationCleared) throw Failure("Переключение ADB не начиналось. Настройки модема не изменены.");
            if (!File.Exists(PendingPath) && error is DeviceFeatureException) throw;
            throw Failure(); // Never surface raw SSH output or identity/token data.
        }
    }
    private async Task<bool> RecoverAbsentStage(Pending pending, CancellationToken ct)
    {
        if (pending.Phase == "dispatched") return false;
        await Bound(pending, ct);
        var stage = Q(pending.Stage);
        var command = "set -eu; test -d /tmp && test ! -L /tmp && test \"$(stat -c %u /tmp)\" = 0 || exit 71; " +
            "test ! -e " + stage + " && test ! -L " + stage + " && test ! -e /tmp/zte-imei-app.lock && test ! -L /tmp/zte-imei-app.lock || exit 71; printf 'ADB_STAGE_ABSENT\\n'";
        if (!Exact(await shell.RunAsync(command, timeout: TimeSpan.FromSeconds(10), ct: ct), "ADB_STAGE_ABSENT")) return false;
        await Bound(pending, ct);
        File.Delete(PendingPath);
        return true;
    }
    private async Task Bound(Pending pending, CancellationToken ct)
    { if (await AccessIdentity.ReadAsync(shell, ct) != pending.Identity) throw Failure(); }
    private string ScriptGuard(Pending pending)
    {
        var stage = Q(pending.Stage); var path = Q(pending.Stage + "/adb-toggle.sh");
        return "test -d " + stage + " && test ! -L " + stage + " && test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700 || exit 71; " +
            "test -f " + path + " && test ! -L " + path + " && test \"$(stat -c '%u:%a:%h' " + path + ")\" = 0:600:1 && test \"$(stat -c %s " + path + ")\" -le 65536 || exit 71; " +
            "test \"$(sha256sum " + path + " | cut -d ' ' -f 1)\" = " + Q(ScriptSha256) + " || exit 71; ";
    }
    private static string Arguments(Pending pending, string action) => string.Join(' ', new[] { pending.Stage + "/adb-toggle.sh", action, pending.Stage, pending.Token, pending.Cid, pending.Boot, pending.Desired ? "1" : "0" }.Select(Q));
    private Task<RemoteResult> Call(Pending pending, string action, CancellationToken ct) => shell.RunAsync("set -eu; " + ScriptGuard(pending) + "sh " + Arguments(pending, action), timeout: TimeSpan.FromSeconds(10), ct: ct);
    private static string Phase(RemoteResult result)
    {
        foreach (var phase in new[] { "preparing", "prepared", "changing", "awaiting-ack", "committed", "rolled-back", "rollback-unknown", "cleanup-unknown", "cancelled" })
            if (Exact(result, "ADB_PHASE=" + phase)) return phase;
        throw new IOException("ADB phase unavailable.");
    }
    private async Task Cleanup(Pending pending, CancellationToken ct)
    {
        await Bound(pending, ct);
        var stage = Q(pending.Stage);
        var names = new[] { "adb-toggle.sh", "before", "after", "udc", "daemon", "name", "target", "desired", "original", "phase", "ack", "worker.log" };
        var files = string.Join(' ', names.Select(n => Q(pending.Stage + "/" + n)));
        var command = "set -eu; test -d " + stage + " && test ! -L " + stage + " && test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700 || exit 71; " +
            "for entry in " + stage + "/* " + stage + "/.[!.]* " + stage + "/..?*; do test ! -e \"$entry\" && test ! -L \"$entry\" && continue; case \"${entry##*/}\" in adb-toggle.sh|before|after|udc|daemon|name|target|desired|original|phase|ack|worker.log|apply-once|decision) :;; *) exit 71;; esac; done; " +
            "for dir in " + Q(pending.Stage + "/apply-once") + " " + Q(pending.Stage + "/decision") + "; do if test -e \"$dir\" || test -L \"$dir\"; then test -d \"$dir\" && test ! -L \"$dir\" && test \"$(stat -c '%u:%a' \"$dir\")\" = 0:700 || exit 71; for f in \"$dir\"/* \"$dir\"/.[!.]* \"$dir\"/..?*; do test ! -e \"$f\" && test ! -L \"$f\" || exit 71; done; fi; done; " +
            "for f in " + files + "; do if test -e \"$f\" || test -L \"$f\"; then test -f \"$f\" && test ! -L \"$f\" && test \"$(stat -c '%u:%a:%h' \"$f\")\" = 0:600:1 || exit 71; fi; done; " +
            "for dir in " + Q(pending.Stage + "/apply-once") + " " + Q(pending.Stage + "/decision") + "; do if test -d \"$dir\"; then rmdir \"$dir\"; fi; done; " +
            "rm -f " + files + "; rmdir " + stage + "; printf 'ADB_STAGE_REMOVED\\n'";
        if (!Exact(await shell.RunAsync(command, timeout: TimeSpan.FromSeconds(10), ct: ct), "ADB_STAGE_REMOVED")) throw Failure();
    }
    private void Save(Pending pending, bool create = false)
    {
        var path = create ? PendingPath : PendingPath + ".new";
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var file = new FileStream(path, options))
        { JsonSerializer.Serialize(file, pending); file.Flush(flushToDisk: true); }
        if (!create) File.Move(path, PendingPath, overwrite: true);
    }
    private Pending Load()
    {
        var info = new FileInfo(PendingPath);
        if (info.LinkTarget is not null || info.Length is < 1 or > 2048) throw Failure();
        var bytes = File.ReadAllBytes(PendingPath);
        using var document = JsonDocument.Parse(bytes);
        var keys = document.RootElement.EnumerateObject().Select(x => x.Name).ToArray();
        if (!keys.Order().SequenceEqual(new[] { "Schema", "Token", "Cid", "Boot", "Firmware", "Router", "Desired", "Original", "Phase" }.Order())) throw Failure();
        var pending = JsonSerializer.Deserialize<Pending>(bytes) ?? throw Failure();
        if (pending.Schema != 1 || !Guid.TryParseExact(pending.Token, "D", out var token) || token.ToString("D") != pending.Token || !Known(pending.Identity) || pending.Phase is not ("preparing" or "prepared" or "dispatched")) throw Failure();
        _ = AccessIdentity.Parse(Encoding.ASCII.GetBytes(pending.Firmware + "  /firmware/image/modem.b16\n" + pending.Router + "  /usr/bin/diag-router\n" + pending.Cid + "\n" + pending.Boot + "\n"));
        return pending;
    }
}
