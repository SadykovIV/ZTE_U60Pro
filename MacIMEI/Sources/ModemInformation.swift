import Foundation

struct ModemInformation: Sendable {
    var collectedAt: Date
    var model: String
    var firmware: String
    var internalFirmware: String
    var distribution: String
    var systemVersion: String
    var revision: String
    var kernel: String
    var architecture: String
    var board: String
    var processor: String
    var cpuCount: Int
    var hostname: String
    var uptimeSeconds: Double
    var loadAverage: String
    var memoryTotalKiB: Int64
    var memoryAvailableKiB: Int64
    var memoryFreeKiB: Int64
    var memoryCachedKiB: Int64
    var swapTotalKiB: Int64
    var swapFreeKiB: Int64
    var volumes: [ModemStorageVolume]
    var readOnlyMounts: Set<String>
    var batteryPercent: Int?
    var batteryState: String
    var agentVersion: String
    var identity: Identity?
    var bootID: String
}

enum DiagnosticOutcome: String, Codable, Sendable {
    case succeeded, commandFailed, connectionError, skipped
    var title: String {
        switch self {
        case .succeeded: return "Собрано"
        case .commandFailed: return "Команда недоступна или завершилась ошибкой"
        case .connectionError: return "Ошибка подключения"
        case .skipped: return "Пропущено"
        }
    }
}
struct DiagnosticFile: Codable, Identifiable, Sendable {
    var name: String
    var title: String
    var status: Int32
    var bytes: Int
    var sha256: String
    var truncated: Bool
    var outcome: DiagnosticOutcome? = nil
    var effectiveOutcome: DiagnosticOutcome { outcome ?? (status == 0 ? .succeeded : status == 255 ? .connectionError : status == -1 ? .skipped : .commandFailed) }
    var statusLabel: String { outcome == nil && status == -1 ? "Нет данных (старый отчёт)" : effectiveOutcome.title }
    var id: String { name }
}
struct DiagnosticReport: Codable, Identifiable, Sendable {
    var id: String
    var created: String
    var identity: Identity?
    var bootID: String
    var warnings: [String]? = nil
    var files: [DiagnosticFile]
    var url: URL
    var transport: String? = nil
    var selectionReason: String? = nil
    var identityVerified: Bool? = nil
    var connectionError: String? = nil
    var outcomeSummary: String {
        let succeeded = files.filter { $0.effectiveOutcome == .succeeded }.count
        let failed = files.filter { $0.effectiveOutcome == .commandFailed }.count
        let connection = files.filter { $0.effectiveOutcome == .connectionError }.count + (connectionError == nil ? 0 : 1)
        let skipped = files.filter { $0.effectiveOutcome == .skipped }.count
        return "Собрано: \(succeeded); ошибки команд: \(failed); ошибки подключения: \(connection); пропущено: \(skipped). Это статусы сбора, а не число неисправностей модема."
    }
}

