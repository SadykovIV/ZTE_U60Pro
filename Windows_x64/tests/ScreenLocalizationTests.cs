using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

static class ScreenLocalizationTests
{
    static int checks;
    static readonly byte[] B31 = Encoding.ASCII.GetBytes("SYNTHETIC-UI-B31-ORIGINAL");
    static readonly byte[] B28 = Encoding.ASCII.GetBytes("SYNTHETIC-UI-B28-ORIGINAL");
    static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    static void Check(bool value,string name) { if(!value)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);checks++; }
    static async Task<int> Main(string[] args)
    {
        try { await Run(args);Console.WriteLine("TOTAL "+checks+" PASS");return 0; }
        catch(Exception e) { Console.WriteLine(e);return 1; }
    }
    static byte[] Patch(byte[] input) => JsonSerializer.SerializeToUtf8Bytes(new {version=1,inputSHA256=Hash(input),outputSHA256=Hash(Patched(input)),inputSize=input.Length,outputSize=input.Length,patches=new[]{new{offset=0,originalHex="53",replacementHex="52"}}});
    static byte[] Patched(byte[] input) { var result=(byte[])input.Clone();result[0]=(byte)'R';return result; }
    static string Resources(string root,string fault="")
    {
        var directory=Path.Combine(root,"Resources","ScreenLocalization");Directory.CreateDirectory(directory);
        var files=new Dictionary<string,byte[]> { ["install.sh"]=Encoding.UTF8.GetBytes("#!/bin/sh\n# synthetic installer"),["service.sh"]=Encoding.UTF8.GetBytes("# synthetic service"),["English.ini"]=Encoding.UTF8.GetBytes("synthetic English"),["Chinese.ini"]=Encoding.UTF8.GetBytes("synthetic Russian"),["font.patch.json"]=Patch(B31),["font.patch.b28.json"]=Patch(fault=="ambiguous"?B31:B28) };
        if(fault=="output") { using var doc=JsonDocument.Parse(files["font.patch.b28.json"]);files["font.patch.b28.json"]=Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(files["font.patch.b28.json"]).Replace(Hash(Patched(B28)),new string('d',64),StringComparison.Ordinal)); }
        if(fault=="size")files["font.patch.b28.json"]=JsonSerializer.SerializeToUtf8Bytes(new{version=1,inputSHA256=Hash(B28),outputSHA256=Hash(Patched(B28)),inputSize=B28.Length+1,outputSize=B28.Length+1,patches=new[]{new{offset=0,originalHex="53",replacementHex="52"}}});
        if(fault=="patch-original")files["font.patch.b28.json"]=Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Patch(B28)).Replace("\"originalHex\":\"53\"","\"originalHex\":\"54\"",StringComparison.Ordinal));
        if(fault=="patch-range")files["font.patch.b28.json"]=Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Patch(B28)).Replace("\"offset\":0","\"offset\":2147483647",StringComparison.Ordinal));
        if(fault=="patch-overlap")files["font.patch.b28.json"]=JsonSerializer.SerializeToUtf8Bytes(new{version=1,inputSHA256=Hash(B28),outputSHA256=Hash(Patched(B28)),inputSize=B28.Length,outputSize=B28.Length,patches=new[]{new{offset=0,originalHex="53",replacementHex="52"},new{offset=0,originalHex="53",replacementHex="52"}}});
        foreach(var (name,bytes) in files)File.WriteAllBytes(Path.Combine(directory,name),bytes);
        File.WriteAllText(Path.Combine(directory,"SHA256.json"),JsonSerializer.Serialize(files.ToDictionary(x=>x.Key,x=>Hash(x.Value))));
        if(fault=="resource")File.AppendAllText(Path.Combine(directory,"font.patch.b28.json")," ");
        return Path.GetDirectoryName(directory)!;
    }
    static async Task Run(string[] args)
    {
        var root=args[0];Directory.CreateDirectory(root);
        async Task<(Fake,ScreenLocalizationStatus)> Install(string name,byte[] original,string firmware="b28",string state="absent",string revision="20261006",string fault="")
        {
            var path=Path.Combine(root,name);var resources=Resources(path,fault);var fake=new Fake(original){Firmware=firmware,State=state,Revision=revision};
            var status=await new DeviceFeatureService(fake,resources,Path.Combine(path,"state")).InstallLocalizationAsync();return(fake,status);
        }
        var first=await Install("b28-fresh",B28);
        Check(first.Item2.State=="enabled"&&first.Item1.Installs==1,"B28 fresh localization uses measured identity without the global B31 override");
        Check(first.Item1.StrictReads==0&&first.Item1.MeasuredReads>=3,"screen operation keeps fresh measured root/platform/device proof");
        Check(first.Item1.Uploads["zte_topsw_devui"].SequenceEqual(Patched(B28))&&first.Item1.Uploads["font.patch.json"].SequenceEqual(Patch(B28)),"B28 exact manifest is selected and staged under the existing canonical name");
        Check(first.Item1.Uploads.Keys.ToHashSet().SetEquals(["install.sh","service.sh","English.ini","Chinese.ini","font.patch.json","zte_topsw_devui"]),"only the six existing installer payload files are staged");
        var b31=await Install("b31-fresh",B31,"b31");
        Check(b31.Item1.Uploads["font.patch.json"].SequenceEqual(Patch(B31))&&b31.Item1.Installs==1,"B31 fresh installation still selects its unchanged font map");
        var absent=await Install("files-absent",B28,"absent");
        Check(absent.Item2.State=="enabled","unrelated firmware/router files may be proven absent for the exact screen profile");
        foreach(var firmware in new[]{"b31","b28"})
        {
            var enabled=await Install(firmware+"-repeat",firmware=="b31"?B31:B28,firmware,"enabled");
            Check(enabled.Item1.Installs==0&&enabled.Item1.Uploads.Count==0,"current "+firmware+" enabled repeat does not stage or reinstall");
            var disabled=await Install(firmware+"-reenable",firmware=="b31"?B31:B28,firmware,"disabled");
            Check(disabled.Item1.Enables==1&&disabled.Item1.Uploads.Count==0,"current "+firmware+" re-enable uses the owned manager");
        }
        foreach(var revision in new[]{"20260922","20260923","20260924"})
        {
            var legacy=await Install("upgrade-"+revision,B31,"b31","disabled",revision);
            Check(legacy.Item1.BackupReads==1&&legacy.Item1.Installs==1,"B31 "+revision+" upgrade patches the owned original backup");
        }
        foreach(var revision in new[]{"20260922","20260923","20260924","20261006"})
        {
            var path=Path.Combine(root,"restore-"+revision);var fake=new Fake(B31){Firmware=revision=="20261006"?"b28":"b31",State="enabled",Revision=revision};
            var result=await new DeviceFeatureService(fake,Resources(path),Path.Combine(path,"state")).RestoreLocalizationAsync();
            Check(result.State=="disabled"&&fake.Disables==1&&fake.Uploads.Count==0,"restore keeps exact known manager for "+revision);
        }
        foreach(var fault in new[]{"unknown","ambiguous","output","resource","size","patch-original","patch-range","patch-overlap","platform","identity-drift","read-error"})
        {
            var path=Path.Combine(root,"reject-"+fault);var fake=new Fake(fault=="unknown"?Encoding.ASCII.GetBytes("unknown UI"):fault=="ambiguous"?B31:B28){Firmware="b28",PlatformFailure=fault=="platform",Drift=fault=="identity-drift",ReadFailure=fault=="read-error"};
            try { await new DeviceFeatureService(fake,Resources(path,fault),Path.Combine(path,"state")).InstallLocalizationAsync();throw new Exception("accepted "+fault); }
            catch(Exception error) when(error is DeviceFeatureException or InvalidDataException)
            { Check(fake.Uploads.Count==0&&fake.Installs==0,"refuse "+fault+" before staging or installer mutation"); }
        }
        foreach(var code in new[]{"FONT_CHANGED","SCREEN_PROFILE"})
        {
            var path=Path.Combine(root,"helper-"+code);var fake=new Fake(B28){HelperError=code};
            try{await new DeviceFeatureService(fake,Resources(path),Path.Combine(path,"state")).InstallLocalizationAsync();throw new Exception("helper error accepted");}
            catch(DeviceFeatureException error){Check(fake.Installs==1&&error.Message.Contains(code=="FONT_CHANGED"?"ZTEZhengYuan.ttf":"исходные словари"),"exact helper "+code+" refusal is translated without replay");}
        }
        var pendingPath=Path.Combine(root,"independent-pending");var pendingState=Path.Combine(pendingPath,"state");Directory.CreateDirectory(pendingState);
        File.WriteAllText(Path.Combine(pendingState,"pending.json"),"synthetic IMEI pending");File.WriteAllText(Path.Combine(pendingState,"setup-pending.json"),"synthetic setup pending");
        var independent=new Fake(B28){Firmware="b28"};await new DeviceFeatureService(independent,Resources(pendingPath),pendingState).InstallLocalizationAsync();
        Check(independent.Installs==1,"unrelated IMEI/setup journals do not block the screen operation");
        File.WriteAllText(Path.Combine(pendingState,"component-cleanup-pending.json"),"synthetic component cleanup");
        var blocked=new Fake(B28){Firmware="b28"};try{await new DeviceFeatureService(blocked,Resources(pendingPath),pendingState).InstallLocalizationAsync();throw new Exception("cleanup bypass");}catch(DeviceFeatureException){Check(blocked.Commands.Count==0,"actual component-cleanup pending still blocks before transport");}
        if(args.Length>1)
        {
            var capture=Path.GetFullPath(args[1]);var original=File.ReadAllBytes(Path.Combine(capture,"files","zte_topsw_devui"));
            var manifest=File.ReadAllBytes(Path.GetFullPath("Windows_x64/Resources/ScreenLocalization/font.patch.b28.json"));
            var method=typeof(DeviceFeatureService).GetMethod("ApplyScreenFontPatch",BindingFlags.NonPublic|BindingFlags.Static)!;
            var patched=(byte[])method.Invoke(null,[original,manifest])!;
            Check(Hash(original)=="8d2ebbde880934f52195ad9595815d728f7aa4671bb0633d5a5149b09467ae90"&&Hash(patched)=="d6c3cd409705d5aa9c12185c84074513b159088025f005da7dbf01c51e3c3715","private actual B28 UI produces the exact reviewed font-map output without execution");
            Check(original.Length==patched.Length&&original.Length==10880811,"actual B28 patch preserves the full file size");
        }
        if(args.Length>2)
        {
            var original=File.ReadAllBytes(Path.GetFullPath(args[2]));var manifest=File.ReadAllBytes(Path.GetFullPath("Windows_x64/Resources/ScreenLocalization/font.patch.json"));
            var method=typeof(DeviceFeatureService).GetMethod("ApplyScreenFontPatch",BindingFlags.NonPublic|BindingFlags.Static)!;var patched=(byte[])method.Invoke(null,[original,manifest])!;
            Check(Hash(original)=="e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9"&&Hash(patched)=="16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4","private actual B31 UI still produces the unchanged reviewed font-map output");
            Check(original.Length==patched.Length&&original.Length==10946355,"actual B31 patch preserves the full file size");
        }
    }
    sealed class Fake(byte[] original):IRemoteShell
    {
        public string Firmware="b28",State="absent",Revision="20261006";
        public bool PlatformFailure,Drift,ReadFailure;
        public string? HelperError;
        public int StrictReads,MeasuredReads,Installs,Enables,Disables,BackupReads;
        public readonly List<string> Commands=[];
        public readonly Dictionary<string,byte[]> Uploads=new(StringComparer.Ordinal);
        const string Cid="11111111111111111111111111111111",Boot="11111111-1111-1111-1111-111111111111";
        string InstalledHash=>Revision switch {"20260922"=>"6aed6654afb7a4fde7792a5f6034aa41e15b0fd77d794ed04d3a12c111c95fd2","20260923"=>"586a7727fb24a5701990c7cd82889887220c1c5566261c53ca21f3bb12549bfa","20260924"=>"810aae3c07c8019f2d0657f2bad6f1ee38f1dea5f1081210ab144478dd87c7b8",_ => (string)typeof(DeviceFeatureService).GetField("ScreenManagerHash",BindingFlags.NonPublic|BindingFlags.Static)!.GetRawConstantValue()!};
        string Identity()=> (Firmware=="b31"?DeviceFeatureService.FirmwareHash:Firmware=="absent"?"absent":new string('a',64))+"  /firmware/image/modem.b16\n"+(Firmware=="b31"?DeviceFeatureService.RouterHash:Firmware=="absent"?"absent":new string('b',64))+"  /usr/bin/diag-router\n"+Cid+"\n"+(Drift&&MeasuredReads>1?"22222222-2222-2222-2222-222222222222":Boot)+"\n";
        static RemoteResult Reply(string s,int exit=0)=>new(exit,Encoding.UTF8.GetBytes(s),[]);
        string Status()=>"SCREEN_RU_STATUS state="+State+" language="+(State=="enabled"?"cn":"en")+" mounted="+(State=="enabled"?"3":"0")+" boot="+(State=="enabled"?"1":"0")+" pid=3 revision="+Revision+"\n";
        public Task<RemoteResult> RunAsync(string command,byte[]? input=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            ct.ThrowIfCancellationRequested();Commands.Add(command);
            if(command==AccessIdentity.Command){MeasuredReads++;return Task.FromResult(Reply(PlatformFailure?"":Identity(),PlatformFailure?71:0));}
            if(command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router")){StrictReads++;return Task.FromResult(Reply(Identity()));}
            if(command==SshReadProof.SessionCommand)return Task.FromResult(Reply("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n"+Cid+"\n"+Boot+"\n?\n?\n"));
            if(command.StartsWith("if test -e /data/zte-imei-screen-ru"))return Task.FromResult(Reply(State=="absent"?"absent":"present"));
            if(command.Contains("/manager.sh | cut")&&!command.Contains("; sh "))return Task.FromResult(Reply(InstalledHash));
            if(command.Contains("/manager.sh")&&command.Contains("; sh "))
            {
                if(!command.Contains(InstalledHash))throw new Exception("Wrong installed-manager proof");
                if(command.Contains("'enable'")){Enables++;State="enabled";}if(command.Contains("'disable'")){Disables++;State="disabled";}
                return Task.FromResult(Reply(Status()));
            }
            if(command.Contains("SCREEN_RU_STATUS"))return Task.FromResult(Reply(Status()));
            if(command.StartsWith("cat /usr/bin/zte_topsw_devui")||command.StartsWith("cat /data/zte-imei-screen-ru/backup/zte_topsw_devui")){if(command.Contains("/backup/"))BackupReads++;return Task.FromResult(new RemoteResult(ReadFailure?1:0,ReadFailure?[]:original,[]));}
            if(input is not null)
            {
                var match=Regex.Match(command,@"cat > '([^']+)'");if(!match.Success)throw new Exception("unexpected input");var name=Path.GetFileName(match.Groups[1].Value);Uploads.Add(name,input);return Task.FromResult(Reply(Hash(input)+"  "+match.Groups[1].Value));
            }
            if(command.Contains("/install.sh'")&&command.Contains(" install ")){Installs++;if(HelperError is not null)return Task.FromResult(new RemoteResult(1,[],Encoding.UTF8.GetBytes("SCREEN_RU_ERROR "+HelperError+"\n")));State="enabled";Revision="20261006";return Task.FromResult(Reply(Status()));}
            if(command.Contains("/tmp/zte-imei-app.lock")||command.Contains("mkdir -m 700 '/tmp/zte-screen-ru-install-")||command.Contains("rmdir '/tmp/zte-screen-ru-install-"))return Task.FromResult(Reply(""));
            throw new Exception("Unexpected synthetic shell command");
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload API");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download API");
    }
}
