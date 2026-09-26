using System.Text;

namespace ZteImeiStudio.Windows.Core;

public sealed record BackupTarMember(string Path, byte Kind, byte[] Header,
    byte[] Bytes, byte[] Padding, byte[] ExtensionRecords, string Link)
{
    public bool IsFile => Kind is 0 or (byte)'0';
}

/// <summary>
/// Bounded ustar reader/repacker. Unchanged members retain byte-for-byte
/// headers, payloads, padding and local PAX records. It rejects sparse files,
/// devices, global PAX records, hardlinks and paths through symlinks.
/// </summary>
public sealed class BackupTar
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly HashSet<string> AllowedPax =
        ["path", "linkpath", "uid", "gid", "uname", "gname", "mtime", "atime", "ctime", "charset", "comment"];
    private readonly byte[] _footer;
    public IReadOnlyList<BackupTarMember> Members { get; }

    public BackupTar(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        if (data.Length is < 1024 or > BackupGzip.ExpandedLimit || data.Length % 512 != 0)
            throw new InvalidDataException("Некорректный размер tar.");
        var members = new List<BackupTarMember>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        var offset = 0;
        var pending = Array.Empty<byte>();
        var pax = new Dictionary<string, string>(StringComparer.Ordinal);
        byte[]? footer = null;
        while (offset + 512 <= data.Length)
        {
            var header = data.AsSpan(offset, 512).ToArray();
            if (header.All(b => b == 0))
            {
                footer = data[offset..];
                if (footer.Length < 1024 || footer.Any(b => b != 0) || pending.Length != 0)
                    throw new InvalidDataException("Неоднозначный конец tar.");
                break;
            }
            if (members.Count >= 4096) throw new InvalidDataException("Слишком много записей tar.");
            var stored = ReadOctal(header, 148, 8);
            var actual = 0;
            for (var index = 0; index < 512; index++)
                actual += index is >= 148 and < 156 ? 32 : header[index];
            if (stored != actual) throw new InvalidDataException("Контрольная сумма заголовка tar не совпала.");
            var magic = header.AsSpan(257, 6);
            if (!magic.SequenceEqual(new byte[] { 117, 115, 116, 97, 114, 0 }) &&
                !magic.SequenceEqual(new byte[] { 117, 115, 116, 97, 114, 32 }))
                throw new InvalidDataException("Неизвестный формат tar; требуется ustar.");
            var size = ReadOctal(header, 124, 12);
            if (size > BackupCipher.EncryptedLimit) throw new InvalidDataException("Запись tar слишком велика.");
            var padded = ((size + 511) / 512) * 512;
            if (padded > data.Length - offset - 512)
                throw new InvalidDataException("Обрезанная запись tar.");
            var bytes = data.AsSpan(offset + 512, size).ToArray();
            var padding = data.AsSpan(offset + 512 + size, padded - size).ToArray();
            if (padding.Any(b => b != 0)) throw new InvalidDataException("Ненулевое заполнение tar.");
            var kind = header[156];
            var prefix = ReadField(header, 345, 155);
            var name = ReadField(header, 0, 100);
            var rawPath = SafePath(prefix.Length == 0 ? name : prefix + "/" + name, kind == (byte)'5');
            if (kind == (byte)'x')
            {
                if (pending.Length != 0 || bytes.Length > 65536)
                    throw new InvalidDataException("Повторный или слишком большой PAX-заголовок.");
                pax = ReadPax(bytes);
                pending = data.AsSpan(offset, 512 + padded).ToArray();
                offset += 512 + padded;
                continue;
            }
            if (kind is not (0 or (byte)'0' or (byte)'2' or (byte)'5'))
                throw new InvalidDataException("Неподдерживаемый тип записи tar.");
            var path = SafePath(pax.GetValueOrDefault("path") ?? rawPath, kind == (byte)'5');
            if (!names.Add(path)) throw new InvalidDataException("Повторный путь в tar.");
            if (kind is not (0 or (byte)'0') && size != 0)
                throw new InvalidDataException("У ссылки или каталога tar не должно быть данных.");
            var rawLink = ReadField(header, 157, 100);
            var link = pax.GetValueOrDefault("linkpath") ?? rawLink;
            if (kind == (byte)'2')
            {
                ValidateLink(rawLink, path);
                ValidateLink(link, path);
            }
            else if (rawLink.Length != 0 || link.Length != 0)
                throw new InvalidDataException("Неожиданная ссылка у обычной записи tar.");
            members.Add(new BackupTarMember(path, kind, header, bytes, padding, pending, link));
            pending = [];
            pax = new Dictionary<string, string>(StringComparer.Ordinal);
            offset += 512 + padded;
        }
        _footer = footer ?? throw new InvalidDataException("В tar отсутствует завершение.");
        var kinds = members.ToDictionary(m => m.Path, m => m.Kind, StringComparer.Ordinal);
        foreach (var member in members)
        {
            var parts = member.Path.Split('/');
            for (var length = 1; length < parts.Length; length++)
            {
                var ancestor = string.Join('/', parts.Take(length));
                if (kinds.TryGetValue(ancestor, out var ancestorKind) && ancestorKind != (byte)'5')
                    throw new InvalidDataException("Путь tar проходит через файл или ссылку.");
            }
        }
        Members = members;
    }

    public byte[] Replace(IReadOnlyDictionary<string, byte[]> changes)
    {
        var files = Members.Where(m => m.IsFile).Select(m => m.Path).ToHashSet(StringComparer.Ordinal);
        if (!changes.Keys.All(files.Contains))
            throw new InvalidDataException("Не найден однозначный файл для изменения tar.");
        using var output = new MemoryStream();
        foreach (var member in Members)
        {
            output.Write(member.ExtensionRecords);
            if (changes.TryGetValue(member.Path, out var replacement))
            {
                if (replacement.Length > BackupCipher.EncryptedLimit)
                    throw new InvalidDataException("Слишком большая замена tar.");
                var header = member.Header.ToArray();
                WriteOctal(header, 124, 12, replacement.Length);
                Array.Fill(header, (byte)' ', 148, 8);
                var checksum = header.Sum(b => (int)b);
                var checksumBytes = Encoding.ASCII.GetBytes(Convert.ToString(checksum, 8)!.PadLeft(6, '0') + "\0 ");
                if (checksumBytes.Length != 8) throw new InvalidDataException("Неверная длина checksum tar.");
                checksumBytes.CopyTo(header.AsSpan(148));
                output.Write(header);
                output.Write(replacement);
                output.Write(new byte[(512 - replacement.Length % 512) % 512]);
            }
            else
            {
                output.Write(member.Header);
                output.Write(member.Bytes);
                output.Write(member.Padding);
            }
            if (output.Length > BackupGzip.ExpandedLimit - _footer.Length)
                throw new InvalidDataException("Собранный tar превышает допустимый размер.");
        }
        output.Write(_footer);
        return output.ToArray();
    }

    public void Verify(BackupTar other, IReadOnlyDictionary<string, byte[]> changes)
    {
        if (Members.Count != other.Members.Count || !_footer.AsSpan().SequenceEqual(other._footer))
            throw new InvalidDataException("Изменена структура tar.");
        for (var index = 0; index < Members.Count; index++)
        {
            var old = Members[index];
            var current = other.Members[index];
            if (old.Path != current.Path || old.Kind != current.Kind || old.Link != current.Link ||
                !old.ExtensionRecords.AsSpan().SequenceEqual(current.ExtensionRecords))
                throw new InvalidDataException("Изменены метаданные записи tar.");
            if (changes.TryGetValue(old.Path, out var replacement))
            {
                var before = old.Header.ToArray();
                var after = current.Header.ToArray();
                Array.Clear(before, 124, 12); Array.Clear(after, 124, 12);
                Array.Clear(before, 148, 8); Array.Clear(after, 148, 8);
                if (!before.AsSpan().SequenceEqual(after) ||
                    !current.Bytes.AsSpan().SequenceEqual(replacement))
                    throw new InvalidDataException("Неожиданное изменение данных или метаданных tar.");
            }
            else if (!old.Header.AsSpan().SequenceEqual(current.Header) ||
                !old.Bytes.AsSpan().SequenceEqual(current.Bytes) ||
                !old.Padding.AsSpan().SequenceEqual(current.Padding))
                throw new InvalidDataException("Изменён посторонний файл резервной копии.");
        }
    }

    private static string ReadField(byte[] source, int offset, int length)
    {
        var field = source.AsSpan(offset, length);
        var end = field.IndexOf((byte)0);
        if (end < 0) end = field.Length;
        else if (field[end..].IndexOfAnyExcept((byte)0) >= 0)
            throw new InvalidDataException("Данные после NUL в поле tar.");
        try { return StrictUtf8.GetString(field[..end]); }
        catch (DecoderFallbackException) { throw new InvalidDataException("Неизвестная кодировка пути tar."); }
    }

    private static int ReadOctal(byte[] source, int offset, int length)
    {
        var field = source.AsSpan(offset, length);
        foreach (var item in field)
            if (item is not (0 or 32 or >= (byte)'0' and <= (byte)'7'))
                throw new InvalidDataException("Неизвестное числовое поле tar.");
        var text = Encoding.ASCII.GetString(field).Trim('\0', ' ');
        try { return text.Length == 0 ? 0 : Convert.ToInt32(text, 8); }
        catch (Exception error) when (error is FormatException or OverflowException)
        { throw new InvalidDataException("Переполнение числового поля tar.", error); }
    }

    private static void WriteOctal(byte[] header, int offset, int length, int value)
    {
        var digits = Convert.ToString(value, 8)!;
        if (digits.Length >= length) throw new InvalidDataException("Размер файла не помещается в tar.");
        Encoding.ASCII.GetBytes(digits.PadLeft(length - 1, '0') + "\0").CopyTo(header.AsSpan(offset));
    }

    private static string SafePath(string path, bool directory)
    {
        if (path.Length == 0 || Encoding.UTF8.GetByteCount(path) > 4096 ||
            path.StartsWith('/') || path.Contains('\\') || path.Any(c => c < 32 || c == 127))
            throw new InvalidDataException("Небезопасный путь в tar.");
        if (path.StartsWith("./", StringComparison.Ordinal)) path = path[2..];
        if (directory && path.EndsWith('/')) path = path[..^1];
        var parts = path.Split('/');
        if (parts.Length == 0 || parts.Any(p => p.Length == 0 || p is "." or ".."))
            throw new InvalidDataException("Переход за пределы пути tar.");
        return string.Join('/', parts);
    }

    private static void ValidateLink(string target, string path)
    {
        if (target.Length == 0 || Encoding.UTF8.GetByteCount(target) > 4096 ||
            target.StartsWith('/') || target.Contains('\\') || target.Any(c => c < 32 || c == 127))
            throw new InvalidDataException("Небезопасная символическая ссылка tar.");
        var stack = path.Split('/')[..^1].ToList();
        foreach (var part in target.Split('/'))
        {
            if (part.Length == 0) throw new InvalidDataException("Некорректная ссылка tar.");
            if (part == "..")
            {
                if (stack.Count == 0) throw new InvalidDataException("Ссылка tar выходит за корень.");
                stack.RemoveAt(stack.Count - 1);
            }
            else if (part != ".") stack.Add(part);
        }
        if (stack.Count == 0) throw new InvalidDataException("Ссылка tar указывает на корень.");
    }

    private static Dictionary<string, string> ReadPax(byte[] payload)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var offset = 0;
        while (offset < payload.Length)
        {
            var space = Array.IndexOf(payload, (byte)' ', offset);
            if (space < 0 || space - offset > 6 || space == offset)
                throw new InvalidDataException("Некорректная длина PAX.");
            for (var index = offset; index < space; index++)
                if (payload[index] is < (byte)'0' or > (byte)'9')
                    throw new InvalidDataException("Некорректная длина PAX.");
            if (!int.TryParse(Encoding.ASCII.GetString(payload, offset, space - offset), out var size) ||
                size <= space - offset + 3 || size > payload.Length - offset ||
                payload[offset + size - 1] != (byte)'\n')
                throw new InvalidDataException("Обрезанный PAX.");
            var body = payload.AsSpan(space + 1, offset + size - 1 - (space + 1));
            var equals = body.IndexOf((byte)'=');
            if (equals < 1) throw new InvalidDataException("Некорректный PAX.");
            string key, value;
            try
            {
                key = StrictUtf8.GetString(body[..equals]);
                value = StrictUtf8.GetString(body[(equals + 1)..]);
            }
            catch (DecoderFallbackException) { throw new InvalidDataException("Некорректная кодировка PAX."); }
            if (!AllowedPax.Contains(key) || result.ContainsKey(key) || value.Contains('\0') || value.Contains('\n'))
                throw new InvalidDataException("Неподдерживаемый или повторный атрибут PAX.");
            result[key] = value;
            offset += size;
        }
        return result;
    }
}
