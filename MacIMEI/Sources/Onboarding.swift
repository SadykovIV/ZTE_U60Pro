import Foundation
import Darwin

struct SetupJournal: Codable {
    var id: String
    var identity: WebIdentity
    var phase: String
    var directory: String
    var restoreRequested = false
    var installRequested = false
    var forceReinstall: Bool?
    var adbSerial: String?
    var cid: String?
    var remoteJournal: String?
    var remoteStage: String?
    var newAgent: Bool?
    var installerProfile: String?
    var firmwareHash: String?
    var routerHash: String?
    var directADBRequested: Bool?
    var directADBOutcome: String?
    var intent: String?
    var diagnosticRebootRequested: Bool?
}
/// Only these two exact layouts are resumable. Old journals without path
/// metadata keep their original staged installer once dispatch was requested.
struct SetupRemotePaths {
    static let anchor = "/data/zte-imei-studio"
    let stage: String
    let journal: String
    let dropbearKey: String

    init(id: String, installRequested: Bool, stage: String?, journal: String?) throws {
        try require(UUID(uuidString: id) != nil, "Некорректный идентификатор журнала установки")
        let oldStage = "/data/local/tmp/zte-imei-setup-" + id
        let oldJournal = "/data/local/tmp/zte-imei-installations/" + id
        let newStage = Self.anchor + "/stage-" + id
        let newJournal = Self.anchor + "/installations/" + id
        try require(stage == nil || stage == oldStage || stage == newStage,
                    "Некорректный путь журнала установки")
        try require(journal == nil || journal == oldJournal || journal == newJournal,
                    "Некорректный путь журнала установки")
        try require(!(stage == oldStage && journal == newJournal) && !(stage == newStage && journal == oldJournal),
                    "Пути журнала установки не согласованы")
        let legacy = installRequested && stage != newStage && journal != newJournal
        self.stage = legacy ? oldStage : newStage
        self.journal = legacy ? oldJournal : newJournal
        self.dropbearKey = legacy ? "/data/bin/dropbearkey" : Self.anchor + "/bin/dropbearkey"
    }

