import Foundation

/// Only an explicit password rejection is an invalid password. Transport,
/// protocol and session failures must not ask the user to change credentials.
enum ModemWebError: Error, LocalizedError, Equatable {
    case passwordRequired
    case invalidPassword
    case authenticationRejected(code: Int)
    case malformedResponse(String)
    case rpcRejected(method: String, code: Int)

    var errorDescription: String? {
        switch self {
        case .passwordRequired: return "Введите пароль веб-интерфейса"
        case .invalidPassword: return "Вход отклонён: неверный пароль веб-интерфейса."
        case .authenticationRejected(let code): return "Веб-интерфейс отклонил вход (код \(code))."
        case .malformedResponse(let detail): return "Некорректный ответ веб-интерфейса: " + detail
        case .rpcRejected(let method, let code): return "Веб-интерфейс отклонил операцию \(method) (код \(code))."
        }
    }
}

struct WebIdentity: Codable, Equatable, Sendable {
    var imei: String
    var firmware: String
    var inner: String
    init(_ object: [String: Any], skipFirmwareCheck: Bool = false) throws {
        guard let imei = object["imei"] as? String, let firmware = object["integrate_version"] as? String, let inner = object["wa_inner_version"] as? String else {
            throw IMEIError.message("Веб-интерфейс не вернул идентификатор и прошивку устройства")
        }
        try require(IMEI.valid(imei), "Веб-интерфейс вернул некорректный IMEI")
        try require(!firmware.isEmpty && !inner.isEmpty && firmware.utf8.count <= 256 && inner.utf8.count <= 256 && !firmware.contains("\0") && !inner.contains("\0"), "Некорректные сведения о прошивке")
        try require(skipFirmwareCheck || (firmware == "CN_ZTE_MU5250V1.0.0B31" && inner == "BD_CNMU5250V1.0.0B31"), "Автоматическая настройка поддерживает только проверенную MU5250 B31")
        self.imei = imei; self.firmware = firmware; self.inner = inner
    }
}
struct WebReply { var data: Data; var headers: [String: String] }
protocol WebTransport { func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply }

