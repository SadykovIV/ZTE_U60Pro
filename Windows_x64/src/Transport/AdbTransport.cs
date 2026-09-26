using System.Buffers;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Transport;

public sealed record AdbDevice(string Serial, string UsbDescriptor);

/// <summary>
/// Runs the bundled Windows adb.exe with ArgumentList, a bounded response,
/// a hard timeout, and an explicit USB serial for every device operation.
/// </summary>
public sealed class AdbTransport
{
    private const int MaximumOutputBytes = 128 * 1024 * 1024;
    private static readonly Regex UsbDescriptorPattern = new(
        @"^usb:[A-Za-z0-9._-]{1,128}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex ResultMarkerPattern = new(
        @"^__ZTE_RESULT_[A-F0-9]{32}__$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public string ExecutablePath { get; }

    public AdbTransport(string? executablePath = null)
    {
        ExecutablePath = executablePath ?? Path.Combine(AppContext.BaseDirectory,
            "Resources", "Tools", "adb.exe");
        if (!Path.IsPathFullyQualified(ExecutablePath))
            throw new ArgumentException("Путь к adb.exe должен быть абсолютным.", nameof(executablePath));
    }

    public async Task<RemoteResult> RunAsync(IReadOnlyList<string> arguments,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        if (!File.Exists(ExecutablePath))
            throw new FileNotFoundException("В комплекте отсутствует Windows adb.exe.", ExecutablePath);
        if (arguments.Count is < 1 or > 64 || arguments.Any(a => a is null || a.IndexOf('\0') >= 0 || a.Length > 128 * 1024))
            throw new ArgumentException("Недопустимые аргументы ADB.", nameof(arguments));

        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(EffectiveTimeout(timeout));
        var start = new ProcessStartInfo(ExecutablePath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new IOException("Не удалось запустить встроенный ADB.");
        process.StandardInput.Close();
        try
        {
            var stdout = ReadBoundedAsync(process.StandardOutput.BaseStream, MaximumOutputBytes, lifetime.Token);
            var stderr = ReadBoundedAsync(process.StandardError.BaseStream, 4 * 1024 * 1024, lifetime.Token);
            await process.WaitForExitAsync(lifetime.Token).ConfigureAwait(false);
            return new RemoteResult(process.ExitCode,
                await stdout.ConfigureAwait(false), await stderr.ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Kill(process);
            throw new TimeoutException("ADB не завершил операцию вовремя. Проверьте состояние модема перед повтором.");
        }
        catch
        {
            Kill(process);
            throw;
        }
    }

    public async Task<IReadOnlyList<AdbDevice>> GetUsbDevicesAsync(CancellationToken ct = default)
    {
        var result = await RunAsync(["devices", "-l"], TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
        if (!result.Success) throw new IOException("ADB не смог получить список USB-устройств.");
        if (result.Stdout.Length > 64 * 1024) throw new InvalidDataException("Список ADB слишком велик.");
        var devices = new List<AdbDevice>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in Encoding.UTF8.GetString(result.Stdout).Split('\n'))
        {
            var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2 || fields[1] != "device") continue;
            ValidateSerial(fields[0]);
            if (!seen.Add(fields[0])) throw new InvalidDataException("ADB вернул повторяющийся serial.");
            var descriptors = fields.Where(f => f.StartsWith("usb:", StringComparison.Ordinal)).ToArray();
            if (descriptors.Length != 1 || !UsbDescriptorPattern.IsMatch(descriptors[0])) continue;
            devices.Add(new AdbDevice(fields[0], descriptors[0]));
        }
        return devices;
    }

    public async Task<string> SelectSingleUsbSerialAsync(CancellationToken ct = default)
    {
        var devices = await GetUsbDevicesAsync(ct).ConfigureAwait(false);
        return devices.Count switch
        {
            1 => devices[0].Serial,
            0 => throw new InvalidOperationException("Нет подключённого и разрешённого USB ADB-модема."),
            _ => throw new InvalidOperationException("Подключено несколько USB ADB-устройств: укажите serial после сверки модема."),
        };
    }

    public async Task<RemoteResult> ShellAsync(string serial, string command,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ValidateSerial(serial);
        if (string.IsNullOrEmpty(command) || command.IndexOf('\0') >= 0 ||
            Encoding.UTF8.GetByteCount(command) > 128 * 1024)
            throw new ArgumentException("Недопустимая команда ADB shell.", nameof(command));
        var marker = "__ZTE_RESULT_" + Guid.NewGuid().ToString("N").ToUpperInvariant() + "__";
        var remote = "(" + command + "); zte_code=$?; printf '\\n" + marker +
            "%s\\n' \"$zte_code\"";
        var local = await RunAsync(["-s", serial, "shell", remote], timeout, ct).ConfigureAwait(false);
        return DecodeShellResult(local, marker);
    }

    public async Task PushAsync(string serial, string localPath, string remotePath,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ValidateSerial(serial);
        if (!Path.IsPathFullyQualified(localPath) || !File.Exists(localPath))
            throw new FileNotFoundException("Файл для передачи по ADB не найден.", localPath);
        ValidateRemotePath(remotePath);
        var result = await RunAsync(["-s", serial, "push", localPath, remotePath],
            timeout ?? TimeSpan.FromMinutes(3), ct).ConfigureAwait(false);
        if (!result.Success) throw new IOException("ADB не передал файл на модем.");
    }

    public static RemoteResult DecodeShellResult(RemoteResult local, string marker)
    {
        if (!local.Success) throw new IOException("Локальный ADB завершился с ошибкой.");
        if (!ResultMarkerPattern.IsMatch(marker))
            throw new ArgumentException("Неверный маркер результата ADB.", nameof(marker));
        var needle = Encoding.ASCII.GetBytes(marker);
        var raw = local.Stdout;
        var offset = raw.AsSpan().IndexOf(needle);
        if (offset < 1 || raw[offset - 1] != (byte)'\n' ||
            raw.AsSpan(offset + needle.Length).IndexOf(needle) >= 0)
            throw new InvalidDataException("ADB не вернул однозначный код удалённой команды.");
        var suffix = raw.AsSpan(offset + needle.Length);
        if (suffix.Length < 2 || suffix[^1] != (byte)'\n')
            throw new InvalidDataException("ADB вернул незавершённый код удалённой команды.");
        suffix = suffix[..^1];
        if (suffix.Length > 0 && suffix[^1] == (byte)'\r') suffix = suffix[..^1];
        if (suffix.Length is < 1 or > 3 || !AsciiDigits(suffix) ||
            !int.TryParse(Encoding.ASCII.GetString(suffix), out var code) ||
            code is < 0 or > 255 || Encoding.ASCII.GetString(suffix) != code.ToString())
            throw new InvalidDataException("ADB вернул неверный удалённый код завершения.");
        var outputEnd = offset - 1;
        if (outputEnd > 0 && raw[outputEnd - 1] == (byte)'\r') outputEnd--;
        return new RemoteResult(code, raw[..outputEnd], local.Stderr);
    }

    private static void ValidateSerial(string serial)
    {
        if (string.IsNullOrEmpty(serial) || serial.Length > 256 ||
            serial.Any(c => c < 33 || c > 126))
            throw new ArgumentException("Неверный serial USB ADB-устройства.", nameof(serial));
    }

    private static bool AsciiDigits(ReadOnlySpan<byte> value)
    {
        foreach (var digit in value)
            if (digit is < (byte)'0' or > (byte)'9') return false;
        return true;
    }

    private static void ValidateRemotePath(string path)
    {
        if (string.IsNullOrEmpty(path) || !path.StartsWith('/') || path.Length > 1024 ||
            path.Any(c => c is '\0' or '\n' or '\r'))
            throw new ArgumentException("Неверный путь на модеме.", nameof(path));
    }

    private static TimeSpan EffectiveTimeout(TimeSpan? value)
    {
        var timeout = value ?? TimeSpan.FromSeconds(30);
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromHours(2))
            throw new ArgumentOutOfRangeException(nameof(value));
        return timeout;
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream source, int limit, CancellationToken ct)
    {
        using var output = new MemoryStream();
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            while (true)
            {
                var count = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), ct).ConfigureAwait(false);
                if (count == 0) return output.ToArray();
                if (count > limit - output.Length)
                    throw new InvalidDataException("Ответ ADB превысил допустимый размер.");
                output.Write(buffer, 0, count);
            }
        }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
    }

    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch { /* The process is already gone. */ }
    }
}
