import Foundation
import Darwin

struct ActivityEvent: Codable, Identifiable, Sendable {
    var id: String
    var timestamp: String
    var operationID: String
    var category: String
    var title: String
    var result: String
    var details: [String: String]
}

/// Private audit records with bounded, sanitized command traces. Stdin is never logged.
final class ActivityJournal: @unchecked Sendable {
    let directory: URL
    init(root: URL) throws {
        directory = root.appendingPathComponent("Activity")
        try secureDirectory(directory)
    }
    static func redact(_ text: String) -> String {
        String(sanitize(text).prefix(4096))
    }
    private static let credentialName = #"(?i)(password|passwd|token|authorization|cookie|secret|private[_ -]?key|api[_ -]?key|access[_ -]?key|key_2g|key_5g|psk|pin|puk|пароль)"#
    static func sanitize(_ text: String) -> String {
        var value = text
        // Remove complete or truncated PEM blocks before processing individual
        // lines. Quoted/escaped secrets are redacted as a whole line so shell
        // quote escaping, JSON escapes and Cookie lists cannot leak a suffix.
        if let pem = try? NSRegularExpression(pattern: #"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|\z)"#) {
            value = pem.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[скрыто]")
        }
        for pattern in [#"(?i)\b(?:vless|vmess|trojan|ss|ssr|hysteria2?|tuic)://[^\s\"<>]+"#,
                        #"(?i)(?:APP_(?:NV|EFS|CONFIG)|EFS_CHUNK)[^\n]*(?:data|hex)=[^\n]*"#,
                        #"\b[0-9]{15,22}\b"#,
                        #"[A-Za-z0-9_+/=-]{100,}"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[скрыто]")
            }
        }
        let sensitive = try? NSRegularExpression(pattern: credentialName + #"["']?\s*(?:[:=]|[ \t]+[^\s])"#)
        let bearer = try? NSRegularExpression(pattern: #"(?i)\bBearer\s+[^\s]+"#)
        let crypt = try? NSRegularExpression(pattern: #"\$(?:[156y]|2[aby])\$[A-Za-z0-9./$]+"#)
        return value.components(separatedBy: "\n").map { line in
            let range = NSRange(line.startIndex..., in: line)
            if sensitive?.firstMatch(in: line, range: range) != nil || bearer?.firstMatch(in: line, range: range) != nil {
                return "[Строка с конфиденциальными данными скрыта]"
            }
            return crypt?.stringByReplacingMatches(in: line, range: range, withTemplate: "[скрыто]") ?? line
        }.joined(separator: "\n")
    }
    private static func redactDetails(_ details: [String: String]) -> [String: String] {
        let secretKey = try? NSRegularExpression(pattern: credentialName)
        var safe = [String: String]()
        for (key, value) in details.prefix(64) {
            let keyRange = NSRange(key.startIndex..., in: key)
            safe[String(Self.redact(key).prefix(128))] = secretKey?.firstMatch(in: key, range: keyRange) != nil ? "[скрыто]" : Self.redact(value)
        }
        return safe
    }
    func record(operationID: String, category: String, title: String, result: String, details: [String: String] = [:]) throws {
        var details = details
        details["sessionID"] = DiagnosticsContext.sessionID
        details["appVersion"] = DiagnosticsContext.version
        details["appBuild"] = DiagnosticsContext.build
        let now = Date(), formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event = ActivityEvent(id: UUID().uuidString.lowercased(), timestamp: formatter.string(from: now),
                                  operationID: Self.redact(operationID), category: Self.redact(category), title: Self.redact(title), result: Self.redact(result),
                                  details: Self.redactDetails(details))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(event); bytes.append(10)
        let day = String(event.timestamp.prefix(10)), file = directory.appendingPathComponent(day + ".jsonl")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Не удалось открыть журнал действий")
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1, "Небезопасный файл журнала")
        try require(flock(fd, LOCK_EX) == 0, "Не удалось заблокировать журнал")
        defer { flock(fd, LOCK_UN) }
        _ = fchmod(fd, 0o600)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                try require(written > 0, "Не удалось дописать журнал действий")
                offset += written
            }
        }
        try require(fsync(fd) == 0, "Не удалось сохранить журнал действий")
    }
    func recent(limit: Int = 400) -> [ActivityEvent] {
        guard limit > 0 else { return [] }
        let limit = min(limit, 1000)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var events: [ActivityEvent] = []
        for file in files {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == getuid() else { close(fd); continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            // Read a bounded tail for the UI; complete files remain available for export.
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
            let data = (try? handle.read(upToCount: 2_000_000)) ?? Data()
            let parsed = data.split(separator: 10).compactMap { try? JSONDecoder().decode(ActivityEvent.self, from: Data($0)) }
            events.append(contentsOf: parsed.reversed())
            if events.count >= limit { break }
        }
        return Array(events.prefix(limit))
    }
}

