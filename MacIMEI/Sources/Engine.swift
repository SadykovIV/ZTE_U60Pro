import Foundation
import Darwin

struct CommandResult: Sendable { var status: Int32; var stdout: Data; var stderr: Data }
protocol RemoteTransport { func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult }
final class SSHTransport: RemoteTransport {
    let connection: Connection
    init(_ connection: Connection) { self.connection = connection }
    func run(_ command: String, input: Data? = nil, timeout: TimeInterval = 30) throws -> CommandResult {
        try connection.validate()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zte-process-" + UUID().uuidString)
        try secureDirectory(dir); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("stdout"), err = dir.appendingPathComponent("stderr"), src = dir.appendingPathComponent("stdin")
        try savePrivate(Data(), out); try savePrivate(Data(), err); try savePrivate(input ?? Data(), src)
        let output = try FileHandle(forWritingTo: out), errors = try FileHandle(forWritingTo: err), source = try FileHandle(forReadingFrom: src)
        defer { try? output.close(); try? errors.close(); try? source.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-F", "/dev/null", "-T", "-p", connection.port, "-i", connection.keyPath,
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"" + connection.knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"", "-o", "GlobalKnownHostsFile=/dev/null",
            "root@" + connection.host, command]
        process.standardInput = source; process.standardOutput = output; process.standardError = errors
        try process.run(); let limit = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); let grace = Date().addingTimeInterval(3)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CommandFailure(message: "Истекло время ожидания SSH. Состояние операции сохранено; подключитесь и продолжите её.", partial: CommandResult(status: -1, stdout: (try? Data(contentsOf: out)) ?? Data(), stderr: (try? Data(contentsOf: err)) ?? Data()))
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: try Data(contentsOf: out), stderr: try Data(contentsOf: err))
    }
}

