using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Features;

static class AppReadTests
{
 static int count;
 static void Check(bool value,string name){if(!value)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);count++;}
 static async Task<int> Main(string[] args){try{await Run(args[0],args[1]);Console.WriteLine("TOTAL "+count+" PASS");return 0;}catch(Exception e){Console.WriteLine(e);return 1;}}
 static async Task Run(string root,string asset)
 {
  var binary=await File.ReadAllBytesAsync(asset);var resources=Path.GetFullPath("Windows_x64/Resources");
  Check(Hash(binary)=="38ba859187c953d159cdd4f1ff397feb5f29116e0bfc7dc284c45b1a6766c770","offline asset is exact approved SSClash binary, never executed locally");
  DeviceFeatureService Service(Fake f,string name,byte[]? bytes=null)=>new(f,resources,Path.Combine(root,name)){SsclashAssetLoader=_=>Task.FromResult(bytes??binary)};
  foreach(var fw in new[]{"b28","absent","b31"}){
   var f=new Fake{Firmware=fw};var s=Service(f,fw);var installed=await s.InstallSsclashAsync("Synthetic123!","192.0.2.1");
   Check(installed.SsclashInstalled&&installed.SsclashRunning&&!installed.SsclashProxyRunning&&f.Measured>=3&&f.Strict==0,fw+" SSClash actual install uses measured proof and stopped proxy");
   Check(f.PasswordStdin&&!f.Commands.Any(x=>x.Contains("Synthetic123!"))&&f.Starts==1&&f.Uploads==2,fw+" one install keeps password on stdin");
   var removed=await s.RemoveSsclashAsync(Path.Combine(root,fw,"backup"));
   Check(!f.Installed&&f.Commits==1&&await File.ReadAllBytesAsync(removed.LocalArchive) is var saved&&saved.SequenceEqual(f.Archive),fw+" remove commits only after exact local archive");
  }
  foreach(var fault in new[]{"platform","abi","drift","preflight","asset","password","auth","anonymous","proxy"}){
   var f=new Fake{Fault=fault};var s=Service(f,"bad-"+fault,fault=="asset"?[1,2,3]:null);
   try{await s.InstallSsclashAsync("Synthetic123!","192.0.2.1");throw new Exception("accepted "+fault);}catch(Exception e)when(e is DeviceFeatureException or InvalidDataException){
    Check(f.Starts<=1&&f.Commits==0,"SSClash refuses "+fault+" without retry");
    if(fault is "platform" or "abi" or "drift" or "preflight" or "asset")Check(f.Uploads==0,"SSClash "+fault+" stops before upload");
   }
  }
  foreach(var fault in new[]{"archive","remove-drift"}){
   var f=new Fake{Fault=fault,Installed=true};try{await Service(f,fault).RemoveSsclashAsync(Path.Combine(root,fault));throw new Exception("accepted "+fault);}catch(Exception e)when(e is DeviceFeatureException or InvalidDataException){Check(f.Commits==0&&(fault!="remove-drift"||!f.RemovalPrepared),"removal "+fault+" refuses before delete commit or preparation on changed device");}
  }
  foreach(var fw in new[]{"b28","absent","b31"}){
   var f=new Fake{Firmware=fw};var s=Service(f,"opkg-"+fw);Directory.CreateDirectory(Path.Combine(root,"opkg-"+fw));await File.WriteAllTextAsync(Path.Combine(root,"opkg-"+fw,"pending.json"),"synthetic");
   Check(!(await s.GetPrivateOpkgStatusAsync()).Installed&&f.Uploads==0&&f.Strict==0,fw+" absent opkg status is read-only stdin with unrelated NV pending");
   f.OpkgInstalled=true;var feeds=await s.ReadPrivateOpkgFeedsAsync();Check(feeds.Release=="23.05.4"&&f.Uploads==0&&f.OpkgCalls==2,fw+" owned opkg feed read requires no mutation stage");
  }
  foreach(var op in new[]{"install","list","save"}){
   var f=new Fake();var s=Service(f,"strict-"+op);try{if(op=="install")await s.InstallPrivateOpkgAsync();else if(op=="list")await s.RunPrivateOpkgCommandAsync("list");else await s.SavePrivateOpkgFeedsAsync("",Fake.Generation);throw new Exception("mutations opened");}catch(DeviceFeatureException){Check(f.OpkgCalls==0&&f.Uploads==0,"opkg "+op+" retains old mutation policy");}
  }
  foreach(var fault in new[]{"platform","drift","opkg"}){
   var f=new Fake{Fault=fault};try{await Service(f,"opkg-bad-"+fault).GetPrivateOpkgStatusAsync();throw new Exception("accepted "+fault);}catch(Exception e)when(e is DeviceFeatureException or InvalidDataException){Check(f.Uploads==0,"opkg status refuses "+fault+" without staging");}
  }
 }
 static string Hash(byte[] b)=>Convert.ToHexStringLower(SHA256.HashData(b));
 sealed class Fake:IRemoteShell
 {
  public const string Generation="g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  public string Firmware="b28",Fault="";public bool Installed,PasswordStdin,OpkgInstalled,RemovalPrepared;public int Measured,Strict,Uploads,Starts,Commits,OpkgCalls;public List<string> Commands=[];
  public readonly byte[] Archive=Encoding.UTF8.GetBytes("synthetic private archive");string archivePath="";
  const string Cid="11111111111111111111111111111111",Boot="11111111-1111-1111-1111-111111111111";
  static RemoteResult Result(string s,int code=0)=>new(code,code==0?Encoding.UTF8.GetBytes(s):[],code==0?[]:Encoding.UTF8.GetBytes(s));
  string Identity()=> (Firmware=="b31"?DeviceFeatureService.FirmwareHash:Firmware=="absent"?"absent":new string('a',64))+"  /firmware/image/modem.b16\n"+(Firmware=="b31"?DeviceFeatureService.RouterHash:Firmware=="absent"?"absent":new string('b',64))+"  /usr/bin/diag-router\n"+Cid+"\n"+((Fault is "drift" or "remove-drift")&&Measured>1?"22222222-2222-2222-2222-222222222222":Boot)+"\n";
  string Inventory()=>"__RELEASE__\nDISTRIB_RELEASE='"+(Fault=="abi"?"24.10":"23.05.4")+"'\nDISTRIB_ARCH='aarch64_cortex-a53'\n__DATA__\nFilesystem Blocks Used Available Use Mount\ndata 999999 1 999998 1% /data\n__MEM__\nMemAvailable: 100000 kB\n__PACKAGES__\nPackage: curl\nVersion: 1\nStatus: install ok installed\n\n__FLAGS__\nopkg=0\npresent="+(Installed?1:0)+"\nssclash="+(Installed?1:0)+"\nrunning="+(Installed?1:0)+"\nproxy="+(Fault=="proxy"?1:0)+"\n";
  string Opkg()=>"__ZTE_PRIVATE_OPKG_V1__\ninstalled="+(OpkgInstalled?1:0)+"\ngeneration="+(OpkgInstalled?Generation:"none")+"\nprevious=unset\nrollback=0\nfree_kib=999999\nrunning=0\n__END__\n";
  public Task<RemoteResult> RunAsync(string command,byte[]? input=null,TimeSpan? timeout=null,CancellationToken ct=default){Commands.Add(command);RemoteResult r;
   if(command==AccessIdentity.Command){Measured++;r=Result(Fault=="platform"?"PLATFORM":Identity(),Fault=="platform"?71:0);}
   else if(command.Contains("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router")){Strict++;r=Result(Identity());}
   else if(command.Contains("/tmp/zte-diag-"))throw new DeviceFeatureException("diagnostic inventory unavailable in fixture");
   else if(command.Contains("printf '__RELEASE__"))r=Result(Inventory());
   else if(command=="curl --config -"){
    var data=Encoding.UTF8.GetString(input!);
    if(data.Contains("/login\"")&&!data.Contains("data ="))r=Result("HTTP/1.1 200 OK\r\nSet-Cookie: csrf=synthetic\r\n\r\n<form action=\"/login\"><input name=\"csrf\" value=\"synthetic\"></form>");
    else if(data.Contains("data ="))r=Result(Fault=="auth"?"HTTP/1.1 403 Bad\r\n\r\n{}":"HTTP/1.1 302 Found\r\nSet-Cookie: session=ok\r\n\r\n");
    else if(data.Contains("Cookie: session=ok"))r=Result("HTTP/1.1 200 OK\r\n\r\n{\"running\":"+(Fault=="proxy"?"true":"false")+"}");
    else r=Result(Fault=="anonymous"?"HTTP/1.1 200 OK\r\n\r\n{}":"HTTP/1.1 401 No\r\n\r\n{}");
   }
   else if(command.Contains("SSCLASH_PLATFORM=openwrt")){PasswordStdin=input!=null&&Encoding.UTF8.GetString(input)=="Synthetic123!\n";r=Result("",Fault=="password"?1:0);}
   else if(command.Contains("/bin/ssclash'")&&command.EndsWith(" version"))r=Result("ssclash 6.4.1\n");
   else if(command.Contains("/ssclash-service")||command.Contains("cat /etc/init.d/zte_imei_ssclash"))r=Result(File.ReadAllText("Windows_x64/Resources/Applications/ssclash-service.sh").Replace("__ZTE_LAN_IPV4__","192.0.2.1"));
   else if(command.Contains("sh -s -- 'prepare'")){RemovalPrepared=true;var id=Regex.Match(command,@"sh -s -- 'prepare' '([^']+)'").Groups[1].Value;archivePath="/data/zte-imei-apps/.removals/"+id+"/archive.tar.gz";r=Result("SSCLASH_ARCHIVE sha256="+Hash(Archive)+" bytes="+Archive.Length);}
   else if(command.Contains("sh -s -- 'commit'")){Commits++;Installed=false;r=Result("SSCLASH_REMOVED archive="+archivePath);}
   else if(command.StartsWith("sh -s -- 'inspect'")||command.StartsWith("sh -s -- 'read-feeds'")){OpkgCalls++;if(input==null||!Encoding.UTF8.GetString(input).Contains("ROOT=$BASE/opkg-private"))throw new Exception("unpinned opkg body");r=Fault=="opkg"?Result("OPKG_ERROR OWNER",1):Result((command.Contains("'read-feeds'")?"__ZTE_OPKG_FEEDS_V1__\nrelease=23.05.4\narchitecture=aarch64_cortex-a53\ngeneration="+Generation+"\nkey=b5043e70f9a75cde\nsource=src/gz base https://example.org/base\n__END_FEEDS__\n":"")+Opkg());}
   else if(input!=null&&command.Contains("cat > '")){Uploads++;var p=Regex.Match(command,@"cat > '([^']+)'").Groups[1].Value;r=Result(Hash(input)+"  "+p);}
   else if(command.Contains("; sh '")&&command.Contains("/manager.sh'"))throw new DeviceFeatureException("diagnostic tools unavailable in fixture");
   else if(command.Contains("/etc/init.d/zte_imei_ssclash start")){Starts++;Installed=true;r=Result("");}
   else if(command.Contains("command -v procd"))r=Result("",Fault=="preflight"?73:0);
   else if(command.Contains("/tmp/zte-imei-app.lock")||command.Contains("mkdir -m 700 '/tmp/")||command.Contains("; rmdir '/tmp/"))r=Result("");
   else throw new Exception("Unexpected synthetic command: "+command[..Math.Min(command.Length,90)]);
   return Task.FromResult(r);
  }
  public Task UploadAsync(string path,byte[] data,TimeSpan? timeout=null,CancellationToken ct=default)=>throw new Exception("unexpected upload");
  public Task<byte[]> DownloadAsync(string path,TimeSpan? timeout=null,CancellationToken ct=default){if(path!=archivePath)throw new Exception("unexpected archive");return Task.FromResult(Fault=="archive"?new byte[]{1}:Archive);}
 }
}
