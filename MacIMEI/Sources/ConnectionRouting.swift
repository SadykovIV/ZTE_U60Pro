import Foundation

enum ConnectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, ssh, agent, adb, web
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "Автоматически"; case .ssh: return "SSH"; case .agent: return "Агент"; case .adb: return "ADB по USB"; case .web: return "Веб-интерфейс" }
    }
    // Legacy read-only API routing remains available to diagnostics. A user
    // connection grants management capabilities only over SSH or physical USB.
    static let priority: [ConnectionMode] = [.ssh, .agent, .adb, .web]
    static let connectionPriority: [ConnectionMode] = [.ssh, .adb]
    static let discoveryOrder: [ConnectionMode] = [.ssh, .adb, .agent, .web]
}
enum ConnectionChannelState: String, Codable, Sendable {
    case available, unavailable, authenticationRequired, invalidPassword, rateLimited, trustRejected, identityMismatch, identityUnverified, ambiguous, unsupported, notChecked
    var title: String {
        switch self {
        case .available: return "Доступен"
        case .unavailable: return "Недоступен"
        case .authenticationRequired: return "Нужна авторизация"
        case .invalidPassword: return "Неверный пароль"
        case .rateLimited: return "Вход временно заблокирован"
        case .trustRejected: return "Проверка доверия не пройдена"
        case .identityMismatch: return "Другое устройство"
        case .identityUnverified: return "Устройство не подтверждено"
        case .ambiguous: return "Неоднозначный выбор"
        case .unsupported: return "Не поддерживается"
        case .notChecked: return "Не проверен"
        }
    }
    var preventsDowngrade: Bool { self == .trustRejected || self == .identityMismatch || self == .ambiguous }
}
struct ConnectionDeviceSummary: Codable, Equatable, Sendable {
    var identity: Identity? = nil
    var webIdentity: WebIdentity? = nil
    var bootID: String? = nil
    var agentVersion: String? = nil
    var imei: String? = nil
    var fields: [String: String] = [:]
    var primaryIMEI: String? { webIdentity?.imei ?? imei }
    var firmware: String? { webIdentity?.firmware ?? fields["firmware"] }
    var model: String? { fields["model"] }
    func validate() throws {
        if let identity {
            try require(identity.cid.count == 32 && identity.cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && (DeviceBackups.validHash(identity.firmwareHash) || identity.firmwareHash == "absent"), "Некорректная идентификация канала")
        }
        if let bootID { try require(UUID(uuidString: bootID) != nil, "Некорректный идентификатор загрузки канала") }
        if let imei { try require(IMEI.valid(imei), "Некорректный IMEI канала") }
        if let webIdentity {
            try require(IMEI.valid(webIdentity.imei) && webIdentity.firmware.utf8.count <= 256 && webIdentity.inner.utf8.count <= 256, "Некорректная веб-идентификация канала")
            if let imei { try require(imei == webIdentity.imei, "Идентификаторы в ответе канала расходятся") }
        }
        try require((agentVersion?.utf8.count ?? 0) <= 256 && fields.count <= 32 && fields.allSatisfy { $0.key.utf8.count <= 64 && $0.value.utf8.count <= 1024 && !$0.key.contains("\0") && !$0.value.contains("\0") }, "Слишком большой ответ со сведениями модема")
        try require(fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } <= 16384, "Слишком большой ответ со сведениями модема")
    }
}
struct ConnectionChannelStatus: Identifiable, Sendable {
    var mode: ConnectionMode
    var state: ConnectionChannelState
    var message: String
    var summary: ConnectionDeviceSummary? = nil
    var id: String { mode.rawValue }
}
struct ConnectionDiagnosticSection: Sendable {
    var name: String
    var title: String
    var data: Data
    var source: String
}
struct ConnectionProbeFailure: LocalizedError {
    var state: ConnectionChannelState
    var message: String
    var errorDescription: String? { message }
}

