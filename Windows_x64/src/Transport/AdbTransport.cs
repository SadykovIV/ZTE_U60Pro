using System.Buffers;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Transport;

public sealed record AdbDevice(string Serial, string UsbDescriptor);
public sealed record AdbDeviceState(string Serial, string State, string? UsbDescriptor);
public sealed record AdbUsbInventory(IReadOnlyList<AdbDevice> ReadyDevices,
    IReadOnlyList<AdbDeviceState> ObservedDevices)
{
    public string UnavailableReason => ObservedDevices.Any(d => d.State == "unauthorized")
        ? "ADB видит устройство, но доступ не разрешён (unauthorized). Подтвердите отладку на модеме, если он показывает запрос."
        : ObservedDevices.Any(d => d.State == "offline")
        ? "ADB видит устройство в состоянии offline. Переподключите USB-кабель и повторите проверку."
        : ObservedDevices.Any(d => d.State == "no permissions")
        ? "ADB видит USB-устройство, но у компьютера нет разрешения на доступ."
        : ObservedDevices.Any(d => d.State == "device")
        ? "ADB видит устройство, но не подтвердил единственное USB-подключение. Оставьте подключённым только нужный модем."
        : "USB ADB не обнаружен. Проверьте кабель данных и драйвер Android ADB в диспетчере устройств Windows.";
}

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
    private readonly Func<IReadOnlyList<string>, TimeSpan?, CancellationToken, Task<RemoteResult>>? _runner;
    private readonly Func<IReadOnlyList<string>, AdbStreamRequest?, TimeSpan?, CancellationToken, Task<RemoteResult>>? _inputRunner;
    private readonly string? _streamTemplatePath;

    internal AdbTransport(Func<IReadOnlyList<string>, TimeSpan?, CancellationToken, Task<RemoteResult>> runner)
        : this() => _runner = runner;

    internal AdbTransport(Func<IReadOnlyList<string>, AdbStreamRequest?, TimeSpan?, CancellationToken, Task<RemoteResult>> runner, string templatePath)
        : this() { _inputRunner=runner; _streamTemplatePath=templatePath; }

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
        if (arguments.Count is < 1 or > 64 || arguments.Any(a => a is null || a.IndexOf('\0') >= 0 || a.Length > 128 * 1024))
            throw new ArgumentException("Недопустимые аргументы ADB.", nameof(arguments));
        if (_runner is not null) return await _runner(arguments, timeout, ct).ConfigureAwait(false);
        if (_inputRunner is not null) return await _inputRunner(arguments, null, timeout, ct).ConfigureAwait(false);
        if (!File.Exists(ExecutablePath))
            throw new FileNotFoundException("В комплекте отсутствует Windows adb.exe.", ExecutablePath);

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
        => (await InspectUsbAsync(ct).ConfigureAwait(false)).ReadyDevices;

    public async Task<AdbUsbInventory> InspectUsbAsync(CancellationToken ct = default)
    {
        var result = await RunAsync(["devices", "-l"], TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
        if (!result.Success) throw new IOException("ADB не смог получить список USB-устройств.");
        if (result.Stdout.Length > 64 * 1024) throw new InvalidDataException("Список ADB слишком велик.");
        var observed = ParseDeviceList(Encoding.UTF8.GetString(result.Stdout));
        var devices = observed.Where(d => d.State == "device" && d.UsbDescriptor is not null)
            .Select(d => new AdbDevice(d.Serial, d.UsbDescriptor!)).ToList();
        // Windows adb devices -l commonly omits usb:. A successful -d proof
        // establishes the transport without accepting a TCP device or emulator.
        if (observed.Any(d => d.State == "device" && d.UsbDescriptor is null))
        {
            var proof = await RunAsync(["-d", "get-serialno"], TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);
            if (proof.Success && proof.Stdout.Length <= 1024)
            {
                var serial = Encoding.UTF8.GetString(proof.Stdout).Trim();
                var candidate = observed.SingleOrDefault(d => d.Serial == serial && d.State == "device");
                if (candidate is not null && devices.All(d => d.Serial != serial))
                    devices.Add(new AdbDevice(serial, "usb:confirmed-by-adb-d"));
            }
        }
        return new AdbUsbInventory(devices, observed);
    }

    public static IReadOnlyList<AdbDeviceState> ParseDeviceList(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > 64 * 1024) throw new InvalidDataException("Список ADB слишком велик.");
        var devices = new List<AdbDeviceState>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in text.Split('\n'))
        {
            var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2) continue;
            var state = fields[1] == "no" && fields.Length > 2 && fields[2] == "permissions" ? "no permissions" : fields[1];
            if (state is not ("device" or "offline" or "unauthorized" or "no permissions")) continue;
            if (!Regex.IsMatch(fields[0], @"^[A-Za-z0-9._-]{1,256}$", RegexOptions.CultureInvariant) ||
                fields[0].StartsWith("emulator-", StringComparison.Ordinal) ||
                fields[0].Contains("_adb-", StringComparison.Ordinal) || fields[0].Contains("_tcp", StringComparison.Ordinal)) continue;
            if (!seen.Add(fields[0])) throw new InvalidDataException("ADB вернул повторяющийся serial.");
            var descriptors = fields.Where(f => f.StartsWith("usb:", StringComparison.Ordinal)).ToArray();
            if (descriptors.Length > 1 || descriptors.Any(d => !UsbDescriptorPattern.IsMatch(d)))
                throw new InvalidDataException("ADB вернул неоднозначное описание USB.");
            devices.Add(new AdbDeviceState(fields[0], state, descriptors.SingleOrDefault()));
        }
        return devices;
    }

    public async Task<string> SelectSingleUsbSerialAsync(CancellationToken ct = default)
    {
        var inventory = await InspectUsbAsync(ct).ConfigureAwait(false);
        var devices = inventory.ReadyDevices;
        return devices.Count switch
        {
            1 => devices[0].Serial,
            0 => throw new InvalidOperationException(inventory.UnavailableReason),
            _ => throw new InvalidOperationException("Подключено несколько USB ADB-устройств: укажите serial после сверки модема."),
        };
    }

    public async Task<RemoteResult> ShellAsync(string serial, string command,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ValidateSerial(serial);
        AdbStreamProtocol.Validate(command);
        var marker = "__ZTE_RESULT_" + Guid.NewGuid().ToString("N").ToUpperInvariant() + "__";
        var remote = "(" + command + "); zte_code=$?; printf '\\n" + marker +
            "%s\\n' \"$zte_code\"";
        if(Encoding.UTF8.GetByteCount(remote)>AdbStreamProtocol.InlineLimit)
        {
            var request=AdbStreamProtocol.Build(command,_streamTemplatePath??AdbStreamProtocol.TemplatePath(ExecutablePath));
            var arguments=new[]{"-s",serial,"shell",request.Wrapper};
            AdbStreamResult streamed;
            if(_inputRunner is not null)
            {
                var raw=await _inputRunner(arguments,request,timeout,ct).ConfigureAwait(false);
                var capture=new AdbStreamCapture(request,MaximumOutputBytes);
                capture.Stdout(raw.Stdout);capture.Stderr(raw.Stderr);capture.EndStdout();streamed=capture.Finish(raw.ExitCode);
            }
            else
            {
                if(_runner is not null)throw new InvalidOperationException("The injected ADB runner does not support stdin.");
                streamed=await AdbStreamProcess.RunAsync(ExecutablePath,arguments,request,EffectiveTimeout(timeout),MaximumOutputBytes,ct).ConfigureAwait(false);
            }
            if(streamed.Truncated || streamed.ResultOccurrences!=1)throw new InvalidDataException("Результат потоковой команды ADB неполон или неоднозначен.");
            return DecodeShellResult(new(streamed.LocalExitCode,streamed.Stdout,streamed.Stderr),request.Result);
        }
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
        if (!local.Success) throw new IOException("Локальный ADB завершился с ошибкой."+AdbStreamProtocol.KnownLocalError(local.Stderr));
        if (!ResultMarkerPattern.IsMatch(marker))
            throw new ArgumentException("Неверный маркер результата ADB.", nameof(marker));
        if (!AdbShellOutput.TryDecodeCompletion(local.Stdout, marker, out var code, out var outputLength))
            throw new InvalidDataException("ADB не вернул однозначный код удалённой команды.");
        return new RemoteResult(code, local.Stdout[..outputLength], local.Stderr);
    }

    private static void ValidateSerial(string serial)
    {
        if (string.IsNullOrEmpty(serial) || serial.Length > 256 ||
            serial.Any(c => c < 33 || c > 126))
            throw new ArgumentException("Неверный serial USB ADB-устройства.", nameof(serial));
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
