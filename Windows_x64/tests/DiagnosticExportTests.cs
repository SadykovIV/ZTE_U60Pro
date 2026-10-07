using ZteImeiStudio.Windows.Core;
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
        var combinedRoot=Path.Combine(root,"logs-only");
        var cachedPath=Path.Combine(combinedRoot,"FirmwareResearch","latest.json");
        Directory.CreateDirectory(Path.GetDirectoryName(cachedPath)!);File.WriteAllText(cachedPath,"RESEARCH-MUST-NOT-BE-EXPORTED");
        var setupId=Guid.NewGuid().ToString();var setup=Path.Combine(combinedRoot,"SetupBackups",setupId,"installation.log");
        Directory.CreateDirectory(Path.GetDirectoryName(setup)!);File.WriteAllText(setup,"Installer failure detail\npassword="+secret);
        DiagnosticsExporter.Append(combinedRoot,new(eventTime,"info","Preparation failure survives export"),privacy);
        var combined=DiagnosticsExporter.Export(combinedRoot,Path.Combine(root,"logs-only.zip"),new(null,null,null,"test"),[],privacy);
        var combinedFiles=ReadZip(combined.Path);
        Check(combined.Omissions==0&&!combinedFiles.Keys.Any(x=>x.StartsWith("firmware-research/")),"logs export never reads or depends on research cache");
        var combinedText=string.Join('\n',combinedFiles.Values.Select(Encoding.UTF8.GetString));
        Check(combinedText.Contains("Installer failure detail")&&combinedText.Contains("Preparation failure survives export")&&!combinedText.Contains(secret)&&!combinedText.Contains("RESEARCH-MUST-NOT-BE-EXPORTED"),"logs ZIP includes sanitized installation transcript and app errors without firmware data");
        var manyRoot=Path.Combine(root,"many-installations");
        var line="Installer transcript: step completed; more details follow.\n";
        var large=string.Concat(Enumerable.Repeat(line,DiagnosticsExporter.SegmentLimit/line.Length));
        var oldestSetup="";var newestSetup="";
        for(var i=0;i<17;i++)
        {
            var id=Guid.NewGuid().ToString();if(i==0)oldestSetup=id;if(i==16)newestSetup=id;
            var directory=Path.Combine(manyRoot,"SetupBackups",id);Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory,"installation.log"),large);
            Directory.SetLastWriteTimeUtc(directory,new DateTime(2026,1,1,0,0,0,DateTimeKind.Utc).AddMinutes(i));
        }
        var many=DiagnosticsExporter.Export(manyRoot,Path.Combine(root,"many-installations.zip"),new(null,null,null,"test"),
            [new(eventTime,"error","CURRENT-ERROR-MUST-SURVIVE")],privacy);
        var manyFiles=ReadZip(many.Path);
        Check(many.Omissions>0&&manyFiles.Keys.Any(x=>x=="preparation/"+newestSetup+"/installation.log")&&!manyFiles.Keys.Any(x=>x=="preparation/"+oldestSetup+"/installation.log"),"oversized installation history omits oldest transcripts and preserves newest");
        Check(Encoding.UTF8.GetString(manyFiles["current-session.jsonl"]).Contains("CURRENT-ERROR-MUST-SURVIVE")&&Encoding.UTF8.GetString(manyFiles["manifest.json"]).Contains("archive size limit"),"installation history cannot prevent local error export; omission is explicit");
        Check(manyFiles.Values.Sum(x=>(long)x.Length)<=32*1024*1024,"optional transcript budget includes final manifest bytes");
        foreach(var kind in new[]{"complete","command-failure","offline","changed"})
        {
            var shell=new LogShell{Kind=kind};
            var collected=await ModemLogCollector.CollectAsync(shell,LogShell.Proof,CancellationToken.None);
            Check(shell.Commands.All(c=>c==SshReadProof.SessionCommand||ModemLogCollector.Commands.Any(x=>c==ModemLogCollector.Wrap(x.Command))),"log collection sends only session proof and three known reads: "+kind);
            Check(collected.Status==(kind=="complete"?"complete":"partial"),"modem log outcome preserves failures: "+kind);
            Check(kind!="changed"||collected.Files.Count==0,"changed device discards remote logs");
            var target=Path.Combine(root,"logs-"+kind+".zip");
            var exportedLogs=DiagnosticsExporter.Export(combinedRoot,target,new("SSH",null,null,"test"),[],privacy,modemLogs:collected);
            var payload=ReadZip(exportedLogs.Path);var body=string.Join('\n',payload.Values.Select(Encoding.UTF8.GetString));
            Check(body.Contains("Preparation failure survives export")&&!body.Contains("REMOTE-SECRET-CANARY"),"local logs survive remote failure and remote secrets are hidden: "+kind);
            Check(kind!="complete"||payload.Keys.Count(x=>x.StartsWith("modem/"))==3,"connected collection contains all modem logs");
        }
        var connectedRoot=Path.Combine(root,"connected-logs");var connected=new WindowsModemService(connectedRoot,Path.Combine(root,"no-agent-resources"));
        typeof(WindowsModemService).GetField("_sshRead",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(connected,new LogShell());
        typeof(WindowsModemService).GetField("_connectionProof",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(connected,LogShell.Proof);
        typeof(WindowsModemService).GetField("_snapshot",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(connected,new DeviceSnapshot(true,"Synthetic SSH",ConnectionMode:"SSH"));
        Check((await connected.RunAsync(new(ModemOperation.ExportDiagnostics))).Success,"real export dispatcher reads selected SSH without installed agent or feature engine");
        var connectedFiles=ReadZip(Directory.GetFiles(Path.Combine(connectedRoot,"Diagnostics"),"*.zip").Single());
        Check(connectedFiles.Keys.Count(x=>x.StartsWith("modem/"))==3,"real export dispatcher adds fresh modem logs to ZIP");
        using(var during=new CancellationTokenSource())
        {
            IEnumerable<DiagnosticActivity> CancelDuring(){during.Cancel();yield return new(eventTime,"info","synthetic cancellation");}
            var target=Path.Combine(root,"cancelled-mid-export.zip");
            try {DiagnosticsExporter.Export(combinedRoot,target,new(null,null,null,"test"),CancelDuring(),privacy,ct:during.Token);Check(false,"mid-export cancellation honored");}
            catch(OperationCanceledException){Check(!File.Exists(target) && !Directory.GetFiles(root,"cancelled-mid-export.zip.*.tmp").Any(),"mid-export cancellation leaves no partial ZIP");}
        }
        Check(!Directory.EnumerateFiles(root,"*.tmp",SearchOption.AllDirectories).Any(),"all export temporary files cleaned");
        Console.WriteLine($"Diagnostic export: {passed} PASS");
    }
}

internal sealed class LogShell : ZteImeiStudio.Transport.IRemoteShell
{
    public string Kind="complete";public List<string> Commands=[];private int proofs;
    internal static SshReadProof Proof => new("0","Linux","aarch64",new string('a',32),"2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601",null,null);
    public Task<ZteImeiStudio.Transport.RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
    {
        Commands.Add(command);if(Kind=="offline")throw new IOException("Synthetic SSH lost");
        if(command==SshReadProof.SessionCommand)
        {
            proofs++;var boot=Kind=="changed"&&proofs>1?"3a2fb1c5-1bbf-4d3b-92a8-3daaf5510601":Proof.BootId;
            return Task.FromResult(new ZteImeiStudio.Transport.RemoteResult(0,Encoding.UTF8.GetBytes("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n"+Proof.Cid+"\n"+boot+"\n?\n?\n"),[]));
        }
        var exit=Kind=="command-failure"?3:0;
        return Task.FromResult(new ZteImeiStudio.Transport.RemoteResult(0,Encoding.UTF8.GetBytes("Useful modem failure\npassword=REMOTE-SECRET-CANARY\n__DIAGNOSTIC_RESULT__"+exit+"\n"),[]));
    }
    public Task UploadAsync(string p,byte[] b,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
    public Task<byte[]> DownloadAsync(string p,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
}
