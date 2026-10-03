using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Transport;

internal sealed class AdbStreamRequest
{
    internal required string OriginalCommand { get; init; }
    internal required string Wrapper { get; init; }
    internal required byte[] Input { get; init; }
    internal required string Ready { get; init; }
    internal required string Begin { get; init; }
    internal required string Result { get; init; }
}

internal static class AdbStreamProtocol
{
    internal const int InlineLimit = 3000;
    internal const int CommandLimit = 128 * 1024;
    internal const string TemplateSha256 = "0692a6b053b7cadae5d4a754684e94062ecaa94067f8f103913c1191e9dc6a1c";
    internal static string TemplatePath(string executable) => Path.GetFullPath(Path.Combine(Path.GetDirectoryName(executable)!, "..", "Onboarding", "adb-stream.sh"));
    internal static void Validate(string command)
    {
        if (string.IsNullOrEmpty(command) || command.Contains('\0') || new UTF8Encoding(false,true).GetByteCount(command)>CommandLimit)
            throw new ArgumentException("Недопустимая команда ADB shell.",nameof(command));
    }
    internal static AdbStreamRequest Build(string command,string path)
    {
        Validate(command);
        var templateBytes=File.ReadAllBytes(path);
        if(templateBytes.Length>4096 || Convert.ToHexStringLower(SHA256.HashData(templateBytes))!=TemplateSha256)
            throw new InvalidDataException("Повреждён встроенный протокол передачи ADB.");
        var template=new UTF8Encoding(false,true).GetString(templateBytes);
        var body=Encoding.UTF8.GetBytes(command);
        string Nonce()=>Guid.NewGuid().ToString("N").ToUpperInvariant();
        var ready="__ZTE_READY_"+Nonce()+"__";var begin="__ZTE_BEGIN_"+Nonce()+"__";
        var result="__ZTE_RESULT_"+Nonce()+"__";var end="__ZTE_END_"+Nonce()+"__";
        var encoded=new StringBuilder(body.Length*5+(body.Length+63)/64+end.Length+1);
        for(var i=0;i<body.Length;i++)
        {
            encoded.Append("\\0").Append(Convert.ToString(body[i],8).PadLeft(3,'0'));
            if(i%64==63 || i==body.Length-1)encoded.Append('\n');
        }
        encoded.Append(end).Append('\n');
        var values=new Dictionary<string,string> { ["@CHUNKS@"]=((body.Length+63)/64).ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["@LAST_CHARS@"]=(5*((body.Length-1)%64+1)).ToString(System.Globalization.CultureInfo.InvariantCulture),["@BYTES@"]=body.Length.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["@SHA256@"]=Convert.ToHexStringLower(SHA256.HashData(body)),["@READY@"]=ready,["@BEGIN@"]=begin,["@RESULT@"]=result,["@END@"]=end };
        foreach(var pair in values)template=template.Replace(pair.Key,pair.Value,StringComparison.Ordinal);
        var wrapper="sh -c '"+template.Replace("'","'\\''",StringComparison.Ordinal)+"'";
        if(Encoding.UTF8.GetByteCount(wrapper)>=4096 || Regex.IsMatch(template,"@[A-Z_]+@"))throw new InvalidDataException("Недопустимый размер протокола ADB.");
        return new() {OriginalCommand=command,Wrapper=wrapper,Input=Encoding.ASCII.GetBytes(encoded.ToString()),Ready=ready,Begin=begin,Result=result};
    }
    internal static string KnownLocalError(byte[] stderr) =>
        Encoding.UTF8.GetString(stderr).Split('\n').Any(line=>line.TrimEnd('\r')=="error: shell command too long") ? " error: shell command too long" : "";
}

internal sealed record AdbStreamResult(int LocalExitCode,byte[] Stdout,byte[] Stderr,byte[] Tail,bool Truncated,int ResultOccurrences);

