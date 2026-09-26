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
    var identity: Identity
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
    ubus call system board
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
        let (identity, boot) = try readOnly ? engine.diagnosticIdentity() : engine.identity()
        let response = try engine.remote(Self.command, timeout: 30)
        try require(response.count <= 1024 * 1024, "Ответ со сведениями о модеме слишком большой")
        let result = try Self.parse(String(decoding: response, as: UTF8.self), identity: identity, boot: boot)
        let after = try readOnly ? engine.diagnosticIdentity() : engine.identity()
        try require(after.0 == identity && after.1 == boot, "Модем перезагрузился во время чтения сведений. Обновите данные.")
        return result
    }
    static func parse(_ text: String, identity: Identity, boot: String) throws -> ModemInformation {
        try require(text.utf8.count <= 1024 * 1024, "Ответ со сведениями о модеме слишком большой")
        let expected = ["SCHEMA", "BOARD", "DEVICE", "ARCH", "CPU", "UPTIME", "LOAD", "MEMORY", "DISKS", "MOUNTS", "BATTERY", "AGENT", "END"].map { "__INFO_" + $0 + "__" }
        var sections: [String: String] = [:], current: String?, seen = [String]()
        for line in text.components(separatedBy: "\n") {
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
        let agentVersion = agentSHA == "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346" ? "2.8.0 · VPN, дисплей, RU/EN и TTL" : agentSHA == "b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537" ? "2.4.1 · RU/EN и TTL" : agentSHA == "5deb5e93ee7d37403b0a931f0e127c64e4d9b4825855653e5b890572b02848aa" ? "2.4.0" : agentSHA.isEmpty ? "Не установлен" : "Другая сборка"
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

    static let diagnosticCommands: [(String, String, String)] = [
        ("firmware.txt", "Версии и хэши прошивки", "uname -a; cat /etc/openwrt_release /etc/os-release; sha256sum /firmware/image/modem.b16 /usr/bin/diag-router /usr/bin/zte_topsw_devui"),
        ("capabilities.txt", "Доступные инструменты", "for tool in ubus ip iptables ip6tables nft bridge opkg curl tar sha256sum awk sed logread dmesg dropbear doas mount umount df stat readlink mkdir mktemp chown chmod flock timeout base64 openssl unzip; do printf '%s: ' \"$tool\"; command -v \"$tool\" || true; done; printf 'Versions:\\n'; busybox | head -n 1; iptables --version; :"),
        ("rpc-methods.txt", "Методы служб прошивки", "ubus -v list"),
        ("packages.txt", "Установленные пакеты", "opkg list-installed"),
        ("modules.txt", "Модули ядра", "cat /proc/modules /proc/filesystems"),
        ("routing-policy.txt", "Правила маршрутизации", "ip -4 rule; ip -4 route show table all; ip -6 rule; ip -6 route show table all"),
        ("components.txt", "Хэши компонентов приложения", "for p in /data/zte-agent /data/bin/dropbear /data/local/tmp/start_zte_imei_studio.sh /data/zte-vpn/vpnctl /data/zte-vpn/mihomo /data/zte-imei-ttl/manager.sh /data/zte-launcher/launcher-start.sh; do if test -f \"$p\"; then sha256sum \"$p\"; else printf '%s: absent\\n' \"$p\"; fi; done"),
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
        ("services.txt", "Агент и службы", "found=0; for p in /tmp/zte-agent.log /tmp/dashboard-uhttpd.log; do if test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c %u \"$p\")\" = 0; then printf '%s\\n' \"$p\"; tail -c 131072 \"$p\"; found=1; fi; done; if test \"$found\" = 0; then printf 'Отдельные файлы журналов служб отсутствуют; агент может использовать системный журнал.\\n'; exit 3; fi"),
    ]
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
        if response.status != 0 || producer == nil {
            if !response.stderr.isEmpty { payload.append(Data("\n".utf8)); payload.append(response.stderr) }
        }
        let clean = ActivityJournal.sanitize(String(decoding: payload.prefix(diagnosticByteLimit), as: UTF8.self))
        let truncated = payload.count > diagnosticByteLimit || clean.utf8.count > diagnosticByteLimit
        // BusyBox reports 128+SIGXFSZ (153) when the intentional file limit
        // stops a large producer such as dmesg. The captured prefix is valid.
        if response.status == 0 && producer == 153 && payload.count > diagnosticByteLimit { status = 0 }
        var bytes = Data(clean.utf8.prefix(diagnosticByteLimit))
        while !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        if truncated { bytes.append(Data("\n[Вывод ограничен 512 КиБ]\n".utf8)) }
        return (bytes, status, truncated)
    }
    func collectDiagnostics(expectedIdentity: Identity? = nil, expectedWebIdentity: WebIdentity? = nil, expectedIMEI: String? = nil, adb: ADBClient? = nil, preferredSession: DiagnosticSession? = nil) throws -> DiagnosticReport {
        try require(engine.lockFD >= 0, "Диагностика требует блокировки операции")
        var warnings = [String](), selectionError: String?
        let session: DiagnosticSession?
        do {
            let expected = try DiagnosticDeviceExpectation.load(root: engine.root, identity: expectedIdentity, web: expectedWebIdentity, imei: expectedIMEI)
            if let preferredSession {
                try require(expected.matches(preferredSession.proof), "Выбранный канал относится к другому модему; переключение транспорта запрещено")
                try preferredSession.verify()
                session = preferredSession
            } else {
                session = try DiagnosticTransportSelector.select(engine: engine, expected: expected, adb: adb)
            }
        } catch {
            session = nil
            selectionError = ActivityJournal.sanitize(error.localizedDescription)
            warnings.append("Сбор не начат: " + selectionError!)
        }
        if let session, session.proof.identity.firmwareHash != ModemEngine.firmwareHash {
            warnings.append("Прошивка отличается от B31. Выполнено только чтение диагностики; разрешение на запись не изменено.")
        }
        let id = UUID().uuidString.lowercased(), directory = engine.root.appendingPathComponent("Diagnostics/" + id)
        try secureDirectory(directory)
        var files: [DiagnosticFile] = [], connectionFailures = 0
        for (index, item) in Self.diagnosticCommands.enumerated() {
            engine.update("Диагностика: " + item.1, Double(index) / Double(Self.diagnosticCommands.count + 1))
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
        let report = DiagnosticReport(id: id, created: ISO8601DateFormatter().string(from: Date()), identity: session?.proof.identity, bootID: session?.proof.bootID ?? "не определён", warnings: warnings, files: files, url: directory, transport: session?.transport ?? preferredSession?.transport ?? "none", selectionReason: session?.selectionReason ?? selectionError, identityVerified: verified, connectionError: selectionError)
        try saveJSON(report, directory.appendingPathComponent("manifest.json"))
        try? ActivityJournal(root: engine.root).record(operationID: engine.logDirectory.lastPathComponent, category: "diagnostics", title: "Диагностический набор сохранён", result: warnings.isEmpty && files.allSatisfy { $0.effectiveOutcome == .succeeded } ? "completed" : "warning", details: ["reportID":id,"transport":report.transport ?? "none", "selectionReason": report.selectionReason ?? "", "summary":report.outcomeSummary, "warnings":warnings.joined(separator: "\n")])
        return report
    }
}
