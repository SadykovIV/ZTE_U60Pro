using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

static class PageInstallerTests
{
 public static async Task Run(string root,Action<bool,string> check)
 {
  var storage=Path.Combine(Path.GetTempPath(),"zte-launcher-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(storage);
  DeviceFeatureService Service(FakeShell s)=>new(s,Path.Combine(root,"Resources"),storage);
  async Task Reject(Func<Task> action,string label){try{await action();}catch(Exception e){check(!e.Message.Contains("PRIVATE"),"installer errors remain fixed: "+label);check(true,label);return;}throw new Exception("accepted "+label);}
  try
  {
   foreach(var absent in new[]{false,true})
   {
    var shell=new FakeShell{FreshVpn=absent,Pages=new LauncherPages(new[]{"vpn","info"}).Encode()};
    var oldHash=shell.Hash;var layout=shell.Layout.ToArray();var pages=shell.Pages.ToArray();
    var installed=await Service(shell).InstallAgentAsync();
    check(installed.IsCurrent&&installed.Running&&installed.BackupHash==oldHash,"bundled agent update confirms current binary and preserved backup, VPN absent="+absent);
    check(shell.Events.SequenceEqual(absent?new[]{"dashboard_preflight","agent_install","dashboard_install"}:new[]{"vpn_preflight","agent_install","vpn_controller","vpn_dashboard","vpn_launcher"}),"bundled agent update keeps controller/launcher dependency chain coherent, VPN absent="+absent);
    check(shell.Layout.SequenceEqual(layout)&&shell.Pages!.SequenceEqual(pages)&&shell.StagedPages==0,"bundled agent update preserves exact page selection and information layout");
    check(!shell.Events.Contains("vpn_components")&&!shell.Requests.Any()&&!shell.Commands.Any(c=>c.Contains("set_enabled")||c.Contains("configure_wifi")),"bundled update never installs absent VPN, enables it or changes profiles");
    check(shell.Commands.Count(c=>c.Contains("mkdir /tmp/zte-imei-app.lock"))==1,"bundled dependency update uses one shared device lock");
    shell=new FakeShell{FreshVpn=absent,FailPhase=absent?"dashboard_preflight":"vpn_preflight",Failure="exit1"};
    await Reject(()=>Service(shell).InstallAgentAsync(),"bundled update preflight refusal, VPN absent="+absent);
    check(shell.Events.SequenceEqual(new[]{shell.FailPhase}),"bundled preflight refusal happens before installed component writes");
   }
   var alreadyCurrent=new FakeShell{Hash=AgentPackage.Sha256};await Service(alreadyCurrent).InstallAgentAsync();
   check(alreadyCurrent.Events.SequenceEqual(new[]{"vpn_preflight","vpn_controller","vpn_dashboard","vpn_launcher"}),"already-current agent still repairs related VPN components without reinstalling binary");
   const string previousCardCheckHash="413ba4b0a07540d6901e87e74c9730196eb3373cf35b8914e31a8194bfe5a839";
   check(AgentPackage.VersionForHash(previousCardCheckHash)=="2.9.0-esim.2"&&AgentPackage.SupportedUpgradeHashes.Contains(previousCardCheckHash),"previous card-check release remains a known upgrade source after repackaging");
   var previousCardCheck=new FakeShell{Hash=previousCardCheckHash,Pages=new LauncherPages(new[]{"esim","info"}).Encode()};
   var previousLayout=previousCardCheck.Layout.ToArray();var previousPages=previousCardCheck.Pages.ToArray();
   var previousUpgraded=await Service(previousCardCheck).InstallAgentAsync();
   check(previousUpgraded.IsCurrent&&previousUpgraded.Running&&!previousUpgraded.RecoveryPending&&previousUpgraded.BackupHash==previousCardCheckHash,"previous card-check agent upgrades to current with verified running state and original backup");
   check(previousCardCheck.Events.SequenceEqual(new[]{"vpn_preflight","agent_install","vpn_controller","vpn_dashboard","vpn_launcher"}),"previous card-check agent follows the complete owned component upgrade chain once");
   check(previousCardCheck.Layout.SequenceEqual(previousLayout)&&previousCardCheck.Pages!.SequenceEqual(previousPages)&&previousCardCheck.StagedPages==0,"previous card-check upgrade preserves saved page order and information layout");
   check(!previousCardCheck.Requests.Any()&&!previousCardCheck.Commands.Any(c=>c.Contains("set_enabled")||c.Contains("configure_wifi")),"previous card-check upgrade does not activate VPN or change profiles");
   var customBundled=new FakeShell{Hash=new string('f',64)};await Reject(()=>Service(customBundled).InstallAgentAsync(),"unknown installed agent blocks VPN dependency update");
   check(customBundled.Events.Count==0,"unknown agent refuses before modifying any installed component");
   check(!customBundled.Commands.Any(c=>c.Contains("/manager.sh' install ")||c.Contains("/upgrade-controller.sh' ")||c.Contains("/update-agent.sh' ")||c.Contains("/install-launcher.sh' ")),"unknown installed agent never dispatches an installed component update; temporary staging is permitted");
   foreach(var phase in new[]{"vpn_preflight","vpn_controller","vpn_dashboard","vpn_launcher"})
   {
    var uncertain=new FakeShell{FailPhase=phase,Failure="timeout"};await Reject(()=>Service(uncertain).InstallAgentAsync(),"uncertain bundled dependency update "+phase);
    check(!uncertain.Cleanup.Contains("zte-vpn-agent")&&uncertain.Events.Count(e=>e==phase)==1,"uncertain dependency update retains its own rollback stage and never retries");
   }
   foreach(var wanted in new[]{Array.Empty<string>(),new[]{"esim","info"},new[]{"vpn","info","esim"}})
   {
    var shell=new FakeShell{FreshVpn=true,LauncherApplied=true};var result=await Service(shell).ApplyLauncherPagesAsync(new LauncherPages(wanted));
    check(result.Pages!.Order.SequenceEqual(wanted)&&!result.Pages.UsesDefault,"atomic apply accepts ordered selection count="+wanted.Length);
    check(shell.PageWrites==1&&!shell.Events.Any(),"page apply writes once without installer or restart");
    check(shell.Commands.Any(c=>c.Contains("mv -f ")&&c.Contains("/proc/sys/kernel/random/boot_id")&&c.Contains("0:600:1")&&c.Contains("-le 128")),"page write checks identity, ownership, bounds and atomic rename");
    if(wanted.Length==0)await CheckActualMetadataGuard(shell.Commands.Single(c=>c.Contains("mv -f ")),check);
   }
   foreach(var absent in new[]{true,false})
   {
    var shell=new FakeShell{FreshVpn=absent,Pages=new LauncherPages(new[]{"vpn","info"}).Encode()};
    var answer=await Service(shell).InstallEsimLauncherAsync();
    check(answer.Pages!.Order.SequenceEqual(new[]{"vpn","info","esim"}),"eSIM install appends only missing eSIM while retaining order, VPN absent="+absent);
    check(shell.StagedPages>=1,"page configuration is an input to transactional installer");
    shell=new FakeShell{FreshVpn=absent,Pages=new LauncherPages(new[]{"esim","vpn"}).Encode()};
    answer=await Service(shell).InstallEsimLauncherAsync();
    check(answer.Pages!.Order.SequenceEqual(new[]{"esim","vpn"})&&shell.StagedPages==0,"existing eSIM order is preserved without replacing page config");
    shell=new FakeShell{FreshVpn=absent};answer=await Service(shell).InstallLauncherPagesAsync(new LauncherPages([]));
    check(answer.Pages!.Order.Count==0&&!answer.Pages.UsesDefault,"generic installer explicitly supports only stock pages, VPN absent="+absent);
   }
   var publicLegacy=new FakeShell{Hash=AgentPackage.LegacyPublicSha256,VpnStatusHash="f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4"};var legacyStatus=await Service(publicLegacy).GetVpnStatusAsync();check(legacyStatus.Installed&&!legacyStatus.HelperReady&&legacyStatus.AgentReady,"public 2.8.0 agent and old controller readable but require upgrade");check(publicLegacy.Requests.Count==1&&publicLegacy.Requests[0].Contains("status"),"legacy controller receives only status");await Reject(()=>Service(publicLegacy).SetVpnEnabledAsync(true),"legacy controller refuses enable before update");check(publicLegacy.Requests.All(x=>x.Contains("status")),"legacy mutation attempt never sends mutation request");
   var broken=new FakeShell{UnsafePages=true,LauncherApplied=true};await Reject(()=>Service(broken).ApplyLauncherPagesAsync(new LauncherPages([])),"unsafe existing page file denies apply");check(broken.PageWrites==0,"unsafe page file is never replaced");
   var malformed=new FakeShell{Pages=Encoding.ASCII.GetBytes("ZTE_LAUNCHER_PAGES_V1\ninfo\ninfo\n")};await Reject(()=>Service(malformed).InstallEsimLauncherAsync(),"malformed installed page file denies installation before writes");check(malformed.Events.Count==0&&malformed.StagedPages==0,"invalid installed configuration is not silently replaced");
   var badReadback=new FakeShell{LauncherApplied=true,CorruptPageReadback=true};await Reject(()=>Service(badReadback).ApplyLauncherPagesAsync(new LauncherPages(new[]{"info"})),"wrong page readback denies success");
   var bootChanged=new FakeShell{LauncherApplied=true,ChangeBootOnUpload=true};await Reject(()=>Service(bootChanged).ApplyLauncherPagesAsync(new LauncherPages(new[]{"vpn"})),"boot change before atomic page write denied");check(bootChanged.PageWrites==0,"changed boot emits no page replacement");
   var changedPrefs=new FakeShell{LauncherApplied=true,ChangePagesOnUpload=true};await Reject(()=>Service(changedPrefs).ApplyLauncherPagesAsync(new LauncherPages(new[]{"vpn"})),"concurrent page configuration change denies replacement");check(changedPrefs.PageWrites==0,"fresh missing-file guard detects concurrent config creation");
   var existingPrefs=new FakeShell{LauncherApplied=true,Pages=new LauncherPages(new[]{"info"}).Encode()};await Service(existingPrefs).ApplyLauncherPagesAsync(new LauncherPages(new[]{"vpn"}));check(existingPrefs.Commands.Any(c=>c.Contains("mv -f ")&&c.Contains(Convert.ToHexStringLower(SHA256.HashData(new LauncherPages(new[]{"info"}).Encode())))),"existing configuration hash is guarded before replacement");
   var unknownWrite=new FakeShell{LauncherApplied=true,UnknownPageWrite=true};await Reject(()=>Service(unknownWrite).ApplyLauncherPagesAsync(new LauncherPages([])),"unknown page write is not retried");check(unknownWrite.PageWrites==0&&!unknownWrite.Cleanup.Contains(".page-layout"),"uncertain page staging retained");
   var infoGuard=new FakeShell{LauncherApplied=true};await Service(infoGuard).ApplyLauncherLayoutAsync(LauncherLayout.Default);
   await CheckActualInfoTypeGuard(infoGuard.Commands.Single(c=>c.Contains("mv -f ")),check);
   foreach(var previousHash in new[]{"9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce","cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0","3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca"})
   {
   var legacy=new FakeShell{VpnStatusHash=previousHash};
   var legacyState=await Service(legacy).GetVpnStatusAsync();
   check(legacyState.Configured&&legacyState.Enabled&&legacyState.Profiles.Count==1,"pinned previous vpnctl retains read-only configured inventory before upgrade");
   var currentHash=(string)typeof(DeviceFeatureService).GetField("VpnHelperHash",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic)!.GetRawConstantValue()!;
   check(legacyState.HelperReady==(legacy.VpnStatusHash==currentHash),"legacy status read does not mark old controller ready for writes");
   if(legacy.VpnStatusHash!=currentHash){await Reject(()=>Service(legacy).SetVpnEnabledAsync(true),"legacy controller refuses mutation until upgrade");check(legacy.Requests.All(x=>x=="status"),"legacy controller emitted no mutation request");}
   check(legacy.Commands.Any(c=>c.EndsWith("/vpnctl request")&&c.Contains(legacy.VpnStatusHash))&&legacy.Requests.Count>0&&legacy.Requests.All(x=>x=="status"),"legacy inventory invokes only exact pinned status request");
   }
   check(AgentPackage.VersionForHash(AgentPackage.LegacyEsimRadioSha256)=="2.7.0-esim.6"&&AgentPackage.SupportsVpn(AgentPackage.LegacyEsimRadioSha256),"released agent .6 recognized as legacy");
   check(AgentPackage.VersionForHash("8fd6d783ceb597d313b75ade5a19aa9f65a9e3594601d3213e7fe97eceaa9ca2")==null,"failed .5 candidate is not accepted");
   var unknown=new FakeShell{VpnStatusHash=new string('f',64)};
   check(!(await Service(unknown).GetVpnStatusAsync()).HelperReady&&unknown.Requests.Count==0,"unrecognized vpnctl is never executed");
   foreach(var absent in new[]{true,false})
   {
    var s=new FakeShell{FreshVpn=absent};var original=s.Layout.ToArray();var result=await Service(s).InstallEsimLauncherAsync();
    check(result.State=="ready"&&s.Layout.SequenceEqual(original),"generic page installer preserves saved layout, VPN absent="+absent);
    check(s.Events.SequenceEqual(absent?new[]{"launcher_preflight","dashboard_preflight","agent_install","dashboard_install","launcher_install"}:new[]{"launcher_preflight","vpn_preflight","agent_install","vpn_controller","vpn_dashboard","vpn_launcher"}),"exact one-time dependency pipeline, VPN absent="+absent);
    check(!s.Events.Contains("vpn_components"),"eSIM page installer never installs absent VPN");
    check(!s.Commands.Any(c=>c.EndsWith("/vpnctl request")||c.Contains("set_enabled")||c.Contains("configure_wifi")),"existing VPN profile and enable state are not explicitly changed");
    s=new FakeShell{FreshVpn=absent,FailPhase="launcher_preflight",Failure="exit1"};await Reject(()=>Service(s).InstallEsimLauncherAsync(),"launcher preflight refusal VPN absent="+absent);
    check(s.Events.SequenceEqual(new[]{"launcher_preflight"}),"preflight refusal precedes all component changes");
   }
   foreach(var phase in new[]{"launcher_preflight","launcher_install"})foreach(var failure in new[]{"timeout","exit255","missing-exit"})
   {
    var s=new FakeShell{FreshVpn=true,FailPhase=phase,Failure=failure};await Reject(()=>Service(s).InstallEsimLauncherAsync(),"uncertain "+phase+"/"+failure);
    check(!s.Cleanup.Contains("zte-vpn-agent"),"unknown launcher outcome retains its rollback inputs");check(s.Events.Count(x=>x==phase)==1,"uncertain install is not retried");
   }
   var custom=new FakeShell{Hash=new string('f',64)};await Reject(()=>Service(custom).InstallEsimLauncherAsync(),"unknown agent refused before VPN changes");check(!custom.Events.Contains("agent_install")&&!custom.Events.Contains("vpn_controller"),"unknown agent does not mutate controller or agent");
   var mismatch=new FakeShell{FreshVpn=true,ChangeLayout=true};await Reject(()=>Service(mismatch).InstallEsimLauncherAsync(),"unexpected saved layout change denies final success");
   var delayed=new FakeShell{FreshVpn=true,StartAfterProbes=2};
   check((await Service(delayed).InstallEsimLauncherAsync()).Running&&delayed.Events.Count(x=>x=="launcher_install")==1,"read-only poll tolerates delayed startup without reinstalling");
   var stopped=new FakeShell{FreshVpn=true,Stopped=true};await Reject(()=>Service(stopped).InstallEsimLauncherAsync(),"installed files without running Launcher cannot claim page ready");
  }
  finally{Directory.Delete(storage,true);}
 }
 static async Task CheckActualMetadataGuard(string command,Action<bool,string> check)
 {
  var path=Path.Combine(Path.GetTempPath(),"zte-page-guard-"+Guid.NewGuid().ToString("N"));await File.WriteAllTextAsync(path,"fixture");
  try{
   var start=command.IndexOf("f='/data/zte-launcher/page-layout.conf';",StringComparison.Ordinal);var end=command.IndexOf("; fi;",start,StringComparison.Ordinal)+5;
   var clause=command[start..end].Replace("'/data/zte-launcher/page-layout.conf'","'"+path+"'").Replace("$(stat -c %s \"$f\")","7");
   foreach(var metadata in new[]{"0:644:1","1000:600:1","0:600:2"}){
    var script="set -e; "+clause.Replace("$(stat -c %u:%a:%h \"$f\")",metadata)+" printf reached";
    async Task<(int,string)> Run(string text){using var p=new System.Diagnostics.Process{StartInfo=new("/bin/sh"){RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true}};p.Start();await p.StandardInput.WriteAsync(text);p.StandardInput.Close();var output=await p.StandardOutput.ReadToEndAsync();await p.WaitForExitAsync();return(p.ExitCode,output);}
    var old=await Run(script.Replace(" || exit 73",""));var fixedResult=await Run(script);
    check(old==(0,"reached")&&fixedResult.Item1==73&&!fixedResult.Item2.Contains("reached"),"actual shell RED to GREEN: unsafe metadata "+metadata);
   }
   var missingStart=command.IndexOf("test ! -e \"$f\" && test ! -L \"$f\"",end,StringComparison.Ordinal);
   var missing=command[missingStart..(command.IndexOf(';',missingStart)+1)];
   async Task<(int,string)> RunMissing(string text){using var p=new System.Diagnostics.Process{StartInfo=new("/bin/sh"){RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true}};p.Start();await p.StandardInput.WriteAsync("set -e; f='"+path+"'; "+text+" printf reached");p.StandardInput.Close();var output=await p.StandardOutput.ReadToEndAsync();await p.WaitForExitAsync();return(p.ExitCode,output);}
   var previous=await RunMissing(missing.Replace(" || exit 73",""));var current=await RunMissing(missing);
   check(previous==(0,"reached")&&current.Item1==73&&!current.Item2.Contains("reached"),"actual shell RED to GREEN: missing-file CAS rejects concurrent creation");
  }finally{File.Delete(path);}
 }
 static async Task CheckActualInfoTypeGuard(string command,Action<bool,string> check)
 {
  var dir=Path.Combine(Path.GetTempPath(),"zte-info-guard-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);
  try{
   var file=Path.Combine(dir,"original");await File.WriteAllTextAsync(file,"fixture");var link=Path.Combine(dir,"link");File.CreateSymbolicLink(link,file);
   var start=command.IndexOf("f='/data/zte-launcher/info-layout.conf';",StringComparison.Ordinal);var end=command.IndexOf("; fi;",start,StringComparison.Ordinal)+5;
   foreach(var path in new[]{link,dir}){
    var clause=command[start..end].Replace("'/data/zte-launcher/info-layout.conf'","'"+path+"'").Replace("$(stat -c %u:%a:%h \"$f\")","0:600:1");
    async Task<(int,string)> Run(string text){using var p=new System.Diagnostics.Process{StartInfo=new("/bin/sh"){RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true}};p.Start();await p.StandardInput.WriteAsync("set -e; "+text+" printf reached");p.StandardInput.Close();var output=await p.StandardOutput.ReadToEndAsync();await p.WaitForExitAsync();return(p.ExitCode,output);}
    var old=await Run(clause.Replace(" || exit 73",""));var fixedResult=await Run(clause);
    check(old==(0,"reached")&&fixedResult.Item1==73&&!fixedResult.Item2.Contains("reached"),"actual info-layout shell RED to GREEN: "+(path==link?"symlink":"directory"));
   }
  }finally{Directory.Delete(dir,true);}
 }
    sealed class FakeShell:IRemoteShell
    {
        const string Cid="0123456789abcdef0123456789abcdef"; string Boot="01234567-89ab-cdef-0123-456789abcdef";
        public byte[]? Pages; public bool UnsafePages,CorruptPageReadback,ChangeBootOnUpload,UnknownPageWrite,ChangePagesOnUpload;public int PageWrites,StagedPages;readonly Dictionary<string,byte[]> Uploads=[];
        public string Hash=AgentPackage.LegacyVpnSha256;public string? BackupHash;
        public string FailPhase="",Failure="";public bool FreshVpn;public bool LauncherApplied,ChangeLayout,Stopped;public byte[] Layout=new LauncherLayout("tiles",LauncherLayout.MetricIds.Reverse().Select((id,i)=>new LauncherMetric(id,i<4)).ToArray()).Encode();
        public int StartAfterProbes, RunningProbes; public List<string> Events=[],Commands=[],Cleanup=[],Requests=[]; public string VpnStatusHash="missing";
        static RemoteResult Reply(string s="")=>new(0,Encoding.UTF8.GetBytes(s),[]);
        RemoteResult Step(string phase,string output="")
        {
            Events.Add(phase);
            if(FailPhase==phase)
            {
                if(Failure=="timeout")throw new TimeoutException("PRIVATE device transport text");
                if(Failure=="wrong-marker")return Reply("WRONG_MARKER");
                return new(Failure=="exit255"?255:Failure=="missing-exit"?-1:1,[],Encoding.UTF8.GetBytes("PRIVATE LPA:1$operator$matching\nVPN_AGENT_UNSAFE_PARENT"));
            }
            return Reply(output);
        }
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            Commands.Add(command);
            if(command == "set -eu; test -f /data/zte-agent && test ! -L /data/zte-agent; sha256sum /data/zte-agent | cut -d ' ' -f1") return Task.FromResult(Reply(Hash));
            if(command.StartsWith("set -eu; uname -m; id -u; sha256sum /usr/bin/zte_topsw_devui"))
            {
                string Pin(string name)=>(string)typeof(DeviceFeatureService).GetField(name,System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static)!.GetRawConstantValue()!;
                return Task.FromResult(Reply("aarch64\n0\ne3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9\na30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35\npresent\n0:700\nzte-native-launcher-v1\n"+Cid+"\n"+(LauncherApplied?Pin("LauncherHash"):new string('a',64))+"\n"+(LauncherApplied?Pin("LauncherManifestHash"):new string('b',64))+"\nenabled\nservice-ok\nintegrity-ok\nclear"));
            }
            if(command.StartsWith("set -eu; f=/data/zte-launcher/page-layout.conf"))return Task.FromResult(Reply(UnsafePages?"unsafe":Pages is null?"missing":"data\n"+Convert.ToBase64String(Pages)));
            if(command.StartsWith("set -eu; f=/data/zte-launcher/info-layout.conf"))return Task.FromResult(Reply("data\n"+Convert.ToBase64String(Layout)));
            if(command.StartsWith("if test -f /tmp/zte-launcher/ready"))return Task.FromResult(Reply(Stopped||(LauncherApplied&&++RunningProbes<StartAfterProbes)?"stopped":"running"));
            if(command=="if test -e /data/zte-vpn || test -L /data/zte-vpn; then echo present; else echo absent; fi")return Task.FromResult(Reply(FreshVpn?"absent":"present"));
            if(command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router"))return Task.FromResult(Reply("604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263  /firmware/image/modem.b16\n55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f  /usr/bin/diag-router\n"+Cid+"\n"+Boot));
            if(stdin is not null&&command.Contains("cat > ")){var path=Regex.Match(command,"cat > '([^']+)'").Groups[1].Value;Uploads[path]=stdin.ToArray();if(path.EndsWith("page-layout.conf"))StagedPages++;if(path.Contains("/.page-layout-")&&ChangePagesOnUpload)Pages=new LauncherPages(new[]{"esim"}).Encode();if(path.Contains("/.page-layout-")&&ChangeBootOnUpload)Boot="11234567-89ab-cdef-0123-456789abcdef";return Task.FromResult(Reply(Convert.ToHexStringLower(SHA256.HashData(stdin))+"  "+path));}
            if(command.Contains("/manager.sh' status"))return Task.FromResult(Reply("AGENT_SHA "+Hash+"\nAGENT_RUNNING yes\nAGENT_STARTUP yes\n"+(BackupHash is null?"":"AGENT_BACKUP "+BackupHash+"\n")));
            if(command.Contains("/manager.sh' install ")){var r=Step("agent_install");if(r.Success){BackupHash=Hash;Hash=AgentPackage.Sha256;}return Task.FromResult(r);}
            if(command.Contains("; sh '/tmp/zte-dashboard-stage-")){var id=Regex.Match(command,@"/tmp/zte-dashboard-stage-([0-9a-f-]{36})/").Groups[1].Value;return Task.FromResult(command.EndsWith(" preflight")?Step("dashboard_preflight","DASHBOARD_PREFLIGHT "+id):Step("dashboard_install","DASHBOARD_INSTALLED "+id));}
            if(command.Contains("; sh '/tmp/zte-vpn-agent-"))
            {
                if(command.Contains("/update-agent.sh' "))return Task.FromResult(command.EndsWith(" preflight")?Step("vpn_preflight","VPN_AGENT_PREFLIGHT_OK"):Step("vpn_dashboard","VPN_AGENT_UPDATED"));
                if(command.Contains("/upgrade-controller.sh' "))return Task.FromResult(Step("vpn_controller"));
                if(command.Contains("/install-launcher.sh' "))
                {
                    if(command.EndsWith(" preflight"))return Task.FromResult(Step("launcher_preflight","LAUNCHER_PREFLIGHT_OK"));
                    var r=Step(FreshVpn?"launcher_install":"vpn_launcher","LAUNCHER_INSTALLED");
                    if(r.Success){LauncherApplied=true;if(ChangeLayout)Layout=LauncherLayout.Default.Encode();var stage=Regex.Match(command,@"/tmp/zte-vpn-agent-[0-9a-f-]{36}").Value;if(Uploads.TryGetValue(stage+"/page-layout.conf",out var pages))Pages=pages;}return Task.FromResult(r);
                }
            }
            if(command.Contains("; sh '/tmp/zte-vpn-install-"))return Task.FromResult(Step("vpn_components","VPN_COMPONENTS_INSTALLED"));
            if(command.StartsWith("for c in lua "))return Task.FromResult(Reply());
            if(command.StartsWith("if test -e /data/zte-vpn"))return Task.FromResult(Reply(FreshVpn?"ABSENT":"PRESENT"));
            if(command=="test -d /data/zte-vpn && test ! -L /data/zte-vpn && echo SAFE")return Task.FromResult(Reply("SAFE"));
            if(command.StartsWith("set -eu; if test -e /data/zte-vpn"))return Task.FromResult(Reply("PRESENT\n"+VpnStatusHash+"\n"+Hash+"\nmissing\nmissing"));
            if(command.EndsWith("/vpnctl request")){
                using var json=System.Text.Json.JsonDocument.Parse(stdin!);Requests.Add(json.RootElement.GetProperty("action").GetString()!);
                return Task.FromResult(Reply("{\"ok\":true,\"data\":{\"schema_version\":1,\"configured\":true,\"enabled\":true,\"core_running\":true,\"profiles\":[{\"id\":\"fixture-profile\",\"name\":\"synthetic\",\"transport\":\"vless\",\"active\":true}],\"active_profile\":\"fixture-profile\"}}"));
            }
            if(command.Contains("mv -f ")&&command.Contains("/info-layout.conf")){var path=Regex.Match(command,"mv -f '([^']+)'").Groups[1].Value;Layout=Uploads[path];return Task.FromResult(Reply());}
            if(command.Contains("; mkdir -m 700 '/data/zte-launcher/.info-layout-"))return Task.FromResult(Reply());
            if(command.Contains("mv -f ")&&command.Contains("/page-layout.conf")){
                if(UnknownPageWrite)throw new TimeoutException();
                if(!command.Contains("= '"+Boot+"'"))return Task.FromResult(new RemoteResult(1,[],[]));
                var missing=command.Contains("test ! -e \"$f\" && test ! -L \"$f\" || exit 73; ");
                if(missing?Pages is not null:Pages is null||!command.Contains(Convert.ToHexStringLower(SHA256.HashData(Pages))))return Task.FromResult(new RemoteResult(1,[],[]));
                var path=Regex.Match(command,"mv -f '([^']+)'").Groups[1].Value;Pages=CorruptPageReadback?new LauncherPages(new[]{"esim"}).Encode():Uploads[path];PageWrites++;return Task.FromResult(Reply());
            }
            if(command.Contains("; mkdir -m 700 '/data/zte-launcher/.page-layout-"))return Task.FromResult(Reply());
            if(command.Contains("rm -f ")&&command.Contains("; rmdir ")){foreach(var p in new[]{"zte-agent-stage","zte-dashboard-stage","zte-vpn-agent","zte-vpn-install",".page-layout"})if(command.Contains("/tmp/"+p+"-")||command.Contains("/data/zte-launcher/"+p+"-"))Cleanup.Add(p);return Task.FromResult(Reply());}
            if(command.Contains("rm /tmp/zte-imei-app.lock/owner && rmdir /tmp/zte-imei-app.lock")||command.Contains("mkdir /tmp/zte-imei-app.lock")||command.StartsWith("set -eu; umask 077; test ! -L /tmp; mkdir -m 700 "))return Task.FromResult(Reply());
            throw new Exception("Unexpected fake command");
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new NotSupportedException();
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new NotSupportedException();
    }
}
