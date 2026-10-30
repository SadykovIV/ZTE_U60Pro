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
    internal const string ScriptSha256 = "1ab9a52c4a5bf062e0863dba043e5f5da08d7397dde2d0fb1856e7955eb9e363";
    internal const string Release1271ScriptSha256 = "8e8f39ca743a4e53971db885afc3117ab3023a0ff3d6144c0954b078f6562a79";
    internal const string PreviousScriptSha256 = "0ca5d10426c8398bab5e35af525782c490dce30f841a073e2cc64e3dc49c27dd";
    internal const string B04FirmwareHash = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
    internal const string B28FirmwareHash = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478";
    internal const string B27FirmwareHash = "4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e";
    internal const string B27RouterHash = "786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f";
    internal const string B27CapabilityCommand = """
        test -f /usr/bin/zte_topsw_mdm && test ! -L /usr/bin/zte_topsw_mdm && test "$(stat -c %u /usr/bin/zte_topsw_mdm)" = 0 || exit 71
          test "$(sha256sum /usr/bin/zte_topsw_mdm | cut -d ' ' -f 1)" = 00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d || exit 71
        """;
    internal const string PendingName = "adb-toggle-pending.json";
    internal const string Unknown = "Результат переключения ADB не подтверждён. Подключитесь по SSH и обновите состояние ADB. Повторное переключение заблокировано. Если повторная проверка не помогает, перезапустите модем и подключитесь снова.";
    internal const string CapabilityCommand = "set -eu; test \"$(id -u)\" = 0; for tool in sh stat readlink sha256sum cut awk sed sort pidof nohup sleep cat mv rm rmdir mkdir ln id uname cmp chmod; do command -v \"$tool\" >/dev/null || exit 71; done; test ! -L /sbin/adbd; test -f /sbin/adbd && test -x /sbin/adbd && test \"$(stat -c %u /sbin/adbd)\" = 0; printf 'ADB_CONTROL_CAPABLE\\n'";
    // The captured B04 image or its absence requires the measured native build; it
    // is never an ADB write grant.
    internal const string B04CapabilityCommand = """
        if test -e /firmware/image/modem.b16 || test -L /firmware/image/modem.b16; then
          test -f /firmware/image/modem.b16 && test ! -L /firmware/image/modem.b16 && test "$(stat -c %u /firmware/image/modem.b16)" = 0 || exit 71
          test "$(sha256sum /firmware/image/modem.b16 | cut -d ' ' -f 1)" = c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81 || exit 71
        fi
          test -f /usr/bin/zte_topsw_mdm && test ! -L /usr/bin/zte_topsw_mdm && test "$(stat -c %u /usr/bin/zte_topsw_mdm)" = 0 || exit 71
          test "$(sha256sum /usr/bin/zte_topsw_mdm | cut -d ' ' -f 1)" = 93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64 || exit 71
          info=$(ubus -t 5 call zwrt_web device_info '{}') || exit 71
          test "$(printf '%s' "$info" | jsonfilter -e '@.integrate_version')" = XCBZ_HK_MU5250V1.0.0B04 || exit 71
          test "$(printf '%s' "$info" | jsonfilter -e '@.wa_inner_version')" = BD_XCBZHKMU5250V1.0.0B04 || exit 71
        """;
    private static string Capability(AccessDeviceIdentity identity) => identity.FirmwareHash == B27FirmwareHash
        ? "set -eu; " + B27CapabilityCommand + "; " + CapabilityCommand
        : (identity.FirmwareHash == "absent" || identity.FirmwareHash == B04FirmwareHash)
        ? "set -eu; " + B04CapabilityCommand + "; " + CapabilityCommand : CapabilityCommand;
    private string PendingPath => Path.Combine(storage, PendingName);
    private sealed record Pending(int Schema, string Token, string Cid, string Boot, string Firmware, string Router, bool Desired, bool Original, string Phase)
    {
        internal string Stage => "/tmp/zte-adb-toggle-" + Token;
        internal AccessDeviceIdentity Identity => new(Cid, Firmware, Boot, Router);
    }
    private static DeviceFeatureException Failure(string message = Unknown) => new(message);
    private static string Q(string value) => DeviceFeatureService.Quote(value);
    private static bool Exact(RemoteResult result, string line) => result.Success && result.Stdout.AsSpan().SequenceEqual(Encoding.ASCII.GetBytes(line + "\n"));
    private static bool Known(AccessDeviceIdentity identity) => identity.FirmwareHash == B27FirmwareHash
        ? identity.RouterHash == B27RouterHash
        : (identity.FirmwareHash == DeviceFeatureService.FirmwareHash || identity.FirmwareHash == B28FirmwareHash || identity.FirmwareHash == B04FirmwareHash || identity.FirmwareHash == "absent") && identity.RouterHash == DeviceFeatureService.RouterHash;

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
        var capability = await shell.RunAsync(Capability(before), timeout: TimeSpan.FromSeconds(10), ct: ct);
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
            var pending = Load();
            var current = await AccessIdentity.ReadAsync(shell, ct);
            if (current.Cid != pending.Cid || current.FirmwareHash != pending.Firmware || current.RouterHash != pending.Router) throw Failure();
            if (current.BootId != pending.Boot)
            {
                // Reboot destroys /tmp. An old dispatch is retired only after two
                // fresh proofs of the same hardware, absent stage/lock and a
                // readable current USB state. No remote file is deleted.
                if (!await StageAbsent(pending, ct)) throw Failure();
                var observed = await Observe(ct, current);
                if (observed.Enabled is null || !await StageAbsent(pending, ct) || await AccessIdentity.ReadAsync(shell, ct) != current) throw Failure();
                Archive(pending);
                return observed;
            }
            if (pending.Phase != "dispatched" && await RecoverAbsentStage(pending, ct))
                return await Observe(ct, pending.Identity);
            // Reconnect never ACKs or reapplies. Execute current verified code
            // over stdin; the old staged script is an identity proof only.
            var source = await Script(ct);
            var recovery = await shell.RunAsync("set -eu; " + ScriptGuard(pending, recovery: true) +
                "exec /bin/sh -s -- " + string.Join(' ', new[] { "reconcile", pending.Stage, pending.Token, pending.Cid, pending.Boot, pending.Desired ? "1" : "0" }.Select(Q)) + " \"$stage_hash\"",
                source, TimeSpan.FromSeconds(30), ct);
            var phase = new[] { "cancelled", "settled-before", "settled-after" }.FirstOrDefault(p => Exact(recovery, "ADB_RECOVERED=" + p));
            if (phase is null) throw Failure();
            var state = await Observe(ct, pending.Identity);
            if (state.Enabled != (phase == "settled-after" ? pending.Desired : pending.Original)) throw Failure();
            await Bound(pending, ct);
            // Archive exact local intent before optional stage housekeeping. A
            // lost cleanup response must not recreate an already settled lock.
            Archive(pending);
            try { await Cleanup(pending, ct); }
            catch (Exception error) when (error is IOException or TimeoutException or DeviceFeatureException or Renci.SshNet.Common.SshException) { }
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
        if (!Known(identity)) throw Failure("Для этой прошивки переключение ADB ещё не подтверждено; поддерживаются измеренные B04, B27, B28 и B31.");
        var state = await Observe(ct, identity);
        var persistenceOnly = !desired && state.Enabled == false && Exact(await shell.RunAsync(Capability(identity), timeout: TimeSpan.FromSeconds(10), ct: ct), "ADB_CONTROL_CAPABLE");
        if ((!state.SupportsChange && !persistenceOnly) || state.Enabled is null) throw Failure("Безопасное переключение ADB для этой конфигурации не подтверждено. Для включения нужны готовые USB-дескрипторы ADB; выключение уже отсутствующего ADB доступно через SSH.");
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
                await Complete(pending, ct);
                return same;
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
                        await Complete(pending, deadline.Token);
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
                    { await Complete(pending, cleanupDeadline.Token); preparationCleared = true; }
                }
                catch { /* Unknown ownership/staging stays recorded for inspection. */ }
            }
            if (preparationCleared) throw Failure("Переключение ADB не начиналось. Настройки модема не изменены.");
            if (!File.Exists(PendingPath) && error is DeviceFeatureException) throw;
            throw Failure(); // Never surface raw SSH output or identity/token data.
        }
    }
    private async Task<bool> StageAbsent(Pending pending, CancellationToken ct)
    {
        var stage = Q(pending.Stage);
        var command = "set -eu; test -d /tmp && test ! -L /tmp && test \"$(stat -c %u /tmp)\" = 0 || exit 71; " +
            "test ! -e " + stage + " && test ! -L " + stage + " && test ! -e /tmp/zte-imei-app.lock && test ! -L /tmp/zte-imei-app.lock || exit 71; printf 'ADB_STAGE_ABSENT\\n'";
        return Exact(await shell.RunAsync(command, timeout: TimeSpan.FromSeconds(10), ct: ct), "ADB_STAGE_ABSENT");
    }
    private async Task<bool> RecoverAbsentStage(Pending pending, CancellationToken ct)
    {
        if (pending.Phase == "dispatched") return false;
        await Bound(pending, ct);
        if (!await StageAbsent(pending, ct)) return false;
        var observed = await Observe(ct, pending.Identity);
        if (observed.Enabled is null || !await StageAbsent(pending, ct)) throw Failure();
        await Bound(pending, ct);
        Archive(pending);
        return true;
    }
    private void Archive(Pending pending)
    {
        if (Load() != pending) throw Failure();
        var destination = Path.Combine(storage, "adb-toggle-recovered-" + pending.Token + ".json");
        if (File.Exists(destination) || Directory.Exists(destination))
        {
            var info = new FileInfo(destination);
            if (info.LinkTarget is not null || info.Length is < 1 or > 2048 || !File.ReadAllBytes(destination).SequenceEqual(File.ReadAllBytes(PendingPath))) throw Failure();
            File.Delete(PendingPath);
        }
        else File.Move(PendingPath, destination);
    }
    private async Task Bound(Pending pending, CancellationToken ct)
    { if (await AccessIdentity.ReadAsync(shell, ct) != pending.Identity) throw Failure(); }
    private string ScriptGuard(Pending pending, bool recovery = false)
    {
        var stage = Q(pending.Stage); var path = Q(pending.Stage + "/adb-toggle.sh");
        return "test -d " + stage + " && test ! -L " + stage + " && test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700 || exit 71; " +
            "test -f " + path + " && test ! -L " + path + " && test \"$(stat -c '%u:%a:%h' " + path + ")\" = 0:600:1 && test \"$(stat -c %s " + path + ")\" -le 65536 || exit 71; " +
            "stage_hash=$(sha256sum " + path + " | cut -d ' ' -f 1); " +
            (recovery ? "case \"$stage_hash\" in " + ScriptSha256 + "|" + Release1271ScriptSha256 + "|" + PreviousScriptSha256 + ") :;; *) exit 71;; esac; " : "test \"$stage_hash\" = " + Q(ScriptSha256) + " || exit 71; ");
    }
    private static string Arguments(Pending pending, string action) => string.Join(' ', new[] { pending.Stage + "/adb-toggle.sh", action, pending.Stage, pending.Token, pending.Cid, pending.Boot, pending.Desired ? "1" : "0" }.Select(Q));
    private Task<RemoteResult> Call(Pending pending, string action, CancellationToken ct) => shell.RunAsync("set -eu; " + ScriptGuard(pending) + "sh " + Arguments(pending, action), timeout: TimeSpan.FromSeconds(10), ct: ct);
    private static string Phase(RemoteResult result)
    {
        foreach (var phase in new[] { "preparing", "prepared", "changing", "awaiting-ack", "committed", "rolled-back", "rollback-unknown", "cleanup-unknown", "cancelled" })
            if (Exact(result, "ADB_PHASE=" + phase)) return phase;
        throw new IOException("ADB phase unavailable.");
    }
    private async Task Complete(Pending pending, CancellationToken ct)
    {
        await Bound(pending, ct);
        Archive(pending);
        try { await Cleanup(pending, ct); }
        catch (Exception error) when (error is IOException or TimeoutException or DeviceFeatureException or Renci.SshNet.Common.SshException) { }
    }
    private async Task Cleanup(Pending pending, CancellationToken ct)
    {
        await Bound(pending, ct);
        var stage = Q(pending.Stage);
        var names = new[] { "adb-toggle.sh", "before", "after", "udc", "daemon", "name", "target", "desired", "original", "phase", "ack", "worker.log", "rc.before", "rc.after", "rc.mode", "phase.new", "before.new", "after.new", "udc.new", "daemon.new", "name.new", "target.new", "desired.new", "original.new", "ack.new", "rc.mode.new" };
        var files = string.Join(' ', names.Select(n => Q(pending.Stage + "/" + n)));
        var released = Q(pending.Stage + "/released-lock");
        var releasedGuard = "if test -e " + released + " || test -L " + released + "; then test -d " + released + " && test ! -L " + released + " && test \"$(stat -c '%u:%a' " + released + ")\" = 0:700 || exit 71; for p in " + released + "/* " + released + "/.[!.]* " + released + "/..?*; do test ! -e \"$p\" && test ! -L \"$p\" && continue; test \"${p##*/}\" = owner && test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c '%u:%a:%h' \"$p\")\" = 0:600:1 && test \"$(cat \"$p\")\" = " + Q(pending.Token) + " || exit 71; done; fi; ";
        var releasedRemove = "if test -d " + released + "; then rm -f " + Q(pending.Stage + "/released-lock/owner") + "; rmdir " + released + "; fi; ";
        var command = "set -eu; test -d " + stage + " && test ! -L " + stage + " && test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700 || exit 71; " + releasedGuard +
            "for entry in " + stage + "/* " + stage + "/.[!.]* " + stage + "/..?*; do test ! -e \"$entry\" && test ! -L \"$entry\" && continue; case \"${entry##*/}\" in adb-toggle.sh|before|after|udc|daemon|name|target|desired|original|phase|ack|worker.log|rc.before|rc.after|rc.mode|phase.new|before.new|after.new|udc.new|daemon.new|name.new|target.new|desired.new|original.new|ack.new|rc.mode.new|apply-once|decision|released-lock) :;; *) exit 71;; esac; done; " +
            "for dir in " + Q(pending.Stage + "/apply-once") + " " + Q(pending.Stage + "/decision") + "; do if test -e \"$dir\" || test -L \"$dir\"; then test -d \"$dir\" && test ! -L \"$dir\" && test \"$(stat -c '%u:%a' \"$dir\")\" = 0:700 || exit 71; for f in \"$dir\"/* \"$dir\"/.[!.]* \"$dir\"/..?*; do test ! -e \"$f\" && test ! -L \"$f\" || exit 71; done; fi; done; " +
            "for f in " + files + "; do if test -e \"$f\" || test -L \"$f\"; then test -f \"$f\" && test ! -L \"$f\" && test \"$(stat -c '%u:%a:%h' \"$f\")\" = 0:600:1 || exit 71; fi; done; " +
            releasedRemove + "rm -f " + files + "; " +
            "for dir in " + Q(pending.Stage + "/apply-once") + " " + Q(pending.Stage + "/decision") + "; do if test -d \"$dir\"; then rmdir \"$dir\"; fi; done; rmdir " + stage + "; printf 'ADB_STAGE_REMOVED\\n'";
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
