using System.Diagnostics;
using System.IO.Compression;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Research;

public sealed record ResearchText(string Ru,string En) { public string Text(bool english)=>english?En:Ru; }
public sealed record ResearchProfile(string Id,string FirmwareSHA256,string RouterSHA256,string Architecture);
public sealed record ResearchProbe(string Id,ResearchText Title,string Category,string Command,int TimeoutSeconds,int MaxBytes);
public sealed record ResearchRequirement(string Probe,string Fact,[property:System.Text.Json.Serialization.JsonPropertyName("equals")] string Expected,ResearchText Label,string[]? Platforms=null);
public sealed record ResearchFeature(string Id,ResearchText Title,string[] Profiles,ResearchRequirement[] Requirements,ResearchText Limitations,string[]? Platforms=null);
public sealed record ResearchSpec(int SchemaVersion,int Revision,ResearchProfile[] Profiles,ResearchProbe[] Probes,ResearchFeature[] Features)
{
    public const string ExpectedSpecificationSha256="f33227f1effbcfa22257739a354451d426015681810fb46f9ae1ebc7531cc939";
    public string? Sha256 { get; private set; }
    public static readonly JsonSerializerOptions Json=new() { PropertyNameCaseInsensitive=true,PropertyNamingPolicy=JsonNamingPolicy.CamelCase,WriteIndented=true };
    public static ResearchSpec Load(string path)
    {
        var bytes=ResearchReportFiles.ReadBoundedFile(path,512*1024);
        if(Convert.ToHexStringLower(SHA256.HashData(bytes))!=ExpectedSpecificationSha256)throw new InvalidDataException("Research specification SHA256 does not match this application build.");
        var spec=JsonSerializer.Deserialize<ResearchSpec>(bytes,Json)??throw new InvalidDataException("Invalid research specification.");
        spec.Validate();spec.Sha256=Convert.ToHexStringLower(SHA256.HashData(bytes)); return spec;
    }
    public void Validate()
    {
        if(SchemaVersion!=1 || Revision<1 || Probes.Length is <1 or >64 || Features.Length>32 || Probes.Select(x=>x.Id).Distinct().Count()!=Probes.Length)
            throw new InvalidDataException("Unsupported research specification.");
        foreach(var probe in Probes)
            if(!Regex.IsMatch(probe.Id,@"^[a-z][a-z0-9-]{0,63}$") || probe.MaxBytes is <1024 or >262144 || probe.TimeoutSeconds is <1 or >60 || probe.Command.Length is <1 or >65536 || probe.Command.Contains('\0'))
                throw new InvalidDataException("Invalid probe or capture limits.");
        foreach(var feature in Features)
            if(feature.Requirements.Any(r=>!Probes.Any(p=>p.Id==r.Probe)) || feature.Profiles.Any(p=>!Profiles.Any(x=>x.Id==p)))
                throw new InvalidDataException("Invalid feature requirements.");
    }
}
public sealed record ResearchProbeResult(string Id,ResearchText Title,string Category,string Command,string Status,int? ExitCode,string Stdout,string Stderr,long DurationMs,DateTimeOffset StartedAt,bool Truncated,IReadOnlyDictionary<string,string> Facts,int? LocalExitCode=null);
public sealed record ResearchFeatureResult(string Id,ResearchText Title,string State,ResearchText[] Reasons,ResearchText Limitations);
public sealed record ResearchProgress(int Completed,int Total,ResearchText Title);
public sealed record ResearchReport(int SchemaVersion,string Id,DateTimeOffset StartedAt,DateTimeOffset CompletedAt,string Outcome,string Channel,string? Profile,string ApplicationVersion,int SpecificationRevision,ResearchProbeResult[] Probes,ResearchFeatureResult[] Features,string[] Omissions,string? SpecificationSHA256=null,string RequestedMode="auto");

