import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func rejects(_ text: String = "", _ work: () throws -> Void) throws {
    do { try work() } catch let error as Failure { throw error } catch {
        try check(text.isEmpty || error.localizedDescription.contains(text), "Unexpected error: " + error.localizedDescription); return
    }
    throw Failure.assertion("Expected refusal")
}
private let cid = "0123456789abcdef0123456789abcdef"
private let otherCID = String(repeating: "f", count: 32)
private let boot = "00112233-4455-6677-8899-aabbccddeeff"
private let imei = "867123456789017"
private let otherIMEI = "867123456789025"
private let firmware = "7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e"
private let token = "0123456789abcdef0123456789abcdef"
private func webObject(_ value: String = imei) -> [String: Any] {
    ["imei": value, "integrate_version": "STD_PL_MU5250V1.0.0B02", "wa_inner_version": "BD_STDPLMU5250V1.0.0B02"]
}
private func summary(_ strong: Bool = true, id: String = cid, sim: String = imei) -> ConnectionDeviceSummary {
    ConnectionDeviceSummary(identity: strong ? Identity(cid: id, firmwareHash: firmware) : nil,
                            bootID: strong ? boot : nil, imei: sim, fields: ["model": "MU5250"])
}
private func session(_ mode: ConnectionMode, _ value: ConnectionDeviceSummary? = nil) -> ReadOnlyChannelSession {
    let value = value ?? summary(mode == .ssh || mode == .adb)
    return ReadOnlyChannelSession(mode: mode, summary: value) { value }
}
private func unavailable() -> ConnectionProbeFailure { ConnectionProbeFailure(state: .unavailable, message: "Connection refused") }
private func state(_ selection: ChannelSelection, _ mode: ConnectionMode) -> ConnectionChannelState {
    selection.statuses.first { $0.mode == mode }!.state
}
private func rawProof(_ id: String = cid, sim: String = imei, reboot: Bool = false) throws -> Data {
    let web = String(decoding: try JSONSerialization.data(withJSONObject: webObject(sim)), as: UTF8.self)
    return Data((firmware + " /firmware/image/modem.b16\n" + ModemEngine.routerHash + " /usr/bin/diag-router\n" + id + "\n" + (reboot ? "ffffffff-ffff-ffff-ffff-ffffffffffff" : boot) + "\n" + web + "\n").utf8)
}
private final class SSH: RemoteTransport {
    var status: Int32 = 255, message = "ssh: connect: Connection refused", cidValue = cid
    var calls = [String](), identityReads = 0, reboot = false, malformed = false, interrupted = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        try check(input == nil && !command.contains("chmod") && !command.contains("setup-agent.sh"), "SSH probe mutation")
        if status != 0 { return CommandResult(status: status, stdout: Data(), stderr: Data(message.utf8)) }
        if interrupted { throw CommandFailure(message: "SSH connection lost", partial: CommandResult(status: 255, stdout: Data(), stderr: Data())) }
        if command.contains(DiagnosticTransportSelector.identityCommand) {
            identityReads += 1
            return CommandResult(status: 0, stdout: malformed ? Data("invalid".utf8) : try rawProof(cidValue, reboot: reboot && identityReads > 1), stderr: Data())
        }
        return CommandResult(status: 1, stdout: Data(), stderr: Data("details unavailable".utf8))
    }
}
private final class ADB: HostCommandRunner {
    var serials = ["USB-A"], usb = true, cids = ["USB-A": cid], calls = [[String]]()
    var physicalSerial: String?, deviceState = "device"
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments)
        if arguments == ["devices", "-l"] {
            return CommandResult(status: 0, stdout: Data(("List of devices attached\n" + serials.map { $0 + " " + deviceState + " " + (usb ? "usb:1-2 " : "") + "transport_id:1\n" }.joined()).utf8), stderr: Data())
        }
        if arguments == ["-d", "get-serialno"] { return CommandResult(status: physicalSerial == nil ? 1 : 0, stdout: Data((physicalSerial ?? "").utf8), stderr: Data()) }
        try check(arguments.count == 4 && arguments[0] == "-s" && arguments[2] == "shell", "ADB probe mutated device")
        guard let marker = ADBClient.shellMarker(in: arguments[3]) else { throw Failure.assertion("Missing ADB footer") }
        let result = arguments[3].contains(DiagnosticTransportSelector.identityCommand) ? try rawProof(cids[arguments[1]] ?? otherCID) : Data()
        return CommandResult(status: 0, stdout: result + Data(("\n" + marker + "0\n").utf8), stderr: Data())
    }
}
private final class Web: WebTransport {
    var calls = [String](), passwords = [String](), value = imei, challengeReply: Data?
    var loginResult = 0, missingCookie = false, transportFailure = false
    func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply {
        if transportFailure { throw URLError(.timedOut) }
        try check(path == "/ubus/", "Non-read-only Web path")
        let body = try JSONSerialization.jsonObject(with: data!) as! [[String: Any]], params = body[0]["params"] as! [Any]
        let method = params[2] as! String; calls.append(method)
        let payload: [String: Any]
        var headers = [String: String]()
        switch method {
        case "web_login_info":
            if let challengeReply { return WebReply(data: challengeReply, headers: [:]) }
            payload = ["zte_web_sault": "fixture-salt"]
        case "web_login":
            passwords.append((params[3] as! [String: String])["password"]!)
            payload = ["result": loginResult, "ubus_rpc_session": token]
            if !missingCookie { headers = ["set-cookie": "webtoken=fixture-cookie; Path=/"] }
        case "device_info": payload = webObject(value)
        default: throw Failure.assertion("Unexpected mutating Web method: " + method)
        }
        return WebReply(data: try JSONSerialization.data(withJSONObject: [["result": [0, payload]]]), headers: headers)
    }
}
private final class Agent: AgentHTTPTransport {
    var calls = [URLRequest](), passwords = [String](), value = imei, noPassword = false
    var loginStatus = 200, transportFailure = false
    func send(_ request: URLRequest) throws -> AgentHTTPReply {
        if transportFailure { throw URLError(.cannotConnectToHost) }
        calls.append(request)
        func response(_ status: Int, _ body: [String: Any]) throws -> AgentHTTPReply { AgentHTTPReply(status: status, data: try JSONSerialization.data(withJSONObject: body), url: request.url!) }
        if request.url!.path == "/api/auth/login" {
            passwords.append((try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String])["password"]!)
            if loginStatus != 200 { return try response(loginStatus, ["ok": false, "error": "fixture rejection"]) }
            return try response(200, ["ok": true, "data": ["token": token]])
        }
        if request.value(forHTTPHeaderField: "Authorization") == nil {
            return try response(noPassword ? 403 : 401, ["ok": false, "error": noPassword ? "no password configured. Set ZTE_AGENT_PASSWORD environment variable." : "unauthorized"])
        }
        try check(request.httpMethod == "GET", "Agent mutation")
        let device: [String: Any] = ["hostname": "MU5250", "kernel": "Linux fixture", "uptime_secs": 100, "load_avg": [0.1, 0.2, 0.3]]
        let payload: [String: Any]
        switch request.url!.path {
        case "/api/health": payload = ["status": "ok", "version": "2.7.0-vpn.1", "ttl_schema_version": 2]
        case "/api/device": payload = device
        case "/api/dashboard": payload = ["device": device, "memory": ["total_kb": 2000, "available_kb": 500], "battery": ["capacity": 77]]
        case "/api/sim/imei": payload = ["imei": value]
        default: throw Failure.assertion("Unknown agent endpoint")
        }
        return try response(200, ["ok": true, "data": payload])
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine
    let ssh = SSH(), adb = ADB(), web = Web(), agent = Agent()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-routing-tests-" + UUID().uuidString)
        try secureDirectory(root)
        let key = root.appendingPathComponent("key"), hosts = root.appendingPathComponent("known_hosts")
        try savePrivate(Data("fixture".utf8), key); try savePrivate(Data("fixture".utf8), hosts)
        engine = try ModemEngine(root: root, resources: root, connection: Connection(host: "192.0.2.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path), transport: ssh)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func router(expected: Identity? = nil, expectedWeb: WebIdentity? = nil, expectedIMEI: String? = nil, webPassword: String = "WEB-SECRET", agentPassword: String = "AGENT-SECRET") throws -> ConnectionRouter {
        try ConnectionRouter(engine: engine, expectedIdentity: expected, expectedWebIdentity: expectedWeb, expectedIMEI: expectedIMEI, webPassword: webPassword, agentPassword: agentPassword, ssh: ssh,
                             adb: ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: adb),
                             web: ModemWebClient(host: "192.0.2.1", transport: web), agent: AgentAccessClient(host: "192.0.2.1", transport: agent))
    }
}

