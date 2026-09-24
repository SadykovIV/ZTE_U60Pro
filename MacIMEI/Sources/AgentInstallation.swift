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
    static let scriptHash = "d12154677e50567a311ca1d9f7d4f4019565e2e6f41cf7dc75d10d47fc8ef3a1"
    init(engine: ModemEngine) { self.engine = engine }
    private func staged<T>(_ work: (String, Identity, String) throws -> T) throws -> T {
        try require(engine.lockFD >= 0, "Установка агента требует блокировки приложения")
        try require(!engine.fm.fileExists(atPath: engine.pendingURL.path) && !engine.fm.fileExists(atPath: engine.root.appendingPathComponent("setup-pending.json").path), "Сначала завершите текущую подготовку или смену IMEI")
        let script = try Data(contentsOf: engine.resources.appendingPathComponent("AgentInstallation/manager.sh"))
        try require(digest(script) == Self.scriptHash, "Повреждён установщик агента")
        let (identity, boot) = try engine.identity()
        try engine.acquireRemoteLock()
        let stage = "/tmp/zte-agent-stage-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer { _ = try? engine.remote("rm -f " + shellQuote(stage + "/manager.sh") + " " + shellQuote(stage + "/agent.bin") + "; rmdir " + shellQuote(stage)) }
        try upload(script, to: stage + "/manager.sh")
        return try work(stage, identity, boot)
    }
    private func upload(_ data: Data, to path: String) throws {
        let result = try engine.textResult("umask 077; cat > " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: data)
        try require(try FirmwareCheck.hash(result, path: path) == digest(data), "Контрольная сумма после передачи агента не совпала")
    }
    private func sameDevice(_ identity: Identity, _ boot: String) throws {
        let after = try engine.identity()
        try require(after.0 == identity && after.1 == boot, "Модем изменился или перезагрузился во время подготовки агента")
    }
    private func status(_ stage: String) throws -> AgentInstallationStatus {
        try AgentInstallationStatus.parse(engine.text("sh " + shellQuote(stage + "/manager.sh") + " status"))
    }
    func inspect() throws -> AgentInstallationStatus {
        try staged { stage, _, _ in try status(stage) }
    }
    func install(_ candidate: AgentCandidate) throws -> AgentInstallationStatus {
        // Re-read and validate the exact file selected by the user before any device write.
        let fresh = try AgentCandidate.inspect(candidate.url)
        try require(fresh.sha256 == candidate.sha256 && fresh.bytes == candidate.bytes, "Выбранный файл изменился. Выберите его заново")
        let data = try Data(contentsOf: candidate.url)
        try require(digest(data) == candidate.sha256, "Файл изменился во время чтения")
        return try staged { stage, identity, boot in
            let before = try status(stage)
            try require(!before.recoveryPending, "Сначала восстановите предыдущий агент")
            try require(before.hash != "absent" && before.startupReady, "Сначала выполните автоматическую подготовку модема с паролем веб-интерфейса")
            if let loader = candidate.interpreter { _ = try engine.remote("test -x " + shellQuote(loader)) }
            if before.hash == candidate.sha256 && before.running { return before }
            engine.update("Передаю выбранный агент; затем будет создана резервная копия текущего…", 0.3)
            try upload(data, to: stage + "/agent.bin")
            try sameDevice(identity, boot)
            _ = try engine.remote("sh " + shellQuote(stage + "/manager.sh") + " install " + shellQuote(stage + "/agent.bin") + " " + shellQuote(candidate.sha256), timeout: 90)
            let after = try status(stage)
            try require(after.hash == candidate.sha256 && after.running && after.backupHash == before.hash && !after.recoveryPending, "Не удалось подтвердить замену агента; проверьте состояние и восстановление")
            engine.update("Агент заменён и процесс запущен. Предыдущий файл сохранён на модеме.", 1)
            return after
        }
    }
    func restore() throws -> AgentInstallationStatus {
        try staged { stage, identity, boot in
            let before = try status(stage)
            guard let expected = before.backupHash else { throw IMEIError.message("Проверенная копия предыдущего агента отсутствует") }
            try sameDevice(identity, boot)
            _ = try engine.remote("sh " + shellQuote(stage + "/manager.sh") + " restore", timeout: 90)
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
