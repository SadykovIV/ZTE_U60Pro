import Foundation

private final class FeedProtocol: URLProtocol {
    static let lock = NSLock()
    static var scenario = "different"
    static var agents: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        Self.lock.lock(); Self.agents.append(agent); let scenario = Self.scenario; Self.lock.unlock()
        if scenario == "error" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "private-token-canary", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://example.test/private-token-canary"]))
            return
        }
        let status = scenario == "fallback" && agent == "clash.meta" ? 503 : 200
        let body = scenario == "same" ? "same-document" : "document-for-" + agent
        let length = scenario == "oversized" ? VPNSubscriptionDownload.documentLimit + 1 : body.utf8.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain", "Content-Length": String(length)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct VPNSubscriptionDownloadTests {
    static func check(_ value: @autoclosure () -> Bool) throws { if !value() { throw IMEIError.message("Subscription download fixture failed") } }
    static func main() async throws {
        var checks = 0
        for invalid in ["http://example.test/private-token-canary", "https://user:pass@example.test/x", "https://example.test/x#token", "https://example.test/line\nbreak", "https://example.test:0/x", "https://example.test/\"", "https://example.test\\x"] {
            do { _ = try VPNSubscriptionDownload.validatedURL(invalid); throw IMEIError.message("TEST: invalid URL accepted") }
            catch { try check(!error.localizedDescription.contains("TEST:") && !error.localizedDescription.contains("private-token-canary")); checks += 1 }
        }
        for valid in ["https://example.test/private-token-canary", "https://[::1]:8443/path"] { _ = try VPNSubscriptionDownload.validatedURL(valid); checks += 1 }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for scenario in ["different", "same", "fallback", "oversized", "error"] {
            FeedProtocol.lock.lock(); FeedProtocol.scenario = scenario; FeedProtocol.agents = []; FeedProtocol.lock.unlock()
            do {
                let documents = try await VPNSubscriptionDownload.documents("https://example.test/private-token-canary", session: session)
                try check(scenario != "oversized" && scenario != "error")
                if scenario == "different" { try check(documents == ["document-for-clash.meta", "document-for-Happ/1.0"]) }
                if scenario == "same" { try check(documents == ["same-document"]) }
                if scenario == "fallback" { try check(documents == ["document-for-Happ/1.0"]) }
            } catch {
                try check(scenario == "oversized" || scenario == "error")
                try check(!error.localizedDescription.contains("private-token-canary") && !error.localizedDescription.contains("example.test"))
            }
            FeedProtocol.lock.lock(); let agents = FeedProtocol.agents; FeedProtocol.lock.unlock()
            try check(Set(agents) == ["clash.meta", "Happ/1.0"]); checks += 1
        }
        print("\(checks) VPN subscription download tests passed; URLProtocol only, no network")
    }
}
