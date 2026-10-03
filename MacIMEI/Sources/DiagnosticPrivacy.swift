import Foundation

/// One ID for all engine, onboarding and UI events in this application process.
enum DiagnosticsContext {
    static let sessionID = UUID().uuidString.lowercased()
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.23.3"
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
        if sensitiveSources.contains(where: { command.contains($0) }) {
            // The pinned inline preflight contains startup-file names even
            // though it never reads their contents. Keep only its fixed error
            // protocol; arbitrary output from credential commands stays hidden.
            var markers: [String] = []
            if command.contains("--preflight") || command.contains("setup-agent.sh") {
                markers = CommandText.decode(Data(data.prefix(64 * 1024))).split(whereSeparator: \.isNewline).map(String.init).filter {
                    $0.range(of: #"^INSTALL_ERROR [A-Z][A-Z0-9_]{0,95}$"#, options: .regularExpression) != nil ||
                    $0.range(of: #"^INSTALL_INCOMPLETE /data/local/tmp/zte-imei-installations/[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$"#, options: .regularExpression) != nil
                }
            }
            return Array(markers.prefix(4)).joined(separator: "\n") + (markers.isEmpty ? "" : "\n") + "[Вывод операции с учётными данными исключён]"
        }
        var sample = Data(data.prefix(64 * 1024))
        if data.count > sample.count { for _ in 0..<3 { if String(data: sample, encoding: .utf8) != nil { break }; sample.removeLast() } }
        guard !sample.contains(0), let text = String(data: sample, encoding: .utf8) else { return "[Бинарный или нетекстовый вывод исключён]" }
        var clean: String
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let bytes = try? JSONSerialization.data(withJSONObject: sanitizeJSON(json), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            clean = boundedText(String(decoding: bytes, as: UTF8.self), limit: 64 * 1024)
        } else { clean = boundedText(CommandText.normalize(text), limit: 64 * 1024) }
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
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let id = UUID().uuidString.lowercased(), started = ProcessInfo.processInfo.systemUptime
        let command = ([executable.path] + arguments).map(shellQuote).joined(separator: " ")
        let adbShell = executable.lastPathComponent == "adb" && arguments.count == 4 && arguments[0] == "-s" && arguments[2] == "shell"
        let title = adbShell ? "ADB: удалённая команда" : "Локальный инструмент: " + executable.lastPathComponent
        var details = ["requestID": id, "endpoint": "Mac / USB / " + executable.lastPathComponent,
                       "commandSHA256": digest(Data(command.utf8)), "timeoutSeconds": String(timeout),
                       "command": ActivityJournal.boundedText(command, limit: 16384),
                       "statusScope": adbShell ? "local-process-and-remote-command" : "local-process"]
        try journal.record(operationID: operationID, category: "transport", title: title, result: "started", details: details)
        do {
            let response = try base.run(executable, arguments, timeout: timeout)
            details["durationMilliseconds"] = String(Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
            details["exitCode"] = String(response.status) // Legacy field is the local process status.
            details["localExitCode"] = String(response.status)
            details["stdoutBytes"] = String(response.stdout.count); details["stderrBytes"] = String(response.stderr.count)
            details["stdoutSHA256"] = digest(response.stdout); details["stderrSHA256"] = digest(response.stderr)
            var completed = response.status == 0
            if adbShell {
                if response.status == 0, let marker = ADBClient.shellMarker(in: arguments[3]) {
                    do {
                        let remote = try ADBClient.decodeShellResult(response, marker: marker, command: arguments[3])
                        details["remoteExitCode"] = String(remote.status)
                        completed = remote.status == 0
                        if !completed {
                            details["remoteError"] = ADBClient.errorExcerpt(remote.stdout + remote.stderr, command: arguments[3])
                        }
                    } catch {
                        completed = false; details["remoteStatus"] = "unconfirmed"
                        details["error"] = ActivityJournal.redact(error.localizedDescription)
                    }
                } else {
                    completed = false; details["remoteStatus"] = "unconfirmed"
                }
            }
            journal.trace(requestID: id, operationID: operationID, details: details, response: response, command: command)
            do { try journal.record(operationID: operationID, category: "transport", title: title, result: completed ? "completed" : "failed", details: details) }
            catch { journal.markIncomplete(operationID) }
            // Return the actual local result. ADBClient separately interprets the
            // remote footer; an audit failure never replays or changes an action.
            return response
        } catch {
            details["durationMilliseconds"] = String(Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
            details["error"] = ActivityJournal.redact(error.localizedDescription)
            if let failure = error as? CommandFailure {
                details["localExitCode"] = String(failure.partial.status)
                details["remoteStatus"] = "unconfirmed"
                details["timedOut"] = "true"
                journal.trace(requestID: id, operationID: operationID, details: details, response: failure.partial, command: command)
            } else { journal.trace(requestID: id, operationID: operationID, details: details, response: nil, command: command) }
            try? journal.record(operationID: operationID, category: "transport", title: title, result: "failed", details: details)
            throw error
        }
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
