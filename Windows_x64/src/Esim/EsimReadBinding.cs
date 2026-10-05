using System.Text;
using System.Text.RegularExpressions;
namespace ZteImeiStudio.Windows.Esim;

/// <summary>Read-only observation. SSH host-key validation provides the target binding;
/// a readable boot ID additionally detects restarts. Missing CID is not a read refusal.</summary>
public static class EsimReadBinding
{
    public const string Command = "if [ -r /proc/sys/kernel/random/boot_id ]; then cat /proc/sys/kernel/random/boot_id; else printf 'unavailable\\n'; fi";
    public static string Parse(int exitCode, byte[] output)
    {
        if (exitCode != 0 || output.Length > 64) throw new EsimException("identity_changed");
        var text = new UTF8Encoding(false, true).GetString(output);
        if (text.EndsWith('\n')) text = text[..^1];
        if (text != "unavailable" && !Regex.IsMatch(text, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) throw new EsimException("identity_changed");
        return text;
    }
}
