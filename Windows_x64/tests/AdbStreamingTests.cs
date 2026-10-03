using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Research;

internal static class AdbStreamingTests
{
    private static readonly string Template=Path.GetFullPath("Windows_x64/Resources/Onboarding/adb-stream.sh");
    private static byte[] Bytes(string value)=>Encoding.UTF8.GetBytes(value);
    private static string Quote(string value)=>"'"+value.Replace("'","'\\''",StringComparison.Ordinal)+"'";
    private static void Need(bool condition) {if(!condition)throw new Exception("Assertion failed");}
    private static Task Sync(Action action) {action();return Task.CompletedTask;}
    private static async Task Reject(Func<Task> action)
    {try {await action();}catch(Exception e) when(e is IOException or InvalidDataException or ArgumentException or TimeoutException or OperationCanceledException){return;}throw new Exception("Accepted invalid input");}
    private static AdbStreamRequest Change(AdbStreamRequest request,byte[]? input=null,string? wrapper=null)=>new()
    {OriginalCommand=request.OriginalCommand,Wrapper=wrapper??request.Wrapper,Input=input??request.Input,Ready=request.Ready,Begin=request.Begin,Result=request.Result};
    private static Task<AdbStreamResult> Shell(AdbStreamRequest request,TimeSpan? timeout=null,int budget=1<<20,CancellationToken ct=default)=>
        AdbStreamProcess.RunAsync("/bin/sh",["-c",request.Wrapper],request,timeout??TimeSpan.FromSeconds(8),budget,ct);
    private static RemoteResult Decode(AdbStreamResult result,AdbStreamRequest request)
    {Need(!result.Truncated && result.ResultOccurrences==1);return AdbTransport.DecodeShellResult(new(result.LocalExitCode,result.Stdout,result.Stderr),request.Result);}