public sealed class ResearchRedactor(IEnumerable<string>? secrets=null)
{
    private readonly List<string> _secrets=(secrets??[]).Where(x=>x.Length>=3).Distinct().OrderByDescending(x=>x.Length).ToList();
    public void AddIdentifiers(IEnumerable<string> identifiers)=>_secrets.AddRange(identifiers.Where(x=>x.Length>=3));
    public string Clean(string value)
    {
        foreach(var secret in _secrets)value=value.Replace(secret,"[REDACTED]",StringComparison.Ordinal);
        value=Regex.Replace(value,@"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)","[PRIVATE KEY REDACTED]");
        value=Regex.Replace(value,@"(?im)(\b(?:password|passwd|passphrase|psk|key|token|cookie|auth|ssid|imei[12]?|imsi|iccid|serial(?:no)?|cid|boot_id|authorization|backup[_-]?key[_-]?suffix)\b[\""']?\s*[:=]\s*)(?:\""[^\""\r\n]*(?:\""|$)|'[^'\r\n]*(?:'|$)|[^\s,;\r\n]+)","$1[REDACTED]");
        value=Regex.Replace(value,@"(?i)\b(?:vless|vmess|trojan|ss)://[^\s\""<>]+","[VPN URL REDACTED]");
        value=Regex.Replace(value,@"(?i)(?<![a-f0-9])[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}(?![a-f0-9])","[UUID REDACTED]");
        value=Regex.Replace(value,@"(?i)(?<![a-f0-9])[a-f0-9]{32}(?![a-f0-9])","[CID REDACTED]");
        value=Regex.Replace(value,@"(?<![A-Za-z0-9])[0-9]{14,22}(?![A-Za-z0-9])","[IDENTIFIER REDACTED]");
        value=Regex.Replace(value,@"(?i)(?<![a-f0-9])(?:[a-f0-9]{2}:){5}[a-f0-9]{2}(?![a-f0-9])","[MAC REDACTED]");
        value=Regex.Replace(value,@"(?<![\d.])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?![\d.])","[IP REDACTED]");
        value=Regex.Replace(value,@"(?i)(?:[a-f0-9]{1,4}:){2,}[a-f0-9:]{0,39}","[IPv6 REDACTED]");
        value=Regex.Replace(value,@"(?im)^([^\s]+)(\s+(?:device|offline|unauthorized|no permissions)\b)","[ADB SERIAL REDACTED]$2");
        value=Regex.Replace(value,@"(?i)(?:C:\\Users\\[^\\\r\n]+|/Users/[^/\r\n]+)","[LOCAL USER]");
        return value;
    }
}

