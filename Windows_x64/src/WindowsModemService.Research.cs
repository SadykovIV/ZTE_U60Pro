using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Research;

namespace ZteImeiStudio.Windows;
public sealed partial class WindowsModemService
{
    private string ResearchPath=>Path.Combine(_storage,"FirmwareResearch","latest.json");
    public Task<ResearchReport?> GetFirmwareResearchAsync(CancellationToken ct=default)
    {
        try { return Task.FromResult(ResearchReportFiles.Load(ResearchPath)); }
        catch { return Task.FromResult<ResearchReport?>(null); }
    }
    public async Task<ResearchReport> CollectFirmwareResearchAsync(IReadOnlyDictionary<string,string> parameters,IProgress<ResearchProgress>? progress,CancellationToken ct=default)
    {
        if(!await _operation.WaitAsync(0,ct))throw new InvalidOperationException("Другая операция уже выполняется.");
        try
        {
            var host=Param(parameters,"host",_host);if(string.IsNullOrWhiteSpace(host))host=_host;
            var key=Param(parameters,"key_path",KeyPath);if(string.IsNullOrWhiteSpace(key))key=KeyPath;
            var known=Param(parameters,"known_hosts_path",KnownHostsPath);if(string.IsNullOrWhiteSpace(known))known=KnownHostsPath;
            var mode=Param(parameters,"mode","Автоматически");
            var spec=ResearchSpec.Load(Path.Combine(_resources,"FirmwareResearch","probes.json"));
            var factory=new ResearchTransportFactory(host,_port,key,known,_adb.ExecutablePath);
            var secrets=parameters.Where(p=>p.Key.Contains("password",StringComparison.Ordinal)||p.Key=="backup_key_suffix").Select(p=>p.Value);
            var engine=new FirmwareResearchEngine(spec,factory,new ResearchRedactor(secrets));
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(ct);deadline.CancelAfter(TimeSpan.FromMinutes(8));
            var boundCid=_adbCid??(host==_host?_snapshot.Serial:null);
            boundCid=ReadPendingResearchCid(boundCid);
            var cidHash=boundCid is {Length:32} && boundCid.All(Uri.IsHexDigit)?FirmwareResearchEngine.HashSavedCid(boundCid):null;
            var report=await engine.CollectAsync(mode,cidHash,progress,deadline.Token).ConfigureAwait(false);
            if(deadline.IsCancellationRequested && !ct.IsCancellationRequested)report=report with { Outcome="time_limit",Omissions=report.Omissions.Append("Collection stopped at the eight-minute time limit; partial evidence is retained.").ToArray() };
            ResearchReportFiles.Save(report,ResearchPath);
            Log("research","Firmware research snapshot saved: "+report.Outcome);
            return report;
        }
        finally { _operation.Release(); }
    }
    private string? ReadPendingResearchCid(string? connectedCid)
    {
        foreach (var name in new[] { "setup-pending.json", "adb-access-pending.json" })
        {
            var path=Path.Combine(_storage,name);
            if (!File.Exists(path)) continue;
            var pending=JsonSerializer.Deserialize<OnboardingPending>(File.ReadAllBytes(path))
                ?? throw new InvalidDataException("Не удалось прочитать идентичность незавершённой операции.");
            if (pending.Intent != (name == "adb-access-pending.json" ? "diagnostic-adb" : "preparation"))
                throw new InvalidDataException("Назначение журнала не совпало с незавершённой операцией.");
            if (pending.Cid is not { } cid) continue;
            if (cid.Length != 32 || !cid.All(Uri.IsHexDigit) || connectedCid is not null && !cid.Equals(connectedCid,StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Сохранённая идентичность относится к другому модему.");
            connectedCid=cid.ToLowerInvariant();
        }
        return connectedCid;
    }

    public Task ExportFirmwareResearchAsync(ResearchReport report,string destination,CancellationToken ct=default)
    {
        ct.ThrowIfCancellationRequested();ResearchReportFiles.Export(report,destination);return Task.CompletedTask;
    }
}
