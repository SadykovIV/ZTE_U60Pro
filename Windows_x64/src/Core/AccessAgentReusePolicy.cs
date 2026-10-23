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

    // Fixed, read-only proof for recovery of a committed agent that stopped.
    // A failed transport or an unreadable live process never proves absence.
    internal static string AbsenceCommand(string expectedHash)
    {
        if (expectedHash.Length != 64 || !Regex.IsMatch(expectedHash,"^[0-9a-f]{64}$")) throw new InvalidDataException("Повреждён журнал замены.");
        return """
        set -eu
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        expected=EXPECTED_AGENT_SHA
        absent_fail() { exit 73; }
        absent_file() {
          test -d /data && test ! -L /data && test -r /data && test -x /data && test "$(stat -c %u /data)" = 0 || absent_fail
          if test ! -e /data/zte-agent && test ! -L /data/zte-agent; then
            file_state=missing
            return
          fi
          test -f /data/zte-agent && test ! -L /data/zte-agent && test -r /data/zte-agent || absent_fail
          test "$(stat -c %u:%h /data/zte-agent)" = 0:1 || absent_fail
          disk=$(sha256sum /data/zte-agent) || absent_fail
          test "${disk%% *}" = "$expected" || absent_fail
          file_state=$(stat -c %d:%i:%u:%a:%h /data/zte-agent) || absent_fail
        }
        absent_scan() {
          names=; pidof_status=0
          names=$(pidof zte-agent 2>/dev/null) || pidof_status=$?
          test "$pidof_status" = 1 && test -z "$names" || absent_fail
          count=0
          for process in /proc/[0-9]*; do
            test -d "$process" || continue
            test ! -L "$process" || absent_fail
            count=$((count + 1)); test "$count" -le 4096 || absent_fail
            pid=${process##*/}
            if test -r "$process/cmdline"; then
              args=$(tr '\000' '\n' < "$process/cmdline" 2>/dev/null) || {
                test ! -d "$process" && continue
                absent_fail
              }
            else
              test ! -d "$process" && continue
              absent_fail
            fi
            first=${args%%'
        '*}
            case "$first" in zte-agent|*/zte-agent) absent_fail;; esac
            if mapped=$(readlink "$process/exe" 2>/dev/null); then
              case "$mapped" in */zte-agent|*/zte-agent' (deleted)') absent_fail;; esac
            else
              test ! -d "$process" && continue
              test -z "$args" || absent_fail
              # Only a kernel thread or a zombie may have no executable. An ordinary
              # process with cleared argv and unreadable exe is not absence evidence.
              state=$(cat "$process/stat" 2>/dev/null) || {
                test ! -d "$process" && continue
                absent_fail
              }
              case "$state" in "$pid ("*') '*) ;; *) absent_fail;; esac
              rest=${state##*) }; set -- $rest
              test "$#" -ge 20 || absent_fail
              process_state=$1; shift 6; flags=$1
              case "$flags" in ''|*[!0-9]*) absent_fail;; esac
              test "$process_state" = Z || test "$((flags & 2097152))" != 0 || absent_fail
            fi
          done
          test "$count" -gt 0 || absent_fail
        }
        absent_file
        initial_file_state=$file_state
        absent_scan
        absent_scan
        absent_file
        test "$file_state" = "$initial_file_state" || absent_fail
        printf 'AGENT_ACCESS_ABSENT %s\n' "$expected"
        """.Replace("EXPECTED_AGENT_SHA",expectedHash,StringComparison.Ordinal);
    }

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

    // Used only to reconcile a hash already bound to a private replacement journal.
    internal static async Task<ProcessProof> ReadExpectedAsync(IRemoteShell ssh, string expectedHash, CancellationToken ct)
    {
        if (!Regex.IsMatch(expectedHash,"^[0-9a-f]{64}$")) throw new InvalidDataException("Повреждён журнал замены.");
        var command=Command(false).Replace(AgentPackage.Sha256,expectedHash,StringComparison.Ordinal);
        var result=await ssh.RunAsync(command,timeout:TimeSpan.FromSeconds(20),ct:ct).ConfigureAwait(false);
        if(!result.Success || result.Stdout.Length>256)throw new InvalidDataException("Не подтверждён процесс записанной установки агента.");
        var match=Regex.Match(new UTF8Encoding(false,true).GetString(result.Stdout),@"\AAGENT_ACCESS_PROOF ([0-9a-f]{64}) ([1-9][0-9]{0,9}) ([0-9]{1,20})\n\z",RegexOptions.CultureInvariant);
        if(!match.Success || match.Groups[1].Value!=expectedHash)throw new InvalidDataException("Неоднозначное подтверждение работающего агента.");
        return new(match.Groups[1].Value,match.Groups[2].Value,match.Groups[3].Value);
    }

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
