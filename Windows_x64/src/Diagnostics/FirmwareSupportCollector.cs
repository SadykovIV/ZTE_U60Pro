using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows.Diagnostics;

internal sealed record FirmwareSupportFile(string Id, string State, long? Bytes, string? Sha256, string? Uid, string? Mode, string? Links);
internal sealed record FirmwareSupportInspection(IReadOnlyDictionary<string,string> Facts, FirmwareSupportFile[] Files);
internal sealed record FirmwareSupportResult(string Path, bool Complete, int CapturedFiles);

/// A fixed read-only protocol. No remote path, command, environment or body is copied into the report.
internal static class FirmwareSupportCollector
{
    internal const string ExpectedHelperSha256 = "0b041b33cdd3879d8245375c9126eb4a9b8d2e60038bae6c6041da79406dbbc6";
    internal sealed record Input(string Id, string RemotePath, string ArchivePath, long Limit, bool Required);
    internal static readonly Input[] Inputs = [
        new("ui", "/usr/bin/zte_topsw_devui", "files/zte_topsw_devui", 256L*1024*1024, true),
        new("english", "/usr/ui/language/English.ini", "files/English.ini", 16L*1024*1024, true),
        new("chinese", "/usr/ui/language/Chinese.ini", "files/Chinese.ini", 16L*1024*1024, true),
        new("init", "/etc/init.d/zte_topsw_devui", "files/zte_topsw_devui.init", 4L*1024*1024, true),
        new("original_ui", "/data/zte-imei-screen-ru/backup/zte_topsw_devui", "originals/zte_topsw_devui", 256L*1024*1024, false),
        new("original_english", "/data/zte-imei-screen-ru/backup/English.ini", "originals/English.ini", 16L*1024*1024, false),
        new("original_chinese", "/data/zte-imei-screen-ru/backup/Chinese.ini", "originals/Chinese.ini", 16L*1024*1024, false),
        new("original_init", "/data/zte-imei-screen-ru/backup/zte_topsw_devui.init", "originals/zte_topsw_devui.init", 4L*1024*1024, false),
    ];
    private static readonly HashSet<string> FactKeys = ["uid","os","architecture","firmware","inner","openwrt_version","target","agent_present","agent_sha256","agent_running_count","agent_mode","agent_mapped_matches_disk","http_health_status","http_capabilities_status","http_dashboard_status","ui_mounts"];
    private static readonly HashSet<string> FileStates = ["present","missing","not_assessed","symlink","not_regular","unreadable","empty"];
    private static readonly UTF8Encoding Utf8 = new(false,true);
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    internal delegate Task<RemoteFileResult> StreamFile(string command, string path, long maximum, TimeSpan timeout, CancellationToken ct, byte[] input);
    internal const string Failed = "Не удалось проверить данные для адаптации прошивки. Итоговый ZIP не создан; модем не изменён.";

