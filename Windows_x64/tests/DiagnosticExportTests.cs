using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows;
using ZteImeiStudio.Windows.Diagnostics;
using ZteImeiStudio.Windows.Research;

internal static class DiagnosticExportTests
{
    public static async Task Main(string[] args)
    {
        var root = Path.GetFullPath(args.Single()); Directory.CreateDirectory(root);
        int passed = 0;
        void Check(bool yes, string name) { if (!yes) throw new Exception("FAIL " + name); Console.WriteLine("PASS " + name); passed++; }
        Dictionary<string, byte[]> ReadZip(string path)
        {
            using var zip = ZipFile.OpenRead(path);
            return zip.Entries.ToDictionary(x => x.FullName, x => { using var input=x.Open();using var output=new MemoryStream();input.CopyTo(output);return output.ToArray(); });
        }
        var privacy = new DiagnosticPrivacy();
        var secret = "synthetic-private-password-42";
        var suffix = "synthetic-private-backup-suffix";
        privacy.Remember([secret,suffix,"a\"b\\c"]);
        var original = "Preparing SSH: detail remains useful\n" + secret + "\n" + suffix + "\n{\"password\":\"a\\\"b\\\\c\"}\nLPA:1$example.com$synthetic-matching-id\nAuthorization: Bearer synthetic-token\nCookie: first=value; second=synthetic-cookie\n-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic-key-body\n-----END OPENSSH PRIVATE KEY-----\nvless://synthetic-profile@host\nconfirmation_code: synthetic-confirmation\n";
        var cleaned = privacy.Clean(original);
        Check(privacy.Clean("version text 1.24.5.0 address 192.0.2.7").Contains("[IP REDACTED]") && !privacy.CleanApplicationVersion("1.24.5.0\nprivate 192.0.2.7").Contains("192.0.2.7"),"version exception cannot affect arbitrary text or injected multiline metadata");
        var versionPrivacy=new DiagnosticPrivacy();versionPrivacy.Remember(["1.24.5.0"]);
        Check(!versionPrivacy.CleanApplicationVersion("1.24.5.0").Contains("1.24.5.0"),"known private values remain redacted even in a version field");
        var versionFiles=ReadZip(DiagnosticsExporter.Export(root,Path.Combine(root,"version.zip"),new(null,null,null,"1.24.5.0"),[],privacy).Path);
        using(var version=JsonDocument.Parse(versionFiles["report.json"]))Check(version.RootElement.GetProperty("applicationVersion").GetString()=="1.24.5.0","structured application version is preserved rather than redacted as an IP");
        Check(cleaned.Contains("detail remains useful") && new[]{secret,suffix,"synthetic-matching-id","synthetic-token","synthetic-cookie","synthetic-key-body","synthetic-profile","synthetic-confirmation","a\\\"b"}.All(x=>!cleaned.Contains(x)), "secret, escaped credentials, LPA, confirmation, key and profile redaction");
        Check(!privacy.Clean("Download failed for https://user:URL_PRIVATE_CANARY@example.com/private-subscription and https://example.com/OPAQUE_SUBSCRIPTION_CANARY").Contains("CANARY"),"URL credentials and opaque subscription paths are hidden even without known inputs");
        DiagnosticsExporter.Append(root,new(DateTimeOffset.UtcNow,"info",original),privacy);
        var journalPath=Path.Combine(root,"Diagnostics","Application","activity.jsonl");
        Check(!File.ReadAllText(journalPath).Contains(secret) && !File.ReadAllText(journalPath).Contains("synthetic-matching-id"),"journal is sanitized before persistence");
        var eventTime=DateTimeOffset.UtcNow;
        DiagnosticsExporter.Append(root,new(eventTime,"error","RefreshAgent: fixed useful failure detail","operation","RefreshAgent","failed",321),privacy);
        foreach(var relative in new[]{"SSH/id_ed25519","SSH/known_hosts","connection.json","Backups/private.bin","VPN/profile.yaml","Diagnostics/raw-stdout.txt","FirmwareResearch/latest.json"})
        {var path=Path.Combine(root,relative);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,"EXCLUDED_PRIVATE_FILE_CANARY");}
        var path1=Path.Combine(root,"diagnostic.zip");
        var result=DiagnosticsExporter.Export(root,path1,new(null,"Synthetic modem","Unknown firmware","1.24.test"),[new(eventTime,"info","Program action: full details after colon")],privacy);
        var files=ReadZip(path1);var text=string.Join('\n',files.Values.Select(Encoding.UTF8.GetString));
        Check(files.Keys.Order().SequenceEqual(new[]{"README.txt","application-journal.jsonl","current-session.jsonl","manifest.json","operation-traces.jsonl","report.json"}.Order()),"ZIP contains only six fixed diagnostic entries");
        Check(text.Contains("full details after colon") && text.Contains("fixed useful failure detail") && text.Contains("Preparing SSH"),"full program actions and errors survive export");
        Check(!text.Contains("EXCLUDED_PRIVATE_FILE_CANARY") && !text.Contains(secret) && !text.Contains(suffix),"sensitive storage files and known secrets excluded");
        using(var report=JsonDocument.Parse(files["report.json"]))
            Check(report.RootElement.GetProperty("schema").GetInt32()==1 && report.RootElement.GetProperty("model").GetString()=="Synthetic modem" && report.RootElement.TryGetProperty("operations",out _),"previous system-summary JSON remains in bundle");
        using(var manifest=JsonDocument.Parse(files["manifest.json"]))
        {
            Check(!manifest.RootElement.GetProperty("collectedFromModem").GetBoolean(),"bundle explicitly marks no modem collection");
            Check(manifest.RootElement.GetProperty("files").EnumerateArray().All(e=>e.GetProperty("sha256").GetString()==Convert.ToHexStringLower(SHA256.HashData(files[e.GetProperty("path").GetString()!])) && e.GetProperty("bytes").GetInt32()==files[e.GetProperty("path").GetString()!].Length),"all ZIP payload hashes and lengths verify");
        }
        Check(Encoding.UTF8.GetString(files["operation-traces.jsonl"]).Contains("\"durationMs\":321"),"structured operation outcome and elapsed time exported without commands");
        var beforeHash=Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path1)));
        try {DiagnosticsExporter.Export(root,path1,new(null,null,null,"test"),[],privacy);Check(false,"existing ZIP not overwritten");}catch(IOException){Check(beforeHash==Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path1))),"existing ZIP not overwritten");}
        using(var cancel=new CancellationTokenSource())
        {cancel.Cancel();try{DiagnosticsExporter.Export(root,Path.Combine(root,"cancelled.zip"),new(null,null,null,"test"),[],privacy,ct:cancel.Token);Check(false,"cancelled export refused");}catch(OperationCanceledException){Check(!File.Exists(Path.Combine(root,"cancelled.zip")),"cancelled export produces no archive");}}
        File.AppendAllText(journalPath,"not-json\n{\"timestamp\":\"2026-10-05T00:00:00Z\",\"level\":\"info\",\"message\":\"benign saved event\",\"unknownSecretField\":\"DO_NOT_EXPORT_UNKNOWN_FIELD\",\"operation\":\"PrivateOperationCanary\"}\n");
        var malformed=DiagnosticsExporter.Export(root,Path.Combine(root,"malformed.zip"),new(null,null,null,"test"),[],privacy);
        var malformedFiles=ReadZip(malformed.Path);
        Check(malformed.Omissions>=1 && new[]{"DO_NOT_EXPORT_UNKNOWN_FIELD","PrivateOperationCanary"}.All(x=>!string.Join('\n',malformedFiles.Values.Select(Encoding.UTF8.GetString)).Contains(x)),"malformed events noted and unknown JSON fields/operation labels never copied");
        var linkRoot=Path.Combine(root,"link-test");Directory.CreateDirectory(Path.Combine(linkRoot,"Diagnostics","Application"));
        var sensitive=Path.Combine(root,"sensitive-target");File.WriteAllText(sensitive,"PRIVATE_LINK_CANARY");
        File.CreateSymbolicLink(Path.Combine(linkRoot,"Diagnostics","Application","activity.jsonl"),sensitive);
        var linked=DiagnosticsExporter.Export(linkRoot,Path.Combine(root,"links.zip"),new(null,null,null,"test"),[],privacy);
        Check(linked.Omissions>=1 && !string.Join('\n',ReadZip(linked.Path).Values.Select(Encoding.UTF8.GetString)).Contains("PRIVATE_LINK_CANARY"),"linked activity segment is omitted without reading target");
        var bigRoot=Path.Combine(root,"oversize-test");Directory.CreateDirectory(Path.Combine(bigRoot,"Diagnostics","Application"));
        File.WriteAllBytes(Path.Combine(bigRoot,"Diagnostics","Application","activity.jsonl"),new byte[DiagnosticsExporter.SegmentLimit+1]);
        Check(DiagnosticsExporter.Export(bigRoot,Path.Combine(root,"oversize.zip"),new(null,null,null,"test"),[],privacy).Omissions>=1,"oversized journal safely omitted and reported");
        var rotationRoot=Path.Combine(root,"rotation-test");Directory.CreateDirectory(Path.Combine(rotationRoot,"Diagnostics","Application"));
        File.WriteAllBytes(Path.Combine(rotationRoot,"Diagnostics","Application","activity.jsonl"),new byte[DiagnosticsExporter.SegmentLimit]);
        DiagnosticsExporter.Append(rotationRoot,new(eventTime,"info","new bounded segment"),privacy);
        Check(new FileInfo(Path.Combine(rotationRoot,"Diagnostics","Application","activity.previous.jsonl")).Length==DiagnosticsExporter.SegmentLimit && new FileInfo(Path.Combine(rotationRoot,"Diagnostics","Application","activity.jsonl")).Length<16384,"journal rotates at fixed bound");
        // Actual service dispatch: no SSH connection, no ADB process, no resources.
        var serviceRoot=Path.Combine(root,"service");var service=new WindowsModemService(serviceRoot,Path.Combine(root,"no-resources"));
        var rejected=await service.RunAsync(new(ModemOperation.RefreshAgent,new Dictionary<string,string>{{"agent_password",secret}}));
        Check(!rejected.Success,"disconnected action records its real failure");
        var log=typeof(WindowsModemService).GetMethod("Log",BindingFlags.NonPublic|BindingFlags.Instance)!;
        log.Invoke(service,["warning","PrepareSsh: useful detail; private input was "+secret]);
        var exported=await service.RunAsync(new(ModemOperation.ExportDiagnostics));
        Check(exported.Success && !(await service.GetDeviceSnapshotAsync()).IsConnected,"actual ExportDiagnostics dispatcher succeeds offline");
        var serviceZip=Directory.GetFiles(Path.Combine(serviceRoot,"Diagnostics"),"*.zip").Single();
        var serviceText=string.Join('\n',ReadZip(serviceZip).Values.Select(Encoding.UTF8.GetString));
        Check(serviceText.Contains("RefreshAgent") && serviceText.Contains("useful detail") && !serviceText.Contains(secret),"actual logger redacts supplied parameters and exports detailed actions");
        var restarted=new WindowsModemService(serviceRoot,Path.Combine(root,"no-resources"));
        Check((await restarted.RunAsync(new(ModemOperation.ExportDiagnostics))).Success,"offline export works after application restart");
        var newest=Directory.GetFiles(Path.Combine(serviceRoot,"Diagnostics"),"*.zip").Single(p=>p!=serviceZip);
        Check(Encoding.UTF8.GetString(ReadZip(newest)["application-journal.jsonl"]).Contains("useful detail"),"previous-session actions included after restart");
        var damagedRoot=Path.Combine(root,"damaged-service");Directory.CreateDirectory(Path.Combine(damagedRoot,"Diagnostics","Application"));
        File.CreateSymbolicLink(Path.Combine(damagedRoot,"Diagnostics","Application","activity.jsonl"),sensitive);
        var damaged=new WindowsModemService(damagedRoot,Path.Combine(root,"no-resources"));
        Check(!(await damaged.RunAsync(new(ModemOperation.RefreshAgent))).Success,"journal write failure does not escape the normal operation failure path");
        var damagedResult=await damaged.RunAsync(new(ModemOperation.ExportDiagnostics));
        Check(damagedResult.Success && File.ReadAllText(sensitive)=="PRIVATE_LINK_CANARY","next operation acquires released semaphore; unsafe journal remains untouched");
        var damagedZip=ReadZip(Directory.GetFiles(Path.Combine(damagedRoot,"Diagnostics"),"*.zip").Single());
        Check(Encoding.UTF8.GetString(damagedZip["manifest.json"]).Contains("could not be persisted"),"persistence failure is explicit in archive omissions");
        try { await restarted.CollectFirmwareResearchAsync(new Dictionary<string,string>(),null); Check(false,"missing research resource refuses before network"); }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        { Check((await restarted.GetLogsAsync()).Any(x=>x.Message=="Firmware research: failed"),"research failure is recorded before any transport use"); }
        Check((await restarted.RunAsync(new(ModemOperation.ExportDiagnostics))).Success,"research failure releases service semaphore for offline export");
        var research=new ResearchReport(1,"synthetic-report",eventTime,eventTime,"complete","none",null,"test",7,[],[],[]);
        await restarted.ExportFirmwareResearchAsync(research,Path.Combine(root,"synthetic-research.zip"));
        Check((await restarted.GetLogsAsync()).Any(x=>x.Message=="Firmware research export: completed"),"research export action recorded without destination data");
        var combinedRoot=Path.Combine(root,"combined");
        var cachedPath=Path.Combine(combinedRoot,"FirmwareResearch","latest.json");
        var cachedTime=new DateTimeOffset(2026,9,1,1,2,3,TimeSpan.Zero);
        var factualHash=new string('a',64);
        var cachedReport=new ResearchReport(1,"cached-synthetic-report",cachedTime,cachedTime.AddMinutes(1),"complete","SSH",null,"1.24.5.0",7,
            [new("identity",new("Система","System"),"platform","uname -s","success",0,"Linux\npassword="+secret+"\nLPA:1$example.com$CACHE_ACTIVATION_PRIVATE\nFR_FACT firmware_sha256="+factualHash,"",12,cachedTime,false,new Dictionary<string,string>{{"firmware_sha256",factualHash},{"os","Linux"},{"detail",secret},{"activation_code","UNKNOWN_CACHED_ACTIVATION_PRIVATE"},{"token_hash",new string('b',64)},{"activation_code_sha256",new string('c',64)},{"password_sha256",new string('d',64)},{"secret_hash",new string('e',64)}})],[],[],factualHash);
        ResearchReportFiles.Save(cachedReport,cachedPath);
        DiagnosticsExporter.Append(combinedRoot,new(eventTime,"info","Combined program action"),privacy);
        var combined=DiagnosticsExporter.Export(combinedRoot,Path.Combine(root,"combined.zip"),new("SSH","Current cached model","Current cached firmware","1.24.test"),[],privacy);
        var combinedFiles=ReadZip(combined.Path);
        Check(combinedFiles.ContainsKey("firmware-research/report.json") && combinedFiles.ContainsKey("firmware-research/probes/identity.txt") && Encoding.UTF8.GetString(combinedFiles["application-journal.jsonl"]).Contains("Combined program action"),"one offline ZIP includes program actions and cached modem probes");
        var combinedText=string.Join('\n',combinedFiles.Values.Select(Encoding.UTF8.GetString));
        Check(!combinedText.Contains(secret) && !combinedText.Contains("CACHE_ACTIVATION_PRIVATE") && !combinedText.Contains("UNKNOWN_CACHED_ACTIVATION_PRIVATE") && !combinedText.Contains("PEM_CACHED_PRIVATE_BODY") && !combinedText.Contains("PEM_TRUNCATED_PRIVATE_BODY") && !new[]{'b','c','d','e'}.Any(ch=>combinedText.Contains(new string(ch,64))),"cached probe transcripts and facts are redacted again on common export");
        using(var cachedVersion=JsonDocument.Parse(combinedFiles["firmware-research/report.json"]))
            Check(cachedVersion.RootElement.GetProperty("applicationVersion").GetString()=="1.24.5.0","cached structured application version is preserved inside the research report");
        using(var cachedJson=JsonDocument.Parse(combinedFiles["firmware-research/report.json"]))
            Check(cachedJson.RootElement.GetProperty("probes")[0].GetProperty("facts").GetProperty("firmware_sha256").GetString()==factualHash && cachedJson.RootElement.GetProperty("specificationSHA256").GetString()==factualHash,"factual SHA256 values remain exact after redaction");
        using(var manifest=JsonDocument.Parse(combinedFiles["manifest.json"]))
        {
            var origin=manifest.RootElement.GetProperty("sources").GetProperty("firmwareResearch");
            Check(origin.GetProperty("collectionStartedAt").GetDateTimeOffset()==cachedTime && origin.GetProperty("applicationVersion").GetString()=="1.24.5.0" && origin.GetProperty("relationToCurrentConnection").GetString()=="not-assessed" && origin.GetProperty("sourceSha256").GetString()==Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(cachedPath))),"cached report timestamps/version/source hash remain separate from current settings");
            Check(manifest.RootElement.GetProperty("files").EnumerateArray().All(e=>e.GetProperty("sha256").GetString()==Convert.ToHexStringLower(SHA256.HashData(combinedFiles[e.GetProperty("path").GetString()!]))),"merged ZIP hashes cover research files and original application files");
            Check(combinedFiles.Values.Sum(x=>(long)x.Length)<=32*1024*1024,"combined payload respects the total byte limit");
        }
        var missRoot=Path.Combine(root,"missing-research");
        DiagnosticsExporter.Append(missRoot,new(eventTime,"info","Retained when research unavailable"),privacy);
        var missing=DiagnosticsExporter.Export(missRoot,Path.Combine(root,"research-missing.zip"),new(null,null,null,"test"),[],privacy);
        Check(missing.Omissions==1 && !ReadZip(missing.Path).Keys.Any(x=>x.StartsWith("firmware-research/")) && Encoding.UTF8.GetString(ReadZip(missing.Path)["application-journal.jsonl"]).Contains("Retained when research unavailable"),"missing cache produces omission while retaining actions");
        void OmittedCache(string name,Action<string> create)
        {
            var cacheRoot=Path.Combine(root,"cache-"+name);Directory.CreateDirectory(cacheRoot);
            var cache=Path.Combine(cacheRoot,"FirmwareResearch","latest.json");Directory.CreateDirectory(Path.GetDirectoryName(cache)!);create(cache);
            var export=DiagnosticsExporter.Export(cacheRoot,Path.Combine(root,"cache-"+name+".zip"),new(null,null,null,"test"),[new(eventTime,"info","Action survives invalid cache")],privacy);
            var entries=ReadZip(export.Path);
            Check(export.Omissions>=1 && !entries.Keys.Any(x=>x.StartsWith("firmware-research/")) && Encoding.UTF8.GetString(entries["current-session.jsonl"]).Contains("Action survives invalid cache"),"unsafe cached research omitted: "+name);
        }
        OmittedCache("corrupt",p=>File.WriteAllText(p,"PRIVATE_CORRUPT_CANARY"));
        OmittedCache("null-fields",p=>File.WriteAllText(p,"{\"schemaVersion\":1}"));
        OmittedCache("oversized",p=>{using var stream=File.Create(p);stream.SetLength(FirmwareResearchEngine.TotalLimit+1);});
        OmittedCache("unsafe-probe-path",p=>ResearchReportFiles.Save(cachedReport with {Probes=[cachedReport.Probes[0] with {Id="../../private"}]},p));
        OmittedCache("duplicate-probe-path",p=>ResearchReportFiles.Save(cachedReport with {Probes=[cachedReport.Probes[0],cachedReport.Probes[0]]},p));
        OmittedCache("expanded-payload",p=>ResearchReportFiles.Save(cachedReport with {Probes=[cachedReport.Probes[0] with {Stdout=string.Concat(Enumerable.Repeat(string.Concat(Enumerable.Repeat("safe detail. ",200))+"\n",3900))}]},p));
        OmittedCache("leaf-link",p=>File.CreateSymbolicLink(p,cachedPath));
        OmittedCache("broken-link",p=>File.CreateSymbolicLink(p,Path.Combine(root,"nonexistent-private-cache")));
        var ancestorRoot=Path.Combine(root,"linked-ancestor");Directory.CreateSymbolicLink(ancestorRoot,combinedRoot);
        var ancestor=DiagnosticsExporter.Export(ancestorRoot,Path.Combine(root,"cache-ancestor.zip"),new(null,null,null,"test"),[],privacy);
        Check(ancestor.Omissions>=1 && !ReadZip(ancestor.Path).Keys.Any(x=>x.StartsWith("firmware-research/")),"linked ancestor cannot supply a cached research report");
        using(var during=new CancellationTokenSource())
        {
            IEnumerable<DiagnosticActivity> CancelDuring(){during.Cancel();yield return new(eventTime,"info","synthetic cancellation");}
            var target=Path.Combine(root,"cancelled-mid-export.zip");
            try {DiagnosticsExporter.Export(combinedRoot,target,new(null,null,null,"test"),CancelDuring(),privacy,ct:during.Token);Check(false,"mid-export cancellation honored");}
            catch(OperationCanceledException){Check(!File.Exists(target) && !Directory.GetFiles(root,"cancelled-mid-export.zip.*.tmp").Any(),"mid-export cancellation leaves no partial ZIP");}
        }
        ResearchReportFiles.Save(cachedReport,Path.Combine(serviceRoot,"FirmwareResearch","latest.json"));
        var existingZips=Directory.GetFiles(Path.Combine(serviceRoot,"Diagnostics"),"*.zip").ToHashSet();
        Check((await restarted.RunAsync(new(ModemOperation.ExportDiagnostics))).Success,"actual common export dispatcher includes cache without transport/resources");
        var mergedService=ReadZip(Directory.GetFiles(Path.Combine(serviceRoot,"Diagnostics"),"*.zip").Single(p=>!existingZips.Contains(p)));
        Check(mergedService.ContainsKey("firmware-research/probes/identity.txt") && mergedService.ContainsKey("operation-traces.jsonl"),"real service path exports actions and research together");
        Check(!Directory.EnumerateFiles(root,"*.tmp",SearchOption.AllDirectories).Any(),"all export temporary files cleaned");
        Console.WriteLine($"Diagnostic export: {passed} PASS");
    }
}