final class AuditedRemoteTransport: RemoteTransport {
    let base: RemoteTransport
    let journal: ActivityJournal
    let operationID: String
    let endpoint: String
    init(base: RemoteTransport, journal: ActivityJournal, operationID: String, endpoint: String) {
        self.base = base; self.journal = journal; self.operationID = operationID; self.endpoint = endpoint
    }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        let requestID = UUID().uuidString.lowercased(), started = ProcessInfo.processInfo.systemUptime
        var details = ["requestID": requestID, "endpoint": endpoint, "commandSHA256": digest(Data(command.utf8)),
                       "inputBytes": String(input?.count ?? 0), "timeoutSeconds": String(timeout),
                       "command": ActivityJournal.boundedText(command, limit: 16384)]
        // Safe operation tags provide context without storing script bodies or secrets.
        let tag = command.contains("manager.sh") ? "Менеджер модема" : command.contains("sha256sum") ? "Проверка файлов" :
            command.contains("ubus call") ? "Запрос к службе модема" : command.contains("tar ") ? "Архивация" :
            command.contains("zte_nv") ? "Операция NV" : command.contains("lock") ? "Блокировка операции" : "SSH-команда"
        try journal.record(operationID: operationID, category: "transport", title: tag, result: "started", details: details)
        do {
            let response = try base.run(command, input: input, timeout: timeout)
            details["durationMilliseconds"] = String(Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
            details["exitCode"] = String(response.status)
            details["stdoutBytes"] = String(response.stdout.count); details["stderrBytes"] = String(response.stderr.count)
            details["stdoutSHA256"] = digest(response.stdout); details["stderrSHA256"] = digest(response.stderr)
            journal.trace(requestID: requestID, operationID: operationID, details: details, response: response, command: command)
            // Do not turn a completed device operation into an apparent failure if
            // only the second audit append fails; a separate marker exposes that gap.
            do { try journal.record(operationID: operationID, category: "transport", title: tag, result: response.status == 0 ? "completed" : "failed", details: details) }
            catch { try? savePrivate(Data("Журнал не дописан после операции \(operationID)\n".utf8), journal.directory.appendingPathComponent("incomplete.txt")) }
            return response
        } catch {
            details["durationMilliseconds"] = String(Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
            details["error"] = ActivityJournal.redact(error.localizedDescription)
            if let failure = error as? CommandFailure {
                details["timedOut"] = "true"
                details["stdoutBytes"] = String(failure.partial.stdout.count)
                details["stderrBytes"] = String(failure.partial.stderr.count)
                journal.trace(requestID: requestID, operationID: operationID, details: details, response: failure.partial, command: command)
            } else { journal.trace(requestID: requestID, operationID: operationID, details: details, response: nil, command: command) }
            try? journal.record(operationID: operationID, category: "transport", title: tag, result: "failed", details: details)
            throw error
        }
    }
}
