using System.Reflection;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class OnboardingLayoutTests
{
    internal static async Task RunAsync()
    {
        var count=0;
        void Check(bool ok,string label){if(!ok)throw new Exception("FAIL "+label);Console.WriteLine("PASS "+label);count++;}
        var id="11111111-1111-1111-1111-111111111111";
        var stage="/data/zte-imei-studio/stage-"+id;
        var journal="/data/zte-imei-studio/installations/"+id;
        Check(OnboardingEngine.CredentialOrigin("INSTALL_AGENT new\n")==true&&OnboardingEngine.CredentialOrigin("INSTALL_AGENT preserved\n")==false,"only exact installer credential receipts identify new or preserved startup");
        foreach(var output in new[]{"", "INSTALL_AGENT unknown\n", "INSTALL_AGENT new\nINSTALL_AGENT preserved\n", "INSTALL_AGENT preserved extra\n"})
            Check(OnboardingEngine.CredentialOrigin(output) is null,"missing or contradictory credential receipt still requires authentication");
        var command=(string)typeof(OnboardingEngine).GetMethod("StagePreparationCommand",BindingFlags.NonPublic|BindingFlags.Static)!.Invoke(null,[stage,"synthetic-owner"])!;
        Check(!command.Contains("/data/local")&&!command.Contains("/data/bin")&&command.Contains("anchor=/data/zte-imei-studio"),"new stage uses private anchor without modifying stock777 parents");
        Check(command.Contains("safe_dir /data")&&command.Contains("mkdir -m 700 \"$anchor\"")&&command.Contains("stat -c %a \"$anchor\")\" = 700")&&!command.Contains("chmod"),"private anchor is checked as root700 and existing parent permissions are never rewritten");
        var pending=new OnboardingPending{Id=id,RestoreRequested=true,Phase="restore-requested"};
        var paths=OnboardingEngine.InstallationPaths(pending);
        Check(paths.Stage==stage&&paths.Journal==journal&&paths.DropbearKey=="/data/zte-imei-studio/bin/dropbearkey","restored but undispatched setup selects current private layout");
        Check(pending.RestoreRequested&&!pending.InstallRequested&&!pending.CanRequestRestore(false,false),"layout selection does not reset restore-requested or grant replay");
        pending.RemoteStage=stage;pending.RemoteJournal=journal;pending.InstallRequested=true;pending.Phase="install-requested";
        pending=JsonSerializer.Deserialize<OnboardingPending>(JsonSerializer.Serialize(pending))!;
        Check(OnboardingEngine.InstallationPaths(pending)==paths,"new installation paths survive the pending journal roundtrip");
        var old=new OnboardingPending{Id=id,InstallRequested=true,Phase="install-requested"};
        var legacy=OnboardingEngine.InstallationPaths(old);
        Check(legacy.Stage=="/data/local/tmp/zte-imei-setup-"+id&&legacy.Journal=="/data/local/tmp/zte-imei-installations/"+id&&legacy.DropbearKey=="/data/bin/dropbearkey","old requested setup retains original stage, journal and key reader");
        old.RemoteJournal=legacy.Journal;
        Check(OnboardingEngine.InstallationPaths(old)==legacy,"old ready journal does not migrate to a new installer");
        foreach(var malformed in new[]{
            new OnboardingPending{Id=id,InstallRequested=true,RemoteStage=stage,RemoteJournal=legacy.Journal},
            new OnboardingPending{Id=id,InstallRequested=true,RemoteStage="/tmp/unowned",RemoteJournal=journal},
            new OnboardingPending{Id=id,InstallRequested=true,RemoteJournal=journal},
            new OnboardingPending{Id=id,RemoteStage=stage},
            new OnboardingPending{Id="../unsafe",InstallRequested=true}})
        {
            try{_=OnboardingEngine.InstallationPaths(malformed);Check(false,"malformed remote layout rejected");}
            catch(InvalidDataException){Check(true,"malformed remote layout rejected");}
        }
        var storage=Path.Combine(Path.GetTempPath(),"zte-install-layout-"+Guid.NewGuid());Directory.CreateDirectory(Path.Combine(storage,"SSH"));
        try
        {
            File.WriteAllText(Path.Combine(storage,"SSH","id_ed25519"),"synthetic-unused-key");
            foreach(var item in new[]{old,pending})
            {
                var expected=OnboardingEngine.InstallationPaths(item);
                var calls=new List<string>();
                var identity=new DeviceIdentity(new string('a',32),new string('b',64),"22222222-2222-2222-2222-222222222222",new string('c',64));
                var adb=new AdbTransport((args,_,_)=>
                {
                    if(args[0]=="devices")return Task.FromResult(new RemoteResult(0,"synthetic-usb device usb:1\n"u8.ToArray(),[]));
                    if(args[0]=="-d")return Task.FromResult(new RemoteResult(0,"synthetic-usb\n"u8.ToArray(),[]));
                    if(args[0]!="-s"||args[2]!="shell")throw new Exception("Unexpected non-read ADB operation");
                    var cmd=args[^1];calls.Add(cmd);
                    var marker=Regex.Match(cmd,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                    string body;
                    if(cmd.Contains("cat '"+expected.Journal+"/state'"))body="ready";
                    else if(cmd.Contains("observed_hash()"))body=identity.FirmwareHash+"  /firmware/image/modem.b16\n"+identity.RouterHash+"  /usr/bin/diag-router\n"+identity.Cid+"\n"+identity.BootId;
                    else if(cmd.Contains("'"+expected.DropbearKey+"' -y -f /etc/dropbear/dropbear_ed25519_host_key"))body="invalid synthetic host key";
                    else throw new Exception("Unexpected resume command");
                    return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(body+"\n"+marker+"0\n"),[]));
                });
                var engine=new OnboardingEngine("192.0.2.1",storage,"unused",adb);
                try
                {
                    var task=(Task<OnboardingResult>)typeof(OnboardingEngine).GetMethod("ResumeInstallationAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(engine,[item,"synthetic-usb",identity,null,"synthetic-password",CancellationToken.None])!;
                    await task;Check(false,"invalid synthetic host key blocks resume");
                }
                catch(InvalidDataException){Check(calls.Count==3&&calls[0].Contains(expected.Journal)&&calls[2].Contains(expected.DropbearKey),"actual resume reads saved layout and refuses invalid key without upload, restart or reinstall");}
            }
        }
        finally{Directory.Delete(storage,true);}
        var authStorage=Path.Combine(Path.GetTempPath(),"zte-install-auth-"+Guid.NewGuid());Directory.CreateDirectory(Path.Combine(authStorage,"SSH"));
        try
        {
            File.WriteAllText(Path.Combine(authStorage,"SSH","id_ed25519"),"synthetic-unused-key");
            var web=new WebIdentity("353490068701222","CN_ZTE_MU5250V1.0.0B31","BD_CNMU5250V1.0.0B31");
            var device=new DeviceIdentity(new string('a',32),ImeiEngine.FirmwareHash,"22222222-2222-2222-2222-222222222222",ImeiEngine.RouterHash);
            var proof=device.FirmwareHash+"  /firmware/image/modem.b16\n"+device.RouterHash+"  /usr/bin/diag-router\n"+device.Cid+"\n"+device.BootId+"\n"+JsonSerializer.Serialize(new{imei=web.Imei,integrate_version=web.Firmware,wa_inner_version=web.Inner});
            var blob=new byte[51];blob[3]=11;"ssh-ed25519"u8.CopyTo(blob.AsSpan(4));blob[18]=32;
            var remote=new RejectedAuth(proof);
            var adb=new AdbTransport((args,_,_)=>
            {
                if(args[0]!="-s"||args[2]!="shell")throw new Exception("Unexpected non-read ADB operation");
                var cmd=args[^1];var marker=Regex.Match(cmd,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                var body=cmd.Contains("/state'")?"ready":cmd.Contains("dropbearkey'")?"ssh-ed25519 "+Convert.ToBase64String(blob):cmd.Contains("observed_hash()")?proof:throw new Exception("Unexpected ADB operation");
                return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(body+"\n"+marker+"0\n"),[]));
            });
            var engine=new OnboardingEngine("192.0.2.1",authStorage,"unused",adb){InstalledSshFactory=()=>remote};
            var genericDevice=device with {FirmwareHash=new string('b',64)};
            var genericProof=genericDevice.FirmwareHash+"  /firmware/image/modem.b16\n"+genericDevice.RouterHash+"  /usr/bin/diag-router\n"+genericDevice.Cid+"\n"+genericDevice.BootId;
            var genericAdb=new AdbTransport((args,_,_)=>
            {
                if(args[0]=="devices")return Task.FromResult(new RemoteResult(0,"synthetic-usb device usb:1\n"u8.ToArray(),[]));
                if(args[0]=="-d")return Task.FromResult(new RemoteResult(0,"synthetic-usb\n"u8.ToArray(),[]));
                if(args[0]!="-s"||args[2]!="shell")throw new Exception("Unexpected mutating ADB operation");
                var cmd=args[^1];var marker=Regex.Match(cmd,"__ZTE_RESULT_[A-F0-9]{32}__").Value;
                var body=cmd.Contains("dropbearkey'")?"ssh-ed25519 "+Convert.ToBase64String(blob):cmd.Contains("observed_hash()")?genericProof:throw new Exception("Unexpected ADB operation");
                return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(body+"\n"+marker+"0\n"),[]));
            });
            var preserved=new RejectedAuth(genericProof);
            var preservedEngine=new OnboardingEngine("192.0.2.1",authStorage,"unused",genericAdb){InstalledSshFactory=()=>preserved};
            pending.NewAgent=false;pending.Profile="linux-arm64-access";
            try
            {
                await (Task<DeviceIdentity>)typeof(OnboardingEngine).GetMethod("PinAndVerifySshAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(preservedEngine,[pending,"synthetic-usb",genericDevice,null,"synthetic-new-unused-password",CancellationToken.None])!;
                Check(false,"ordinary preparation does not bypass an incorrect supplied agent password");
            }
            catch(InvalidDataException){Check(preserved.AuthCalls==1&&preserved.Writes==0,"ordinary preparation requires the supplied password even for preserved startup");}
            foreach(var force in new[]{false,true})
            {
                pending.NewAgent=force?false:true;pending.ForceReinstall=force;
                try{await (Task<DeviceIdentity>)typeof(OnboardingEngine).GetMethod("PinAndVerifySshAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(preservedEngine,[pending,"synthetic-usb",genericDevice,null,"synthetic-wrong-password",CancellationToken.None])!;Check(false,"new or forced agent requires supplied password");}
                catch(InvalidDataException){Check(preserved.AuthCalls== (force?3:2)&&preserved.Writes==0,"new or forced agent still requires authentication, force="+force);}
            }
            pending.ForceReinstall=false;
            pending.Profile="b31";
            pending.NewAgent=false;pending.Phase="ready";pending.BackupDirectory=Path.Combine(authStorage,"SetupBackups",id);
            Directory.CreateDirectory(pending.BackupDirectory);
            try
            {
                await (Task<OnboardingResult>)typeof(OnboardingEngine).GetMethod("ResumeInstallationAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(engine,[pending,"synthetic-usb",device,web,"synthetic-new-unused-password",CancellationToken.None])!;
                Check(false,"ordinary B31 ready resume requires the supplied password");
            }
            catch(InvalidDataException){Check(remote.AuthCalls==1&&remote.Writes==0&&remote.Commits==0&&pending.Phase=="ready","ordinary B31 ready resume refuses incorrect password without NV or install replay");}
            pending.Phase="install-requested";
            pending.NewAgent=null;
            try
            {
                await (Task<OnboardingResult>)typeof(OnboardingEngine).GetMethod("ResumeInstallationAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(engine,[pending,"synthetic-usb",device,web,"synthetic-wrong-password",CancellationToken.None])!;
                Check(false,"B31 resume requires agent authentication even when installation output was lost");
            }
            catch(InvalidDataException)
            {
                Check(remote.AuthCalls==2&&remote.Writes==0&&pending.Phase=="install-requested"&&pending.NewAgent is null,"B31 resume refuses wrong agent password before commit even when NewAgent is unknown");
            }
        }
        finally{Directory.Delete(authStorage,true);}
        if (!OperatingSystem.IsWindows())
        {
            var fixture=Path.Combine(Path.GetTempPath(),"zte-commit-guard-"+Guid.NewGuid());Directory.CreateDirectory(fixture);
            try
            {
                var device=new DeviceIdentity(new string('a',32),ImeiEngine.FirmwareHash,"22222222-2222-2222-2222-222222222222",ImeiEngine.RouterHash);
                var previous=new OnboardingPending{Id=id,InstallRequested=true,Profile="b31"};
                var owner=string.Join(' ',new[]{id}.Concat(OnboardingEngine.InstallerPolicy(device,"b31")));
                foreach(var state in new[]{"unsafe-parent","wrong-owner","symlink-script","hardlinked-script","mode-script","replace-after-open","good"})
                {
                    var folder=Path.Combine(fixture,state);var data=Path.Combine(folder,"data");var staged=Path.Combine(data,"local/tmp/zte-imei-setup-"+id);Directory.CreateDirectory(staged);
                    foreach(var dir in new[]{data,Path.Combine(data,"local"),Path.Combine(data,"local/tmp")})File.SetUnixFileMode(dir,(UnixFileMode)Convert.ToInt32("755",8));
                    File.SetUnixFileMode(staged,(UnixFileMode)Convert.ToInt32("700",8));
                    foreach(var name in new[]{".owner",".install-requested"}){File.WriteAllText(Path.Combine(staged,name),owner+"\n");File.SetUnixFileMode(Path.Combine(staged,name),(UnixFileMode)Convert.ToInt32("600",8));}
                    var script=Path.Combine(staged,"setup-agent.sh");File.WriteAllText(script,"#!/bin/sh\nprintf ORIGINAL_COMMIT\n");File.SetUnixFileMode(script,(UnixFileMode)Convert.ToInt32("600",8));
                    if(state=="unsafe-parent")File.SetUnixFileMode(Path.Combine(data,"local"),(UnixFileMode)Convert.ToInt32("777",8));
                    if(state=="wrong-owner")File.WriteAllText(Path.Combine(staged,".owner"),"foreign\n");
                    if(state=="symlink-script"){File.Move(script,script+".real");File.CreateSymbolicLink(script,script+".real");}
                    if(state=="hardlinked-script"){var link=new ProcessStartInfo("/bin/ln");link.ArgumentList.Add(script);link.ArgumentList.Add(script+".hard");using var proc=Process.Start(link)!;await proc.WaitForExitAsync();}
                    if(state=="mode-script")File.SetUnixFileMode(script,(UnixFileMode)Convert.ToInt32("666",8));
                    // Host paths and root UID are substituted only in this offline shell fixture.
                    var fdHook=state=="replace-after-open"?"mv \"$script\" \"$script.original\"; printf '#!/bin/sh\\nprintf REPLACED\\n' >\"$script\"; chmod 600 \"$script\"; ":"";
                    var stat="stat() { case \"$2\" in %u) printf '0\\n';; %a) /usr/bin/stat -f %Lp \"$3\";; %h) /usr/bin/stat -f %l \"$3\";; %s) /usr/bin/stat -f %z \"$3\";; %d:%i:%u:%a:%h) if [ \"$1\" = '-Lc' ]; then "+fdHook+"/usr/bin/python3 -c 'import os; s=os.fstat(9); print(\"%d:%d:0:%o:%d\"%(s.st_dev,s.st_ino,s.st_mode&4095,s.st_nlink))'; else /usr/bin/stat -f '%d:%i:0:%Lp:%l' \"$3\"; fi;; *) exit 88;; esac; };\n";
                    var body=OnboardingEngine.CommitCommand(previous,device).Replace("/data",data,StringComparison.Ordinal).Replace("/proc/self/fd/9","/dev/fd/9",StringComparison.Ordinal);
                    var start=new ProcessStartInfo("/bin/sh"){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};start.ArgumentList.Add("-c");start.ArgumentList.Add(stat+body);
                    using var child=Process.Start(start)!;var output=child.StandardOutput.ReadToEndAsync();var error=child.StandardError.ReadToEndAsync();await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                    var stdout=await output;var stderr=await error;
                    Check(state=="good"?child.ExitCode==0&&stdout=="ORIGINAL_COMMIT":child.ExitCode!=0&&stdout==""&&stderr.Contains("INSTALL_ERROR COMMIT_STAGE_UNSAFE"),"actual legacy commit refuses unsafe stage before executing original script: "+state);
                }
            }
            finally{Directory.Delete(fixture,true);}
        }
        Console.WriteLine($"RESULT {count} installation layout checks; no device");
    }
    private sealed class RejectedAuth(string proof):IRemoteShell
    {
        public int AuthCalls,Writes,Commits;
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            if(command.Contains("observed_hash()"))return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes(proof),[]));
            if(command.Contains("AGENT_ACCESS_PROOF"))return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes("AGENT_ACCESS_PROOF "+AgentPackage.Sha256+" 100 200\n"),[]));
            if(command.Contains("'--commit'")){Commits++;return Task.FromResult(new RemoteResult(0,Encoding.UTF8.GetBytes("INSTALL_COMMITTED /data/zte-imei-studio/installations/11111111-1111-1111-1111-111111111111\n"),[]));}
            if(command.Contains("/api/auth/login")&&stdin is not null){if(!command.Contains("http://192.0.2.1:9090/api/auth/login"))throw new Exception("Login did not use the selected address");AuthCalls++;return Task.FromResult(new RemoteResult(22,[],[]));}
            throw new Exception("Unexpected post-install action before credential proof");
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default){Writes++;throw new Exception("Unexpected upload");}
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
}