final class ModemInformationManager {
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }
    static let command = #"""
    set -eu
    printf '__INFO_SCHEMA__\n1\n__INFO_BOARD__\n'
    ubus call system board 2>/dev/null || printf '{}\n'
    printf '__INFO_DEVICE__\n'
    ubus call zwrt_web device_info '{}' || printf '{}\n'
    printf '__INFO_ARCH__\n'
    uname -m
    printf '__INFO_CPU__\n'
    awk '/^processor[ \t]*:/ {n++} END {print n+0}' /proc/cpuinfo
    printf '__INFO_UPTIME__\n'
    cat /proc/uptime
    printf '__INFO_LOAD__\n'
    cut -d ' ' -f 1-3 /proc/loadavg
    printf '__INFO_MEMORY__\n'
    cat /proc/meminfo
    printf '__INFO_DISKS__\n'
    df -Pk
    printf '__INFO_MOUNTS__\n'
    cat /proc/mounts
    printf '__INFO_BATTERY__\n'
    cat /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/status 2>/dev/null || true
    printf '__INFO_AGENT__\n'
    sha256sum /data/zte-agent 2>/dev/null || true
    printf '__INFO_END__\n'
    """#
    func inspect(readOnly: Bool = false) throws -> ModemInformation {
        if readOnly {
            let before = try SSHReadProof.parse(engine.remote(SSHReadProof.command, timeout: 15))
            let response = try engine.remote(Self.command, timeout: 30)
            let result = try Self.parse(String(decoding: response, as: UTF8.self), identity: before.identity, boot: before.bootID ?? "")
            try before.verify(SSHReadProof.parse(engine.remote(SSHReadProof.command, timeout: 15)))
            return result
        }
        let (identity, boot) = try engine.identity()
        let response = try engine.remote(Self.command, timeout: 30)
        try require(response.count <= 1024 * 1024, "Ответ со сведениями о модеме слишком большой")
        let result = try Self.parse(String(decoding: response, as: UTF8.self), identity: identity, boot: boot)
        let after = try engine.identity()
        try require(after.0 == identity && after.1 == boot, "Модем перезагрузился во время чтения сведений. Обновите данные.")
        return result
    }
    static func parse(_ text: String, identity: Identity?, boot: String) throws -> ModemInformation {
        try require(text.utf8.count <= 1024 * 1024, "Ответ со сведениями о модеме слишком большой")
        let expected = ["SCHEMA", "BOARD", "DEVICE", "ARCH", "CPU", "UPTIME", "LOAD", "MEMORY", "DISKS", "MOUNTS", "BATTERY", "AGENT", "END"].map { "__INFO_" + $0 + "__" }
        var sections: [String: String] = [:], current: String?, seen = [String]()
        for line in CommandText.normalize(text).components(separatedBy: "\n") {
            if line.hasPrefix("__INFO_") && line.hasSuffix("__") {
                try require(sections[line] == nil, "Повтор раздела сведений о модеме")
                try require(seen.count < expected.count && line == expected[seen.count], "Неизвестный или пропущенный раздел сведений")
                seen.append(line); sections[line] = ""; current = line
            } else if let key = current { sections[key, default: ""] += line + "\n" }
            else { try require(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Лишние данные перед сведениями о модеме") }
        }
        try require(seen == expected && sections["__INFO_END__"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true, "Неполные сведения о модеме")
        try require(sections["__INFO_SCHEMA__"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" && sections["__INFO_END__"] != nil, "Неполные сведения о модеме")
        func value(_ key: String) -> String { sections["__INFO_" + key + "__", default: ""].trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let board = try JSONSerialization.jsonObject(with: Data(value("BOARD").utf8)) as? [String: Any] else { throw IMEIError.message("Не удалось прочитать сведения об ОС") }
        let release = board["release"] as? [String: Any] ?? [:]
        let device = (try? JSONSerialization.jsonObject(with: Data(value("DEVICE").utf8))) as? [String: Any] ?? [:]
        var memory: [String: Int64] = [:]
        for line in value("MEMORY").split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let name = fields.first.map(String.init), name.hasSuffix(":") else { continue }
            let key = String(name.dropLast())
            guard ["MemTotal", "MemAvailable", "MemFree", "Cached", "SwapTotal", "SwapFree"].contains(key) else { continue }
            try require(memory[key] == nil && fields.count == 3 && fields[2] == "kB", "Неверный формат оперативной памяти")
            guard let number = Int64(fields[1]), number >= 0 && number <= Int64.max / 1024 else { throw IMEIError.message("Некорректный объём памяти") }
            memory[key] = number
        }
        guard let total = memory["MemTotal"], total > 0, let available = memory["MemAvailable"], available <= total else { throw IMEIError.message("Некорректные данные оперативной памяти") }
        try require((memory["MemFree"] ?? 0) <= total && (memory["Cached"] ?? 0) <= total && (memory["SwapFree"] ?? 0) <= (memory["SwapTotal"] ?? 0), "Несогласованные значения памяти")
        var volumes: [ModemStorageVolume] = []
        for line in value("DISKS").split(separator: "\n").dropFirst() {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count == 6, let size = Int64(f[1]), let used = Int64(f[2]), let free = Int64(f[3]), size > 0, size <= Int64.max / 1024, used >= 0, free >= 0, used <= size, free <= size else { continue }
            let mount = String(f[5])
            // Bind-mounted screen resources are files, not additional storage.
            if mount.hasSuffix(".ini") || mount == "/usr/bin/zte_topsw_devui" { continue }
            if !volumes.contains(where: { $0.mount == mount }) { volumes.append(ModemStorageVolume(mount: mount, totalKiB: size, usedKiB: used, availableKiB: free)) }
        }
        var readOnly = Set<String>()
        for line in value("MOUNTS").split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.count >= 4 && f[3].split(separator: ",").contains("ro") { readOnly.insert(String(f[1])) }
        }
        let battery = value("BATTERY").split(separator: "\n").map(String.init)
        let capacity = battery.first.flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil }
        let agentSHA = value("AGENT").split(separator: " ").first.map(String.init) ?? ""
        let agentVersion = BundledAgent.description(for: agentSHA)
        guard let uptimeField = value("UPTIME").split(whereSeparator: \.isWhitespace).first,
              let uptime = Double(uptimeField), uptime.isFinite && uptime >= 0 && uptime <= 100 * 366 * 24 * 3600,
              let cpuCount = Int(value("CPU")), (1...4096).contains(cpuCount) else { throw IMEIError.message("Некорректные сведения о времени работы или процессоре") }
        let loads = value("LOAD").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        try require(loads.count == 3 && loads.allSatisfy { $0.isFinite && $0 >= 0 }, "Некорректная загрузка процессора")
        return ModemInformation(collectedAt: Date(), model: board["model"] as? String ?? "Модель не определена", firmware: device["integrate_version"] as? String ?? "Версия не определена",
            internalFirmware: device["wa_inner_version"] as? String ?? "—", distribution: release["distribution"] as? String ?? "—", systemVersion: release["version"] as? String ?? "—",
            revision: release["revision"] as? String ?? "—", kernel: board["kernel"] as? String ?? "—", architecture: value("ARCH"), board: board["board_name"] as? String ?? "—",
            processor: board["system"] as? String ?? "—", cpuCount: cpuCount, hostname: board["hostname"] as? String ?? "—", uptimeSeconds: uptime, loadAverage: value("LOAD"),
            memoryTotalKiB: total, memoryAvailableKiB: available, memoryFreeKiB: memory["MemFree"] ?? 0, memoryCachedKiB: memory["Cached"] ?? 0,
            swapTotalKiB: memory["SwapTotal"] ?? 0, swapFreeKiB: memory["SwapFree"] ?? 0, volumes: volumes, readOnlyMounts: readOnly,
            batteryPercent: capacity, batteryState: battery.dropFirst().first ?? "—", agentVersion: agentVersion, identity: identity, bootID: boot)
    }

    static let setupStateCommand = #"""
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
for base in /data/zte-imei-studio/installations /data/local/tmp/zte-imei-installations; do
  printf 'INSTALLATIONS %s\n' "$base"
  safe=1; parent=$base
  while test "$parent" != /; do
    if test -L "$parent" || test ! -d "$parent" || test ! -r "$parent" || test ! -x "$parent"; then safe=0; break; fi
    parent=${parent%/*}; test -n "$parent" || parent=/
  done
  if test "$safe" != 1; then printf 'layout=absent-or-unreadable\n'; continue; fi
  active=
  if test -f "$base/active" && test ! -L "$base/active" && test "$(stat -c %s "$base/active")" -le 64; then
    candidate=$(cat "$base/active")
    if printf '%s\n' "$candidate" | grep -qE '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'; then active=$candidate; printf 'active=present\n'; else printf 'active=invalid\n'; fi
  elif test -e "$base/active" || test -L "$base/active"; then printf 'active=unreadable\n'
  else printf 'active=absent\n'; fi
  if test -d "$base/lock" && test ! -L "$base/lock"; then printf 'lock=present\n'; else printf 'lock=absent-or-invalid\n'; fi
  count=0
  for journal in "$base"/*; do
    test -d "$journal" && test ! -L "$journal" || continue
    name=${journal##*/}
    printf '%s\n' "$name" | grep -qE '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' || continue
    count=$((count+1)); test "$count" -le 32 || { printf 'journals=truncated\n'; break; }
    printf 'journal=%s\n' "$count"
    if test "$name" = "$active"; then printf 'current=yes\n'; else printf 'current=no\n'; fi
    for key in state mode; do
      value=unavailable
      if test -f "$journal/$key" && test ! -L "$journal/$key" && test "$(stat -c %s "$journal/$key")" -le 64; then
        candidate=$(cat "$journal/$key")
        case "$key:$candidate" in state:preparing|state:pending|state:ready|state:complete|state:rolled-back|mode:reinstall|mode:install) value=$candidate;; *) value=unknown;; esac
      fi
      printf '%s=%s\n' "$key" "$value"
    done
    for file in before.sha256 after.sha256 targets cid profile.identity; do
      if test -f "$journal/$file" && test ! -L "$journal/$file"; then printf '%s=present\n' "$file"; else printf '%s=absent-or-invalid\n' "$file"; fi
    done
  done
  printf 'journal_count=%s\n' "$count"
