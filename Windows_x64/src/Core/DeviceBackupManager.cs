using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows.Core;

public sealed record DeviceBackupEntry(string Name, string Source, long Bytes, string Sha256);
public sealed record DeviceBackupManifest(int Schema, string Id, DateTimeOffset CreatedAt,
    string Cid, string FirmwareHash, string BootId, DeviceBackupEntry[] Files,
    string Scope, bool Complete);

/// <summary>
/// Read-only data snapshot. The modem streams four NV partitions, /data,
/// and configuration; firmware and system images are outside this copy.
/// </summary>
public sealed class DeviceBackupManager(SshTransport shell, DeviceFeatureService features,
    string storageRoot)
{
    private const long Limit = 16L * 1024 * 1024 * 1024;
    private const long Reserve = 64L * 1024 * 1024;
    private string Root => Path.Combine(storageRoot, "DeviceBackups");
    private static readonly (string Name,string Mode,string Argument,string Source,long? ExactSize)[] Files =
    [
        ("modemst1.bin","partition","modemst1","/dev/mmcblk0p8",4_194_304),
        ("modemst2.bin","partition","modemst2","/dev/mmcblk0p9",4_194_304),
        ("fsg.bin","partition","fsg","/dev/mmcblk0p10",4_194_304),
        ("persist.bin","partition","persist","/dev/mmcblk0p56",8_388_608),
        ("user-data.tar","userData","userData","/data",null),
        ("configuration.tar","configuration","configuration","/etc + selected /data settings",null),
    ];
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public async Task<string> CreateAsync(CancellationToken ct = default)
    {
        foreach (var pending in new[] { "imei-pending.json", "setup-pending.json" })
            if (File.Exists(Path.Combine(storageRoot,pending)))
                throw new InvalidOperationException("Сначала завершите незавершённую операцию с модемом.");
        Directory.CreateDirectory(Root);
        var id = Guid.NewGuid().ToString("D");
        var partial = Path.Combine(Root,".partial-" + id);
        var final = Path.Combine(Root,id);
        if (Directory.Exists(partial) || Directory.Exists(final)) throw new IOException("Имя резервной копии уже занято.");
        Directory.CreateDirectory(partial);
        try
        {
            var manifest = await features.MutateAsync(async (identity, token) =>
            {
                var bytes = await features.ResourceAsync("DeviceBackups","reader.sh",ct);
                var stage = await features.StageAsync("zte-device-backup",new Dictionary<string,byte[]> { ["reader.sh"] = bytes },ct);
                try
                {
                    var script = stage + "/reader.sh";
                    var expectedScriptHash = DeviceFeatureService.Sha(bytes);
                    var guard = DeviceFeatureService.Guard(identity,token) +
                        "test \"$(sha256sum " + DeviceFeatureService.Quote(script) + " | cut -d ' ' -f1)\" = " +
                        DeviceFeatureService.Quote(expectedScriptHash) + "; ";
                    var userEstimate = await EstimateAsync(guard,script,identity.Cid,"userData",ct);
                    var configEstimate = await EstimateAsync(guard,script,identity.Cid,"configuration",ct);
                    var estimated = checked(20_971_520L + userEstimate + configEstimate);
                    var free = new DriveInfo(Path.GetPathRoot(partial)!).AvailableFreeSpace;
                    if (free < Math.Min(Limit, estimated + Math.Max(Reserve, estimated / 2)) + Reserve)
                        throw new IOException("Недостаточно места для полного бэкапа и запаса 64 МиБ.");
                    var entries = new List<DeviceBackupEntry>();
                    foreach (var file in Files)
                    {
                        ct.ThrowIfCancellationRequested();
                        var estimate = file.Mode switch
                        {
                            "userData" => userEstimate,
                            "configuration" => configEstimate,
                            _ => file.ExactSize!.Value,
                        };
                        var maximum = file.ExactSize ?? Math.Min(Limit,checked(estimate + Math.Max(Reserve,estimate / 2)));
                        var command = guard + "sh " + DeviceFeatureService.Quote(script) + " " +
                            file.Mode + " " + DeviceFeatureService.Quote(identity.Cid) + " " +
                            DeviceFeatureService.Quote(file.Argument);
                        var path = Path.Combine(partial,file.Name);
                        var stream = await shell.RunToFileAsync(command,path,maximum,TimeSpan.FromHours(2),ct);
                        if (!stream.Success) throw new IOException("Снимок " + file.Name + " не получен: " + SafeFailure(stream.Stderr));
                        var receipt = ParseReceipt(stream.Stderr);
                        if (stream.Bytes != receipt.Bytes || stream.Sha256 != receipt.Sha256 ||
                            (file.ExactSize is { } exact && exact != stream.Bytes))
                            throw new InvalidDataException("Размер или SHA-256 потока " + file.Name + " не совпали с подтверждением модема.");
                        entries.Add(new DeviceBackupEntry(file.Name,file.Source,stream.Bytes,stream.Sha256));
                    }
                    await features.VerifyIdentityAsync(identity,ct);
                    return new DeviceBackupManifest(1,id,DateTimeOffset.UtcNow,identity.Cid,
                        identity.FirmwareHash,identity.BootId,entries.ToArray(),
                        "modemst1, modemst2, fsg, persist, /data и конфигурация; снимок работающего устройства",true);
                }
                finally { await features.CleanupStageAsync(stage,["reader.sh"],CancellationToken.None); }
            },ct);
            await using (var output = new FileStream(Path.Combine(partial,"manifest.json"),FileMode.CreateNew,
                FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough))
            { await JsonSerializer.SerializeAsync(output,manifest,Json,ct); await output.FlushAsync(ct); }
            _ = await VerifyPathAsync(partial,id,ct);
            Directory.Move(partial,final);
            return final;
        }
        catch
        {
            try { Directory.Delete(partial,true); } catch { /* partial remains visibly incomplete */ }
            throw;
        }
    }

    private async Task<long> EstimateAsync(string guard,string script,string cid,string kind,CancellationToken ct)
    {
        var reply = await features.RunTextAsync(guard + "sh " + DeviceFeatureService.Quote(script) +
            " estimate " + DeviceFeatureService.Quote(cid) + " " + kind,seconds:90,ct:ct);
        const string prefix = "BACKUP_ESTIMATE bytes=";
        if (!reply.StartsWith(prefix,StringComparison.Ordinal) ||
            !long.TryParse(reply[prefix.Length..],NumberStyles.None,CultureInfo.InvariantCulture,out var value) ||
            value is < 1 or > Limit - Reserve)
            throw new InvalidDataException("Модем не вернул допустимую оценку размера бэкапа.");
        return value;
    }

    private static (string Sha256,long Bytes) ParseReceipt(byte[] stderr)
    {
        if (stderr.Length > 1024 * 1024) throw new InvalidDataException("Слишком большой ответ копирования.");
        var lines = Encoding.UTF8.GetString(stderr).Split('\n',StringSplitOptions.TrimEntries);
        var found = lines.Where(x => x.StartsWith("BACKUP_RESULT ",StringComparison.Ordinal)).ToArray();
        if (found.Length != 1) throw new InvalidDataException("Модем не подтвердил SHA-256 потока.");
        var fields = found[0].Split(' ',StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 3 || !fields[1].StartsWith("sha256=") || !fields[2].StartsWith("bytes="))
            throw new InvalidDataException("Неверный формат подтверждения потока.");
        var hash = fields[1][7..];
        if (hash.Length != 64 || hash.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')) ||
            !long.TryParse(fields[2][6..],NumberStyles.None,CultureInfo.InvariantCulture,out var size) || size <= 0)
            throw new InvalidDataException("Неверная контрольная сумма или размер потока.");
        return (hash,size);
    }

    private static string SafeFailure(byte[] stderr)
    {
        var lines = Encoding.UTF8.GetString(stderr.AsSpan(0,Math.Min(stderr.Length,16_384))).Split('\n');
        return string.Join("; ",lines.Where(x => x.StartsWith("BACKUP_ERROR ",StringComparison.Ordinal))
            .Take(3).Select(x => x[..Math.Min(x.Length,160)])) is { Length: > 0 } text
            ? text : "модем остановил чтение; неполная копия удалена";
    }

    public async Task<DeviceBackupManifest> VerifyAsync(string id,CancellationToken ct = default)
    {
        return await VerifyStoredAsync(storageRoot,id,ct);
    }

    public static async Task<DeviceBackupManifest> VerifyStoredAsync(string storageRoot,string id,CancellationToken ct = default)
    {
        if (!Guid.TryParseExact(id,"D",out _)) throw new ArgumentException("Неверный ID резервной копии.");
        return await VerifyPathAsync(Path.Combine(storageRoot,"DeviceBackups",id),id,ct);
    }

    private static async Task<DeviceBackupManifest> VerifyPathAsync(string directory,string id,CancellationToken ct)
    {
        if (!Directory.Exists(directory) || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Папка копии отсутствует или является ссылкой.");
        var manifestPath = Path.Combine(directory,"manifest.json");
        if (!File.Exists(manifestPath) || (File.GetAttributes(manifestPath) & FileAttributes.ReparsePoint) != 0 ||
            new FileInfo(manifestPath).Length > 64 * 1024)
            throw new InvalidDataException("Манифест копии отсутствует или повреждён.");
        var manifest = JsonSerializer.Deserialize<DeviceBackupManifest>(await File.ReadAllTextAsync(manifestPath,ct))
            ?? throw new InvalidDataException("Неверный манифест копии.");
        if (manifest.Schema != 1 || !manifest.Complete || manifest.Id != id || manifest.Files.Length != Files.Length ||
            !Guid.TryParse(manifest.BootId,out _) || manifest.Cid.Length != 32 ||
            manifest.Cid.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')) ||
            manifest.FirmwareHash != ImeiEngine.FirmwareHash)
            throw new InvalidDataException("Неверный формат полной копии.");
        var names = Files.Select(x => x.Name).Append("manifest.json").ToHashSet(StringComparer.Ordinal);
        if (!Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).ToHashSet(StringComparer.Ordinal).SetEquals(names))
            throw new InvalidDataException("Состав файлов бэкапа отличается от ожидаемого.");
        foreach (var expected in Files)
        {
            var entry = manifest.Files.SingleOrDefault(x => x.Name == expected.Name);
            if (entry is null || entry.Source != expected.Source || entry.Bytes < 1 || entry.Bytes > Limit ||
                entry.Sha256.Length != 64 || entry.Sha256.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')) ||
                (expected.ExactSize is { } exact && exact != entry.Bytes))
                throw new InvalidDataException("Неверное описание файла в копии: " + expected.Name);
            var path = Path.Combine(directory,expected.Name);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length != entry.Bytes)
                throw new InvalidDataException("Размер файла копии не совпал: " + expected.Name);
            await using var input = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,1024*1024,FileOptions.Asynchronous);
            var hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(input,ct));
            if (hash != entry.Sha256) throw new InvalidDataException("SHA-256 файла копии не совпал: " + expected.Name);
        }
        return manifest;
    }

    public static IReadOnlyList<(DeviceBackupManifest Manifest,string Path,long Bytes)> List(string storageRoot)
    {
        var root = Path.Combine(storageRoot,"DeviceBackups");
        if (!Directory.Exists(root)) return [];
        var result = new List<(DeviceBackupManifest,string,long)>();
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var id = Path.GetFileName(directory);
            if (!Guid.TryParseExact(id,"D",out _)) continue;
            try
            {
                var path = Path.Combine(directory,"manifest.json");
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0 ||
                    (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) continue;
                var manifest = JsonSerializer.Deserialize<DeviceBackupManifest>(File.ReadAllText(path));
                if (manifest is not { Schema: 1, Complete: true } || manifest.Id != id ||
                    manifest.Files.Length != Files.Length) continue;
                result.Add((manifest,directory,manifest.Files.Sum(f => f.Bytes)));
            }
            catch { /* damaged entries are hidden until manual inspection */ }
        }
        return result.OrderByDescending(x => x.Item1.CreatedAt).ToArray();
    }
}