final class ModemEngine: @unchecked Sendable {
    static let firmwareHash = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263"
    static let routerHash = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f"
    let root: URL, resources: URL, connection: Connection
    let transport: RemoteTransport
    let update: @Sendable (String, Double) -> Void
    let fm = FileManager.default
    var lockFD: Int32 = -1
    var remoteLockToken: String?
    var logDirectory: URL
    var backupsURL: URL { root.appendingPathComponent("Backups") }
    var pendingURL: URL { root.appendingPathComponent("pending.json") }
    init(root: URL, resources: URL, connection: Connection, transport: RemoteTransport? = nil, update: @escaping @Sendable (String, Double) -> Void = { _,_ in }) throws {
        self.root = root; self.resources = resources; self.connection = connection
        self.logDirectory = root.appendingPathComponent("Logs/" + UUID().uuidString)
        try secureDirectory(root); try secureDirectory(root.appendingPathComponent("Backups")); try secureDirectory(logDirectory)
        let journal = try ActivityJournal(root: root), operationID = logDirectory.lastPathComponent
        self.update = { message, value in
            do { try journal.record(operationID: operationID, category: "step", title: message, result: value >= 1 ? "completed" : "progress", details: ["progress": String(value)]) }
            catch { journal.markIncomplete(operationID) }
            update(message, value)
        }
        try journal.record(operationID: operationID, category: "engine", title: "Создан контекст операции", result: "started", details: ["endpoint": connection.host + ":" + connection.port, "firmwareCheckSkipped": String(connection.skipFirmwareCheck)])
        self.transport = AuditedRemoteTransport(base: transport ?? SSHTransport(connection), journal: try ActivityJournal(root: root),
                                               operationID: logDirectory.lastPathComponent, endpoint: connection.host + ":" + connection.port)
    }
    func locked<T>(_ body: () throws -> T) throws -> T {
        lockFD = open(root.appendingPathComponent("operation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        try require(lockFD >= 0, "Не удалось открыть локальную блокировку")
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); lockFD = -1; throw IMEIError.message("Другая копия приложения уже выполняет операцию") }
        defer { releaseRemoteLock(); flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        let journal = try ActivityJournal(root: root)
        do {
            let value = try body()
            try? journal.record(operationID: logDirectory.lastPathComponent, category: "engine", title: "Операция завершена", result: "completed")
            return value
        } catch {
            try? journal.record(operationID: logDirectory.lastPathComponent, category: "engine", title: "Операция остановлена", result: "failed", details: ["error": error.localizedDescription])
            throw error
        }
    }
    func remote(_ command: String, input: Data? = nil, timeout: TimeInterval = 30) throws -> Data {
        let r = try transport.run(command, input: input, timeout: timeout)
        if r.status != 0 {
            let reason = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw IMEIError.message("SSH завершился с кодом \(r.status). \(String(reason.prefix(450)))")
        }
        return r.stdout
    }
    func text(_ command: String) throws -> String { String(decoding: try remote(command), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    var tokenURL: URL { root.appendingPathComponent("device-lock.json") }
    func acquireRemoteLock() throws {
        guard remoteLockToken == nil else { return }
        let endpoint = connection.host + ":" + connection.port
        let saved = try? readJSON([String:String].self, tokenURL)
        if let saved { try require(saved["endpoint"] == endpoint, "Сохранена блокировка другого подключения; сначала завершите его операцию") }
        let token = saved?["token"] ?? UUID().uuidString.lowercased()
        try require(UUID(uuidString: token) != nil, "Повреждён токен блокировки")
        try saveJSON(["endpoint": endpoint, "token": token], tokenURL)
        let path = "/tmp/zte-imei-app.lock"
        let command = "umask 077; if mkdir " + path + " 2>/dev/null; then printf '%s' " + shellQuote(token) + " > " + path + "/owner; else test \"$(cat " + path + "/owner 2>/dev/null)\" = " + shellQuote(token) + "; fi"
        _ = try remote(command)
        remoteLockToken = token
    }
    func releaseRemoteLock() {
        if let token = remoteLockToken {
            if (try? remote("test \"$(cat /tmp/zte-imei-app.lock/owner 2>/dev/null)\" = " + shellQuote(token) + " && rm /tmp/zte-imei-app.lock/owner && rmdir /tmp/zte-imei-app.lock", timeout: 10)) != nil {
                try? fm.removeItem(at: tokenURL)
            }
            remoteLockToken = nil
        }
    }
    func identity() throws -> (Identity, String) { try readIdentity(enforceFirmware: true) }
    /// Read-only diagnosis does not grant any write capability or change the connection policy.
    func diagnosticIdentity() throws -> (Identity, String) { try readIdentity(enforceFirmware: false) }
    private func readIdentity(enforceFirmware: Bool) throws -> (Identity, String) {
        let raw = try text("sha256sum /firmware/image/modem.b16 /usr/bin/diag-router; cat /sys/block/mmcblk0/device/cid /proc/sys/kernel/random/boot_id")
        let lines = raw.split(separator: "\n").map(String.init)
        try require(lines.count == 4, "Не удалось прочитать идентификаторы модема")
        let firmware = try FirmwareCheck.hash(lines[0], path: "/firmware/image/modem.b16")
        let router = try FirmwareCheck.hash(lines[1], path: "/usr/bin/diag-router")
        try ActivityJournal(root: root).record(operationID: logDirectory.lastPathComponent, category: "firmware", title: "Сверка прошивки", result: firmware == Self.firmwareHash && router == Self.routerHash ? "completed" : "warning", details: ["firmwareSHA256":firmware, "routerSHA256":router, "expectedFirmwareSHA256": Self.firmwareHash, "expectedRouterSHA256": Self.routerHash, "readOnlyProbe": String(!enforceFirmware)])
        try require(!enforceFirmware || connection.skipFirmwareCheck || (firmware == Self.firmwareHash && router == Self.routerHash), "Прошивка отличается от проверенной MU5250 B31. Операции остановлены.")
        try require(lines[2].count == 32 && lines[2].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Не удалось определить уникальный eMMC CID модема")
        try require(UUID(uuidString: lines[3]) != nil, "Не удалось прочитать boot ID")
        if connection.skipFirmwareCheck {
            try ActivityJournal(root: root).record(operationID: logDirectory.lastPathComponent, category: "firmware", title: "Проверка соответствия B31 отключена пользователем", result: "warning", details: ["firmwareSHA256":firmware, "routerSHA256":router])
        }
        return (Identity(cid: lines[2], firmwareHash: firmware), lines[3])
    }
    func helper(_ name: String, _ mode: String, plan: Data? = nil) throws -> String {
        try require(["zte_nv", "zte_config", "zte_config_read"].contains(name), "Неизвестный helper")
        let manifest = try readJSON([String:String].self, resources.appendingPathComponent("helpers.json"))
        let binary = try Data(contentsOf: resources.appendingPathComponent(name))
        try require(manifest[name] == digest(binary), "Повреждён встроенный инструмент \(name)")
        let directory = "/tmp/zte-imei-" + UUID().uuidString.lowercased(), path = directory + "/helper"
        _ = try remote("umask 077; mkdir " + shellQuote(directory))
        defer { _ = try? remote("rm -f " + shellQuote(path) + " " + shellQuote(directory + "/plan") + "; rmdir " + shellQuote(directory), timeout: 15) }
        let hash = try remote("umask 077; cat > " + shellQuote(path) + " && chmod 700 " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: binary)
        try require(String(decoding: hash, as: UTF8.self).split(separator: " ").first == Substring(digest(binary)), "Контрольная сумма переданного инструмента не совпала")
        if let plan {
            let hash = try remote("umask 077; cat > " + shellQuote(directory + "/plan") + " && sha256sum " + shellQuote(directory + "/plan"), input: plan)
            try require(String(decoding: hash, as: UTF8.self).split(separator: " ").first == Substring(digest(plan)), "Контрольная сумма плана не совпала")
        }
        let command = shellQuote(path) + " " + shellQuote(mode) + (plan == nil ? "" : " " + shellQuote(directory + "/plan"))
        let result = try transport.run(command, input: nil, timeout: 240)
        let log = result.stdout + result.stderr
        try savePrivate(log, logDirectory.appendingPathComponent(name + "-" + mode.replacingOccurrences(of: "--", with: "") + "-" + UUID().uuidString + ".log"))
        let text = String(decoding: log, as: UTF8.self)
        try require(result.status == 0, "Инструмент \(name) остановился (код \(result.status)). Журнал сохранён. Новые операции записи не выполняются.")
        return text
    }
    func snapshot() throws -> [Data] {
        let output = try helper("zte_nv", "--snapshot")
        var records: [Int: Data] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("APP_NV ") {
            let fields = line.split(separator: " "); try require(fields.count == 3, "Неполный ответ NV")
            guard let index = Int(fields[1].replacingOccurrences(of: "index=", with: "")), (0...1).contains(index), fields[2].hasPrefix("data=") else { throw IMEIError.message("Неизвестный индекс NV") }
            try require(records[index] == nil, "Повтор NV в ответе")
            records[index] = try Data(hex: String(fields[2].dropFirst(5)))
        }
        try require(records.count == 2, "Не получена полная пара NV после освобождения сессии")
        let pair = [records[0]!, records[1]!]; for r in pair { _ = try IMEI.decode(r) }; return pair
    }
    func apiPair() throws -> [String] {
        try ["get_imei", "get_imei2"].map { method in
            let data = try remote("ubus call zwrt_zte_mdm.api " + method)
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IMEIError.message("Неверный ответ API IMEI") }
            let imeis = values.values.compactMap { $0 as? String }.filter(IMEI.valid)
            try require(imeis.count == 1, "API не вернул однозначный IMEI"); return imeis[0]
        }
    }
    func readConfig() throws -> Data {
        let log = try helper("zte_config_read", "--read-config"); var data = Data(); var complete = false
        for line in log.split(separator: "\n") {
            if line.hasPrefix("EFS_DATA_HEX ") {
                let fields = line.split(separator: " "); try require(fields.count == 4, "Некорректный ответ config")
                let offset = Int(fields[1].dropFirst(7)), length = Int(fields[2].dropFirst(7))
                let chunk = try Data(hex: String(fields[3].dropFirst(5)))
                try require(offset == data.count && length == chunk.count, "Пропуск данных config"); data += chunk
            }
            if line.hasPrefix("EFS_FILE_COMPLETE path=/config length=15073 ") { complete = true }
        }
        try require(complete, "Не получен полный config"); _ = try ConfigFile.validate(data); return data
    }
    func inspect() throws -> DeviceState {
        update(connection.skipFirmwareCheck ? "Проверка подключения. Сверка прошивки с B31 отключена." : "Проверка подключения и прошивки…", 0.08)
        let (id, boot) = try identity(); try acquireRemoteLock()
        let records = try snapshot(), imeis = try records.map(IMEI.decode)
        try require(try apiPair() == imeis, "IMEI в API и NV отличаются")
        update("Модем подключён. Оба IMEI прочитаны и проверены.", 1)
        return DeviceState(identity: id, boot: boot, records: records, imeis: imeis)
    }
    func makeBackup(_ state: DeviceState) throws -> URL {
        update("Сохраняю полные NV обоих слотов и config…", 0.15)
        let config = try readConfig(); try require(try ConfigFile.validate(config) == 0, "Config содержит активный флаг записи. Продолжите незавершённую операцию.")
        try require(try snapshot() == state.records, "NV изменился во время создания бэкапа")
        let id = UUID().uuidString.lowercased(), url = backupsURL.appendingPathComponent(id); try secureDirectory(url)
        let files = ["nv0.bin": state.records[0], "nv1.bin": state.records[1], "config.bin": config]
        for (name, data) in files { try savePrivate(data, url.appendingPathComponent(name)) }
        let manifest = BackupManifest(id: id, created: ISO8601DateFormatter().string(from: Date()), identity: state.identity, imeis: state.imeis, hashes: files.mapValues(digest))
        try saveJSON(manifest, url.appendingPathComponent("manifest.json")); _ = try loadBackup(url)
        update("Бэкап создан и проверен: \(id.prefix(8)).", 0.25); return url
    }
    func loadBackup(_ url: URL) throws -> (BackupManifest, [Data], Data) {
        let m = try readJSON(BackupManifest.self, url.appendingPathComponent("manifest.json"))
        try require(m.schema == 1 && UUID(uuidString: m.id) != nil && m.imeis.count == 2 && m.hashes.count == 3, "Неверный формат бэкапа")
        var files: [String:Data] = [:]
        for name in ["nv0.bin", "nv1.bin", "config.bin"] {
            let file = url.appendingPathComponent(name), values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            try require(values.isSymbolicLink == false && values.isRegularFile == true, "В бэкапе допускаются только обычные файлы")
            let data = try Data(contentsOf: file); try require(m.hashes[name] == digest(data), "Повреждён бэкап: \(name)"); files[name] = data
        }
        let records = [files["nv0.bin"]!, files["nv1.bin"]!], config = files["config.bin"]!
        try require(try records.map(IMEI.decode) == m.imeis, "IMEI в бэкапе не совпадают с манифестом")
        try require(try ConfigFile.validate(config) == 0, "Config в бэкапе не является исходным")
        return (m, records, config)
    }
    func begin(targets: [String]?, restore: URL? = nil) throws -> DeviceState {
        try require(!fm.fileExists(atPath: root.appendingPathComponent("setup-pending.json").path), "Сначала завершите первоначальную настройку модема")
        try require(!fm.fileExists(atPath: pendingURL.path), "Сначала продолжите незавершённую операцию")
        let state = try inspect(); let desired: [Data]
        if let restore {
            let (m, records, _) = try loadBackup(restore)
            try require(m.identity == state.identity, "Бэкап относится к другому модему или прошивке")
            for i in 0...1 { try require(records[i].dropFirst(9) == state.records[i].dropFirst(9), "Остальные байты NV отличаются от бэкапа; восстановление остановлено") }
            desired = records
        } else {
            try require(targets?.count == 2 && targets![0] != targets![1], "Введите два разных IMEI")
            desired = try (0...1).map { try IMEI.encode(targets![$0], preserving: state.records[$0]) }
        }
        try require(try IMEI.decode(desired[0]) != IMEI.decode(desired[1]), "Для двух слотов нужны разные IMEI")
        try require(desired != state.records, "Эта пара IMEI уже записана")
        let backupURL = try makeBackup(state)
        let t = Transaction(id: UUID().uuidString.lowercased(), backupID: backupURL.lastPathComponent, identity: state.identity, targetHex: desired.map(\.hex), connection: connection, phase: "prepared")
        try saveJSON(t, pendingURL)
        return try resume()
    }
    func reboot(from boot: String, expected: Identity) throws -> String {
        update("Перезагрузка модема. Ожидаю новое подключение…", 0.6)
        // Send once: loss of SSH during a successful reboot is expected. Never blindly repeat.
        _ = try? transport.run("ubus call zwrt_mc.device.manager device_reboot '{\"moduleName\":\"web\"}'", input: nil, timeout: 15)
        let deadline = Date().addingTimeInterval(240)
        var lastAnnouncement = Date.distantPast
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 3)
            if Date().timeIntervalSince(lastAnnouncement) > 20 { update("Модем перезагружается; ожидаю SSH…", 0.6); lastAnnouncement = Date() }
            if let (id, newBoot) = try? identity(), newBoot != boot {
                try require(id == expected, "После перезагрузки подключён другой модем")
                remoteLockToken = nil
                try acquireRemoteLock(); return newBoot
            }
        }
        throw IMEIError.message("Перезагрузка пока не подтверждена. Дождитесь подключения и нажмите «Продолжить»; повторная запись не запускается автоматически.")
    }
    func resume() throws -> DeviceState {
        var t = try readJSON(Transaction.self, pendingURL)
        try require(t.schema == 1 && UUID(uuidString: t.backupID) != nil && t.targetHex.count == 2, "Повреждён журнал операции")
        let (m, original, config) = try loadBackup(backupsURL.appendingPathComponent(t.backupID))
        try require(m.identity == t.identity, "Бэкап и журнал относятся к разным устройствам")
        let initialIdentity = try identity(); let id = initialIdentity.0; var boot = initialIdentity.1; try require(id == t.identity, "Подключён другой модем"); try acquireRemoteLock()
        let desired = try t.targetHex.map { try Data(hex: $0) }
        for i in 0...1 { _ = try IMEI.decode(desired[i]); try require(desired[i].dropFirst(9) == original[i].dropFirst(9), "Журнал изменяет посторонние байты NV") }
        try require(try IMEI.decode(desired[0]) != IMEI.decode(desired[1]), "В журнале одинаковые IMEI")
        let candidate = try ConfigFile.candidate(config), configPlan = config + candidate
        var current = try snapshot()
        for i in 0...1 { try require(current[i] == original[i] || current[i] == desired[i], "Текущий NV не совпал ни с исходным, ни с целевым. Операция остановлена.") }
        let diskConfig = try readConfig(); try require(diskConfig == config || diskConfig == candidate, "Config изменился посторонним образом. Операция остановлена.")
        if current != desired {
            update("Включаю разрешение записи…", 0.35); t.phase = "enabling"; try saveJSON(t, pendingURL)
            _ = try helper("zte_config", "--enable-flag", plan: configPlan)
            t.phase = "rebooting-to-enable"; try saveJSON(t, pendingURL)
            boot = try reboot(from: boot, expected: t.identity)
            let identityAfter = try identity(); try require(identityAfter.0 == t.identity, "После перезагрузки подключён другой модем")
            let afterConfig = try readConfig(); try require(afterConfig == config || afterConfig == candidate, "После перезагрузки config не совпал с известным")
            current = try snapshot()
            for i in 0...1 { try require(current[i] == original[i] || current[i] == desired[i], "NV изменился во время перезагрузки") }
            let plan = current[0] + current[1] + desired[0] + desired[1]
            try savePrivate(plan, logDirectory.appendingPathComponent("nv-plan.bin"))
            t.phase = "writing"; try saveJSON(t, pendingURL); update("Записываю пару IMEI с проверкой каждого шага…", 0.72)
            _ = try helper("zte_nv", "--apply-plan", plan: plan)
            try require(try snapshot() == desired && apiPair() == desired.map(IMEI.decode), "Проверка новых IMEI не прошла")
            t.phase = "written"; try saveJSON(t, pendingURL)
        }
        update("Проверяю исходный config и сохранность IMEI…", 0.82)
        _ = try helper("zte_config", "--restore-original-config", plan: configPlan)
        if t.phase != "final-reboot" || t.finalBootBefore == nil || t.finalBootBefore == boot {
            t.phase = "final-reboot"; t.finalBootBefore = boot; try saveJSON(t, pendingURL)
            boot = try reboot(from: boot, expected: t.identity)
        }
        let final = try inspect(); try require(final.identity == t.identity && final.boot != t.finalBootBefore && final.records == desired, "IMEI после заключительной перезагрузки не совпали")
        _ = try helper("zte_config", "--check-original", plan: configPlan)
        t.phase = "complete"; t.completed = true
        try saveJSON(t, logDirectory.appendingPathComponent("completed.json"))
        try saveJSON(["imei1": final.imeis[0], "imei2": final.imeis[1], "bootID": final.boot, "verified": "NV + API + original config after reboot"], logDirectory.appendingPathComponent("result.json"))
        try fm.removeItem(at: pendingURL)
        update("Готово. Оба IMEI подтверждены после перезагрузки.", 1)
        return final
    }
    func importBackup(_ source: URL) throws -> URL {
        if fm.fileExists(atPath: source.appendingPathComponent("manifest.json").path) {
            let (m, records, config) = try loadBackup(source), state = try inspect()
            try require(m.identity == state.identity, "Бэкап относится к другому модему")
            let id = UUID().uuidString.lowercased(), dest = backupsURL.appendingPathComponent(id); try secureDirectory(dest)
            for (name,data) in ["nv0.bin":records[0], "nv1.bin":records[1], "config.bin":config] { try savePrivate(data, dest.appendingPathComponent(name)) }
            var copied = m; copied.id = id; try saveJSON(copied, dest.appendingPathComponent("manifest.json")); return dest
        }
        // Import the original project backup using exact records, not only the text IMEIs.
        let state = try inspect()
        let records = try (0...1).map { try Data(contentsOf: source.appendingPathComponent("diag-nv550/original-index\($0).bin")) }
        let imeis = try records.map(IMEI.decode)
        let sums = try String(contentsOf: source.appendingPathComponent("diag-nv550/SHA256SUMS"), encoding: .utf8)
        for i in 0...1 {
            let name = "original-index\(i).bin"
            try require(sums.split(separator: "\n").contains { let fields = $0.split(whereSeparator: \.isWhitespace); return fields.count == 2 && fields[0] == Substring(digest(records[i])) && fields[1] == Substring(name) }, "Контрольная сумма старого бэкапа не совпала")
            try require(records[i].dropFirst(9) == state.records[i].dropFirst(9), "Старый NV-бэкап не соответствует текущим служебным данным")
        }
        let config = try readConfig(); try require(try ConfigFile.validate(config) == 0, "Сначала завершите текущую операцию")
        let id = UUID().uuidString.lowercased(), dest = backupsURL.appendingPathComponent(id); try secureDirectory(dest)
        let files = ["nv0.bin":records[0], "nv1.bin":records[1], "config.bin":config]
        for (name,data) in files { try savePrivate(data, dest.appendingPathComponent(name)) }
        let m = BackupManifest(id: id, created: "Импорт исходного бэкапа • " + ISO8601DateFormatter().string(from: Date()), identity: state.identity, imeis: imeis, hashes: files.mapValues(digest))
        try saveJSON(m, dest.appendingPathComponent("manifest.json")); return dest
    }
}