// Discard PTY echo before BEGIN. Body bytes remain untouched, including trailing CR.
// Keep a bounded prefix plus a footer tail while scanning the entire stream.
internal sealed class AdbStreamCapture(AdbStreamRequest request,int maxBytes)
{
    private readonly object gate=new();
    private readonly MemoryStream output=new(),errors=new(),line=new();
    private int remaining=maxBytes,prefixBytes,resultOccurrences;
    private bool readySeen,longLine,truncated,knownLocalFailure;
    private volatile bool begun;
    private byte[] preErrorTail=[];
    private byte[] carry=[],tail=[];
    internal TaskCompletionSource Ready {get;}=new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly byte[] result=Encoding.ASCII.GetBytes(request.Result),begin=Encoding.ASCII.GetBytes(request.Begin),ready=Encoding.ASCII.GetBytes(request.Ready);
    internal void Stdout(ReadOnlySpan<byte> data)
    {
        var position=0;
        while(!begun && position<data.Length)
        {
            var value=data[position++];
            if(++prefixBytes>request.Input.Length*3+8192)throw new InvalidDataException("ADB stream prefix exceeded its limit.");
            if(value!=10) {if(line.Length<512)line.WriteByte(value);else longLine=true;continue;}
            var bytes=line.ToArray();line.SetLength(0);
            var length=bytes.Length;while(length>0 && bytes[length-1]==13)length--;
            if(!longLine && bytes.Length-length<=2)
            {
                if(bytes.AsSpan(0,length).SequenceEqual(ready)) {if(readySeen)throw new InvalidDataException("Duplicate ADB READY.");readySeen=true;Ready.TrySetResult();}
                else if(bytes.AsSpan(0,length).SequenceEqual(begin)) {if(!readySeen)throw new InvalidDataException("ADB BEGIN preceded READY.");begun=true;}
            }
            longLine=false;
        }
        if(position<data.Length)Body(data[position..]);
    }
    private void Body(ReadOnlySpan<byte> data)
    {
        var window=new byte[carry.Length+data.Length];carry.CopyTo(window,0);data.CopyTo(window.AsSpan(carry.Length));
        Count(window,result,ref resultOccurrences);
        var bad=0;Count(window,begin,ref bad);Count(window,ready,ref bad);
        if(bad!=0)throw new InvalidDataException("Duplicate ADB stream boundary.");
        var keepCarry=Math.Max(result.Length,Math.Max(begin.Length,ready.Length))-1;
        carry=window[Math.Max(0,window.Length-keepCarry)..];
        // All nonce strings have equal-size suffixes but not equal total lengths.
        // Count only matches ending in new data, avoiding carry-only recounts.
        var combined=new byte[tail.Length+data.Length];tail.CopyTo(combined,0);data.CopyTo(combined.AsSpan(tail.Length));tail=combined[Math.Max(0,combined.Length-512)..];
        lock(gate) {var keep=Math.Min(data.Length,remaining);output.Write(data[..keep]);remaining-=keep;truncated|=keep<data.Length;}
    }
    private void Count(byte[] window,byte[] needle,ref int count)
    {
        var offset=0;
        while(offset<window.Length)
        {
            var found=window.AsSpan(offset).IndexOf(needle);if(found<0)break;
            var end=offset+found+needle.Length;if(end>carry.Length)count=Math.Min(2,count+1);offset=end;
        }
    }
    internal void Stderr(ReadOnlySpan<byte> data)
    {
        lock(gate)
        {
            // Legacy PTY echo can expose reversible command packets. Retain
            // only a known fixed client error until execution has begun.
            if(!begun)
            {
                var scan=new byte[preErrorTail.Length+data.Length];preErrorTail.CopyTo(scan,0);data.CopyTo(scan.AsSpan(preErrorTail.Length));
                knownLocalFailure|=AdbStreamProtocol.KnownLocalError(scan).Length!=0;
                preErrorTail=scan[Math.Max(0,scan.Length-256)..];return;
            }
            var keep=Math.Min(data.Length,remaining);errors.Write(data[..keep]);remaining-=keep;truncated|=keep<data.Length;
        }
    }
    internal void EndStdout() {if(!readySeen)Ready.TrySetException(new IOException("ADB stream ended before READY."));}
    internal AdbStreamResult Finish(int code)
    {
        if(!readySeen || !begun)throw new IOException("ADB stream execution is unconfirmed."+AdbStreamProtocol.KnownLocalError(ErrorBytes));
        return new(code,output.ToArray(),errors.ToArray(),tail,truncated,resultOccurrences);
    }
    internal byte[] ErrorBytes {get {lock(gate)return knownLocalFailure?Encoding.ASCII.GetBytes("error: shell command too long\n"):errors.ToArray();}}
}

internal static class AdbStreamProcess
{
    internal static async Task<AdbStreamResult> RunAsync(string executable,IReadOnlyList<string> arguments,AdbStreamRequest request,TimeSpan timeout,int maxBytes,CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if(timeout<=TimeSpan.Zero || maxBytes<1)throw new ArgumentOutOfRangeException(nameof(timeout));
        using var deadline=new CancellationTokenSource(timeout);
        using var lifetime=CancellationTokenSource.CreateLinkedTokenSource(ct,deadline.Token);
        var start=new ProcessStartInfo(executable) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var arg in arguments)start.ArgumentList.Add(arg);
        using var process=new Process {StartInfo=start};
        if(!process.Start())throw new IOException("ADB process did not start.");
        var capture=new AdbStreamCapture(request,maxBytes);
        async Task Drain(Stream stream,bool stdout)
        {
            var buffer=new byte[8192];try {int count;while((count=await stream.ReadAsync(buffer,lifetime.Token).ConfigureAwait(false))>0)
                {if(stdout)capture.Stdout(buffer.AsSpan(0,count));else capture.Stderr(buffer.AsSpan(0,count));}}
            finally {if(stdout)capture.EndStdout();}
        }
        async Task Send()
        {
            try
            {
                await capture.Ready.Task.WaitAsync(lifetime.Token).ConfigureAwait(false);
                await process.StandardInput.BaseStream.WriteAsync(request.Input,lifetime.Token).ConfigureAwait(false);
                await process.StandardInput.BaseStream.FlushAsync(lifetime.Token).ConfigureAwait(false);
            }
            finally {process.StandardInput.Close();}
        }
        var stdout=Drain(process.StandardOutput.BaseStream,true);var stderr=Drain(process.StandardError.BaseStream,false);var stdin=Send();var exited=process.WaitForExitAsync(lifetime.Token);
        var tasks=Task.WhenAll(stdout,stderr,stdin,exited);
        // Any pump failure cancels the other pumps; a blocked writer must not
        // outlive the one shared deadline or trigger another device request.
        foreach(var task in new[]{stdout,stderr,stdin,exited})_ = task.ContinueWith(t=> {if(t.IsFaulted)lifetime.Cancel();},CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
        try
        {
            await tasks.ConfigureAwait(false);
            return capture.Finish(process.ExitCode);
        }
        catch
        {
            try {if(!process.HasExited)process.Kill(true);}catch { }
            lifetime.Cancel();
            if(ct.IsCancellationRequested)throw new OperationCanceledException(ct);
            if(deadline.IsCancellationRequested)throw new TimeoutException("ADB не завершил потоковую передачу вовремя; результат не подтверждён.");
            throw new IOException("Результат потоковой команды ADB не подтверждён."+AdbStreamProtocol.KnownLocalError(capture.ErrorBytes));
        }
    }
}
