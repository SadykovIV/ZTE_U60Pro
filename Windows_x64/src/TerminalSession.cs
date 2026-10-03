using System.Text;
using Renci.SshNet;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows;

/// <summary>Interactive SSH PTY. Bytes stay in memory; they are never written to the app journal.</summary>
internal sealed class TerminalSession : ITerminalSession
{
    private readonly Func<bool> _connected;
    private readonly Action _disconnect;
    private readonly FileStream _operationLock;
    private readonly Stream _stream;
    private readonly CancellationTokenSource _closed = new();
    private readonly SemaphoreSlim _write = new(1,1);
    private readonly Task _reader;
    private EventHandler<TerminalDataEventArgs>? _output;
    private readonly StringBuilder _pending = new();
    private bool _disposed;
    private volatile bool _readerEnded;
    private const int BufferLimit = 2 * 1024 * 1024;
    public bool IsConnected => !_disposed && !_readerEnded && _connected();
    public event EventHandler<TerminalDataEventArgs>? OutputReceived
    {
        add { lock (_pending) { _output += value; if (_pending.Length > 0) { value?.Invoke(this,new TerminalDataEventArgs(_pending.ToString())); _pending.Clear(); } } }
        remove { lock (_pending) _output -= value; }
    }
    internal TerminalSession(SshClient client,ShellStream stream,string firstOutput,FileStream operationLock)
        : this(stream, () => client.IsConnected, () => { client.Disconnect(); client.Dispose(); }, firstOutput, operationLock) { }

    internal TerminalSession(Stream stream,Func<bool> connected,Action disconnect,string firstOutput,FileStream operationLock)
    {
        _connected=connected; _disconnect=disconnect; _stream=stream; _operationLock=operationLock;
        if (!string.IsNullOrEmpty(firstOutput)) _pending.Append(firstOutput);
        _reader=Task.Run(ReadLoop);
    }
    private async Task ReadLoop()
    {
        var bytes=new byte[8192];
        var decoder=Encoding.UTF8.GetDecoder(); var chars=new char[8192];
        try
        {
            while (!_closed.IsCancellationRequested)
            {
                var count=await _stream.ReadAsync(bytes,_closed.Token);
                if (count==0) break;
                var length=decoder.GetChars(bytes,0,count,chars,0,flush:false);
                if (length>0) Publish(new string(chars,0,length));
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception error) { Publish("\nSSH: " + error.Message + "\n"); }
        finally { _readerEnded=true; _operationLock.Dispose(); }
    }
    private void Publish(string value)
    {
        lock (_pending)
        {
            if (_output is { } output) output.Invoke(this,new TerminalDataEventArgs(value));
            else { _pending.Append(value); if (_pending.Length>BufferLimit) _pending.Remove(0,_pending.Length-BufferLimit); }
        }
    }
    public async Task SendAsync(string text,CancellationToken cancellationToken=default)
    {
        if (!IsConnected) throw new IOException("Терминал отключён.");
        var data=Encoding.UTF8.GetBytes(text);
        if (data.Length>1024*1024) throw new ArgumentOutOfRangeException(nameof(text),"Вставка превышает 1 МБ. Отправьте её частями.");
        await _write.WaitAsync(cancellationToken);
        try { await _stream.WriteAsync(data,cancellationToken); await _stream.FlushAsync(cancellationToken); }
        finally { _write.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed=true; _closed.Cancel();
        try { _stream.Dispose(); } catch { }
        try { _disconnect(); } catch { }
        try { await _reader.WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        _write.Dispose(); _closed.Dispose(); _operationLock.Dispose();
    }
}

public sealed partial class WindowsModemService
{
    private partial async Task<ITerminalSession> OpenTerminalCoreAsync(CancellationToken ct)
    {
        RequireSsh();
        var operationLock=new FileStream(Path.Combine(_storage,"operation.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        try
        {
        foreach (var name in new[] { "setup-pending.json", "adb-access-pending.json", "imei-pending.json", "pending.json", "system-restore-pending.json" })
            if (File.Exists(Path.Combine(_storage,name))) throw new InvalidOperationException("Сначала завершите незавершённую операцию модема; терминал пока недоступен.");
        var identity=await _imei!.IdentityAsync(ct);
        var (client,stream)=await _ssh!.OpenShellAsync(ct);
        try
        {
            // Hide the handshake command from PTY echo. The marker is accepted
            // only after both CID and boot ID have been compared inside the shell.
            var marker="__ZTE_WIN_TERMINAL_"+Guid.NewGuid().ToString("N").ToUpperInvariant()+"__";
            await stream.WriteAsync(Encoding.ASCII.GetBytes("stty -echo\r"),ct);
            var command="test \"$(cat /sys/block/mmcblk0/device/cid)\" = "+VerifiedHash.ShellQuote(identity.Cid)+
                " && test \"$(cat /proc/sys/kernel/random/boot_id)\" = "+VerifiedHash.ShellQuote(identity.BootId)+
                " && printf '%s\\n' "+VerifiedHash.ShellQuote(marker)+" || exit 1\r";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(command),ct);
            using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            var data=new byte[4096];var received=new StringBuilder();
            while (!received.ToString().Contains(marker,StringComparison.Ordinal))
            {
                var count=await stream.ReadAsync(data,timeout.Token);
                if (count==0 || received.Length>32768) throw new IOException("SSH не подтвердил CID и boot ID терминала.");
                received.Append(Encoding.UTF8.GetString(data,0,count));
            }
            await stream.WriteAsync(Encoding.ASCII.GetBytes("unset ENV; HISTFILE=/dev/null; opkg() { /data/zte-imei-apps/opkg-private/opkg \"$@\"; }; stty echo\r"),ct);
            var current=received.ToString();var offset=current.IndexOf(marker,StringComparison.Ordinal)+marker.Length;
            return new TerminalSession(client,stream,current[offset..],operationLock);
        }
        catch { stream.Dispose();client.Dispose();throw; }
        }
        catch { operationLock.Dispose(); throw; }
    }
}
