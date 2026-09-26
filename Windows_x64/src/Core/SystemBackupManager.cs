using System.Globalization;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows.Core;

public sealed record SystemBackupDevice(string Name, string Source, long Bytes,
    long? Sectors, long? LogicalSectorBytes, long? PhysicalSectorBytes)
{
    public string FileName => Name + ".bin";
}
public sealed record SystemBackupPartition(string Device, string Name, int Number,
    long StartSector, long Sectors);
public sealed record SystemBackupInventory(int Schema, string Cid, string BootID,
    string FirmwareHash, string LayoutHash, long DiskBytes, bool Offline,
    string OfflineReason, string Capture, SystemBackupDevice[] Devices,
    SystemBackupPartition[] Partitions);
public sealed record SystemBackupFile(string Name, string Source, long Bytes, string Sha256);
public sealed record SystemBackupChunk(string Target, long Offset, long Bytes, string Sha256);
public sealed record SystemBackupManifest(int Schema, string Id, DateTimeOffset Created,
    SystemBackupInventory Inventory, string Capture, SystemBackupFile[] Files,
    SystemBackupChunk[] Chunks, bool Complete, string Scope, string Limitations);
public sealed record SystemBackupItem(string Id, string Path, long Bytes, string Capture,
    DateTimeOffset Created);

