import Foundation
import Security

private struct TestFailure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message: message) }
}

/// Synthetic local certificate and RPC tests. Never opens a network connection.
@main enum MacEsimRegressionTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw TestFailure(message: "fixture directory required") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS " + name)
        }
        let privateText = "LPA:1$private.invalid$synthetic-secret"
        let codes: [(Int, EsimNetworkFailure)] = [
            (NSURLErrorTimedOut, .timeout), (NSURLErrorCannotFindHost, .dns),
            (NSURLErrorDNSLookupFailed, .dns), (NSURLErrorCannotConnectToHost, .connection),
            (NSURLErrorNotConnectedToInternet, .connection), (NSURLErrorNetworkConnectionLost, .connection),
            (NSURLErrorSecureConnectionFailed, .tls), (NSURLErrorServerCertificateHasBadDate, .tls),
            (NSURLErrorServerCertificateUntrusted, .tls), (NSURLErrorServerCertificateHasUnknownRoot, .tls),
            (NSURLErrorServerCertificateNotYetValid, .tls), (NSURLErrorClientCertificateRejected, .tls),
            (NSURLErrorClientCertificateRequired, .tls), (NSURLErrorCancelled, .cancelled),
            (NSURLErrorUnknown, .transport)
        ]
        try test("URL errors produce only fixed diagnostic codes") {
            for (code, expected) in codes {
                let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: privateText, "NSErrorFailingURLStringKey": privateText])
                let actual = EsimHTTPSRelay.classify(error)
                try check(actual == expected, "classification mismatch for " + String(code))
                let shown = EsimFailure.network(actual).localizedDescription + EsimLog.failureCode(.network(actual))
                try check(!shown.contains(privateText) && !shown.contains("private.invalid"), "private network error escaped")
            }
            try check(EsimHTTPSRelay.classify(NSError(domain: "synthetic", code: NSURLErrorTimedOut)) == .transport, "foreign domain misclassified")
        }
        func failure(_ raw: String, exit: Int32) throws -> EsimFailure {
            var decoder = EsimRPCDecoder()
            _ = try decoder.consume(JSONSerialization.data(withJSONObject: ["type":"result", "ok":false, "error":raw]))
            do { _ = try decoder.finish(exitCode: exit, operation: .list, before: nil) }
            catch let result as EsimFailure { return result }
            throw TestFailure(message: "failed result accepted")
        }
        try test("exit one preserves fixed backend failure and redacts arbitrary error") {
            for exit: Int32 in [0, 1] {
                if case .backend(let code) = try failure("lpac_failed", exit: exit) { try check(code == "lpac_failed", "fixed error lost") }
                else { throw TestFailure(message: "backend failure became transport error") }
                let unknown = try failure(privateText, exit: exit)
                try check(EsimLog.failureCode(unknown) == "unrecognized_backend_error" && !unknown.localizedDescription.contains(privateText), "private backend error escaped")
            }
        }
        try test("SSH loss and success with nonzero exit remain unconfirmed") {
            for exit: Int32 in [2, 255, -1] {
                guard case .transport = try failure("lpac_failed", exit: exit) else { throw TestFailure(message: "SSH failure attributed to backend") }
            }
            var decoder = EsimRPCDecoder()
            _ = try decoder.consume(JSONSerialization.data(withJSONObject:["type":"result", "ok":true, "snapshot":["ok":true,"eid":String(repeating:"1",count:32),"profiles":[]],"changed":false,"notifications_pending":false]))
            do { _ = try decoder.finish(exitCode:1,operation:.list,before:nil); throw TestFailure(message:"nonzero success accepted") }
            catch is TestFailure { throw TestFailure(message:"nonzero success accepted") }
            catch let result as EsimFailure { guard case .transport = result else { throw TestFailure(message:"wrong nonzero failure") } }
        }
        func certificate(_ name: String) throws -> SecCertificate {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name + ".der"))
            guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else { throw TestFailure(message:"invalid fixture certificate") }
            return certificate
        }
        let first = try certificate("root-a"), second = try certificate("root-b"), leaf = try certificate("leaf")
        func trusted(_ roots: [SecCertificate], host: String = "fixture.example", future: Bool = false) throws -> Bool {
            var result: SecTrust?
            try check(SecTrustCreateWithCertificates([leaf, first] as CFArray, SecPolicyCreateSSL(true, host as CFString), &result) == errSecSuccess, "trust creation failed")
            guard let trust = result else { throw TestFailure(message:"missing trust") }
            // All certificate material is local; even system discovery must not use networking.
            try check(SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess, "network disable failed")
            if future { try check(SecTrustSetVerifyDate(trust, Date(timeIntervalSinceNow: 3*86400) as CFDate) == errSecSuccess, "date set failed") }
            return EsimHTTPSRelay.evaluateTrust(trust, host: host, roots: roots)
        }
        try test("custom trust accepts matching leaf with either root bundle order") {
            try check(try trusted([first,second]), "first custom anchor rejected")
            try check(try trusted([second,first]), "second custom anchor rejected")
        }
        try test("custom trust still rejects wrong hostname expired and untrusted leaf") {
            try check(try !trusted([first,second],host:"other.example"), "wrong hostname accepted")
            try check(try !trusted([first,second],future:true), "expired certificate accepted")
            try check(try !trusted([second]), "untrusted issuer accepted")
        }
        try test("PEM bundle parser accepts two certificates and rejects invalid bundle") {
            let pem = try Data(contentsOf:directory.appendingPathComponent("roots.pem"))
            _ = try EsimHTTPSRelay(certificatePEM:pem)
            try check(try EsimHTTPSRelay.certificates(pem).count == 2,"PEM bundle lost an anchor")
            for invalid in [Data(), Data("not a certificate".utf8), Data("-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----".utf8), pem + pem, pem + Data("unexpected suffix".utf8)] {
                do { _ = try EsimHTTPSRelay(certificatePEM:invalid); throw TestFailure(message:"malformed bundle accepted") }
                catch is TestFailure { throw TestFailure(message:"malformed bundle accepted") }
                catch is EsimFailure { }
            }
        }
        print("PASS \(passed) focused regression groups; 15 URL codes; no network or modem")
    }
}