done
printf 'RESET_RECOVERY\n'
anchor=/data/zte-imei-studio
safe=1; parent=$anchor
while test "$parent" != /; do
  if test -L "$parent" || test ! -d "$parent" || test ! -r "$parent" || test ! -x "$parent"; then safe=0; break; fi
  parent=${parent%/*}; test -n "$parent" || parent=/
done
if test "$safe" != 1; then printf 'archive_layout=absent-or-unreadable\n'
else
  count=0; metadata_present=0; metadata_incomplete=0; unsafe=0; truncated=0
  for archive in "$anchor"/reset-recovery-*; do
    test -e "$archive" || test -L "$archive" || continue
    name=${archive##*/}
    printf '%s\n' "$name" | grep -qE '^reset-recovery-[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}-[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' || continue
    count=$((count+1)); test "$count" -le 32 || { truncated=1; break; }
    if test ! -d "$archive" || test -L "$archive" || test "$(stat -c '%u:%a' "$archive" 2>/dev/null)" != 0:700; then unsafe=$((unsafe+1)); continue; fi
    present=1
    for directory in journal current; do
      test -d "$archive/$directory" && test ! -L "$archive/$directory" || present=0
    done
    for file in snapshot.sha256 cid boot; do
      test -f "$archive/$file" && test ! -L "$archive/$file" || present=0
    done
    if test "$present" = 1; then metadata_present=$((metadata_present+1)); else metadata_incomplete=$((metadata_incomplete+1)); fi
  done
  printf 'archive_count=%s\narchive_metadata_present=%s\narchive_metadata_incomplete=%s\narchive_layout_unsafe=%s\narchive_inventory_truncated=%s\n' "$count" "$metadata_present" "$metadata_incomplete" "$unsafe" "$truncated"
  printf 'archive_contents_verified=not-performed\n'
