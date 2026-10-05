import Foundation
import Darwin

struct ComponentCleanupResult: Sendable {
    var connection: Connection
    var identity: Identity
    var setupID: String
    var cancelled = false
}

/// Separate durable intent: a cleanup retry cannot replay setup/restore or rotate
/// credentials. Archives are private and are never included in diagnostic exports.
struct ComponentCleanupPlan: Codable {
    var schema = 1
    var id: String
    var cid: String
    var bootID: String
    var firmwareHash: String
    var routerHash: String
    var connection: Connection
    var setupReceipt: String
    var backupDirectory: String
    var phase = "prepared"
    var archiveSha: String?
    var archiveBytes: Int64?
    var identity: Identity { Identity(cid: cid, firmwareHash: firmwareHash) }
    var transaction: String { "/data/zte-imei-studio/cleanup-" + id }

    func validate(root: URL) throws {
        try require(schema == 1 && UUID(uuidString: id)?.uuidString.lowercased() == id &&
                    UUID(uuidString: bootID)?.uuidString.lowercased() == bootID &&
                    cid.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil &&
                    DeviceBackups.validHash(firmwareHash) && DeviceBackups.validHash(routerHash),
                    "Повреждён журнал чистой установки")
        try require(["prepared", "backup-verified", "clean-requested", "complete", "cancelled"].contains(phase), "Повреждён журнал чистой установки")
        try require(URL(fileURLWithPath: backupDirectory).standardizedFileURL.path == root.appendingPathComponent("ComponentBackups/" + id).standardizedFileURL.path,
                    "Некорректный путь резервной копии компонентов")
        let receipt = URL(fileURLWithPath: setupReceipt).standardizedFileURL
        try require(receipt.lastPathComponent == "setup-result.json" &&
                    receipt.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("SetupBackups").standardizedFileURL.path &&
                    UUID(uuidString: receipt.deletingLastPathComponent().lastPathComponent) != nil,
                    "Некорректный журнал завершённой подготовки")
        if archiveSha != nil || !["prepared", "cancelled"].contains(phase) {
            try require(archiveSha.map(DeviceBackups.validHash) == true && (archiveBytes ?? 0) > 0 && (archiveBytes ?? 0) <= DeviceBackups.maximumBytes,
                        "Не подтверждена локальная копия компонентов")
        }
        try connection.validate()
    }
}

final class ComponentCleanup {
    static func pendingURL(_ root: URL) -> URL { root.appendingPathComponent("component-cleanup-pending.json") }
    static func pendingURL(root: URL) -> URL { pendingURL(root) }
    static func hasPending(root: URL) -> Bool { var info = stat(); return lstat(pendingURL(root).path, &info) == 0 }
    static func acknowledge(root: URL, setupID: String) throws {
        let plan = try JSONDecoder().decode(ComponentCleanupPlan.self, from: DeviceBackups.smallFile(pendingURL(root), maximum: 65536))
        try plan.validate(root: root)
        try require(plan.id == setupID && ["complete", "cancelled"].contains(plan.phase), "Очистка компонентов ещё не подтверждена")
        if plan.phase == "cancelled" {
            try verifyCancellation(plan)
            try FileManager.default.removeItem(at: pendingURL(root)); return
        }
        let archive = try DeviceBackups.hashFile(URL(fileURLWithPath: plan.backupDirectory).appendingPathComponent("components.tar"))
        try require(archive.sha256 == plan.archiveSha && archive.bytes == plan.archiveBytes, "Копия компонентов повреждена")
        try FileManager.default.removeItem(at: pendingURL(root))
    }

