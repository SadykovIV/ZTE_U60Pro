using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Features;

public sealed record DeviceIdentity(string Cid, string BootId, string FirmwareHash, string RouterHash);

public sealed class DeviceFeatureException(string message) : Exception(message);

/// <summary>
/// Shared guards for the device-owned feature managers. The SHA pins and device
/// lock are the same ones used by the Mac application and its on-device scripts.
/// </summary>
public sealed partial class DeviceFeatureService
{
    internal const string FirmwareHash = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
    internal const string RouterHash = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f";
    internal const string LockPath = "/tmp/zte-imei-app.lock";
    private static readonly SemaphoreSlim OperationGate = new(1, 1);
    private static readonly Regex HashPattern = new("^[0-9a-f]{64}$", RegexOptions.Compiled);
    private static readonly Regex CidPattern = new("^[0-9a-f]{32}$", RegexOptions.Compiled);
    private readonly IRemoteShell _shell;
    private readonly string _resourcesRoot;
    private readonly string _storageRoot;
    internal string? CompletedCoreReplacementId { get; set; }

    public DeviceFeatureService(IRemoteShell shell, string? resourcesRoot = null, string? storageRoot = null, bool skipFirmwareCheck = false)
    {
        _shell = shell ?? throw new ArgumentNullException(nameof(shell));
        _resourcesRoot = resourcesRoot ?? Path.Combine(AppContext.BaseDirectory, "Resources");
        _storageRoot = storageRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZTE IMEI Studio");
    }

    private void CheckLocalPending()
    {
        var replacement = Path.Combine(_storageRoot, "core-replacement-pending.json");
        if (File.Exists(replacement) || Directory.Exists(replacement))
        {
            Check(File.Exists(replacement) && (File.GetAttributes(replacement) & FileAttributes.ReparsePoint) == 0 && new FileInfo(replacement).Length is > 0 and <= 65536,
                "Повреждён журнал замены основных компонентов.");
            using var document = JsonDocument.Parse(File.ReadAllBytes(replacement));
            Check(document.RootElement.TryGetProperty("Phase", out var phase) && phase.GetString() == "complete" &&
                document.RootElement.TryGetProperty("Id", out var id) && CompletedCoreReplacementId is not null && id.GetString() == CompletedCoreReplacementId,
                "Сначала продолжите подготовку модема или установку агента.");
        }
        var cleanup = Path.Combine(_storageRoot, "component-cleanup-pending.json");
        Check(!File.Exists(cleanup) && !Directory.Exists(cleanup), "Сначала завершите очистку компонентов программы в подготовке модема.");
        foreach (var name in new[] { "adb-access-pending.json", AdbToggleTransaction.PendingName, "system-restore-pending.json" })
        {
            var path = Path.Combine(_storageRoot, name);
            Check(!File.Exists(path) && !Directory.Exists(path),
                "Сначала завершите незавершённую операцию модема: " + name);
        }
    }