/// <summary>
/// Read-only full eMMC capture on verified B31. Images are streamed to disk and
/// independently rehashed before publishing. This class has no raw restore API.
/// Live captures are not atomic and RPMB/OTP are outside the eMMC image.
/// </summary>
public sealed class SystemBackupManager(SshTransport ssh, DeviceFeatureService features,
    string storageRoot)
{
    public const long MaximumBytes = 16L * 1024 * 1024 * 1024;
    public const int ChunkBytes = 8 * 1024 * 1024;
    private const long ReserveBytes = 64L * 1024 * 1024;
    private const string HelperHash = "24580a6e05567db9b98d20efd54b87a7b4a7fee2a240be793c0629f1305bd53c";
    private static readonly string[] Names = ["mmcblk0", "mmcblk0boot0", "mmcblk0boot1"];
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };
    private static readonly Regex ErrorPattern = new(@"(?:^|\n)BACKUP_ERROR ([A-Z][A-Z0-9_]{0,79})(?:\r?\n|$)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex ReceiptPattern = new(@"^BACKUP_RESULT sha256=([0-9a-f]{64}) bytes=([1-9][0-9]*)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private string Root => Path.Combine(storageRoot, "SystemBackups");

    public async Task<SystemBackupItem> CreateAsync(CancellationToken ct = default)
    {
        Directory.CreateDirectory(Root);
        SecureDirectory(Root);
        var id = Guid.NewGuid().ToString("D");
        var partial = Path.Combine(Root, ".partial-" + id);
        var final = Path.Combine(Root, id);
        if (File.Exists(partial) || Directory.Exists(partial) ||
            File.Exists(final) || Directory.Exists(final))
            throw new IOException("Имя полной копии уже занято.");
        Directory.CreateDirectory(partial);
        SecureDirectory(partial);
        try
        {
            var manifest = await features.MutateAsync(async (identity, token) =>
            {
                var script = await features.ResourceAsync("SystemBackups", "device.sh", ct)
                    .ConfigureAwait(false);
                if (Convert.ToHexStringLower(SHA256.HashData(script)) != HelperHash)
                    throw new InvalidDataException("Повреждён встроенный инструмент полной копии.");
                var stage = await features.StageAsync("zte-system-backup",
                    new Dictionary<string, byte[]> { ["device.sh"] = script }, ct).ConfigureAwait(false);
                var captureInFlight = false;
                try
                {
                    var first = await ReadInventoryAsync(stage, identity.Cid, token, ct)
                        .ConfigureAwait(false);
                    if (first.Cid != identity.Cid || first.BootID != identity.BootId ||
                        first.FirmwareHash != identity.FirmwareHash || first.Offline)
                        throw new InvalidDataException("Полная копия работающего модема требует подтверждённую B31 и ту же загрузку.");
                    var total = first.Devices.Sum(d => d.Bytes);
                    var free = new DriveInfo(Path.GetPathRoot(partial)!).AvailableFreeSpace;
                    if (free < checked(total + ReserveBytes))
                        throw new IOException("Недостаточно места для полного образа eMMC и запаса 64 МиБ.");
                    var files = new List<SystemBackupFile>();
                    var chunks = new List<SystemBackupChunk>();
                    foreach (var device in first.Devices)
                    {
                        ct.ThrowIfCancellationRequested();
                        var command = ScriptCommand(stage, ["capture", first.Cid, token, device.Name]);
                        var path = Path.Combine(partial, device.FileName);
                        captureInFlight = true;
                        var stream = await ssh.RunToFileAsync(command, path, device.Bytes,
                            TimeSpan.FromHours(2), ct).ConfigureAwait(false);
                        captureInFlight = false;
                        if (!stream.Success)
                            throw new IOException(device.Name + ": " + SafeFailure(stream.Stderr));
                        var receipt = ParseReceipt(stream.Stderr);
                        var checkedFile = await InspectImageAsync(path, device, ct).ConfigureAwait(false);
                        if (stream.Bytes != device.Bytes || stream.Bytes != receipt.Bytes ||
                            stream.Bytes != checkedFile.Bytes || stream.Sha256 != receipt.Sha256 ||
                            stream.Sha256 != checkedFile.Sha256)
                            throw new InvalidDataException("Размер или SHA256 полного образа не совпал: " + device.Name);
                        files.Add(new SystemBackupFile(device.FileName, device.Source,
                            device.Bytes, checkedFile.Sha256));
                        chunks.AddRange(checkedFile.Chunks);
                    }
                    var after = await ReadInventoryAsync(stage, first.Cid, token, ct)
                        .ConfigureAwait(false);
                    if (!SameDevice(first, after) || first.BootID != after.BootID ||
                        first.Offline != after.Offline)
                        throw new InvalidDataException("Во время копирования изменилось устройство, разметка или загрузка.");
                    await features.VerifyIdentityAsync(identity, ct).ConfigureAwait(false);
                    return new SystemBackupManifest(1, id, DateTimeOffset.UtcNow, first,
                        "live-non-atomic", files.ToArray(), chunks.ToArray(), true,
                        "Полный образ пользовательской области eMMC, включая GPT, разделы и промежутки, и boot0/boot1. RPMB и OTP не включены.",
                        "Снимок работающего модема не атомарен: согласованность разделов и файлов не гарантируется. Копия не зашифрована. Автоматическое восстановление разделов отсутствует.");
                }
                finally
                {
                    // A disconnected SSH command may still be reading the
                    // block device. Leave its private stage intact until it
                    // exits; never remove work files under a live helper.
                    if (!captureInFlight) await CleanupStageAsync(stage).ConfigureAwait(false);
                }
            }, ct).ConfigureAwait(false);

            var manifestPath = Path.Combine(partial, "manifest.json");
            await using (var output = new FileStream(manifestPath, FileMode.CreateNew,
                FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(output, manifest, Json, ct).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }
            await VerifyPathAsync(partial, id, ct).ConfigureAwait(false);
            Directory.Move(partial, final);
            return new SystemBackupItem(id, final, manifest.Inventory.Devices.Sum(d => d.Bytes),
                manifest.Capture, manifest.Created);
        }
        catch
        {
            try { Directory.Delete(partial, recursive: true); }
            catch { /* Remains visibly incomplete, never published as a backup. */ }
            throw;
        }
    }

    public Task<SystemBackupManifest> VerifyAsync(string id, CancellationToken ct = default) =>
        VerifyStoredAsync(storageRoot, id, ct);

    public static Task<SystemBackupManifest> VerifyStoredAsync(string storageRoot,
        string id, CancellationToken ct = default)
    {
        if (!Guid.TryParseExact(id, "D", out _) || id != id.ToLowerInvariant())
            throw new ArgumentException("Неверный ID полной копии.", nameof(id));
        return VerifyPathAsync(Path.Combine(storageRoot, "SystemBackups", id), id, ct);
    }

    /// <summary>
    /// Fast local listing: validates manifest shape, exact file names, sizes,
    /// and link-free paths. Call VerifyAsync for SHA256 of every image/chunk.
    /// </summary>
    public static IReadOnlyList<SystemBackupItem> List(string storageRoot)
    {
        var root = Path.Combine(storageRoot, "SystemBackups");
        if (!Directory.Exists(root)) return [];
        CheckDirectory(root);
        var result = new List<SystemBackupItem>();
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var id = Path.GetFileName(directory);
            if (!Guid.TryParseExact(id, "D", out _) || id != id.ToLowerInvariant()) continue;
            try
            {
                var manifest = ReadManifestMetadata(directory, id);
                result.Add(new SystemBackupItem(id, directory,
                    manifest.Inventory.Devices.Sum(d => d.Bytes), manifest.Capture, manifest.Created));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or OverflowException)
            { /* Damaged or incomplete entries are hidden until manual inspection. */ }
        }
        return result.OrderByDescending(item => item.Created).ToArray();
    }

    private async Task<SystemBackupInventory> ReadInventoryAsync(string stage, string cid,
        string token, CancellationToken ct)
    {
        var reply = await ssh.RunAsync(ScriptCommand(stage, ["inventory", cid, token]),
            timeout: TimeSpan.FromSeconds(60), ct: ct).ConfigureAwait(false);
        if (!reply.Success)
            throw new IOException("Не удалось прочитать геометрию eMMC: " + SafeFailure(reply.Stderr));
        if (reply.Stdout.Length > 131072)
            throw new InvalidDataException("Слишком большой ответ геометрии eMMC.");
        SystemBackupInventory inventory;
        try { inventory = JsonSerializer.Deserialize<SystemBackupInventory>(reply.Stdout, Json)!; }
        catch (JsonException error) { throw new InvalidDataException("Неверный ответ геометрии eMMC.", error); }
        ValidateInventory(inventory);
        if (inventory.Cid != cid)
            throw new InvalidDataException("SSH подключён к другому eMMC.");
        return inventory;
    }

    private static string ScriptCommand(string stage, IReadOnlyList<string> arguments)
    {
        var file = stage + "/device.sh";
        return "set -eu; test -f " + Quote(file) + "; test ! -L " + Quote(file) +
            "; test \"$(sha256sum " + Quote(file) + " | cut -d ' ' -f1)\" = " +
            Quote(HelperHash) + "; sh " + Quote(file) + " " +
            string.Join(' ', arguments.Select(Quote));
    }

    private async Task CleanupStageAsync(string stage)
    {
        if (!Regex.IsMatch(stage, @"^/tmp/zte-system-backup-[0-9a-f-]{36}$",
            RegexOptions.CultureInvariant)) return;
        // The helper creates a private work directory, so StageAsync's simple
        // rmdir cleanup is insufficient. The path is a fresh UUID under /tmp.
        try
        {
            await ssh.RunAsync("test -d " + Quote(stage) + "; test ! -L " + Quote(stage) +
                "; test \"$(stat -c %u:%a " + Quote(stage) + ")\" = 0:700; rm -rf " + Quote(stage),
                timeout: TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        }
        catch { /* A failed capture keeps only a private temporary stage. */ }
    }

    private static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
    private static bool ValidHash(string? value) => value is { Length: 64 } &&
        value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static bool ValidCid(string? value) => value is { Length: 32 } &&
        value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    public static void ValidateInventory(SystemBackupInventory value)
    {
        if (value is null || value.Schema != 1 || !ValidCid(value.Cid) ||
            !Guid.TryParseExact(value.BootID, "D", out _) || !ValidHash(value.LayoutHash) ||
            value.FirmwareHash != ImeiEngine.FirmwareHash ||
            value.OfflineReason is null || value.OfflineReason.Length > 4096 ||
            value.Capture != (value.Offline ? "offline" : "live-non-atomic") ||
            value.Devices is null || value.Devices.Length != Names.Length ||
            value.Partitions is null || value.Partitions.Length is < 1 or > 512)
            throw new InvalidDataException("Неверная геометрия полной копии eMMC.");
        long total = 0;
        for (var index = 0; index < Names.Length; index++)
        {
            var device = value.Devices[index];
            if (device is null || device.Name != Names[index] ||
                device.Source != "/dev/" + device.Name ||
                device.Bytes is <= 0 or > MaximumBytes || device.Bytes % 512 != 0 ||
                device.Sectors != device.Bytes / 512 ||
                device.LogicalSectorBytes is not (512 or 4096) ||
                device.PhysicalSectorBytes is not (512 or 4096) ||
                device.Bytes % device.LogicalSectorBytes.Value != 0)
                throw new InvalidDataException("Неверное описание области eMMC: " + Names[index]);
            total = checked(total + device.Bytes);
        }
        if (value.DiskBytes != value.Devices[0].Bytes || total > MaximumBytes)
            throw new InvalidDataException("Неверный общий размер eMMC.");
        var numbers = new HashSet<int>();
        foreach (var part in value.Partitions)
        {
            if (part is null || part.Number <= 0 || !numbers.Add(part.Number) ||
                part.Device != "mmcblk0p" + part.Number ||
                part.Name is not { Length: > 0 and <= 64 } ||
                part.Name.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'z' or >= 'A' and <= 'Z' or '_' or ':' or '-')) ||
                part.StartSector < 0 || part.Sectors <= 0 ||
                part.StartSector >= value.DiskBytes / 512 ||
                part.Sectors > value.DiskBytes / 512 - part.StartSector)
                throw new InvalidDataException("Неверная таблица разделов eMMC.");
        }
    }

    private static bool SameDevice(SystemBackupInventory first, SystemBackupInventory second) =>
        first.Cid == second.Cid && first.LayoutHash == second.LayoutHash &&
        first.DiskBytes == second.DiskBytes && first.Devices.SequenceEqual(second.Devices) &&
        first.Partitions.SequenceEqual(second.Partitions);

    private static (string Sha256, long Bytes) ParseReceipt(byte[] stderr)
    {
        if (stderr.Length > 1024 * 1024)
            throw new InvalidDataException("Слишком большой ответ копирования eMMC.");
        var found = Encoding.UTF8.GetString(stderr).Split('\n', StringSplitOptions.TrimEntries)
            .Where(line => line.StartsWith("BACKUP_RESULT ", StringComparison.Ordinal)).ToArray();
        if (found.Length != 1)
            throw new InvalidDataException("Модем не подтвердил SHA256 полного образа.");
        var match = ReceiptPattern.Match(found[0]);
        if (!match.Success || !long.TryParse(match.Groups[2].Value, NumberStyles.None,
                CultureInfo.InvariantCulture, out var bytes) || bytes is <= 0 or > MaximumBytes)
            throw new InvalidDataException("Неверный размер или SHA256 подтверждения модема.");
        return (match.Groups[1].Value, bytes);
    }

    private static string SafeFailure(byte[] stderr)
    {
        var text = Encoding.UTF8.GetString(stderr.AsSpan(0, Math.Min(stderr.Length, 16 * 1024)));
        var code = ErrorPattern.Match(text);
        return code.Success ? "BACKUP_ERROR " + code.Groups[1].Value :
            "модем остановил чтение; неполная копия удалена";
    }

    private static async Task<(long Bytes, string Sha256, List<SystemBackupChunk> Chunks)> InspectImageAsync(
        string path, SystemBackupDevice device, CancellationToken ct)
    {
        CheckRegularFile(path);
        if (new FileInfo(path).Length != device.Bytes)
            throw new InvalidDataException("Образ eMMC имеет неверный размер: " + device.Name);
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.Read, ChunkBytes, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var chunks = new List<SystemBackupChunk>();
        var buffer = new byte[ChunkBytes];
        long offset = 0;
        while (offset < device.Bytes)
        {
            var length = (int)Math.Min(ChunkBytes, device.Bytes - offset);
            await input.ReadExactlyAsync(buffer.AsMemory(0, length), ct).ConfigureAwait(false);
            hash.AppendData(buffer, 0, length);
            chunks.Add(new SystemBackupChunk(device.Name, offset, length,
                Convert.ToHexStringLower(SHA256.HashData(buffer.AsSpan(0, length)))));
            offset += length;
        }
        if (input.ReadByte() != -1)
            throw new InvalidDataException("Образ eMMC содержит лишние данные.");
        return (offset, Convert.ToHexStringLower(hash.GetHashAndReset()), chunks);
    }

    private static async Task<SystemBackupManifest> VerifyPathAsync(string directory,
        string id, CancellationToken ct)
    {
        var value = ReadManifestMetadata(directory, id);
        var chunks = new List<SystemBackupChunk>();
        for (var index = 0; index < Names.Length; index++)
        {
            var device = value.Inventory.Devices[index];
            var file = value.Files[index];
            var checkedFile = await InspectImageAsync(Path.Combine(directory, file.Name), device, ct)
                .ConfigureAwait(false);
            if (checkedFile.Bytes != file.Bytes || checkedFile.Sha256 != file.Sha256)
                throw new InvalidDataException("SHA256 образа не совпал: " + device.Name);
            chunks.AddRange(checkedFile.Chunks);
        }
        if (!chunks.SequenceEqual(value.Chunks))
            throw new InvalidDataException("SHA256 блоков полного образа не совпали.");
        return value;
    }

    private static SystemBackupManifest ReadManifestMetadata(string directory, string id)
    {
        CheckDirectory(directory);
        var manifestPath = Path.Combine(directory, "manifest.json");
        CheckRegularFile(manifestPath);
        if (new FileInfo(manifestPath).Length is < 1 or > 4 * 1024 * 1024)
            throw new InvalidDataException("Манифест полной копии повреждён.");
        SystemBackupManifest value;
        try { value = JsonSerializer.Deserialize<SystemBackupManifest>(
            File.ReadAllBytes(manifestPath), Json)!; }
        catch (JsonException error) { throw new InvalidDataException("Неверный манифест полной копии.", error); }
        if (value is null || value.Schema != 1 || !value.Complete || value.Id != id ||
            value.Created == default || value.Inventory is null || value.Files is null ||
            value.Chunks is null || value.Scope is null || value.Limitations is null ||
            value.Scope.Length > 4096 || value.Limitations.Length > 8192)
            throw new InvalidDataException("Неверный манифест полной копии.");
        ValidateInventory(value.Inventory);
        if (value.Capture != (value.Inventory.Offline ? "offline" : "live-non-atomic") ||
            value.Files.Length != Names.Length ||
            !Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName)
                .ToHashSet(StringComparer.Ordinal).SetEquals(Names.Select(n => n + ".bin").Append("manifest.json")))
            throw new InvalidDataException("Неверный состав файлов полной копии.");
        var chunkIndex = 0;
        for (var index = 0; index < Names.Length; index++)
        {
            var device = value.Inventory.Devices[index];
            var file = value.Files[index];
            if (file is null || file.Name != device.FileName || file.Source != device.Source ||
                file.Bytes != device.Bytes || !ValidHash(file.Sha256))
                throw new InvalidDataException("Неверное описание образа: " + device.Name);
            var imagePath = Path.Combine(directory, file.Name);
            CheckRegularFile(imagePath);
            if (new FileInfo(imagePath).Length != file.Bytes)
                throw new InvalidDataException("Размер образа не совпал: " + device.Name);
            long offset = 0;
            while (offset < device.Bytes)
            {
                var length = Math.Min(ChunkBytes, device.Bytes - offset);
                if (chunkIndex >= value.Chunks.Length || value.Chunks[chunkIndex] is not { } chunk ||
                    chunk.Target != device.Name || chunk.Offset != offset ||
                    chunk.Bytes != length || !ValidHash(chunk.Sha256))
                    throw new InvalidDataException("Неверное описание блоков полного образа.");
                offset += length;
                chunkIndex++;
            }
        }
        if (chunkIndex != value.Chunks.Length)
            throw new InvalidDataException("Лишние блоки в манифесте полной копии.");
        return value;
    }

    private static void CheckDirectory(string path)
    {
        if (!Directory.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Каталог полной копии отсутствует или является ссылкой.");
    }

    private static void CheckRegularFile(string path)
    {
        if (!File.Exists(path) || (File.GetAttributes(path) &
            (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new InvalidDataException("Файл полной копии отсутствует или является ссылкой.");
    }

    private static void SecureDirectory(string path)
    {
        CheckDirectory(path);
        if (OperatingSystem.IsWindows()) ProtectWindowsDirectory(path);
    }

    [SupportedOSPlatform("windows")]
    private static void ProtectWindowsDirectory(string path)
    {
        var user = WindowsIdentity.GetCurrent().User ??
            throw new IOException("Не удалось определить пользователя Windows для приватного бэкапа.");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None, AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(path), security);
    }
}