    static func canCancel(root: URL) -> Bool {
        guard let data = try? DeviceBackups.smallFile(pendingURL(root), maximum: 65536),
              let plan = try? JSONDecoder().decode(ComponentCleanupPlan.self, from: data),
              (try? plan.validate(root: root)) != nil else { return false }
        return ["prepared", "backup-verified"].contains(plan.phase)
    }
    private static func verifyCancellation(_ plan: ComponentCleanupPlan) throws {
        let url = URL(fileURLWithPath: plan.backupDirectory).appendingPathComponent("cleanup-cancelled.json")
        let saved = try JSONDecoder().decode(ComponentCleanupPlan.self, from: DeviceBackups.smallFile(url, maximum: 65536))
        try require(saved.phase == "cancelled" && saved.id == plan.id && saved.cid == plan.cid && saved.bootID == plan.bootID &&
                    saved.firmwareHash == plan.firmwareHash && saved.routerHash == plan.routerHash && saved.backupDirectory == plan.backupDirectory,
                    "Отмена очистки компонентов не подтверждена")
    }

    static func schedule(root: URL, connection: Connection, setupID: String, setupDirectory: URL,
                         expectedIdentity: Identity, transport: RemoteTransport) throws {
        let response = try transport.run(AccessIdentity.command, input: nil, timeout: 20)
        try require(response.status == 0, "Не удалось подтвердить модем перед чистой установкой")
        let proof = try AccessIdentity.parse(response.stdout)
        try require(proof.identity == expectedIdentity, "Модем изменился перед чистой установкой")
        let plan = ComponentCleanupPlan(id: setupID, cid: proof.identity.cid, bootID: proof.bootID,
            firmwareHash: proof.identity.firmwareHash, routerHash: proof.routerHash, connection: connection,
            setupReceipt: setupDirectory.appendingPathComponent("setup-result.json").path,
            backupDirectory: root.appendingPathComponent("ComponentBackups/" + setupID).path)
        try plan.validate(root: root)
        if hasPending(root: root) {
            let previous = try readJSON(ComponentCleanupPlan.self, pendingURL(root))
            try previous.validate(root: root)
            try require(previous.id == plan.id && previous.identity == plan.identity && previous.bootID == plan.bootID &&
                        previous.routerHash == plan.routerHash && previous.connection.host == plan.connection.host && previous.connection.port == plan.connection.port && previous.connection.keyPath == plan.connection.keyPath && previous.connection.knownHostsPath == plan.connection.knownHostsPath && previous.setupReceipt == plan.setupReceipt,
                        "Другая чистая установка ещё не завершена")
        } else { try saveJSON(plan, pendingURL(root)) }
    }

    let root: URL, resources: URL, connection: Connection
    let sshFactory: ((Connection) -> RemoteTransport)?
    let streamer: BackupStreamTransport?
    let cancelled: @Sendable () -> Bool
    let update: @Sendable (String, Double) -> Void
    init(root: URL, resources: URL, connection: Connection,
         sshFactory: ((Connection) -> RemoteTransport)? = nil, streamer: BackupStreamTransport? = nil,
         cancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
         update: @escaping @Sendable (String, Double) -> Void = { _,_ in }) {
        self.root = root; self.resources = resources; self.connection = connection
        self.sshFactory = sshFactory; self.streamer = streamer; self.cancelled = cancelled; self.update = update
    }
    private func source() throws -> String {
        let folder = resources.appendingPathComponent("Onboarding")
        let hashes = try readJSON([String: String].self, folder.appendingPathComponent("SHA256.json"))
        let bytes = try Data(contentsOf: folder.appendingPathComponent("clean-components.sh"))
        try require(bytes.count <= 262_144 && hashes["clean-components.sh"] == digest(bytes), "Повреждён встроенный инструмент чистой установки")
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { throw IMEIError.message("Повреждён встроенный инструмент чистой установки") }
        return text
    }
    static func message(_ code: String) -> String {
        switch code {
        case "BUSY", "PENDING": return "Другая операция модема ещё не завершена. Чистая установка сохранена для продолжения."
        case "VPN_CONFIGURATION": return "Сначала выключите Wi-Fi с VPN. Если он уже выключен, настройки VPN отличаются от установленных программой; очистка остановлена."
        case "CHANGED", "IDENTITY": return "Состав компонентов или модем изменился. Очистка остановлена; копия и журнал сохранены."
        case "RECOVERY_REQUIRED", "STOP", "VPN_RESTORE": return "Очистка прервана. Резервная копия и удалённые компоненты сохранены для восстановления; повторная подготовка не запускается."
        default: return "Не удалось безопасно очистить компоненты. Резервная копия и журнал сохранены; чужие файлы не удаляются."
        }
    }
    private func validateRemainingSetup(_ plan: ComponentCleanupPlan) throws {
        let oldPending = root.appendingPathComponent("setup-pending.json")
        var info = stat()
        if lstat(oldPending.path, &info) == 0 {
            let data = try DeviceBackups.smallFile(oldPending, maximum: 65536)
            guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  saved["id"] as? String == plan.id, saved["phase"] as? String == "complete",
                  saved["cleanComponents"] as? Bool == true, saved["forceReinstall"] as? Bool == true else {
                throw IMEIError.message("Незавершённая подготовка не соответствует журналу очистки")
            }
        }
    }

