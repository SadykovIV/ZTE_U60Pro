import Foundation

enum AccessServiceID: String, CaseIterable, Codable, Sendable { case stockWeb, dashboard, agent, managementSSH, userSSH, adb }
enum AccessServiceRuntime: String, Codable, Sendable { case running, stopped, unavailable, unknown }
enum AccessServiceAction: String, CaseIterable, Codable, Sendable {
    case start, stop, restart
    var title: String { switch self { case .start: return "Запустить"; case .stop: return "Остановить"; case .restart: return "Перезапустить" } }
}
struct AccessServiceState: Identifiable, Sendable {
    var id: AccessServiceID
    var title: String
    var endpoint: String
    var state: AccessServiceRuntime
    var detail: String
    var allowedActions: [AccessServiceAction]
    var credentialModel: String
    var isProtected: Bool { id == .managementSSH }
}
struct AccessManagementState: Sendable {
    var services: [AccessServiceState]
    var sshAccounts: SSHAccountState
}

/// Service controls affect this boot only. Account management is independent of
/// the protected key-only SSH connection on 2222; no shared web credential is changed.
final class AccessManager: @unchecked Sendable {
    let engine: ModemEngine
    var assets: URL { engine.resources.appendingPathComponent("SSHAccounts") }
    init(root: URL, resources: URL, connection: Connection, transport: RemoteTransport? = nil,
         update: @escaping @Sendable (String, Double) -> Void = { _, _ in }) throws {
        engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: transport, update: update)
    }
    private func script() throws -> Data {
        let data = try Data(contentsOf: assets.appendingPathComponent("access-services.sh"))
        let hashes = try readJSON([String:String].self, assets.appendingPathComponent("SHA256.json"))
        try require(hashes["access-services.sh"] == digest(data), "Повреждён компонент управления доступом")
        return data
    }
    private func checkPending() throws {
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите текущую операцию с модемом")
        }
    }
    private func readServices(cid: String, data: Data) throws -> [AccessServiceState] {
        let result = try engine.remote("sh -s -- status " + shellQuote(cid) + " " + shellQuote(engine.connection.host), input: data, timeout: 45)
        return try Self.parseServices(String(decoding: result, as: UTF8.self), host: engine.connection.host)
    }
    func inspect() throws -> AccessManagementState {
        try engine.locked {
            try checkPending()
            let (identity, _) = try engine.identity()
            let services = try readServices(cid: identity.cid, data: script())
            let accounts = try SSHAccountManager(root: engine.root, resources: engine.resources, connection: engine.connection, transport: engine.transport).readStateUnlocked()
            return AccessManagementState(services: services, sshAccounts: accounts)
        }
    }
    func perform(service: AccessServiceID, action: AccessServiceAction) throws -> AccessManagementState {
        try require([.dashboard, .agent, .userSSH].contains(service), "Этот канал защищён или доступен только для просмотра")
        try require(engine.connection.port == "2222", "Управление службами доступно через защищённый служебный SSH на порту 2222")
        return try engine.locked {
            try checkPending()
            let (identity, _) = try engine.identity()
            try engine.acquireRemoteLock()
            let data = try script()
            let before = try readServices(cid: identity.cid, data: data)
            try require(before.first(where: { $0.id == service })?.allowedActions.contains(action) == true, "Служба не подтверждена как управляемая приложением")
            let token = UUID().uuidString.lowercased(), stage = "/tmp/zte-access-" + token
            let journal = engine.root.appendingPathComponent("AccessOperations/" + token)
            try secureDirectory(journal)
            try saveJSON(["service":service.rawValue,"action":action.rawValue,"cid":identity.cid,"phase":"prepared"], journal.appendingPathComponent("operation.json"))
            _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
            defer { _ = try? engine.remote("rm -f " + shellQuote(stage + "/access-services.sh") + " " + shellQuote(stage + "/launcher.private.sh") + "; rmdir " + shellQuote(stage), timeout: 10) }
            let path = stage + "/access-services.sh"
            let output = try engine.remote("umask 077; cat > " + shellQuote(path) + " && chmod 600 " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: data)
            try require(String(decoding: output, as: UTF8.self).split(separator: " ").first == Substring(digest(data)), "Не совпала контрольная сумма управления доступом")
            let (again, _) = try engine.identity(); try require(again.cid == identity.cid, "Подключён другой модем")
            let command = ["sh",shellQuote(path),"action",shellQuote(identity.cid),shellQuote(engine.connection.host),service.rawValue,action.rawValue,shellQuote(stage),shellQuote(engine.remoteLockToken!)].joined(separator:" ")
            engine.update("Изменяю состояние службы: " + service.rawValue + "…", 0.4)
            let result = try engine.transport.run(command, input: nil, timeout: 75)
            try savePrivate(result.stdout + result.stderr, journal.appendingPathComponent("result.log"))
            try require(result.status == 0, "Служба не подтвердила изменение состояния. Обновите список доступов; подробности сохранены в журнале.")
            let services = try Self.parseServices(String(decoding: result.stdout, as: UTF8.self), host: engine.connection.host)
            try require(services.first(where: { $0.id == service })?.state == (action == .stop ? .stopped : .running), "Состояние службы после операции не совпало с ожидаемым")
            let accounts = try SSHAccountManager(root: engine.root, resources: engine.resources, connection: engine.connection, transport: engine.transport).readStateUnlocked()
            try saveJSON(["service":service.rawValue,"action":action.rawValue,"cid":identity.cid,"phase":"complete"], journal.appendingPathComponent("operation.json"))
            engine.update("Состояние службы изменено. Настройки автозапуска сохранены.", 1)
            return AccessManagementState(services: services, sshAccounts: accounts)
        }
    }
    static func parseServices(_ text: String, host: String) throws -> [AccessServiceState] {
        var states = [AccessServiceID:AccessServiceState](), schema = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator:" ").map(String.init)
            if fields == ["ACCESS_SCHEMA","1"] { try require(!schema, "Повтор схемы доступов"); schema = true; continue }
            guard fields.count == 4, fields[0] == "ACCESS_SERVICE", let id = AccessServiceID(rawValue:fields[1]),
                  let runtime = AccessServiceRuntime(rawValue:fields[2]), ["control","readonly","protected"].contains(fields[3]) else { throw IMEIError.message("Неизвестный формат состояния доступов") }
            try require(states[id] == nil, "Повтор службы в состоянии доступов")
            let capability = fields[3]
            try require((id == .managementSSH) == (capability == "protected"), "Повреждён статус защищённого канала")
            try require(capability != "control" || ([.agent,.dashboard,.userSSH].contains(id) && [.running,.stopped].contains(runtime)), "Небезопасные возможности управления службой")
            let actions: [AccessServiceAction] = capability == "control" ? (runtime == .running ? [.stop,.restart] : [.start]) : []
            let title: String, endpoint: String, credentials: String
            switch id {
            case .stockWeb: title="Штатный WEB"; endpoint="http://\(host)"; credentials="Общий пароль штатной веб-панели. Отдельные WEB-пользователи не поддерживаются."
            case .dashboard: title="Веб-панель агента"; endpoint="http://\(host):8080"; credentials="Одна учётная запись агента. Отдельные пользователи веб-панели не поддерживаются."
            case .agent: title="Агент модема"; endpoint="http://\(host):9090"; credentials="Общий пароль агента; веб-панель использует тот же доступ."
            case .managementSSH: title="Служебный SSH"; endpoint="\(host):2222"; credentials="Ключ приложения. Остановка и изменение учётной записи root защищены."
            case .userSSH: title="Пользовательский SSH"; endpoint="\(host):2223"; credentials="Отдельные SSH-пользователи приложения; права администратора через doas."
            case .adb: title="ADB по USB"; endpoint="USB"; credentials="Доступ по USB. Штатный запуск ADB приложением не изменяется."
            }
            let detail = capability == "protected" ? "Обеспечивает связь приложения с модемом; отключение недоступно." : capability == "control" ? "Управление до перезагрузки. Автозапуск не изменяется." : "Только просмотр: безопасное управление этой службой не подтверждено."
            states[id] = AccessServiceState(id:id,title:title,endpoint:endpoint,state:runtime,detail:detail,allowedActions:actions,credentialModel:credentials)
        }
        try require(schema && states.count == AccessServiceID.allCases.count, "Неполный список доступов")
        return AccessServiceID.allCases.compactMap { states[$0] }
    }
}
