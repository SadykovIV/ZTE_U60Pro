import Foundation

/// The deployed agent has an HTTP JSON API, not an SSH or arbitrary-shell API.
/// These contracts follow ModemAgent/agent/src/server.rs and handlers.rs.
enum AgentAccessError: Error, LocalizedError {
    case invalidAddress, forbiddenRequest, unreachable, redirect, oversized, malformed
    case authenticationRequired, invalidPassword, passwordNotConfigured, loginAlreadyAttempted, rateLimited
    case httpStatus(Int), identityChanged, identityUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Для API агента нужен точный IPv4-адрес модема; используется порт 9090."
        case .forbiddenRequest: return "Этот запрос не входит в разрешённые операции чтения API агента."
        case .unreachable: return "API агента не ответил или соединение прервано."
        case .redirect: return "API агента попытался перенаправить запрос; пароль и токен не передаются на другой адрес."
        case .oversized: return "Ответ API агента превышает допустимый размер."
        case .malformed: return "Ответ API агента не соответствует поддерживаемому формату."
        case .authenticationRequired: return "Для API агента требуется отдельный пароль или новый вход."
        case .invalidPassword: return "API агента отклонил пароль. Автоматический повтор входа не выполняется."
        case .passwordNotConfigured: return "API агента доступен, но пароль на нём не настроен."
        case .loginAlreadyAttempted: return "Вход в API агента уже запрошен; повтор возможен только новым явным действием."
        case .rateLimited: return "API агента временно ограничил попытки входа."
        case .httpStatus(let status): return "API агента вернул HTTP \(status)."
        case .identityChanged: return "Идентификация или сеанс работы агента изменились во время чтения."
        case .identityUnavailable: return "API агента не подтвердил ожидаемый IMEI устройства."
        }
    }
}
struct AgentHTTPReply {
    var status: Int
    var data: Data
    var url: URL
}
protocol AgentHTTPTransport {
    func send(_ request: URLRequest) throws -> AgentHTTPReply
}

enum AgentRequestPolicy {
    static let byteLimit = 1_048_576
    static let requestTimeout: TimeInterval = 5
    static let resourceTimeout: TimeInterval = 8
    static let allowedReads = Set(["/api/health", "/api/device", "/api/dashboard", "/api/sim/imei"])
    static func baseURL(host: String) throws -> URL {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) } &&
            (part.count == 1 || part.first != "0") && Int(part).map { (0...255).contains($0) } == true
        }), let url = URL(string: "http://" + host + ":9090") else { throw AgentAccessError.invalidAddress }
        return url
    }
    static func validate(_ request: URLRequest, base: URL) throws {
        guard let url = request.url, url.scheme == "http", url.host == base.host, url.port == 9090,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              (request.httpMethod == "GET" && allowedReads.contains(url.path) && request.httpBody == nil) ||
              (request.httpMethod == "POST" && url.path == "/api/auth/login") else { throw AgentAccessError.forbiddenRequest }
    }
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
    static func validateResponse(status: Int, url: URL?, expected: URL, length: Int64) throws {
        if (300...399).contains(status) || url != expected { throw AgentAccessError.redirect }
        if length > Int64(byteLimit) { throw AgentAccessError.oversized }
    }
}

/// No shared URLSession, redirect, proxy, cookie, cache, or credential store.
/// Error messages never include response bodies, passwords, bearer tokens, or requests.
private final class AgentRoundtrip: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0), lock = NSLock()
    private let expected: URL
    private var responseStatus: Int?, bytes = Data(), failure: AgentAccessError?
    init(expected: URL) { self.expected = expected }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); failure = .redirect; lock.unlock()
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let http = response as? HTTPURLResponse else { failure = .malformed; completionHandler(.cancel); return }
        do {
            try AgentRequestPolicy.validateResponse(status: http.statusCode, url: http.url, expected: expected, length: response.expectedContentLength)
            responseStatus = http.statusCode
            completionHandler(.allow)
        } catch { failure = error as? AgentAccessError ?? .malformed; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count > AgentRequestPolicy.byteLimit - bytes.count { failure = .oversized; dataTask.cancel() }
        else { bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); if error != nil && failure == nil { failure = .unreachable }; lock.unlock(); done.signal()
    }
    func execute(_ request: URLRequest) throws -> AgentHTTPReply {
        let session = URLSession(configuration: AgentRequestPolicy.configuration(), delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request); task.resume()
        guard done.wait(timeout: .now() + AgentRequestPolicy.resourceTimeout + 2) == .success else { task.cancel(); throw AgentAccessError.unreachable }
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard let status = responseStatus else { throw AgentAccessError.malformed }
        return AgentHTTPReply(status: status, data: bytes, url: expected)
    }
}
final class HTTPAgentTransport: AgentHTTPTransport {
    let base: URL
    init(host: String) throws { base = try AgentRequestPolicy.baseURL(host: host) }
    func send(_ request: URLRequest) throws -> AgentHTTPReply {
        try AgentRequestPolicy.validate(request, base: base)
        return try AgentRoundtrip(expected: request.url!).execute(request)
    }
}