/// Each request has its own ephemeral session: no disk cookies, cache, proxy or redirect.
private final class WebRoundtrip: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0), mutex = NSLock()
    var buffer = Data(), failure: Error?, headers: [String: String] = [:]
    let limit = 32 * 1024 * 1024
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        mutex.lock(); defer { mutex.unlock() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= limit else {
            failure = IMEIError.message("Модем вернул HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1); размер ответа \(response.expectedContentLength) байт"); completionHandler(.cancel); return
        }
        for (k,v) in http.allHeaderFields { headers[String(describing:k).lowercased()] = String(describing:v) }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        mutex.lock(); defer { mutex.unlock() }
        if buffer.count + data.count > limit { failure = IMEIError.message("Ответ модема превышает допустимый размер"); dataTask.cancel() }
        else { buffer += data }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        mutex.lock(); if failure == nil { failure = error }; mutex.unlock(); done.signal()
    }
    func execute(_ request: URLRequest) throws -> WebReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]; configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 75
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request); task.resume()
        guard done.wait(timeout: .now() + 80) == .success else { task.cancel(); throw IMEIError.message("Веб-интерфейс не ответил вовремя") }
        mutex.lock(); defer { mutex.unlock() }
        if let failure { throw failure }
        return WebReply(data: buffer, headers: headers)
    }
}
final class HTTPWebTransport: WebTransport {
    let base: URL
    init(host: String) throws {
        let p = host.split(separator: ".", omittingEmptySubsequences: false)
        try require(p.count == 4 && p.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && (Int($0) ?? 256) <= 255 }, "Введите IPv4-адрес модема")
        guard let base = URL(string: "http://" + host) else { throw IMEIError.message("Некорректный адрес") }; self.base = base
    }
    func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply {
        try require(["/ubus/", "/backup/back_parameter", "/cgi-bin/cgi-upload"].contains(path), "Неизвестный веб-метод")
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = data == nil ? "GET" : "POST"; request.httpBody = data
        request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(base.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let cookie { request.setValue("webtoken=\"" + cookie + "\"", forHTTPHeaderField: "Cookie") }
        return try WebRoundtrip().execute(request)
    }
}
final class ModemWebClient {
    let transport: WebTransport
    var session = String(repeating: "0", count: 32)
    var cookie: String?
    init(host: String, transport: WebTransport? = nil) throws { self.transport = try transport ?? HTTPWebTransport(host: host) }
    private func statusCode(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }
    private func call(_ object: String, _ method: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let payload: [[String: Any]] = [["jsonrpc": "2.0", "id": 1, "method": "call", "params": [session, object, method, args]]]
        let reply = try transport.request(path: "/ubus/", data: JSONSerialization.data(withJSONObject: payload), contentType: "application/json", cookie: cookie)
        guard let array = (try? JSONSerialization.jsonObject(with: reply.data)) as? [[String: Any]], array.count == 1,
              let result = array[0]["result"] as? [Any], let code = statusCode(result.first) else {
            throw ModemWebError.malformedResponse("не получен результат \(method)")
        }
        guard code == 0 else { throw ModemWebError.rpcRejected(method: method, code: code) }
        guard result.count == 1 || (result.count == 2 && result[1] is [String: Any]) else {
            throw ModemWebError.malformedResponse("неверные данные \(method)")
        }
        if let setCookie = reply.headers["set-cookie"] {
            for part in setCookie.components(separatedBy: ";") {
                let value = part.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("webtoken=") {
                    let token = value.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    guard !token.isEmpty && token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 34 && $0 != 59 }) else {
                        throw ModemWebError.malformedResponse("неверный токен веб-сессии")
                    }
                    cookie = token
                }
            }
        }
        return result.count > 1 ? (result[1] as? [String: Any] ?? [:]) : [:]
    }
    func login(password: String) throws {
        session = String(repeating: "0", count: 32); cookie = nil
        var authenticated = false
        defer { if !authenticated { session = String(repeating: "0", count: 32); cookie = nil } }
        guard !password.isEmpty else { throw ModemWebError.passwordRequired }
        try require(password.utf8.count <= 256 && !password.contains("\0"), "Пароль веб-интерфейса имеет недопустимую длину или содержит нулевой символ")
        let info = try call("zwrt_web", "web_login_info")
        guard let salt = info["zte_web_sault"] as? String, !salt.isEmpty, salt.utf8.count <= 1024 else { throw ModemWebError.malformedResponse("не получен challenge веб-интерфейса") }
        let first = digest(Data(password.utf8)).uppercased()
        let hash = digest(Data((first + salt).utf8)).uppercased()
        let result = try call("zwrt_web", "web_login", ["password": hash])
        guard let code = statusCode(result["result"]) else { throw ModemWebError.malformedResponse("не получен код входа") }
        if code == 1 { throw ModemWebError.invalidPassword }
        guard code == 0 else { throw ModemWebError.authenticationRejected(code: code) }
        guard let id = result["ubus_rpc_session"] as? String, id.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }), id != String(repeating: "0", count: 32), cookie != nil else {
            throw ModemWebError.malformedResponse("вход подтверждён, но не получена действительная веб-сессия")
        }
        session = id; authenticated = true
    }
    func identity(skipFirmwareCheck: Bool = false) throws -> WebIdentity { try WebIdentity(call("zwrt_web", "device_info"), skipFirmwareCheck: skipFirmwareCheck) }
    func advertisesDirectADB() throws -> Bool {
        let payload: [[String: Any]] = [["jsonrpc": "2.0", "id": 1, "method": "list", "params": ["zwrt_bsp.usb"]]]
        let reply = try transport.request(path: "/ubus/", data: JSONSerialization.data(withJSONObject: payload), contentType: "application/json", cookie: cookie)
        guard let array = (try? JSONSerialization.jsonObject(with: reply.data)) as? [[String: Any]], array.count == 1,
              let objects = array[0]["result"] as? [String: Any] else { throw ModemWebError.malformedResponse("не получен список возможностей USB") }
        guard let object = objects["zwrt_bsp.usb"] as? [String: Any], let set = object["set"] as? [String: Any] else { return false }
        return set["mode"] as? String == "String" || set["mode"] as? String == "string"
    }
    func enableDirectADB() throws {
        let response = try call("zwrt_bsp.usb", "set", ["mode": "debug"])
        if let value = response["result"] ?? response["status"] {
            guard let code = statusCode(value) else { throw ModemWebError.malformedResponse("неверный статус включения USB debug") }
            guard code == 0 else { throw ModemWebError.rpcRejected(method: "zwrt_bsp.usb.set", code: code) }
        }
    }
    func freshBackup() throws -> Data {
        _ = try call("zwrt_mc.device.manager", "device_backup_proc", ["procType": "web"])
        Thread.sleep(forTimeInterval: 2)
        let reply = try transport.request(path: "/backup/back_parameter", data: nil, contentType: nil, cookie: cookie)
        try require(reply.data.count >= 24 && reply.data.count <= 8 * 1024 * 1024 && reply.data.prefix(8) == Data("Salted__".utf8), "Получен некорректный зашифрованный бэкап")
        return reply.data
    }
    func upload(_ data: Data) throws {
        let boundary = "----zte-imei-" + UUID().uuidString
        var body = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"filename\"\r\n\r\n/tmp/back_parameter\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"filedata\"; filename=\"back_parameter\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8)
        body += data; body += Data("\r\n--\(boundary)--\r\n".utf8)
        let reply = try transport.request(path: "/cgi-bin/cgi-upload", data: body, contentType: "multipart/form-data; boundary=" + boundary, cookie: cookie)
        guard let object = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any], object["sha256sum"] as? String == digest(data) else { throw IMEIError.message("SHA256 загруженного бэкапа не совпал. Восстановление не запущено.") }
    }
    func rebootForADB() throws { _ = try call("zwrt_mc.device.manager", "device_reboot", ["moduleName": "web"]) }
    func restore() throws { _ = try call("zwrt_mc.device.manager", "device_restore_proc", ["procType": "web"]) }
}