@main enum ConnectionRoutingTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + name) }
        try test("manual modes probe only the selected channel on success and failure") {
            for selected in ConnectionMode.priority {
                for failure in [false, true] {
                    var calls = [ConnectionMode]()
                    let probes = Dictionary(uniqueKeysWithValues: ConnectionMode.priority.map { channel in
                        (channel, { (_: DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession in
                            calls.append(channel); if failure { throw unavailable() }; return session(channel)
                        } as ConnectionRouter.Probe)
                    })
                    let result = try ConnectionRouter(probes: probes).select(mode: selected)
                    try check(calls == [selected] && result.actualMode == (failure ? nil : selected), "Manual mode fell back")
                    try check(result.statuses.filter { $0.mode != selected }.allSatisfy { $0.state == .notChecked }, "Other channel was marked checked")
                }
            }
        }
        try test("automatic probes all channels in priority order and selects first available") {
            for first in ConnectionMode.priority.indices {
                var calls = [ConnectionMode]()
                let probes = Dictionary(uniqueKeysWithValues: ConnectionMode.priority.enumerated().map { index, channel in
                    (channel, { (_: DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession in
                        calls.append(channel); if index < first { throw unavailable() }; return session(channel)
                    } as ConnectionRouter.Probe)
                })
                let result = try ConnectionRouter(probes: probes).select(mode: .automatic)
                try check(calls == ConnectionMode.priority && result.actualMode == ConnectionMode.priority[first], "Wrong automatic order")
                try check(result.statuses.count == 4 && result.requiresSSHPreparation == (first != 0), "Wrong capabilities")
            }
        }
        try test("trust and identity refusal stop all lower probes") {
            for failure in [ConnectionChannelState.trustRejected, .identityMismatch, .ambiguous] {
                var calls = [ConnectionMode]()
                let probes = Dictionary(uniqueKeysWithValues: ConnectionMode.priority.map { channel in
                    (channel, { (_: DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession in
                        calls.append(channel); if channel == .ssh { throw ConnectionProbeFailure(state: failure, message: "Rejected") }; return session(channel)
                    } as ConnectionRouter.Probe)
                })
                let result = try ConnectionRouter(probes: probes).select(mode: .automatic)
                try check(result.session == nil && calls == [.ssh] && result.statuses.dropFirst().allSatisfy { $0.state == .notChecked }, "Unsafe downgrade")
            }
        }
        try test("an expected CID alone never authenticates API-only identity") {
            let expected = DiagnosticDeviceExpectation(cids: [cid], imeis: [])
            let result = try ConnectionRouter(expected: expected, probes: [.agent: { _ in session(.agent) }]).select(mode: .agent)
            try check(result.session == nil && state(result, .agent) == .identityUnverified, "API invented CID")
        }
        try test("matching USB binds earlier API identity without inventing its CID") {
            let expected = DiagnosticDeviceExpectation(cids: [cid], imeis: [])
            let router = ConnectionRouter(expected: expected, probes: [.ssh: { _ in throw unavailable() }, .agent: { _ in session(.agent) }, .adb: { _ in session(.adb) }, .web: { _ in session(.web) }])
            let result = try router.select(mode: .automatic)
            try check(result.actualMode == .agent && result.session?.summary.identity == nil && state(result, .adb) == .available, "Missing explicit CID/IMEI mapping")
        }
        try test("USB rejects earlier wrong API IMEI before sending Web credentials") {
            var webCalls = 0
            let expected = DiagnosticDeviceExpectation(cids: [cid], imeis: [])
            let router = ConnectionRouter(expected: expected, probes: [.ssh: { _ in throw unavailable() }, .agent: { _ in session(.agent, summary(false, sim: otherIMEI)) }, .adb: { _ in session(.adb) }, .web: { _ in webCalls += 1; return session(.web) }])
            let result = try router.select(mode: .automatic)
            try check(result.session == nil && state(result, .agent) == .identityMismatch && webCalls == 0, "Mixed-device API downgraded to Web")
        }
        try test("lower-priority unrelated USB does not replace authenticated higher-priority Agent") {
            let router = ConnectionRouter(probes: [.ssh: { _ in throw unavailable() }, .agent: { _ in session(.agent) }, .adb: { _ in session(.adb, summary(true, id: otherCID, sim: otherIMEI)) }, .web: { _ in session(.web) }])
            let result = try router.select(mode: .automatic)
            try check(result.actualMode == .agent && state(result, .adb) == .identityMismatch, "Lower-priority device replaced active Agent")
        }
        try test("invalid or conflicting saved expectations fail before any probe") {
            for expected in [DiagnosticDeviceExpectation(cids: [cid, otherCID], imeis: []), DiagnosticDeviceExpectation(cids: ["../x"], imeis: []), DiagnosticDeviceExpectation(cids: [], imeis: ["invalid"])] {
                var calls = 0
                try rejects { _ = try ConnectionRouter(expected: expected, probes: [.ssh: { _ in calls += 1; return session(.ssh) }]).select(mode: .automatic) }
                try check(calls == 0, "Invalid pending identity contacted device")
            }
        }
        try test("session identity or boot change fails without retrying another channel") {
            for kind in 0..<3 {
                let first = summary(), changed = kind == 0 ? summary(true, id: otherCID) : (kind == 1 ? summary(true, sim: otherIMEI) : ConnectionDeviceSummary(identity: first.identity, bootID: UUID().uuidString, imei: imei))
                var reads = 0
                let fixed = ReadOnlyChannelSession(mode: .adb, summary: first) { reads += 1; return changed }
                try rejects { _ = try fixed.readSummary() }
                try check(reads == 1, "Session retried after identity change")
            }
        }
        try test("API summaries are bounded and cannot expose shell capability") {
            for mode in [ConnectionMode.agent, .web] {
                let selected = session(mode), sections = try selected.readDiagnosticSections()
                try check(selected.diagnosticSession == nil && sections.count == 1 && sections[0].source == mode.rawValue && sections[0].name == "device-info.json", "False shell capability")
                try rejects("требуется SSH") { _ = try selected.requireSSH() }
            }
            let large = ConnectionDeviceSummary(imei: imei, fields: ["model": String(repeating: "x", count: 1025)])
            let result = try ConnectionRouter(probes: [.agent: { _ in session(.agent, large) }]).select(mode: .agent)
            try check(result.session == nil, "Oversized summary accepted")
        }
        try test("real SSH host-key failure never sends HTTP secrets or contacts ADB") {
            let f = try Fixture(); f.ssh.message = "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! Host key verification failed."
            let result = try f.router().select(mode: .automatic)
            try check(result.session == nil && state(result, .ssh) == .trustRejected && f.web.calls.isEmpty && f.agent.calls.isEmpty && f.adb.calls.isEmpty, "Credentials sent after SSH trust failure")
        }
        try test("SSH CID mismatch malformed proof and reboot stop credential downgrade") {
            for kind in 0..<3 {
                let f = try Fixture(); f.ssh.status = 0; f.ssh.cidValue = kind == 0 ? otherCID : cid; f.ssh.malformed = kind == 1; f.ssh.reboot = kind == 2
                let result = try f.router(expected: Identity(cid: cid, firmwareHash: firmware)).select(mode: .automatic)
                try check(result.session == nil && state(result, .ssh).preventsDowngrade && f.agent.calls.isEmpty && f.web.calls.isEmpty && f.adb.calls.isEmpty, "Identity failure sent credentials")
            }
        }
        try test("production manual SSH exposes verified shell and never logs in to APIs") {
            let f = try Fixture(); f.ssh.status = 0
            let result = try f.router().select(mode: .ssh)
            try check(result.actualMode == .ssh && result.session?.diagnosticSession?.proof.identity.cid == cid && f.agent.calls.isEmpty && f.web.calls.isEmpty && f.adb.calls.isEmpty, "Manual SSH contacted another channel")
            _ = try result.session!.requireSSH()
            let data = try result.session!.readSummary()
            try check(data.identity?.cid == cid && data.fields["detailsUnavailable"] != nil, "Partial summary lost identity")
            f.ssh.interrupted = true
            try rejects { _ = try result.session!.readSummary() }
            try check(f.agent.calls.isEmpty && f.web.calls.isEmpty && f.adb.calls.isEmpty, "Disconnected SSH session fell back")
        }
        try test("production automatic uses separate passwords and reports all real channels") {
            let f = try Fixture(), result = try f.router().select(mode: .automatic)
            try check(result.actualMode == .agent && state(result, .ssh) == .unavailable && state(result, .adb) == .available && state(result, .web) == .available, "Automatic real adapters failed")
            let hash = digest(Data((digest(Data("WEB-SECRET".utf8)).uppercased() + "fixture-salt").utf8)).uppercased()
            try check(f.agent.passwords == ["AGENT-SECRET"] && f.web.passwords == [hash], "Credentials crossed channels")
            let value = try result.session!.readSummary()
            try check(value.identity == nil && value.bootID == nil && value.firmware == nil && value.fields["batteryPercent"] == "77" && value.fields["memoryTotalKiB"] == "2000", "API invented identity or lost basic info")
        }
        try test("production strict API modes never contact shell and report auth-needed without login") {
            for mode in [ConnectionMode.agent, .web] {
                let f = try Fixture(), result = try f.router(webPassword: "", agentPassword: "").select(mode: mode)
                try check(result.session == nil && state(result, mode) == .authenticationRequired && f.ssh.calls.isEmpty && f.adb.calls.isEmpty && f.web.passwords.isEmpty && f.agent.passwords.isEmpty, "No-password probe attempted authentication or fallback")
                try check(mode == .agent ? f.web.calls.isEmpty : f.agent.calls.isEmpty, "Strict API contacted other API")
            }
        }
        try test("unconfigured Agent password has a specific setup explanation") {
            let f = try Fixture(); f.agent.noPassword = true
            let result = try f.router().select(mode: .agent)
            try check(result.reason.contains("ещё не настроен") && result.reason.contains("SSH") && f.agent.passwords.isEmpty, "Missing unconfigured Agent explanation")
        }
        try test("physical USB accepts unverified firmware read-only without policy override") {
            let f = try Fixture(), result = try f.router().select(mode: .adb)
            try check(result.actualMode == .adb && result.session?.diagnosticSession?.proof.identity.firmwareHash == firmware && !f.engine.connection.skipFirmwareCheck, "USB diagnostics changed write policy")
            try check(f.ssh.calls.isEmpty && f.web.calls.isEmpty && f.agent.calls.isEmpty && f.adb.calls.allSatisfy { $0 == ["devices", "-l"] || $0[2] == "shell" }, "USB probe mutations or fallback")
        }
        try test("network ADB is excluded and multiple unknown USB devices refuse before shell") {
            let tcp = try Fixture(); tcp.adb.usb = false; tcp.adb.serials = ["192.0.2.10:5555"]
            let result = try tcp.router().select(mode: .adb)
            try check(result.session == nil && result.reason.contains("USB") && tcp.adb.calls == [["devices", "-l"]], "TCP ADB treated as USB")
            let multi = try Fixture(); multi.adb.serials.append("USB-B")
            let ambiguous = try multi.router().select(mode: .adb)
            try check(ambiguous.session == nil && state(ambiguous, .adb) == .ambiguous && multi.adb.calls == [["devices", "-l"]], "Ambiguous USB shell inspected")
        }
        try test("known CID selects one attached USB and duplicate matches refuse") {
            let f = try Fixture(); f.adb.serials.append("USB-B"); f.adb.cids["USB-B"] = otherCID
            let expected = Identity(cid: cid, firmwareHash: firmware)
            try check(try f.router(expected: expected).select(mode: .adb).actualMode == .adb, "Known USB not selected")
            f.adb.cids["USB-B"] = cid
            let ambiguous = try f.router(expected: expected).select(mode: .adb)
            try check(ambiguous.session == nil && state(ambiguous, .adb) == .ambiguous, "Duplicate USB accepted")
        }
        try test("persisted pending identity binds selected channel and malformed pending fails before IO") {
            let f = try Fixture()
            try savePrivate(JSONSerialization.data(withJSONObject: ["cid": cid, "identity": webObject()]), f.root.appendingPathComponent("setup-pending.json"))
            f.adb.cids["USB-A"] = otherCID
            let result = try f.router().select(mode: .adb)
            try check(result.session == nil && state(result, .adb) == .identityMismatch, "Pending target ignored")
            let g = try Fixture(); try savePrivate(Data("{}".utf8), g.root.appendingPathComponent("setup-pending.json"))
            try rejects { _ = try g.router().select(mode: .automatic) }
            try check(g.ssh.calls.isEmpty && g.web.calls.isEmpty && g.agent.calls.isEmpty && g.adb.calls.isEmpty, "Broken pending contacted modem")
        }
        try test("standalone retained Agent IMEI rejects another channel and conflicting saved identity") {
            let f = try Fixture(), expected = Identity(cid: cid, firmwareHash: firmware)
            try check(try f.router(expected: expected, expectedIMEI: imei).select(mode: .agent).actualMode == .agent, "Retained CID/IMEI mapping lost")
            let g = try Fixture()
            let wrong = try g.router(expectedIMEI: otherIMEI).select(mode: .adb)
            try check(wrong.session == nil && state(wrong, .adb) == .identityMismatch, "Standalone IMEI ignored")
            let h = try Fixture()
            try rejects { _ = try h.router(expectedWeb: WebIdentity(webObject(), skipFirmwareCheck: true), expectedIMEI: otherIMEI) }
            try check(h.ssh.calls.isEmpty && h.adb.calls.isEmpty && h.web.calls.isEmpty && h.agent.calls.isEmpty, "Conflicting explicit identities contacted devices")
        }
        try test("Connect automatic selects SSH before ADB and never contacts Agent or Web") {
            let f = try Fixture(); f.ssh.status = 0
            let result = try f.router().connect(mode: .automatic)
            try check(result.actualMode == .ssh && result.session?.diagnosticSession?.transport == "ssh", "Connect did not select SSH")
            try check(f.agent.calls.isEmpty && f.web.calls.isEmpty && state(result, .agent) == .notChecked && state(result, .web) == .notChecked, "Connect sent HTTP credentials")
        }
        try test("Connect automatic falls back to physical ADB even when Agent would be available") {
            let f = try Fixture()
            let result = try f.router().connect(mode: .automatic)
            try check(result.actualMode == .adb && result.session?.diagnosticSession?.transport == "adb" && result.reason.contains("чтение"), "ADB was not selected with limited capability")
            try check(f.agent.calls.isEmpty && f.web.calls.isEmpty, "Agent or Web was used as connection")
            try rejects("SSH") { _ = try result.session!.requireSSH() }
        }
        try test("Connect manual SSH or ADB is strict on success and failure") {
            for mode in ConnectionMode.connectionPriority {
                for missing in [false, true] {
                    var calls = [ConnectionMode]()
                    let probes = Dictionary(uniqueKeysWithValues: ConnectionMode.priority.map { channel in
                        (channel, { (_: DiagnosticDeviceExpectation) throws -> ReadOnlyChannelSession in
                            calls.append(channel); if missing { throw unavailable() }; return session(channel)
                        } as ConnectionRouter.Probe)
                    })
                    let result = try ConnectionRouter(probes: probes).connect(mode: mode)
                    try check(calls == [mode] && result.actualMode == (missing ? nil : mode), "Manual Connect fell back")
                }
            }
        }
        try test("Connect never labels Agent or Web as a connected modem") {
            for mode in [ConnectionMode.agent, .web] {
                let f = try Fixture(), result = try f.router().connect(mode: mode)
                try check(result.session == nil && result.actualMode == nil && state(result, mode) == .unsupported && result.reason.contains("подготовку"), "API was labelled a connection")
                try check(f.ssh.calls.isEmpty && f.adb.calls.isEmpty && f.agent.calls.isEmpty && f.web.calls.isEmpty, "Unsupported connection mode performed IO")
            }
        }
        try test("Connect without SSH and ADB directs the user to preparation") {
            let f = try Fixture(); f.adb.serials = []
            let result = try f.router().connect(mode: .automatic)
            try check(result.actualMode == nil && result.session == nil && result.reason.contains("подготовку модема"), "Missing preparation guidance")
            try check(f.agent.calls.isEmpty && f.web.calls.isEmpty, "Missing shell fell back to HTTP")
        }
        try test("Connect refuses SSH trust failure and mismatched identity before USB downgrade") {
            for kind in 0..<2 {
                let f = try Fixture()
                if kind == 0 { f.ssh.message = "Host key verification failed." }
                else { f.ssh.status = 0; f.ssh.cidValue = otherCID }
                let result = try f.router(expected: Identity(cid: cid, firmwareHash: firmware)).connect(mode: .automatic)
                try check(result.session == nil && state(result, .ssh).preventsDowngrade && f.adb.calls.isEmpty && f.agent.calls.isEmpty && f.web.calls.isEmpty, "Unsafe connection downgrade")
            }
        }
        try test("Discovery verifies every channel without logging in or installing") {
            let f = try Fixture(); f.ssh.status = 0
            let statuses = try f.router(webPassword: "DO-NOT-SEND-WEB", agentPassword: "DO-NOT-SEND-AGENT").discover()
            func status(_ mode: ConnectionMode) -> ConnectionChannelStatus { statuses.first { $0.mode == mode }! }
            try check(status(.ssh).state == .available && status(.adb).state == .available, "Shell discovery failed")
            try check(status(.web).state == .authenticationRequired && status(.agent).state == .authenticationRequired, "Known unauthenticated services not discovered")
            try check(f.web.calls == ["web_login_info"] && f.web.passwords.isEmpty && f.agent.passwords.isEmpty, "Discovery logged in to HTTP")
            try check(f.agent.calls.count == 1 && f.agent.calls[0].url?.path == "/api/health" && f.agent.calls[0].httpMethod == "GET" && f.agent.calls[0].httpBody == nil, "Discovery requested non-read-only Agent operation")
            try check(status(.web).summary == nil && status(.agent).summary == nil, "Unauthenticated response invented device identity")
        }
        try test("Explicit discovery verifies the supplied independent HTTP passwords once") {
            let f = try Fixture()
            let statuses = try f.router().discover(authenticate: true)
            for mode in [ConnectionMode.web, .agent] {
                try check(statuses.first { $0.mode == mode }?.state == .available, "Correct password did not authorize " + mode.rawValue)
            }
            let hash = digest(Data((digest(Data("WEB-SECRET".utf8)).uppercased() + "fixture-salt").utf8)).uppercased()
            try check(f.web.passwords == [hash] && f.agent.passwords == ["AGENT-SECRET"], "Missing, repeated, or crossed password attempt")
            try check(f.web.calls == ["web_login_info", "web_login", "device_info", "device_info"], "Discovery changed Web configuration")
            try check(f.agent.calls.filter { $0.httpMethod != "GET" }.map { $0.url!.path } == ["/api/auth/login"], "Discovery changed Agent configuration")
        }
        try test("Explicit discovery with blank passwords asks for authentication without a login") {
            let f = try Fixture()
            let statuses = try f.router(webPassword: "", agentPassword: "").discover(authenticate: true)
            for mode in [ConnectionMode.web, .agent] {
                try check(statuses.first { $0.mode == mode }?.state == .authenticationRequired, "Blank password shown as rejection")
            }
            try check(f.web.passwords.isEmpty && f.agent.passwords.isEmpty, "Blank password submitted")
        }
        try test("Rejected passwords are distinct from unreachable services and are not retried") {
            let f = try Fixture(); f.web.loginResult = 1; f.agent.loginStatus = 401
            let statuses = try f.router().discover(authenticate: true)
            for mode in [ConnectionMode.web, .agent] {
                let status = statuses.first { $0.mode == mode }!
                try check(status.state == .invalidPassword && status.state.title == "Неверный пароль", "Wrong-password status missing")
                try check(!status.message.contains("SECRET"), "Password leaked in status")
            }
            try check(f.web.passwords.count == 1 && f.agent.passwords.count == 1, "Invalid password retried")
        }
        try test("A new explicit check accepts corrected passwords and replaces prior failures") {
            let f = try Fixture(); f.web.loginResult = 1; f.agent.loginStatus = 401
            _ = try f.router().discover(authenticate: true)
            f.web.loginResult = 0; f.agent.loginStatus = 200
            let statuses = try f.router(webPassword: "CORRECTED-WEB", agentPassword: "CORRECTED-AGENT").discover(authenticate: true)
            for mode in [ConnectionMode.web, .agent] {
                try check(statuses.first { $0.mode == mode }?.state == .available, "Corrected password retained old rejection")
            }
            let hash = digest(Data((digest(Data("CORRECTED-WEB".utf8)).uppercased() + "fixture-salt").utf8)).uppercased()
            try check(f.web.passwords.count == 2 && f.web.passwords.last == hash && f.agent.passwords == ["AGENT-SECRET", "CORRECTED-AGENT"], "Recheck reused stale credentials")
        }
        try test("Password rejection on one HTTP channel does not mask success on the other") {
            for wrongWeb in [false, true] {
                let f = try Fixture(); f.web.loginResult = wrongWeb ? 1 : 0; f.agent.loginStatus = wrongWeb ? 200 : 401
                let statuses = try f.router().discover(authenticate: true)
                try check(statuses.first { $0.mode == .web }?.state == (wrongWeb ? .invalidPassword : .available), "Web status contaminated by Agent")
                try check(statuses.first { $0.mode == .agent }?.state == (wrongWeb ? .available : .invalidPassword), "Agent status contaminated by Web")
            }
        }
        try test("Connection refusal and timeout remain unavailable even with supplied passwords") {
            let f = try Fixture(); f.web.transportFailure = true; f.agent.transportFailure = true
            let statuses = try f.router().discover(authenticate: true)
            for mode in [ConnectionMode.web, .agent] {
                try check(statuses.first { $0.mode == mode }?.state == .unavailable, "Transport failure blamed on password")
            }
            try check(f.web.passwords.isEmpty && f.agent.passwords.isEmpty, "Login attempted after unreachable probe")
        }
        try test("Rate limit and malformed successful login are not labelled wrong password") {
            let f = try Fixture(); f.agent.loginStatus = 429; f.web.missingCookie = true
            let statuses = try f.router().discover(authenticate: true)
            try check(statuses.first { $0.mode == .agent }?.state == .rateLimited, "Rate limit blamed on password")
            try check(statuses.first { $0.mode == .web }?.state == .unsupported, "Missing successful-session cookie blamed on password")
            try check(f.agent.passwords.count == 1 && f.web.passwords.count == 1, "Malformed/restricted login retried")
        }
        try test("Explicit discovery refuses to send passwords after SSH trust rejection") {
            let f = try Fixture(); f.ssh.message = "Host key verification failed."
            let statuses = try f.router().discover(authenticate: true)
            try check(statuses.first { $0.mode == .ssh }?.state == .trustRejected, "SSH rejection hidden")
            try check(f.web.calls.isEmpty && f.agent.calls.isEmpty && f.adb.calls.isEmpty, "Explicit check sent secrets after trust rejection")
        }
        try test("Discovery finds stock Web without shell or any password so preparation can be offered") {
            let f = try Fixture(); f.adb.serials = []
            let statuses = try f.router(webPassword: "", agentPassword: "").discover()
            try check(statuses.first { $0.mode == .web }?.state == .authenticationRequired && f.web.calls == ["web_login_info"], "Stock Web was hidden without credentials")
            try check(statuses.first { $0.mode == .ssh }?.state == .unavailable && statuses.first { $0.mode == .adb }?.state == .unavailable, "Missing shell was labelled connected")
        }
        try test("Discovery never accepts an arbitrary HTTP page as stock Web") {
            for response in [Data("<html>Router login</html>".utf8), Data("[{\"result\":[0,{}]}]".utf8), Data("[{\"result\":[0,{\"zte_web_sault\":\"\"}]}]".utf8), Data("[{\"result\":[0,{\"zte_web_sault\":23}]}]".utf8)] {
                let f = try Fixture(); f.web.challengeReply = response
                let statuses = try f.router().discover()
                let web = statuses.first { $0.mode == .web }!
                try check(web.state != .authenticationRequired && web.state != .available && f.web.passwords.isEmpty, "Unrelated HTTP service accepted as stock Web")
            }
        }
        try test("Discovery preserves SSH trust rejection instead of probing lower services") {
            let f = try Fixture(); f.ssh.message = "Host key verification failed."
            let statuses = try f.router().discover()
            try check(statuses.first { $0.mode == .ssh }?.state == .trustRejected && statuses.filter { $0.mode != .ssh }.allSatisfy { $0.state == .notChecked }, "Trust failure obscured")
            try check(f.adb.calls.isEmpty && f.agent.calls.isEmpty && f.web.calls.isEmpty, "Discovery bypassed trust rejection")
        }
        try test("Discovery and Connect reject invalid saved expectations before IO") {
            for discovery in [false, true] {
                var calls = 0
                let router = ConnectionRouter(expected: DiagnosticDeviceExpectation(cids: ["invalid"], imeis: []), probes: [.ssh: { _ in calls += 1; return session(.ssh) }])
                try rejects { if discovery { _ = try router.discover() } else { _ = try router.connect(mode: .automatic) } }
                try check(calls == 0, "Invalid expected modem contacted a device")
            }
        }
        try test("Connect accepts a verified USB selector when devices output omits usb") {
            let f = try Fixture(); f.adb.usb = false; f.adb.physicalSerial = "USB-A"
            let result = try f.router().connect(mode: .adb)
            try check(result.actualMode == .adb && result.session?.summary.identity?.cid == cid && f.adb.calls.contains(["-d", "get-serialno"]), "Physical USB missing descriptor was hidden")
        }
        try test("Connect reports unauthorized and offline rather than missing ADB") {
            for deviceState in ["unauthorized", "offline"] {
                let f = try Fixture(); f.adb.deviceState = deviceState
                let result = try f.router().connect(mode: .adb)
                try check(result.session == nil && result.statuses.first { $0.mode == .adb }?.message.contains(deviceState) == true, "ADB transport state was hidden")
                try check(f.adb.calls == [["devices", "-l"]] && f.web.calls.isEmpty && f.agent.calls.isEmpty, "Unavailable manual ADB fell back or ran shell")
            }
        }
        print("Connection routing: \(passed) passed; 0 failed")
    }
}