/// A chosen session is fixed for its entire lifetime. It exposes no operation
/// which can install, enable ADB, repair SSH, or silently change transports.
final class ReadOnlyChannelSession: @unchecked Sendable {
    let mode: ConnectionMode
    let summary: ConnectionDeviceSummary
    let diagnosticSession: DiagnosticSession?
    private let refresh: () throws -> ConnectionDeviceSummary
    init(mode: ConnectionMode, summary: ConnectionDeviceSummary, diagnosticSession: DiagnosticSession? = nil,
         readSummary: @escaping () throws -> ConnectionDeviceSummary) {
        self.mode = mode; self.summary = summary; self.diagnosticSession = diagnosticSession; self.refresh = readSummary
    }
    func readSummary() throws -> ConnectionDeviceSummary {
        let current = try refresh()
        try current.validate()
        if let identity = summary.identity { try require(current.identity == identity, "Устройство или прошивка выбранного канала изменились") }
        if let boot = summary.bootID { try require(current.bootID == boot, "Модем перезагрузился; проверьте подключение заново") }
        if let web = summary.webIdentity { try require(current.webIdentity == web, "Устройство веб-интерфейса изменилось") }
        if let imei = summary.primaryIMEI { try require(current.primaryIMEI == imei, "IMEI выбранного канала изменился; чтение остановлено") }
        return current
    }
    func readDiagnosticSections() throws -> [ConnectionDiagnosticSection] {
        let current = try readSummary()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)
        try require(data.count <= 65536, "Слишком большой диагностический ответ API")
        return [ConnectionDiagnosticSection(name: "device-info.json", title: "Сведения устройства через " + mode.title, data: data, source: mode.rawValue)]
    }
    func requireSSH() throws -> DiagnosticSession {
        guard mode == .ssh, let diagnosticSession else {
            throw IMEIError.message("Для этой операции требуется SSH. Текущий канал: \(mode.title). В разделе «Подготовка» нажмите «Выполнить предварительную подготовку модема», затем выберите SSH или автоматическое подключение.")
        }
        try diagnosticSession.verify()
        return diagnosticSession
    }
}
struct ChannelSelection: @unchecked Sendable {
    var requestedMode: ConnectionMode
    var actualMode: ConnectionMode?
    var statuses: [ConnectionChannelStatus]
    var session: ReadOnlyChannelSession?
    var reason: String
    var requiresSSHPreparation: Bool { actualMode != .ssh }
}