enum AgentAccessState: String, Sendable { case needsAuthentication, passwordNotConfigured, authenticated }
struct AgentAccessProbe {
    var state: AgentAccessState
    var session: AgentAccessSession?
}
struct AgentAccessSnapshot: Equatable, Sendable {
    var hostname: String
    var kernel: String
    var uptimeSeconds: UInt64
    var loadAverage: [Double]
    var agentVersion: String
    var imei: String?
    var memoryTotalKiB: UInt64?
    var memoryAvailableKiB: UInt64?
    var batteryPercent: Int?
    var limitations: String { "API агента не сообщает CID, boot ID, модель и версию прошивки; произвольные команды shell через него недоступны." }
}
private struct AgentEnvelope<T: Decodable>: Decodable { var ok: Bool; var data: T }
private struct AgentToken: Decodable { var token: String }
private struct AgentHealth: Decodable { var status: String; var version: String; var ttl_schema_version: Int? }
private struct AgentDevice: Decodable {
    var hostname: String; var uptime_secs: UInt64; var load_avg: [Double]; var kernel: String
    func validate() throws {
        guard !hostname.isEmpty, hostname.utf8.count <= 255, !kernel.isEmpty, kernel.utf8.count <= 4096,
              uptime_secs <= 100 * 366 * 24 * 3600, load_avg.count == 3,
              load_avg.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) else { throw AgentAccessError.malformed }
    }
}
private struct AgentMemory: Decodable { var total_kb: UInt64; var available_kb: UInt64 }
private struct AgentBattery: Decodable { var capacity: Int }
private struct AgentDashboard: Decodable { var device: AgentDevice; var memory: AgentMemory?; var battery: AgentBattery? }

final class AgentAccessClient: @unchecked Sendable {
    let base: URL
    private let transport: AgentHTTPTransport
    private let attemptLock = NSLock()
    private var loginAttempted = false
    init(host: String, transport: AgentHTTPTransport? = nil) throws {
        base = try AgentRequestPolicy.baseURL(host: host)
        self.transport = try transport ?? HTTPAgentTransport(host: host)
    }
    fileprivate func request(_ path: String, token: String? = nil, password: String? = nil) throws -> AgentHTTPReply {
        let url = base.appendingPathComponent(String(path.dropFirst()))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: AgentRequestPolicy.requestTimeout)
        request.httpMethod = password == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("ZTE-IMEI-Studio", forHTTPHeaderField: "User-Agent")
        if let password {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        try AgentRequestPolicy.validate(request, base: base)
        let result: AgentHTTPReply
        do { result = try transport.send(request) }
        catch let error as AgentAccessError { throw error }
        catch { throw AgentAccessError.unreachable }
        try AgentRequestPolicy.validateResponse(status: result.status, url: result.url, expected: url, length: Int64(result.data.count))
        return result
    }
    fileprivate static func decode<T: Decodable>(_ type: T.Type, _ result: AgentHTTPReply) throws -> T {
        if result.status == 401 { throw AgentAccessError.authenticationRequired }
        if result.status == 403 { throw AgentAccessError.passwordNotConfigured }
        if result.status == 429 { throw AgentAccessError.rateLimited }
        guard result.status == 200 else { throw AgentAccessError.httpStatus(result.status) }
        do {
            let envelope = try JSONDecoder().decode(AgentEnvelope<T>.self, from: result.data)
            guard envelope.ok else { throw AgentAccessError.malformed }
            return envelope.data
        } catch let error as AgentAccessError { throw error }
        catch { throw AgentAccessError.malformed }
    }
    /// A supplied password permits one login request on this client. It is never retained.
    func probe(password: String? = nil) throws -> AgentAccessProbe {
        let response = try request("/api/health")
        if response.status == 401 || response.status == 403 {
            struct Rejection: Decodable { var ok: Bool; var error: String }
            guard let rejection = try? JSONDecoder().decode(Rejection.self, from: response.data), !rejection.ok,
                  (response.status == 401 && rejection.error == "unauthorized") ||
                  (response.status == 403 && rejection.error.hasPrefix("no password configured.")) else { throw AgentAccessError.malformed }
        }
        if response.status == 403 { return AgentAccessProbe(state: .passwordNotConfigured, session: nil) }
        guard response.status == 401 else {
            // The actual deployed API protects health. An open or unrelated service
            // cannot be labelled an authenticated agent based on an HTTP 200.
            throw response.status == 429 ? AgentAccessError.rateLimited : AgentAccessError.malformed
        }
        guard let password, !password.isEmpty else { return AgentAccessProbe(state: .needsAuthentication, session: nil) }
        guard password.utf8.count <= 1024 && !password.contains("\0") else { throw AgentAccessError.invalidPassword }
        attemptLock.lock()
        let attempted = loginAttempted; loginAttempted = true
        attemptLock.unlock()
        guard !attempted else { throw AgentAccessError.loginAlreadyAttempted }
        let login = try request("/api/auth/login", password: password)
        if login.status == 401 { throw AgentAccessError.invalidPassword }
        let token = try Self.decode(AgentToken.self, login).token
        guard token.count == 32, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AgentAccessError.malformed }
        let health = try Self.decode(AgentHealth.self, request("/api/health", token: token))
        guard health.status == "ok", !health.version.isEmpty, health.version.utf8.count <= 128,
              health.ttl_schema_version.map({ (1...100).contains($0) }) ?? true else { throw AgentAccessError.malformed }
        return AgentAccessProbe(state: .authenticated, session: AgentAccessSession(client: self, token: token, version: health.version))
    }
}

