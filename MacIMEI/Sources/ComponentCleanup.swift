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
    // The original boot remains the immutable transaction/setup owner identity.
    var acceptedBootID: String?
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
    var effectiveBootID: String { acceptedBootID ?? bootID }

    func validate(root: URL) throws {
        try require(schema == 1 && UUID(uuidString: id)?.uuidString.lowercased() == id &&
                    UUID(uuidString: bootID)?.uuidString.lowercased() == bootID &&
                    cid.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil &&
                    (firmwareHash == "absent" || DeviceBackups.validHash(firmwareHash)) && (routerHash == "absent" || DeviceBackups.validHash(routerHash)),
                    "Повреждён журнал чистой установки")
        try require(["prepared", "backup-verified", "clean-requested", "complete", "cancelled"].contains(phase), "Повреждён журнал чистой установки")
        try require(acceptedBootID == nil || UUID(uuidString: acceptedBootID!)?.uuidString.lowercased() == acceptedBootID, "Повреждён журнал чистой установки")
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
    static func undispatchedRecoveryPlan(root: URL) throws -> ComponentCleanupPlan? {
        guard hasPending(root: root) else { return nil }
        let plan = try JSONDecoder().decode(ComponentCleanupPlan.self, from: DeviceBackups.smallFile(pendingURL(root), maximum: 65536))
        try plan.validate(root: root)
        return ["prepared", "backup-verified"].contains(plan.phase) ? plan : nil
    }

    /// The caller holds the operation lock and supplies fresh, repeated USB
    /// identity proof. Retiring an undispatched intent changes host metadata only.
    static func archiveUndispatchedAfterReboot(root: URL, connection: Connection, proof: DiagnosticDeviceProof) throws -> Bool {
        guard hasPending(root: root) else { return false }
        let original = try DeviceBackups.smallFile(pendingURL(root), maximum: 65536)
        let plan = try JSONDecoder().decode(ComponentCleanupPlan.self, from: original)
        try plan.validate(root: root)
        guard ["prepared", "backup-verified"].contains(plan.phase) else { return false }
        try require(connection.host == plan.connection.host && proof.identity == plan.identity && proof.routerHash == plan.routerHash &&
                    UUID(uuidString: proof.bootID)?.uuidString.lowercased() == proof.bootID,
                    "После перезагрузки обнаружено другое устройство или прошивка; журнал очистки сохранён")
        guard proof.bootID != plan.effectiveBootID else { return false }
        try validateRemainingSetup(plan, root: root)
        let directory = URL(fileURLWithPath: plan.backupDirectory)
        if let sha = plan.archiveSha {
            let archive = try DeviceBackups.hashFile(directory.appendingPathComponent("components.tar"))
            try require(archive.sha256 == sha && archive.bytes == plan.archiveBytes, "Копия компонентов повреждена; журнал очистки сохранён")
        }
        try DeviceBackups.directory(root.appendingPathComponent("ComponentBackups"), create: true)
        try DeviceBackups.directory(directory, create: true)
        try require(try DeviceBackups.smallFile(pendingURL(root), maximum: 65536) == original, "Журнал очистки изменился; он сохранён для проверки")
        try FileManager.default.moveItem(at: pendingURL(root), to: directory.appendingPathComponent("cleanup-before-reset-" + UUID().uuidString.lowercased() + ".json"))
        return true
    }

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
        try require(saved.phase == "cancelled" && saved.id == plan.id && saved.cid == plan.cid && saved.bootID == plan.bootID && saved.acceptedBootID == plan.acceptedBootID &&
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
    static let errorCodes: Set<String> = [
        "ARCHIVE", "BACKUP_NOT_VERIFIED", "BUSY", "CHANGED", "IDENTITY", "LAYOUT", "MOUNT", "OWNER", "PATH", "PENDING",
        "PLATFORM", "PROCESS", "RECOVERY_REQUIRED", "SERVICE", "SNAPSHOT", "STARTUP", "STOP", "SYMLINK", "TRANSACTION",
        "VPN_BACKUP", "VPN_CONFIGURATION", "VPN_INTEGRITY", "VPN_NETWORK", "VPN_RESTORE",
        "PENDING_AGENT", "PENDING_FOREIGN", "PENDING_LIVE", "PENDING_OWNER", "IKE_RESTORE", "VPN_PLAN", "WRITE",
        "CLEAN", "LOCK", "MOVE", "PLAN", "PREPARE", "RESTORE"
    ]
    struct ReplyFailure: LocalizedError {
        let action: String, code: String
        var outcomeUnknown = false
        var errorDescription: String? { ComponentCleanup.message(code, action: action) }
    }
    static func message(_ code: String, action: String = "clean") -> String {
        let safeCode = errorCodes.contains(code) || ["TRANSPORT", "TIMEOUT", "PROTOCOL"].contains(code) ? code : "REMOTE_FAILURE"
        let stage = action == "status" ? "проверка состояния" : action == "prepare" ? "подготовка копии" : action == "stream" ? "сохранение копии" : action == "rebind" ? "подтверждение новой загрузки" : "очистка"
        let reason: String
        switch safeCode {
        case "BUSY", "PENDING", "PENDING_FOREIGN", "PENDING_LIVE", "LOCK": reason = "Другая операция модема ещё не завершена."
        case "SERVICE", "VPN_INTEGRITY", "STARTUP": reason = "Не подтверждена установленная версия компонентов или их запуска."
        case "VPN_CONFIGURATION", "VPN_NETWORK", "VPN_PLAN": reason = "Настройки VPN не соответствуют подтверждённой установке."
        case "VPN_BACKUP", "ARCHIVE", "BACKUP_NOT_VERIFIED", "SNAPSHOT": reason = "Не подтверждена резервная копия компонентов."
        case "CHANGED", "IDENTITY": reason = "Состав компонентов или модем изменился."
        case "LAYOUT", "MOUNT", "OWNER", "PATH", "SYMLINK": reason = "Не подтверждены расположение или принадлежность файлов компонентов."
        case "PLATFORM": reason = "Не подтверждены необходимые возможности прошивки."
        case "PROCESS", "STOP": reason = "Не подтверждена остановка процессов компонентов."
        case "RECOVERY_REQUIRED", "TRANSACTION", "VPN_RESTORE", "IKE_RESTORE", "PENDING_AGENT", "PENDING_OWNER": reason = "Не завершено восстановление сохранённой операции."
        case "CLEAN", "MOVE", "PLAN", "PREPARE", "RESTORE", "WRITE": reason = "Инструмент очистки прервался на сохранённом этапе."
        case "TRANSPORT": reason = "SSH не подтвердил результат команды. Проверьте подключение к модему."
        case "TIMEOUT": reason = "Истекло время ожидания ответа модема."
        case "PROTOCOL": reason = "Ответ инструмента очистки имеет неподтверждённый формат."
        default: reason = "Инструмент очистки завершился без подтверждённого кода причины."
        }
        let retry = ["BUSY", "PENDING", "PENDING_FOREIGN", "PENDING_LIVE", "LOCK", "STOP", "PROCESS", "VPN_RESTORE", "IKE_RESTORE", "CLEAN", "MOVE", "PLAN", "PREPARE", "RESTORE", "WRITE", "TRANSPORT", "TIMEOUT", "PROTOCOL", "REMOTE_FAILURE"].contains(safeCode)
        let next = retry ? "Журнал сохранён; продолжите чистую установку для проверки состояния." : "Журнал сохранён. Сохраните диагностический отчёт с этим кодом."
        return "Чистая установка: \(stage) [\(safeCode)]. \(reason) \(next)"
    }
    static func parseReply(_ reply: CommandResult, action: String) throws -> String {
        if reply.status != 0 {
            if reply.status < 0 || reply.status > 254 { throw ReplyFailure(action: action, code: "TRANSPORT", outcomeUnknown: true) }
            let text = reply.stderr.count <= 4096 ? String(data: reply.stderr, encoding: .utf8) : nil
            let codes = text?.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").filter { $0.hasPrefix("CLEAN_ERROR ") } ?? []
            let code = codes.count == 1 ? String(codes[0].dropFirst(12)) : ""
            throw ReplyFailure(action: action, code: errorCodes.contains(code) ? code : "REMOTE_FAILURE")
        }
        var text = reply.stdout.count <= 512 ? String(data: reply.stdout, encoding: .utf8) ?? "" : ""
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        var valid = action != "rebind" && text == "CLEAN_COMPLETE"
        if action == "rebind", text.range(of: #"\ACLEAN_REBOUND [0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12} (none|[0-9a-f]{64}) (0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil {
            let fields = text.split(separator: " ")
            valid = Int64(fields[3]).map { $0 <= DeviceBackups.maximumBytes && (fields[2] == "none" ? $0 == 0 : $0 > 0) } == true
        }
        if action == "status" && ["CLEAN_ABSENT", "CLEAN_INCOMPLETE"].contains(text) { valid = true }
        if ["status", "prepare"].contains(action), text.range(of: #"\ACLEAN_(PREPARED|PENDING) [0-9a-f]{64} [1-9][0-9]*\z"#, options: .regularExpression) != nil {
            let fields = text.split(separator: " ")
            valid = (action == "status" || fields[0] == "CLEAN_PREPARED") && Int64(fields[2]).map { $0 <= DeviceBackups.maximumBytes } == true
        }
        guard valid else { throw ReplyFailure(action: action, code: "PROTOCOL", outcomeUnknown: true) }
        return text
    }
    static func streamFailureMessage(_ status: Int32, _ diagnostic: Data) -> String {
        do { _ = try parseReply(.init(status: status, stdout: Data(), stderr: diagnostic), action: "stream") }
        catch let failure as ReplyFailure { return failure.localizedDescription }
        catch { }
        return message("PROTOCOL", action: "stream")
    }
    private static func invoke(_ ssh: RemoteTransport, command: String, body: String, action: String) throws -> String {
        do {
            let reply = try ssh.run(command, input: Data(body.utf8), timeout: ["prepare", "status", "rebind"].contains(action) ? 300 : 180)
            return try parseReply(reply, action: action)
        } catch let failure as CommandFailure {
            throw ReplyFailure(action: action, code: failure.partial.status == -1 ? "TIMEOUT" : "TRANSPORT", outcomeUnknown: true)
        }
    }
    private static func validateRemainingSetup(_ plan: ComponentCleanupPlan, root: URL) throws {
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
        try Self.validateRemainingSetup(plan, root: root)
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
            try require(proof.identity == plan.identity && proof.routerHash == plan.routerHash && proof.bootID == plan.effectiveBootID,
                        "Модем изменился; журнал очистки сохранён")
        }
        let body = try source()
        let args = ["status", plan.transaction, plan.id, plan.cid, plan.bootID, plan.firmwareHash, plan.routerHash, UUID().uuidString.lowercased()]
        try bound()
        let status = try Self.invoke(ssh, command: "sh -s -- " + args.map(shellQuote).joined(separator: " "), body: body, action: "status")
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
        try Self.validateRemainingSetup(plan, root: root)
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
        let body = try source()
        func bound() throws {
            try DeviceBackups.checkCancelled(cancelled)
            let reply = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(reply.status == 0, "Не удалось подтвердить модем перед очисткой")
            let proof = try AccessIdentity.parse(reply.stdout)
            try require(proof.identity == plan.identity && proof.bootID == plan.effectiveBootID && proof.routerHash == plan.routerHash,
                        "Модем или его загрузка изменились; журнал чистой установки сохранён")
        }
        func command(_ action: String, _ hash: String? = nil) -> String {
            // A new token lets the helper prove an earlier lock owner is gone;
            // reusing it in this argv would make a stale lock appear live.
            let args = [action, plan.transaction, plan.id, plan.cid, plan.bootID, plan.firmwareHash, plan.routerHash, UUID().uuidString.lowercased()] + (hash.map { [$0] } ?? [])
            return "sh -s -- " + args.map(shellQuote).joined(separator: " ")
        }
        try DeviceBackups.checkCancelled(cancelled)
        let initial = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
        try require(initial.status == 0, "Не удалось подтвердить модем перед очисткой")
        let observed = try AccessIdentity.parse(initial.stdout)
        try require(observed.identity == plan.identity && observed.routerHash == plan.routerHash, "Модем или его загрузка изменились; журнал чистой установки сохранён")
        if observed.bootID != plan.effectiveBootID {
            if let sha = plan.archiveSha {
                let archive = try DeviceBackups.hashFile(URL(fileURLWithPath: plan.backupDirectory).appendingPathComponent("components.tar"), cancelled: cancelled)
                try require(archive.sha256 == sha && archive.bytes == plan.archiveBytes, "Не подтверждена локальная копия завершённой очистки")
            }
            progress("Подтверждаю продолжение чистой установки после перезагрузки…", 0.89)
            let receipt = try Self.invoke(ssh, command: command("rebind", plan.archiveSha ?? "none") + " " + shellQuote(observed.bootID), body: body, action: "rebind")
            let fields = receipt.split(separator: " ")
            try require(fields[1] == observed.bootID && (plan.archiveSha == nil || (String(fields[2]) == plan.archiveSha && Int64(fields[3]) == plan.archiveBytes)), "Удалённый журнал очистки изменился; автоматическое продолжение остановлено")
            try DeviceBackups.checkCancelled(cancelled)
            let repeated = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(repeated.status == 0, "Не удалось подтвердить модем перед очисткой")
            let confirmed = try AccessIdentity.parse(repeated.stdout)
            try require(confirmed.identity == observed.identity && confirmed.routerHash == observed.routerHash && confirmed.bootID == observed.bootID, "Модем или его загрузка изменились; журнал чистой установки сохранён")
            // Save only after the durable remote receipt and repeated proof.
            // Lost responses can repeat this metadata step without replaying clean.
            plan.acceptedBootID = observed.bootID
            try saveJSON(plan, Self.pendingURL(root))
        }
        func invoke(_ action: String, hash: String? = nil) throws -> String {
            try bound()
            let receipt = try Self.invoke(ssh, command: command(action, hash), body: body, action: action)
            try bound()
            return receipt
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
                defer { try? FileManager.default.removeItem(at: partial) }
                let receiver = streamer ?? SSHBackupStreamTransport(plan.connection, failureFormatter: Self.streamFailureMessage)
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
            plan.archiveSha = expectedHash; plan.archiveBytes = count
            // Do not move a dispatched transaction backwards during recovery:
            // a crash between these writes must still permit CLEAN_PENDING.
            if plan.phase == "prepared" { plan.phase = "backup-verified" }
            try saveJSON(plan, directory.appendingPathComponent("backup-receipt.json"))
            try saveJSON(plan, Self.pendingURL(root))
            plan.phase = "clean-requested"; try saveJSON(plan, Self.pendingURL(root))
            progress("Очищаю подтверждённые компоненты программы…", 0.97)
            do { complete = try invoke("clean", hash: expectedHash) == "CLEAN_COMPLETE" }
            catch let failure as ReplyFailure where failure.outcomeUnknown {
                // Confirm a possibly committed command once, read-only, using
                // the same identity and archive. Never repeat clean/prepare here.
                do { complete = try invoke("status") == "CLEAN_COMPLETE" }
                catch is ReplyFailure { complete = false }
                if !complete { throw failure }
            }
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
