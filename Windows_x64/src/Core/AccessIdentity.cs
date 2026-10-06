using System.Text;
using System.Text.RegularExpressions;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Core;

/// <summary>Access identity measures the current device; it grants no NV or component capability.</summary>
internal static class AccessIdentity
{
    internal const string Command = """
        set -eu
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        test "$(id -u)" = 0
        test "$(uname -s)" = Linux
        test "$(uname -m)" = aarch64
        observed_hash() {
          path=$1; parent=${path%/*}
          test ! -L "$path" || return 71
          while :; do
            test ! -L "$parent" || return 71
            if test -e "$parent"; then
              test -d "$parent" && test -r "$parent" && test -x "$parent" || return 71
            fi
            test "$parent" != / || break
            parent=${parent%/*}; test -n "$parent" || parent=/
          done
          if test -e "$path"; then
            test -f "$path" && test -r "$path" || return 71
            sha256sum "$path" || return 71
          else
            printf 'absent  %s\n' "$path"
          fi
        }
        observed_hash /firmware/image/modem.b16 || exit 71
        observed_hash /usr/bin/diag-router || exit 71
        cat /sys/block/mmcblk0/device/cid /proc/sys/kernel/random/boot_id
        """;

    internal static DeviceIdentity Parse(byte[] bytes)
    {
        if(bytes.Length>4096)throw new InvalidDataException("Неполная или слишком большая идентификация доступа.");
        var lines=AdbShellOutput.NormalizeText(new UTF8Encoding(false,true).GetString(bytes)).TrimEnd('\n').Split('\n');
        if(lines.Length!=4)throw new InvalidDataException("Не удалось измерить идентичность доступа.");
        var firmware=HashLine(lines[0],"/firmware/image/modem.b16");
        var router=HashLine(lines[1],"/usr/bin/diag-router");
        if(!Regex.IsMatch(lines[2],"^[0-9a-f]{32}$") || !Guid.TryParseExact(lines[3],"D",out var boot) || lines[3]!=boot.ToString("D"))throw new InvalidDataException("Для установки доступа нужны точные CID и boot ID.");
        return new DeviceIdentity(lines[2],firmware,lines[3],router);
    }
    internal static string HashLine(string line,string path)
    {
        var fields=line.Split(' ',StringSplitOptions.RemoveEmptyEntries);
        if(fields.Length!=2 || fields[1]!=path || fields[0]!="absent" && !Regex.IsMatch(fields[0],"^[0-9a-f]{64}$"))throw new InvalidDataException("Не подтверждено измерение компонента доступа.");
        return fields[0];
    }
    internal static async Task<DeviceIdentity> ReadAsync(IRemoteShell shell,CancellationToken ct)
    {
        var result=await shell.RunAsync(Command,timeout:TimeSpan.FromSeconds(20),ct:ct);
        if(!result.Success)throw new InvalidDataException("Доступ требует root Linux ARM64 и читаемой идентичности устройства.");
        return Parse(result.Stdout);
    }
}


/// Observations for an authenticated SSH session, never write authorization.
internal sealed record SshReadProof(string? Uid,string? System,string? Architecture,string? Cid,string? BootId,string? FirmwareHash,string? RouterHash)
{
    // A connection proves access and continuity, not component compatibility.
    // Large firmware hashes belong to the operation that needs them.
    internal const string SessionCommand = """
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    zte_read_fact() { value=$("$@" 2>/dev/null) || value=; case "$value" in ''|*[!A-Za-z0-9_.-]*) printf '?\n';; *) test "${#value}" -le 128 && printf '%s\n' "$value" || printf '?\n';; esac; }
    printf 'ZTE_SSH_READ_V1\n'
    zte_read_fact id -u
    zte_read_fact uname -s
    zte_read_fact uname -m
    zte_read_fact cat /sys/block/mmcblk0/device/cid
    zte_read_fact cat /proc/sys/kernel/random/boot_id
    printf '?\n?\n'
    """;
    internal static async Task<SshReadProof> ReadSessionAsync(IRemoteShell shell,CancellationToken ct)
    {
        var result=await shell.RunAsync(SessionCommand,timeout:TimeSpan.FromSeconds(10),ct:ct);
        if(!result.Success)throw new InvalidDataException("Не удалось проверить сеанс SSH.");
        return Parse(result.Stdout);
    }
    internal const string Command = """
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    zte_read_fact() { value=$("$@" 2>/dev/null) || value=; case "$value" in ''|*[!A-Za-z0-9_.-]*) printf '?\n';; *) test "${#value}" -le 128 && printf '%s\n' "$value" || printf '?\n';; esac; }
    zte_read_hash() {
      p=$1
      if test -L "$p"; then printf '?\n'
      elif test -f "$p" && test -r "$p"; then
        h=$(sha256sum "$p" 2>/dev/null) || h=
        h=${h%% *}; case "$h" in ''|*[!0-9a-f]*) printf '?\n';; *) test "${#h}" = 64 && printf '%s\n' "$h" || printf '?\n';; esac
      elif test ! -e "$p" && test -r "${p%/*}" && test -x "${p%/*}"; then printf 'absent\n'
      else printf '?\n'; fi
    }
    printf 'ZTE_SSH_READ_V1\n'
    zte_read_fact id -u
    zte_read_fact uname -s
    zte_read_fact uname -m
    zte_read_fact cat /sys/block/mmcblk0/device/cid
    zte_read_fact cat /proc/sys/kernel/random/boot_id
    zte_read_hash /firmware/image/modem.b16
    zte_read_hash /usr/bin/diag-router
    """;
    internal static SshReadProof Parse(byte[] bytes)
    {
        if(bytes.Length>4096||bytes.Contains((byte)0))throw new InvalidDataException("Неверный ответ проверки SSH.");
        var fields=AdbShellOutput.NormalizeText(new UTF8Encoding(false,true).GetString(bytes)).TrimEnd('\n').Split('\n');
        if(fields.Length!=8||fields[0]!="ZTE_SSH_READ_V1")throw new InvalidDataException("Неполный ответ проверки SSH.");
        var values=fields.Skip(1).Select(x=>x=="?"?null:x).ToArray();
        string[] patterns=["^[0-9]{1,10}$","^[A-Za-z0-9_.-]{1,128}$","^[A-Za-z0-9_.-]{1,128}$","^[0-9a-f]{32}$","^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$","^(?:absent|[0-9a-f]{64})$","^(?:absent|[0-9a-f]{64})$"];
        for(var i=0;i<values.Length;i++)if(values[i] is string value&&!Regex.IsMatch(value,patterns[i]))throw new InvalidDataException("Некорректные сведения SSH.");
        return new(values[0],values[1],values[2],values[3],values[4],values[5],values[6]);
    }
    internal void Verify(SshReadProof current)
    {
        string?[] before=[Uid,System,Architecture,Cid,BootId,FirmwareHash,RouterHash];
        string?[] after=[current.Uid,current.System,current.Architecture,current.Cid,current.BootId,current.FirmwareHash,current.RouterHash];
        for(var i=0;i<before.Length;i++)if(before[i] is not null&&before[i]!=after[i])throw new InvalidDataException("Устройство или сеанс SSH изменились; дальнейшее чтение остановлено.");
    }
    internal static async Task<SshReadProof> ReadAsync(IRemoteShell shell,CancellationToken ct)
    {
        var result=await shell.RunAsync(Command,timeout:TimeSpan.FromSeconds(15),ct:ct);
        if(!result.Success)throw new InvalidDataException("Не удалось проверить сеанс SSH.");
        return Parse(result.Stdout);
    }
}
