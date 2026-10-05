using System.Text;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Transport;

namespace ZteImeiStudio.Windows.Features;

public sealed record AdbControlStatus(bool? Enabled, bool SupportsChange = false, bool ReadyForChange = false)
{
    public string Detail => SupportsChange ? (Enabled == true ? "USB ADB включён. Переключение доступно через SSH." : "USB ADB выключен. Переключение доступно через SSH.") : Enabled switch
    {
        true => "USB ADB включён. Безопасное переключение без изменения USB-сети не подтверждено для этой прошивки.",
        false => "USB ADB выключен. Безопасное переключение без изменения USB-сети не подтверждено для этой прошивки.",
        null => "Состояние USB ADB не определено. Управление для этой конфигурации не подтверждено.",
    };
}
internal static class AdbControlProtocol
{
    internal const string Command = """
        set -eu
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        test "$(id -u)" = 0 || exit 71
        test "$(uname -s)" = Linux || exit 71
        base=/sys/kernel/config/usb_gadget/g1
        linked=unknown; ready=unknown; bound=unknown; daemon=unknown
        if test -d "$base/configs/c.1" && test -r "$base/configs/c.1" && test -x "$base/configs/c.1" && test ! -L "$base" && test ! -L "$base/configs" && test ! -L "$base/configs/c.1"; then
          configs=0
          for config in "$base"/configs/*; do
            test ! -e "$config" && test ! -L "$config" && continue
            configs=$((configs + 1))
          done
          if test "$configs" = 1; then
            linked=0; count=0
            for link in "$base"/configs/c.1/*; do
              test -L "$link" || continue
              count=$((count + 1)); test "$count" -le 32 || exit 71
              target=$(readlink -f "$link") || exit 71
              test "$target" != "$base/functions/ffs.adb" || linked=1
            done
          fi
        fi
        if test -r "$base/functions/ffs.adb/ready"; then
          value=$(cat "$base/functions/ffs.adb/ready") || exit 71
          case "$value" in 0|1) ready=$value;; *) exit 71;; esac
        fi
        if test -r "$base/UDC"; then
          value=$(cat "$base/UDC") || exit 71
          case "$value" in '') bound=0;; *[!a-zA-Z0-9._-]*) exit 71;; *) test "${#value}" -le 64 || exit 71; bound=1;; esac
        fi
        if command -v pidof >/dev/null 2>&1; then
          result=0; pids=$(pidof adbd 2>/dev/null) || result=$?
          if test "$result" = 1 && test -z "$pids"; then daemon=0
          elif test "$result" = 0; then
            case "$pids" in ''|*[!0-9]*) :;; *)
              executable=$(readlink "/proc/$pids/exe") || exit 71
              owner=$(stat -c %u "/proc/$pids") || exit 71
              if test "$executable" = /sbin/adbd && test "$owner" = 0; then
                daemon=1
                # Older kernels omit the configfs ready attribute. Open descriptor
                # endpoints belong to the same verified root daemon, not host adb.
                if test "$ready" = unknown && test -r "/proc/$pids/fd" && test -x "/proc/$pids/fd"; then
                  ep0=0; ep1=0; ep2=0; fdcount=0
                  for fd in "/proc/$pids"/fd/*; do
                    test -L "$fd" || continue
                    fdcount=$((fdcount + 1)); test "$fdcount" -le 128 || exit 71
                    target=$(readlink "$fd") || exit 71
                    case "$target" in /dev/usb-ffs/adb/ep0) ep0=1;; /dev/usb-ffs/adb/ep1) ep1=1;; /dev/usb-ffs/adb/ep2) ep2=1;; esac
                  done
                  test "$ep0$ep1$ep2" != 111 || ready=1
                fi
              fi
            ;; esac
          fi
        fi
        printf 'ZTE_ADB_STATE_V1\nlinked=%s\nready=%s\nbound=%s\ndaemon=%s\n' "$linked" "$ready" "$bound" "$daemon"
        """;
    internal static AdbControlStatus Parse(byte[] data)
    {
        if (data.Length > 256 || data.Contains((byte)0)) throw new InvalidDataException("Некорректный ответ состояния ADB.");
        var lines = AdbShellOutput.NormalizeText(new UTF8Encoding(false, true).GetString(data)).Split('\n');
        if (lines.Length != 6 || lines[0] != "ZTE_ADB_STATE_V1" || lines[5] != "") throw new InvalidDataException("Неполный ответ состояния ADB.");
        string[] keys = ["linked", "ready", "bound", "daemon"];
        var values = new string[4];
        for (var i = 0; i < keys.Length; i++)
        {
            var prefix = keys[i] + "=";
            if (!lines[i + 1].StartsWith(prefix, StringComparison.Ordinal)) throw new InvalidDataException("Некорректное поле состояния ADB.");
            var value = lines[i + 1][prefix.Length..];
            if (value is not ("0" or "1" or "unknown")) throw new InvalidDataException("Некорректное значение состояния ADB.");
            values[i] = value;
        }
        if (values[0] == "0") return new(false, ReadyForChange: values.Skip(1).All(x => x == "1"));
        if (values.SequenceEqual(new[] { "1", "1", "1", "1" })) return new(true, ReadyForChange: true);
        if (values.SequenceEqual(new[] { "1", "0", "1", "0" })) return new(false);
        return new(null);
    }
}
public sealed partial class DeviceFeatureService
{
    public async Task<AdbControlStatus> GetAdbControlStatusAsync(CancellationToken ct = default)
    {
        await OperationGate.WaitAsync(ct);
        try
        {
            Directory.CreateDirectory(_storageRoot);
            using var localOperation = new FileStream(Path.Combine(_storageRoot, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return await new AdbToggleTransaction(_shell, _resourcesRoot, _storageRoot).ReadAsync(ct);
        }
        finally { OperationGate.Release(); }
    }

    public async Task<AdbControlStatus> SetAdbEnabledAsync(bool enabled, CancellationToken ct = default)
    {
        await OperationGate.WaitAsync(ct);
        try
        {
            Directory.CreateDirectory(_storageRoot);
            using var localOperation = new FileStream(Path.Combine(_storageRoot, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            CheckLocalPending();
            return await new AdbToggleTransaction(_shell, _resourcesRoot, _storageRoot).SetAsync(enabled, ct);
        }
        finally { OperationGate.Release(); }
    }
}
