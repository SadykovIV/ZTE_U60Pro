import Foundation

/// Observes USB ADB only. Host USB detection and a running daemon alone do not
/// establish FunctionFS readiness. A separate verified adapter controls writes.
struct ADBControlStatus: Equatable {
    var enabled: Bool?
    var supportsChange: Bool = false
    var descriptorsReady: Bool = false
    var message: String? = nil
    var detail: String {
        if let message { return message }
        if supportsChange { return enabled == true ? "USB ADB включён. Переключение действует до перезагрузки; USB-соединение кратко переподключится." : "USB ADB выключен. Переключение действует до перезагрузки; USB-соединение кратко переподключится." }
        switch enabled {
        case true: return "USB ADB включён. Безопасное переключение без изменения USB-сети не подтверждено для этой прошивки."
        case false: return "USB ADB выключен. Безопасное переключение без изменения USB-сети не подтверждено для этой прошивки."
        case nil: return "Состояние USB ADB не определено. Управление для этой конфигурации не подтверждено."
        }
    }
}
enum ADBControlProtocol {
    static let command = #"""
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
"""#
    static func parse(_ data: Data) throws -> ADBControlStatus {
        try require(data.count <= 256 && !data.contains(0), "Некорректный ответ состояния ADB")
        let lines = CommandText.decode(data).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try require(lines.count == 6 && lines[0] == "ZTE_ADB_STATE_V1" && lines[5].isEmpty, "Неполный ответ состояния ADB")
        var values: [String] = []
        for (index, key) in ["linked", "ready", "bound", "daemon"].enumerated() {
            let prefix = key + "="
            try require(lines[index + 1].hasPrefix(prefix), "Некорректное поле состояния ADB")
            let value = String(lines[index + 1].dropFirst(prefix.count))
            try require(["0", "1", "unknown"].contains(value), "Некорректное значение состояния ADB")
            values.append(value)
        }
        // A known missing USB function is off. Other incomplete/conflicting
        // observations remain unknown, including a daemon without descriptors.
        if values[0] == "0" { return .init(enabled: false, descriptorsReady: Array(values.suffix(3)) == ["1", "1", "1"]) }
        if values == ["1", "1", "1", "1"] { return .init(enabled: true, descriptorsReady: true) }
        if values == ["1", "0", "1", "0"] { return .init(enabled: false) }
        return .init(enabled: nil)
    }
}