    public static async Task RunAsync()
    {
        var failed=new List<string>();var passed=0;
        async Task Test(string name,Func<Task> body)
        {try {await body();Console.WriteLine("PASS "+name);passed++;}catch(Exception error){Console.WriteLine("FAIL "+name+" ("+error.GetType().Name+")");failed.Add(name);}}
        var temp=Path.Combine(Path.GetTempPath(),"zte-adb-stream-tests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(temp);
        try
        {
            await Test("Builder pins unchanged shared receiver and bounded argv",()=>Sync(()=>
            {
                var command="printf '%s' 'Тест quote'\n#"+new string('a',24000);var req=AdbStreamProtocol.Build(command,Template);
                Need(req.OriginalCommand==command && Encoding.UTF8.GetByteCount(req.Wrapper)<4096 && !req.Wrapper.Contains("Тест",StringComparison.Ordinal));
                var lines=Encoding.ASCII.GetString(req.Input).Split('\n');Need(lines[..^2].All(line=>line.Length<=320 && line.Length%5==0));
                Need(Regex.IsMatch(lines[^2],"^__ZTE_END_[A-F0-9]{32}__$"));
                Need(new[]{req.Ready,req.Begin,req.Result,lines[^2]}.Select(x=>Regex.Match(x,"[A-F0-9]{32}").Value).Distinct().Count()==4);
            }));
            foreach(var (label,command) in new[]{("NUL","a\0b"),("UTF8 invalid","\ud800"),("oversize",new string('a',131073)),("empty","")})
                await Test("Reject "+label+" before dispatch",()=>Reject(()=>Sync(()=>AdbStreamProtocol.Build(command,Template))));
            await Test("Maximum command bound counts UTF8 bytes and allows exact limit",()=>Sync(()=>
            {
                var accepted=AdbStreamProtocol.Build("#"+new string('a',AdbStreamProtocol.CommandLimit-1),Template);
                Need(accepted.Input.Length<700000);
                try {AdbStreamProtocol.Build(new string('€',AdbStreamProtocol.CommandLimit/3+1),Template);}catch(ArgumentException){return;}
                throw new Exception("UTF8 oversize accepted");
            }));
            await Test("Reject template tamper before dispatch",async()=>
            {var bad=Path.Combine(temp,"bad.sh");File.WriteAllText(bad,File.ReadAllText(Template)+"\n");await Reject(()=>Sync(()=>AdbStreamProtocol.Build("true",bad)));});
            foreach(var ending in new[]{"\n","\r\n","\r\r\n"})
                await Test("PTY echo discarded and binary body preserved EOL"+ending.Length,()=>Sync(()=>
                {
                    var req=AdbStreamProtocol.Build("private synthetic password",Template);var capture=new AdbStreamCapture(req,1024);
                    var prefix=Bytes("noise"+ending+req.Ready+ending).Concat(req.Input).Concat(Bytes(ending+req.Begin+ending)).ToArray();
                    byte[] payload=[0,255,13,13,10,65,13];
                    var raw=prefix.Concat(payload).Concat(Bytes(ending+req.Result+"0"+ending)).ToArray();
                    foreach(var b in raw)capture.Stdout([b]);capture.EndStdout();var result=Decode(capture.Finish(0),req);
                    Need(result.Stdout.SequenceEqual(payload) && result.Stderr.Length==0);
                }));
            await Test("Duplicate boundary rejected even beyond bounded capture",()=>Reject(()=>Sync(()=>
            {
                var req=AdbStreamProtocol.Build("true",Template);var capture=new AdbStreamCapture(req,1);
                capture.Stdout(Bytes(req.Ready+"\n"+req.Begin+"\n"+new string('x',5000)+req.Begin+"\n"));
            })));
            await Test("Duplicate RESULT counted outside prefix and tail",()=>Sync(()=>
            {
                var req=AdbStreamProtocol.Build("true",Template);var capture=new AdbStreamCapture(req,1);
                var raw=Bytes(req.Ready+"\n"+req.Begin+"\n"+req.Result+"0\n"+new string('x',9000)+"\n"+req.Result+"0\n");
                foreach(var b in raw)capture.Stdout([b]);capture.EndStdout();var result=capture.Finish(0);Need(result.ResultOccurrences==2 && result.Truncated);
            }));
            await Test("Pre-BEGIN stderr is discarded including echoed credentials",()=>Sync(()=>
            {
                var req=AdbStreamProtocol.Build("synthetic-private-password",Template);var capture=new AdbStreamCapture(req,1024);
                capture.Stderr(Bytes("synthetic-private-password\n"));capture.Stdout(Bytes(req.Ready+"\n"+req.Begin+"\n"));
                capture.Stderr(Bytes("body-error"));capture.Stdout(Bytes("\n"+req.Result+"1\n"));capture.EndStdout();
                var result=capture.Finish(0);Need(Encoding.UTF8.GetString(result.Stderr)=="body-error");
            }));
            await Test("Malformed footer and nonzero local status stay failures",()=>Sync(()=>
            {
                var req=AdbStreamProtocol.Build("true",Template);
                foreach(var (suffix,local) in new[]{("0\n",1),("00\n",0),("0\nextra",0),("0",0),("0\r\r\r\n",0)})
                {try {AdbTransport.DecodeShellResult(new(local,Bytes("\n"+req.Result+suffix),[]),req.Result);}catch(Exception error) when(error is IOException or InvalidDataException){continue;}throw new Exception("Bad footer accepted");}
            }));
            await Test("Known ADB failure literal only; secret stderr never in exception",()=>Sync(()=>
            {
                var req=AdbStreamProtocol.Build("true",Template);
                foreach(var error in new[]{"synthetic-private-password\n","error: shell command too long\n"})
                {try {AdbTransport.DecodeShellResult(new(1,[],Bytes(error)),req.Result);}catch(IOException exception)
                    {Need(!exception.Message.Contains("synthetic-private-password",StringComparison.Ordinal));Need(exception.Message.Contains("shell command too long",StringComparison.Ordinal)==error.StartsWith("error:",StringComparison.Ordinal));}}
            }));
            if(!OperatingSystem.IsWindows())
            {
                await Test("Real stdin receiver Unicode quotes trailing LF and child EOF",async()=>
                {
                    var req=AdbStreamProtocol.Build("printf '%s\\n' 'Тест $ a'\nif read line; then printf BAD; else printf EOF; fi\n#"+new string('x',24000)+"\n",Template);
                    var result=Decode(await Shell(req),req);Need(result.ExitCode==0 && Encoding.UTF8.GetString(result.Stdout)=="Тест $ a\nEOF");
                });
                foreach(var (command,code) in new[]{("set -e; false; printf BAD",1),("exit 7",7),("exec /bin/sh -c 'exit 9'",9)})
                    await Test("Subshell preserves completion for "+command.Split(';')[0],async()=>
                    {var req=AdbStreamProtocol.Build(command,Template);var result=Decode(await Shell(req),req);Need(result.ExitCode==code && result.Stdout.Length==0);});
                foreach(var kind in new[]{"truncate","tamper","wrong-end"})
                    await Test("Receive verifies all bytes before eval "+kind,async()=>
                    {
                        var sentinel=Path.Combine(temp,"must-not-run-"+kind);var req=AdbStreamProtocol.Build("printf EXECUTED > "+Quote(sentinel)+"\n#"+new string('x',5000),Template);
                        var input=req.Input.ToArray();
                        if(kind=="truncate")input=input[..^20];
                        else if(kind=="tamper")input[4]=input[4]==(byte)'0'?(byte)'1':(byte)'0';
                        else input[^3]=(byte)'X';
                        var changed=Change(req,input);var result=Decode(await Shell(changed),req);
                        Need(result.ExitCode==70 && !File.Exists(sentinel) && Encoding.UTF8.GetString(result.Stdout).StartsWith("ZTE_STREAM_ERROR ",StringComparison.Ordinal));
                    });
                await Test("Partial delivery is never executed before remaining input",async()=>
                {
                    var sentinel=Path.Combine(temp,"only-after-all");var req=AdbStreamProtocol.Build("printf YES > "+Quote(sentinel)+"\n#"+new string('a',4096),Template);
                    var start=new ProcessStartInfo("/bin/sh"){UseShellExecute=false,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};start.ArgumentList.Add("-c");start.ArgumentList.Add(req.Wrapper);
                    using var process=Process.Start(start)!;Need(await process.StandardOutput.ReadLineAsync()=="");Need(await process.StandardOutput.ReadLineAsync()==req.Ready);
                    await process.StandardInput.BaseStream.WriteAsync(req.Input.AsMemory(0,64*5+1));await process.StandardInput.BaseStream.FlushAsync();await Task.Delay(100);Need(!File.Exists(sentinel));
                    await process.StandardInput.BaseStream.WriteAsync(req.Input.AsMemory(64*5+1));process.StandardInput.Close();var output=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();Need(File.ReadAllText(sentinel)=="YES" && output.Contains(req.Result+"0",StringComparison.Ordinal));
                });
                await Test("Input waits for READY and drains PTY-size echo concurrently",async()=>
                {
                    var req=AdbStreamProtocol.Build("#"+new string('a',24000),Template);var helper=Path.Combine(temp,"fake_pty.py");
                    File.WriteAllText(helper,"import sys,select,time\nready,begin,result=sys.argv[1:]\nassert not select.select([sys.stdin],[],[],0.15)[0]\nsys.stdout.write(ready+'\\n');sys.stdout.flush()\nfor line in sys.stdin:\n sys.stdout.write(line);sys.stdout.flush()\n if line.startswith('__ZTE_END_'): break\nsys.stdout.write('\\n'+begin+'\\nOK\\n'+result+'0\\n');sys.stdout.flush()\n");
                    var result=await AdbStreamProcess.RunAsync("/usr/bin/python3",[helper,req.Ready,req.Begin,req.Result],req,TimeSpan.FromSeconds(8),2048,CancellationToken.None);
                    Need(Encoding.UTF8.GetString(Decode(result,req).Stdout)=="OK" && !result.Truncated);
                });
                foreach(var phase in new[]{"before-ready","before-begin","after-begin"})
                    await Test("Bounded timeout redacts partial input "+phase,async()=>
                    {
                        var req=AdbStreamProtocol.Build("private-synthetic-value",Template);
                        var script=phase=="before-ready"?"sleep 5":"printf '%s\\n' "+Quote(req.Ready)+(phase=="after-begin"?" "+Quote(req.Begin):"")+"; cat >/dev/null; sleep 5";
                        try {await AdbStreamProcess.RunAsync("/bin/sh",["-c",script],req,TimeSpan.FromMilliseconds(250),1024,CancellationToken.None);throw new Exception("No timeout");}
                        catch(TimeoutException e){Need(!e.Message.Contains("private-synthetic-value",StringComparison.Ordinal));}
                    });
                await Test("Explicit cancellation retains unknown and never replays",async()=>
                {
                    var req=AdbStreamProtocol.Build("private-synthetic-value",Template);using var stop=new CancellationTokenSource(150);
                    try {await AdbStreamProcess.RunAsync("/bin/sh",["-c","sleep 5"],req,TimeSpan.FromSeconds(5),1024,stop.Token);throw new Exception("No cancellation");}
                    catch(OperationCanceledException){Need(stop.IsCancellationRequested);}
                });
                await Test("Already cancelled request cannot start a process",async()=>
                {
                    var req=AdbStreamProtocol.Build("true",Template);using var cancelled=new CancellationTokenSource();cancelled.Cancel();
                    try {await AdbStreamProcess.RunAsync(Path.Combine(temp,"absent-executable"),[],req,TimeSpan.FromSeconds(5),1024,cancelled.Token);throw new Exception("Started cancelled process");}
                    catch(OperationCanceledException){ }
                });
                await Test("Unknown post-BEGIN timeout never replays completed side effect",async()=>
                {
                    var sentinel=Path.Combine(temp,"once-only");var req=AdbStreamProtocol.Build("printf x >> "+Quote(sentinel)+"; sleep 5",Template);
                    try {await Shell(req,TimeSpan.FromMilliseconds(300));throw new Exception("No timeout");}
                    catch(TimeoutException){Need(File.ReadAllText(sentinel)=="x");}
                });
                var tools=Path.Combine(temp,"Resources","Tools");var resources=Path.Combine(temp,"Resources","Onboarding");Directory.CreateDirectory(tools);Directory.CreateDirectory(resources);File.Copy(Template,Path.Combine(resources,"adb-stream.sh"));
                var adb=Path.Combine(tools,"fake-adb");var countFile=Path.Combine(temp,"dispatch-count");
                File.WriteAllText(adb,"#!/bin/sh\nprintf x >> "+Quote(countFile)+"\ntest \"$1\" = -s && test \"$2\" = synthetic && test \"$3\" = shell || exit 3\ntest \"${#4}\" -lt 4096 || { printf 'error: shell command too long\\n' >&2; exit 1; }\nexec /bin/sh -c \"$4\"\n");File.SetUnixFileMode(adb,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
                await Test("RED old oversized argv fails; GREEN shared Shell streams same body once",async()=>
                {
                    var body="printf FR_FACT\\ root=1\\\\n\n#"+new string('a',12000);var transport=new AdbTransport(adb);
                    var old=await transport.RunAsync(["-s","synthetic","shell","("+body+"); printf oldfooter"]);Need(old.ExitCode==1 && AdbStreamProtocol.KnownLocalError(old.Stderr).Contains("too long",StringComparison.Ordinal));
                    var before=File.ReadAllText(countFile).Length;var result=await transport.ShellAsync("synthetic",body,TimeSpan.FromSeconds(8));
                    Need(result.ExitCode==0 && File.ReadAllText(countFile).Length==before+1 && Encoding.UTF8.GetString(result.Stdout).Contains("root=1",StringComparison.Ordinal));
                });
                await Test("Research long body success authorizes only verified remote zero facts",async()=>
                {
                    var shell=new ResearchAdbShell(adb,"synthetic");var result=await shell.ExecuteAsync("printf 'FR_FACT root=1\\nFR_FACT architecture=aarch64\\n'\n#"+new string('x',12000),8,4096,CancellationToken.None);
                    Need(result.Status=="success" && result.LocalExitCode==0 && result.ExitCode==0 && FirmwareResearchEngine.Facts(result).GetValueOrDefault("root")=="1");
                });
                await Test("Research retains bounded result but truncated output cannot authorize facts",async()=>
                {
                    var shell=new ResearchAdbShell(adb,"synthetic");var result=await shell.ExecuteAsync("printf 'FR_FACT root=1\\n'; printf '%s' "+Quote(new string('x',12000)),8,128,CancellationToken.None);
                    Need(result.Status=="truncated" && result.ExitCode==0 && result.Truncated && result.Stdout.Length<=128 && FirmwareResearchEngine.Facts(result).Count==0);
                });
                await Test("Research nonzero is failed and facts remain unavailable",async()=>
                {
                    var shell=new ResearchAdbShell(adb,"synthetic");var result=await shell.ExecuteAsync("printf 'FR_FACT root=1\\n'; exit 9\n#"+new string('x',4000),8,4096,CancellationToken.None);
                    Need(result.Status=="failed" && result.ExitCode==9 && FirmwareResearchEngine.Facts(result).Count==0);
                });
            }
            await Test("Injected runner receives private original separately and no fallback on failure",async()=>
            {
                var calls=0;var command="synthetic_private_credential\n#"+new string('x',4000);
                var transport=new AdbTransport((arguments,stream,_,_)=>{calls++;Need(stream is not null && stream.OriginalCommand==command && !arguments[^1].Contains("synthetic_private_credential",StringComparison.Ordinal));return Task.FromResult(new RemoteResult(1,[],Bytes("synthetic_private_credential")));},Template);
                await Reject(()=>transport.ShellAsync("synthetic",command));Need(calls==1);
            });
        }
        finally {Directory.Delete(temp,true);}
        Console.WriteLine($"Streaming tests: {passed} passed, {failed.Count} failed");
        if(failed.Count!=0)throw new Exception(string.Join(", ",failed));
    }
}
