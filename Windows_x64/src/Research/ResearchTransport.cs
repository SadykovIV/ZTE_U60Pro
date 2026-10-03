using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Research;

public sealed record ResearchCommandResult(string Status, int? ExitCode, string Stdout, string Stderr, bool Truncated = false, int? LocalExitCode = null, bool ConnectionEstablished = false);
public interface IResearchShell
{
    string Channel { get; }
    Task<ResearchCommandResult> ExecuteAsync(string command, int seconds, int maxBytes, CancellationToken ct);
}
public interface IResearchTransportFactory
{
    bool SshConfigured { get; }
    IResearchShell OpenSsh();
    Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct);
    IResearchShell OpenAdb(string serial);
    Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct);
}

// A single shared byte budget covers stdout AND stderr. Streams continue draining,
// avoiding pipe deadlocks while retaining only the bounded prefix and marker tail.
public sealed class ResearchCapture(int maxBytes)
{
    private readonly object _gate = new();
    private int _remaining = maxBytes;
    public bool Truncated { get; private set; }
    public bool Incomplete { get; private set; }
    public string? Failure { get; private set; }
    public int MarkerOccurrences { get; private set; }
    public async Task<(string Text, string Tail)> ReadAsync(Stream stream, CancellationToken ct, string? marker = null)
    {
        using var data = new MemoryStream();
        var tail = new byte[512]; var tailCount = 0;
        var buffer = new byte[8192];
        var needle = marker is null ? [] : Encoding.ASCII.GetBytes(marker);
        byte[] markerCarry = [];
        try
        {
            while (true)
            {
                var count = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
                if (count == 0) break;
                if (needle.Length > 0)
                {
                    // Count across chunk boundaries and discarded output too;
                    // truncation must not hide a duplicate completion nonce.
                    var window = new byte[markerCarry.Length + count];
                    markerCarry.CopyTo(window, 0); Buffer.BlockCopy(buffer, 0, window, markerCarry.Length, count);
                    var position = 0;
                    while (position < window.Length)
                    {
                        var found = window.AsSpan(position).IndexOf(needle);
                        if (found < 0) break;
                        MarkerOccurrences = Math.Min(2, MarkerOccurrences + 1);
                        position += found + needle.Length;
                    }
                    markerCarry = window[Math.Max(0, window.Length - needle.Length + 1)..];
                }
                var keep = 0;
                lock (_gate) { keep = Math.Min(count, _remaining); _remaining -= keep; Truncated |= keep != count; }
                data.Write(buffer, 0, keep);
                if (count >= tail.Length) { Buffer.BlockCopy(buffer, count-tail.Length, tail, 0, tail.Length); tailCount=tail.Length; }
                else { var previous=Math.Min(tailCount,tail.Length-count); Buffer.BlockCopy(tail,tailCount-previous,tail,0,previous); Buffer.BlockCopy(buffer,0,tail,previous,count); tailCount=previous+count; }
            }
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException) { lock(_gate) { Incomplete=true;Failure=error.GetType().Name+": "+error.Message; } }
        return (Encoding.UTF8.GetString(data.ToArray()), Encoding.UTF8.GetString(tail,0,tailCount));
    }
}

