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