    internal static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
    internal static string Sha(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
    internal static string Text(byte[] data) => Encoding.UTF8.GetString(data).TrimEnd('\r', '\n');
    internal static void Check(bool condition, string message)
    {
        if (!condition) throw new DeviceFeatureException(message);
    }

    internal async Task<RemoteResult> RunAsync(string command, byte[]? stdin = null, int seconds = 30, CancellationToken ct = default)
    {
        var result = await _shell.RunAsync(command, stdin, TimeSpan.FromSeconds(seconds), ct);
        if (!result.Success)
        {
            var reason = Text(result.Stderr);
            throw new DeviceFeatureException($"Команда модема завершилась с кодом {result.ExitCode}: {reason[..Math.Min(reason.Length, 450)]}");
        }
        return result;
    }

    internal async Task<string> RunTextAsync(string command, byte[]? stdin = null, int seconds = 30, CancellationToken ct = default)
        => Text((await RunAsync(command, stdin, seconds, ct)).Stdout);

    public async Task<DeviceIdentity> ReadIdentityAsync(bool requireSupportedFirmware = false, CancellationToken ct = default)
    {
        // Access identity also represents an absent modem.b16 (for example HK B04).
        // Feature managers validate their own files and ABI before mutation.
        var measured = await Core.AccessIdentity.ReadAsync(_shell, ct);
        return new DeviceIdentity(measured.Cid, measured.BootId, measured.FirmwareHash, measured.RouterHash);
    }

    internal async Task VerifyIdentityAsync(DeviceIdentity expected, CancellationToken ct)
        => Check(await ReadIdentityAsync(ct: ct) == expected, "Модем или его загрузка изменились во время операции. Обновите состояние.");

    private async Task<DeviceIdentity> ReadAgentIdentityAsync(CancellationToken ct)
    {
        var proof = await Core.AccessIdentity.ReadAsync(_shell, ct);
        return new DeviceIdentity(proof.Cid, proof.BootId, proof.FirmwareHash, proof.RouterHash);
    }

    internal async Task<T> MutateAsync<T>(Func<DeviceIdentity, string, Task<T>> work, CancellationToken ct, bool measuredAgentPlatform = false)
    {
        await OperationGate.WaitAsync(ct);
        string? token = null;
        FileStream? localOperation = null;
        try
        {
            Directory.CreateDirectory(_storageRoot);
            localOperation = new FileStream(Path.Combine(_storageRoot,"operation.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
            CheckLocalPending();
            var identity = measuredAgentPlatform ? await ReadAgentIdentityAsync(ct) : await ReadIdentityAsync(requireSupportedFirmware: true, ct);
            token = Guid.NewGuid().ToString("D");
            await RunAsync("set -eu; umask 077; test ! -L /tmp; mkdir " + LockPath + "; printf '%s' " + Quote(token) + " > " + LockPath + "/owner", ct: ct);
            CheckLocalPending();
            var result = await work(identity, token);
            if (measuredAgentPlatform) Check(identity == await ReadAgentIdentityAsync(ct), "Устройство изменилось во время операции с агентом.");
            else await VerifyIdentityAsync(identity, ct);
            return result;
        }
        finally
        {
            if (token != null)
            {
                try
                {
                    await RunAsync("set -eu; test -d " + LockPath + " && test ! -L " + LockPath + " && test \"$(cat " + LockPath + "/owner)\" = " + Quote(token) + " && rm " + LockPath + "/owner && rmdir " + LockPath, seconds: 10, ct: CancellationToken.None);
                }
                catch { /* A changed lock must remain for recovery inspection. */ }
            }
            localOperation?.Dispose();
            OperationGate.Release();
        }
    }

    internal static string Guard(DeviceIdentity identity, string token) =>
        "set -eu; test -d " + LockPath + " && test ! -L " + LockPath +
        "; test \"$(cat " + LockPath + "/owner)\" = " + Quote(token) +
        "; test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + Quote(identity.Cid) +
        "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + Quote(identity.BootId) + "; ";

    internal async Task<byte[]> ResourceAsync(string category, string name, CancellationToken ct = default)
    {
        Check(!category.Contains("..") && !name.Contains('/') && !name.Contains('\\') && !name.Contains(".."), "Недопустимое имя компонента.");
        var manifestFile = Path.Combine(_resourcesRoot, category, "SHA256.json");
        var manifest = JsonSerializer.Deserialize<Dictionary<string, string>>(await File.ReadAllBytesAsync(manifestFile, ct));
        Check(manifest != null && manifest.ContainsKey(name) && HashPattern.IsMatch(manifest[name]), "Компонент отсутствует в манифесте: " + name);
        var expected = manifest![name];
        var bytes = await File.ReadAllBytesAsync(Path.Combine(_resourcesRoot, category, name), ct);
        Check(bytes.Length > 0 && Sha(bytes) == expected, "Контрольная сумма компонента не совпадает: " + name);
        return bytes;
    }

    internal async Task<string> StageAsync(string prefix, IReadOnlyDictionary<string, byte[]> files, CancellationToken ct)
    {
        Check(Regex.IsMatch(prefix, "^[a-z0-9-]+$"), "Некорректный каталог передачи.");
        var stage = "/tmp/" + prefix + "-" + Guid.NewGuid().ToString("D");
        await RunAsync("set -eu; umask 077; test ! -L /tmp; mkdir -m 700 " + Quote(stage), ct: ct);
        try
        {
            foreach (var (name, bytes) in files)
            {
                Check(Regex.IsMatch(name, "^[A-Za-z0-9._-]+$"), "Недопустимое имя компонента.");
                var path = stage + "/" + name;
                var mode = name is "zte-timeout" or "ssclash-linux-arm64" ? "700" : "600";
                var output = await RunTextAsync("set -eu; umask 077; test ! -e " + Quote(path) + "; cat > " + Quote(path) + "; chmod " + mode + " " + Quote(path) + "; sha256sum " + Quote(path), bytes, 180, ct);
                Check(output.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() == Sha(bytes), "Переданный компонент повреждён: " + name);
            }
            return stage;
        }
        catch
        {
            await CleanupStageAsync(stage, files.Keys, CancellationToken.None);
            throw;
        }
    }

    internal async Task CleanupStageAsync(string stage, IEnumerable<string> names, CancellationToken ct)
    {
        var files = names.Select(name => Quote(stage + "/" + name));
        try
        {
            await RunAsync("set -eu; test -d " + Quote(stage) + " && test ! -L " + Quote(stage) + "; rm -f " + string.Join(" ", files) + "; rmdir " + Quote(stage), seconds: 15, ct: ct);
        }
        catch { /* A failed operation leaves only its private, named staging folder. */ }
    }

    internal async Task<Dictionary<string, byte[]>> LoadResourcesAsync(string category, IEnumerable<string> names, CancellationToken ct)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var name in names) files.Add(name, await ResourceAsync(category, name, ct));
        return files;
    }

    internal static string? StringProperty(JsonElement value, string name)
        => value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    internal static bool BoolProperty(JsonElement value, string name)
        => value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.True;
}
