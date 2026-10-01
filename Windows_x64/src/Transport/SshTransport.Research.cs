using ZteImeiStudio.Windows.Research;
namespace ZteImeiStudio.Transport;

public sealed partial class SshTransport
{
    // Dedicated diagnostic capture: no upload, no stdin, no writes, bounded from
    // the moment bytes leave SSH.NET. It does not use the 256 MiB transfer path.
    public async Task<ResearchCommandResult> RunResearchAsync(string command,int seconds,int maxBytes,CancellationToken ct)
    {
        if(seconds is <1 or >60 || maxBytes is <1024 or >262144 || command.Length is <1 or >65536 || command.Contains('\0'))
            throw new ArgumentException("Invalid research command limits.");
        using var lifetime=CancellationTokenSource.CreateLinkedTokenSource(ct); lifetime.CancelAfter(TimeSpan.FromSeconds(seconds));
        var trustRejected=false;
        using var client=CreateClient(()=>trustRejected=true);
        try { await client.ConnectAsync(lifetime.Token).WaitAsync(lifetime.Token).ConfigureAwait(false); }
        catch(Exception error) when(trustRejected) { throw new SshTrustException("SSH host key mismatch; research stopped.",error); }
        catch(OperationCanceledException) { return new(ct.IsCancellationRequested?"cancelled":"timeout",null,"","SSH connection did not finish."); }
        using var remote=client.CreateCommand(command); remote.CommandTimeout=Timeout.InfiniteTimeSpan;
        var task=remote.ExecuteAsync(CancellationToken.None);
        var capture=new ResearchCapture(maxBytes);
        var stdout=capture.ReadAsync(remote.OutputStream,lifetime.Token);
        var stderr=capture.ReadAsync(remote.ExtendedOutputStream,lifetime.Token);
        var status="success"; int? code=null;
        try { await task.WaitAsync(lifetime.Token).ConfigureAwait(false); code=remote.ExitStatus; }
        catch(OperationCanceledException) { status=ct.IsCancellationRequested?"cancelled":"timeout"; Observe(task); TryDisconnect(client); }
        catch { Observe(task); TryDisconnect(client); throw; }
        var output=await stdout.ConfigureAwait(false); var errorOutput=await stderr.ConfigureAwait(false);
        if(capture.Incomplete || lifetime.IsCancellationRequested)
        {
            status=ct.IsCancellationRequested?"cancelled":lifetime.IsCancellationRequested?"timeout":"failed";
            errorOutput=(errorOutput.Text+"\nIncomplete capture: "+capture.Failure,errorOutput.Tail);
            TryDisconnect(client);
        }
        if(status=="success")status=capture.Truncated?"truncated":code==0?"success":"failed";
        return new(status,code,output.Text,errorOutput.Text,capture.Truncated,ConnectionEstablished:true);
    }
}
