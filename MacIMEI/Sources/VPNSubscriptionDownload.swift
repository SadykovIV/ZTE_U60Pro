import Foundation

/// Subscription URLs can contain credentials. Never surface URLSession's raw
/// error, store cookies, or write the URL/document into the application journal.
enum VPNSubscriptionDownload {
    static let documentLimit = 8 * 1024 * 1024
    static func validatedURL(_ source: String) throws -> URL {
        guard source.hasPrefix("https://"), source.utf8.count <= 8192,
              !source.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !source.contains("\\"), !source.contains("\""), !source.contains("#"),
              let c = URLComponents(string: source), c.scheme == "https", c.user == nil, c.password == nil,
              let host = c.host, !host.isEmpty, host.utf8.allSatisfy({ $0 < 128 }),
              c.port == nil || (1...65535).contains(c.port!), let url = c.url else {
            throw IMEIError.message("Нужна полная ссылка подписки HTTPS без пробелов и имени пользователя.")
        }
        return url
    }
    static func documents(_ source: String, session provided: URLSession? = nil) async throws -> [String] {
        let url = try validatedURL(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 65
        let session = provided ?? URLSession(configuration: configuration)
        defer { if provided == nil { session.invalidateAndCancel() } }
        async let first = document(url, agent: "clash.meta", session: session)
        async let second = document(url, agent: "Happ/1.0", session: session)
        let results = try await [first, second]
        var documents: [String] = []
        for result in results { if let result, !documents.contains(result) { documents.append(result) } }
        guard !documents.isEmpty else { throw IMEIError.message("Не удалось загрузить подписку через интернет компьютера. Проверьте подключение и ссылку.") }
        return documents
    }
    private static func document(_ url: URL, agent: String, session: URLSession) async throws -> String? {
            try Task.checkCancellation()
            var request = URLRequest(url: url); request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/yaml, application/json, */*", forHTTPHeaderField: "Accept")
            do {
                let (stream, response) = try await session.bytes(for: request, delegate: HTTPSRedirects())
                defer { stream.task.cancel() }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      response.expectedContentLength <= Int64(documentLimit) else { return nil }
                var data = Data(); data.reserveCapacity(min(documentLimit, max(0, Int(response.expectedContentLength))))
                for try await byte in stream {
                    guard data.count < documentLimit else { throw IMEIError.message("Содержимое подписки превышает 8 МиБ или пусто.") }
                    data.append(byte)
                }
                if let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Try the second supported representation; only fixed public
                // error text is returned if neither document can be fetched.
            }
        return nil
    }
}

private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 4, let raw = request.url?.absoluteString,
              (try? VPNSubscriptionDownload.validatedURL(raw)) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
