using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Core;

public sealed record BackupPatchResult(byte[] OriginalOuter, byte[] PatchedEncrypted,
    bool AlreadyEnabled, string OriginalHash, string PatchedHash);

/// <summary>
/// The verified B31 web-backup format. No tar entry is ever extracted to the
/// Windows file system. Only etc/rc.local is changed, then both archive layers
/// are reparsed and compared before returning upload bytes.
/// </summary>
public static class BackupPatch
{
    public const string RcPath = "etc/rc.local";
    public const string UsbNode = "/sys/class/android_usb/android0/usb_op";
    public const string EnableLine = "echo 1 > " + UsbNode + "\n";
    private const string InnerPath = "tmp/back_parameter_r1.tgz";
    private const string Md5Path = "tmp/back_parameter_r.md5";
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly Regex UsbNodePattern = new(
        "/sys/[^\\s`\"']*usb_op[^\\s`\"']*", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static BackupPatchResult Prepare(byte[] encrypted, string imei,
        string suffix)
    {
        ArgumentNullException.ThrowIfNull(encrypted);
        if (!ImeiCodec.IsValid(imei)) throw new InvalidDataException("IMEI устройства не проходит проверку Luhn.");
        if (string.IsNullOrEmpty(suffix) || Encoding.UTF8.GetByteCount(suffix) > 128 || suffix.Contains('\0'))
            throw new InvalidDataException("Некорректный Backup-key suffix.");
        var password = imei + suffix;
        var originalOuter = BackupCipher.Decrypt(encrypted, password);
        var original = Inspect(originalOuter);
        var rc = original.Inner.Members.Single(m => m.Path == RcPath).Bytes;
        var patchedRc = EnableAdb(rc);
        if (patchedRc.AsSpan().SequenceEqual(rc))
            return new BackupPatchResult(originalOuter, encrypted, true, Sha(encrypted), Sha(encrypted));

        var innerTar = original.Inner.Replace(new Dictionary<string, byte[]> { [RcPath] = patchedRc });
        var patchedInner = BackupGzip.Compress(innerTar);
        var md5 = Encoding.ASCII.GetBytes(Convert.ToHexString(MD5.HashData(patchedInner)).ToLowerInvariant() + "\n");
        var outerTar = original.Outer.Replace(new Dictionary<string, byte[]>
        {
            [InnerPath] = patchedInner,
            [Md5Path] = md5,
        });
        var patchedOuter = BackupGzip.Compress(outerTar);
        var verified = Inspect(patchedOuter);
        original.Inner.Verify(verified.Inner, new Dictionary<string, byte[]> { [RcPath] = patchedRc });
        original.Outer.Verify(verified.Outer, new Dictionary<string, byte[]>
        {
            [InnerPath] = patchedInner,
            [Md5Path] = md5,
        });
        var patchedEncrypted = BackupCipher.Encrypt(patchedOuter, password);
        if (!BackupCipher.Decrypt(patchedEncrypted, password).AsSpan().SequenceEqual(patchedOuter))
            throw new InvalidDataException("Проверка шифрования резервной копии не пройдена.");
        return new BackupPatchResult(originalOuter, patchedEncrypted, false,
            Sha(encrypted), Sha(patchedEncrypted));
    }

    public static (BackupTar Outer, BackupTar Inner) Inspect(byte[] outerGzip)
    {
        var outer = new BackupTar(BackupGzip.Decompress(outerGzip));
        if (outer.Members.Count != 2 || outer.Members[0].Path != InnerPath ||
            outer.Members[1].Path != Md5Path || outer.Members.Any(m => !m.IsFile))
            throw new InvalidDataException("Неизвестная структура внешнего архива B31.");
        var compressedInner = outer.Members[0].Bytes;
        var expectedMd5 = Encoding.ASCII.GetBytes(Convert.ToHexString(MD5.HashData(compressedInner)).ToLowerInvariant() + "\n");
        if (!outer.Members[1].Bytes.AsSpan().SequenceEqual(expectedMd5))
            throw new InvalidDataException("MD5 внутреннего архива не совпал.");
        var inner = new BackupTar(BackupGzip.Decompress(compressedInner));
        var rc = inner.Members.SingleOrDefault(m => m.Path == RcPath);
        if (rc is null || !rc.IsFile || rc.Bytes.Length > 128 * 1024)
            throw new InvalidDataException("В бэкапе отсутствует обычный etc/rc.local допустимого размера.");
        return (outer, inner);
    }

    public static byte[] EnableAdb(byte[] rcLocal)
    {
        string text;
        try { text = StrictUtf8.GetString(rcLocal); }
        catch (DecoderFallbackException) { throw new InvalidDataException("Неизвестная кодировка rc.local."); }
        const string shebang = "#!/bin/sh\n";
        if (text.Contains('\0') || text.Split(shebang, StringSplitOptions.None).Length != 2)
            throw new InvalidDataException("Неизвестный заголовок rc.local.");
        var heading = text.IndexOf(shebang, StringComparison.Ordinal);
        if (heading < 0 || text[..heading].Split('\n').Any(line =>
                line.Trim().Length > 0 && !line.Trim().StartsWith('#')))
            throw new InvalidDataException("Команды перед заголовком rc.local не поддерживаются.");
        var nodes = UsbNodePattern.Matches(text).Select(m => m.Value).ToHashSet(StringComparer.Ordinal);
        if (nodes.Count != 1 || !nodes.Contains(UsbNode))
            throw new InvalidDataException("USB-путь rc.local отличается от проверенного B31.");
        if (text.AsSpan(heading).StartsWith(shebang + EnableLine, StringComparison.Ordinal)) return rcLocal;
        if (text.Contains(EnableLine, StringComparison.Ordinal))
            throw new InvalidDataException("Строка включения ADB расположена неоднозначно.");
        return StrictUtf8.GetBytes(text.Insert(heading + shebang.Length, EnableLine));
    }

    private static string Sha(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}

internal static class BackupCipher
{
    public const int EncryptedLimit = 16 * 1024 * 1024;
    private static ReadOnlySpan<byte> Marker => "Salted__"u8;

    public static byte[] Decrypt(byte[] encrypted, string password)
    {
        if (encrypted.Length is < 24 or > EncryptedLimit ||
            !encrypted.AsSpan(0, 8).SequenceEqual(Marker) || (encrypted.Length - 16) % 8 != 0)
            throw new InvalidDataException("Бэкап не имеет формата OpenSSL Salted__.");
        return Crypt(encrypted.AsSpan(16).ToArray(), password, encrypted.AsSpan(8, 8), false);
    }

    public static byte[] Encrypt(byte[] plain, string password)
    {
        if (plain.Length is < 1 or > EncryptedLimit)
            throw new InvalidDataException("Недопустимый размер бэкапа перед шифрованием.");
        var salt = RandomNumberGenerator.GetBytes(8);
        var encrypted = Crypt(plain, password, salt, true);
        var result = new byte[16 + encrypted.Length];
        Marker.CopyTo(result);
        salt.CopyTo(result.AsSpan(8));
        encrypted.CopyTo(result.AsSpan(16));
        return result;
    }

    private static byte[] Crypt(byte[] input, string password, ReadOnlySpan<byte> salt, bool encrypt)
    {
        if (salt.Length != 8 || input.Length is < 1 or > EncryptedLimit)
            throw new InvalidDataException("Некорректный размер шифрованного архива.");
        var secret = Encoding.UTF8.GetBytes(password);
        var seed = new byte[secret.Length + salt.Length];
        secret.CopyTo(seed, 0);
        salt.CopyTo(seed.AsSpan(secret.Length));
        var material = SHA256.HashData(seed); // OpenSSL EVP_BytesToKey: SHA256(password || salt), one iteration.
        try
        {
            using var algorithm = TripleDES.Create();
            algorithm.Mode = CipherMode.CBC;
            algorithm.Padding = PaddingMode.PKCS7;
            algorithm.Key = material[..24];
            algorithm.IV = material[24..32];
            using var transform = encrypt ? algorithm.CreateEncryptor() : algorithm.CreateDecryptor();
            try { return transform.TransformFinalBlock(input, 0, input.Length); }
            catch (CryptographicException) { throw new InvalidDataException("Ключ или файл бэкапа не соответствует B31."); }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
            CryptographicOperations.ZeroMemory(seed);
            CryptographicOperations.ZeroMemory(material);
        }
    }
}

internal static class BackupGzip
{
    public const int ExpandedLimit = 64 * 1024 * 1024;

    public static byte[] Decompress(byte[] input)
    {
        if (input.Length is < 18 or > BackupCipher.EncryptedLimit ||
            input[0] != 0x1f || input[1] != 0x8b || input[2] != 8 || (input[3] & 0xe0) != 0)
            throw new InvalidDataException("Недопустимый заголовок gzip.");
        try
        {
            // GZipStream accepts bytes after a complete member. Locate the
            // deflate payload ourselves and feed it one byte at a time so the
            // exact compressed-byte count can be checked after stream end.
            var payloadStart = HeaderLength(input);
            using var source = new BytewiseInput(input.AsSpan(payloadStart,
                input.Length - payloadStart - 8).ToArray());
            using var deflate = new DeflateStream(source, CompressionMode.Decompress);
            using var output = new MemoryStream();
            var buffer = new byte[64 * 1024];
            while (true)
            {
                var count = deflate.Read(buffer, 0, buffer.Length);
                if (count == 0) break;
                if (count > ExpandedLimit - output.Length)
                    throw new InvalidDataException("Распакованный бэкап превышает допустимый размер.");
                output.Write(buffer, 0, count);
            }
            if (source.Position != source.Length)
                throw new InvalidDataException("Лишние данные или второй поток после gzip.");
            var result = output.ToArray();
            var expectedCrc = BinaryPrimitives.ReadUInt32LittleEndian(input.AsSpan(input.Length - 8));
            var expectedSize = BinaryPrimitives.ReadUInt32LittleEndian(input.AsSpan(input.Length - 4));
            if (Crc32(result) != expectedCrc || (uint)result.Length != expectedSize)
                throw new InvalidDataException("Повреждён или дополнен gzip-архив.");
            return result;
        }
        catch (InvalidDataException) { throw; }
        catch (IOException) { throw new InvalidDataException("Не удалось распаковать gzip-архив."); }
    }

    private static int HeaderLength(byte[] input)
    {
        var limit = input.Length - 8;
        var offset = 10;
        var flags = input[3];
        if ((flags & 4) != 0)
        {
            if (offset + 2 > limit) throw new InvalidDataException("Обрезанный gzip-заголовок.");
            var length = BinaryPrimitives.ReadUInt16LittleEndian(input.AsSpan(offset, 2));
            offset += 2 + length;
            if (offset > limit) throw new InvalidDataException("Обрезанное расширение gzip.");
        }
        if ((flags & 8) != 0) offset = SkipZeroTerminated(input, offset, limit);
        if ((flags & 16) != 0) offset = SkipZeroTerminated(input, offset, limit);
        if ((flags & 2) != 0)
        {
            if (offset + 2 > limit) throw new InvalidDataException("Обрезанный gzip header CRC.");
            var expected = BinaryPrimitives.ReadUInt16LittleEndian(input.AsSpan(offset, 2));
            if ((ushort)Crc32(input.AsSpan(0, offset)) != expected)
                throw new InvalidDataException("Повреждён gzip header CRC.");
            offset += 2;
        }
        if (offset >= limit) throw new InvalidDataException("Отсутствует gzip-поток.");
        return offset;
    }

    private static int SkipZeroTerminated(byte[] input, int offset, int limit)
    {
        while (offset < limit)
            if (input[offset++] == 0) return offset;
        throw new InvalidDataException("Обрезанное поле gzip-заголовка.");
    }

    private sealed class BytewiseInput(byte[] data) : Stream
    {
        private int _position;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => data.Length;
        public override long Position { get => _position; set => throw new NotSupportedException(); }
        public override int Read(Span<byte> buffer)
        {
            if (buffer.Length == 0) return 0;
            if (_position == data.Length)
                throw new EndOfStreamException("Deflate завершился без конечного блока.");
            buffer[0] = data[_position++];
            return 1;
        }
        public override int Read(byte[] buffer, int offset, int count) =>
            Read(buffer.AsSpan(offset, count));
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    public static byte[] Compress(byte[] input)
    {
        if (input.Length is < 1 or > ExpandedLimit)
            throw new InvalidDataException("Недопустимый размер архива перед сжатием.");
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true))
            gzip.Write(input);
        if (output.Length > BackupCipher.EncryptedLimit)
            throw new InvalidDataException("Сжатый архив превышает допустимый размер.");
        return output.ToArray();
    }

    private static uint Crc32(ReadOnlySpan<byte> input)
    {
        uint value = 0xffffffff;
        foreach (var item in input)
        {
            value ^= item;
            for (var i = 0; i < 8; i++)
                value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1;
        }
        return ~value;
    }
}
