using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

static class ComponentReadTests
{
    internal static async Task Run(string resources)
    {
        void Need(bool condition,string message) { if(!condition)throw new Exception(message);Console.WriteLine("PASS "+message); }
        var root=Path.Combine(Path.GetTempPath(),"zte-component-read-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try
        {
            var shell=new ReadShell();var feature=new DeviceFeatureService(shell,resources,root);
            var status=await feature.GetAgentStatusAsync();
            Need(status.Hash=="absent"&&!status.Running&&!status.StartupReady,"factory reset agent absence is readable");
            Need(shell.Uploads==0&&!shell.Commands.Any(c=>c.Contains("mkdir")||c.Contains("rm -f")),"agent status never creates a remote stage or uploads a file");
            Need(shell.Commands.Count==3&&shell.Commands.All(c=>!c.Contains("sha256sum /firmware")),"agent status uses session proofs and one scoped manager call");
            Need(shell.Inputs.Single().AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(resources,"AgentInstallation/manager.sh"))),"agent status sends exactly pinned manager bytes through stdin");
            Need(shell.Commands.Contains("unset ZTE_AGENT_TEST_ROOT; sh -s -- status"),"agent status clears the test-root environment before running the pinned helper");
            var owner=new ReadShell{AgentOutput="AGENT_SHA absent\nAGENT_PENDING yes\nAGENT_WARNING OWNER\n"};
            var warning=await new DeviceFeatureService(owner,resources,root).GetAgentStatusAsync();
            Need(warning.Warning=="OWNER"&&warning.RecoveryPending&&owner.Uploads==0,"unsafe installer ownership remains a visible warning without preventing read-only status");
            foreach(var output in new[]{"AGENT_SHA absent\nAGENT_WARNING PRIVATE\n","AGENT_SHA absent\nAGENT_RUNNING maybe\n","AGENT_SHA absent\nAGENT_SHA absent\n"})
            {
                try{await new DeviceFeatureService(new ReadShell{AgentOutput=output},resources,root).GetAgentStatusAsync();throw new Exception("accepted bad status");}
                catch(DeviceFeatureException){Need(true,"malformed agent status remains rejected");}
            }
            foreach(var error in new[]{"AGENT_ERROR OWNER\n","AGENT_ERROR CID\n","AGENT_ERROR PRIVATE_VALUE\n"})
            {
                var broken=new ReadShell{AgentError=error};
                try { await new DeviceFeatureService(broken,resources,root).GetAgentStatusAsync();throw new Exception("accepted agent refusal"); }
                catch(DeviceFeatureException e){Need(!e.Message.Contains("PRIVATE_VALUE")&&e.Message.Contains(error.Contains("OWNER")?"OWNER":error.Contains("CID")?"CID":"STATUS_FAILED"),"agent refusal has fixed scoped reason: "+error.Split(' ')[1].Trim());}
                Need(broken.Uploads==0,"failed status does not leave a stage");
            }
            var changed=new ReadShell{ChangeBoot=true};
            try{await new DeviceFeatureService(changed,resources,root).GetAgentStatusAsync();throw new Exception("accepted changed boot");}
            catch(InvalidDataException){Need(changed.Uploads==0,"agent status rejects changed session without writing");}
            var localization=new ReadShell();
            var screen=await new DeviceFeatureService(localization,resources,root).GetLocalizationStatusAsync();
            Need(screen.State=="absent"&&localization.Uploads==0,"factory reset localization absence is readable without firmware equality");
            Need(!localization.Commands.Any(c=>c.Contains("sha256sum /firmware")||c.Contains("/usr/bin/diag-router")),"localization status does not hash unrelated modem/NV binaries");
            foreach(var name in new[]{"imei-pending.json","pending.json","setup-pending.json"}) File.WriteAllText(Path.Combine(root,name),"synthetic pending");
            var independent=new ReadShell{ScreenOwned=true,ScreenError=true};
            var enabled=await new DeviceFeatureService(independent,resources,root).InstallLocalizationAsync();
            Need(enabled.State=="enabled"&&independent.Enables==1&&independent.Uploads==0,"owned localization repair is independent of unrelated NV and setup journal flags");
            Need(independent.Commands.Any(c=>c.Contains("/manager.sh")&&c.Contains("'enable'")&&c.Contains("sha256sum")),"localization still verifies its pinned manager before enabling");
            File.WriteAllText(Path.Combine(root,"component-cleanup-pending.json"),"synthetic pending");
            var competing=new ReadShell{ScreenOwned=true};
            try{await new DeviceFeatureService(competing,resources,root).InstallLocalizationAsync();throw new Exception("accepted competing cleanup");}
            catch(DeviceFeatureException){Need(competing.Enables==0&&competing.Commands.Count==0,"actual component cleanup remains a mutation guard");}
            File.Delete(Path.Combine(root,"component-cleanup-pending.json"));
            var brokenScreen=new ReadShell{ScreenError=true};
            var failure=await new DeviceFeatureService(brokenScreen,resources,root).GetLocalizationStatusAsync();
            Need(failure.State=="error"&&failure.Reason=="STOCK_INIT_MISSING"&&brokenScreen.Commands.Count(c=>c.Contains("reason=STATUS_UNVERIFIED"))==1,"localization reads one scoped failure reason without a mutation");
        }
        finally{Directory.Delete(root,true);}
    }

    sealed class ReadShell:IRemoteShell
    {
        internal List<string> Commands=[];internal List<byte[]> Inputs=[];internal int Uploads,Proofs,Enables;internal bool ChangeBoot,ScreenError,ScreenOwned;internal string? AgentError;internal string AgentOutput="AGENT_SHA absent\n";
        const string Cid="0123456789abcdef0123456789abcdef",Boot="11111111-1111-1111-1111-111111111111";
        static RemoteResult Reply(string s)=>new(0,Encoding.UTF8.GetBytes(s),[]);
        public Task<RemoteResult> RunAsync(string command,byte[]? stdin=null,TimeSpan? timeout=null,CancellationToken ct=default)
        {
            Commands.Add(command);
            if(command.Contains("ZTE_SSH_READ_V1"))return Task.FromResult(Reply("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n?\n"+(ChangeBoot&&++Proofs>1?"22222222-2222-2222-2222-222222222222":Boot)+"\n?\n?\n"));
            if(command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router"))return Task.FromResult(Reply(DeviceFeatureService.FirmwareHash+"  /firmware/image/modem.b16\n"+DeviceFeatureService.RouterHash+"  /usr/bin/diag-router\n"+Cid+"\n"+Boot));
            if(command=="unset ZTE_AGENT_TEST_ROOT; sh -s -- status") {Inputs.Add(stdin!);return Task.FromResult(AgentError is null?Reply(AgentOutput):new RemoteResult(1,[],Encoding.UTF8.GetBytes(AgentError)));}
            if(command.Contains("cat > ")&&stdin is not null){Uploads++;return Task.FromResult(Reply(Convert.ToHexStringLower(SHA256.HashData(stdin))+"  fixture"));}
            if(command.Contains("/manager.sh' status"))return Task.FromResult(Reply("AGENT_SHA absent\n"));
            if(command.StartsWith("set -eu; umask 077; test ! -L /tmp; mkdir")||command.Contains("rm -f "))return Task.FromResult(Reply(""));
            if(command.StartsWith("if test -e /data/zte-imei-screen-ru"))return Task.FromResult(Reply(ScreenOwned?"present":"absent"));
            if(ScreenOwned&&command.Contains("/manager.sh | cut")&&!command.Contains("; sh "))return Task.FromResult(Reply((string)typeof(DeviceFeatureService).GetField("ScreenManagerHash",BindingFlags.NonPublic|BindingFlags.Static)!.GetRawConstantValue()!));
            if(ScreenOwned&&command.Contains("; sh /data/zte-imei-screen-ru/manager.sh"))
            {
                if(command.Contains("'enable'")){Enables++;return Task.FromResult(Reply("SCREEN_RU_STATUS state=enabled language=cn mounted=3 boot=1 pid=3 revision=20260924"));}
                return Task.FromResult(Reply("SCREEN_RU_STATUS state="+(ScreenError?"error":"disabled")+" language=en mounted=0 boot=0 pid=3 revision=20260924"));
            }
            if(command.Contains("SCREEN_RU_STATUS"))return Task.FromResult(Reply("SCREEN_RU_STATUS state="+(ScreenError?"error":"absent")+" language=en mounted=0 boot=0 pid=3 revision=20260924\n"));
            if(command.Contains("reason=STATUS_UNVERIFIED"))return Task.FromResult(Reply(ScreenOwned?"BOOT_HOOK_MISSING\n":"STOCK_INIT_MISSING\n"));
            throw new Exception("Unexpected component read command");
        }
        public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected upload");
        public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("Unexpected download");
    }
}
