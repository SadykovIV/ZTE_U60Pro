using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Core;

public sealed record DeviceIdentity(string Cid, string FirmwareHash, string BootId);
public sealed record ImeiState(DeviceIdentity Identity, byte[][] Nv, string[] Imeis);
public sealed record ImeiBackupManifest(int Schema, string Id, DateTimeOffset Created, DeviceIdentity Identity, string[] Imeis, Dictionary<string,string> Hashes);
public sealed record ImeiPending(int Schema, string Id, string BackupId, DeviceIdentity Identity, string[] TargetHex,
    string Phase, string? FinalBootBefore = null, DateTimeOffset? WriteStartedAt = null,
    DateTimeOffset? ConfigMutationStartedAt = null);

/// <summary>Windows port of the B31 NV550 transaction. A journal survives process/device restarts.</summary>
public sealed partial class ImeiEngine(IRemoteShell shell, string storageRoot, string resourcesRoot, bool skipFirmwareCheck = false)
{
    public const string FirmwareHash = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
    public const string RouterHash = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f";
    private readonly JsonSerializerOptions jsonOptions = new() { WriteIndented = true };
    private string Backups => Path.Combine(storageRoot, "Backups", "IMEI");
    private string Pending => Path.Combine(storageRoot, "imei-pending.json");
    private string LockJournal => Path.Combine(storageRoot, "imei-lock.json");
    private string LocalLock => Path.Combine(storageRoot, "imei-operation.lock");
    private string? lockToken;
    private DeviceIdentity? lockIdentity;
    private FileStream? localLock;
    private sealed record LockOwnership(int Schema, string Token, string Cid, string FirmwareHash);

    private async Task<RemoteResult> Raw(string command, byte[]? input = null, TimeSpan? timeout = null, CancellationToken ct = default)
        => await shell.RunAsync(command, input, timeout ?? TimeSpan.FromSeconds(30), ct);
    private async Task<byte[]> Remote(string command, byte[]? input = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var result = await Raw(command, input, timeout, ct);
        if (result.ExitCode != 0) { var reason = Encoding.UTF8.GetString(result.Stderr).Trim(); throw new IOException($"SSH завершился с кодом {result.ExitCode}: {reason[..Math.Min(reason.Length,400)]}"); }
        return result.Stdout;
    }
    private async Task<string> Text(string command, CancellationToken ct = default)
        => Encoding.UTF8.GetString(await Remote(command, ct: ct)).Trim();

