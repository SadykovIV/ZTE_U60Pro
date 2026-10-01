using System.Buffers;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Renci.SshNet;

namespace ZteImeiStudio.Transport;

public sealed record RemoteResult(int ExitCode, byte[] Stdout, byte[] Stderr)
{
    public bool Success => ExitCode == 0;
}
public sealed record RemoteFileResult(int ExitCode, long Bytes, string Sha256, byte[] Stderr)
{
    public bool Success => ExitCode == 0;
}

public sealed class SshTrustException(string message, Exception innerException)
    : IOException(message, innerException);

public interface IRemoteShell
{
    Task<RemoteResult> RunAsync(string command, byte[]? stdin = null,
        TimeSpan? timeout = null, CancellationToken ct = default);
    Task UploadAsync(string remotePath, byte[] data,
        TimeSpan? timeout = null, CancellationToken ct = default);
    Task<byte[]> DownloadAsync(string remotePath,
        TimeSpan? timeout = null, CancellationToken ct = default);
}

/// <summary>
/// Opens a fresh SSH connection for each operation. The server's exact ed25519
/// public key must already be present in an OpenSSH known_hosts file; this class
/// never learns or replaces a key over the network.
/// </summary>
public sealed partial class SshTransport : IRemoteShell
{
    private const int MaximumCommandBytes = 128 * 1024;
    // SSClash recovery archives are bounded to 256 MiB by the device helper.
    private const int MaximumOutputBytes = 256 * 1024 * 1024;
    private const int MaximumTransferBytes = 128 * 1024 * 1024;
    private readonly string _host;
    private readonly int _port;
    private readonly string _username;
    private readonly string _privateKeyPath;
    private readonly byte[] _pinnedHostKey;

    public SshTransport(string host, int port, string privateKeyPath,
        string knownHostsPath, string username = "root")
    {
        ValidateIpv4(host);
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        if (username != "root") throw new ArgumentException("Для управления модемом требуется root SSH.", nameof(username));
        if (!File.Exists(privateKeyPath)) throw new FileNotFoundException("Приватный SSH-ключ не найден.", privateKeyPath);
        if (!File.Exists(knownHostsPath)) throw new FileNotFoundException("Закреплённый SSH host key не найден.", knownHostsPath);
        _host = host;
        _port = port;
        _username = username;
        _privateKeyPath = privateKeyPath;
        _pinnedHostKey = ReadPinnedKey(knownHostsPath, host, port);
    }

