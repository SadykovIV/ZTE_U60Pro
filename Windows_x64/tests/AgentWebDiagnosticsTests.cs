using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using ZteImeiStudio.Windows.Diagnostics;

static class AgentWebDiagnosticsTests
{
    static int count;
    static void Check(bool ok, string name) { if (!ok) throw new Exception(name); count++; Console.WriteLine("PASS " + name); }
    static async Task Main()
    {
        foreach (var bad in new[] { "192.168.00.1", "192.168.0.1:8080", "host", "192.168.0.1;reboot", "999.1.1.1" })
        { var rejected=false;try{AgentWebDiagnostics.Address(bad);}catch(ArgumentException){rejected=true;}Check(rejected,"Reject noncanonical host " + bad); }
        using var handler=AgentWebDiagnostics.Handler();
        Check(!handler.UseProxy && !handler.AllowAutoRedirect && !handler.UseCookies && !handler.UseDefaultCredentials && handler.Credentials is null,"No proxy, redirects, credentials or cookies");
        var script=AgentWebDiagnostics.Command("192.168.0.1");
        Check(script.Contains("--noproxy '*'") && script.Contains("--output /dev/null") && !script.Contains("--location"),"Remote body never exported or redirected");
        var parsed=AgentWebDiagnostics.Parse("AGENT_WEB lan 200 yes\nAGENT_WEB loopback 200 yes\n");
        Check(parsed.Loopback.Available && parsed.Lan.Available,"Concurrent results accepted in either order");
        foreach(var text in new[]{"AGENT_WEB lan 200 yes\nAGENT_WEB lan 200 yes\n","AGENT_WEB loopback 200 yes SECRET","AGENT_WEB lan 999 yes"})
        {var pair=AgentWebDiagnostics.Parse(text);Check(!pair.Loopback.Available&&!pair.Lan.Available,"Malformed facts cannot certify HTML");}
        foreach(var status in new[]{200,401,404,302})
        {
            var mock=new Wire(status,"text/html");using var client=new HttpClient(mock);
            var reply=await AgentWebDiagnostics.ProbeAsync(AgentWebDiagnostics.Address("192.168.0.1"),client);
            Check(reply.Code==status.ToString()&&reply.Available==(status==200)&&mock.Calls==1,"Header-only HTTP " + status + " without redirect");
        }
        using(var client=new HttpClient(new Wire(200,"application/json"))) Check(!(await AgentWebDiagnostics.ProbeAsync(AgentWebDiagnostics.Address("192.168.0.1"),client)).Available,"HTTP200 JSON is not HTML");
        foreach(var code in new[]{"timeout","refused","302","404"})
        {
            var value=await AgentWebDiagnostics.CollectAsync("192.168.0.1",(_,_)=>Task.FromResult("AGENT_WEB loopback 200 yes\nAGENT_WEB lan 200 yes\n"),(_,_)=>Task.FromResult(new AgentWebObservation(code)));
            Check(value.Loopback.Available&&!value.Computer.Available&&value.Warning is not null&&value.Log.Contains("computer="+code),"PC failure does not erase modem success: "+code);
        }
        foreach(var pair in new[]{("timeout",(Exception)new TaskCanceledException()),("refused",new HttpRequestException("fixture",new SocketException((int)SocketError.ConnectionRefused)))})
        {using var client=new HttpClient(new Wire(0,"",pair.Item2));Check((await AgentWebDiagnostics.ProbeAsync(AgentWebDiagnostics.Address("192.168.0.1"),client)).Code==pair.Item1,"Typed HTTP transport failure "+pair.Item1);}
        var ssh=await AgentWebDiagnostics.CollectAsync("192.168.0.1",(_,_)=>throw new IOException("SSH failed"),(_,_)=>Task.FromResult(new AgentWebObservation("200",true)));
        Check(ssh.Loopback.Code=="ssh-unavailable"&&ssh.Computer.Available&&ssh.Warning is null,"SSH failure preserves independent PC success");
        var invalid=await AgentWebDiagnostics.CollectAsync("bad",(_,_)=>throw new Exception("unexpected SSH"),(_,_)=>throw new Exception("unexpected HTTP"));
        Check(invalid.Computer.Code=="invalid-address","Invalid address performs no I/O");
        using(var client=new HttpClient(new Wire(200,"text/html"))) Check((await AgentWebDiagnostics.ProbeAsync(new Uri("http://127.0.0.1:8080/?secret"),client)).Code=="invalid-address","Probe refuses arbitrary URL shape");
        ZteImeiStudio.Windows.Localization.SetLanguage("en", persist:false);
        var summary = new AgentWebStatus("http://192.168.0.1:8080/",new("200",true),new("404"),new("refused")).Summary;
        var english=ZteImeiStudio.Windows.Localization.Translate(summary);
        Check(!english.Any(c=>c is >= '\u0400' and <= '\u04ff') && english.Contains("HTTP 404 · response is not HTML"),"Dynamic composed summary translates fully to English: " + english);
        Console.WriteLine($"{count} passed, 0 failed; no modem contacted");
    }
    sealed class Wire(int status,string type,Exception? error=null):HttpMessageHandler
    {
        public int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)
        {
            Calls++;Check(request.Method==HttpMethod.Get&&request.Content is null&&!request.Headers.Any(),"Request contains no credentials or body");
            if(error is not null)throw error;
            var content=new UnreadBody();content.Headers.ContentType=new MediaTypeHeaderValue(type);
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status){Content=content});
        }
    }
    sealed class UnreadBody:HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream,TransportContext? context)=>throw new Exception("Body must not be read");
        protected override bool TryComputeLength(out long length){length=123;return true;}
    }
}
