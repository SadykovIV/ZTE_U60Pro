using System.Buffers.Binary;
using System.Security.Cryptography;
using ZteImeiStudio.Windows.Core;
static class CustomAgentTests
{
 static int count;
 static void Check(bool ok,string name){if(!ok)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);count++;}
 static async Task Main(string[] args)
 {
  var root=args[0];Directory.CreateDirectory(root);var path=Path.Combine(root,"custom-agent.elf");
  byte[] Elf(){var b=new byte[512];new byte[]{127,69,76,70,2,1,1,0}.CopyTo(b,0);U16(b,16,2);U16(b,18,183);U32(b,20,1);U64(b,24,0x1080);U64(b,32,64);U16(b,52,64);U16(b,54,56);U16(b,56,1);U32(b,64,1);U32(b,68,5);U64(b,80,0x1000);U64(b,96,512);U64(b,104,512);return b;}
  void Reject(byte[] b,string name){try{AgentCandidate.ValidateElf(b);Check(false,name);}catch(InvalidDataException){Check(true,name);}}
  File.WriteAllBytes(path,Elf());var candidate=AgentCandidate.Inspect(path);
  Check(candidate.Bytes==512&&candidate.Interpreter is null&&candidate.Sha256==Convert.ToHexStringLower(SHA256.HashData(Elf())),"ELF selection captures exact bytes and SHA without executing local binary");
  foreach(var fault in new[]{"magic","class","endian","version","osabi","type","machine","ehsize","phsize","empty-table","table-overflow","segment-overflow","memory","entry"})
  {
   var b=Elf();switch(fault){case "magic":b[0]=0;break;case "class":b[4]=1;break;case "endian":b[5]=2;break;case "version":b[6]=0;break;case "osabi":b[7]=9;break;case "type":U16(b,16,1);break;case "machine":U16(b,18,62);break;case "ehsize":U16(b,52,0);break;case "phsize":U16(b,54,0);break;case "empty-table":U16(b,56,0);break;case "table-overflow":U64(b,32,ulong.MaxValue);break;case "segment-overflow":U64(b,72,ulong.MaxValue);break;case "memory":U64(b,104,511);break;case "entry":U64(b,24,0x9999);break;}Reject(b,"invalid ELF refused: "+fault);
  }
  var dynamic=Elf();U16(dynamic,56,2);U32(dynamic,120,3);U64(dynamic,128,300);var loader=System.Text.Encoding.UTF8.GetBytes("/lib/ld-musl-aarch64.so.1\0");loader.CopyTo(dynamic,300);U64(dynamic,152,(ulong)loader.Length);
  Check(AgentCandidate.ValidateElf(dynamic)=="/lib/ld-musl-aarch64.so.1","dynamic ELF exposes bounded valid interpreter");dynamic[300]=(byte)'x';Reject(dynamic,"unsafe interpreter refused");
  var link=Path.Combine(root,"link");File.CreateSymbolicLink(link,path);try{AgentCandidate.Inspect(link);Check(false,"symlink");}catch(InvalidDataException){Check(true,"symbolic link candidate refused");}
  try{AgentCandidate.Inspect(root);Check(false,"directory");}catch(InvalidDataException){Check(true,"directory candidate refused");}
  await PageInstallerTests.RunCustom(Path.GetFullPath("Windows_x64/Resources"),Path.Combine(root,"state"),candidate,Check);
  if(args.Contains("--existing"))await PageInstallerTests.Run(Path.GetFullPath("Windows_x64"),Check);
  Console.WriteLine("TOTAL "+count+" PASS");
 }
 static void U16(byte[] b,int p,ushort v)=>BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(p,2),v);
 static void U32(byte[] b,int p,uint v)=>BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(p,4),v);
 static void U64(byte[] b,int p,ulong v)=>BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(p,8),v);
}