/// Opaque in-memory bearer session. No token/password serialization or logging API.
final class AgentAccessSession: @unchecked Sendable {
    private let client: AgentAccessClient, token: String, version: String
    private let readLock = NSLock()
    private var firstIMEI: String?, firstHostname: String?, firstKernel: String?, lastUptime: UInt64?
    fileprivate init(client: AgentAccessClient, token: String, version: String) {
        self.client = client; self.token = token; self.version = version
    }
    private func imei() throws -> String? {
        let result = try client.request("/api/sim/imei", token: token)
        if result.status == 404 || result.status == 503 { return nil }
        struct IMEIValue: Decodable { var imei: String }
        let value = try AgentAccessClient.decode(IMEIValue.self, result).imei
        guard IMEI.valid(value) else { throw AgentAccessError.malformed }
        return value
    }
    func snapshot(expectedIMEI: String? = nil) throws -> AgentAccessSnapshot {
        readLock.lock(); defer { readLock.unlock() }
        let beforeIMEI = try imei()
        if let expectedIMEI { guard IMEI.valid(expectedIMEI), beforeIMEI == expectedIMEI else { throw AgentAccessError.identityUnavailable } }
        if let firstIMEI { guard beforeIMEI == firstIMEI else { throw AgentAccessError.identityChanged } }
        let device = try AgentAccessClient.decode(AgentDevice.self, client.request("/api/device", token: token))
        try device.validate()
        let dashboard = try AgentAccessClient.decode(AgentDashboard.self, client.request("/api/dashboard", token: token))
        try dashboard.device.validate()
        guard device.hostname == dashboard.device.hostname, device.kernel == dashboard.device.kernel,
              dashboard.device.uptime_secs >= device.uptime_secs else { throw AgentAccessError.identityChanged }
        let afterIMEI = try imei()
        let afterDevice = try AgentAccessClient.decode(AgentDevice.self, client.request("/api/device", token: token))
        try afterDevice.validate()
        guard beforeIMEI == afterIMEI, device.hostname == afterDevice.hostname, device.kernel == afterDevice.kernel,
              afterDevice.uptime_secs >= dashboard.device.uptime_secs else { throw AgentAccessError.identityChanged }
        if let firstHostname { guard device.hostname == firstHostname && device.kernel == firstKernel else { throw AgentAccessError.identityChanged } }
        if let lastUptime { guard device.uptime_secs >= lastUptime else { throw AgentAccessError.identityChanged } }
        if let memory = dashboard.memory {
            guard memory.total_kb > 0, memory.total_kb <= 1_099_511_627_776, memory.available_kb <= memory.total_kb else { throw AgentAccessError.malformed }
        }
        firstIMEI = beforeIMEI; firstHostname = device.hostname; firstKernel = device.kernel; lastUptime = afterDevice.uptime_secs
        func clean(_ value: String) -> String { ActivityJournal.sanitize(value.replacingOccurrences(of: token, with: "[REDACTED]")) }
        return AgentAccessSnapshot(hostname: clean(device.hostname), kernel: clean(device.kernel), uptimeSeconds: afterDevice.uptime_secs,
            loadAverage: dashboard.device.load_avg, agentVersion: clean(version), imei: beforeIMEI,
            memoryTotalKiB: dashboard.memory?.total_kb, memoryAvailableKiB: dashboard.memory?.available_kb,
            batteryPercent: dashboard.battery.flatMap { (0...100).contains($0.capacity) ? $0.capacity : nil })
    }
}
