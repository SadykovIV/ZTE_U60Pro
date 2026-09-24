import Foundation

/// One ID for all engine, onboarding and UI events in this application process.
enum DiagnosticsContext {
    static let sessionID = UUID().uuidString.lowercased()
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.9.1"
}

extension ActivityJournal {
    static func sanitizeJSON(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues { sanitizeJSON($0) }.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = isSecretField(pair.key) ? "[скрыто]" : pair.value
            }
        }
        if let array = value as? [Any] { return array.map(sanitizeJSON) }
        if let string = value as? String { return sanitize(string) }
        return value
    }
    static func isSecretField(_ key: String) -> Bool {
        key.range(of: #"(?i)(password|passwd|token|authorization|cookie|secret|private[_ -]?key|api[_ -]?key|access[_ -]?key|key_2g|key_5g|psk|(^|_)pin$|puk|пароль|imei|imsi|iccid|^uri$|^profile$|^profiles$|^encryption$|^pbk$|^sid$|^uuid$|^data$)"#, options: .regularExpression) != nil
    }
    static func boundedText(_ text: String, limit: Int) -> String {
        let clean = sanitize(text)
        if clean.utf8.count <= limit { return clean }
        var prefix = Data(clean.utf8.prefix(limit))
        while !prefix.isEmpty && String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return String(decoding: prefix, as: UTF8.self) + "\n[Вывод сокращён; исходный размер \(text.utf8.count) байт]"
    }
    static func diagnosticOutput(_ data: Data, command: String) -> String {
        // Auth replies and raw credential stores can have unlabelled secrets.
        let sensitiveSources = ["profiles.json", "config.yaml", "config.json", "uci export", "/api/auth/", "/etc/shadow", "start_zte_agent.sh", "back_parameter", "cat /etc/config/wireless", "uci show wireless", "/profiles/", "export-profile", "ssh-keygen"]
        if sensitiveSources.contains(where: { command.contains($0) }) { return "[Вывод операции с учётными данными исключён]" }
        var sample = Data(data.prefix(64 * 1024))
        if data.count > sample.count { for _ in 0..<3 { if String(data: sample, encoding: .utf8) != nil { break }; sample.removeLast() } }
        guard !sample.contains(0), let text = String(data: sample, encoding: .utf8) else { return "[Бинарный или нетекстовый вывод исключён]" }
        var clean: String
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let bytes = try? JSONSerialization.data(withJSONObject: sanitizeJSON(json), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            clean = boundedText(String(decoding: bytes, as: UTF8.self), limit: 64 * 1024)
        } else { clean = boundedText(text, limit: 64 * 1024) }
        if data.count > sample.count { clean += "\n[Вывод сокращён до 64 КиБ; всего \(data.count) байт]" }
        return clean
    }
    func trace(requestID: String, operationID: String, details: [String: String], response: CommandResult?, command: String) {
        do {
            try require(operationID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil && UUID(uuidString: requestID) != nil, "Некорректный ID трассировки")
            let folder = directory.appendingPathComponent("Traces/" + operationID)
            try secureDirectory(folder)
            var fields = details
            fields["sessionID"] = DiagnosticsContext.sessionID
            fields["operationID"] = operationID
            fields["timestamp"] = ISO8601DateFormatter().string(from: Date())
            if let response {
                fields["stdout"] = Self.diagnosticOutput(response.stdout, command: command)
                fields["stderr"] = Self.diagnosticOutput(response.stderr, command: command)
            }
            try saveJSON(fields, folder.appendingPathComponent(requestID + ".json"))
        } catch { markIncomplete(operationID) }
    }
    func markIncomplete(_ operationID: String) {
        try? savePrivate(Data("Журнал не дописан после операции \(operationID)\n".utf8), directory.appendingPathComponent("incomplete.txt"))
    }
}

/// Transport errors retain partial output for the audit record, never for retries.
struct CommandFailure: LocalizedError {
    let message: String
    let partial: CommandResult
    var errorDescription: String? { message }
}

final class AuditedHostRunner: HostCommandRunner {
    let base: HostCommandRunner, journal: ActivityJournal, operationID: String
    init(base: HostCommandRunner, journal: ActivityJournal, operationID: String) { self.base = base; self.journal = journal; self.operationID = operationID }
    private final class Adapter: RemoteTransport {
        let execute: () throws -> CommandResult
        init(_ execute: @escaping () throws -> CommandResult) { self.execute = execute }
        func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult { try execute() }
    }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let adapter = Adapter { try self.base.run(executable, arguments, timeout: timeout) }
        return try AuditedRemoteTransport(base: adapter, journal: journal, operationID: operationID, endpoint: "Mac / USB / " + executable.lastPathComponent)
            .run(([executable.path] + arguments).map(shellQuote).joined(separator: " "), input: nil, timeout: timeout)
    }
}

final class AuditedWebTransport: WebTransport {
    let base: WebTransport, journal: ActivityJournal, operationID: String, endpoint: String
    init(base: WebTransport, journal: ActivityJournal, operationID: String, endpoint: String) { self.base = base; self.journal = journal; self.operationID = operationID; self.endpoint = endpoint }
    func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply {
        let id = UUID().uuidString.lowercased(), start = ProcessInfo.processInfo.systemUptime
        var details = ["requestID": id, "endpoint": endpoint, "path": path, "method": data == nil ? "GET" : "POST", "inputBytes": String(data?.count ?? 0)]
        if let data, contentType == "application/json", let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let params = rows.first?["params"] as? [Any], params.count >= 3 {
            details["rpcObject"] = params[1] as? String; details["rpcMethod"] = params[2] as? String
        }
        try journal.record(operationID: operationID, category: "http", title: "Веб-интерфейс модема", result: "started", details: details)
        do {
            let reply = try base.request(path: path, data: data, contentType: contentType, cookie: cookie)
            details["durationMilliseconds"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
            details["responseBytes"] = String(reply.data.count)
            details["httpStatus"] = "200"
            if let rows = (try? JSONSerialization.jsonObject(with: reply.data)) as? [[String: Any]], let row = rows.first {
                if let result = row["result"] as? [Any] {
                    details["rpcStatus"] = (result.first as? Int).map(String.init)
                    if result.count > 1, let body = result[1] as? [String: Any] {
                        details["deviceResultCode"] = (body["result"] as? Int).map(String.init) ?? body["result"] as? String
                        for field in ["integrate_version", "wa_inner_version"] { details[field] = body[field] as? String }
                    }
                }
                if let error = row["error"] as? [String: Any] { details["rpcErrorCode"] = (error["code"] as? Int).map(String.init) }
            }
            do { try journal.record(operationID: operationID, category: "http", title: "Ответ веб-интерфейса", result: "completed", details: details) } catch { journal.markIncomplete(operationID) }
            return reply
        } catch {
            details["durationMilliseconds"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
            details["error"] = error.localizedDescription
            try? journal.record(operationID: operationID, category: "http", title: "Ошибка веб-интерфейса", result: "failed", details: details)
            throw error
        }
    }
}
