import Foundation

/// Diagnostic collection stays on the session selected at the start. API
/// access supplies a limited report and never becomes an arbitrary shell.
enum ConnectionDiagnostics {
    static let apiByteLimit = 64 * 1024
    static func collect(engine: ModemEngine, mode: ConnectionMode, session supplied: ReadOnlyChannelSession? = nil,
                        expectedIdentity: Identity? = nil, expectedWebIdentity: WebIdentity? = nil, expectedIMEI: String? = nil,
                        webPassword: String = "", agentPassword: String = "", router suppliedRouter: ConnectionRouter? = nil) throws -> DiagnosticReport {
        try require(engine.lockFD >= 0, "Диагностика требует блокировки операции")
        let session: ReadOnlyChannelSession, reason: String
        if let supplied {
            try require(mode == .automatic || supplied.mode == mode, "Сохранённое подключение не соответствует выбранному режиму; проверьте канал заново")
            session = supplied
            reason = "Диагностика использует ранее выбранный канал: " + supplied.mode.title + ". Переключение при ошибке не выполняется."
        } else {
            let router = try suppliedRouter ?? ConnectionRouter(engine: engine, expectedIdentity: expectedIdentity, expectedWebIdentity: expectedWebIdentity, expectedIMEI: expectedIMEI, webPassword: webPassword, agentPassword: agentPassword)
            let selected = try router.select(mode: mode)
            guard let chosen = selected.session else { throw IMEIError.message(selected.reason) }
            session = chosen; reason = selected.reason
        }
        try require(session.mode != .automatic, "Не определён фактический канал диагностики")
        if session.mode == .ssh || session.mode == .adb {
            guard let shell = session.diagnosticSession, shell.transport == session.mode.rawValue else { throw IMEIError.message("Выбранный канал не предоставил проверенную shell-сессию") }
            return try ModemInformationManager(engine: engine).collectDiagnostics(expectedIdentity: expectedIdentity, expectedWebIdentity: expectedWebIdentity, expectedIMEI: expectedIMEI, preferredSession: shell)
        }
        return try collectAPI(engine: engine, session: session, reason: reason, expectedIdentity: expectedIdentity, expectedWebIdentity: expectedWebIdentity, expectedIMEI: expectedIMEI)
    }

    static func sanitizedSection(_ data: Data, source: String) -> (Data, Bool) {
        let text = ActivityJournal.diagnosticOutput(data, command: source)
        let marker = Data("\n[Вывод API ограничен 64 КиБ]\n".utf8)
        let clean = Data(text.utf8)
        let clipped = data.count > apiByteLimit || clean.count > apiByteLimit
        guard clipped else { return (clean, false) }
        var prefix = Data(clean.prefix(apiByteLimit - marker.count))
        while !prefix.isEmpty && String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return (prefix + marker, true)
    }
    private static func collectAPI(engine: ModemEngine, session: ReadOnlyChannelSession, reason: String,
                                   expectedIdentity: Identity?, expectedWebIdentity: WebIdentity?, expectedIMEI: String?) throws -> DiagnosticReport {
        try require(session.mode == .agent || session.mode == .web, "Неизвестный API диагностики")
        let expected = try DiagnosticDeviceExpectation.load(root: engine.root, identity: expectedIdentity, web: expectedWebIdentity, imei: expectedIMEI)
        let limitation = session.mode.title + " предоставляет только сведения через API. Журналы ядра, файловая система, процессы и команды shell недоступны; для них выберите SSH или USB ADB."
        var warnings = [limitation, "CID, хэш прошивки и boot ID в этом отчёте не подтверждены: API не заменяет проверку идентичности через SSH или USB ADB."]
        let id = UUID().uuidString.lowercased(), directory = engine.root.appendingPathComponent("Diagnostics/" + id)
        try secureDirectory(directory)
        var files: [DiagnosticFile] = []
        func save(name: String, title: String, body: Data, status: Int32, outcome: DiagnosticOutcome, truncated: Bool = false) throws {
            try savePrivate(body, directory.appendingPathComponent(name))
            files.append(DiagnosticFile(name: name, title: title, status: status, bytes: body.count, sha256: digest(body), truncated: truncated, outcome: outcome))
        }
        func checkExpected(_ summary: ConnectionDeviceSummary) throws {
            try require(summary.identity != nil || expected.cids.isEmpty || !expected.imeis.isEmpty,
                        "Этот API не сообщает CID и не может подтвердить устройство незавершённой операции. Выберите SSH или USB ADB либо подтвердите связь CID и IMEI заново.")
            if let identity = summary.identity, !expected.cids.isEmpty {
                try require(expected.cids.contains(identity.cid), "Выбранный API сообщил другое устройство")
            }
            if !expected.imeis.isEmpty {
                try require(summary.primaryIMEI.map { expected.imeis.contains($0) } == true, "Выбранный API не подтвердил IMEI ожидаемого модема")
            }
        }
        do {
            engine.update("Диагностика через " + session.mode.title + ": сведения API", 0.1)
            try checkExpected(session.readSummary())
            let sections = try session.readDiagnosticSections()
            try require(!sections.isEmpty && sections.count <= 16, "Неверное число диагностических разделов API")
            var names = Set<String>(), total = 0
            for section in sections {
                try require(section.name.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}\.(json|txt|log)$"#, options: .regularExpression) != nil && !section.name.contains("..") && names.insert(section.name).inserted, "Некорректное имя диагностического раздела API")
                try require(section.title.utf8.count <= 256 && section.source.utf8.count <= 256 && section.data.count <= 1_048_576 - total, "Диагностический ответ API превышает допустимый размер")
                total += section.data.count
            }
            // Do not publish data if the endpoint changed during API collection.
            try checkExpected(session.readSummary())
            for section in sections {
                let (body, truncated) = sanitizedSection(section.data, source: section.source)
                try save(name: "api-" + section.name, title: ActivityJournal.sanitize(section.title), body: body, status: 0, outcome: .succeeded, truncated: truncated)
            }
        } catch {
            let detail = ActivityJournal.boundedText(error.localizedDescription, limit: 4096)
            warnings.append("Чтение API остановлено; другой канал не запрашивался: " + detail)
            try save(name: "api-error.txt", title: "Ошибка чтения выбранного API", body: Data(detail.utf8), status: -1, outcome: .connectionError)
        }
        for item in ModemInformationManager.diagnosticCommands {
            try save(name: item.0, title: item.1, body: Data(("Раздел не запрашивался. " + limitation).utf8), status: -3, outcome: .skipped)
        }
        let report = DiagnosticReport(id: id, created: ISO8601DateFormatter().string(from: Date()), identity: nil, bootID: "не сообщается API", warnings: warnings, files: files, url: directory, transport: session.mode.rawValue, selectionReason: reason, identityVerified: false)
        try saveJSON(report, directory.appendingPathComponent("manifest.json"))
        try? ActivityJournal(root: engine.root).record(operationID: engine.logDirectory.lastPathComponent, category: "diagnostics", title: "Сохранён ограниченный отчёт API", result: "warning", details: ["reportID": id, "transport": session.mode.rawValue, "summary": report.outcomeSummary])
        engine.update("Диагностика через " + session.mode.title + " сохранена с ограничениями API", 1)
        return report
    }
}
