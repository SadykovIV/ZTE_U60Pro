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
        Check(malformed.Omissions==1 && new[]{"DO_NOT_EXPORT_UNKNOWN_FIELD","PrivateOperationCanary"}.All(x=>!string.Join('\n',malformedFiles.Values.Select(Encoding.UTF8.GetString)).Contains(x)),"malformed events noted and unknown JSON fields/operation labels never copied");
        var linkRoot=Path.Combine(root,"link-test");Directory.CreateDirectory(Path.Combine(linkRoot,"Diagnostics","Application"));
        var sensitive=Path.Combine(root,"sensitive-target");File.WriteAllText(sensitive,"PRIVATE_LINK_CANARY");
        File.CreateSymbolicLink(Path.Combine(linkRoot,"Diagnostics","Application","activity.jsonl"),sensitive);
        var linked=DiagnosticsExporter.Export(linkRoot,Path.Combine(root,"links.zip"),new(null,null,null,"test"),[],privacy);
        Check(linked.Omissions==1 && !string.Join('\n',ReadZip(linked.Path).Values.Select(Encoding.UTF8.GetString)).Contains("PRIVATE_LINK_CANARY"),"linked activity segment is omitted without reading target");
        var bigRoot=Path.Combine(root,"oversize-test");Directory.CreateDirectory(Path.Combine(bigRoot,"Diagnostics","Application"));
        File.WriteAllBytes(Path.Combine(bigRoot,"Diagnostics","Application","activity.jsonl"),new byte[DiagnosticsExporter.SegmentLimit+1]);
        Check(DiagnosticsExporter.Export(bigRoot,Path.Combine(root,"oversize.zip"),new(null,null,null,"test"),[],privacy).Omissions==1,"oversized journal safely omitted and reported");
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
        Check(!Directory.EnumerateFiles(root,"*.tmp",SearchOption.AllDirectories).Any(),"all export temporary files cleaned");
        Console.WriteLine($"Diagnostic export: {passed} PASS");
    }
}
