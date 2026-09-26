using System.Buffers.Binary;
using System.Security.Cryptography;

namespace ZteImeiStudio.Windows.Core;

public static class ImeiCodec
{
    public static bool IsValid(string? value)
    {
        if (value is null || value.Length != 15 || value.Any(c => c is < '0' or > '9')) return false;
        var sum = 0;
        for (var i = 0; i < 15; i++)
        {
            var n = value[i] - '0';
            if ((i & 1) == 1) n *= 2;
            sum += n > 9 ? n - 9 : n;
        }
        return sum % 10 == 0;
    }

    public static string Second(string first)
    {
        if (!IsValid(first)) throw new InvalidDataException("Первый IMEI недействителен.");
        var serial = int.Parse(first.Substring(8, 6));
        if (serial == 999999) throw new InvalidDataException("Серийный номер достиг 999999; введите второй IMEI вручную.");
        var stem = first[..8] + (serial + 1).ToString("D6");
        return Enumerable.Range(0, 10).Select(n => stem + n).First(IsValid)!;
    }

    public static string DecodeNv550(ReadOnlySpan<byte> record)
    {
        if (record.Length != 128 || record[0] != 8 || (record[1] & 15) != 10)
            throw new InvalidDataException("Неизвестный формат NV550.");
        Span<char> digits = stackalloc char[15];
        digits[0] = Digit(record[1] >> 4);
        for (var i = 2; i <= 8; i++)
        {
            digits[1 + (i - 2) * 2] = Digit(record[i] & 15);
            digits[2 + (i - 2) * 2] = Digit(record[i] >> 4);
        }
        var value = new string(digits);
        if (!IsValid(value)) throw new InvalidDataException("IMEI в NV550 не проходит контрольную сумму.");
        return value;
    }

    private static char Digit(int value) => value is >= 0 and <= 9 ? (char)('0' + value) : throw new InvalidDataException("Некорректный BCD в NV550.");

    public static byte[] EncodeNv550(string imei, ReadOnlySpan<byte> original)
    {
        _ = DecodeNv550(original);
        if (!IsValid(imei)) throw new InvalidDataException("Неверный IMEI.");
        var result = original.ToArray();
        result[0] = 8;
        result[1] = (byte)(((imei[0] - '0') << 4) | 10);
        for (var i = 0; i < 7; i++)
            result[i + 2] = (byte)((imei[1 + 2 * i] - '0') | ((imei[2 + 2 * i] - '0') << 4));
        return result;
    }
}

public static class ConfigCodec
{
    public const int Length = 15073;
    public static uint Crc(ReadOnlySpan<byte> bytes)
    {
        uint value = 0;
        for (var i = 0; i < bytes.Length; i++)
        {
            value ^= (uint)(i is >= 12 and < 16 ? 0 : bytes[i]) << 24;
            for (var j = 0; j < 8; j++) value = (value & 0x80000000) != 0 ? (value << 1) ^ 0x04c11db7 : value << 1;
        }
        return value;
    }
    public static byte Validate(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != Length || BinaryPrimitives.ReadUInt32LittleEndian(bytes) != 0x78563412 ||
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[4..]) != 249 ||
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[8..]) != Length ||
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[12..]) != Crc(bytes) ||
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[^4..]) != 0x21436587)
            throw new InvalidDataException("Заголовок или CRC config не совпадает с проверенной B31.");
        var ids = new HashSet<uint>(); var offset = 16; byte? flag = null;
        for (var index = 0; index < 249; index++)
        {
            if (offset + 16 > bytes.Length - 4) throw new InvalidDataException("Обрезанный config.");
            var id = BinaryPrimitives.ReadUInt32LittleEndian(bytes[offset..]);
            var length = BinaryPrimitives.ReadUInt32LittleEndian(bytes[(offset + 4)..]);
            if (length < 16 || length > bytes.Length - 4 - offset ||
                BinaryPrimitives.ReadUInt32LittleEndian(bytes[(offset + 8)..]) != 0x18080820 ||
                id > 65535 || !ids.Add(id)) throw new InvalidDataException("Неизвестная запись config.");
            if (id == 102)
            {
                if (index != 5 || offset != 483 || length != 17 ||
                    BinaryPrimitives.ReadUInt32LittleEndian(bytes[(offset + 12)..]) != 0 || bytes[offset + 16] > 1)
                    throw new InvalidDataException("Неизвестная структура флага config102.");
                flag = bytes[offset + 16];
            }
            offset += (int)length;
        }
        if (offset != bytes.Length - 4 || flag is null) throw new InvalidDataException("Не найден однозначный config102.");
        return flag.Value;
    }
    public static byte[] Candidate(ReadOnlySpan<byte> original)
    {
        if (Validate(original) != 0) throw new InvalidDataException("Config уже содержит активный флаг записи.");
        var result = original.ToArray(); result[499] = 1;
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(12), Crc(result));
        _ = Validate(result); return result;
    }
}

public static class VerifiedHash
{
    public static string Sha256(ReadOnlySpan<byte> data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    public static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";
}