final class ConnectionRouter {
    typealias Probe = (DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession
    private let expected: DiagnosticDeviceExpectation
    private let probes: [ConnectionMode: Probe]
    private let discoveryProbes: [ConnectionMode: Probe]
    init(expected: DiagnosticDeviceExpectation = DiagnosticDeviceExpectation(), probes: [ConnectionMode: Probe],
         discoveryProbes: [ConnectionMode: Probe]? = nil) {
        self.expected = expected; self.probes = probes; self.discoveryProbes = discoveryProbes ?? probes
    }
    convenience init(engine: ModemEngine, expectedIdentity: Identity? = nil, expectedWebIdentity: WebIdentity? = nil, expectedIMEI: String? = nil,
                     webPassword: String = "", agentPassword: String = "", ssh: RemoteTransport? = nil,
                     adb: ADBClient? = nil, web: ModemWebClient? = nil, agent: AgentAccessClient? = nil) throws {
        let expected = try DiagnosticDeviceExpectation.load(root: engine.root, identity: expectedIdentity, web: expectedWebIdentity, imei: expectedIMEI)
        let remote = ssh ?? engine.transport
        let webClient = try web ?? ModemWebClient(host: engine.connection.host)
        let agentClient = try agent ?? AgentAccessClient(host: engine.connection.host)
        let sshProbe: Probe = { expected in try Self.sshSession(engine: engine, remote: remote, expected: expected) }
        let adbProbe: Probe = { expected in try Self.adbSession(adb ?? DiagnosticTransportSelector.bundledADB(engine), expected: expected) }
        self.init(expected: expected, probes: [
            .ssh: sshProbe, .adb: adbProbe,
            .agent: { _ in try Self.agentSession(agentClient, password: agentPassword) },
            .web: { _ in try Self.webSession(webClient, password: webPassword) }
        ], discoveryProbes: [
            .ssh: sshProbe, .adb: adbProbe,
            .agent: { _ in try Self.agentSession(agentClient, password: "") },
            .web: { _ in try Self.webSession(webClient, password: "") }
        ])
    }
    private static func failure(_ error: Error) -> ConnectionProbeFailure {
        if let known = error as? ConnectionProbeFailure { return known }
        if let agent = error as? AgentAccessError {
            let state: ConnectionChannelState
            switch agent {
            case .identityChanged: state = .identityMismatch
            case .identityUnavailable: state = .identityUnverified
            case .redirect: state = .trustRejected
            case .invalidPassword: state = .invalidPassword
            case .rateLimited: state = .rateLimited
            case .authenticationRequired, .passwordNotConfigured, .loginAlreadyAttempted: state = .authenticationRequired
            case .malformed, .oversized, .forbiddenRequest: state = .unsupported
            default: state = .unavailable
            }
            return ConnectionProbeFailure(state: state, message: agent.localizedDescription)
        }
        if let web = error as? ModemWebError {
            let state: ConnectionChannelState
            switch web {
            case .passwordRequired: state = .authenticationRequired
            case .invalidPassword: state = .invalidPassword
            case .authenticationRejected: state = .authenticationRequired
            case .malformedResponse, .rpcRejected: state = .unsupported
            }
            return ConnectionProbeFailure(state: state, message: web.localizedDescription)
        }
        let partial = (error as? CommandFailure).map { String(decoding: $0.partial.stderr + $0.partial.stdout, as: UTF8.self) } ?? ""
        let message = ActivityJournal.redact(error.localizedDescription)
        if DiagnosticTransportSelector.hostTrustFailure(error.localizedDescription + partial) {
            return ConnectionProbeFailure(state: .trustRejected, message: "Ключ сервера SSH не подтверждён или изменился. Автоматический переход на другой канал остановлен.")
        }
        let lower = (error.localizedDescription + partial).lowercased()
        if lower.contains("устройство, прошивка или сеанс загрузки изменились") || lower.contains("устройство веб-интерфейса изменилось") {
            return ConnectionProbeFailure(state: .identityMismatch, message: message)
        }
        if ["permission denied", "authentication", "вход отклонён", "пароль", "password", "unauthorized"].contains(where: lower.contains) {
            return ConnectionProbeFailure(state: .authenticationRequired, message: message)
        }
        return ConnectionProbeFailure(state: .unavailable, message: message)
    }
    private static func binding(_ summary: ConnectionDeviceSummary, expected: DiagnosticDeviceExpectation) -> ConnectionProbeFailure? {
        if let identity = summary.identity, !expected.cids.isEmpty, !expected.cids.contains(identity.cid) {
            return ConnectionProbeFailure(state: .identityMismatch, message: "CID канала относится к другому модему.")
        }
        if !expected.imeis.isEmpty {
            guard let imei = summary.primaryIMEI else { return ConnectionProbeFailure(state: .identityUnverified, message: "Канал не сообщил IMEI для сверки ожидаемого модема.") }
            if !expected.imeis.contains(imei) { return ConnectionProbeFailure(state: .identityMismatch, message: "IMEI канала относится к другому модему.") }
        }
        if summary.identity == nil && !expected.cids.isEmpty && expected.imeis.isEmpty {
            return ConnectionProbeFailure(state: .identityUnverified, message: "Этот API не сообщает CID. Сначала подтвердите соответствие модема через SSH или USB ADB.")
        }
        if summary.identity == nil && summary.primaryIMEI == nil {
            return ConnectionProbeFailure(state: .identityUnverified, message: "Канал доступен, но не сообщил проверяемый идентификатор модема.")
        }
        return nil
    }
    /// Passive discovery sends no credentials. An explicit check can authenticate
    /// with the supplied passwords, once per service, and read device identity.
    /// Neither path enables ADB, installs files, or changes the active connection.
    func discover(authenticate: Bool = false) throws -> [ConnectionChannelStatus] {
        try select(mode: .automatic, priority: ConnectionMode.discoveryOrder,
                   probes: authenticate ? probes : discoveryProbes).statuses
    }

    /// Connect fixes one verified shell session. Agent and stock Web are useful
    /// availability information, but never count as an application connection.
    func connect(mode: ConnectionMode) throws -> ChannelSelection {
        guard mode == .automatic || ConnectionMode.connectionPriority.contains(mode) else {
            return ChannelSelection(requestedMode: mode, actualMode: nil, statuses: ConnectionMode.priority.map { channel in
                ConnectionChannelStatus(mode: channel, state: channel == mode ? .unsupported : .notChecked,
                                        message: channel == mode ? "Для подключения выберите SSH, ADB по USB или автоматический режим." : "Не проверен в выбранном режиме")
            }, session: nil, reason: "Агент и веб-интерфейс используются для проверки доступности и подготовки. Подключитесь по SSH или ADB по USB; при их отсутствии сначала выполните подготовку модема.")
        }
        var selection = try select(mode: mode, priority: ConnectionMode.connectionPriority, probes: probes)
        if selection.session == nil && !selection.statuses.contains(where: { $0.state.preventsDowngrade }) {
            selection.reason += " Если SSH или ADB ещё не настроены, сначала выполните подготовку модема."
        } else if selection.actualMode == .adb {
            selection.reason += " Доступны чтение сведений и диагностика. Для управления выполните подготовку SSH."
        }
        return selection
    }

    /// Retained for explicit read-only API diagnostics; the app's Connect
    /// action must use connect(mode:) and cannot choose Agent or Web.
    func select(mode: ConnectionMode) throws -> ChannelSelection {
        try select(mode: mode, priority: ConnectionMode.priority, probes: probes)
    }
    private func select(mode: ConnectionMode, priority: [ConnectionMode], probes: [ConnectionMode: Probe]) throws -> ChannelSelection {
        try require(expected.cids.count <= 1 && expected.imeis.count <= 1, "Сохранённая идентификация относится к разным модемам")
        try require(expected.cids.allSatisfy { $0.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } && expected.imeis.allSatisfy(IMEI.valid), "Некорректная ожидаемая идентификация модема")
        var statuses = Dictionary(uniqueKeysWithValues: ConnectionMode.priority.map { ($0, ConnectionChannelStatus(mode: $0, state: .notChecked, message: "Не проверен в выбранном режиме")) })
        var sessions: [ConnectionMode: ReadOnlyChannelSession] = [:]
        var context = expected
        let requested = mode == .automatic ? priority : [mode]
        var blocked: String?
        for channel in requested {
            if let blocked {
                statuses[channel] = ConnectionChannelStatus(mode: channel, state: .notChecked, message: "Проверка остановлена: " + blocked)
                continue
            }
            guard let probe = probes[channel] else {
                statuses[channel] = ConnectionChannelStatus(mode: channel, state: .unsupported, message: "Для этого канала нет доступного клиента")
                continue
            }
            do {
                let session = try probe(context)
                try require(session.mode == channel, "Проверка вернула другой канал")
                try session.summary.validate()
                sessions[channel] = session
                // Strong SSH/ADB identities can supply the IMEI associated with
                // a known CID. Weak API responses never invent that association.
                if let identity = session.summary.identity {
                    if let error = Self.binding(session.summary, expected: context) { throw error }
                    context.cids = [identity.cid]
                    if let imei = session.summary.primaryIMEI { context.imeis = [imei] }
                } else if context.cids.isEmpty, context.imeis.isEmpty, let imei = session.summary.primaryIMEI {
                    // An authenticated higher-priority API can identify which
                    // attached USB device belongs to the selected IP endpoint.
                    context.imeis = [imei]
                }
                if let error = Self.binding(session.summary, expected: context) {
                    statuses[channel] = ConnectionChannelStatus(mode: channel, state: error.state, message: error.message, summary: session.summary)
                    let earlierUsable = priority.prefix { $0 != channel }.contains { statuses[$0]?.state == .available }
                    if mode == .automatic && error.state.preventsDowngrade && !earlierUsable { blocked = error.message }
                } else {
                    statuses[channel] = ConnectionChannelStatus(mode: channel, state: .available, message: "Канал авторизован; идентификация прочитана", summary: session.summary)
                }
                // Before sending a password to the next HTTP service, check
                // whether this strong proof rejected an earlier weak response.
                if mode == .automatic, session.summary.identity != nil {
                    for prior in priority.prefix(while: { $0 != channel }) {
                        guard let candidate = sessions[prior], let error = Self.binding(candidate.summary, expected: context), error.state.preventsDowngrade else { continue }
                        statuses[prior] = ConnectionChannelStatus(mode: prior, state: error.state, message: error.message, summary: candidate.summary)
                        let earlierUsable = priority.prefix(while: { $0 != prior }).contains { statuses[$0]?.state == .available }
                        if !earlierUsable { blocked = error.message }
                    }
                }
            } catch {
                sessions.removeValue(forKey: channel)
                let error = Self.failure(error)
                statuses[channel] = ConnectionChannelStatus(mode: channel, state: error.state, message: error.message)
                // Do not send API passwords to a host whose higher-priority
                // identity or SSH host key was positively rejected.
                let earlierUsable = priority.prefix { $0 != channel }.contains { statuses[$0]?.state == .available }
                if mode == .automatic && error.state.preventsDowngrade && !earlierUsable { blocked = error.message }
            }
        }
        // A matching ADB proof may resolve an earlier Agent response which
        // supplied only IMEI while the stored expectation contained only CID.
        for channel in requested where sessions[channel] != nil {
            let summary = sessions[channel]!.summary
            if let error = Self.binding(summary, expected: context) {
                statuses[channel] = ConnectionChannelStatus(mode: channel, state: error.state, message: error.message, summary: summary)
            } else { statuses[channel] = ConnectionChannelStatus(mode: channel, state: .available, message: summary.identity == nil ? "Авторизация и IMEI подтверждены; CID этот API не сообщает" : "Авторизация и идентификация модема подтверждены", summary: summary) }
        }
        var chosen: ConnectionMode?
        var reason = "Доступный подтверждённый канал не найден. Проверьте подключения и учётные данные."
        for channel in requested {
            guard let status = statuses[channel] else { continue }
            if status.state == .available { chosen = channel; break }
            if mode == .automatic && status.state.preventsDowngrade { reason = status.message + " Автоматический переход на менее приоритетный канал остановлен."; break }
        }
        if let chosen { reason = mode == .automatic ? "Выбран \(chosen.title). Приоритет: \(priority.map(\.title).joined(separator: " → "))." : "Используется только выбранный канал: \(chosen.title)." }
        else if mode != .automatic { reason = statuses[mode]?.message ?? reason }
        return ChannelSelection(requestedMode: mode, actualMode: chosen, statuses: ConnectionMode.priority.compactMap { statuses[$0] }, session: chosen.flatMap { sessions[$0] }, reason: reason)
    }
    private static func summary(_ proof: DiagnosticDeviceProof) -> ConnectionDeviceSummary {
        var fields = ["routerSHA256": proof.routerHash, "accessProfile": AccessIdentity.profile(proof, experimental: false)]
        if let web = proof.webIdentity { fields["firmware"] = web.firmware; fields["innerVersion"] = web.inner }
        return ConnectionDeviceSummary(identity: proof.identity, webIdentity: proof.webIdentity, bootID: proof.bootID, fields: fields)
    }
    private static func shellSummary(_ session: DiagnosticSession) throws -> ConnectionDeviceSummary {
        var result = summary(session.proof)
        let response = try session.run(ModemInformationManager.command, timeout: 30)
        if response.status != 0 {
            result.fields["detailsUnavailable"] = "Расширенные сведения недоступны в этом сеансе"
            return result
        }
        try require(response.stdout.count <= 1_048_576, "Слишком большой ответ сведений модема")
        guard let info = try? ModemInformationManager.parse(String(decoding: response.stdout, as: UTF8.self), identity: session.proof.identity, boot: session.proof.bootID) else {
            result.fields["detailsUnavailable"] = "Формат расширенных сведений не распознан"
            return result
        }
        result.fields.merge(["model": info.model, "hostname": info.hostname, "kernel": info.kernel, "architecture": info.architecture,
                             "uptimeSeconds": String(info.uptimeSeconds), "memoryTotalKiB": String(info.memoryTotalKiB),
                             "memoryAvailableKiB": String(info.memoryAvailableKiB), "batteryState": info.batteryState]) { _, new in new }
        if let battery = info.batteryPercent { result.fields["batteryPercent"] = String(battery) }
        return result
    }
    private static func sshSession(engine: ModemEngine, remote: RemoteTransport, expected: DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession {
        do { try engine.connection.validate() }
        catch { throw ConnectionProbeFailure(state: .authenticationRequired, message: "SSH ещё не настроен: " + ActivityJournal.redact(error.localizedDescription)) }
        let command = expected.requiresWeb ? DiagnosticTransportSelector.identityCommand(requireWeb: true) : AccessIdentity.optionalWebCommand
        let read: () throws -> DiagnosticDeviceProof = {
            let result = try remote.run(command, input: nil, timeout: 15)
            guard result.status == 0 else {
                let text = String(decoding: result.stderr + result.stdout, as: UTF8.self)
                if DiagnosticTransportSelector.hostTrustFailure(text) { throw ConnectionProbeFailure(state: .trustRejected, message: "Ключ SSH изменился или не подтверждён") }
                if result.status != 255 && result.status != -1 { throw ConnectionProbeFailure(state: .trustRejected, message: "SSH отвечает, но полная идентификация устройства не подтверждена") }
                throw CommandFailure(message: "SSH недоступен: " + ActivityJournal.redact(text), partial: result)
            }
            do { return try AccessIdentity.parseObservation(result.stdout, requireWeb: expected.requiresWeb) }
            catch { throw ConnectionProbeFailure(state: .trustRejected, message: "SSH вернул неполную или некорректную идентификацию устройства") }
        }
        let proof = try read()
        let initial = summary(proof)
        if let failure = binding(initial, expected: expected) { throw failure }
        let session = DiagnosticSession(transport: "ssh", reason: "Проверенный SSH выбран при проверке каналов", proof: proof, readIdentity: read) { command, timeout in
            let result = try remote.run(command, input: nil, timeout: timeout)
            try require(result.status != 255, "Связь SSH потеряна. Повторно проверьте каналы; текущая операция не переключается автоматически.")
            return result
        }
        try session.verify()
        return ReadOnlyChannelSession(mode: .ssh, summary: initial, diagnosticSession: session) { try shellSummary(session) }
    }
    private static func physicalSerials(_ adb: ADBClient) throws -> [String] {
        try adb.discovery().readyUSBSerials
    }
    private static func adbSession(_ adb: ADBClient, expected: DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession {
        let discovery = try adb.discovery(), serials = discovery.readyUSBSerials
        guard !serials.isEmpty else { throw ConnectionProbeFailure(state: .unavailable, message: discovery.explanation + " Проверка не включает ADB автоматически.") }
        guard serials.count == 1 || !expected.cids.isEmpty || !expected.imeis.isEmpty else { throw ConnectionProbeFailure(state: .ambiguous, message: "Подключено несколько USB ADB устройств, ожидаемый модем неизвестен") }
        let command = expected.requiresWeb ? DiagnosticTransportSelector.identityCommand(requireWeb: true) : AccessIdentity.optionalWebCommand
        var matches: [(String, DiagnosticDeviceProof)] = []
        var mismatch = false
        for serial in serials {
            guard let result = try? adb.shellResult(serial, command, timeout: 20), result.status == 0, let proof = try? AccessIdentity.parseObservation(result.stdout, requireWeb: expected.requiresWeb) else { continue }
            if binding(summary(proof), expected: expected) == nil { matches.append((serial, proof)) } else { mismatch = true }
        }
        guard matches.count == 1 else {
            throw ConnectionProbeFailure(state: matches.count > 1 ? .ambiguous : (mismatch ? .identityMismatch : .unsupported), message: matches.count > 1 ? "Несколько USB модемов совпали с ожидаемой идентификацией" : "USB ADB не подтвердил root-доступ и идентичность ожидаемого модема")
        }
        let (serial, proof) = matches[0]
        let read: () throws -> DiagnosticDeviceProof = {
            try require(try physicalSerials(adb).contains(serial), "Выбранный USB ADB отключён")
            let result = try adb.shellResult(serial, command, timeout: 20)
            try require(result.status == 0, "Идентификация выбранного USB ADB недоступна")
            return try AccessIdentity.parseObservation(result.stdout, requireWeb: expected.requiresWeb)
        }
        let session = DiagnosticSession(transport: "adb", reason: "USB ADB выбран при проверке каналов", proof: proof, readIdentity: read) { command, timeout in
            try adb.shellResult(serial, command, timeout: timeout)
        }
        try session.verify()
        return ReadOnlyChannelSession(mode: .adb, summary: summary(proof), diagnosticSession: session) { try shellSummary(session) }
    }
    private static func webSession(_ client: ModemWebClient, password: String) throws -> ReadOnlyChannelSession {
        if password.isEmpty {
            let payload: [[String: Any]] = [["jsonrpc": "2.0", "id": 1, "method": "call", "params": [String(repeating: "0", count: 32), "zwrt_web", "web_login_info", [:]]]]
            let response = try client.transport.request(path: "/ubus/", data: JSONSerialization.data(withJSONObject: payload), contentType: "application/json", cookie: nil)
            try require(response.data.count <= 65536, "Слишком большой ответ веб-интерфейса")
            guard let array = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]], array.count == 1, let result = array[0]["result"] as? [Any], result.count == 2, result[0] as? Int == 0, let info = result[1] as? [String: Any], let challenge = info["zte_web_sault"] as? String, !challenge.isEmpty && challenge.utf8.count <= 1024 else {
                throw ConnectionProbeFailure(state: .unsupported, message: "Устройство не подтвердило известный протокол веб-интерфейса")
            }
            throw ConnectionProbeFailure(state: .authenticationRequired, message: "Веб-интерфейс доступен. Введите его пароль для чтения сведений.")
        }
        try client.login(password: password)
        let first = try client.identity(skipFirmwareCheck: true)
        try require(try client.identity(skipFirmwareCheck: true) == first, "Устройство веб-интерфейса изменилось во время проверки")
        let initial = ConnectionDeviceSummary(webIdentity: first, fields: ["firmware": first.firmware, "innerVersion": first.inner])
        return ReadOnlyChannelSession(mode: .web, summary: initial) {
            let current = try client.identity(skipFirmwareCheck: true)
            return ConnectionDeviceSummary(webIdentity: current, fields: ["firmware": current.firmware, "innerVersion": current.inner])
        }
    }
    private static func agentSummary(_ value: AgentAccessSnapshot) -> ConnectionDeviceSummary {
        var fields = ["hostname": value.hostname, "kernel": value.kernel, "uptimeSeconds": String(value.uptimeSeconds)]
        if let total = value.memoryTotalKiB { fields["memoryTotalKiB"] = String(total) }
        if let available = value.memoryAvailableKiB { fields["memoryAvailableKiB"] = String(available) }
        if let battery = value.batteryPercent { fields["batteryPercent"] = String(battery) }
        return ConnectionDeviceSummary(agentVersion: value.agentVersion, imei: value.imei, fields: fields)
    }
    private static func agentSession(_ client: AgentAccessClient, password: String) throws -> ReadOnlyChannelSession {
        let probe = try client.probe(password: password.isEmpty ? nil : password)
        guard let session = probe.session else {
            let message = probe.state == .passwordNotConfigured ? "Агент доступен, но пароль на устройстве ещё не настроен. Для настройки подготовьте SSH." : "Агент доступен, но авторизация не подтверждена. Введите пароль агента; пароль веб-интерфейса используется отдельно."
            throw ConnectionProbeFailure(state: .authenticationRequired, message: message)
        }
        let first = try session.snapshot()
        let initial = agentSummary(first)
        return ReadOnlyChannelSession(mode: .agent, summary: initial) { agentSummary(try session.snapshot()) }
    }
}
