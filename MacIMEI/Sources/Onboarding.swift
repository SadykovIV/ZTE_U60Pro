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
    var installerProfile: String?
    var firmwareHash: String?
    var routerHash: String?
}
struct SetupResult: Sendable {
    var connection: Connection
    var state: DeviceState?
    var identity: Identity
    var firmware: String
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
    func devices(usbOnly: Bool = false) throws -> [String] {
        let output = String(decoding: try command(["devices", "-l"]), as: UTF8.self)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 && fields[1] == "device" else { return nil }
            if usbOnly {
                let descriptors = fields.filter { $0.hasPrefix("usb:") }
                guard descriptors.count == 1, String(descriptors[0]).range(of: #"^usb:[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
            }
            let serial = String(fields[0]); guard serial.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }; return serial
        }
    }
    func shell(_ serial: String, _ text: String, timeout: TimeInterval = 40) throws -> String {
        let result = try shellResult(serial, text, timeout: timeout)
        try require(result.status == 0, "Модем отклонил операцию ADB (удалённый код \(result.status)). " + Self.errorExcerpt(result.stderr + result.stdout, command: text))
        return String(decoding: result.stdout, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func errorExcerpt(_ data: Data, command: String = "") -> String {
        let safe = ActivityJournal.diagnosticOutput(data, command: command)
        let clean = safe.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }.map(String.init).joined()
        return String(clean.split(whereSeparator: \.isNewline).prefix(4).joined(separator: "; ").prefix(600))
    }
    static func shellMarker(in command: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "__ZTE_RESULT_[A-F0-9]{32}__") else { return nil }
        let matches = regex.matches(in: command, range: NSRange(command.startIndex..., in: command))
        guard matches.count == 1, let range = Range(matches[0].range, in: command) else { return nil }
        return String(command[range])
    }
    static func decodeShellResult(_ result: CommandResult, marker: String, command: String = "") throws -> CommandResult {
        guard result.status == 0 else {
            throw CommandFailure(message: "ADB не выполнил команду (локальный код \(result.status)). " + errorExcerpt(result.stderr + result.stdout, command: command), partial: result)
        }
        try require(shellMarker(in: marker) == marker, "Некорректный маркер завершения ADB")
        let needle = Data(marker.utf8), raw = result.stdout
        guard let range = raw.range(of: needle), raw.range(of: needle, in: range.upperBound..<raw.endIndex) == nil, range.lowerBound > raw.startIndex, raw[range.lowerBound - 1] == 10 else {
            throw CommandFailure(message: "ADB не вернул однозначный удалённый код завершения. " + errorExcerpt(result.stderr + result.stdout, command: command), partial: result)
        }
        var suffix = Data(raw[range.upperBound...])
        guard suffix.last == 10 else { throw CommandFailure(message: "ADB вернул незавершённый маркер результата", partial: result) }
        suffix.removeLast(); if suffix.last == 13 { suffix.removeLast() }
        guard !suffix.isEmpty, suffix.count <= 3, suffix.allSatisfy({ (48...57).contains($0) }), let code = Int32(String(decoding: suffix, as: UTF8.self)), (0...255).contains(code), String(code) == String(decoding: suffix, as: UTF8.self) else {
            throw CommandFailure(message: "ADB вернул неверный удалённый код завершения", partial: result)
        }
        var end = range.lowerBound - 1
        if end > raw.startIndex && raw[end - 1] == 13 { end -= 1 }
        return CommandResult(status: code, stdout: Data(raw[..<end]), stderr: result.stderr)
    }
    func shellResult(_ serial: String, _ text: String, timeout: TimeInterval = 40) throws -> CommandResult {
        try require(!serial.isEmpty && serial.utf8.count <= 256 && serial.utf8.allSatisfy { (33...126).contains($0) }, "Неверный серийный номер ADB")
        let marker = "__ZTE_RESULT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__"
        let commandText = "(" + text + "); zte_code=$?; printf '\\n" + marker + "%s\\n' \"$zte_code\""
        return try Self.decodeShellResult(runner.run(binary, ["-s", serial, "shell", commandText], timeout: timeout), marker: marker, command: text)
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
    static let b02FirmwareHash = "7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e"
    static func installerProfile(web: WebIdentity, device: Identity, experimental: Bool) throws -> String {
        if web.firmware == "CN_ZTE_MU5250V1.0.0B31" && web.inner == "BD_CNMU5250V1.0.0B31" && device.firmwareHash == ModemEngine.firmwareHash { return "b31" }
        if experimental && web.firmware == "STD_PL_MU5250V1.0.0B02" && web.inner == "BD_STDPLMU5250V1.0.0B02" && device.firmwareHash == b02FirmwareHash { return "b02-experimental" }
        throw IMEIError.message("Установщик поддерживает B31 и отдельный экспериментальный профиль B02 с проверкой точных хэшей. Эта прошивка не разрешена для установки.")
    }
    static func isB31(_ identity: WebIdentity) -> Bool { identity.firmware == "CN_ZTE_MU5250V1.0.0B31" && identity.inner == "BD_CNMU5250V1.0.0B31" }
    let backupSuffix: String
    let root: URL, resources: URL, host: String
    let currentConnection: Connection
    let web: ModemWebClient
    let runner: HostCommandRunner
    let sshFactory: ((Connection) -> RemoteTransport)?
    let update: @Sendable (String, Double) -> Void
    let fm = FileManager.default
    var assets: URL { resources.appendingPathComponent("Onboarding") }
    var pending: URL { root.appendingPathComponent("setup-pending.json") }
    init(root: URL, resources: URL, connection: Connection, backupSuffix: String = "", web: ModemWebClient? = nil, runner: HostCommandRunner = HostProcessRunner(), sshFactory: ((Connection) -> RemoteTransport)? = nil, update: @escaping @Sendable (String,Double)->Void = {_,_ in}) throws {
        self.backupSuffix = backupSuffix
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
        try require(!SystemBackups.hasPendingRestore(root: root), "Сначала завершите восстановление полного образа модема")
        return try work()
    }
    func verifyAssets() throws -> [String:String] {
        let hashes = try readJSON([String:String].self, assets.appendingPathComponent("SHA256.json"))
        for name in ["adb", "zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] {
            try require(hashes[name] == digest(Data(contentsOf: assets.appendingPathComponent(name))), "Повреждён встроенный компонент настройки: \(name)")
        }
        return hashes
    }
    /// Verify access without logging in to either HTTP service, uploading a
    /// helper, or interpreting SSH reachability as agent/NV readiness.
    func prepareSSH(expectedIdentity: Identity? = nil, expectedIMEI: String? = nil) throws -> SetupResult? {
        try locked {
            try require(!fm.fileExists(atPath: pending.path), "Сначала продолжите незавершённую настройку с паролями веб-интерфейса и агента. Журнал установки сохранён.")
            update("Проверяю существующий SSH-доступ…", 0.1)
            let expected = try DiagnosticDeviceExpectation.load(root: root, identity: expectedIdentity, web: nil, imei: expectedIMEI)
            let own = Connection(host: host, port: "2222", keyPath: root.appendingPathComponent("SSH/id_ed25519").path, knownHostsPath: root.appendingPathComponent("SSH/known_hosts").path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
            var seen = Set<String>()
            let command = DiagnosticTransportSelector.identityCommand(requireWeb: true)
            for candidate in [currentConnection, own] {
                let key = [candidate.host, candidate.port, candidate.keyPath, candidate.knownHostsPath].joined(separator: "\n")
                guard seen.insert(key).inserted else { continue }
                let ssh: RemoteTransport = sshFactory?(candidate) ?? SSHTransport(candidate)
                let first: CommandResult
                do { first = try ssh.run(command, input: nil, timeout: 15) }
                catch {
                    let partial = (error as? CommandFailure).map { String(decoding: $0.partial.stderr + $0.partial.stdout, as: UTF8.self) } ?? ""
                    try require(!DiagnosticTransportSelector.hostTrustFailure(error.localizedDescription + partial), "Проверка ключа SSH не пройдена. Подготовка остановлена без изменения модема.")
                    continue
                }
                let detail = String(decoding: first.stderr + first.stdout, as: UTF8.self)
                try require(!DiagnosticTransportSelector.hostTrustFailure(detail), "Проверка ключа SSH не пройдена. Подготовка остановлена без изменения модема.")
                if first.status == 255 || first.status == -1 { continue }
                try require(first.status == 0, "SSH отвечает, но не подтвердил root-доступ и идентификацию модема")
                let proof = try DiagnosticTransportSelector.parseIdentity(first.stdout, requireWeb: true)
                try require(expected.matches(proof) && (expectedIdentity == nil || expectedIdentity == proof.identity), "SSH подключён к другому модему или прошивке; подготовка остановлена")
                guard let webIdentity = proof.webIdentity else { throw IMEIError.message("SSH не вернул сведения модели модема") }
                try require(proof.routerHash == ModemEngine.routerHash, "SSH-модем имеет неподдерживаемый diag-router")
                _ = try Self.installerProfile(web: webIdentity, device: proof.identity, experimental: currentConnection.skipFirmwareCheck)
                let second = try ssh.run(command, input: nil, timeout: 15)
                try require(second.status == 0 && (try DiagnosticTransportSelector.parseIdentity(second.stdout, requireWeb: true)) == proof, "Во время проверки SSH изменился модем, прошивка или загрузка")
                update("SSH проверен. Готовность агента и IMEI проверяются отдельно.", 1)
                return SetupResult(connection: candidate, state: nil, identity: proof.identity, firmware: webIdentity.firmware, suffix: "")
            }
            return nil
        }
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
    func inspectSetupSSH(_ connection: Connection, expected: WebIdentity, password: String) throws -> (Identity, DeviceState?) {
        if Self.isB31(expected) {
            let state = try inspectSSH(connection, expected: expected)
            return (state.identity, state)
        }
        let engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: sshFactory?(connection))
        let (identity, boot) = try engine.diagnosticIdentity()
        _ = try Self.installerProfile(web: expected, device: identity, experimental: currentConnection.skipFirmwareCheck)
        let info = try engine.remote("set -e; test \"$(id -u)\" = 0; test \"$(uname -m)\" = aarch64; test \"$(sha256sum /usr/bin/diag-router | cut -d ' ' -f1)\" = " + shellQuote(ModemEngine.routerHash) + "; ubus call zwrt_web device_info '{}'")
        guard let object = try JSONSerialization.jsonObject(with: info) as? [String: Any] else { throw IMEIError.message("Неполная идентификация SSH после установки") }
        try require(try WebIdentity(object, skipFirmwareCheck: true) == expected, "SSH-модем и устройство веб-интерфейса различаются")
        let proof = try engine.text("set -e; found=0; for p in $(pidof zte-agent); do if test \"$(readlink /proc/$p/exe)\" = /data/zte-agent; then found=1; fi; done; test \"$found\" = 1; printf AGENT_READY")
        try require(proof == "AGENT_READY", "Агент установлен, но не запущен")
        try authenticateAgent(transport: engine.transport, password: password)
        let after = try engine.diagnosticIdentity()
        try require(after.0 == identity && after.1 == boot, "Во время проверки доступа изменился модем, прошивка или загрузка")
        return (identity, nil)
    }
    private func authenticateAgent(transport: RemoteTransport, password: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        let login = try transport.run("/usr/bin/curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 -H 'Content-Type: application/json' --data-binary @- " + shellQuote("http://" + host + ":9090/api/auth/login"), input: body, timeout: 20)
        guard login.status == 0, let response = try JSONSerialization.jsonObject(with: login.stdout) as? [String: Any], response["ok"] as? Bool == true, let data = response["data"] as? [String: Any], let token = data["token"] as? String, !token.isEmpty else {
            throw IMEIError.message("Агент запущен, но не подтвердил вход заданным паролем")
        }
    }
    static func stagePreparationCommand(stage: String, owner: String) -> String {
        """
        set -eu
        umask 077
        stage=\(shellQuote(stage)); owner=\(shellQuote(owner))
        fail() { printf 'INSTALL_ERROR STAGE_%s\\n' "$1" >&2; exit 1; }
        safe_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail DIRECTORY; mode=$(stat -c %a "$1"); case "$mode" in ''|*[!0-7]*) fail MODE;; esac; test "$((0$mode & 0022))" = 0 || fail MODE; }
        safe_dir /data
        for parent in /data/local /data/local/tmp; do
          if test ! -e "$parent" && test ! -L "$parent"; then mkdir -m 755 "$parent"; fi
          safe_dir "$parent"
        done
        if test ! -e "$stage" && test ! -L "$stage"; then
          mkdir -m 700 "$stage"
          printf '%s\\n' "$owner" > "$stage/.owner"
        fi
        safe_dir "$stage"
        test "$(stat -c %a "$stage")" = 700 || fail MODE
        test -f "$stage/.owner" && test ! -L "$stage/.owner" && test "$(stat -c %u "$stage/.owner")" = 0 && test "$(stat -c %a "$stage/.owner")" = 600 && test "$(stat -c %h "$stage/.owner")" = 1 || fail OWNER_FILE
        test "$(cat "$stage/.owner")" = "$owner" || fail OWNER
        test ! -e "$stage/.install-requested" && test ! -L "$stage/.install-requested" || fail INSTALL_REQUESTED
        printf 'INSTALL_STAGE_READY\\n'
        """
    }
    private func pushStaged(_ adb: ADBClient, serial: String, source: URL, stage: String, name: String, owner: String) throws {
        let incoming = stage + "/incoming-" + UUID().uuidString.lowercased(), destination = stage + "/" + name
        try adb.push(serial, source: source, destination: incoming)
        let command = "set -eu; test -d " + shellQuote(stage) + "; test ! -L " + shellQuote(stage) + "; test \"$(cat " + shellQuote(stage + "/.owner") + ")\" = " + shellQuote(owner) + "; test ! -e " + shellQuote(stage + "/.install-requested") + "; test ! -L " + shellQuote(stage + "/.install-requested") + "; test -f " + shellQuote(incoming) + "; test ! -L " + shellQuote(incoming) + "; test \"$(stat -c %h " + shellQuote(incoming) + ")\" = 1; test ! -L " + shellQuote(destination) + "; if test -e " + shellQuote(destination) + "; then test -f " + shellQuote(destination) + "; test \"$(stat -c %h " + shellQuote(destination) + ")\" = 1; fi; mv " + shellQuote(incoming) + " " + shellQuote(destination)
        _ = try adb.shell(serial, command)
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
            let serials = (try? adb.devices(usbOnly: !Self.isB31(expected))) ?? []
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
    func prepare(password: String, expectedIMEI: String? = nil) throws -> (WebIdentity, BackupPatch.Result, URL) {
        try require(!backupSuffix.isEmpty && backupSuffix.utf8.count <= 128 && !backupSuffix.contains("\0"), "Введите ключ расшифровки бэкапа (backup-key suffix)")
        update("Вхожу в веб-интерфейс…", 0.05); try web.login(password: password)
        let identity = try web.identity(skipFirmwareCheck: currentConnection.skipFirmwareCheck)
        try require(expectedIMEI == nil || identity.imei == expectedIMEI, "Веб-интерфейс относится к другому модему; подготовка остановлена до резервного копирования")
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
    /// Compatibility entry point whose caller explicitly supplies one password
    /// for both services. New UI flows pass the two credentials separately.
    func run(password: String) throws -> SetupResult { try run(webPassword: password, agentPassword: password) }
    func run(webPassword: String, agentPassword: String, expectedIdentity: Identity? = nil, expectedIMEI: String? = nil) throws -> SetupResult {
        try locked {
            try require(!webPassword.isEmpty && !webPassword.contains("\0"), "Введите пароль веб-интерфейса")
            try require(!agentPassword.isEmpty && !agentPassword.contains("\0"), "Введите отдельный пароль агента")
            let expected = try DiagnosticDeviceExpectation.load(root: root, identity: expectedIdentity, web: nil, imei: expectedIMEI)
            func validateExpectedDevice(_ device: Identity) throws {
                try require(expected.cids.isEmpty || expected.cids.contains(device.cid), "CID отличается от ожидаемого модема или незавершённой установки")
                if let expectedIdentity { try require(device == expectedIdentity, "Прошивка ожидаемого модема изменилась; подготовка остановлена") }
            }
            let hashes = try verifyAssets()
            let (identity, patch, directory) = try prepare(password: webPassword, expectedIMEI: expected.imeis.first)
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
                    if !expected.cids.isEmpty || !expected.imeis.isEmpty {
                        let response = try ssh.run(DiagnosticTransportSelector.identityCommand(requireWeb: true), input: nil, timeout: 15)
                        try require(response.status == 0, "SSH не подтвердил ожидаемый модем до установки")
                        let proof = try DiagnosticTransportSelector.parseIdentity(response.stdout, requireWeb: true)
                        try validateExpectedDevice(proof.identity)
                        try require(expected.matches(proof), "SSH относится к другому модему; подготовка остановлена до загрузки помощников")
                    }
                    let (deviceID, state) = try inspectSetupSSH(candidate, expected: identity, password: agentPassword)
                    if let cid = journal.cid { try require(deviceID.cid == cid, "CID не совпал с незавершённой установкой") }
                    if journal.installRequested && journal.phase != "complete" {
                        try commitIfReady(journal: &journal, connection: candidate, password: agentPassword)
                    }
                    journal.phase = "complete"; try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json"))
                    try fm.removeItem(at: pending)
                    update(state == nil ? "SSH и агент доступны. Совместимость NV/EFS на B02 ещё не проверена." : "Доступ уже настроен. Агент работает; можно менять IMEI.", 1)
                    return SetupResult(connection: candidate, state: state, identity: deviceID, firmware: identity.firmware, suffix: "")
                }
            }
            let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
            var match: (String,Identity)?
            for serial in (try? adb.devices(usbOnly: !Self.isB31(identity))) ?? [] {
                if let id = try? adb.identity(serial, expected: identity, skipFirmwareCheck: currentConnection.skipFirmwareCheck) {
                    try validateExpectedDevice(id)
                    try require(match == nil, "Подключено несколько одинаковых модемов"); match = (serial,id)
                }
            }
            try require(match != nil || Self.isB31(identity), "Для экспериментальной настройки B02 нужен уже работающий root ADB по USB. Включение ADB через восстановление бэкапа на этой прошивке не поддерживается.")
            if match == nil && !patch.alreadyEnabled && !journal.restoreRequested && !journal.installRequested {
                try require(expected.cids.isEmpty || !expected.imeis.isEmpty, "Веб-интерфейс не сообщает CID. Для включения ADB сначала подтвердите связь ожидаемого CID и IMEI либо подключите уже работающий USB ADB.")
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
            try validateExpectedDevice(deviceID)
            let profile = try Self.installerProfile(web: identity, device: deviceID, experimental: currentConnection.skipFirmwareCheck)
            if let cid = journal.cid { try require(cid == deviceID.cid, "CID отличается от незавершённой установки") }
            if let previous = journal.installerProfile { try require(previous == profile && journal.firmwareHash == deviceID.firmwareHash && journal.routerHash == ModemEngine.routerHash, "Профиль прошивки изменился после начала установки") }
            journal.cid = deviceID.cid; journal.adbSerial = serial
            if journal.installRequested {
                let remoteJournal = "/data/local/tmp/zte-imei-installations/" + journal.id
                let phase = try adb.shell(serial, "cat " + shellQuote(remoteJournal + "/state"))
                try require(phase == "ready" || phase == "complete", "Предыдущая установка прервалась до готовности. Журнал сохранён: " + remoteJournal)
                let key = root.appendingPathComponent("SSH/id_ed25519")
                try require(fm.fileExists(atPath: key.path), "Отсутствует собственный ключ незавершённой установки")
                let connection = try pinSSH(adb: adb, serial: serial, expected: identity, deviceID: deviceID, key: key)
                let (sshIdentity, state) = try inspectSetupSSH(connection, expected: identity, password: agentPassword)
                try require(sshIdentity == deviceID, "SSH CID отличается от проверенного USB-модема")
                journal.remoteJournal = remoteJournal
                try commitIfReady(journal: &journal, connection: connection, password: agentPassword)
                try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
                update(state == nil ? "Установка доступа завершена. Совместимость NV/EFS на B02 ещё не проверена." : "Установка завершена; агент и IMEI проверены.", 1)
                return SetupResult(connection: connection, state: state, identity: deviceID, firmware: identity.firmware, suffix: "")
            }
            let installer = try String(contentsOf: assets.appendingPathComponent("setup-agent.sh"), encoding: .utf8)
            let policyArguments = [deviceID.cid, profile, deviceID.firmwareHash, ModemEngine.routerHash]
            update(profile == "b31" ? "Проверяю условия установки для B31…" : "Проверяю условия экспериментальной установки доступа для B02…", 0.55)
            let preflight = try adb.shell(serial, "sh -c " + shellQuote(installer) + " -- " + (["--preflight"] + policyArguments).map(shellQuote).joined(separator: " "), timeout: 60)
            try require(preflight == "INSTALL_PREFLIGHT " + profile + " imei_config=unknown", "Установщик не подтвердил предварительную проверку этой прошивки")
            journal.installerProfile = profile; journal.firmwareHash = deviceID.firmwareHash; journal.routerHash = ModemEngine.routerHash
            try saveJSON(journal, pending)
            let key = try createKey(), pub = key.appendingPathExtension("pub"), publicData = try Data(contentsOf: pub)
            let stage = "/data/local/tmp/zte-imei-setup-" + journal.id
            let owner = [journal.id, deviceID.cid, profile, deviceID.firmwareHash, ModemEngine.routerHash].joined(separator: " ")
            try require(try adb.identity(serial, expected: identity, skipFirmwareCheck: currentConnection.skipFirmwareCheck) == deviceID, "CID изменился перед передачей установщика")
            update("Подготавливаю временный каталог установки…", 0.6)
            try require(try adb.shell(serial, Self.stagePreparationCommand(stage: stage, owner: owner)) == "INSTALL_STAGE_READY", "Не подтверждён приватный каталог установки")
            let temporary = fm.temporaryDirectory.appendingPathComponent("zte-credential-" + UUID().uuidString); try secureDirectory(temporary)
            defer { try? fm.removeItem(at: temporary) }
            let startup = temporary.appendingPathComponent("start-agent.sh"); try savePrivate(Self.agentStartup(password: agentPassword), startup)
            update("Устанавливаю агент и доступ по собственному SSH-ключу…", 0.65)
            for name in ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] { try pushStaged(adb, serial: serial, source: assets.appendingPathComponent(name), stage: stage, name: name, owner: owner) }
            try pushStaged(adb, serial: serial, source: pub, stage: stage, name: "id_ed25519.pub", owner: owner)
            try pushStaged(adb, serial: serial, source: startup, stage: stage, name: "start-agent.sh", owner: owner)
            journal.installRequested = true; journal.phase = "install-requested"; try saveJSON(journal, pending)
            _ = try adb.shell(serial, "set -eu; umask 077; set -C; printf '%s\\n' " + shellQuote(owner) + " > " + shellQuote(stage + "/.install-requested"))
            let arguments = [stage + "/setup-agent.sh", stage, deviceID.cid, hashes["zte-agent"]!, hashes["dropbear"]!, digest(publicData), profile, deviceID.firmwareHash, ModemEngine.routerHash]
            let installOutput = try adb.shell(serial, "sh " + arguments.map(shellQuote).joined(separator: " "), timeout: 100)
            try savePrivate(Data(installOutput.utf8), URL(fileURLWithPath: journal.directory).appendingPathComponent("installation.log"))
            guard let ready = installOutput.split(separator: "\n").first(where: { $0.hasPrefix("INSTALL_READY ") }) else { throw IMEIError.message("Установщик не подтвердил готовность") }
            let remoteJournal = String(ready.dropFirst("INSTALL_READY ".count))
            try require(remoteJournal == "/data/local/tmp/zte-imei-installations/" + journal.id, "Неожиданный путь журнала установщика")
            journal.remoteJournal = remoteJournal; journal.newAgent = installOutput.split(separator: "\n").contains("INSTALL_AGENT new"); journal.phase = "ready"; try saveJSON(journal, pending)
            let connection = try pinSSH(adb: adb, serial: serial, expected: identity, deviceID: deviceID, key: key)
            update(profile == "b31" ? "Проверяю SSH, агент и чтение IMEI…" : "Проверяю SSH, идентичность модема и вход в агент…", 0.88)
            let (sshIdentity, state) = try inspectSetupSSH(connection, expected: identity, password: agentPassword)
            try require(sshIdentity == deviceID, "После установки подключён другой модем")
            try commitIfReady(journal: &journal, connection: connection, password: agentPassword)
            try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
            // Credentials in this owned staging directory are no longer needed. Device recovery snapshots remain private.
            _ = try? adb.shell(serial, "rm -f " + ["zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh","id_ed25519.pub","start-agent.sh",".owner",".install-requested"].map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage))
            update(state == nil ? "SSH и агент настроены. Совместимость NV/EFS на B02 ещё не проверена." : "ADB и агент настроены. Оба IMEI прочитаны; можно менять пару.", 1)
            return SetupResult(connection: connection, state: state, identity: deviceID, firmware: identity.firmware, suffix: "")
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
            try authenticateAgent(transport: ssh, password: password)
        }
        var arguments = [script, "--commit", remoteJournal, cid]
        if let profile = journal.installerProfile, let firmware = journal.firmwareHash, let router = journal.routerHash { arguments += [profile, firmware, router] }
        let command = "sh " + arguments.map(shellQuote).joined(separator: " ")
        let r = try ssh.run(command, input: nil, timeout: 40)
        try require(r.status == 0 && String(decoding: r.stdout, as: UTF8.self).contains("INSTALL_COMMITTED " + remoteJournal), "Установка готова, но её журнал не удалось завершить")
        journal.remoteJournal = remoteJournal; journal.phase = "complete"
    }
}
