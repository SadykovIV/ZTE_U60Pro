using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Transport;

/// <summary>ADB shell framing and opt-in text handling. Binary stdout is never normalized.</summary>
public static class AdbShellOutput
{
    private static readonly Regex MarkerPattern = new(
        @"\A__(?:ZTE|FR)_RESULT_[A-Fa-f0-9]{32}__\z", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static bool TryDecodeCompletion(ReadOnlySpan<byte> raw, string marker, out int code, out int outputLength)
    {
        code = 0; outputLength = 0;
        if (!MarkerPattern.IsMatch(marker)) return false;
        var needle = Encoding.ASCII.GetBytes(marker);
        var offset = raw.IndexOf(needle);
        if (offset < 1 || raw[offset - 1] != (byte)'\n' || raw[(offset + needle.Length)..].IndexOf(needle) >= 0 || raw[^1] != (byte)'\n')
            return false;
        var digitsEnd = raw.Length - 1;
        while (digitsEnd > 0 && raw[digitsEnd - 1] == (byte)'\r') digitsEnd--;
        var endingLength = raw.Length - digitsEnd;
        if (endingLength > 3) return false; // LF, CRLF or the observed CRCRLF only.
        var digits = raw[(offset + needle.Length)..digitsEnd];
        if (digits.Length is < 1 or > 3 || digits.Length > 1 && digits[0] == (byte)'0') return false;
        foreach (var digit in digits)
        {
            if (digit is < (byte)'0' or > (byte)'9') return false;
            code = code * 10 + digit - (byte)'0';
        }
        if (code > 255 || offset < endingLength || !raw.Slice(offset - endingLength, endingLength).SequenceEqual(raw[digitsEnd..])) return false;
        // Infer exactly one separator from the footer. A preceding payload CR
        // is data, not part of the separator, and must survive unchanged.
        outputLength = offset - endingLength;
        return true;
    }

    public static string NormalizeText(string text)
    {
        if (!text.Contains('\r')) return text;
        var output = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length;)
        {
            if (text[i] != '\r') { output.Append(text[i++]); continue; }
            var start = i;
            while (i < text.Length && text[i] == '\r') i++;
            if (i < text.Length && text[i] == '\n' && i - start <= 2)
            { output.Append('\n'); i++; }
            else output.Append(text, start, i - start);
        }
        return output.ToString();
    }
}