public sealed class FirmwareResearchEngine(ResearchSpec spec,IResearchTransportFactory factory,ResearchRedactor redactor)
{
    public const int TotalLimit=16*1024*1024;
    private readonly List<ResearchProbeResult> _results=[];
    private int _bytes;
    private IResearchShell? _shell;
    private string _outcome="complete";
    private static readonly IReadOnlyDictionary<string,string> NoFacts=new Dictionary<string,string>();
    private ResearchProbe Fingerprint=>spec.Probes.Single(p=>p.Id=="fingerprint");
    public async Task<ResearchReport> CollectAsync(string mode,string? boundCidHash,IProgress<ResearchProgress>? progress,CancellationToken ct)
    {
        spec.Validate(); var started=DateTimeOffset.UtcNow;
        try
        {
            await SelectAsync(mode,boundCidHash,ct).ConfigureAwait(false);
            if(_shell is not null)
            {
                var initial=await ProbeAsync(Fingerprint,ct).ConfigureAwait(false); _results.Add(initial);
                var binding=Binding(initial);
                if(binding.Count!=2) { _outcome="partial"; AddIssue("identity-unavailable","Both stable CID and boot fingerprints are required; further probes skipped.");
                    var identity=spec.Probes.SingleOrDefault(p=>p.Id=="identity");if(identity is not null)_results.Add(await ProbeAsync(identity,ct).ConfigureAwait(false)); }
                else if(boundCidHash is not null && binding.GetValueOrDefault("cid_sha256")!=boundCidHash) { _outcome="device_changed";AddIssue("saved-identity-mismatch","USB device does not match the saved modem CID."); }
                else
                {
                    foreach(var probe in spec.Probes.Where(p=>p.Id!="fingerprint"))
                    {
                        if(ct.IsCancellationRequested) { _outcome="cancelled";break; }
                        if(_bytes> TotalLimit-524288) { _outcome="partial"; AddIssue("total-limit","Report byte limit reached.");break; }
                        var guard=await ProbeAsync(Fingerprint,ct).ConfigureAwait(false);
                        if(!SameBinding(binding,Binding(guard))) { _results.Add(guard with {Id="fingerprint-change-before-"+probe.Id});_outcome=ct.IsCancellationRequested?"cancelled":guard.Status=="success"?"device_changed":"connection_lost";break; }
                        progress?.Report(new(spec.Probes.Count(p=>_results.Any(r=>r.Id==p.Id)),spec.Probes.Length,probe.Title));
                        var result=await ProbeAsync(probe,ct).ConfigureAwait(false);_results.Add(result);
                        if(result.Status=="cancelled") { _outcome="cancelled";break; }
                        var after=await ProbeAsync(Fingerprint,ct).ConfigureAwait(false);
                        if(!SameBinding(binding,Binding(after))) { _results.Add(after with {Id="fingerprint-change-after-"+probe.Id});_outcome=ct.IsCancellationRequested?"cancelled":after.Status=="success"?"device_changed":"connection_lost";break; }
                    }
                }
            }
        }
        catch(SshTrustException error) { _outcome="trust_rejected";AddIssue("ssh-trust-rejected",error.Message); }
        catch(OperationCanceledException) { _outcome="cancelled"; }
        catch(Exception error) { _outcome="partial";AddIssue("collection-error",error.GetType().Name+": "+error.Message); }
        foreach(var probe in spec.Probes.Where(p=>!_results.Any(r=>r.Id==p.Id)))
            _results.Add(new(probe.Id,probe.Title,probe.Category,probe.Command,"skipped",null,"","Not collected: "+_outcome,0,DateTimeOffset.UtcNow,false,NoFacts));
        if(_outcome=="complete" && _results.Any(x=>x.Status!="success"))_outcome="partial";
        var profile=MatchProfile(spec,_results);
        var features=Evaluate(spec,_results,profile,_outcome);
        return new(1,Guid.NewGuid().ToString("N"),started,DateTimeOffset.UtcNow,_outcome,_shell?.Channel??"none",profile,
            typeof(FirmwareResearchEngine).Assembly.GetName().Version?.ToString()??"unknown",spec.Revision,_results.ToArray(),features,
            ["Read-only prerequisite survey; no operation is executed or certified compatible.","No passwords, private keys, raw NV/EFS, configuration backups or personal traffic are collected.","CID and boot identifiers are hashed on device; fingerprint absence stops collection.","No ADB activation, no SSH trust enrollment, no preparation, upload, install, remount or firmware check bypass.","Full restore is not implemented on Windows; only available prerequisites are assessed."],spec.Sha256,mode);
    }
    private async Task SelectAsync(string mode,string? boundCidHash,CancellationToken ct)
    {
        var automatic=mode!="SSH" && mode!="ADB";
        if(mode!="ADB" && factory.SshConfigured)
        {
            try
            {
                var ssh=factory.OpenSsh();
                var probe=new ResearchProbe("ssh-attempt",new("Проверка SSH","SSH attempt"),"connection","id -u",10,16384);
                _shell=ssh; var sshWatch=Stopwatch.StartNew(); var reply=await ssh.ExecuteAsync(probe.Command,probe.TimeoutSeconds,probe.MaxBytes,ct).ConfigureAwait(false);var result=ToResult(probe,reply,sshWatch.ElapsedMilliseconds);_results.Add(result);
                if(result.Status=="success")return;
                _shell=null;
                // A command failure means SSH did connect: never silently switch devices.
                if(result.Status!="timeout" || reply.ConnectionEstablished || !automatic)throw new IOException("SSH research attempt failed; inspect connection evidence.");
            }
            catch(Exception error) when(automatic && SafeUnavailable(error)) { _shell=null;AddIssue("ssh-unavailable",error.GetType().Name+": "+error.Message); }
        }
        else if(mode=="SSH")throw new InvalidOperationException("SSH research requires a configured private key and pinned known_hosts.");
        else if(mode!="ADB")AddIssue("ssh-not-configured","No configured key and known_hosts pair; trying USB ADB.","skipped");
        if(mode=="SSH")return;
        var watch=Stopwatch.StartNew();var list=await factory.ListAdbAsync(ct).ConfigureAwait(false);
        _results.Add(ToResult(new("adb-devices",new("Устройства ADB","ADB devices"),"connection","adb devices -l",15,65536),list,watch.ElapsedMilliseconds));
        if(list.Status!="success")throw new IOException("Cannot enumerate USB ADB devices; see preserved ADB output.");
        var serials=ParseAdb(list.Stdout);
        if(serials.Count==0)throw new IOException("No authorized USB ADB device. See ADB list for offline/unauthorized state.");
        redactor.AddIdentifiers(serials);
        if(serials.Count==1)
        {
            var usbWatch=Stopwatch.StartNew();var usb=await factory.SingleUsbSerialAsync(ct).ConfigureAwait(false);
            _results.Add(ToResult(new("adb-usb-proof",new("Проверка USB ADB","USB ADB proof"),"connection","adb -d get-serialno",10,16384),usb,usbWatch.ElapsedMilliseconds));
            if(usb.Status!="success" || usb.Stdout.Trim()!=serials[0])throw new IOException("ADB device is not confirmed as the single USB device; collection stopped.");
            _shell=factory.OpenAdb(serials[0]);return;
        }
        if(string.IsNullOrEmpty(boundCidHash))throw new IOException("Multiple USB ADB devices: selection is ambiguous. Leave only the intended modem connected.");
        IResearchShell? selected=null;
        foreach(var serial in serials)
        {
            var candidate=factory.OpenAdb(serial);var watchCandidate=Stopwatch.StartNew();var result=await candidate.ExecuteAsync(Fingerprint.Command,Fingerprint.TimeoutSeconds,Fingerprint.MaxBytes,ct).ConfigureAwait(false);
            _results.Add(ToResult(Fingerprint with {Id="adb-candidate-"+_results.Count},result,watchCandidate.ElapsedMilliseconds));
            var facts=Facts(result);
            if(result.Status=="success" && facts.GetValueOrDefault("cid_sha256")==boundCidHash) { if(selected is not null)throw new IOException("Multiple devices match the saved identity.");selected=candidate; }
        }
        _shell=selected??throw new IOException("No USB device matches the saved modem identity.");
    }
    private static bool SafeUnavailable(Exception e)=>e is not SshTrustException && e is not Renci.SshNet.Common.SshAuthenticationException && e is not InvalidDataException && (e is SocketException or TimeoutException || e.InnerException is SocketException);
    public static string HashSavedCid(string cid)=>Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(cid.Trim()+"\n")));
    public static IReadOnlyList<string> ParseAdb(string text)
    {
        var devices=new List<string>();
        foreach(var line in text.Split('\n'))
        {
            var fields=line.Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries);
            if(fields.Length<2 || fields[1]!="device")continue;
            // ADB over TCP and emulators must never be silently chosen as the modem.
            if(!Regex.IsMatch(fields[0],@"^[A-Za-z0-9._-]{1,256}$") || fields[0].StartsWith("emulator-",StringComparison.Ordinal) || fields[0].Contains("_adb-",StringComparison.Ordinal) || fields[0].Contains("_tcp",StringComparison.Ordinal))continue;
            if(devices.Contains(fields[0]))throw new InvalidDataException("Duplicate ADB serial.");devices.Add(fields[0]);
        }
        return devices;
    }
    private async Task<ResearchProbeResult> ProbeAsync(ResearchProbe probe,CancellationToken ct)
    {
        var watch=Stopwatch.StartNew(); ResearchCommandResult value;
        try { value=await _shell!.ExecuteAsync(probe.Command,probe.TimeoutSeconds,probe.MaxBytes,ct).ConfigureAwait(false); }
        catch(SshTrustException) { throw; }
        catch(OperationCanceledException) { value=new("cancelled",null,"","Cancelled."); }
        catch(Exception error) { value=new("failed",null,"",error.GetType().Name+": "+error.Message); }
        return ToResult(probe,value,watch.ElapsedMilliseconds);
    }
    private ResearchProbeResult ToResult(ResearchProbe probe,ResearchCommandResult value,long duration)
    {
        var output=redactor.Clean(value.Stdout);var error=redactor.Clean(value.Stderr);var facts=Facts(value).ToDictionary(x=>x.Key,x=>redactor.Clean(x.Value));
        _bytes+=Encoding.UTF8.GetByteCount(output)+Encoding.UTF8.GetByteCount(error);
        return new(probe.Id,probe.Title,probe.Category,probe.Command,value.Status,value.ExitCode,output,error,duration,DateTimeOffset.UtcNow.AddMilliseconds(-duration),value.Truncated,facts,value.LocalExitCode);
    }
    private void AddIssue(string id,string detail,string status="failed")=>_results.Add(new(id,new("Подключение / сбор","Connection / collection"),"connection","",status,null,"",redactor.Clean(detail),0,DateTimeOffset.UtcNow,false,NoFacts));
    public static Dictionary<string,string> Facts(ResearchCommandResult value)
    {
        var facts=new Dictionary<string,string>();
        foreach(Match m in Regex.Matches(value.Stdout,@"(?m)^FR_FACT ([a-z0-9_]+)=([^\r\n]{0,512})\r?$"))
            if(!facts.TryAdd(m.Groups[1].Value,m.Groups[2].Value))facts[m.Groups[1].Value]="conflicting";
        return facts;
    }
    private static Dictionary<string,string> Binding(ResearchProbeResult result)=>result.Status=="success"
        ?result.Facts.Where(x=>x.Key is "cid_sha256" or "boot_sha256" && Regex.IsMatch(x.Value,@"^[a-f0-9]{64}$")).ToDictionary(x=>x.Key,x=>x.Value):[];
    private static bool SameBinding(Dictionary<string,string> before,Dictionary<string,string> after)=>before.Count>0 && before.Count==after.Count && before.All(x=>after.GetValueOrDefault(x.Key)==x.Value);
    public static string? MatchProfile(ResearchSpec spec,IReadOnlyList<ResearchProbeResult> results)
    {
        string? Fact(string probe,string fact)=>results.SingleOrDefault(p=>p.Id==probe && p.Status=="success")?.Facts.GetValueOrDefault(fact);
        return spec.Profiles.SingleOrDefault(p=>p.Architecture==Fact("identity","architecture") && p.FirmwareSHA256==Fact("firmware-hashes","firmware_sha256") && p.RouterSHA256==Fact("firmware-hashes","router_sha256"))?.Id;
    }
    public static ResearchFeatureResult[] Evaluate(ResearchSpec spec,IReadOnlyList<ResearchProbeResult> results,string? profile,string outcome)
    {
        return spec.Features.Select(feature=>
        {
            var reasons=new List<ResearchText>();var blocked=false;var unknown=false;
            if(feature.Platforms is {Length:>0} && !feature.Platforms.Contains("windows")) { blocked=true;reasons.Add(new("Функция не реализована в Windows.","This operation is not implemented on Windows.")); }
            if(feature.Profiles.Length>0 && profile is null) { unknown=true;reasons.Add(new("Профиль прошивки не подтверждён для этой операции.","Firmware profile is not confirmed for this operation.")); }
            else if(feature.Profiles.Length>0 && !feature.Profiles.Contains(profile!)) { blocked=true;reasons.Add(new("Известная прошивка не поддерживается установщиком этой операции.","This known firmware is not supported by the operation installer.")); }
            foreach(var requirement in feature.Requirements.Where(r=>r.Platforms is not {Length:>0} || r.Platforms.Contains("windows")))
            {
                var probe=results.SingleOrDefault(x=>x.Id==requirement.Probe);
                if(probe?.Status!="success" || !probe.Facts.TryGetValue(requirement.Fact,out var actual)) { unknown=true;reasons.Add(requirement.Label); }
                else if(actual is "not-assessed" or "not-performed" or "unknown" or "conflicting") { unknown=true;reasons.Add(requirement.Label); }
                else if(actual!=requirement.Expected) { blocked=true;reasons.Add(requirement.Label); }
            }
            if(outcome is "device_changed" or "cancelled" or "connection_lost" or "trust_rejected") { unknown=true;reasons.Add(new("Сбор прерван; вывод требует повторной проверки.","Collection was interrupted; conclusions need a new survey.")); }
            return new ResearchFeatureResult(feature.Id,feature.Title,blocked?"blocked":unknown?"unknown":"prerequisites_met",reasons.ToArray(),feature.Limitations);
        }).ToArray();
    }
}

