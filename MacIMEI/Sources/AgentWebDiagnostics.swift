import Foundation

struct AgentWebObservation: Equatable, Sendable {
    var code: String
    var isHTML = false
    var available: Bool { code == "200" && isHTML }
    func display(_ translate: (String) -> String) -> String {
        if code.count == 3, Int(code) != nil { return "HTTP " + code + (isHTML ? " · HTML" : " · " + translate("ответ не HTML")) }
        return translate(description)
    }
    var description: String {
        if code.count == 3, Int(code) != nil { return "HTTP " + code + (isHTML ? " · HTML" : " · ответ не HTML") }
        switch code {
        case "timeout": return "Истекло время ожидания HTTP"
        case "refused": return "Соединение отклонено"
        case "cancelled": return "Проверка отменена"
        case "curl-unavailable": return "На модеме отсутствует curl"
        case "ssh-unavailable": return "Проверка через SSH недоступна"
        case "invalid-response": return "Некорректный ответ HTTP"
        case "invalid-address": return "Некорректный адрес модема"
        default: return "HTTP недоступен"
        }
    }
}

struct AgentWebStatus: Sendable {
    var url: String
    var loopback: AgentWebObservation
    var lan: AgentWebObservation
    var computer: AgentWebObservation
    var log: String {
        "Agent web: url=" + url + " loopback=" + loopback.code + "/html=" + String(loopback.isHTML) +
        " lan=" + lan.code + "/html=" + String(lan.isHTML) + " computer=" + computer.code + "/html=" + String(computer.isHTML)
    }
    var warning: String? {
        if computer.available { return nil }
        if loopback.available || lan.available { return "Веб-панель отвечает на модеме, но доступ с этого компьютера не подтверждён. Откройте указанный HTTP-адрес и проверьте настройки браузера, прокси и сети." }
        return "Доступ к веб-панели не подтверждён. Это отдельная проверка HTTP; состояние процесса агента показано выше. Результаты сохранены в журнале."
    }
}

enum AgentWebDiagnostics {
    static func collect(engine: ModemEngine) -> AgentWebStatus {
        collect(host: engine.connection.host) { command in
            let result = try engine.transport.run(command, input: nil, timeout: 8)
            try require(result.status == 0, "Проверка через SSH недоступна")
            return CommandText.decode(result.stdout)
        }
    }
    static func address(_ host: String) throws -> URL {
        _ = try AgentRequestPolicy.baseURL(host: host)
        return URL(string: "http://" + host + ":8080/")!
    }
    static func command(host: String) throws -> String {
        _ = try address(host)
        return """
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        probe() {
          if ! command -v curl >/dev/null 2>&1; then printf 'AGENT_WEB %s curl-unavailable no\\n' "$1"; return; fi
          value=$(curl -q --noproxy '*' --silent --output /dev/null --write-out '%{http_code} %{content_type}' --connect-timeout 2 --max-time 4 "$2" 2>/dev/null); rc=$?
          if test "$rc" != 0; then case "$rc" in 7) code=refused;; 28) code=timeout;; *) code=unreachable;; esac; html=no
          else code=${value%% *}; kind=${value#* }; case "$code" in [1-5][0-9][0-9]) ;; *) code=invalid-response;; esac
            case "$kind" in text/html|text/html\\;*) html=yes;; *) html=no;; esac
          fi
          printf 'AGENT_WEB %s %s %s\\n' "$1" "$code" "$html"
        }
        probe loopback http://127.0.0.1:8080/ &
        probe lan http://\(host):8080/ &
        wait
        """
    }
    static func parse(_ text: String) -> (AgentWebObservation, AgentWebObservation) {
        var found = [String: AgentWebObservation]()
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard words.count == 4, words[0] == "AGENT_WEB", ["loopback", "lan"].contains(words[1]), found[words[1]] == nil,
                  ["yes", "no"].contains(words[3]), validCode(words[2]) else {
                return (.init(code: "invalid-response"), .init(code: "invalid-response"))
            }
            found[words[1]] = .init(code: words[2], isHTML: words[3] == "yes")
        }
        return (found["loopback"] ?? .init(code: "invalid-response"), found["lan"] ?? .init(code: "invalid-response"))
    }
    private static func validCode(_ code: String) -> Bool {
        ["refused", "timeout", "unreachable", "curl-unavailable", "invalid-response"].contains(code) ||
        (code.count == 3 && Int(code).map { (100...599).contains($0) } == true)
    }
    static func collect(host: String, remote: @escaping (String) throws -> String,
                        http: @escaping (URL) -> AgentWebObservation = { AgentWebRoundtrip.probe($0) }) -> AgentWebStatus {
        guard let url = try? address(host), let script = try? command(host: host) else {
            let bad = AgentWebObservation(code: "invalid-address")
            return AgentWebStatus(url: "", loopback: bad, lan: bad, computer: bad)
        }
        let computer = AgentWebResultBox(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { computer.set(http(url)); group.leave() }
        let pair: (AgentWebObservation, AgentWebObservation)
        do { pair = parse(try remote(script)) }
        catch { pair = (.init(code: "ssh-unavailable"), .init(code: "ssh-unavailable")) }
        group.wait()
        return AgentWebStatus(url: url.absoluteString, loopback: pair.0, lan: pair.1, computer: computer.value)
    }
}

private final class AgentWebResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AgentWebObservation(code: "unreachable")
    func set(_ value: AgentWebObservation) { lock.lock(); stored = value; lock.unlock() }
    var value: AgentWebObservation { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Read response headers only. No body, redirect, credential, cookie or proxy is used.
private final class AgentWebRoundtrip: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0), lock = NSLock()
    private var result: AgentWebObservation?
    private let expected: URL
    init(_ expected: URL) { self.expected = expected }
    static func probe(_ url: URL) -> AgentWebObservation {
        let delegate = AgentWebRoundtrip(url)
        let config = AgentRequestPolicy.configuration()
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 4
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 4
        session.dataTask(with: request).resume()
        guard delegate.done.wait(timeout: .now() + 5) == .success else { return .init(code: "timeout") }
        delegate.lock.lock(); defer { delegate.lock.unlock() }
        return delegate.result ?? .init(code: "unreachable")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); result = .init(code: String(response.statusCode)); lock.unlock(); completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let http = challenge.failureResponse as? HTTPURLResponse, http.url == expected {
            lock.lock(); result = .init(code: String(http.statusCode), isHTML: http.mimeType?.lowercased() == "text/html"); lock.unlock()
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let http = response as? HTTPURLResponse, http.url == expected {
            result = .init(code: String(http.statusCode), isHTML: http.mimeType?.lowercased() == "text/html")
        } else { result = .init(code: "invalid-response") }
        completionHandler(.cancel)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if result == nil {
            let code = (error as? URLError)?.code
            result = .init(code: code == .timedOut ? "timeout" : code == .cannotConnectToHost ? "refused" : code == .cancelled ? "cancelled" : "unreachable")
        }
        lock.unlock(); done.signal()
    }
}
