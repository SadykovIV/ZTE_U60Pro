using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Core;

// Access-only reuse does not add this build to any updater or feature allowlist.
internal static class AccessAgentReusePolicy
{
    internal const string PreviousB31Sha256 = "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19";
    internal const string PreviousPublicB31Sha256 = "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67";
    internal static bool IsPrevious(string hash) => hash is PreviousB31Sha256 or PreviousPublicB31Sha256;
    internal sealed record ProcessProof(string Sha256, string Pid, string StartTime);
    internal static bool AllowsPrevious(DeviceIdentity identity, string profile, bool freshExistingReuse) =>
        freshExistingReuse && profile == "b31" && identity.FirmwareHash == ImeiEngine.FirmwareHash && identity.RouterHash == ImeiEngine.RouterHash;

    internal static string Command(bool allowPrevious) => """
        set -eu
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        test ! -L /data/zte-agent && test -f /data/zte-agent && test -r /data/zte-agent || exit 71
        disk=$(sha256sum /data/zte-agent); disk=${disk%% *}
        case "$disk" in ALLOWED_HASHES) ;; *) exit 71;; esac
        found=0; agent_pid=; agent_start=
        for p in $(pidof zte-agent); do
          case "$p" in ''|*[!0-9]*) exit 71;; esac
          if test "$(readlink /proc/$p/exe)" = /data/zte-agent; then
            mapped=$(sha256sum /proc/$p/exe); mapped=${mapped%% *}
            test "$mapped" = "$disk" || exit 71
            started=$(awk '{print $22}' /proc/$p/stat)
            case "$started" in ''|*[!0-9]*) exit 71;; esac
            found=$((found+1)); agent_pid=$p; agent_start=$started
          fi
        done
        test "$found" = 1 || exit 71
        printf 'AGENT_ACCESS_PROOF %s %s %s\n' "$disk" "$agent_pid" "$agent_start"
        """.Replace("ALLOWED_HASHES",AgentPackage.Sha256+(allowPrevious?"|"+PreviousB31Sha256+"|"+PreviousPublicB31Sha256:""),StringComparison.Ordinal);

    internal static async Task<ProcessProof> ReadAsync(IRemoteShell ssh, bool allowPrevious, CancellationToken ct)
    {
        var result=await ssh.RunAsync(Command(allowPrevious),timeout:TimeSpan.FromSeconds(20),ct:ct).ConfigureAwait(false);
        if(!result.Success || result.Stdout.Length>256)throw new InvalidDataException("Сборка или работающий процесс агента не подтверждены; установка автоматически не запускается.");
        var text=new UTF8Encoding(false,true).GetString(result.Stdout);
        var match=Regex.Match(text,@"\AAGENT_ACCESS_PROOF ([0-9a-f]{64}) ([1-9][0-9]{0,9}) ([0-9]{1,20})\n\z",RegexOptions.CultureInvariant);
        if(!match.Success || match.Groups[1].Value!=AgentPackage.Sha256 && (!allowPrevious || !IsPrevious(match.Groups[1].Value)))
            throw new InvalidDataException("Неоднозначное подтверждение работающего агента.");
        return new(match.Groups[1].Value,match.Groups[2].Value,match.Groups[3].Value);
    }
}