    public async Task<RemoteResult> RunAsync(string command, byte[]? stdin = null,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(command);
        if (command.Length == 0 || command.IndexOf('\0') >= 0 ||
            Encoding.UTF8.GetByteCount(command) > MaximumCommandBytes)
            throw new ArgumentException("Недопустимая SSH-команда.", nameof(command));
        if (stdin?.Length > MaximumTransferBytes)
            throw new ArgumentException("Передаваемые данные превышают допустимый размер.", nameof(stdin));

        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(EffectiveTimeout(timeout));
        var trustRejected = false;
        using var client = CreateClient(() => trustRejected = true);
        Task? execution = null;
        try
        {
            await client.ConnectAsync(lifetime.Token).WaitAsync(lifetime.Token).ConfigureAwait(false);
            using var remote = client.CreateCommand(command);
            // SSH.NET 2024.x/2025.x has had timer/cancellation races in
            // SshCommand. The outer deadline closes the connection instead.
            remote.CommandTimeout = Timeout.InfiniteTimeSpan;
            execution = remote.ExecuteAsync(CancellationToken.None);
            var stdout = ReadBoundedAsync(remote.OutputStream, MaximumOutputBytes, lifetime.Token);
            var stderr = ReadBoundedAsync(remote.ExtendedOutputStream, 4 * 1024 * 1024, lifetime.Token);
            using (var input = remote.CreateInputStream())
            {
                if (stdin is { Length: > 0 })
                    await input.WriteAsync(stdin, lifetime.Token).ConfigureAwait(false);
            }
            await execution.WaitAsync(lifetime.Token).ConfigureAwait(false);
            return new RemoteResult(remote.ExitStatus ?? -1,
                await stdout.ConfigureAwait(false), await stderr.ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Observe(execution);
            TryDisconnect(client);
            throw new TimeoutException("Истекло время ожидания SSH. Состояние операции необходимо проверить перед повтором.");
        }
        catch (Exception error) when (trustRejected)
        {
            Observe(execution);
            TryDisconnect(client);
            throw new SshTrustException("Ключ сервера SSH не совпадает с закреплённым ключом. Подключение остановлено.", error);
        }
        catch
        {
            Observe(execution);
            TryDisconnect(client);
            throw;
        }
    }

    public async Task UploadAsync(string remotePath, byte[] data,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ValidateRemotePath(remotePath);
        ArgumentNullException.ThrowIfNull(data);
        if (data.Length > MaximumTransferBytes)
            throw new ArgumentException("Передаваемый файл превышает допустимый размер.", nameof(data));
        // The caller must choose a fresh staged path. set -C forbids overwriting
        // any pre-existing device file, including a symlink.
        var quoted = ShellQuote(remotePath);
        var command = "set -eu; umask 077; set -C; cat > " + quoted +
            "; chmod 600 " + quoted + "; sha256sum " + quoted;
        var result = await RunAsync(command, data, timeout, ct).ConfigureAwait(false);
        if (!result.Success)
            throw new IOException("Модем не принял файл; код SSH " + result.ExitCode + ".");
        var receipt = Encoding.UTF8.GetString(result.Stdout).Trim().Split((char[]?)null,
            StringSplitOptions.RemoveEmptyEntries);
        var expected = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        if (receipt.Length != 2 || receipt[0] != expected || receipt[1] != remotePath)
            throw new IOException("SHA256 файла на модеме не совпал с исходным файлом.");
    }

    /// <summary>Stream a large, bounded remote stdout into a new local file.</summary>
    public async Task<RemoteFileResult> RunToFileAsync(string command, string destination,
        long maximumBytes, TimeSpan timeout, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(command) || command.IndexOf('\0') >= 0 ||
            Encoding.UTF8.GetByteCount(command) > MaximumCommandBytes)
            throw new ArgumentException("Недопустимая SSH-команда.", nameof(command));
        if (!Path.IsPathFullyQualified(destination) || maximumBytes is < 1 or > 16L * 1024 * 1024 * 1024)
            throw new ArgumentException("Недопустимый путь или размер резервной копии.", nameof(destination));
        _ = EffectiveTimeout(timeout);
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(timeout);
        var trustRejected = false;
        using var client = CreateClient(() => trustRejected = true);
        Task? execution = null;
        try
        {
            await client.ConnectAsync(lifetime.Token).WaitAsync(lifetime.Token).ConfigureAwait(false);
            using var remote = client.CreateCommand(command);
            remote.CommandTimeout = Timeout.InfiniteTimeSpan;
            execution = remote.ExecuteAsync(CancellationToken.None);
            var stderr = ReadBoundedAsync(remote.ExtendedOutputStream, 1024 * 1024, lifetime.Token);
            await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 1024 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = ArrayPool<byte>.Shared.Rent(1024 * 1024);
            long total = 0;
            try
            {
                while (true)
                {
                    var count = await remote.OutputStream.ReadAsync(buffer.AsMemory(0, buffer.Length), lifetime.Token)
                        .ConfigureAwait(false);
                    if (count == 0) break;
                    if (count > maximumBytes - total) throw new InvalidDataException("Резервная копия превышает допустимый размер.");
                    await output.WriteAsync(buffer.AsMemory(0, count), lifetime.Token).ConfigureAwait(false);
                    hash.AppendData(buffer, 0, count);
                    total += count;
                }
            }
            finally { ArrayPool<byte>.Shared.Return(buffer); }
            await execution.WaitAsync(lifetime.Token).ConfigureAwait(false);
            await output.FlushAsync(lifetime.Token).ConfigureAwait(false);
            return new RemoteFileResult(remote.ExitStatus ?? -1, total,
                Convert.ToHexStringLower(hash.GetHashAndReset()), await stderr.ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Observe(execution); TryDisconnect(client);
            throw new TimeoutException("Истекло время передачи резервной копии. Неполный файл будет удалён.");
        }
        catch (Exception error) when (trustRejected)
        {
            Observe(execution); TryDisconnect(client);
            throw new SshTrustException("Ключ сервера SSH не совпадает с закреплённым ключом.", error);
        }
        catch { Observe(execution); TryDisconnect(client); throw; }
    }

    public async Task<byte[]> DownloadAsync(string remotePath,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        ValidateRemotePath(remotePath);
        var result = await RunAsync("cat -- " + ShellQuote(remotePath), null, timeout, ct)
            .ConfigureAwait(false);
        if (!result.Success)
            throw new IOException("Модем не вернул файл; код SSH " + result.ExitCode + ".");
        return result.Stdout;
    }

    /// <summary>
    /// Opens an interactive SSH PTY with the same exact host-key pin as RunAsync.
    /// The caller owns and must dispose both returned objects.
    /// </summary>
    public async Task<(SshClient Client, ShellStream Stream)> OpenShellAsync(
        CancellationToken ct = default)
    {
        var trustRejected = false;
        var client = CreateClient(() => trustRejected = true);
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            await client.ConnectAsync(lifetime.Token).WaitAsync(lifetime.Token).ConfigureAwait(false);
            var stream = client.CreateShellStream("xterm-256color", 100, 26, 0, 0, 64 * 1024);
            return (client, stream);
        }
        catch (Exception error) when (trustRejected)
        {
            client.Dispose();
            throw new SshTrustException("Ключ сервера SSH не совпадает с закреплённым ключом. Терминал остановлен.", error);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            client.Dispose();
            throw new TimeoutException("SSH-терминал не открылся вовремя.");
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    private SshClient CreateClient(Action onTrustRejected)
    {
        var privateKey = new PrivateKeyFile(_privateKeyPath);
        var connection = new ConnectionInfo(_host, _port, _username,
            new PrivateKeyAuthenticationMethod(_username, privateKey))
        {
            Timeout = TimeSpan.FromSeconds(8),
        };
        var client = new SshClient(connection);
        client.HostKeyReceived += (_, args) =>
        {
            args.CanTrust = args.HostKeyName == "ssh-ed25519" &&
                args.HostKey.Length == _pinnedHostKey.Length &&
                CryptographicOperations.FixedTimeEquals(args.HostKey, _pinnedHostKey);
            if (!args.CanTrust) onTrustRejected();
        };
        return client;
    }

    private static byte[] ReadPinnedKey(string path, string host, int port)
    {
        var target = port == 22 ? host : $"[{host}]:{port}";
        byte[]? match = null;
        foreach (var line in File.ReadLines(path))
        {
            var trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed[0] == '#') continue;
            var fields = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            var offset = fields.Length > 0 && fields[0].StartsWith('@') ? 1 : 0;
            if (fields.Length < offset + 3) continue;
            var hosts = fields[offset].Split(',');
            if (!hosts.Contains(target, StringComparer.Ordinal)) continue;
            if (offset != 0 || fields[offset + 1] != "ssh-ed25519")
                throw new InvalidDataException("Для этого модема нужен явный ed25519 host key без маркера.");
            byte[] key;
            try { key = Convert.FromBase64String(fields[offset + 2]); }
            catch (FormatException ex) { throw new InvalidDataException("Неверный формат закреплённого host key.", ex); }
            if (!ValidEd25519Blob(key)) throw new InvalidDataException("Неверный ed25519 host key.");
            if (match is not null && !CryptographicOperations.FixedTimeEquals(match, key))
                throw new InvalidDataException("Для модема записано несколько разных host key.");
            match = key;
        }
        return match ?? throw new InvalidDataException("Для указанного адреса и порта нет закреплённого SSH host key.");
    }

    private static bool ValidEd25519Blob(byte[] key)
    {
        return key.Length == 51 &&
            key.AsSpan(0, 4).SequenceEqual(new byte[] { 0, 0, 0, 11 }) &&
            key.AsSpan(4, 11).SequenceEqual("ssh-ed25519"u8) &&
            key.AsSpan(15, 4).SequenceEqual(new byte[] { 0, 0, 0, 32 });
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream source, int limit, CancellationToken ct)
    {
        using var output = new MemoryStream();
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            while (true)
            {
                var count = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)
                    .ConfigureAwait(false);
                if (count == 0) return output.ToArray();
                if (count > limit - output.Length)
                    throw new InvalidDataException("Ответ SSH превысил допустимый размер.");
                output.Write(buffer, 0, count);
            }
        }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
    }

    private static TimeSpan EffectiveTimeout(TimeSpan? value)
    {
        var timeout = value ?? TimeSpan.FromSeconds(30);
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromHours(2))
            throw new ArgumentOutOfRangeException(nameof(value), "Недопустимое время ожидания SSH.");
        return timeout;
    }

    private static void ValidateIpv4(string host)
    {
        if (host is null || host.Split('.').Length != 4 ||
            host.Any(c => c != '.' && (c < '0' || c > '9')) ||
            !IPAddress.TryParse(host, out var address) || address.AddressFamily != AddressFamily.InterNetwork)
            throw new ArgumentException("Введите полный IPv4-адрес модема.", nameof(host));
    }

    private static void ValidateRemotePath(string path)
    {
        if (string.IsNullOrEmpty(path) || !path.StartsWith('/') || path.Length > 1024 ||
            path.Any(c => c is '\0' or '\n' or '\r'))
            throw new ArgumentException("Неверный абсолютный путь на модеме.", nameof(path));
    }

    private static string ShellQuote(string text) => "'" + text.Replace("'", "'\\''", StringComparison.Ordinal) + "'";

    private static void Observe(Task? task)
    {
        if (task is null) return;
        _ = task.ContinueWith(static completed => _ = completed.Exception,
            CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
    }

    private static void TryDisconnect(SshClient client)
    {
        try { if (client.IsConnected) client.Disconnect(); }
        catch { /* The connection is already unusable. */ }
    }
}
