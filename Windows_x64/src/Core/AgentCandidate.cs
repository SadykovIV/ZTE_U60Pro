using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Core;

/// <summary>A local executable selected by the user; never executed on the desktop.</summary>
public sealed record AgentCandidate
{
    public const int MaximumBytes = 64 * 1024 * 1024;
    public string Path { get; }
    public long Bytes { get; }
    public string Sha256 { get; }
    public string? Interpreter { get; }
    public string FileName => System.IO.Path.GetFileName(Path);

    private AgentCandidate(string path, byte[] data)
    {
        Path = path; Bytes = data.LongLength;
        Interpreter = ValidateElf(data);
        Sha256 = Convert.ToHexStringLower(SHA256.HashData(data));
    }

    public static AgentCandidate Inspect(string path) => new(System.IO.Path.GetFullPath(path), ReadFile(path));

    public static AgentCandidate FromSelection(string path, long bytes, string sha256)
    {
        var candidate = Inspect(path);
        if (candidate.Bytes != bytes || candidate.Sha256 != sha256) throw new InvalidDataException(Changed);
        return candidate;
    }

    internal byte[] ReadValidatedBytes()
    {
        var data = ReadFile(Path);
        if (data.LongLength != Bytes || Convert.ToHexStringLower(SHA256.HashData(data)) != Sha256)
            throw new InvalidDataException(Changed);
        _ = ValidateElf(data);
        return data;
    }

    private const string Changed = "Выбранный файл изменился. Выберите его заново.";
    private static byte[] ReadFile(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0 ||
            info.Length is < 64 or > MaximumBytes)
            throw new InvalidDataException("Выберите обычный файл агента размером от 64 байт до 64 МиБ; ссылки не поддерживаются.");
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (!input.CanSeek || input.Length != info.Length) throw new InvalidDataException(Changed);
        var data = new byte[(int)input.Length]; input.ReadExactly(data);
        if (input.ReadByte() != -1 || input.Length != data.Length) throw new InvalidDataException(Changed);
        return data;
    }

    public static string? ValidateElf(byte[] data)
    {
        static void Require(bool condition) { if (!condition) throw new InvalidDataException("Нужен исполняемый ELF64 Linux ARM64 с корректными сегментами и точкой входа."); }
        Require(data.Length is >= 64 and <= MaximumBytes);
        ushort U16(int at) => BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(at,2));
        uint U32(int at) => BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(at,4));
        ulong U64(int at) => BinaryPrimitives.ReadUInt64LittleEndian(data.AsSpan(at,8));
        Require(data.AsSpan(0,4).SequenceEqual(new byte[]{0x7f,69,76,70}) && data[4]==2 && data[5]==1 && data[6]==1 &&
            data[7] is 0 or 3 && U16(16) is 2 or 3 && U16(18)==183 && U32(20)==1 && U16(52)==64);
        var table=U64(32); var count=U16(56); var length=(ulong)data.Length;
        Require(U16(54)==56 && count is >=1 and <=128 && table<=length && (ulong)count*56<=length-table);
        var entry=U64(24); var executable=false; string? interpreter=null;
        for(var i=0;i<count;i++)
        {
            var at=(int)table+i*56; var type=U32(at); var flags=U32(at+4);
            var offset=U64(at+8); var address=U64(at+16); var size=U64(at+32); var memory=U64(at+40);
            Require(offset<=length && size<=length-offset);
            if(type==1) { Require(size<=memory); if((flags&1)!=0 && entry>=address && entry-address<size) executable=true; }
            if(type==3)
            {
                Require(interpreter is null && size is >=2 and <=256 && data[(int)(offset+size)-1]==0);
                try { interpreter=new UTF8Encoding(false,true).GetString(data,(int)offset,(int)size-1); }
                catch(DecoderFallbackException) { Require(false); }
                Require(interpreter is not null && Regex.IsMatch(interpreter,@"\A/lib(?:64)?/[A-Za-z0-9._-]+\z"));
            }
        }
        Require(executable); return interpreter;
    }
}
