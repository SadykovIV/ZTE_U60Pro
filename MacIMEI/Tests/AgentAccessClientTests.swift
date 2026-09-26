import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func rejects(_ expected: AgentAccessError? = nil, _ work: () throws -> Void) throws {
    do { try work() } catch let e as Failure { throw e } catch {
        if let expected { try check(error.localizedDescription == expected.localizedDescription, "Unexpected error: " + error.localizedDescription) }
        return
    }
    throw Failure.assertion("Expected refusal")
}
private let token = "0123456789abcdef0123456789abcdef"
private let imei = "867123456789017"
private final class MockAgent: AgentHTTPTransport {
    var requests: [URLRequest] = []
    var noPassword = false, invalidPassword = false, redirect = false, oversize = false, malformed = false, falseOK = false
    var unavailable = false, unprotected = false, genericUnauthorized = false, changedIMEI = false, reboot = false
    var missingIMEI = false, secretError = false, secretHostname = false
    var expired = false, authenticatedRedirect = false, authenticatedOversize = false, invalidDevice = false, invalidMemory = false
    var loginCount = 0, imeiReads = 0, deviceReads = 0
    func result(_ status: Int, _ object: [String: Any], _ request: URLRequest) throws -> AgentHTTPReply {
        AgentHTTPReply(status: status, data: try JSONSerialization.data(withJSONObject: object), url: request.url!)
    }
    func send(_ request: URLRequest) throws -> AgentHTTPReply {
        requests.append(request)
        if secretError { throw IMEIError.message("PASSWORD-SECRET " + token) }
        if unavailable { throw AgentAccessError.unreachable }
        if redirect { return AgentHTTPReply(status: 302, data: Data(), url: URL(string: "http://192.0.2.99:9090/api/health")!) }
        if oversize { return AgentHTTPReply(status: 200, data: Data(repeating: 0, count: AgentRequestPolicy.byteLimit + 1), url: request.url!) }
        if request.url!.path == "/api/auth/login" {
            loginCount += 1
            if invalidPassword { return try result(401, ["ok":false,"error":"invalid credentials PASSWORD-SECRET"], request) }
            if malformed { return try result(200, ["ok":true,"data":["token":"\n" + token]], request) }
            return try result(200, ["ok": !falseOK, "data":["token": token]], request)
        }
        if request.value(forHTTPHeaderField: "Authorization") == nil {
            if noPassword { return try result(403,["ok":false,"error":"no password configured. Set ZTE_AGENT_PASSWORD environment variable."],request) }
            if unprotected { return try result(200,["ok":true,"data":["status":"ok","version":"x"]],request) }
            if genericUnauthorized { return try result(401,["message":"unauthorized"],request) }
            return try result(401,["ok":false,"error":"unauthorized"],request)
        }
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "Wrong bearer")
        if expired { return try result(401,["ok":false,"error":"unauthorized"],request) }
        if authenticatedRedirect { return AgentHTTPReply(status:307,data:Data(),url:URL(string:"http://192.0.2.99:9090/api/device")!) }
        if authenticatedOversize { return AgentHTTPReply(status:200,data:Data(repeating:0,count:AgentRequestPolicy.byteLimit+1),url:request.url!) }
        let device: [String: Any] = ["hostname":secretHostname ? token : "MU5250", "kernel":"Linux fixture", "uptime_secs":100,"load_avg":invalidDevice ? [-1,0.2,0.3] : [0.1,0.2,0.3]]
        switch request.url!.path {
        case "/api/health": return try result(200,["ok":true,"data":["status":"ok","version":"2.7.0-vpn.1","ttl_schema_version":2]],request)
        case "/api/device":
            deviceReads += 1
            var value = device
            if reboot && deviceReads > 1 { value["uptime_secs"] = 1 }
            return try result(200,["ok":true,"data":value],request)
        case "/api/dashboard": return try result(200,["ok":true,"data":["device":device,"memory":["total_kb":2000,"available_kb":invalidMemory ? 2001 : 500],"battery":["capacity":77],"unexpected_password":"PASSWORD-SECRET"]],request)
        case "/api/sim/imei":
            imeiReads += 1
            if missingIMEI { return try result(503,["ok":false,"error":"unavailable"],request) }
            return try result(200,["ok":true,"data":["imei": changedIMEI && imeiReads > 1 ? "867123456789025" : imei]],request)
        default: throw Failure.assertion("Invented or mutating endpoint")
        }
    }
}
@main enum AgentAccessClientTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + name) }
        func client(_ mock: MockAgent) throws -> AgentAccessClient { try AgentAccessClient(host: "192.0.2.1", transport: mock) }
        try test("reachable API without password is distinct from authenticated") {
            let mock = MockAgent(), c = try client(mock)
            let probe = try c.probe()
            try check(probe.state == .needsAuthentication && probe.session == nil && mock.loginCount == 0 && mock.requests.count == 1, "Implicit login")
            mock.noPassword = true
            let noPassword = try c.probe(password:"PASSWORD-SECRET")
            try check(noPassword.state == .passwordNotConfigured && mock.loginCount == 0, "Unconfigured server logged in")
        }
        try test("one explicit login produces bounded typed snapshot from real endpoints") {
            let mock = MockAgent(), c = try client(mock), probe = try c.probe(password:"PASSWORD-SECRET")
            try check(probe.state == .authenticated && probe.session != nil, "No session")
            let snapshot = try probe.session!.snapshot(expectedIMEI:imei)
            try check(snapshot.hostname == "MU5250" && snapshot.imei == imei && snapshot.agentVersion == "2.7.0-vpn.1" && snapshot.memoryTotalKiB == 2000 && snapshot.memoryAvailableKiB == 500 && snapshot.batteryPercent == 77, "Wrong schema")
            try check(snapshot.limitations.contains("CID") && !String(describing:snapshot).contains("PASSWORD-SECRET"), "Invented capability or leaked extras")
            try check(mock.loginCount == 1 && mock.requests.allSatisfy { $0.url?.host == "192.0.2.1" && $0.url?.port == 9090 }, "Off-origin credential request")
            let login = mock.requests.first { $0.httpMethod == "POST" }!
            try check(try JSONSerialization.jsonObject(with:login.httpBody!) as? [String:String] == ["password":"PASSWORD-SECRET"], "Wrong auth protocol")
            try check(login.value(forHTTPHeaderField:"Authorization") == nil && login.value(forHTTPHeaderField:"Cookie") == nil, "Unexpected credentials")
            try rejects(.loginAlreadyAttempted) { _ = try c.probe(password:"PASSWORD-SECRET") }
            try check(mock.loginCount == 1, "Retried password")
        }
        try test("invalid credentials do not retry or expose response secrets") {
            let mock = MockAgent(); mock.invalidPassword = true
            let c = try client(mock)
            try rejects(.invalidPassword) { _ = try c.probe(password:"PASSWORD-SECRET") }
            try rejects(.loginAlreadyAttempted) { _ = try c.probe(password:"PASSWORD-SECRET") }
            try check(mock.loginCount == 1, "Automatic password retry")
        }
        try test("redirect and oversized replies stop before password submission") {
            for kind in [0,1] {
                let mock = MockAgent(); mock.redirect = kind == 0; mock.oversize = kind == 1
                try rejects(kind == 0 ? .redirect : .oversized) { _ = try client(mock).probe(password:"PASSWORD-SECRET") }
                try check(mock.loginCount == 0 && mock.requests.count == 1, "Followed redirected origin")
            }
        }
        try test("malformed successful login or unprotected unrelated service is rejected") {
            for kind in 0..<4 {
                let mock = MockAgent(); mock.malformed = kind == 0; mock.falseOK = kind == 1; mock.unprotected = kind == 2; mock.genericUnauthorized = kind == 3
                try rejects(.malformed) { _ = try client(mock).probe(password:"PASSWORD-SECRET") }
            }
        }
        try test("expected identity unavailable changed IMEI and reboot are refused") {
            for kind in 0..<3 {
                let mock = MockAgent(); mock.missingIMEI = kind == 0; mock.changedIMEI = kind == 1; mock.reboot = kind == 2
                let session = try client(mock).probe(password:"PASSWORD-SECRET").session!
                try rejects(kind == 0 ? .identityUnavailable : .identityChanged) { _ = try session.snapshot(expectedIMEI:imei) }
            }
            let mock = MockAgent(); mock.missingIMEI = true
            let snapshot = try client(mock).probe(password:"PASSWORD-SECRET").session!.snapshot()
            try check(snapshot.imei == nil, "Invented identity")
        }
        try test("transport errors and typed snapshot redact secrets") {
            let mock = MockAgent(); mock.secretError = true
            do { _ = try client(mock).probe(password:"PASSWORD-SECRET"); throw Failure.assertion("Expected error") }
            catch let e as Failure { throw e }
            catch { try check(!error.localizedDescription.contains("PASSWORD-SECRET") && !error.localizedDescription.contains(token), "Error leaked secret") }
            let echo = MockAgent(); echo.secretHostname = true
            let snapshot = try client(echo).probe(password:"PASSWORD-SECRET").session!.snapshot()
            try check(!snapshot.hostname.contains(token), "Server echo leaked token")
        }
        try test("expired bearer stops session without password retry") {
            let mock = MockAgent(), c = try client(mock), session = try c.probe(password:"PASSWORD-SECRET").session!
            _ = try session.snapshot(expectedIMEI:imei)
            mock.expired = true
            let before = mock.requests.count
            try rejects(.authenticationRequired) { _ = try session.snapshot(expectedIMEI:imei) }
            try check(mock.loginCount == 1 && mock.requests.count == before + 1, "Automatic relogin or continued partial read")
        }
        try test("authenticated redirect and oversized responses abort immediately") {
            for kind in [0,1] {
                let mock = MockAgent(), session = try client(mock).probe(password:"PASSWORD-SECRET").session!
                mock.authenticatedRedirect = kind == 0; mock.authenticatedOversize = kind == 1
                let before = mock.requests.count
                try rejects(kind == 0 ? .redirect : .oversized) { _ = try session.snapshot() }
                try check(mock.requests.count == before + 1 && mock.loginCount == 1 && mock.requests.allSatisfy { $0.url?.host == "192.0.2.1" }, "Followed bearer redirect or continued failed read")
            }
        }
        try test("invalid typed device and memory measurements refuse snapshot") {
            for kind in [0,1] {
                let mock = MockAgent(), session = try client(mock).probe(password:"PASSWORD-SECRET").session!
                mock.invalidDevice = kind == 0; mock.invalidMemory = kind == 1
                try rejects(.malformed) { _ = try session.snapshot() }
            }
        }
        try test("identity continuity remains enforced between successive snapshots") {
            let mock = MockAgent(), session = try client(mock).probe(password:"PASSWORD-SECRET").session!
            _ = try session.snapshot()
            mock.changedIMEI = true
            try rejects(.identityChanged) { _ = try session.snapshot() }
        }
        try test("exact address and read-only endpoint policy reject alternate targets and mutations") {
            for host in ["localhost","192.0.2.1:9091","192.0.2.1/path","192.0.2.256","0192.0.2.1","192.0.2.1@evil.example"] { try rejects(.invalidAddress) { _ = try AgentAccessClient(host:host) } }
            let base = try AgentRequestPolicy.baseURL(host:"192.0.2.1")
            for address in ["http://192.0.2.99:9090/api/health","http://192.0.2.1:9091/api/health","http://192.0.2.1:9090/api/device/reboot","http://192.0.2.1:9090/api/health?forward=1"] {
                var request = URLRequest(url:URL(string:address)!); request.httpMethod = "GET"
                try rejects(.forbiddenRequest) { try AgentRequestPolicy.validate(request,base:base) }
            }
            var request = URLRequest(url:base.appendingPathComponent("api/device")); request.httpMethod = "POST"
            try rejects(.forbiddenRequest) { try AgentRequestPolicy.validate(request,base:base) }
        }
        try test("ephemeral transport has no proxy cookies credentials or cache and bounded time") {
            let c = AgentRequestPolicy.configuration()
            try check(c.urlCache == nil && c.httpCookieStorage == nil && c.urlCredentialStorage == nil && !c.httpShouldSetCookies, "Persistent HTTP state")
            try check(c.connectionProxyDictionary?.isEmpty == true && c.timeoutIntervalForResource <= 10 && c.timeoutIntervalForRequest <= 5, "Proxy or unbounded time")
            let url = try AgentRequestPolicy.baseURL(host:"192.0.2.1").appendingPathComponent("api/health")
            try rejects(.redirect) { try AgentRequestPolicy.validateResponse(status:307,url:url,expected:url,length:0) }
            try rejects(.oversized) { try AgentRequestPolicy.validateResponse(status:200,url:url,expected:url,length:Int64(AgentRequestPolicy.byteLimit+1)) }
        }
        print("RESULT \(passed) passed; 0 failed")
    }
}
