import Foundation

struct AgentCandidate: Sendable {
    let url: URL
    let bytes: Int
    let sha256: String
    let interpreter: String?
    static let maxBytes = 64 * 1024 * 1024
    static func inspect(_ url: URL) throws -> AgentCandidate {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true && (64...maxBytes).contains(values.fileSize ?? 0), "Выберите исполняемый файл агента размером от 64 байт до 64 МиБ, не архив и не ссылку")
        let data = try Data(contentsOf: url)
        let interpreter = try validateELF(data)
        return AgentCandidate(url: url, bytes: data.count, sha256: digest(data), interpreter: interpreter)
    }
    static func validateELF(_ data: Data) throws -> String? {
        try require((64...maxBytes).contains(data.count), "Некорректный размер файла агента")
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at+1]) << 8 }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(data[at+$1]) << (8*$1) } }
        try require(data.prefix(4) == Data([0x7f,69,76,70]) && data[4] == 2 && data[5] == 1 && data[6] == 1 &&
                    [0,3].contains(data[7]) && [2,3].contains(u16(16)) && u16(18) == 183 && data.u32(20) == 1 && u16(52) == 64,
                    "Нужен исполняемый ELF64 Linux для ARM64 (AArch64), не файл macOS, Windows или x86")
        let table = u64(32), count = u16(56)
        try require(u16(54) == 56 && (1...128).contains(count) && table <= UInt64(data.count) && UInt64(count * 56) <= UInt64(data.count) - table, "Повреждена таблица сегментов ELF")
        var executableEntry = false, interpreter: String?
        let entry = u64(24)
        for index in 0..<count {
            let start = Int(table) + index * 56, type = data.u32(start), flags = data.u32(start + 4)
            let offset = u64(start+8), address = u64(start+16), size = u64(start+32), memory = u64(start+40)
            try require(offset <= UInt64(data.count) && size <= UInt64(data.count) - offset, "Сегмент ELF выходит за конец файла")
            if type == 1 {
                try require(size <= memory, "Некорректный размер сегмента ELF")
                if flags & 1 != 0 && entry >= address && entry - address < size { executableEntry = true }
            }
            if type == 3 {
                try require(interpreter == nil && (2...256).contains(size), "Некорректный загрузчик ELF")
                let bytes = Data(data[Int(offset)..<Int(offset+size)])
                try require(bytes.last == 0, "Некорректный путь загрузчика ELF")
                guard let path = String(data: bytes.dropLast(), encoding: .utf8) else { throw IMEIError.message("Некорректная строка загрузчика ELF") }
                try require(path.range(of: #"^/lib(?:64)?/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil, "Неподдерживаемый путь загрузчика ELF")
                interpreter = path
            }
        }
        try require(executableEntry, "В ELF отсутствует исполняемая точка входа")
        return interpreter
    }
}
struct AgentInstallationStatus: Sendable {
    var hash = "absent"
    var running = false
    var startupReady = false
    var recoveryPending = false
    var backupHash: String?
    static func parse(_ text: String) throws -> Self {
        var value = Self(), seen = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            try require(seen.insert(fields[0]).inserted, "Повтор данных состояния агента")
            switch fields[0] {
            case "AGENT_SHA": value.hash = fields[1]
            case "AGENT_RUNNING": value.running = fields[1] == "yes"
            case "AGENT_STARTUP": value.startupReady = fields[1] == "yes"
            case "AGENT_PENDING": value.recoveryPending = fields[1] == "yes"
            case "AGENT_BACKUP": value.backupHash = fields[1]
            default: break
            }
        }
        func hash(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
        try require(seen.contains("AGENT_SHA") && (value.hash == "absent" || hash(value.hash)) && (value.backupHash.map(hash) ?? true), "Неверный ответ проверки агента")
        return value
    }
}
final class AgentInstallationManager {
    let engine: ModemEngine
    static let scriptHash = "fd76710b266669b34d251b7f06ac31ae1ee55a5d123f3dde8ca19f367cf3f289"
    init(engine: ModemEngine) { self.engine = engine }
    private func staged<T>(cleanupAllowed: () -> Bool = { true }, _ work: (String, Identity, String, String) throws -> T) throws -> T {
        try require(engine.lockFD >= 0, "Установка агента требует блокировки приложения")
        try require(!engine.fm.fileExists(atPath: engine.root.appendingPathComponent("adb-access-pending.json").path), "Сначала завершите включение ADB для диагностики")
        try require(!engine.fm.fileExists(atPath: engine.pendingURL.path) && !engine.fm.fileExists(atPath: engine.root.appendingPathComponent("setup-pending.json").path), "Сначала завершите текущую подготовку или смену IMEI")
        let script = try Data(contentsOf: engine.resources.appendingPathComponent("AgentInstallation/manager.sh"))
        try require(digest(script) == Self.scriptHash, "Повреждён установщик агента")
        let proof = try engine.measuredIdentity(); let identity = proof.identity, boot = proof.bootID, router = proof.routerHash
        try engine.acquireRemoteLock()
        let stage = "/tmp/zte-agent-stage-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer { if cleanupAllowed() { _ = try? engine.remote("rm -f " + shellQuote(stage + "/manager.sh") + " " + shellQuote(stage + "/agent.bin") + "; rmdir " + shellQuote(stage)) } }
        try upload(script, to: stage + "/manager.sh")
        return try work(stage, identity, boot, router)
    }
    private func upload(_ data: Data, to path: String) throws {
        let result = try engine.textResult("umask 077; cat > " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: data)
        try require(try FirmwareCheck.hash(result, path: path) == digest(data), "Контрольная сумма после передачи агента не совпала")
    }
    private func sameDevice(_ identity: Identity, _ boot: String, _ router: String) throws {
        let after = try engine.measuredIdentity()
        try require(after.identity == identity && after.bootID == boot && after.routerHash == router, "Модем изменился или перезагрузился во время подготовки агента")
    }
    private func status(_ stage: String) throws -> AgentInstallationStatus {
        try AgentInstallationStatus.parse(engine.text("sh " + shellQuote(stage + "/manager.sh") + " status"))
    }
    func inspect() throws -> AgentInstallationStatus {
        try staged { stage, _, _, _ in try status(stage) }
    }
    func install(_ candidate: AgentCandidate) throws -> AgentInstallationStatus {
        // Re-read and validate the exact file selected by the user before any device write.
        let fresh = try AgentCandidate.inspect(candidate.url)
        try require(fresh.sha256 == candidate.sha256 && fresh.bytes == candidate.bytes, "Выбранный файл изменился. Выберите его заново")
        let data = try Data(contentsOf: candidate.url)
        try require(digest(data) == candidate.sha256, "Файл изменился во время чтения")
        var cleanupSafe = true
        return try staged(cleanupAllowed: { cleanupSafe }) { stage, identity, boot, router in
            let before = try status(stage)
            try require(!before.recoveryPending, "Сначала восстановите предыдущий агент")
            try require(before.startupReady, "Сначала выполните автоматическую подготовку модема с паролем веб-интерфейса")
            try require(before.hash != "absent" || !before.running, "Агент работает из удалённого файла. Выполните подготовку модема для восстановления.")
            if let loader = candidate.interpreter { _ = try engine.remote("test -x " + shellQuote(loader)) }
            if before.hash == candidate.sha256 && before.running { return before }
            engine.update(before.hash == "absent" ? "Передаю выбранный агент для установки…" : "Передаю выбранный агент; затем будет создана резервная копия текущего…", 0.3)
            try upload(data, to: stage + "/agent.bin")
            try sameDevice(identity, boot, router)
            cleanupSafe = false
            let result = try engine.transport.run("sh " + shellQuote(stage + "/manager.sh") + " install " + shellQuote(stage + "/agent.bin") + " " + shellQuote(candidate.sha256), input: nil, timeout: 90)
            cleanupSafe = result.status >= 0 && result.status < 255
            try require(result.status == 0, "Замена агента не подтверждена (exit " + String(result.status) + "). Обновите состояние. При потере связи средства восстановления сохранены.")
            let after = try status(stage)
            try require(after.hash == candidate.sha256 && after.running && after.backupHash == (before.hash == "absent" ? nil : before.hash) && !after.recoveryPending, "Не удалось подтвердить замену агента; проверьте состояние и восстановление")
            engine.update(before.hash == "absent" ? "Агент установлен и процесс запущен." : "Агент заменён и процесс запущен. Предыдущий файл сохранён на модеме.", 1)
            return after
        }
    }
    /// Bundled installation also refreshes the matching web UI. Custom binaries
    /// keep their existing dashboard because API compatibility is not established.
    func installBundled(_ candidate: AgentCandidate) throws -> AgentInstallationStatus {
        try require(candidate.sha256 == BundledAgent.sha256, "Повреждён встроенный агент")
        let payload = try AgentDashboardPayload.load(engine.resources)
        // A bundled agent pins the installed VPN controller, which pins the
        // display library. Keep that existing chain compatible during updates.
        // This path does not configure Wi-Fi or enable a VPN.
        try require(engine.lockFD >= 0, "Установка агента требует блокировки приложения")
        try engine.acquireRemoteLock()
        if try inspect().hash == "absent" { _ = try install(candidate) }
        if try VPNSettingsManager(engine: engine).updateDisplayIntegrationIfNeeded() {
            let final = try inspect()
            try require(final.hash == candidate.sha256 && final.running && !final.recoveryPending,
                        "Агент после обновления компонентов требует проверки. Обновите состояние перед повтором.")
            return final
        }
        return try installDashboard(payload) { try install(candidate) }
    }
    private func installDashboard(_ payload: AgentDashboardPayload, installAgent: () throws -> AgentInstallationStatus) throws -> AgentInstallationStatus {
        try require(engine.lockFD >= 0, "Установка панели требует блокировки приложения")
        let proof = try engine.measuredIdentity(); let identity = proof.identity, boot = proof.bootID, router = proof.routerHash
        try engine.acquireRemoteLock()
        let stage = "/tmp/zte-dashboard-stage-" + UUID().uuidString.lowercased()
        // The helper receipt identifies its actual staging directory.
        let receiptID = String(stage.dropFirst("/tmp/zte-dashboard-stage-".count))
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        let cleanup = "rm -f " + AgentDashboardPayload.names.map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage)
        var cleanupSafe = true
        defer { if cleanupSafe { _ = try? engine.remote(cleanup, timeout: 15) } }
        for name in AgentDashboardPayload.names { try upload(payload.files[name]!, to: stage + "/" + name) }
        try sameDevice(identity, boot, router)
        let command = "sh " + [stage + "/dashboard.sh", stage, identity.cid, BundledAgent.sha256].map(shellQuote).joined(separator: " ")
        engine.update("Проверяю условия установки веб-панели до замены агента", 0.15)
        let preflight = try engine.transport.run(command + " preflight", input: nil, timeout: 45)
        try require(preflight.status == 0 && String(decoding: preflight.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "DASHBOARD_PREFLIGHT " + receiptID,
                    "Проверка веб-панели не пройдена. Замена агента не запускалась. Код: " + Self.dashboardCode(preflight))
        let installed = try installAgent()
        var dashboardOutcome = "DASHBOARD_PRE_APPLY_FAILED"
        do {
            try sameDevice(identity, boot, router)
            engine.update("Устанавливаю веб-панель с eSIM без изменения VPN", 0.95)
            // An interrupted SSH process may leave the remote rollback running.
            // Preserve its staging tools until a remote exit is known.
            cleanupSafe = false
            dashboardOutcome = "DASHBOARD_REMOTE_OUTCOME_UNKNOWN"
            let result = try engine.transport.run(command, input: nil, timeout: 120)
            cleanupSafe = result.status >= 0 && result.status < 255
            dashboardOutcome = Self.dashboardCode(result)
            try require(result.status == 0, "Код: " + Self.dashboardCode(result))
            let response = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            dashboardOutcome = "DASHBOARD_RECEIPT_INVALID"
            try require(response == "DASHBOARD_INSTALLED " + receiptID, "Код: DASHBOARD_RECEIPT_INVALID")
            dashboardOutcome = "DASHBOARD_TARGET_CHANGED"
            try sameDevice(identity, boot, router)
            engine.update("Агент с eSIM и веб-панель установлены", 1)
            return installed
        } catch {
            // The agent phase completed. Preserve that distinction in the UI;
            // the audited transport journal retains individual fixed failures.
            throw IMEIError.message("Агент проверен и запущен, но установка веб-панели не подтверждена. " + dashboardOutcome + ". Подробности — в журнале; обновите состояние перед повтором.")
        }
    }
    private static func dashboardCode(_ result: CommandResult) -> String {
        if result.status < 0 || result.status == 255 { return "SSH_CONNECTION_LOST" }
        // Never copy arbitrary stderr into this UI summary.
        let known = ["DASHBOARD_UNSAFE_PARENT", "DASHBOARD_LEGACY_LISTENER_UNVERIFIED", "DASHBOARD_BUSY", "DASHBOARD_RECOVERY_REQUIRED", "DASHBOARD_PREFLIGHT_FAILED", "DASHBOARD_AGENT_MISMATCH"]
        let fields = String(decoding: result.stderr, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        return known.first(where: fields.contains) ?? "DASHBOARD_EXIT_\(result.status)"
    }
    func restore() throws -> AgentInstallationStatus {
        var cleanupSafe = true
        return try staged(cleanupAllowed: { cleanupSafe }) { stage, identity, boot, router in
            let before = try status(stage)
            guard let expected = before.backupHash else { throw IMEIError.message("Проверенная копия предыдущего агента отсутствует") }
            try sameDevice(identity, boot, router)
            cleanupSafe = false
            let result = try engine.transport.run("sh " + shellQuote(stage + "/manager.sh") + " restore", input: nil, timeout: 90)
            cleanupSafe = result.status >= 0 && result.status < 255
            try require(result.status == 0, "Восстановление агента не подтверждено (exit " + String(result.status) + "). Обновите состояние. При потере связи средства восстановления сохранены.")
            let after = try status(stage)
            try require(after.hash == expected && after.running && !after.recoveryPending, "Восстановление агента не подтверждено")
            return after
        }
    }
}
private extension ModemEngine {
    func textResult(_ command: String, input: Data) throws -> String {
        String(decoding: try remote(command, input: input, timeout: 90), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