    internal static string Sha(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static bool Match(string text,string pattern) => Regex.IsMatch(text, "\\A(?:"+pattern+")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static void Require(bool condition) { if (!condition) throw new InvalidDataException(Failed); }

    internal static FirmwareSupportInspection Parse(RemoteResult reply)
    {
        Require(reply.Success && reply.Stdout.Length<=65536 && reply.Stderr.Length==0 && !reply.Stdout.Contains((byte)0));
        var text=Utf8.GetString(reply.Stdout);
        Require(text.EndsWith('\n')&&!text.Contains('\r'));
        var lines=text[..^1].Split('\n');
        Require(lines.Length==2+Inputs.Length+FactKeys.Count && lines[0]=="FIRMWARE_SUPPORT_V1" && lines[^1]=="FIRMWARE_SUPPORT_END");
        var facts=new Dictionary<string,string>(StringComparer.Ordinal);
        var files=new Dictionary<string,FirmwareSupportFile>(StringComparer.Ordinal);
        foreach(var line in lines.Skip(1).SkipLast(1))
        {
            var fields=line.Split('\t');
            if(fields.Length==3 && fields[0]=="FACT")
            {
                Require(FactKeys.Contains(fields[1]) && fields[2].Length<=1024);
                var value=Utf8.GetString(Convert.FromBase64String(fields[2]));
                Require(value.Length<=256 && !value.Any(char.IsControl) && ValidFact(fields[1],value) && facts.TryAdd(fields[1],value));
            }
            else
            {
                Require(fields.Length==8 && fields[0]=="FILE" && Inputs.Any(x=>x.Id==fields[1]) && FileStates.Contains(fields[2]));
                long? size=null; string? hash=null,uid=null,mode=null,links=null;
                if(fields[2]=="present")
                {
                    Require(Match(fields[3],"[1-9][0-9]{0,9}") && long.TryParse(fields[3],NumberStyles.None,CultureInfo.InvariantCulture,out var parsed));
                    size=long.Parse(fields[3],CultureInfo.InvariantCulture);
                    Require(Match(fields[4],"[0-9a-f]{64}") && Match(fields[5],"[0-9]{1,10}") && Match(fields[6],"[0-7]{1,4}") && Match(fields[7],"[1-9][0-9]{0,9}"));
                    hash=fields[4];uid=fields[5];mode=fields[6];links=fields[7];
                }
                else Require(fields.Skip(3).All(x=>x=="-"));
                Require(files.TryAdd(fields[1],new(fields[1],fields[2],size,hash,uid,mode,links)));
            }
        }
        Require(FactKeys.SetEquals(facts.Keys)&&Inputs.Select(x=>x.Id).ToHashSet().SetEquals(files.Keys));
        return new(facts,Inputs.Select(x=>files[x.Id]).ToArray());
    }

    private static bool ValidFact(string key,string value)
    {
        if(value is "unknown" or "not_assessed" or "not-assessed" or "missing" or "absent") return true;
        return key switch {
            "uid" or "agent_running_count" or "ui_mounts" => Match(value,"[0-9]{1,10}"),
            "agent_present" or "agent_mapped_matches_disk" => value is "0" or "1" or "yes" or "no" or "true" or "false",
            "agent_sha256" => Match(value,"[0-9a-f]{64}"),
            "agent_mode" => value is "normal" or "discovery" or "default" or "ambiguous",
            "http_health_status" or "http_capabilities_status" or "http_dashboard_status" => Match(value,"[1-5][0-9]{2}|000") || value is "auth_needed" or "unreachable" or "unavailable",
            "firmware" or "inner" or "openwrt_version" or "target" => Match(value,"[ -~]{1,256}"),
            _ => Match(value,"[A-Za-z0-9._/+:-]{1,128}"),
        };
    }

    internal static byte[] LoadHelper(string resources)
    {
        var path=Path.Combine(resources,"FirmwareSupport","collect.sh");
        SafeLocal(path);
        Require(new FileInfo(path).Length is >0 and <=131072);
        var bytes=File.ReadAllBytes(path);
        Require(bytes.Length is >0 and <=131072 && Sha(bytes)==ExpectedHelperSha256 && !bytes.Contains((byte)0));
        var manifest=Path.Combine(resources,"FirmwareSupport","SHA256.json");SafeLocal(manifest);
        Require(new FileInfo(manifest).Length<=4096);
        using var parsed=JsonDocument.Parse(File.ReadAllBytes(manifest));
        Require(parsed.RootElement.ValueKind==JsonValueKind.Object && parsed.RootElement.EnumerateObject().Count()==1 &&
            parsed.RootElement.TryGetProperty("collect.sh",out var pin) && pin.ValueKind==JsonValueKind.String && pin.GetString()==ExpectedHelperSha256);
        return bytes;
    }

    private static void SafeLocal(string path)
    {
        for(string? p=Path.GetFullPath(path);p is not null;p=Path.GetDirectoryName(p))
        {
            try { Require((File.GetAttributes(p)&FileAttributes.ReparsePoint)==0); }
            catch(FileNotFoundException) {} catch(DirectoryNotFoundException) {}
        }
    }
    private static void PrivateDirectory(string path)
    {
        SafeLocal(path);
        if(OperatingSystem.IsWindows())Directory.CreateDirectory(path);
        else Directory.CreateDirectory(path,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
    }
    private static void PrivateFile(string path)
    { if(!OperatingSystem.IsWindows())File.SetUnixFileMode(path,UnixFileMode.UserRead|UnixFileMode.UserWrite); }
    private static async Task<string> FileSha(string path,CancellationToken ct)
    { using var stream=File.OpenRead(path);return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream,ct)); }

    internal static async Task<FirmwareSupportResult> CollectAsync(IRemoteShell shell,SshReadProof selected,StreamFile stream,
        byte[] helper,string host,string destination,string workingDirectory,IReadOnlyDictionary<string,byte[]> activity,string version,CancellationToken ct,Action? verifySelection = null)
    {
        Require(System.Net.IPAddress.TryParse(host,out var ip)&&ip.AddressFamily==System.Net.Sockets.AddressFamily.InterNetwork);
        Require(Path.IsPathFullyQualified(destination)&&!File.Exists(destination)&&!Directory.Exists(destination));
        SafeLocal(destination);SafeLocal(workingDirectory);
        var token=ct;
        var stage=Path.Combine(workingDirectory,"capture-"+Guid.NewGuid().ToString("N"));PrivateDirectory(stage);
        string? partial=null;
        try
        {
            var before=await SshReadProof.ReadSessionAsync(shell,token);selected.Verify(before);
            var inspect="sh -s -- inspect "+VerifiedHash.ShellQuote(host);
            var firstTime=DateTimeOffset.UtcNow;
            var first=Parse(await shell.RunAsync(inspect,helper,TimeSpan.FromSeconds(45),token));
            var captures=new Dictionary<string,string>(StringComparer.Ordinal);
            foreach(var item in first.Files.Where(x=>x.State=="present" && x.Bytes<=Inputs.Single(i=>i.Id==x.Id).Limit))
            {
                token.ThrowIfCancellationRequested();
                var path=Path.Combine(stage,item.Id+".bin");
                var command="sh -s -- file "+item.Id+" "+item.Bytes!.Value.ToString(CultureInfo.InvariantCulture)+" "+item.Sha256;
                var result=await stream(command,path,item.Bytes.Value,TimeSpan.FromSeconds(180),token,helper);
                PrivateFile(path);
                Require(result.Success&&result.Bytes==item.Bytes&&result.Sha256==item.Sha256&&
                    Utf8.GetString(result.Stderr)=="BACKUP_RESULT sha256="+item.Sha256+" bytes="+item.Bytes.Value.ToString(CultureInfo.InvariantCulture)+"\n"&&
                    new FileInfo(path).Length==item.Bytes&&await FileSha(path,token)==item.Sha256);
                captures.Add(item.Id,path);
            }
            var last=Parse(await shell.RunAsync(inspect,helper,TimeSpan.FromSeconds(45),token));
            var lastTime=DateTimeOffset.UtcNow;
            Require(first.Files.SequenceEqual(last.Files));
            foreach(var key in new[]{"uid","os","architecture","firmware","inner","openwrt_version","target"})
                Require(first.Facts[key] == last.Facts[key]);
            // Runtime facts may change while collecting; both observations retain their timestamps.
            var after=await SshReadProof.ReadSessionAsync(shell,token);before.Verify(after);selected.Verify(after);
            var complete=Inputs.Where(x=>x.Required).All(x=>captures.ContainsKey(x.Id));
            var entries=new SortedDictionary<string,(string? Path,byte[]? Data)>(StringComparer.Ordinal);
            foreach(var input in Inputs.Where(x=>captures.ContainsKey(x.Id)))entries.Add(input.ArchivePath,(captures[input.Id],null));
            foreach(var item in activity)
            {
                Require(item.Key is "application-journal.jsonl" or "current-session.jsonl" or "operation-traces.jsonl");
                Require(item.Value.Length<=8*1024*1024);entries.Add("activity/"+item.Key,(null,item.Value));
            }
            entries.Add("README.txt",(null,Utf8.GetBytes("Firmware adaptation evidence; read-only SSH collection.\nFiles under files/ and originals/ are unchanged bytes, not redacted text.\nOnly the fixed screen program, language files and screen init script are collected. Agent startup, passwords, keys, device identifiers, user configuration, NV and SIM/eSIM profiles are excluded.\nactivity/ contains sanitized application activity; it may include earlier actions and is not a same-device proof. No cached firmware survey is copied.\nHTTP 401 means authentication is required, not an agent failure. Runtime mode may restrict features despite a running process.\nobservedFactsStable refers only to available quick SSH identity observations. identityStable is true only with both CID and boot continuity; partial or transport-only binding cannot establish full device identity. Runtime facts retain separate before/after observations and may differ.\nAn incomplete report is evidence only, not compatibility or write authorization.\n")));
            var payloads=new List<object>();
            foreach(var (name,entry) in entries)payloads.Add(new { path=name,bytes=entry.Data?.LongLength??new FileInfo(entry.Path!).Length,sha256=entry.Data is {} data?Sha(data):await FileSha(entry.Path!,token) });
            var binding=before.Cid is not null&&before.BootId is not null?"full":before.Cid is not null||before.BootId is not null?"partial":"transport-only";
            entries.Add("manifest.json",(null,JsonSerializer.SerializeToUtf8Bytes(new {
                schemaVersion=1,outcome=complete?"complete":"incomplete",complete,applicationVersion=version,createdAt=DateTimeOffset.UtcNow,
                readOnly=true,channel="SSH",bindingStrength=binding,observedFactsStable=true,identityStable=binding=="full",helperSha256=Sha(helper),
                firstObservedAt=firstTime,lastObservedAt=lastTime,factsBefore=first.Facts,factsAfter=last.Facts,files=Inputs.Select(x=>new {id=x.Id,path=x.RemotePath,archivePath=x.ArchivePath,required=x.Required,observation=first.Files.Single(f=>f.Id==x.Id),captureStatus=captures.ContainsKey(x.Id)?"verified":first.Files.Single(f=>f.Id==x.Id).Bytes>x.Limit?"over_limit":"unavailable"}),payloads,
            },Json)));
            var directory=Path.GetDirectoryName(destination)!;PrivateDirectory(directory);
            partial=Path.Combine(directory,".zte-firmware-support-"+Guid.NewGuid().ToString("N")+".partial");
            using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None))
            {
                PrivateFile(partial);
                using var zip=new ZipArchive(output,ZipArchiveMode.Create);
                foreach(var (name,entry) in entries)
                {
                    token.ThrowIfCancellationRequested();using var target=zip.CreateEntry(name,CompressionLevel.Optimal).Open();
                    if(entry.Data is {} data)await target.WriteAsync(data,token);
                    else {using var source=File.OpenRead(entry.Path!);await source.CopyToAsync(target,token);}
                }
            }
            using(var zip=ZipFile.OpenRead(partial))
            {
                Require(zip.Entries.Count==entries.Count);
                foreach(var entry in zip.Entries)
                {
                    Require(entries.TryGetValue(entry.FullName,out var source));using var input=entry.Open();
                    var hash=Convert.ToHexStringLower(await SHA256.HashDataAsync(input,token));
                    Require(hash==(source.Data is {} data?Sha(data):await FileSha(source.Path!,token)));
                }
            }
            token.ThrowIfCancellationRequested();verifySelection?.Invoke();File.Move(partial,destination,false);partial=null;
            return new(destination,complete,captures.Count);
        }
        catch(OperationCanceledException) {throw;}
        catch(Exception)
        {throw new InvalidDataException(Failed);}
        finally {if(partial is not null&&File.Exists(partial))File.Delete(partial);if(Directory.Exists(stage))Directory.Delete(stage,true);}
    }
}
