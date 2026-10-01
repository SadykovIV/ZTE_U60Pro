namespace ZteImeiStudio.Transport;

public sealed partial class SshTransport
{
    // No stdout/stderr snapshots, terminal rendering or command-result logging.
    public async Task<(T Value, int ExitCode)> RunPrivateAsync<T>(string command,
        Func<Stream, Stream, CancellationToken, Task<T>> exchange, CancellationToken ct)
    {
        var trustRejected = false;
        using var client = CreateClient(() => trustRejected = true);
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(TimeSpan.FromMinutes(20));
        await client.ConnectAsync(lifetime.Token).ConfigureAwait(false);
        if (trustRejected) throw new IOException("SSH trust rejected.");
        using var remote = client.CreateCommand(command);
        remote.CommandTimeout = Timeout.InfiniteTimeSpan;
        var execution = remote.ExecuteAsync(CancellationToken.None);
        var discard = DiscardPrivateAsync(remote.ExtendedOutputStream, CancellationToken.None);
        using var input = remote.CreateInputStream();
        try
        {
            var value = await exchange(remote.OutputStream, input, lifetime.Token).ConfigureAwait(false);
            input.Close();
            await execution.WaitAsync(lifetime.Token).ConfigureAwait(false);
            await discard.WaitAsync(lifetime.Token).ConfigureAwait(false);
            return (value, remote.ExitStatus ?? -1);
        }
        catch (Exception error)
        {
            // EOF gives the agent a chance to close its owned QMI channel.
            input.Close();
            var drain = DiscardPrivateAsync(remote.OutputStream, CancellationToken.None);
            // A normal protocol/HTTPS error must not interrupt the bridge's pending
            // QMI transaction and owned-channel close. Only explicit caller cancellation
            // abandons this wait; the operation then stays unconfirmed.
            try { await Task.WhenAll(execution, drain, discard).WaitAsync(ct).ConfigureAwait(false); }
            catch { TryDisconnect(client); Observe(execution); Observe(drain); Observe(discard); }
            if (error is OperationCanceledException && lifetime.IsCancellationRequested && !ct.IsCancellationRequested)
                throw new TimeoutException("Private eSIM transport deadline exceeded.");
            // Preserve typed, fixed protocol errors after cleanup. The service maps
            // all other exceptions to a fixed code and never logs their text.
            throw;
        }
    }
    private static async Task DiscardPrivateAsync(Stream stream, CancellationToken ct)
    {
        var buffer = new byte[8192];
        while (await stream.ReadAsync(buffer, ct).ConfigureAwait(false) != 0) Array.Clear(buffer);
    }
}