    func commitCommand(id: String, policy: [String]) -> String {
        let arguments = (["--commit", journal] + policy).map(shellQuote).joined(separator: " ")
        guard stage.hasPrefix("/data/local/tmp/zte-imei-setup-") else {
            return "sh " + shellQuote(stage + "/setup-agent.sh") + " " + arguments
        }
        let owner = ([id] + policy).joined(separator: " ")
        // A previously dispatched installer must retain its original script.
        // Validate its old parent/stage ownership before executing through FD9.
        return """
        set -eu
        fail() { printf 'INSTALL_ERROR COMMIT_STAGE_UNSAFE\\n' >&2; exit 1; }
        safe_dir() {
          test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 || fail
          mode=$(stat -c %a "$1") || fail
          case "$mode" in ''|*[!0-7]*) fail;; esac
          test "$((0$mode & 0022))" = 0 || fail
        }
        safe_file() {
          test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 && test "$(stat -c %h "$1")" = 1 || fail
        }
        for parent in /data /data/local /data/local/tmp; do safe_dir "$parent"; done
        stage=\(shellQuote(stage)); owner=\(shellQuote(owner))
        safe_dir "$stage"
        test "$(stat -c %a "$stage")" = 700 || fail
        for name in .owner .install-requested; do
          file="$stage/$name"; safe_file "$file"
          test "$(stat -c %a "$file")" = 600 && test "$(stat -c %s "$file")" = \(owner.utf8.count + 1) && test "$(cat "$file")" = "$owner" || fail
        done
        script="$stage/setup-agent.sh"; safe_file "$script"
        case "$(stat -c %a "$script")" in 600|700) ;; *) fail;; esac
        original=$(stat -c %d:%i:%u:%a:%h "$script") || fail
        exec 9<"$script" || fail
        test "$(stat -Lc %d:%i:%u:%a:%h /proc/self/fd/9)" = "$original" && test ! -L "$script" && test "$(stat -c %d:%i:%u:%a:%h "$script")" = "$original" || fail
        sh /proc/self/fd/9 \(arguments)
        """
    }
}
struct ADBAccessResult: Codable, Sendable {
    var identity: Identity
    var webIdentity: WebIdentity
    var serial: String
    var routerHash: String
}
struct BackupKeyVerification: Codable, Sendable {
    let firmware: String
    let inner: String
    let entryCount: Int
    let encryptedSHA256: String
    let directory: URL
}
struct SetupResult: Sendable {
    var connection: Connection
    var state: DeviceState?
    var identity: Identity?
    var firmware: String
    var suffix: String
}
protocol HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: ADBStreamInput?) throws -> CommandResult
}
extension HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: ADBStreamInput?) throws -> CommandResult {
        try require(input == nil, "Этот транспорт не поддерживает потоковую передачу ADB")
        return try run(executable, arguments, timeout: timeout)
    }
}
final class HostProcessRunner: HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: ADBStreamInput?) throws -> CommandResult {
        guard let input else { return try run(executable, arguments, timeout: timeout) }
        let value = try ADBStreamProcess.run(executable, arguments: arguments, input: input, timeout: timeout, maxBytes: 8 * 1024 * 1024, cancellation: ResearchCancellation())
        let result = CommandResult(status: value.status, stdout: value.stdout, stderr: value.stderr)
        guard value.outcome == "success" else { throw CommandFailure(message: "Потоковая передача ADB не подтверждена (" + value.outcome + "); повтор автоматически не выполняется", partial: result, transportOutcome: value.outcome) }
        return result
    }
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
            throw CommandFailure(message: "Инструмент настройки не завершился вовремя. Состояние сохранено; подключите модем и продолжите настройку.", partial: CommandResult(status: -1, stdout: (try? Data(contentsOf: out)) ?? Data(), stderr: (try? Data(contentsOf: err)) ?? Data()), transportOutcome: "timeout")
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
        guard result.status == 0 else { throw CommandFailure(message: "ADB не выполнил команду (локальный код \(result.status)). " + Self.errorExcerpt(result.stderr + result.stdout), partial: result) }
        return result.stdout
    }
    func devices(usbOnly: Bool = false) throws -> [String] {
        if usbOnly { return try discovery().readyUSBSerials }
        return try ADBDiscovery.parse(command(["devices", "-l"])).records.filter { $0.state == "device" }.map(\.serial)
    }
    func shell(_ serial: String, _ text: String, timeout: TimeInterval = 40) throws -> String {
        let result = try shellResult(serial, text, timeout: timeout)
        try require(result.status == 0, "Модем отклонил операцию ADB (удалённый код \(result.status)). " + Self.errorExcerpt(result.stderr + result.stdout, command: text))
        return CommandText.decode(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
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
        suffix.removeLast()
        var carriageReturns = 0
        while suffix.last == 13 && carriageReturns < 2 { suffix.removeLast(); carriageReturns += 1 }
        guard !suffix.isEmpty, suffix.count <= 3, suffix.allSatisfy({ (48...57).contains($0) }), let code = Int32(String(decoding: suffix, as: UTF8.self)), (0...255).contains(code), String(code) == String(decoding: suffix, as: UTF8.self) else {
            throw CommandFailure(message: "ADB вернул неверный удалённый код завершения", partial: result)
        }
        // Both separators are emitted by the same printf. Match its observed
        // LF/CRLF/CRCRLF convention, then remove exactly that framing. Do not
        // strip a payload's own trailing CR or normalize any payload bytes.
        let separator = Data(repeating: 13, count: carriageReturns) + Data([10])
        let end = range.lowerBound - separator.count
        guard end >= raw.startIndex, Data(raw[end..<range.lowerBound]) == separator else {
            throw CommandFailure(message: "ADB вернул несогласованный маркер результата", partial: result)
        }
        return CommandResult(status: code, stdout: Data(raw[..<end]), stderr: result.stderr)
    }
    func shellResult(_ serial: String, _ text: String, timeout: TimeInterval = 40) throws -> CommandResult {
        try require(!serial.isEmpty && serial.utf8.count <= 256 && serial.utf8.allSatisfy { (33...126).contains($0) }, "Неверный серийный номер ADB")
        let plan = try ADBShellPlan.make(text, templateURL: binary.deletingLastPathComponent().appendingPathComponent("adb-stream.sh"))
        let value = try runner.run(binary, ["-s", serial, "shell", plan.command], timeout: timeout, input: plan.input)
        return try plan.decode(value, original: text)
    }
    func identity(_ serial: String, expected: WebIdentity, skipFirmwareCheck: Bool = false) throws -> Identity {
        try identityDetails(serial, expected: expected, skipFirmwareCheck: skipFirmwareCheck).identity
    }
    func identityDetails(_ serial: String, expected: WebIdentity, skipFirmwareCheck: Bool = false) throws -> (identity: Identity, routerHash: String) {
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
        return (Identity(cid: cid, firmwareHash: firmware), router)
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
    // A firmware-family format parameter, not a device credential. The archive
    // must pass complete format and executable-template validation before use.
    private static let knownB31BackupSuffix = "zteSDX75*11Mbb2@1"
    private func resolveSuffix() -> String {
        if !backupSuffix.isEmpty { return backupSuffix }
        return Self.knownB31BackupSuffix
    }
    let backupSuffix: String
    let root: URL, resources: URL, host: String
    let currentConnection: Connection
    let web: ModemWebClient
    let runner: HostCommandRunner
    let sshFactory: ((Connection) -> RemoteTransport)?
    let update: @Sendable (String, Double) -> Void
    let researchRunner: ResearchProcessRunning
    let adbWaitAttempts: Int, directADBWaitAttempts: Int, adbPollDelay: TimeInterval
    private var lastADBFailure = ""
    let fm = FileManager.default
    var assets: URL { resources.appendingPathComponent("Onboarding") }
    var pending: URL { root.appendingPathComponent("setup-pending.json") }
    var diagnosticPending: URL { root.appendingPathComponent("adb-access-pending.json") }
    init(root: URL, resources: URL, connection: Connection, backupSuffix: String = "", web: ModemWebClient? = nil, runner: HostCommandRunner = HostProcessRunner(), sshFactory: ((Connection) -> RemoteTransport)? = nil, adbWaitAttempts: Int = 80, directADBWaitAttempts: Int = 30, adbPollDelay: TimeInterval = 3, researchRunner: ResearchProcessRunning = ResearchBoundedRunner(), update: @escaping @Sendable (String,Double)->Void = {_,_ in}) throws {
        self.researchRunner = researchRunner
        self.backupSuffix = backupSuffix
        self.root = root; self.resources = resources; self.host = connection.host; self.currentConnection = connection
        self.adbWaitAttempts = max(1, adbWaitAttempts); self.directADBWaitAttempts = max(1, directADBWaitAttempts); self.adbPollDelay = max(0, adbPollDelay)
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
        try locked { try reuseSSH(expectedIdentity: expectedIdentity, expectedIMEI: expectedIMEI) }
    }
    private func reuseSSH(expectedIdentity: Identity?, expectedIMEI: String?) throws -> SetupResult? {
        try require(!fm.fileExists(atPath: diagnosticPending.path), "Сначала завершите включение ADB для диагностики")
        try require(!fm.fileExists(atPath: pending.path), "Сначала продолжите незавершённую настройку. Журнал установки сохранён.")
        update("Проверяю существующий SSH-доступ…", 0.1)
        let expected = try DiagnosticDeviceExpectation.load(root: root, identity: expectedIdentity, web: nil, imei: expectedIMEI)
        let own = Connection(host: host, port: "2222", keyPath: root.appendingPathComponent("SSH/id_ed25519").path, knownHostsPath: root.appendingPathComponent("SSH/known_hosts").path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
        var seen = Set<String>()
        for candidate in [currentConnection, own] {
            let key = [candidate.host, candidate.port, candidate.keyPath, candidate.knownHostsPath].joined(separator: "\n")
            guard seen.insert(key).inserted else { continue }
            let ssh: RemoteTransport = sshFactory?(candidate) ?? SSHTransport(candidate)
            let first: CommandResult
            do { first = try ssh.run(SSHReadProof.command, input: nil, timeout: 15) }
            catch {
                let partial = (error as? CommandFailure).map { String(decoding: $0.partial.stderr + $0.partial.stdout, as: UTF8.self) } ?? ""
                try require(!DiagnosticTransportSelector.hostTrustFailure(error.localizedDescription + partial), "Проверка ключа SSH не пройдена. Подготовка остановлена без изменения модема.")
                continue
            }
            let detail = String(decoding: first.stderr + first.stdout, as: UTF8.self)
            try require(!DiagnosticTransportSelector.hostTrustFailure(detail), "Проверка ключа SSH не пройдена. Подготовка остановлена без изменения модема.")
            if first.status == 255 || first.status == -1 { continue }
            try require(first.status == 0, "Не удалось проверить существующий сеанс SSH")
            let proof = try SSHReadProof.parse(first.stdout)
            try require(proof.matches(expected), "SSH подключён к другому модему; подготовка остановлена")
            let second = try ssh.run(SSHReadProof.command, input: nil, timeout: 15)
            try require(second.status == 0, "Повторная проверка SSH не завершена")
            try proof.verify(SSHReadProof.parse(second.stdout))
            update("SSH проверен. Готовность агента и IMEI проверяются отдельно.", 1)
            return SetupResult(connection: candidate, state: nil, identity: proof.identity, firmware: "unknown", suffix: "")
        }
        return nil
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
        let engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: sshFactory?(connection))
        let (identity, boot) = try engine.accessIdentity()
        _ = try Self.installerProfile(web: expected, device: identity, experimental: currentConnection.skipFirmwareCheck)
        let info = try engine.remote("set -e; test \"$(id -u)\" = 0; test \"$(uname -m)\" = aarch64; test \"$(sha256sum /usr/bin/diag-router | cut -d ' ' -f1)\" = " + shellQuote(ModemEngine.routerHash) + "; ubus call zwrt_web device_info '{}'")
        guard let object = try JSONSerialization.jsonObject(with: info) as? [String: Any] else { throw IMEIError.message("Неполная идентификация SSH после установки") }
        try require(try WebIdentity(object, skipFirmwareCheck: true) == expected, "SSH-модем и устройство веб-интерфейса различаются")
        let proof = try engine.text("set -e; found=0; for p in $(pidof zte-agent); do if test \"$(readlink /proc/$p/exe)\" = /data/zte-agent; then found=1; fi; done; test \"$found\" = 1; printf AGENT_READY")
        try require(proof == "AGENT_READY", "Агент установлен, но не запущен")
        try authenticateAgent(transport: engine.transport, password: password)
        let after = try engine.accessIdentity()
        try require(after.0 == identity && after.1 == boot, "Во время проверки доступа изменился модем, прошивка или загрузка")
        return (identity, nil)
    }
    func authenticateAgent(transport: RemoteTransport, password: String) throws {
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
        anchor=/data/zte-imei-studio
        if test ! -e "$anchor" && test ! -L "$anchor"; then mkdir -m 700 "$anchor"; fi
        safe_dir "$anchor"
        test "$(stat -c %a "$anchor")" = 700 || fail MODE
        case "$stage" in "$anchor"/stage-*) suffix=${stage#"$anchor"/stage-};; *) fail PATH;; esac
        test -n "$suffix" || fail PATH
        case "$suffix" in *[!a-fA-F0-9-]*) fail PATH;; esac
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
    func pushStaged(_ adb: ADBClient, serial: String, source: URL, stage: String, name: String, owner: String) throws {
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
    private func findADB(_ adb: ADBClient, expected: WebIdentity, tolerateInventoryFailure: Bool = false, enforceInstallerPolicy: Bool = false) throws -> (String, Identity)? {
        let discovery: ADBDiscovery
        do { discovery = try adb.discovery() }
        catch {
            lastADBFailure = ActivityJournal.sanitize(error.localizedDescription)
            if !tolerateInventoryFailure { throw IMEIError.message("Не удалось проверить USB ADB на компьютере. " + lastADBFailure + " Включение ADB и восстановление не запускались.") }
            return nil
        }
        lastADBFailure = discovery.explanation
        var matches: [(String, Identity)] = [], failures = [String]()
        for serial in discovery.readyUSBSerials {
            let proof: (identity: Identity, routerHash: String)
            do { proof = try adb.identityDetails(serial, expected: expected, skipFirmwareCheck: true) }
            catch { failures.append(ActivityJournal.sanitize(error.localizedDescription)); continue }
            // Usable root ADB on the correct modem must not trigger another
            // activation attempt just because installation policy rejects it.
            if enforceInstallerPolicy {
                try require(proof.routerHash == ModemEngine.routerHash, "ADB уже работает и модем подтверждён, но версия diag-router не поддерживается установщиком. Повторное включение ADB и восстановление не запускались.")
                try require(currentConnection.skipFirmwareCheck || proof.identity.firmwareHash == ModemEngine.firmwareHash, "ADB уже работает и модем подтверждён, но хэш прошивки отличается от проверенной B31. Повторное включение ADB и восстановление не запускались.")
            }
            matches.append((serial, proof.identity))
        }
        try require(matches.count <= 1, "Найдено несколько одинаковых модемов. Оставьте подключённым только нужный")
        if matches.isEmpty && !failures.isEmpty { lastADBFailure = "USB ADB обнаружен, но проверка root и идентичности не пройдена: " + failures.prefix(3).joined(separator: "; ") }
        return matches.first
    }
    private func pollADB(_ adb: ADBClient, expected: WebIdentity, attempts: Int, enforceInstallerPolicy: Bool = false) throws -> (String, Identity)? {
        let deadline = Date().addingTimeInterval(Double(attempts) * adbPollDelay)
        for attempt in 0..<attempts {
            if attempt > 0 && adbPollDelay > 0 && Date() >= deadline { break }
            if let match = try findADB(adb, expected: expected, tolerateInventoryFailure: true, enforceInstallerPolicy: enforceInstallerPolicy) { update("USB ADB подтверждён: root, ARM64 и идентичность модема проверены.", 0.5); return match }
            if attempt % 5 == 0 { update("Ожидаю USB ADB. " + lastADBFailure, 0.48) }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: adbPollDelay == 0 ? 0 : max(0, min(adbPollDelay, deadline.timeIntervalSinceNow))) }
        }
        return nil
    }
    func waitADB(_ adb: ADBClient, expected: WebIdentity, enforceInstallerPolicy: Bool = false) throws -> (String, Identity) {
        if let match = try pollADB(adb, expected: expected, attempts: adbWaitAttempts, enforceInstallerPolicy: enforceInstallerPolicy) { return match }
        throw IMEIError.message("Работающий ADB модема не подтверждён. " + lastADBFailure + " Повторное восстановление бэкапа автоматически не запускается.")
    }
    static func agentStartup(password: String, discovery: Bool = false, discoveryHost: String? = nil) throws -> Data {
        try require(!password.isEmpty && !password.contains("\0"), "Неверный пароль")
        var mode = ""
        if discovery {
            guard let host = discoveryHost else { throw IMEIError.message("Для discovery нужен выбранный IPv4-адрес") }
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            try require(parts.count == 4 && parts.allSatisfy { p in guard let n = UInt8(p) else { return false }; return String(n) == p } && host != "0.0.0.0" && host != "255.255.255.255", "Некорректный адрес discovery")
            mode = "export ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND=" + shellQuote(host + ":9090") + "\n"
        }
        return Data(("#!/bin/sh\nexport ZTE_AGENT_PASSWORD=" + shellQuote(password) + "\n" + mode + "unset ZTE_AGENT_PIN\ntrap '' HUP\nnohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &\n").utf8)
    }
    func prepare(password: String, expectedIMEI: String? = nil) throws -> (WebIdentity, BackupPatch.Result, URL) {
        let (identity, encrypted, directory) = try prepareRawBackup(password: password, expectedIMEI: expectedIMEI)
        let result = try BackupPatch.prepare(encrypted: encrypted, imei: identity.imei, suffix: resolveSuffix())
        try savePatchManifest(result, directory: directory)
        return (identity, result, directory)
    }
    func verifyBackupKey(password: String) throws -> BackupKeyVerification {
        // Only a host-side lease: reading a backup does not grant or reuse a
        // pending mutation's permissions. No ADB/helper resources are loaded.
        let fd = open(root.appendingPathComponent("operation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Не удалось создать блокировку приложения"); defer { close(fd) }
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "Другая операция приложения ещё выполняется"); defer { flock(fd, LOCK_UN) }
        let (identity, encrypted, directory) = try prepareRawBackup(password: password, expectedIMEI: nil, folder: "BackupKeyChecks")
        let suffix = resolveSuffix()
        try require(!suffix.isEmpty && suffix.utf8.count <= 128 && !suffix.contains("\0"), "Некорректный Backup-key suffix")
        let entryCount: Int
        do {
            let decrypted = try BackupCipher.decrypt(encrypted, password: identity.imei + suffix)
            entryCount = try BackupPatch.inspect(decrypted).inner.members.count
        } catch {
            throw IMEIError.message("Не удалось подтвердить ключ и формат этого бэкапа. Кандидат ключа может не подходить или архив повреждён. Совместимость записи не проверялась.")
        }
        let result = BackupKeyVerification(firmware: identity.firmware, inner: identity.inner,
            entryCount: entryCount, encryptedSHA256: digest(encrypted), directory: directory)
        try saveJSON(result, directory.appendingPathComponent("verification.json"))
        try saveJSON(["encryptedSHA256": result.encryptedSHA256, "suffixVerified": "true", "formatVerified": "true", "operation": "read-only-key-check"], directory.appendingPathComponent("manifest.json"))
        update("Ключ и формат бэкапа подтверждены. Восстановление, ADB и установка не запускались.", 1)
        return result
    }
    private func savePatchManifest(_ result: BackupPatch.Result, directory: URL) throws {
        try saveJSON(["encryptedSHA256":result.originalHash, "patchedSHA256":result.patchedHash, "suffixVerified":"true", "adbAlreadyEnabled":String(result.alreadyEnabled)], directory.appendingPathComponent("manifest.json"))
        update("Ключ расшифровки бэкапа проверен.", 0.25)
    }
    private func prepareWebIdentity(password: String, expectedIMEI: String?) throws -> WebIdentity {
        update("Вхожу в веб-интерфейс…", 0.05); try web.login(password: password)
        let identity = try web.identity(skipFirmwareCheck: true)
        try require(expectedIMEI == nil || identity.imei == expectedIMEI, "Веб-интерфейс относится к другому модему; подготовка остановлена до резервного копирования")
        return identity
    }
    private func prepareRawBackup(password: String, expectedIMEI: String?, folder: String = "SetupBackups") throws -> (WebIdentity, Data, URL) {
        let identity = try prepareWebIdentity(password: password, expectedIMEI: expectedIMEI)
        let (encrypted, directory) = try captureRawBackup(identity: identity, folder: folder)
        return (identity, encrypted, directory)
    }
    private func backupContext(identity: WebIdentity, folder: String) throws -> URL {
        let directory = root.appendingPathComponent(folder + "/" + UUID().uuidString.lowercased())
        try secureDirectory(directory)
        try saveJSON(identity, directory.appendingPathComponent("identity.json"))
        return directory
    }
    private func captureRawBackup(identity: WebIdentity, folder: String = "SetupBackups", destination: URL? = nil) throws -> (Data, URL) {
        update("Сохраняю свежий бэкап настроек…", 0.12)
        let encrypted = try web.freshBackup()
        try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство изменилось во время подготовки бэкапа")
        let directory = destination ?? root.appendingPathComponent(folder + "/" + UUID().uuidString.lowercased()); try secureDirectory(directory)
        try savePrivate(encrypted, directory.appendingPathComponent("back_parameter.original"))
        try saveJSON(identity, directory.appendingPathComponent("identity.json"))
        try saveJSON(["encryptedSHA256": digest(encrypted), "suffixVerified": "false"], directory.appendingPathComponent("manifest.json"))
        return (encrypted, directory)
    }
    private func ensureADB(_ adb: ADBClient, identity: WebIdentity, initialMatch: (String, Identity)?, expected: DiagnosticDeviceExpectation,
                           journal: inout SetupJournal, journalURL: URL, encryptedBackup: Data?, webPassword: String,
                           backupFolder: String = "SetupBackups", enforceInstallerPolicy: Bool = false, directPollCompleted: Bool = false) throws -> (String, Identity) {
        var match = initialMatch
        if match == nil && !journal.restoreRequested && !journal.installRequested && journal.diagnosticRebootRequested != true {
            var fallbackBackup = encryptedBackup
            try require(expected.cids.isEmpty || !expected.imeis.isEmpty, "Веб-интерфейс не сообщает CID. Для включения ADB сначала подтвердите связь ожидаемого CID и IMEI либо подключите уже работающий USB ADB.")
            if journal.directADBRequested != true {
                var advertised: Bool?
                do { advertised = try web.advertisesDirectADB() }
                catch { update("Список USB-возможностей недоступен: " + ActivityJournal.sanitize(error.localizedDescription), 0.27) }
                if advertised != false {
                    try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство изменилось перед включением ADB")
                    journal.directADBRequested = true; journal.directADBOutcome = "requested"; journal.phase = "direct-adb-requested"; try saveJSON(journal, journalURL)
                    update("Пробую штатный USB debug через zwrt_bsp.usb.set; затем проверю root ADB…", 0.3)
                    do { try web.enableDirectADB(); journal.directADBOutcome = "accepted" }
                    catch let error as ModemWebError {
                        if case .rpcRejected = error { journal.directADBOutcome = "rejected" }
                        else { journal.directADBOutcome = "uncertain" }
                        update("Результат штатного включения ADB: " + ActivityJournal.sanitize(error.localizedDescription), 0.32)
                    } catch { journal.directADBOutcome = "uncertain"; update("Ответ USB debug не получен; проверяю ADB без повторной отправки команды.", 0.32) }
                    try saveJSON(journal, journalURL)
                } else { update("Штатный USB debug не объявлен этой прошивкой. Проверяю следующий способ.", 0.3) }
            }
            if journal.directADBRequested == true {
                update("Проверяю ADB после штатного USB debug (" + (journal.directADBOutcome ?? "uncertain") + "). Команда повторно не отправляется.", 0.34)
                if !directPollCompleted { match = try pollADB(adb, expected: identity, attempts: directADBWaitAttempts, enforceInstallerPolicy: enforceInstallerPolicy) }
                if match == nil {
                    // A USB switch can drop HTTP. Never upload/restore into an
                    // unknown or still rebooting target after an uncertain reply.
                    try web.login(password: webPassword)
                    try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство не подтверждено после USB debug; восстановление не запускалось")
                    let (freshBackup, freshDirectory) = try captureRawBackup(identity: identity, folder: backupFolder, destination: URL(fileURLWithPath: journal.directory))
                    fallbackBackup = freshBackup; journal.directory = freshDirectory.path; try saveJSON(journal, journalURL)
                }
            }
            if match == nil {
                if fallbackBackup == nil {
                    let (fresh, directory) = try captureRawBackup(identity: identity, folder: backupFolder, destination: URL(fileURLWithPath: journal.directory))
                    fallbackBackup = fresh; journal.directory = directory.path
                    try saveJSON(journal, journalURL)
                }
                let patch = try BackupPatch.prepare(encrypted: fallbackBackup!, imei: identity.imei, suffix: resolveSuffix())
                try savePatchManifest(patch, directory: URL(fileURLWithPath: journal.directory))
                if !patch.alreadyEnabled {
                    try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство изменилось перед включением ADB")
                    try savePrivate(patch.patchedEncrypted, URL(fileURLWithPath: journal.directory).appendingPathComponent("back_parameter.adb-only"))
                    update("Включаю ADB через проверенный бэкап. Модем перезагрузится…", 0.35)
                    try web.upload(patch.patchedEncrypted)
                    try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство изменилось перед восстановлением")
                    journal.restoreRequested = true; journal.phase = "restore-requested"; try saveJSON(journal, journalURL)
                    do { try web.restore() } catch { update("Связь при восстановлении прервалась; проверяю появление ADB без повторной отправки…", 0.4) }
                } else if journal.intent == "diagnostic-adb" {
                    try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство изменилось перед включением ADB")
                    journal.diagnosticRebootRequested = true; journal.phase = "diagnostic-reboot-requested"; try saveJSON(journal, journalURL)
                    update("ADB уже прописан в загрузке. Перезагружаю модем один раз для применения USB ADB…", 0.4)
                    do { try web.rebootForADB() }
                    catch { update("Ответ перезагрузки не получен; проверяю USB ADB без повторной отправки…", 0.42) }
                } else { update("В бэкапе ADB уже включён, но runtime-доступ не подтверждён. " + lastADBFailure, 0.4) }
            }
        }
        if match == nil { match = try waitADB(adb, expected: identity, enforceInstallerPolicy: enforceInstallerPolicy) }
        return match!
    }
    /// This operation only establishes a verified USB diagnostic channel. It
    /// deliberately never consults SSH readiness or invokes the installer.
    func enableDiagnosticADB(webPassword: String, expectedIdentity: Identity? = nil, expectedIMEI: String? = nil) throws -> ADBAccessResult {
        try locked {
            try require(!fm.fileExists(atPath: pending.path), "Сначала завершите предварительную подготовку модема")
            let expected = try DiagnosticDeviceExpectation.load(root: root, identity: expectedIdentity, web: nil, imei: expectedIMEI)
            let hashes = try readJSON([String: String].self, assets.appendingPathComponent("SHA256.json"))
            try require(hashes["adb"] == digest(Data(contentsOf: assets.appendingPathComponent("adb"))), "Повреждён встроенный компонент настройки: adb")
            let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
            var journal: SetupJournal?
            if fm.fileExists(atPath: diagnosticPending.path) {
                let saved = try readJSON(SetupJournal.self, diagnosticPending)
                let directory = URL(fileURLWithPath: saved.directory).standardizedFileURL
                try require(saved.intent == "diagnostic-adb" && !saved.installRequested && UUID(uuidString: saved.id) != nil &&
                            directory.deletingLastPathComponent() == root.appendingPathComponent("ADBAccessBackups").standardizedFileURL && UUID(uuidString: directory.lastPathComponent) != nil,
                            "Некорректный журнал включения ADB для диагностики")
                journal = saved
            }
            let identity: WebIdentity
            if let journal { identity = journal.identity }
            else {
                try require(!webPassword.isEmpty && !webPassword.contains("\0"), "Введите пароль веб-интерфейса")
                update("Диагностика ADB: проверяю устройство через штатный Web…", 0.05)
                try web.login(password: webPassword)
                identity = try web.identity(skipFirmwareCheck: true)
            }
            try require(expected.imeis.isEmpty || expected.imeis.contains(identity.imei), "Веб-интерфейс относится к другому модему; включение ADB остановлено")
            func validate(_ device: Identity) throws {
                try require(expected.cids.isEmpty || expected.cids.contains(device.cid), "CID отличается от ожидаемого модема или незавершённой установки")
                if let expectedIdentity { try require(device == expectedIdentity, "Прошивка ожидаемого модема изменилась; включение ADB остановлено") }
                if let cid = journal?.cid { try require(device.cid == cid, "CID отличается от незавершённого включения ADB") }
            }
            var match = try findADB(adb, expected: identity, enforceInstallerPolicy: false)
            let resumeDirect = journal?.directADBRequested == true && journal?.restoreRequested != true && journal?.diagnosticRebootRequested != true
            if match == nil && resumeDirect {
                update("Проверяю ADB после штатного USB debug (" + (journal?.directADBOutcome ?? "uncertain") + "). Команда повторно не отправляется.", 0.34)
                match = try pollADB(adb, expected: identity, attempts: directADBWaitAttempts, enforceInstallerPolicy: false)
            }
            if let match { try validate(match.1) }
            if match == nil {
                let encrypted: Data? = nil
                if journal?.restoreRequested != true && journal?.diagnosticRebootRequested != true {
                    try require(!webPassword.isEmpty && !webPassword.contains("\0"), "Введите пароль веб-интерфейса")
                    try web.login(password: webPassword)
                    try require(try web.identity(skipFirmwareCheck: true) == identity, "Устройство изменилось перед включением ADB")
                    try require(expected.cids.isEmpty || !expected.imeis.isEmpty, "Веб-интерфейс не сообщает CID. Для включения ADB сначала подтвердите связь ожидаемого CID и IMEI либо подключите уже работающий USB ADB.")
                    let directory = try backupContext(identity: identity, folder: "ADBAccessBackups")
                    if journal == nil {
                        journal = SetupJournal(id: UUID().uuidString.lowercased(), identity: identity, phase: "prepared", directory: directory.path, cid: expected.cids.first, intent: "diagnostic-adb")
                    } else { journal!.directory = directory.path }
                    try saveJSON(journal!, diagnosticPending)
                }
                var current = journal!
                defer { journal = current }
                match = try ensureADB(adb, identity: identity, initialMatch: nil, expected: expected, journal: &current,
                                      journalURL: diagnosticPending, encryptedBackup: encrypted, webPassword: webPassword,
                                      backupFolder: "ADBAccessBackups", enforceInstallerPolicy: false, directPollCompleted: resumeDirect)
            }
            let (serial, device) = match!
            try validate(device)
            let first = try adb.identityDetails(serial, expected: identity, skipFirmwareCheck: true)
            let second = try adb.identityDetails(serial, expected: identity, skipFirmwareCheck: true)
            try require(first.identity == device && second.identity == device && first.routerHash == second.routerHash,
                        "Устройство или прошивка изменились во время проверки ADB")
            let result = ADBAccessResult(identity: device, webIdentity: identity, serial: serial, routerHash: first.routerHash)
            if var journal {
                journal.phase = "complete"; journal.cid = device.cid; journal.adbSerial = serial; journal.firmwareHash = device.firmwareHash; journal.routerHash = first.routerHash
                try saveJSON(result, URL(fileURLWithPath: journal.directory).appendingPathComponent("adb-access-result.json"))
                try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("adb-access-journal.json"))
                try fm.removeItem(at: diagnosticPending)
            }
            update("ADB готов для диагностики. Агент и параметры SSH не изменялись.", 1)
            return result
        }
    }
    /// Compatibility entry point whose caller explicitly supplies one password
    /// for both services. New UI flows pass the two credentials separately.
    func run(password: String) throws -> SetupResult { try run(webPassword: password, agentPassword: password) }
    static let rollbackRestoredMessage = "Предыдущая принудительная подготовка отменена; исходное состояние подтверждено. Повторите подготовку, чтобы начать новую попытку."
    /// Only the bundled read-only verifier can release a failed forced intent.
    /// A state file or a lost apply response alone is never proof of rollback.
    func reconcileForcedRollback(_ adb: ADBClient, serial: String, paths: SetupRemotePaths, id: String,
                                 policy: [String], directory: URL) throws {
        try require(paths.stage == SetupRemotePaths.anchor + "/stage-" + id,
                    "Откат незавершённой установки не подтверждён")
        let original = try Data(contentsOf: pending)
        let installer = try String(contentsOf: assets.appendingPathComponent("setup-agent.sh"), encoding: .utf8)
        let arguments = ["--verify-rollback", paths.journal] + policy
        let output = try adb.shell(serial, "sh -c " + shellQuote(installer) + " -- " + arguments.map(shellQuote).joined(separator: " "), timeout: 60)
        try require(output == "INSTALL_ROLLBACK_VERIFIED " + paths.journal && (try Data(contentsOf: pending)) == original,
                    "Откат незавершённой установки не подтверждён")
        try savePrivate(original, directory.appendingPathComponent("setup-rolled-back.json"))
        try savePrivate(Data((output + "\n").utf8), directory.appendingPathComponent("rollback-verification.txt"))
        try fm.removeItem(at: pending)
    }
    func run(webPassword: String, agentPassword: String, expectedIdentity: Identity? = nil, expectedIMEI: String? = nil, forceReinstall: Bool = false) throws -> SetupResult {
        try locked {
            try require(!fm.fileExists(atPath: diagnosticPending.path), "Сначала завершите включение ADB для диагностики")
            if !forceReinstall && !fm.fileExists(atPath: pending.path), let reused = try reuseSSH(expectedIdentity: expectedIdentity, expectedIMEI: expectedIMEI) { return reused }
            let expected = try DiagnosticDeviceExpectation.load(root: root, identity: expectedIdentity, web: nil, imei: expectedIMEI)
            func validateExpectedDevice(_ device: Identity) throws {
                try require(expected.cids.isEmpty || expected.cids.contains(device.cid), "CID отличается от ожидаемого модема или незавершённой установки")
                if let expectedIdentity { try require(device == expectedIdentity, "Прошивка ожидаемого модема изменилась; подготовка остановлена") }
            }
            let hashes = try verifyAssets()
            if let access = try runExistingUSBAccess(hashes: hashes, webPassword: webPassword, agentPassword: agentPassword, expected: expected, expectedIdentity: expectedIdentity, forceReinstall: forceReinstall) { return access }
            // A previously dispatched restore needs no new Web authentication
            // once the same modem has returned as verified root USB ADB.
            if fm.fileExists(atPath: pending.path), var prior = try? readJSON(SetupJournal.self, pending),
               prior.intent == nil, prior.restoreRequested, !prior.installRequested {
                let directory = URL(fileURLWithPath: prior.directory).standardizedFileURL
                _ = try SetupRemotePaths(id: prior.id, installRequested: false, stage: prior.remoteStage, journal: prior.remoteJournal)
                try require(["restore-requested", "adb-ready"].contains(prior.phase) &&
                            directory.deletingLastPathComponent() == root.appendingPathComponent("SetupBackups").standardizedFileURL &&
                            UUID(uuidString: directory.lastPathComponent) != nil,
                            "Некорректный журнал подтверждённого ADB; установка не запускалась")
                let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
                if let (serial, device) = try findADB(adb, expected: prior.identity) {
                    try validateExpectedDevice(device)
                    let fresh = try adb.identityDetails(serial, expected: prior.identity, skipFirmwareCheck: true)
                    try require(fresh.identity == device && (prior.cid == nil || prior.cid == device.cid) &&
                                (prior.firmwareHash == nil || prior.firmwareHash == device.firmwareHash) &&
                                (prior.routerHash == nil || prior.routerHash == fresh.routerHash),
                                "Подтверждённый ADB относится к другому устройству; установка не запускалась")
                    prior.phase = "adb-ready"; prior.cid = device.cid; prior.adbSerial = serial
                    prior.firmwareHash = device.firmwareHash; prior.routerHash = fresh.routerHash
                    try saveJSON(prior, pending)
                    let bound = try DiagnosticDeviceExpectation.load(root: root, identity: device, web: prior.identity)
                    guard let result = try runExistingUSBAccess(hashes: hashes, webPassword: "", agentPassword: agentPassword,
                        expected: bound, expectedIdentity: device, completedBootstrapID: prior.id, forceReinstall: forceReinstall) else {
                        throw IMEIError.message("Для продолжения установки нужен тот же USB ADB; новая установка не запускалась")
                    }
                    return result
                }
            }
            try require(!agentPassword.isEmpty && !agentPassword.contains("\0"), "Введите отдельный пароль агента")
            try require(!webPassword.isEmpty && !webPassword.contains("\0"), "Для включения ADB через штатный Web нужен его пароль")
            let identity = try prepareWebIdentity(password: webPassword, expectedIMEI: expected.imeis.first)
            let directory = try backupContext(identity: identity, folder: "SetupBackups")
            var journal: SetupJournal
            if fm.fileExists(atPath: pending.path) {
                journal = try readJSON(SetupJournal.self, pending)
                _ = try SetupRemotePaths(id: journal.id, installRequested: journal.installRequested, stage: journal.remoteStage, journal: journal.remoteJournal)
                try require(journal.identity == identity && UUID(uuidString: journal.id) != nil, "Незавершённая настройка относится к другому устройству")
                let savedDirectory = URL(fileURLWithPath: journal.directory).standardizedFileURL
                try require(savedDirectory.deletingLastPathComponent() == root.appendingPathComponent("SetupBackups").standardizedFileURL && UUID(uuidString: savedDirectory.lastPathComponent) != nil, "Некорректный путь бэкапа незавершённой настройки")
                if !journal.restoreRequested && !journal.installRequested { journal.directory = directory.path; try saveJSON(journal, pending) }
            } else {
                journal = SetupJournal(id: UUID().uuidString.lowercased(), identity: identity, phase: "prepared", directory: directory.path)
                journal.forceReinstall = forceReinstall
                try saveJSON(journal, pending)
            }
            // Existing verified SSH+agent is sufficient; do not restore a backup just to enable ADB again.
            let own = Connection(host: host, port: "2222", keyPath: root.appendingPathComponent("SSH/id_ed25519").path, knownHostsPath: root.appendingPathComponent("SSH/known_hosts").path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
            for candidate in [own, currentConnection] where journal.forceReinstall != true {
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
                    update("SSH и агент доступны. Совместимость операций с NV проверяется отдельно.", 1)
                    return SetupResult(connection: candidate, state: state, identity: deviceID, firmware: identity.firmware, suffix: "")
                }
            }
            let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
            let initialMatch = try findADB(adb, expected: identity)
            if let initialMatch { try validateExpectedDevice(initialMatch.1) }
            let (serial, deviceID) = try ensureADB(adb, identity: identity, initialMatch: initialMatch, expected: expected,
                                                 journal: &journal, journalURL: pending, encryptedBackup: nil, webPassword: webPassword)
            try validateExpectedDevice(deviceID)
            let fresh = try adb.identityDetails(serial, expected: identity, skipFirmwareCheck: true)
            try require(fresh.identity == deviceID, "USB-устройство изменилось после включения ADB")
            let legacyProfile = try? Self.installerProfile(web: identity, device: deviceID, experimental: currentConnection.skipFirmwareCheck)
            if legacyProfile == nil || fresh.routerHash != ModemEngine.routerHash {
                // Activation is complete only after verified USB readiness. Its
                // history stays in the original backup directory. Installation
                // then uses the existing measured generic-access transaction.
                try require(!journal.installRequested, "Незавершённая установка требует исходного профиля; новая установка не запускалась")
                if let cid = journal.cid { try require(cid == deviceID.cid, "CID отличается от незавершённой установки") }
                journal.phase = "adb-ready"; journal.cid = deviceID.cid; journal.adbSerial = serial
                journal.firmwareHash = deviceID.firmwareHash; journal.routerHash = fresh.routerHash
                try saveJSON(journal, pending)
                let bound = try DiagnosticDeviceExpectation.load(root: root, identity: deviceID, web: identity)
                guard let result = try runExistingUSBAccess(hashes: hashes, webPassword: webPassword, agentPassword: agentPassword, expected: bound, expectedIdentity: deviceID, completedBootstrapID: journal.id, forceReinstall: forceReinstall) else {
                    throw IMEIError.message("USB ADB был подтверждён, но сейчас недоступен. Восстановление автоматически не повторяется.")
                }
                return result
            }
            let profile = legacyProfile!
            if let cid = journal.cid { try require(cid == deviceID.cid, "CID отличается от незавершённой установки") }
            if let previous = journal.installerProfile { try require(previous == profile && journal.firmwareHash == deviceID.firmwareHash && journal.routerHash == ModemEngine.routerHash, "Профиль прошивки изменился после начала установки") }
            journal.cid = deviceID.cid; journal.adbSerial = serial
            let paths = try SetupRemotePaths(id: journal.id, installRequested: journal.installRequested, stage: journal.remoteStage, journal: journal.remoteJournal)
            if journal.installRequested {
                let remoteJournal = paths.journal
                let phase = try adb.shell(serial, "cat " + shellQuote(remoteJournal + "/state"))
                if phase == "rolled-back" && journal.forceReinstall == true {
                    try reconcileForcedRollback(adb, serial: serial, paths: paths, id: journal.id,
                        policy: [deviceID.cid, profile, deviceID.firmwareHash, ModemEngine.routerHash], directory: URL(fileURLWithPath: journal.directory))
                    throw IMEIError.message(Self.rollbackRestoredMessage)
                }
                try require(phase == "ready" || phase == "complete", "Предыдущая установка прервалась до готовности. Журнал сохранён: " + remoteJournal)
                let key = root.appendingPathComponent("SSH/id_ed25519")
                try require(fm.fileExists(atPath: key.path), "Отсутствует собственный ключ незавершённой установки")
                let connection = try pinSSH(adb: adb, serial: serial, expected: identity, deviceID: deviceID, key: key, dropbearKey: paths.dropbearKey)
                let (sshIdentity, state) = try inspectSetupSSH(connection, expected: identity, password: agentPassword)
                try require(sshIdentity == deviceID, "SSH CID отличается от проверенного USB-модема")
                journal.remoteJournal = remoteJournal
                try commitIfReady(journal: &journal, connection: connection, password: agentPassword)
                try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
                update("Установка доступа завершена. Совместимость операций с NV проверяется отдельно.", 1)
                return SetupResult(connection: connection, state: state, identity: deviceID, firmware: identity.firmware, suffix: "")
            }
            let installer = try String(contentsOf: assets.appendingPathComponent("setup-agent.sh"), encoding: .utf8)
            let policyArguments = [deviceID.cid, profile, deviceID.firmwareHash, ModemEngine.routerHash]
            let installFlags = journal.forceReinstall == true ? ["--reinstall"] : []
            update(profile == "b31" ? "Проверяю условия установки для B31…" : "Проверяю условия экспериментальной установки доступа для B02…", 0.55)
            let preflight = try adb.shell(serial, "sh -c " + shellQuote(installer) + " -- " + (installFlags + ["--preflight"] + policyArguments).map(shellQuote).joined(separator: " "), timeout: 60)
            try require(preflight == "INSTALL_PREFLIGHT " + profile + " imei_config=unknown", "Установщик не подтвердил предварительную проверку этой прошивки")
            journal.installerProfile = profile; journal.firmwareHash = deviceID.firmwareHash; journal.routerHash = ModemEngine.routerHash
            try saveJSON(journal, pending)
            let key = try createKey(), pub = key.appendingPathExtension("pub"), publicData = try Data(contentsOf: pub)
            let stage = paths.stage
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
            journal.remoteStage = paths.stage; journal.remoteJournal = paths.journal
            journal.installRequested = true; journal.phase = "install-requested"; try saveJSON(journal, pending)
            _ = try adb.shell(serial, "set -eu; umask 077; set -C; printf '%s\\n' " + shellQuote(owner) + " > " + shellQuote(stage + "/.install-requested"))
            let arguments = [stage + "/setup-agent.sh"] + installFlags + [stage, deviceID.cid, hashes["zte-agent"]!, hashes["dropbear"]!, digest(publicData), profile, deviceID.firmwareHash, ModemEngine.routerHash]
            let installOutput: String
            do { installOutput = try adb.shell(serial, "sh " + arguments.map(shellQuote).joined(separator: " "), timeout: 100) }
            catch {
                if journal.forceReinstall == true,
                   (try? reconcileForcedRollback(adb, serial: serial, paths: paths, id: journal.id, policy: policyArguments, directory: URL(fileURLWithPath: journal.directory))) != nil {
                    throw IMEIError.message(Self.rollbackRestoredMessage)
                }
                throw error
            }
            try savePrivate(Data(installOutput.utf8), URL(fileURLWithPath: journal.directory).appendingPathComponent("installation.log"))
            guard let ready = installOutput.split(separator: "\n").first(where: { $0.hasPrefix("INSTALL_READY ") }) else { throw IMEIError.message("Установщик не подтвердил готовность") }
            let remoteJournal = String(ready.dropFirst("INSTALL_READY ".count))
            try require(remoteJournal == paths.journal, "Неожиданный путь журнала установщика")
            journal.remoteJournal = remoteJournal; journal.newAgent = installOutput.split(separator: "\n").contains("INSTALL_AGENT new"); journal.phase = "ready"; try saveJSON(journal, pending)
            let connection = try pinSSH(adb: adb, serial: serial, expected: identity, deviceID: deviceID, key: key, dropbearKey: paths.dropbearKey)
            update(profile == "b31" ? "Проверяю SSH, агент и чтение IMEI…" : "Проверяю SSH, идентичность модема и вход в агент…", 0.88)
            let (sshIdentity, state) = try inspectSetupSSH(connection, expected: identity, password: agentPassword)
            try require(sshIdentity == deviceID, "После установки подключён другой модем")
            try commitIfReady(journal: &journal, connection: connection, password: agentPassword)
            try saveJSON(journal, URL(fileURLWithPath: journal.directory).appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
            // Credentials in this owned staging directory are no longer needed. Device recovery snapshots remain private.
            _ = try? adb.shell(serial, "rm -f " + ["zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh","id_ed25519.pub","start-agent.sh","legacy-agent.private.sh",".owner",".install-requested"].map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage))
            update("SSH и агент настроены. Совместимость операций с NV проверяется отдельно.", 1)
            return SetupResult(connection: connection, state: state, identity: deviceID, firmware: identity.firmware, suffix: "")
        }
    }
    func pinSSH(adb: ADBClient, serial: String, expected: WebIdentity, deviceID: Identity, key: URL, dropbearKey: String) throws -> Connection {
        try require(try adb.identity(serial, expected: expected, skipFirmwareCheck: currentConnection.skipFirmwareCheck) == deviceID, "CID изменился перед чтением SSH host key")
        let publicHost = try adb.shell(serial, shellQuote(dropbearKey) + " -y -f /etc/dropbear/dropbear_ed25519_host_key")
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
        let paths = try SetupRemotePaths(id: journal.id, installRequested: journal.installRequested, stage: journal.remoteStage, journal: journal.remoteJournal)
        let remoteJournal = paths.journal
        let ssh: RemoteTransport = sshFactory?(connection) ?? SSHTransport(connection)
        if journal.newAgent == nil {
            let query = try ssh.run("if test -f " + shellQuote(remoteJournal + "/present/data_zte-agent") + "; then printf EXISTING; else printf NEW; fi", input: nil, timeout: 15)
            try require(query.status == 0, "Не удалось проверить происхождение установленного агента")
            journal.newAgent = query.stdout == Data("NEW".utf8)
        }
        if journal.newAgent == true {
            try authenticateAgent(transport: ssh, password: password)
        }
        var policy = [cid]
        if let profile = journal.installerProfile, let firmware = journal.firmwareHash, let router = journal.routerHash { policy += [profile, firmware, router] }
        let command = paths.commitCommand(id: journal.id, policy: policy)
        let r = try ssh.run(command, input: nil, timeout: 40)
        try require(r.status == 0 && String(decoding: r.stdout, as: UTF8.self).contains("INSTALL_COMMITTED " + remoteJournal), "Установка готова, но её журнал не удалось завершить")
        journal.remoteJournal = remoteJournal; journal.phase = "complete"
    }
}