fi
:
"""#
    static let diagnosticCommands: [(String, String, String)] = [
        ("firmware.txt", "Версии и хэши прошивки", "uname -a; cat /etc/openwrt_release /etc/os-release; sha256sum /firmware/image/modem.b16 /usr/bin/diag-router /usr/bin/zte_topsw_devui"),
        ("capabilities.txt", "Доступные инструменты", "for tool in ubus ip iptables ip6tables nft bridge opkg curl tar sha256sum awk sed logread dmesg dropbear doas mount umount df stat readlink mkdir mktemp chown chmod flock timeout base64 openssl unzip; do printf '%s: ' \"$tool\"; command -v \"$tool\" || true; done; printf 'Versions:\\n'; busybox | head -n 1; iptables --version; :"),
        ("rpc-methods.txt", "Методы служб прошивки", "ubus -v list"),
        ("packages.txt", "Установленные пакеты", "opkg list-installed"),
        ("modules.txt", "Модули ядра", "cat /proc/modules /proc/filesystems"),
        ("routing-policy.txt", "Правила маршрутизации", "ip -4 rule; ip -4 route show table all; ip -6 rule; ip -6 route show table all"),
        ("components.txt", "Хэши компонентов приложения", "for p in /data/zte-agent /data/zte-imei-studio/bin/dropbear /data/zte-imei-studio/start_zte_imei_studio.sh /data/bin/dropbear /data/local/tmp/start_zte_imei_studio.sh /data/zte-vpn/vpnctl /data/zte-vpn/mihomo /data/zte-imei-ttl/manager.sh /data/zte-launcher/launcher-start.sh; do if test -f \"$p\"; then sha256sum \"$p\"; else printf '%s: absent\\n' \"$p\"; fi; done"),
        ("system.log", "Системный журнал", "if ubus list log 2>/dev/null | grep -qFx log; then logread; else printf 'Служба системного журнала недоступна\\n'; exit 3; fi"),
        ("kernel.log", "Журнал ядра", "dmesg"),
        ("board.json", "Система и плата", "ubus call system board"),
        ("device.json", "Сведения ZTE", "ubus call zwrt_web device_info '{}'"),
        ("memory.txt", "Память и загрузка", "cat /proc/meminfo /proc/loadavg /proc/uptime"),
        ("storage.txt", "Диски и подключения", "df -Pk; cat /proc/mounts /proc/partitions"),
        ("filesystem-layout.txt", "Каталоги и права Linux", #"printf 'Linux filesystem metadata only. Linux /config is NOT modem EFS /config accessed through DIAG; this does not establish IMEI/NV compatibility.\n'; for p in /data /data/local /data/local/tmp /config /tmp /data/bin /etc/dropbear /usr/bin/diag-router /firmware/image/modem.b16; do printf '\nPATH %s\n' "$p"; if test -e "$p" || test -L "$p"; then ls -ld "$p"; stat -c 'type=%F mode=%a uid=%u gid=%g bytes=%s links=%h' "$p" || true; if test -L "$p"; then printf 'link='; readlink "$p" || true; fi; if test -d "$p"; then if test -w "$p"; then printf 'access_writable=yes\n'; else printf 'access_writable=no\n'; fi; fi; else printf 'absent\n'; fi; done; printf '\nMounts and free space:\n'; cat /proc/self/mountinfo; df -Pk"#),
        ("network.json", "Сетевые интерфейсы", "ubus call network.interface dump"),
        ("routes.txt", "Адреса и маршруты", "ip -s address; ip -4 route; ip -6 route"),
        ("firewall4.txt", "Правила IPv4", "iptables-save"),
        ("firewall6.txt", "Правила IPv6", "ip6tables-save"),
        ("usb.txt", "USB и ADB", "for p in /sys/class/android_usb/android0/functions /sys/class/android_usb/android0/state; do printf '%s: ' \"$p\"; if test -r \"$p\"; then cat \"$p\" 2>/dev/null || printf 'недоступно\\n'; else printf 'недоступно\\n'; fi; done; printf 'ConfigFS USB functions:\\n'; if test -d /config/usb_gadget/g1/configs/b.1; then for p in /config/usb_gadget/g1/configs/b.1/*; do test -L \"$p\" || continue; printf '%s -> ' \"${p##*/}\"; readlink \"$p\" 2>/dev/null || printf 'недоступно\\n'; done; else printf 'недоступно\\n'; fi; printf 'USB devices:\\n'; if test -d /sys/bus/usb/devices; then ls /sys/bus/usb/devices 2>/dev/null || printf 'недоступно\\n'; else printf 'недоступно\\n'; fi"),
        ("power.txt", "Аккумулятор и питание", "for n in capacity status health voltage_now current_now temp; do printf '%s=' \"$n\"; cat /sys/class/power_supply/battery/\"$n\" 2>/dev/null || true; done"),
        ("thermal.txt", "Температуры", "for p in /sys/class/thermal/thermal_zone*; do printf '%s ' \"${p##*/}\"; cat \"$p/type\" \"$p/temp\" 2>/dev/null || true; done"),
        ("processes.txt", "Процессы", "for p in /proc/[0-9]*/status; do test -r \"$p\" || continue; awk '/^(Name|Pid|PPid|State|VmRSS|Threads):/ {print}' \"$p\" 2>/dev/null || continue; printf '\\n'; done; :"),
        ("listeners.txt", "Сетевые службы", "cat /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6"),
        ("setup-state.txt", "Состояние подготовки модема", setupStateCommand),
        ("services.txt", "Агент и службы", "found=0; for p in /tmp/zte-agent.log /tmp/dashboard-uhttpd.log /data/zte-vpn/last-validation.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 131072 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'Отдельные файлы журналов служб отсутствуют; агент может использовать системный журнал.\\n'; exit 3; fi"),
        ("vpn.log", "Журналы VPN", "found=0; for p in /data/zte-vpn/core.log /data/zte-vpn/core.previous.log /data/zte-vpn/actions.log /data/zte-vpn/profile-actions.jsonl /data/zte-vpn/firewall.log /data/zte-vpn/reload.log /data/zte-vpn/dns.log /data/zte-vpn/dns.previous.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 65536 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'VPN runtime logs are not present\\n'; fi"),
        ("vpn-runtime.txt", "Состояние сети VPN", "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; run() { printf '\\nCOMMAND'; printf ' %s' \"$@\"; printf '\\n'; \"$@\" 2>&1 || printf 'READ_FAILED=%s\\n' \"$?\"; }; for name in core dns; do p=/data/zte-vpn/$name.pid; printf '\\nPROCESS %s\\n' \"$name\"; if test -f \"$p\" && test ! -L \"$p\"; then pid=$(cat \"$p\"); case \"$pid\" in ''|*[!0-9]*) printf 'INVALID_PID\\n';; *) run readlink \"/proc/$pid/exe\";; esac; else printf 'MISSING_PID\\n'; fi; done; for dev in br-vpn zvpn-tun wlan1 wlan3; do run ip -s link show dev \"$dev\"; run readlink \"/sys/class/net/$dev/master\"; done; run ip -4 addr show dev br-vpn; run ip -4 route show table 19090; run ip -4 rule show; run ip -4 route show; for section in guest_2g guest_5g; do for field in disabled network bridge guest_active_time guest_remaining; do run uci -q get \"wireless.$section.$field\"; done; done; for dev in wlan1 wlan3; do printf '\\nHOSTAPD %s\\n' \"$dev\"; hostapd_cli -p /data/vendor/wifi/hostapd -i \"$dev\" status 2>/dev/null | sed -n '/^state=/p'; done; run cat /proc/net/tcp /proc/net/udp; for spec in 'filter ZVPN_IN' 'filter ZVPN_FW' 'mangle ZVPN_PRE' 'nat ZVPN_DNS'; do set -- $spec; run iptables -w 2 -t \"$1\" -nvxL \"$2\"; done; run nft list table inet zte_vpn_guard; for chain in ZVPN_L2IN ZVPN_L2FW ZVPN_L2OUT; do run ebtables -L \"$chain\" --Lc; done; run cat /proc/sys/net/ipv4/ip_forward; for dev in all br-vpn zvpn-tun; do run cat \"/proc/sys/net/ipv4/conf/$dev/rp_filter\"; done; :"),
    ]
    static let logCommands = diagnosticCommands.filter { ["system.log", "kernel.log", "services.txt", "vpn.log", "vpn-runtime.txt", "setup-state.txt"].contains($0.0) }
    static let diagnosticByteLimit = 512 * 1024
    /// Footer status belongs to the producer only when SSH/the wrapper succeeded.
    /// Cap bytes before decoding, redact before export, and preserve UTF-8 boundaries.
    static func decodeDiagnostic(_ response: CommandResult) -> (body: Data, status: Int32, truncated: Bool) {
        let marker = Data("\n__DIAGNOSTIC_RESULT__".utf8)
        let location = response.stdout.range(of: marker, options: .backwards)
        let footer = location.map { String(decoding: response.stdout[$0.upperBound...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let producer = footer.flatMap(Int32.init).flatMap { (0...255).contains($0) ? $0 : nil }
        var status = response.status != 0 ? response.status : producer ?? -2
        var payload = location.map { Data(response.stdout[..<$0.lowerBound]) } ?? response.stdout
        // The marker starts at LF, so any transport-added CR in its separator
        // is still in payload. Remove only the CR count shown by the matching
        // footer EOL; all remaining bytes are interpreted as text below.
        if location != nil && response.stdout.last == 10 {
            let suffix = response.stdout.dropLast().suffix(3)
            let count = suffix.reversed().prefix { $0 == 13 }.count
            if count <= 2 && payload.suffix(count).allSatisfy({ $0 == 13 }) && payload.count >= count { payload.removeLast(count) }
        }
        if response.status != 0 || producer == nil {
            if !response.stderr.isEmpty { payload.append(Data("\n".utf8)); payload.append(response.stderr) }
        }
        let clean = ActivityJournal.sanitize(CommandText.decode(Data(payload.prefix(diagnosticByteLimit))))
        let truncated = payload.count > diagnosticByteLimit || clean.utf8.count > diagnosticByteLimit
        // BusyBox reports 128+SIGXFSZ (153) when the intentional file limit
        // stops a large producer such as dmesg. The captured prefix is valid.
        if response.status == 0 && producer == 153 && payload.count > diagnosticByteLimit { status = 0 }
        var bytes = Data(clean.utf8.prefix(diagnosticByteLimit))
        while !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        if truncated { bytes.append(Data("\n[Вывод ограничен 512 КиБ]\n".utf8)) }
        return (bytes, status, truncated)
    }
    private func sshDiagnosticSession(expected: DiagnosticDeviceExpectation) throws -> DiagnosticSession {
        let read: () throws -> SSHReadProof = {
            let result = try self.engine.transport.run(SSHReadProof.command, input: nil, timeout: 15)
            try require(result.status == 0, "Не удалось проверить сеанс SSH; другой канал не запрашивался")
            return try SSHReadProof.parse(result.stdout)
        }
        let proof = try read()
        try require(proof.matches(expected), "SSH подключён к другому модему; сбор остановлен")
        return DiagnosticSession(reason: "Диагностика использует SSH с проверенным ключом сервера", proof: proof, readIdentity: read) { command, timeout in
            let result = try self.engine.transport.run(command, input: nil, timeout: timeout)
            try require(result.status != 255, "Соединение SSH потеряно; другой канал не запрашивался")
            return result
        }
    }
    func collectDiagnostics(expectedIdentity: Identity? = nil, expectedWebIdentity: WebIdentity? = nil, expectedIMEI: String? = nil, adb: ADBClient? = nil, preferredSession: DiagnosticSession? = nil, logsOnly: Bool = false) throws -> DiagnosticReport {
        try require(engine.lockFD >= 0, "Диагностика требует блокировки операции")
        try require(preferredSession == nil || preferredSession?.transport == "ssh", "Диагностика модема доступна только через SSH")
        var warnings = [String](), selectionError: String?
        let session: DiagnosticSession?
        do {
            let expected = try DiagnosticDeviceExpectation.load(root: engine.root, identity: expectedIdentity, web: expectedWebIdentity, imei: expectedIMEI)
            if let preferredSession {
                try require(preferredSession.readProof.matches(expected) && (preferredSession.proof?.webIdentity.map { expected.imeis.isEmpty || expected.imeis.contains($0.imei) } ?? true), "Выбранный канал относится к другому модему; переключение транспорта запрещено")
                try preferredSession.verify()
                session = preferredSession
            } else {
                session = try sshDiagnosticSession(expected: expected)
            }
        } catch {
            session = nil
            selectionError = ActivityJournal.sanitize(error.localizedDescription)
            warnings.append("Сбор не начат: " + selectionError!)
        }
        if !logsOnly, let session, session.readProof.firmwareHash != ModemEngine.firmwareHash {
            warnings.append("Прошивка отличается от B31. Выполнено только чтение диагностики; разрешение на запись не изменено.")
        }
        let id = UUID().uuidString.lowercased(), directory = engine.root.appendingPathComponent("Diagnostics/" + id)
        try secureDirectory(directory)
        var files: [DiagnosticFile] = [], connectionFailures = 0
        let commands = logsOnly ? Self.logCommands : Self.diagnosticCommands
        for (index, item) in commands.enumerated() {
            engine.update("Диагностика: " + item.1, Double(index) / Double(commands.count + 1))
            let body: Data, status: Int32, truncated: Bool, outcome: DiagnosticOutcome
            if session == nil || connectionFailures >= 3 {
                body = Data((session == nil ? "Раздел не запрашивался: " + (selectionError ?? "транспорт недоступен") : "Раздел не запрашивался после трёх ошибок подключения").utf8)
                status = -3; truncated = false; outcome = .skipped
            } else {
                let cap = Self.diagnosticByteLimit
                // Only a private temporary output buffer is written on the modem;
                // no service, permissions, firmware or ADB settings are changed.
                let command = "umask 077; d=$(mktemp -d /tmp/zte-diagnostic.XXXXXX) || exit 1; trap 'rm -f \"$d/out\"; rmdir \"$d\"' EXIT HUP INT TERM; ( set -e; ulimit -f 1025; " + item.2 + " ) > \"$d/out\" 2>&1; code=$?; head -c \(cap + 1) \"$d/out\"; printf '\\n__DIAGNOSTIC_RESULT__%s\\n' \"$code\""
                do {
                    let response = try session!.run(command, timeout: 20)
                    let decoded = Self.decodeDiagnostic(response)
                    body = decoded.body; status = decoded.status; truncated = decoded.truncated
                    outcome = status == 0 ? .succeeded : .commandFailed
                    connectionFailures = 0
                } catch {
                    connectionFailures += 1
                    body = Data(ActivityJournal.sanitize(error.localizedDescription).utf8)
                    status = -1; truncated = false; outcome = .connectionError
                }
            }
            try savePrivate(body, directory.appendingPathComponent(item.0))
            files.append(DiagnosticFile(name: item.0, title: item.1, status: status, bytes: body.count, sha256: digest(body), truncated: truncated, outcome: outcome))
        }
        var verified = false
        if let session {
            do { try session.verify(); verified = true }
            catch { warnings.append("Итоговая проверка устройства недоступна: " + ActivityJournal.sanitize(error.localizedDescription)) }
        }
        if connectionFailures >= 3 { warnings.append("Соединение недоступно. Сохранён частичный набор; остальные разделы помечены как пропущенные.") }
        let report = DiagnosticReport(id: id, created: ISO8601DateFormatter().string(from: Date()), identity: session?.readProof.identity, bootID: session?.readProof.bootID ?? "не определён", warnings: warnings, files: files, url: directory, transport: session?.transport ?? preferredSession?.transport ?? "none", selectionReason: session?.selectionReason ?? selectionError, identityVerified: verified, connectionError: selectionError)
        try saveJSON(report, directory.appendingPathComponent("manifest.json"))
        try? ActivityJournal(root: engine.root).record(operationID: engine.logDirectory.lastPathComponent, category: "diagnostics", title: "Диагностический набор сохранён", result: warnings.isEmpty && files.allSatisfy { $0.effectiveOutcome == .succeeded } ? "completed" : "warning", details: ["reportID":id,"transport":report.transport ?? "none", "selectionReason": report.selectionReason ?? "", "summary":report.outcomeSummary, "warnings":warnings.joined(separator: "\n")])
        return report
    }
}