public static class ResearchReportFiles
{
    private static void EnsureSafePath(string path)
    {
        foreach(var candidate in new[]{path,Path.GetDirectoryName(path)!})
            if((File.Exists(candidate)||Directory.Exists(candidate)) && (File.GetAttributes(candidate)&FileAttributes.ReparsePoint)!=0)
                throw new InvalidDataException("Research files cannot use links or reparse points.");
    }
    public static byte[] ReadBoundedFile(string path,int maximum)
    {
        EnsureSafePath(path);
        using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);
        if(input.Length>maximum)throw new InvalidDataException("Research file exceeds size limit.");
        using var output=new MemoryStream();var buffer=new byte[8192];int count;
        while((count=input.Read(buffer))>0) { if(output.Length+count>maximum)throw new InvalidDataException("Research file exceeds size limit.");output.Write(buffer,0,count); }
        return output.ToArray();
    }
    public static void Save(ResearchReport report,string path)
    {
        var data=JsonSerializer.SerializeToUtf8Bytes(report,ResearchSpec.Json);
        if(data.Length>FirmwareResearchEngine.TotalLimit)throw new InvalidDataException("Sanitized report exceeds the size limit.");
        EnsureSafePath(path);Directory.CreateDirectory(Path.GetDirectoryName(path)!);EnsureSafePath(path);var temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try { using(var stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None))stream.Write(data);File.Move(temporary,path,true); }
        finally { if(File.Exists(temporary))File.Delete(temporary); }
    }
    public static ResearchReport? Load(string path)
    {
        if(!File.Exists(path))return null;
        if(new FileInfo(path).Length>FirmwareResearchEngine.TotalLimit)throw new InvalidDataException("Saved report exceeds the size limit.");
        var report=JsonSerializer.Deserialize<ResearchReport>(ReadBoundedFile(path,FirmwareResearchEngine.TotalLimit),ResearchSpec.Json);
        if(report?.SchemaVersion!=1)throw new InvalidDataException("Unsupported saved research report.");return report;
    }
    public static void Export(ResearchReport report,string destination)
    {
        var files=new SortedDictionary<string,byte[]> { ["report.json"]=JsonSerializer.SerializeToUtf8Bytes(report,ResearchSpec.Json),
            ["REPORT_RU.md"]=Encoding.UTF8.GetBytes(Markdown(report,false)),["REPORT_EN.md"]=Encoding.UTF8.GetBytes(Markdown(report,true)),
            ["app-context.json"]=JsonSerializer.SerializeToUtf8Bytes(new {platform="windows",report.ApplicationVersion,report.SpecificationRevision,report.SpecificationSHA256,report.RequestedMode,runtime=System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,architecture=System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),report.StartedAt,report.CompletedAt,report.Channel,report.Outcome},ResearchSpec.Json) };
        foreach(var probe in report.Probes)
        {
            if(!Regex.IsMatch(probe.Id,@"^[a-z][a-z0-9-]{0,127}$"))throw new InvalidDataException("Unsafe probe report path.");
            files["probes/"+probe.Id+".txt"]=Encoding.UTF8.GetBytes($"Status: {probe.Status}\nRemote exit: {probe.ExitCode}\nLocal exit: {probe.LocalExitCode}\nDuration ms: {probe.DurationMs}\nTruncated: {probe.Truncated}\nCommand:\n{probe.Command}\n\nSTDOUT:\n{probe.Stdout}\n\nSTDERR:\n{probe.Stderr}\n");
        }
        if(files.Values.Sum(x=>(long)x.Length)>FirmwareResearchEngine.TotalLimit)throw new InvalidDataException("Export exceeds its size limit.");
        var manifest=files.Select(x=>new {path=x.Key,bytes=x.Value.Length,sha256=Convert.ToHexStringLower(SHA256.HashData(x.Value))}).ToArray();
        files["manifest.json"]=JsonSerializer.SerializeToUtf8Bytes(new {schemaVersion=1,files=manifest,omissions=report.Omissions},ResearchSpec.Json);
        var temp=destination+"."+Guid.NewGuid().ToString("N")+".tmp";
        try { using(var zip=ZipFile.Open(temp,ZipArchiveMode.Create))foreach(var file in files) { using var stream=zip.CreateEntry(file.Key,CompressionLevel.Optimal).Open();stream.Write(file.Value); }File.Move(temp,destination,true); }
        finally { if(File.Exists(temp))File.Delete(temp); }
    }
    public static string Markdown(ResearchReport report,bool en)
    {
        var text=new StringBuilder(en?"# Firmware research\n\n":"# Исследование прошивки\n\n");
        text.AppendLine($"{report.StartedAt:O} → {report.CompletedAt:O}\n\n{report.Channel} · {report.Outcome} · {report.Profile??"unknown firmware"}\n");
        text.AppendLine(en?"This is a read-only prerequisite survey, not proof that a write operation works. No diagnostic action changes firmware support or disables existing checks.\n":"Это проверка предпосылок только чтением, а не доказательство работы изменяющей операции. Исследование не расширяет поддержку прошивок и не отключает проверки.\n");
        foreach(var feature in report.Features) { text.AppendLine($"## {feature.Title.Text(en)} — {feature.State}\n");foreach(var reason in feature.Reasons)text.AppendLine("- "+reason.Text(en));text.AppendLine("\n"+feature.Limitations.Text(en)+"\n"); }
        text.AppendLine(en?"## Probe results\n":"## Результаты проверок\n");
        foreach(var probe in report.Probes)text.AppendLine($"- {probe.Id}: {probe.Status}; exit={probe.ExitCode}; {probe.DurationMs} ms; truncated={probe.Truncated}");
        text.AppendLine("\n## Omissions\n");foreach(var omission in report.Omissions)text.AppendLine("- "+omission);
        return text.ToString();
    }
}
