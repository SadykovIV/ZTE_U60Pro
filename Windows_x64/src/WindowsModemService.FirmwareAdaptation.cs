using System.IO.Compression;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Research;
using ZteImeiStudio.Windows.Diagnostics;

namespace ZteImeiStudio.Windows;

public sealed partial class WindowsModemService
{
    internal FirmwareSupportCollector.StreamFile? FirmwareSupportStream { get; init; }

    private async Task<FirmwareSupportResult> CollectFirmwareAdaptationAsync(IReadOnlyDictionary<string,string>? parameters,CancellationToken ct)
    {
        // Capture the established selection. No Web/ADB fallback, mutation engine or firmware profile is involved.
        var shell = _sshRead ?? _ssh;
        var transport = _ssh;
        var selected = _connectionProof;
        var host = _host; var port = _port; var key = _keyPath; var knownHosts = _knownHostsPath;
        if (shell is null || selected is null || !_snapshot.IsConnected || _snapshot.ConnectionMode != "SSH")
            throw new InvalidOperationException("Для сбора данных для адаптации сначала подключитесь по SSH.");
        if (Param(parameters,"host",host)!=host || Param(parameters,"port",port.ToString(System.Globalization.CultureInfo.InvariantCulture))!=port.ToString(System.Globalization.CultureInfo.InvariantCulture) || Param(parameters,"key_path",key)!=key || Param(parameters,"known_hosts_path",knownHosts)!=knownHosts)
            throw new InvalidOperationException("Настройки подключения изменились; начните сбор заново.");
        var helper = FirmwareSupportCollector.LoadHelper(_resources);
        var spec = ResearchSpec.Load(Path.Combine(_resources,"FirmwareResearch","probes.json"));
        var researchShell = _researchFactory is not null ? _researchFactory().OpenSsh() :
            transport is not null ? new ResearchSshShell(transport) : throw new InvalidOperationException(FirmwareSupportCollector.Failed);
        if(researchShell.Channel!="SSH")throw new InvalidOperationException(FirmwareSupportCollector.Failed);
        var destination = Param(parameters,"destination");
        var work = Path.Combine(_storage,"FirmwareSupport");
        var activityZip = Path.Combine(work,"activity-"+Guid.NewGuid().ToString("N")+".zip");
        var logs = await GetLogsAsync(ct);
        var version = typeof(WindowsModemService).Assembly.GetName().Version?.ToString()??"unknown";
        var activity = new Dictionary<string,byte[]>(StringComparer.Ordinal);
        try
        {
            DiagnosticsExporter.Export(_storage, activityZip, new("SSH",null,null,version),
                logs.Select(x=>new DiagnosticActivity(x.Timestamp,x.Level,x.Message)), _diagnosticPrivacy, _diagnosticJournalWriteFailed, ct, includeResearch:false);
            using(var zip=ZipFile.OpenRead(activityZip))
                foreach(var name in new[]{"application-journal.jsonl","current-session.jsonl","operation-traces.jsonl"})
                {
                    var entry=zip.GetEntry(name)??throw new InvalidDataException(FirmwareSupportCollector.Failed);
                    if(entry.Length>8*1024*1024)throw new InvalidDataException(FirmwareSupportCollector.Failed);
                    using var input=entry.Open();using var bytes=new MemoryStream();input.CopyTo(bytes);activity.Add(name,bytes.ToArray());
                }
            var stream=FirmwareSupportStream ?? ((command,path,maximum,timeout,token,input)=>
                transport!.RunToFileAsync(command,path,maximum,timeout,token,stdin:input));
            void VerifySelection()
            {
                if(_host!=host || _port!=port || _keyPath!=key || _knownHostsPath!=knownHosts ||
                    !ReferenceEquals(_sshRead??_ssh,shell) || !ReferenceEquals(_ssh,transport) ||
                    !_snapshot.IsConnected || _snapshot.ConnectionMode!="SSH")
                    throw new InvalidDataException("Настройки подключения изменились; начните сбор заново.");
            }
            async Task<ResearchReport> CollectResearch(SshReadProof proof,CancellationToken token)
            {
                VerifySelection();
                var captured = new AdaptationResearchShell(researchShell,VerifySelection);
                var engine = new FirmwareResearchEngine(spec,new AdaptationResearchFactory(captured),new ResearchRedactor(new[]{host,key,knownHosts,proof.Cid??"",proof.BootId??""}));
                var report = await engine.CollectAsync("SSH",proof.Cid is null?null:FirmwareResearchEngine.HashSavedCid(proof.Cid),null,token,
                    boundBootHash:proof.BootId is null?null:FirmwareResearchEngine.HashSavedCid(proof.BootId),enforceTimeLimit:false);
                token.ThrowIfCancellationRequested();VerifySelection();
                if(captured.ConnectionLost)throw new InvalidDataException(FirmwareSupportCollector.Failed);
                return report;
            }
            VerifySelection();
            return await FirmwareSupportCollector.CollectAsync(shell,selected,stream,helper,host,destination,work,activity,version,ct,VerifySelection,CollectResearch,_diagnosticPrivacy);
        }
        finally { if(File.Exists(activityZip))File.Delete(activityZip); }
    }

    // Uses the already captured, pinned SSH actor. The adapter cannot select ADB
    // or reopen the public operation gate while the support capture owns it.
    private sealed class AdaptationResearchFactory(IResearchShell shell):IResearchTransportFactory
    {
        public bool SshConfigured=>true;
        public IResearchShell OpenSsh()=>shell;
        public IResearchShell OpenAdb(string serial)=>throw new InvalidOperationException(FirmwareSupportCollector.Failed);
        public Task<ResearchCommandResult> ListAdbAsync(CancellationToken ct)=>throw new InvalidOperationException(FirmwareSupportCollector.Failed);
        public Task<ResearchCommandResult> SingleUsbSerialAsync(CancellationToken ct)=>throw new InvalidOperationException(FirmwareSupportCollector.Failed);
    }
    private sealed class AdaptationResearchShell(IResearchShell shell,Action verifySelection):IResearchShell
    {
        public string Channel=>"SSH";
        public bool ConnectionLost { get; private set; }
        public async Task<ResearchCommandResult> ExecuteAsync(string command,int seconds,int maxBytes,CancellationToken ct)
        {
            try
            {
                verifySelection();
                var reply=await shell.ExecuteAsync(command,seconds,maxBytes,ct);
                verifySelection();
                if(reply.Status=="failed" && reply.ExitCode is null || reply.Status=="timeout" && !reply.ConnectionEstablished)ConnectionLost=true;
                return reply;
            }
            catch { ConnectionLost=true;throw; }
        }
    }
}
