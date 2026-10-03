import Foundation
import Darwin

/// An observation for diagnostics, never a firmware write permission.
struct DiagnosticDeviceProof: Equatable {
    var identity: Identity
    var routerHash: String
    var bootID: String
    var webIdentity: WebIdentity?
}
struct DiagnosticDeviceExpectation {
    var cids = Set<String>()
    var imeis = Set<String>()
    var requiresWeb: Bool { !imeis.isEmpty }
    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    static func load(root: URL, identity: Identity?, web: WebIdentity?, imei: String? = nil) throws -> Self {
        var result = Self()
        if let identity { result.cids.insert(identity.cid) }
        if let web { result.imeis.insert(web.imei) }
        if let imei { result.imeis.insert(imei) }
        for name in ["setup-pending.json", "adb-access-pending.json", "pending.json"] {
            guard exists(root.appendingPathComponent(name)) else { continue }
            let (data, truncated) = try DiagnosticArchive.readRegular(root: root, relative: name, limit: 1_048_576)
            try require(!truncated, "Сохранённая идентификация устройства слишком велика")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IMEIError.message("Повреждена сохранённая идентификация устройства") }
            let saved = object["identity"] as? [String: Any] ?? [:]
            try require(object["cid"] is String || saved["cid"] is String || saved["imei"] is String, "В сохранённой операции отсутствует идентификация устройства")
            if let cid = object["cid"] as? String ?? saved["cid"] as? String { result.cids.insert(cid) }
            if let imei = saved["imei"] as? String { result.imeis.insert(imei) }
        }
        let systemPending = "system-restore-pending.json"
        if exists(root.appendingPathComponent(systemPending)) {
            let (data, truncated) = try DiagnosticArchive.readRegular(root: root, relative: systemPending, limit: 4096)
            let pointer = try JSONDecoder().decode([String: String].self, from: data)
            guard !truncated, let id = pointer["id"], SystemBackups.validID(id) else { throw IMEIError.message("Повреждена сохранённая идентификация восстановления") }
            let (journal, clipped) = try DiagnosticArchive.readRegular(root: root, relative: "SystemRestoreTransactions/" + id + ".json", limit: 2_097_152)
            guard !clipped, let object = try JSONSerialization.jsonObject(with: journal) as? [String: Any], let inventory = object["inventory"] as? [String: Any], let cid = inventory["cid"] as? String else { throw IMEIError.message("Нет идентификации незавершённого восстановления") }
            result.cids.insert(cid)
        }
        try require(result.cids.count <= 1 && result.imeis.count <= 1, "Сохранённые сведения относятся к разным модемам; автоматический выбор диагностики остановлен")
        for cid in result.cids { try require(cid.count == 32 && cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Некорректный сохранённый CID") }
        for imei in result.imeis { try require(IMEI.valid(imei), "Некорректная сохранённая идентификация модема") }
        return result
    }
    func matches(_ proof: DiagnosticDeviceProof) -> Bool {
        (cids.isEmpty || cids.contains(proof.identity.cid)) && (imeis.isEmpty || proof.webIdentity.map { imeis.contains($0.imei) } == true)
    }
}

final class DiagnosticSession {
    let transport: String
    let selectionReason: String
    let proof: DiagnosticDeviceProof
    private let readIdentity: () throws -> DiagnosticDeviceProof
    private let execute: (String, TimeInterval) throws -> CommandResult
    init(transport: String, reason: String, proof: DiagnosticDeviceProof,
         readIdentity: @escaping () throws -> DiagnosticDeviceProof,
         execute: @escaping (String, TimeInterval) throws -> CommandResult) {
        self.transport = transport; self.selectionReason = reason; self.proof = proof
        self.readIdentity = readIdentity; self.execute = execute
    }
    func verify() throws {
        try require(try readIdentity() == proof, "Устройство, прошивка или сеанс загрузки изменились; дальнейшее чтение остановлено")
    }
    func run(_ command: String, timeout: TimeInterval) throws -> CommandResult {
        try verify()
        let result = try execute(command, timeout)
        try verify() // Never accept a section from a replaced USB device or reboot.
        return result
    }
}

enum DiagnosticTransportSelector {
    static let identityCommand = "set -e; test \"$(id -u)\" = 0; test \"$(uname -m)\" = aarch64; sha256sum /firmware/image/modem.b16 /usr/bin/diag-router; cat /sys/block/mmcblk0/device/cid /proc/sys/kernel/random/boot_id"
    static func identityCommand(requireWeb: Bool) -> String {
        identityCommand + (requireWeb ? "; ubus call zwrt_web device_info '{}'" : "")
    }
    static func parseIdentity(_ data: Data, requireWeb: Bool) throws -> DiagnosticDeviceProof {
        try require(data.count <= 65536, "Слишком большой ответ идентификации диагностики")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        try require(lines.count >= 4 && (requireWeb || lines.count == 4), "Неполная идентификация модема")
        let firmware = try FirmwareCheck.hash(lines[0], path: "/firmware/image/modem.b16")
        let router = try FirmwareCheck.hash(lines[1], path: "/usr/bin/diag-router")
        let cid = lines[2], boot = lines[3]
        try require(cid.count == 32 && cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && UUID(uuidString: boot) != nil, "Неверные CID или boot ID диагностики")
        var web: WebIdentity?
        if requireWeb {
            guard let object = try JSONSerialization.jsonObject(with: Data(lines.dropFirst(4).joined(separator: "\n").utf8)) as? [String: Any] else { throw IMEIError.message("Нет идентификации веб-устройства через выбранный транспорт") }
            web = try WebIdentity(object, skipFirmwareCheck: true)
        }
        return DiagnosticDeviceProof(identity: Identity(cid: cid, firmwareHash: firmware), routerHash: router, bootID: boot, webIdentity: web)
    }
    static func hostTrustFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("host key verification failed") || lower.contains("remote host identification has changed") || lower.contains("offending") && lower.contains("key")
    }
    static func usbSerials(_ data: Data) throws -> [String] {
        try ADBDiscovery.parse(data).readyUSBSerials
    }
    static func bundledADB(_ engine: ModemEngine) throws -> ADBClient {
        let directory = engine.resources.appendingPathComponent("Onboarding")
        let hashes = try readJSON([String: String].self, directory.appendingPathComponent("SHA256.json"))
        let path = directory.appendingPathComponent("adb")
        try require(hashes["adb"] == digest(Data(contentsOf: path)), "Повреждён встроенный ADB; диагностика USB остановлена")
        let journal = try ActivityJournal(root: engine.root)
        return ADBClient(binary: path, runner: AuditedHostRunner(base: HostProcessRunner(), journal: journal, operationID: engine.logDirectory.lastPathComponent))
    }
    static func select(engine: ModemEngine, expected: DiagnosticDeviceExpectation, adb supplied: ADBClient? = nil) throws -> DiagnosticSession {
        let command = identityCommand(requireWeb: expected.requiresWeb)
        var sshFailure = ""
        let first: CommandResult?
        do { first = try engine.transport.run(command, input: nil, timeout: 15) }
        catch {
            let partial = (error as? CommandFailure).map { String(decoding: $0.partial.stderr + $0.partial.stdout, as: UTF8.self) } ?? ""
            if hostTrustFailure(error.localizedDescription + partial) { throw IMEIError.message("Проверка ключа SSH не пройдена. Автоматический переход на другой транспорт остановлен.") }
            sshFailure = ActivityJournal.sanitize(error.localizedDescription)
            first = nil
        }
        if let first, first.status == 0 {
            let proof = try parseIdentity(first.stdout, requireWeb: expected.requiresWeb)
            try require(expected.matches(proof), "SSH подключён к другому модему; автоматический переход на USB остановлен")
            let read: () throws -> DiagnosticDeviceProof = {
                let response = try engine.transport.run(command, input: nil, timeout: 15)
                try require(response.status == 0, "Соединение SSH потеряно при проверке устройства: " + ActivityJournal.sanitize(String(decoding: response.stderr, as: UTF8.self)))
                return try parseIdentity(response.stdout, requireWeb: expected.requiresWeb)
            }
            return DiagnosticSession(transport: "ssh", reason: "Выбран SSH с проверенным ключом сервера и прочитанной идентификацией модема.", proof: proof, readIdentity: read) { command, timeout in
                let result = try engine.transport.run(command, input: nil, timeout: timeout)
                try require(result.status != 255, "Ошибка подключения SSH: " + ActivityJournal.sanitize(String(decoding: result.stderr, as: UTF8.self)))
                return result
            }
        }
        if let first {
            let detail = String(decoding: first.stderr + first.stdout, as: UTF8.self)
            try require(!hostTrustFailure(detail), "Проверка ключа SSH не пройдена. Автоматический переход на другой транспорт остановлен.")
            // A responding shell with invalid identity is not an unavailable connection.
            try require(first.status == 255 || first.status == -1, "SSH отвечает, но идентификация недоступна; автоматический выбор другого устройства остановлен")
            sshFailure = "SSH недоступен (код \(first.status)): " + ActivityJournal.sanitize(detail)
        }
        let adb = try supplied ?? bundledADB(engine)
        let discovery = try adb.discovery(), serials = discovery.readyUSBSerials
        try require(!serials.isEmpty, "SSH недоступен. " + discovery.explanation + " ADB автоматически не включается. " + String(sshFailure.prefix(600)))
        try require(serials.count == 1 || !expected.cids.isEmpty || !expected.imeis.isEmpty, "Подключено несколько USB ADB устройств, а ожидаемый модем неизвестен; выбор первого запрещён")
        var matches: [(String, DiagnosticDeviceProof)] = []
        for serial in serials {
            do {
                let result = try adb.shellResult(serial, command, timeout: 20)
                guard result.status == 0 else { continue }
                let proof = try parseIdentity(result.stdout, requireWeb: expected.requiresWeb)
                if expected.matches(proof) { matches.append((serial, proof)) }
            } catch { continue }
        }
        try require(matches.count == 1, matches.isEmpty ? "USB ADB не подтвердил ожидаемый модем и его идентификацию" : "Несколько USB ADB устройств совпали с ожидаемым модемом; выбор неоднозначен")
        let (serial, proof) = matches[0]
        let read: () throws -> DiagnosticDeviceProof = {
            let serials = try adb.discovery().readyUSBSerials
            try require(serials.contains(serial), "Выбранное USB ADB устройство отключено")
            let result = try adb.shellResult(serial, command, timeout: 20)
            try require(result.status == 0, "Не удалось повторно прочитать идентификацию USB ADB")
            return try parseIdentity(result.stdout, requireWeb: expected.requiresWeb)
        }
        let bound = !expected.cids.isEmpty || !expected.imeis.isEmpty
        let reason = bound ? "SSH недоступен; USB ADB выбран по сохранённой идентификации модема." : "SSH недоступен; выбран единственный USB ADB модем. Совпадение с настроенным IP-адресом не установлено."
        return DiagnosticSession(transport: "adb", reason: reason + " " + String(sshFailure.prefix(600)), proof: proof, readIdentity: read) { command, timeout in
            try adb.shellResult(serial, command, timeout: timeout)
        }
    }
}