    /// Before a clean dispatch, cancel only the host intent. The private remote
    /// snapshot remains available, and no service/configuration/component changes.
    func cancelBeforeDispatch() throws -> ComponentCleanupResult {
        try DeviceBackups.directory(root)
        let original = try DeviceBackups.smallFile(Self.pendingURL(root), maximum: 65536)
        var plan = try JSONDecoder().decode(ComponentCleanupPlan.self, from: original)
        try plan.validate(root: root)
        try validateRemainingSetup(plan)
        try require(connection.host == plan.connection.host, "Незавершённая чистая установка относится к другому адресу модема")
        if plan.phase == "cancelled" {
            try Self.verifyCancellation(plan)
            return .init(connection: plan.connection, identity: plan.identity, setupID: plan.id, cancelled: true)
        }
        try require(["prepared", "backup-verified"].contains(plan.phase), "Очистка уже запускалась; отмена до записи недоступна")
        let journal = try ActivityJournal(root: root)
        let ssh = AuditedRemoteTransport(base: sshFactory?(plan.connection) ?? SSHTransport(plan.connection), journal: journal,
                                        operationID: "clean-cancel-" + plan.id, endpoint: plan.connection.host + ":" + plan.connection.port)
        func bound() throws {
            try DeviceBackups.checkCancelled(cancelled)
            let answer = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(answer.status == 0, "Не удалось подтвердить модем перед отменой очистки")
            let proof = try AccessIdentity.parse(answer.stdout)
            try require(proof.identity == plan.identity && proof.routerHash == plan.routerHash && proof.bootID == plan.bootID,
                        "Модем изменился; журнал очистки сохранён")
        }
        let body = try source(), token = UUID().uuidString.lowercased()
        let args = ["status", plan.transaction, plan.id, plan.cid, plan.bootID, plan.firmwareHash, plan.routerHash, token]
        try bound()
        let reply = try ssh.run("sh -s -- " + args.map(shellQuote).joined(separator: " "), input: Data(body.utf8), timeout: 30)
        try require(reply.status == 0 && reply.stdout.count <= 512, "Состояние очистки неизвестно; журнал сохранён")
        let status = CommandText.decode(reply.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "CLEAN_ABSENT" || status == "CLEAN_INCOMPLETE" {
            try require(plan.phase == "prepared" && plan.archiveSha == nil, "Удалённая копия изменилась; журнал сохранён")
        } else {
            let fields = status.split(separator: " ")
            try require(fields.count == 3 && fields[0] == "CLEAN_PREPARED" && DeviceBackups.validHash(String(fields[1])), "Очистка уже запускалась или её состояние неизвестно")
            guard let count = Int64(fields[2]), count > 0 && count <= DeviceBackups.maximumBytes else { throw IMEIError.message("Не подтверждена копия компонентов") }
            if let sha = plan.archiveSha { try require(sha == String(fields[1]) && plan.archiveBytes == count, "Удалённая копия изменилась; журнал сохранён") }
        }
        try bound()
        let directory = URL(fileURLWithPath: plan.backupDirectory)
        try DeviceBackups.directory(root.appendingPathComponent("ComponentBackups"), create: true)
        try DeviceBackups.directory(directory, create: true)
        try savePrivate(original, directory.appendingPathComponent("cleanup-before-cancel.json"))
        plan.phase = "cancelled"
        try saveJSON(plan, directory.appendingPathComponent("cleanup-cancelled.json"))
        try saveJSON(plan, Self.pendingURL(root))
        let note = "Очистка отменена до изменения компонентов. Созданные копии и журнал сохранены."
        update(note, 1)
        do { try journal.record(operationID: "clean-cancel-" + plan.id, category: "cleanup", title: note, result: "completed", details: [:]) }
        catch { journal.markIncomplete("clean-cancel-" + plan.id) }
        return .init(connection: plan.connection, identity: plan.identity, setupID: plan.id, cancelled: true)
    }

    func run() throws -> ComponentCleanupResult {
        try DeviceBackups.directory(root)
        var plan = try JSONDecoder().decode(ComponentCleanupPlan.self, from: DeviceBackups.smallFile(Self.pendingURL(root), maximum: 65536))
        try plan.validate(root: root)
        try validateRemainingSetup(plan)
        try require(connection.host == plan.connection.host, "Незавершённая чистая установка относится к другому адресу модема")
        if plan.phase == "cancelled" {
            try Self.verifyCancellation(plan)
            return .init(connection: plan.connection, identity: plan.identity, setupID: plan.id, cancelled: true)
        }
        let journal = try ActivityJournal(root: root)
        let operationID = "clean-" + plan.id
        let ssh = AuditedRemoteTransport(base: sshFactory?(plan.connection) ?? SSHTransport(plan.connection), journal: journal, operationID: operationID, endpoint: plan.connection.host + ":" + plan.connection.port)
        func progress(_ message: String, _ value: Double) {
            update(message, value)
            do { try journal.record(operationID: operationID, category: "cleanup", title: message, result: value >= 1 ? "completed" : "progress", details: ["progress": String(value)]) }
            catch { journal.markIncomplete(operationID) }
        }
        let body = try source(), token = UUID().uuidString.lowercased()
        func bound() throws {
            try DeviceBackups.checkCancelled(cancelled)
            let reply = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(reply.status == 0, "Не удалось подтвердить модем перед очисткой")
            let proof = try AccessIdentity.parse(reply.stdout)
            try require(proof.identity == plan.identity && proof.bootID == plan.bootID && proof.routerHash == plan.routerHash,
                        "Модем или его загрузка изменились; журнал чистой установки сохранён")
        }
        func command(_ action: String, _ hash: String? = nil) -> String {
            let args = [action, plan.transaction, plan.id, plan.cid, plan.bootID, plan.firmwareHash, plan.routerHash, token] + (hash.map { [$0] } ?? [])
            return "sh -s -- " + args.map(shellQuote).joined(separator: " ")
        }
        func invoke(_ action: String, hash: String? = nil) throws -> String {
            try bound()
            let reply = try ssh.run(command(action, hash), input: Data(body.utf8), timeout: action == "prepare" ? 300 : action == "clean" ? 180 : 30)
            if reply.status != 0 {
                let lines = CommandText.decode(reply.stderr).split(separator: "\n")
                let code = lines.first(where: { $0.hasPrefix("CLEAN_ERROR ") }).map { String($0.dropFirst(12)) } ?? ""
                throw IMEIError.message(Self.message(code))
            }
            try bound()
            return CommandText.decode(reply.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        progress("Проверяю компоненты перед чистой установкой…", 0.90)
        var status = try invoke("status")
        if status == "CLEAN_ABSENT" || status == "CLEAN_INCOMPLETE" {
            try require(plan.phase == "prepared" && plan.archiveSha == nil, "Удалённый журнал очистки изменился; автоматическое продолжение остановлено")
            status = try invoke("prepare")
        }
        try require(plan.phase != "complete" || status == "CLEAN_COMPLETE", "Удалённое завершение очистки больше не подтверждено")
        var complete = status == "CLEAN_COMPLETE"
        try require(!complete || ["clean-requested", "complete"].contains(plan.phase), "Удалённое завершение не соответствует сохранённой операции")
        let directory = URL(fileURLWithPath: plan.backupDirectory)
        try DeviceBackups.directory(root.appendingPathComponent("ComponentBackups"), create: true)
        try DeviceBackups.directory(directory, create: true)
        if !complete {
            let fields = status.split(separator: " ")
            try require(fields.count == 3 && ["CLEAN_PREPARED", "CLEAN_PENDING"].contains(String(fields[0])) && DeviceBackups.validHash(String(fields[1])), "Неверное подтверждение копии компонентов")
            guard let count = Int64(fields[2]), count > 0, count <= DeviceBackups.maximumBytes else { throw IMEIError.message("Недопустимый размер копии компонентов") }
            try require(fields[0] != "CLEAN_PENDING" || plan.phase == "clean-requested", "Удалённая очистка не соответствует сохранённой операции")
            let expectedHash = String(fields[1])
            if plan.phase != "prepared" { try require(plan.archiveSha == expectedHash && plan.archiveBytes == count, "Удалённая копия компонентов изменилась") }
            let archive = directory.appendingPathComponent("components.tar")
            if FileManager.default.fileExists(atPath: archive.path) {
                let existing = try DeviceBackups.hashFile(archive, cancelled: cancelled)
                try require(existing.sha256 == expectedHash && existing.bytes == count, "Локальная копия компонентов повреждена; очистка не запускалась")
            } else {
                try require(try DeviceBackups.freeBytes(at: directory) >= count + DeviceBackups.reserveBytes, "Недостаточно места для копии компонентов")
                let partial = directory.appendingPathComponent(".partial-" + UUID().uuidString.lowercased())
                let receiver = streamer ?? SSHBackupStreamTransport(plan.connection)
                try bound()
                progress("Сохраняю резервную копию компонентов на компьютер…", 0.92)
                let result = try receiver.stream(command("stream"), input: Data(body.utf8), to: partial, maxBytes: count, timeout: 600, cancelled: cancelled)
                try require(result.sha256 == expectedHash && result.bytes == count, "Контрольная сумма копии компонентов не совпала; очистка не запускалась")
                let actual = try DeviceBackups.hashFile(partial, cancelled: cancelled)
                try require(actual.sha256 == expectedHash && actual.bytes == count, "Копия компонентов не прошла локальную проверку")
                try bound()
                try FileManager.default.moveItem(at: partial, to: archive)
            }
            progress("Резервная копия компонентов проверена: " + directory.path, 0.95)
            plan.archiveSha = expectedHash; plan.archiveBytes = count; plan.phase = "backup-verified"
            try saveJSON(plan, directory.appendingPathComponent("backup-receipt.json"))
            try saveJSON(plan, Self.pendingURL(root))
            plan.phase = "clean-requested"; try saveJSON(plan, Self.pendingURL(root))
            progress("Очищаю подтверждённые компоненты программы…", 0.97)
            complete = try invoke("clean", hash: expectedHash) == "CLEAN_COMPLETE"
        }
        try require(complete && plan.archiveSha != nil && plan.archiveBytes != nil, "Не подтверждено завершение чистой установки")
        let checked = try DeviceBackups.hashFile(directory.appendingPathComponent("components.tar"), cancelled: cancelled)
        try require(checked.sha256 == plan.archiveSha && checked.bytes == plan.archiveBytes, "Не подтверждена локальная копия завершённой очистки")
        plan.phase = "complete"
        try saveJSON(plan, directory.appendingPathComponent("cleanup-result.json"))
        try saveJSON(plan, Self.pendingURL(root))
        progress("Чистая установка завершена. Копия компонентов: " + directory.path, 1)
        return .init(connection: plan.connection, identity: plan.identity, setupID: plan.id)
    }
}
