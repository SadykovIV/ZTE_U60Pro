import Foundation
import Darwin

struct SetupJournal: Codable {
    var id: String
    var identity: WebIdentity
    var phase: String
    var directory: String
    var restoreRequested = false
    var installRequested = false
    var adbSerial: String?
    var cid: String?
    var remoteJournal: String?
    var newAgent: Bool?
}
struct SetupResult: Sendable {
    var connection: Connection
    var state: DeviceState
    var suffix: String
}
protocol HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult
}
final class HostProcessRunner: HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 40) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zte-setup-" + UUID().uuidString)
        try secureDirectory(directory); defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdout"), err = directory.appendingPathComponent("stderr")
        try savePrivate(Data(), out); try savePrivate(Data(), err)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        try process.run(); let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); let grace = Date().addingTimeInterval(3)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit()
            throw CommandFailure(message: "Инструмент настройки не завершился вовремя. Состояние сохранено; подключите модем и продолжите настройку.", partial: CommandResult(status: -1, stdout: (try? Data(contentsOf: out)) ?? Data(), stderr: (try? Data(contentsOf: err)) ?? Data()))
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: try Data(contentsOf: out), stderr: try Data(contentsOf: err))
    }
}
final class ADBClient {
    let binary: URL; let runner: HostCommandRunner
    init(binary: URL, runner: HostCommandRunner) { self.binary = binary; self.runner = runner }
    func command(_ args: [String], timeout: TimeInterval = 30) throws -> Data {
        let result = try runner.run(binary, args, timeout: timeout)
        try require(result.status == 0, "ADB не выполнил команду. Проверьте USB-кабель и подключение модема.")
        return result.stdout
    }
    func devices() throws -> [String] {
        let output = String(decoding: try command(["devices", "-l"]), as: UTF8.self)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 && fields[1] == "device" else { return nil }
            let serial = String(fields[0]); guard serial.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }; return serial
        }
    }
    func shell(_ serial: String, _ text: String, timeout: TimeInterval = 40) throws -> String {
        let marker = "__ZTE_RESULT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__"
        let commandText = "(" + text + "); zte_code=$?; printf '\\n" + marker + "%s\\n' \"$zte_code\""
        let raw = String(decoding: try command(["-s", serial, "shell", commandText], timeout: timeout), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = raw.range(of: marker, options: .backwards), raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            // Keep detailed non-secret installer markers, never raw arbitrary shell output.
            let markers = raw.split(separator: "\n").filter { $0.hasPrefix("INSTALL_ERROR ") || $0.hasPrefix("INSTALL_INCOMPLETE ") }.joined(separator: "; ")
            throw IMEIError.message("Модем отклонил операцию ADB. " + String(markers.prefix(600)))
        }
        return raw[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func identity(_ serial: String, expected: WebIdentity, skipFirmwareCheck: Bool = false) throws -> Identity {
        let output = try shell(serial, "set -e; test \"$(id -u)\" = 0; test \"$(uname -m)\" = aarch64; sha256sum /firmware/image/modem.b16 /usr/bin/diag-router; cat /sys/block/mmcblk0/device/cid; ubus call zwrt_web device_info '{}'")
        let lines = output.split(separator: "\n").map(String.init)
        try require(lines.count >= 4, "Неполные сведения ADB-устройства")
        let firmware = try FirmwareCheck.hash(lines[0], path: "/firmware/image/modem.b16")
        let router = try FirmwareCheck.hash(lines[1], path: "/usr/bin/diag-router")
        try require(skipFirmwareCheck || (firmware == ModemEngine.firmwareHash && router == ModemEngine.routerHash), "ADB-устройство не соответствует проверенной прошивке B31")
        let cid = lines[2]
        try require(cid.count == 32 && cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Не удалось прочитать CID через ADB")
        let data = Data(lines.dropFirst(3).joined(separator: "\n").utf8)
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IMEIError.message("Неверный ответ идентификации ADB") }
        try require(try WebIdentity(info, skipFirmwareCheck: skipFirmwareCheck) == expected, "USB-модем и устройство веб-интерфейса различаются")
        return Identity(cid: cid, firmwareHash: firmware)
    }
    func push(_ serial: String, source: URL, destination: String) throws {
        _ = try command(["-s", serial, "push", source.path, destination], timeout: 90)
        let expected = digest(try Data(contentsOf: source))
        let output = try shell(serial, "set -e; chmod 600 " + shellQuote(destination) + "; sha256sum " + shellQuote(destination))
        try require(output.split(separator: " ").first == Substring(expected), "SHA256 файла после передачи ADB не совпал")
    }
}

final class OnboardingEngine: @unchecked Sendable {
    let root: URL, resources: URL, host: String
    let currentConnection: Connection
    let web: ModemWebClient
    let runner: HostCommandRunner
    let sshFactory: ((Connection) -> RemoteTransport)?
    let update: @Sendable (String, Double) -> Void
    let fm = FileManager.default
    var assets: URL { resources.appendingPathComponent("Onboarding") }
    var pending: URL { root.appendingPathComponent("setup-pending.json") }
    init(root: URL, resources: URL, connection: Connection, web: ModemWebClient? = nil, runner: HostCommandRunner = HostProcessRunner(), sshFactory: ((Connection) -> RemoteTransport)? = nil, update: @escaping @Sendable (String,Double)->Void = {_,_ in}) throws {
        self.root = root; self.resources = resources; self.host = connection.host; self.currentConnection = connection
        let journal = try ActivityJournal(root: root), operationID = "setup-" + UUID().uuidString.lowercased()
        self.web = try web ?? ModemWebClient(host: connection.host, transport: AuditedWebTransport(base: HTTPWebTransport(host: connection.host), journal: journal, operationID: operationID, endpoint: connection.host))
        self.runner = AuditedHostRunner(base: runner, journal: journal, operationID: operationID)
        self.sshFactory = { config in AuditedRemoteTransport(base: sshFactory?(config) ?? SSHTransport(config), journal: journal, operationID: operationID, endpoint: config.host + ":" + config.port) }
        self.update = { message, value in
            do { try journal.record(operationID: operationID, category: "setup", title: message, result: value >= 1 ? "completed" : "progress", details: ["progress": String(value)]) } catch { journal.markIncomplete(operationID) }
            update(message, value)
        }
        try secureDirectory(root)
    }
    func locked<T>(_ work: () throws -> T) throws -> T {
        let fd = open(root.appendingPathComponent("operation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Не удалось создать блокировку приложения"); defer { close(fd) }
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "Другая операция приложения ещё выполняется"); defer { flock(fd, LOCK_UN) }
        try require(!fm.fileExists(atPath: root.appendingPathComponent("pending.json").path), "Сначала завершите незавершённую смену IMEI")
        return try work()
    }
    func verifyAssets() throws -> [String:String] {
        let hashes = try readJSON([String:String].self, assets.appendingPathComponent("SHA256.json"))
        for name in ["adb", "zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] {
            try require(hashes[name] == digest(Data(contentsOf: assets.appendingPathComponent(name))), "Повреждён встроенный компонент настройки: \(name)")
        }
        return hashes
    }
    func inspectSSH(_ connection: Connection, expected: WebIdentity) throws -> DeviceState {
        let engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: sshFactory?(connection))
        defer { engine.releaseRemoteLock() }
        let state = try engine.inspect()
        try require(state.imeis[0] == expected.imei, "SSH-модем отличается от устройства веб-интерфейса")
        let proof = try engine.text("set -e; found=0; for p in $(pidof zte-agent); do if test \"$(readlink /proc/$p/exe)\" = /data/zte-agent; then found=1; fi; done; test \"$found\" = 1; printf AGENT_READY")
        try require(proof == "AGENT_READY", "Агент установлен, но не запущен")
        return state
    }
    func createKey() throws -> URL {
        let directory = root.appendingPathComponent("SSH"); try secureDirectory(directory)
        let key = directory.appendingPathComponent("id_ed25519"), pub = directory.appendingPathComponent("id_ed25519.pub")
        if !fm.fileExists(atPath: key.path) {
            try require(!fm.fileExists(atPath: pub.path), "Найдена неполная пара SSH-ключей; существующий ключ не перезаписан")
            let r = try runner.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), ["-q", "-t", "ed25519", "-N", "", "-C", "ZTE IMEI Studio", "-f", key.path], timeout: 15)
            try require(r.status == 0, "Не удалось создать SSH-ключ")
        }
        let r = try runner.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), ["-y", "-f", key.path], timeout: 15)
        try require(r.status == 0, "Не удалось прочитать собственный SSH-ключ приложения")
        try savePrivate(r.stdout, pub); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        return key
    }
    func waitADB(_ adb: ADBClient, expected: WebIdentity) throws -> (String, Identity) {
        let deadline = Date().addingTimeInterval(240); var announcement = Date.distantPast
        while Date() < deadline {
            if Date().timeIntervalSince(announcement) > 15 { update("Ожидаю ADB. Подключите модем к Mac USB-кабелем с передачей данных…", 0.48); announcement = Date() }
            let serials = (try? adb.devices()) ?? []
            var matches: [(String,Identity)] = []
            for serial in serials { if let identity = try? adb.identity(serial, expected: expected, skipFirmwareCheck: currentConnection.skipFirmwareCheck) { matches.append((serial,identity)) } }
            try require(matches.count <= 1, "Найдено несколько одинаковых модемов. Оставьте подключённым только нужный")
            if let match = matches.first { return match }
            Thread.sleep(forTimeInterval: 3)
        }
        throw IMEIError.message("ADB модема не появился. Подключите USB-кабель с передачей данных и повторите настройку с паролем. Повторное восстановление бэкапа автоматически не запускается.")
    }
    static func agentStartup(password: String) throws -> Data {
        try require(!password.isEmpty && !password.contains("\0"), "Неверный пароль")
        return Data(("#!/bin/sh\nexport ZTE_AGENT_PASSWORD=" + shellQuote(password) + "\nunset ZTE_AGENT_PIN\ntrap '' HUP\nnohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &\n").utf8)
    }
    func prepare(password: String, backupSuffix: String) throws -> (WebIdentity, BackupPatch.Result, URL) {
        try require(!backupSuffix.isEmpty && backupSuffix.utf8.count <= 256 && !backupSuffix.contains("\0"), "Введите ключ расшифровки бэкапа (backup-key suffix)")
        update("Вхожу в веб-интерфейс…", 0.05); try web.login(password: password)
        let identity = try web.identity(skipFirmwareCheck: currentConnection.skipFirmwareCheck)
        update("Сохраняю свежий бэкап настроек…", 0.12)
        let encrypted = try web.freshBackup()
        try require(try web.identity(skipFirmwareCheck: currentConnection.skipFirmwareCheck) == identity, "Устройство изменилось во время подготовки бэкапа")
        let id = UUID().uuidString.lowercased(), directory = root.appendingPathComponent("SetupBackups/" + id); try secureDirectory(directory)
        try savePrivate(encrypted, directory.appendingPathComponent("back_parameter.original"))
        try saveJSON(identity, directory.appendingPathComponent("identity.json"))
        let result = try BackupPatch.prepare(encrypted: encrypted, imei: identity.imei, suffix: backupSuffix)
        try saveJSON(["encryptedSHA256":result.originalHash, "patchedSHA256":result.patchedHash, "suffixVerified":"true", "adbAlreadyEnabled":String(result.alreadyEnabled)], directory.appendingPathComponent("manifest.json"))
        update("Ключ расшифровки проверен по бэкапу.", 0.25)
        return (identity, result, directory)
    }
    func run(password: String, backupSuffix: String) throws -> SetupResult {
        try locked {
            let hashes = try verifyAssets()
            let (identity, patch, directory) = try prepare(password: password, backupSuffix: backupSuffix)
            var journal: SetupJournal
            if fm.fileExists(atPath: pending.path) {
                journal = try readJSON(SetupJournal.self, pending)
                try require(journal.identity == identity && UUID(uuidString: journal.id) != nil, "Незавершённая настройка относится к другому устройству")
                let savedDirectory = URL(fileURLWithPath: journal.directory).standardizedFileURL
                try require(savedDirectory.deletingLastPathComponent() == root.appendingPathComponent("SetupBackups").standardizedFileURL && UUID(uuidString: savedDirectory.lastPathComponent) != nil, "Некорректный путь бэкапа незавершённой настройки")
                if !journal.restoreRequested && !journal.installRequested { journal.directory = directory.path; try saveJSON(journal, pending) }
            } else {
                journal = SetupJournal(id: UUID().uuidString.lowercased(), identity: identity, phase: "prepared", directory: directory.path)
                try saveJSON(journal, pending)
            }
            // Existing verified SSH+agent is sufficient; do not restore a backup just to enable ADB again.
            let own = Connection(host: host, port: "2222", keyPath: root.appendingPathComponent("SSH/id_ed25519").path, knownHostsPath: root.appendingPathComponent("SSH/known_hosts").path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
            for candidate in [own, currentConnection] {
                let ssh: RemoteTransport = sshFactory?(candidate) ?? SSHTransport(candidate)
                let probe = try? ssh.run("test -x /data/zte-agent && pidof zte-agent >/dev/null && printf ZTE_AGENT_PRESENT", input: nil, timeout: 15)
                if probe?.status == 0 && probe?.stdout == Data("ZTE_AGENT_PRESENT".utf8) {
                    let state = try inspectSSH(candidate, expected: identity)
                    if let cid = journal.cid { try require(state.identity.cid == cid, "CID не совпал с незавершённой установкой") }
                    if journal.installRequested && journal.phase != "complete" {
                        try commitIfReady(journal: &journal, connection: candidate, password: password)
                    }
                    journal.phase = "complete"; try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json"))
                    try fm.removeItem(at: pending)
                    update("Доступ уже настроен. Агент работает; можно менять IMEI.", 1)
                    return SetupResult(connection: candidate, state: state, suffix: backupSuffix)
                }
            }
            let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
            var match: (String,Identity)?
            for serial in (try? adb.devices()) ?? [] {
                if let id = try? adb.identity(serial, expected: identity, skipFirmwareCheck: currentConnection.skipFirmwareCheck) {
                    try require(match == nil, "Подключено несколько одинаковых модемов"); match = (serial,id)
                }
            }
            if match == nil && !patch.alreadyEnabled && !journal.restoreRequested && !journal.installRequested {
                try require(try web.identity(skipFirmwareCheck: currentConnection.skipFirmwareCheck) == identity, "Устройство изменилось перед включением ADB")
                try savePrivate(patch.patchedEncrypted, URL(fileURLWithPath: journal.directory).appendingPathComponent("back_parameter.adb-only"))
                update("Включаю ADB через проверенный бэкап. Модем перезагрузится…", 0.35)
                try web.upload(patch.patchedEncrypted)
                try require(try web.identity(skipFirmwareCheck: currentConnection.skipFirmwareCheck) == identity, "Устройство изменилось перед восстановлением")
                journal.restoreRequested = true; journal.phase = "restore-requested"; try saveJSON(journal, pending)
                do { try web.restore() } catch { update("Связь при восстановлении прервалась; проверяю появление ADB без повторной отправки…", 0.4) }
            }
            if match == nil { match = try waitADB(adb, expected: identity) }
            let (serial, deviceID) = match!
            if let cid = journal.cid { try require(cid == deviceID.cid, "CID отличается от незавершённой установки") }
            journal.cid = deviceID.cid; journal.adbSerial = serial
            if journal.installRequested {
                let remoteJournal = "/data/local/tmp/zte-imei-installations/" + journal.id
                let phase = try adb.shell(serial, "cat " + shellQuote(remoteJournal + "/state"))
                try require(phase == "ready" || phase == "complete", "Предыдущая установка прервалась до готовности. Журнал сохранён: " + remoteJournal)
                let key = root.appendingPathComponent("SSH/id_ed25519")
                try require(fm.fileExists(atPath: key.path), "Отсутствует собственный ключ незавершённой установки")
                let connection = try pinSSH(adb: adb, serial: serial, expected: identity, deviceID: deviceID, key: key)
                let state = try inspectSSH(connection, expected: identity)
                try require(state.identity == deviceID, "SSH CID отличается от проверенного USB-модема")
                journal.remoteJournal = remoteJournal
                try commitIfReady(journal: &journal, connection: connection, password: password)
                try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
                update("Установка завершена; агент и IMEI проверены.", 1)
                return SetupResult(connection: connection, state: state, suffix: backupSuffix)
            }
            let key = try createKey(), pub = key.appendingPathExtension("pub"), publicData = try Data(contentsOf: pub)
            let stage = "/data/local/tmp/zte-imei-setup-" + journal.id
            try require(try adb.identity(serial, expected: identity, skipFirmwareCheck: currentConnection.skipFirmwareCheck) == deviceID, "CID изменился перед передачей установщика")
            _ = try adb.shell(serial, "umask 077; mkdir " + shellQuote(stage))
            let temporary = fm.temporaryDirectory.appendingPathComponent("zte-credential-" + UUID().uuidString); try secureDirectory(temporary)
            defer { try? fm.removeItem(at: temporary) }
            let startup = temporary.appendingPathComponent("start-agent.sh"); try savePrivate(Self.agentStartup(password: password), startup)
            update("Устанавливаю агент и доступ по собственному SSH-ключу…", 0.65)
            for name in ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] { try adb.push(serial, source: assets.appendingPathComponent(name), destination: stage + "/" + name) }
            try adb.push(serial, source: pub, destination: stage + "/id_ed25519.pub")
            try adb.push(serial, source: startup, destination: stage + "/start-agent.sh")
            journal.installRequested = true; journal.phase = "install-requested"; try saveJSON(journal, pending)
            let arguments = [stage + "/setup-agent.sh", stage, deviceID.cid, hashes["zte-agent"]!, hashes["dropbear"]!, digest(publicData)]
            let installOutput = try adb.shell(serial, "sh " + arguments.map(shellQuote).joined(separator: " "), timeout: 100)
            try savePrivate(Data(installOutput.utf8), URL(fileURLWithPath: journal.directory).appendingPathComponent("installation.log"))
            guard let ready = installOutput.split(separator: "\n").first(where: { $0.hasPrefix("INSTALL_READY ") }) else { throw IMEIError.message("Установщик не подтвердил готовность") }
            let remoteJournal = String(ready.dropFirst("INSTALL_READY ".count))
            try require(remoteJournal == "/data/local/tmp/zte-imei-installations/" + journal.id, "Неожиданный путь журнала установщика")
            journal.remoteJournal = remoteJournal; journal.newAgent = installOutput.split(separator: "\n").contains("INSTALL_AGENT new"); journal.phase = "ready"; try saveJSON(journal, pending)
            let connection = try pinSSH(adb: adb, serial: serial, expected: identity, deviceID: deviceID, key: key)
            update("Проверяю SSH, агент и чтение IMEI…", 0.88)
            let state = try inspectSSH(connection, expected: identity)
            try require(state.identity == deviceID, "После установки подключён другой модем")
            try commitIfReady(journal: &journal, connection: connection, password: password)
            try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
            // Credentials in this owned staging directory are no longer needed. Device recovery snapshots remain private.
            _ = try? adb.shell(serial, "rm -f " + ["zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh","id_ed25519.pub","start-agent.sh"].map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage))
            update("ADB и агент настроены. Оба IMEI прочитаны; можно менять пару.", 1)
            return SetupResult(connection: connection, state: state, suffix: backupSuffix)
        }
    }
    func pinSSH(adb: ADBClient, serial: String, expected: WebIdentity, deviceID: Identity, key: URL) throws -> Connection {
        try require(try adb.identity(serial, expected: expected, skipFirmwareCheck: currentConnection.skipFirmwareCheck) == deviceID, "CID изменился перед чтением SSH host key")
        let publicHost = try adb.shell(serial, "/data/bin/dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key")
        let hostKeys = publicHost.split(separator: "\n").filter { $0.hasPrefix("ssh-ed25519 ") }
        try require(hostKeys.count == 1, "Не получен однозначный SSH host key по USB")
        let fields = hostKeys[0].split(separator: " ")
        try require(fields.count >= 2 && Data(base64Encoded: String(fields[1]))?.count == 51, "Неверный SSH host key")
        try require(try adb.identity(serial, expected: expected, skipFirmwareCheck: currentConnection.skipFirmwareCheck) == deviceID, "CID изменился при чтении SSH host key")
        let knownHosts = root.appendingPathComponent("SSH/known_hosts")
        try savePrivate(Data("[\(host)]:2222 ssh-ed25519 \(fields[1])\n".utf8), knownHosts)
        return Connection(host: host, port: "2222", keyPath: key.path, knownHostsPath: knownHosts.path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
    }
    func commitIfReady(journal: inout SetupJournal, connection: Connection, password: String) throws {
        guard journal.installRequested else { return }
        guard let cid = journal.cid else { throw IMEIError.message("В журнале установки отсутствует CID") }
        let remoteJournal = journal.remoteJournal ?? "/data/local/tmp/zte-imei-installations/" + journal.id
        let script = "/data/local/tmp/zte-imei-setup-" + journal.id + "/setup-agent.sh"
        let ssh: RemoteTransport = sshFactory?(connection) ?? SSHTransport(connection)
        if journal.newAgent == nil {
            let query = try ssh.run("if test -f " + shellQuote(remoteJournal + "/present/data_zte-agent") + "; then printf EXISTING; else printf NEW; fi", input: nil, timeout: 15)
            try require(query.status == 0, "Не удалось проверить происхождение установленного агента")
            journal.newAgent = query.stdout == Data("NEW".utf8)
        }
        if journal.newAgent == true {
            let body = try JSONSerialization.data(withJSONObject: ["password": password])
            let login = try ssh.run("/usr/bin/curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 -H 'Content-Type: application/json' --data-binary @- " + shellQuote("http://" + host + ":9090/api/auth/login"), input: body, timeout: 20)
            guard login.status == 0, let response = try JSONSerialization.jsonObject(with: login.stdout) as? [String:Any], response["ok"] as? Bool == true, let data = response["data"] as? [String:Any], let token = data["token"] as? String, !token.isEmpty else {
                throw IMEIError.message("Новый агент запущен, но не подтвердил вход заданным паролем")
            }
        }
        let command = "sh " + [script, "--commit", remoteJournal, cid].map(shellQuote).joined(separator: " ")
        let r = try ssh.run(command, input: nil, timeout: 40)
        try require(r.status == 0 && String(decoding: r.stdout, as: UTF8.self).contains("INSTALL_COMMITTED " + remoteJournal), "Установка готова, но её журнал не удалось завершить")
        journal.remoteJournal = remoteJournal; journal.phase = "complete"
    }
}