public sealed class ResearchAdbShell(string executable, string? serial) : IResearchShell
{
    public string Channel => "ADB";
    public Task<ResearchCommandResult> ExecuteAsync(string command,int seconds,int maxBytes,CancellationToken ct)
    {
        if (serial is null) return RunAsync(executable,["devices","-l"],seconds,maxBytes,null,ct);
        if (!Regex.IsMatch(serial,@"^[A-Za-z0-9._-]{1,256}$") || serial.StartsWith("emulator-",StringComparison.Ordinal))
            throw new InvalidDataException("Research requires a bound USB ADB serial.");
        var marker="__FR_RESULT_"+Guid.NewGuid().ToString("N")+"__";
        var wrapped="("+command+"); fr_code=$?; printf '\\n"+marker+"%s\\n' \"$fr_code\"";
        return RunAsync(executable,["-s",serial,"shell",wrapped],seconds,maxBytes,marker,ct);
    }
    public static async Task<ResearchCommandResult> RunAsync(string executable,string[] arguments,int seconds,int maxBytes,string? marker,CancellationToken ct)
    {
        using var lifetime=CancellationTokenSource.CreateLinkedTokenSource(ct); lifetime.CancelAfter(TimeSpan.FromSeconds(seconds));
        var start=new ProcessStartInfo(executable) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,RedirectStandardInput=true };
        foreach(var argument in arguments)start.ArgumentList.Add(argument);
        using var process=new Process {StartInfo=start};
        if(!process.Start()) throw new IOException("ADB process did not start.");
        process.StandardInput.Close();
        var capture=new ResearchCapture(maxBytes);
        var stdout=capture.ReadAsync(process.StandardOutput.BaseStream,lifetime.Token,marker);
        var stderr=capture.ReadAsync(process.StandardError.BaseStream,lifetime.Token);
        var status="success"; int? code=null; int? localCode=null;
        try { await process.WaitForExitAsync(lifetime.Token).ConfigureAwait(false); localCode=process.ExitCode; }
        catch(OperationCanceledException) { status=ct.IsCancellationRequested?"cancelled":"timeout"; try { process.Kill(true); }catch{} }
        var output=await stdout.ConfigureAwait(false); var error=await stderr.ConfigureAwait(false);
        if(capture.Incomplete || lifetime.IsCancellationRequested)
        {
            status=ct.IsCancellationRequested?"cancelled":lifetime.IsCancellationRequested?"timeout":"failed";
            error=(error.Text+"\nIncomplete capture: "+capture.Failure,error.Tail);
            try { if(!process.HasExited)process.Kill(true); }catch { }
        }
        if(status=="success" && localCode==0 && marker is not null)
        {
            if(capture.MarkerOccurrences==1 && AdbShellOutput.TryDecodeCompletion(Encoding.UTF8.GetBytes(output.Tail),marker,out var remoteCode,out _)) code=remoteCode;
            else { code=null; status="failed"; error=(error.Text+"\nADB remote exit status is missing.",error.Tail); }
            var bytes=Encoding.UTF8.GetBytes(output.Text);
            if(code is not null && AdbShellOutput.TryDecodeCompletion(bytes,marker,out _,out var length))
                output=(Encoding.UTF8.GetString(bytes,0,length),output.Tail);
        }
        if(status=="success") status=capture.Truncated?"truncated":(marker is null?localCode==0:code==0)?"success":"failed";
        return new(status,code,AdbShellOutput.NormalizeText(output.Text),AdbShellOutput.NormalizeText(error.Text),capture.Truncated,localCode);
    }
}

public sealed class ResearchTransportFactory(string host,int port,string key,string knownHosts,string adbPath) : IResearchTransportFactory
{
    public bool SshConfigured => File.Exists(key) && File.Exists(knownHosts);
    public IResearchShell OpenSsh()=>new ResearchSshShell(new SshTransport(host,port,key,knownHosts));
    public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct)=>new ResearchAdbShell(adbPath,null).ExecuteAsync("",15,64*1024,ct);
    public IResearchShell OpenAdb(string serial)=>new ResearchAdbShell(adbPath,serial);
    public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct)=>ResearchAdbShell.RunAsync(adbPath,["-d","get-serialno"],10,16384,null,ct);
}
public sealed class ResearchSshShell(SshTransport ssh) : IResearchShell
{
    public string Channel=>"SSH";
    public Task<ResearchCommandResult> ExecuteAsync(string command,int seconds,int maxBytes,CancellationToken ct)=>ssh.RunResearchAsync(command,seconds,maxBytes,ct);
}
