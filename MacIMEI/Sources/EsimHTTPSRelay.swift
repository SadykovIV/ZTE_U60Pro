import Foundation
import Security

/// Ephemeral HTTPS relay. No request/response data is logged or cached.
final class EsimHTTPSRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxBody = 4 * 1024 * 1024
    private let roots: [SecCertificate]
    private var bytes = Data()
    private var status = 0
    private var failed = false
    private(set) var failure: EsimNetworkFailure?
    private let done = DispatchSemaphore(value: 0)
    init(certificatePEM: Data) throws {
        roots = try Self.certificates(certificatePEM)
    }
    static func certificates(_ data: Data) throws -> [SecCertificate] {
        guard data.count <= 16384, let pem = String(data: data, encoding: .utf8) else { throw EsimFailure.resources }
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        var remaining = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [SecCertificate] = []
        var seen = Set<Data>()
        while !remaining.isEmpty {
            guard result.count < 16, remaining.hasPrefix(begin), let stop = remaining.range(of: end) else { throw EsimFailure.resources }
            let body = remaining[remaining.index(remaining.startIndex, offsetBy: begin.count)..<stop.lowerBound]
            guard let der = Data(base64Encoded: body.filter { !$0.isWhitespace }), seen.insert(der).inserted,
                  let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw EsimFailure.resources }
            result.append(cert)
            remaining = String(remaining[stop.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !result.isEmpty else { throw EsimFailure.resources }
        return result
    }
    static func request(_ payload: [String: Any]) throws -> URLRequest {
        guard let raw = payload["url"] as? String, raw.utf8.count <= 8192, raw.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !raw.contains("\\"), let parts = URLComponents(string: raw), parts.scheme == "https",
              let host = parts.host, EsimValidation.domain(host), parts.percentEncodedHost?.contains("%") != true, parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil, let url = parts.url,
              let tx = payload["tx"] as? String, let headers = payload["headers"] as? [String] else { throw EsimFailure.protocolError }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"; request.httpBody = try EsimValidation.hex(tx, maxBytes: maxBody)
        request.httpShouldHandleCookies = false
        var seen = Set<String>()
        for header in headers {
            guard header.utf8.count <= 8192, header.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }), let colon = header.firstIndex(of: ":") else { throw EsimFailure.protocolError }
            let name = String(header[..<colon]).lowercased()
            guard ["content-type", "user-agent", "x-admin-protocol"].contains(name), seen.insert(name).inserted else { throw EsimFailure.protocolError }
            request.setValue(String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: name)
        }
        return request
    }
    func perform(_ payload: [String: Any]) -> (Int, Data) {
        guard let request = try? Self.request(payload) else { failure = .invalidRequest; return (0, Data()) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
        done.wait(); session.finishTasksAndInvalidate()
        return failed ? (0, Data()) : (status, bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { failed = true; failure = .redirect; completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The SM-DP+ TLS endpoint requests an optional client certificate.
        // Explicitly continue without a client identity; server trust is
        // still checked independently below, with hostname and pinned CA.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.useCredential, nil)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let host = challenge.protectionSpace.host.lowercased()
        if Self.evaluateTrust(trust, host: host, roots: roots) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { failed = true; failure = .tls; completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    static func evaluateTrust(_ trust: SecTrust, host: String, roots: [SecCertificate]) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess else { return false }
        // GSMA RSP is the eSIM PKI, shared by multiple SM-DP+ providers.
        // Extend trust only for this private relay; keep system roots and
        // SSL hostname, validity and chain verification for every endpoint.
        guard !roots.isEmpty, SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(Self.maxBody) else { failed = true; failure = .bodyLimit; completionHandler(.cancel); return }
        status = http.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count <= Self.maxBody - data.count else { failed = true; failure = .bodyLimit; dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failed = true; if failure == nil { failure = Self.classify(error) } }
        done.signal()
    }
    static func classify(_ error: Error) -> EsimNetworkFailure {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return .transport }
        switch value.code {
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return .connection
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired: return .tls
        case NSURLErrorCancelled: return .cancelled
        default: return .transport
        }
    }
}