    public async Task<DeviceIdentity> IdentityAsync(CancellationToken ct = default)
    {
        var lines = (await Text("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router; cat /sys/block/mmcblk0/device/cid /proc/sys/kernel/random/boot_id", ct)).Split('\n', StringSplitOptions.TrimEntries);
        if (lines.Length != 4) throw new InvalidDataException("Не удалось прочитать идентификаторы модема.");
        static string HashLine(string line, string path)
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2 || parts[1] != path || parts[0].Length != 64 || parts[0].Any(c => !Uri.IsHexDigit(c))) throw new InvalidDataException("Неверная контрольная сумма прошивки.");
            return parts[0].ToLowerInvariant();
        }
        var firmware = HashLine(lines[0], "/firmware/image/modem.b16");
        var router = HashLine(lines[1], "/usr/bin/diag-router");
        if (!skipFirmwareCheck && (firmware != FirmwareHash || router != RouterHash)) throw new InvalidDataException("Прошивка отличается от проверенной MU5250 B31. Запись остановлена.");
        if (lines[2].Length != 32 || lines[2].Any(c => !Uri.IsHexDigit(c)) || !Guid.TryParse(lines[3], out _)) throw new InvalidDataException("Неверный CID или boot ID.");
        return new DeviceIdentity(lines[2].ToLowerInvariant(), firmware, lines[3]);
    }

    private static bool SameDevice(DeviceIdentity first, DeviceIdentity second) =>
        first.Cid == second.Cid && first.FirmwareHash == second.FirmwareHash;

    private async Task AcquireLock(DeviceIdentity identity, CancellationToken ct)
    {
        if (lockToken is not null)
        {
            if (lockIdentity is null || !SameDevice(lockIdentity, identity))
                throw new InvalidDataException("Блокировка относится к другому модему.");
            return;
        }
        Directory.CreateDirectory(storageRoot);
        var handle = new FileStream(LocalLock, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        try
        {
            if (File.Exists(Path.Combine(storageRoot,"adb-access-pending.json")))
                throw new InvalidOperationException("Сначала завершите включение диагностического ADB.");
            LockOwnership owner;
            if (File.Exists(LockJournal))
            {
                owner = JsonSerializer.Deserialize<LockOwnership>(await File.ReadAllTextAsync(LockJournal, ct))
                    ?? throw new InvalidDataException("Повреждён локальный токен блокировки.");
                if (owner.Schema != 1 || !Guid.TryParse(owner.Token, out _) ||
                    owner.Cid != identity.Cid || owner.FirmwareHash != identity.FirmwareHash)
                    throw new InvalidDataException("Сохранённая блокировка относится к другому модему.");
            }
            else
            {
                owner = new LockOwnership(1, Guid.NewGuid().ToString(), identity.Cid, identity.FirmwareHash);
                await SaveJson(LockJournal, owner, ct);
            }
            await AcquireRemoteToken(owner.Token, ct);
            localLock = handle;
            lockToken = owner.Token;
            lockIdentity = identity;
        }
        catch { handle.Dispose(); throw; }
    }

    private async Task AcquireRemoteToken(string token, CancellationToken ct)
    {
        var command = "umask 077; if mkdir /tmp/zte-imei-app.lock 2>/dev/null; then printf '%s' " +
            VerifiedHash.ShellQuote(token) + " > /tmp/zte-imei-app.lock/owner; else test \"$(cat /tmp/zte-imei-app.lock/owner 2>/dev/null)\" = " +
            VerifiedHash.ShellQuote(token) + "; fi";
        await Remote(command, ct: ct);
    }
    private async Task ReleaseLock()
    {
        if (lockToken is not { } token) return;
        lockToken = null;
        lockIdentity = null;
        try
        {
            // A timed-out helper can still be finishing a raw write. Keep its
            // token until the pending journal is reconciled explicitly.
            if (!File.Exists(Pending))
            {
                await Remote("test \"$(cat /tmp/zte-imei-app.lock/owner 2>/dev/null)\" = " +
                    VerifiedHash.ShellQuote(token) + " && rm /tmp/zte-imei-app.lock/owner && rmdir /tmp/zte-imei-app.lock",
                    timeout: TimeSpan.FromSeconds(10));
                File.Delete(LockJournal);
            }
        }
        catch { /* Keep the local token if remote ownership is uncertain. */ }
        finally { localLock?.Dispose(); localLock = null; }
    }
    private async Task<T> Locked<T>(DeviceIdentity identity, Func<CancellationToken,Task<T>> work, CancellationToken ct)
    {
        await AcquireLock(identity, ct);
        try { return await work(ct); }
        finally { await ReleaseLock(); }
    }

    private async Task<string> Helper(string name, string mode, byte[]? plan = null, CancellationToken ct = default)
    {
        if (name is not ("zte_nv" or "zte_config" or "zte_config_read")) throw new ArgumentException("Неизвестный helper.");
        var manifest = JsonSerializer.Deserialize<Dictionary<string,string>>(await File.ReadAllTextAsync(Path.Combine(resourcesRoot, "Helpers", "helpers.json"), ct))!;
        var bytes = await File.ReadAllBytesAsync(Path.Combine(resourcesRoot, "Helpers", name), ct);
        if (!manifest.TryGetValue(name, out var expected) || expected != VerifiedHash.Sha256(bytes)) throw new InvalidDataException("Повреждён встроенный helper.");
        var dir = "/tmp/zte-imei-" + Guid.NewGuid().ToString();
        var path = dir + "/helper";
        await Remote("umask 077; mkdir " + VerifiedHash.ShellQuote(dir), ct: ct);
        try
        {
            var receipt = await TextWithInput("umask 077; cat > " + VerifiedHash.ShellQuote(path) + " && chmod 700 " + VerifiedHash.ShellQuote(path) + " && sha256sum " + VerifiedHash.ShellQuote(path), bytes, ct);
            if (!receipt.StartsWith(VerifiedHash.Sha256(bytes), StringComparison.Ordinal)) throw new InvalidDataException("Helper повреждён при передаче.");
            if (plan is not null)
            {
                var planPath = dir + "/plan";
                receipt = await TextWithInput("umask 077; cat > " + VerifiedHash.ShellQuote(planPath) + " && sha256sum " + VerifiedHash.ShellQuote(planPath), plan, ct);
                if (!receipt.StartsWith(VerifiedHash.Sha256(plan), StringComparison.Ordinal)) throw new InvalidDataException("План повреждён при передаче.");
            }
            var result = await Raw(VerifiedHash.ShellQuote(path) + " " + VerifiedHash.ShellQuote(mode) + (plan is null ? "" : " " + VerifiedHash.ShellQuote(dir + "/plan")), timeout: TimeSpan.FromSeconds(240), ct: ct);
            if (result.ExitCode != 0) throw new IOException($"Helper {name} остановился (код {result.ExitCode}). Повторная запись не запускается автоматически.");
            return Encoding.UTF8.GetString(result.Stdout) + Encoding.UTF8.GetString(result.Stderr);
        }
        finally { try { await Remote("rm -f " + VerifiedHash.ShellQuote(path) + " " + VerifiedHash.ShellQuote(dir + "/plan") + "; rmdir " + VerifiedHash.ShellQuote(dir), timeout: TimeSpan.FromSeconds(15)); } catch { } }
    }
    private async Task<string> TextWithInput(string command, byte[] bytes, CancellationToken ct)
        => Encoding.UTF8.GetString(await Remote(command, bytes, ct: ct)).Trim();

    private async Task<byte[][]> Snapshot(CancellationToken ct)
    {
        var result = await Helper("zte_nv", "--snapshot", ct: ct);
        var values = new Dictionary<int,byte[]>();
        foreach (var line in result.Split('\n', StringSplitOptions.TrimEntries))
        {
            if (!line.StartsWith("APP_NV ", StringComparison.Ordinal)) continue;
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length != 3 || !fields[1].StartsWith("index=") || !fields[2].StartsWith("data=") || !int.TryParse(fields[1][6..], out var index) || index is < 0 or > 1 || values.ContainsKey(index)) throw new InvalidDataException("Неполный или неоднозначный ответ NV.");
            values[index] = Convert.FromHexString(fields[2][5..]);
        }
        if (values.Count != 2) throw new InvalidDataException("Не получены оба NV550.");
        var pair = new[] { values[0], values[1] };
        foreach (var record in pair) _ = ImeiCodec.DecodeNv550(record);
        return pair;
    }
    private async Task<string[]> ApiPair(CancellationToken ct)
    {
        var pair = new string[2]; var methods = new[] { "get_imei", "get_imei2" };
        for (var i = 0; i < 2; i++)
        {
            using var doc = JsonDocument.Parse(await Remote("ubus call zwrt_zte_mdm.api " + methods[i], ct: ct));
            var values = doc.RootElement.EnumerateObject().Where(p => p.Value.ValueKind == JsonValueKind.String).Select(p => p.Value.GetString()!).Where(ImeiCodec.IsValid).ToArray();
            if (values.Length != 1) throw new InvalidDataException("API не вернул однозначный IMEI.");
            pair[i] = values[0];
        }
        return pair;
    }
    private async Task<byte[]> ReadConfig(CancellationToken ct)
    {
        var output = await Helper("zte_config_read", "--read-config", ct: ct);
        using var memory = new MemoryStream(); var complete = false;
        foreach (var line in output.Split('\n', StringSplitOptions.TrimEntries))
        {
            if (line.StartsWith("EFS_DATA_HEX ", StringComparison.Ordinal))
            {
                var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length != 4 || !parts[1].StartsWith("offset=") || !parts[2].StartsWith("length=") || !parts[3].StartsWith("data=")) throw new InvalidDataException("Неверный ответ config.");
                if (!int.TryParse(parts[1][7..], out var offset) || !int.TryParse(parts[2][7..], out var length)) throw new InvalidDataException("Неверный offset config.");
                var chunk = Convert.FromHexString(parts[3][5..]);
                if (offset != memory.Length || length != chunk.Length) throw new InvalidDataException("Пропуск данных config.");
                memory.Write(chunk);
            }
            if (line.StartsWith("EFS_FILE_COMPLETE path=/config length=15073 ", StringComparison.Ordinal)) complete = true;
        }
        if (!complete) throw new InvalidDataException("Не получен полный config.");
        var result = memory.ToArray(); _ = ConfigCodec.Validate(result); return result;
    }

    public async Task<ImeiState> InspectAsync(CancellationToken ct = default)
    {
        var identity = await IdentityAsync(ct);
        return await Locked(identity, token => InspectCoreAsync(identity, token), ct);
    }

    private async Task<ImeiState> InspectCoreAsync(DeviceIdentity identity, CancellationToken ct)
    {
        var nv = await Snapshot(ct);
        var imeis = nv.Select(item => ImeiCodec.DecodeNv550(item)).ToArray();
        if (!(await ApiPair(ct)).SequenceEqual(imeis)) throw new InvalidDataException("IMEI в API и NV различаются.");
        return new ImeiState(identity, nv, imeis);
    }

    public async Task<string> CreateBackupAsync(CancellationToken ct = default)
    {
        if (File.Exists(Pending)) throw new InvalidOperationException("Сначала продолжите незавершённую запись IMEI.");
        var identity = await IdentityAsync(ct);
        return await Locked(identity, async token =>
            await CreateBackupCoreAsync(await InspectCoreAsync(identity, token), token), ct);
    }

    private async Task<string> CreateBackupCoreAsync(ImeiState state, CancellationToken ct)
    {
        var config = await ReadConfig(ct);
        if (ConfigCodec.Validate(config) != 0 || !PairEqual(await Snapshot(ct), state.Nv))
            throw new InvalidDataException("NV/config изменился во время бэкапа.");
        var id = Guid.NewGuid().ToString();
        var dir = Path.Combine(Backups, id);
        Directory.CreateDirectory(dir);
        var files = new Dictionary<string,byte[]> { ["nv0.bin"] = state.Nv[0], ["nv1.bin"] = state.Nv[1], ["config.bin"] = config };
        foreach (var (name, data) in files) await SaveBytes(Path.Combine(dir, name), data, ct);
        var manifest = new ImeiBackupManifest(1,id,DateTimeOffset.UtcNow,state.Identity,state.Imeis,
            files.ToDictionary(x => x.Key,x => VerifiedHash.Sha256(x.Value)));
        await SaveJson(Path.Combine(dir,"manifest.json"),manifest,ct);
        _ = await LoadBackup(dir,ct);
        return dir;
    }
    private async Task<(ImeiBackupManifest manifest,byte[][] nv,byte[] config)> LoadBackup(string dir,CancellationToken ct)
    {
        var manifest = JsonSerializer.Deserialize<ImeiBackupManifest>(await File.ReadAllTextAsync(Path.Combine(dir,"manifest.json"),ct)) ?? throw new InvalidDataException("Неверный манифест бэкапа.");
        if (manifest.Schema != 1 || !Guid.TryParse(manifest.Id,out _) || manifest.Imeis.Length != 2 || manifest.Hashes.Count != 3) throw new InvalidDataException("Неверный формат бэкапа.");
        var files = new Dictionary<string,byte[]>();
        foreach (var name in new[] { "nv0.bin","nv1.bin","config.bin" })
        {
            var path = Path.Combine(dir,name);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Ссылка в бэкапе запрещена.");
            var data = await File.ReadAllBytesAsync(path,ct);
            if (manifest.Hashes.GetValueOrDefault(name) != VerifiedHash.Sha256(data)) throw new InvalidDataException("Повреждён бэкап: " + name);
            files[name] = data;
        }
        var pair = new[] { files["nv0.bin"],files["nv1.bin"] }; var config = files["config.bin"];
        if (!pair.Select(item => ImeiCodec.DecodeNv550(item)).SequenceEqual(manifest.Imeis) || ConfigCodec.Validate(config) != 0) throw new InvalidDataException("IMEI/config бэкапа не совпадают.");
        return (manifest,pair,config);
    }
    private async Task SaveJson<T>(string path,T value,CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        await using (var stream = new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough))
        { await JsonSerializer.SerializeAsync(stream,value,jsonOptions,ct); await stream.FlushAsync(ct); }
        File.Move(temp,path,true);
    }

    private static async Task SaveBytes(string path, byte[] data, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        await using (var stream = new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough))
        { await stream.WriteAsync(data,ct); await stream.FlushAsync(ct); }
        File.Move(temp,path);
    }

    private static bool PairEqual(byte[][] first, byte[][] second) =>
        first.Length == 2 && second.Length == 2 && first[0].AsSpan().SequenceEqual(second[0]) && first[1].AsSpan().SequenceEqual(second[1]);
}
