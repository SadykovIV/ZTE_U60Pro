using System.IO.Compression;
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
            VerifySelection();
            return await FirmwareSupportCollector.CollectAsync(shell,selected,stream,helper,host,destination,work,activity,version,ct,VerifySelection);
        }
        finally { if(File.Exists(activityZip))File.Delete(activityZip); }
    }
}
