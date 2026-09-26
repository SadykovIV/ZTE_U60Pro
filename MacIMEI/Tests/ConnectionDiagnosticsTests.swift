import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.assertion(message) }
}
private func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch let failure as Failure { throw failure } catch { return }
    throw Failure.assertion("Expected refusal")
}
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "00112233-4455-6677-8899-aabbccddeeff"
private let imei = "867123456789017"
private func webIdentity(_ value: String = imei) throws -> WebIdentity {
    try WebIdentity(["imei": value, "integrate_version": "CN_ZTE_MU5250V1.0.0B31", "wa_inner_version": "BD_CNMU5250V1.0.0B31"])
}
private final class ForbiddenSSH: RemoteTransport {
    var calls = 0
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls += 1; throw Failure.assertion("Unexpected SSH operation")
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine
    let ssh = ForbiddenSSH()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-channel-diagnostics-" + UUID().uuidString)
        try secureDirectory(root)
        engine = try ModemEngine(root: root, resources: root, connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/hosts"), transport: ssh)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
@main enum ConnectionDiagnosticsTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + name) }
        try test("manual ADB uses only its selected session and preserves full diagnostics") {
            let f = try Fixture(), web = try webIdentity()
            let proof = DiagnosticDeviceProof(identity: Identity(cid: cid, firmwareHash: ModemEngine.firmwareHash), routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: web)
            var queries = 0, probes = [ConnectionMode]()
            let shell = DiagnosticSession(transport: "adb", reason: "strict selected ADB", proof: proof, readIdentity: { proof }) { _, _ in
                queries += 1
                return CommandResult(status: 0, stdout: Data("USB-only section\n__DIAGNOSTIC_RESULT__0\n".utf8), stderr: Data())
            }
            let summary = ConnectionDeviceSummary(identity: proof.identity, webIdentity: web, bootID: boot)
            let channel = ReadOnlyChannelSession(mode: .adb, summary: summary, diagnosticSession: shell) { summary }
            let router = ConnectionRouter(probes: [.ssh: { _ in probes.append(.ssh); throw Failure.assertion("SSH probe in manual ADB") }, .adb: { _ in probes.append(.adb); return channel }])
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .adb, expectedIdentity: proof.identity, router: router) }
            try check(probes == [.adb] && f.ssh.calls == 0 && queries == ModemInformationManager.diagnosticCommands.count, "Manual ADB reached another channel or lost sections")
            try check(report.transport == "adb" && report.identityVerified == true && report.files.allSatisfy { $0.effectiveOutcome == .succeeded }, "ADB report lost verified provenance")
        }
        try test("manual unavailable channel never tries the available alternative") {
            let f = try Fixture(); var probes = [ConnectionMode]()
            let router = ConnectionRouter(probes: [.adb: { _ in probes.append(.adb); throw IMEIError.message("USB unavailable") }, .ssh: { _ in probes.append(.ssh); throw Failure.assertion("Unexpected fallback") }])
            try rejects { _ = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .adb, router: router) } }
            try check(probes == [.adb] && f.ssh.calls == 0, "Manual failure fell back")
        }
        try test("API report redacts credentials and labels shell sections unsupported") {
            for mode in [ConnectionMode.agent, .web] {
                let f = try Fixture(), web = try webIdentity()
                let summary = ConnectionDeviceSummary(webIdentity: web, agentVersion: mode == .agent ? "fixture" : nil, fields: ["model": "MU5250", "password": "secret-api-password", "token": "secret-api-token"])
                var reads = 0
                let session = ReadOnlyChannelSession(mode: mode, summary: summary) { reads += 1; return summary }
                let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: mode, session: session, expectedWebIdentity: web) }
                try check(report.transport == mode.rawValue && report.identity == nil && report.identityVerified == false && report.bootID == "не сообщается API", "API fabricated strong identity")
                try check(report.files.filter { $0.effectiveOutcome == .succeeded }.count == 1 && report.files.filter { $0.effectiveOutcome == .skipped }.count == ModemInformationManager.diagnosticCommands.count, "API implied shell capabilities")
                try check(reads == 3 && f.ssh.calls == 0, "API report changed channels or missed identity checks")
                for item in report.files {
                    let url = report.url.appendingPathComponent(item.name), data = try Data(contentsOf: url), text = String(decoding: data, as: UTF8.self)
                    try check(digest(data) == item.sha256 && data.count == item.bytes && data.count <= ConnectionDiagnostics.apiByteLimit, "Report checksum/size mismatch")
                    try check(!text.contains("secret-api-password") && !text.contains("secret-api-token") && !text.contains(imei), "API response disclosed sensitive data")
                    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                    try check(permissions?.intValue == 0o600, "Report file not private")
                }
            }
        }
        try test("large JSON is redacted before a UTF8 safe strict byte limit") {
            let data = try JSONSerialization.data(withJSONObject: ["body": String(repeating: "Ж", count: 60000), "password": "SECRET-AT-END", "token": "TOKEN-AT-END"])
            let (body, truncated) = ConnectionDiagnostics.sanitizedSection(data, source: "agent")
            try check(truncated && body.count <= ConnectionDiagnostics.apiByteLimit && String(data: body, encoding: .utf8) != nil, "Output not strictly bounded UTF8")
            let text = String(decoding: body, as: UTF8.self)
            try check(!text.contains("SECRET-AT-END") && !text.contains("TOKEN-AT-END"), "Truncation bypassed JSON redaction")
        }
        try test("API identity change discards collected sections without fallback") {
            let f = try Fixture(), web = try webIdentity(), changed = try webIdentity("353490068701230")
            let summary = ConnectionDeviceSummary(webIdentity: web)
            var reads = 0, probes = 0
            let session = ReadOnlyChannelSession(mode: .agent, summary: summary) {
                reads += 1; return ConnectionDeviceSummary(webIdentity: reads == 3 ? changed : web)
            }
            let router = ConnectionRouter(probes: [.ssh: { _ in probes += 1; throw Failure.assertion("Mid-operation fallback") }])
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .automatic, session: session, router: router) }
            try check(probes == 0 && f.ssh.calls == 0 && report.transport == "agent", "API failure switched transport")
            try check(report.files.filter { $0.effectiveOutcome == .connectionError }.count == 1 && !report.files.contains { $0.effectiveOutcome == .succeeded }, "Mixed-device API output accepted")
        }
        try test("a new pending CID guard cannot be bypassed by an already selected API") {
            let f = try Fixture(), summary = ConnectionDeviceSummary(imei: imei)
            var reads = 0
            let session = ReadOnlyChannelSession(mode: .agent, summary: summary) { reads += 1; return summary }
            // The transaction appeared after the API session was selected.
            try saveJSON(["cid": cid], f.root.appendingPathComponent("setup-pending.json"))
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .agent, session: session) }
            try check(reads == 1 && f.ssh.calls == 0 && report.identityVerified == false, "Cached API bypassed pending-device binding")
            try check(!report.files.contains { $0.effectiveOutcome == .succeeded } && report.files.contains { $0.name == "api-error.txt" }, "CID-unverified API data published")
            try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("setup-pending.json").path), "Read-only report changed pending transaction")
        }
        try test("selected shell failure cannot trigger the legacy automatic selector") {
            let f = try Fixture(), web = try webIdentity()
            let proof = DiagnosticDeviceProof(identity: Identity(cid: cid, firmwareHash: ModemEngine.firmwareHash), routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: web)
            var commands = 0, probes = 0
            let shell = DiagnosticSession(transport: "adb", reason: "selected before disconnect", proof: proof, readIdentity: { throw IMEIError.message("Selected USB disconnected") }) { _, _ in
                commands += 1; throw Failure.assertion("Read on disconnected session")
            }
            let summary = ConnectionDeviceSummary(identity: proof.identity, webIdentity: web, bootID: boot)
            let session = ReadOnlyChannelSession(mode: .adb, summary: summary, diagnosticSession: shell) { summary }
            let router = ConnectionRouter(probes: [.ssh: { _ in probes += 1; throw Failure.assertion("Fallback") }])
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .automatic, session: session, router: router) }
            try check(probes == 0 && commands == 0 && f.ssh.calls == 0 && report.transport == "adb", "Disconnected session switched transport")
            try check(report.connectionError != nil && report.identityVerified == false && report.files.allSatisfy { $0.effectiveOutcome == .skipped }, "Disconnect reported successful data")
        }
        try test("manual mode rejects a cached session from another channel before reading") {
            let f = try Fixture(), summary = ConnectionDeviceSummary(imei: imei); var reads = 0
            let session = ReadOnlyChannelSession(mode: .agent, summary: summary) { reads += 1; return summary }
            try rejects { _ = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .adb, session: session) } }
            try check(reads == 0 && f.ssh.calls == 0, "Manual mode consumed foreign cached session")
        }
        try test("standalone expected IMEI remains binding for cached API and shell sessions") {
            for mode in [ConnectionMode.agent, .adb] {
                let f = try Fixture(), web = try webIdentity()
                let proof = DiagnosticDeviceProof(identity: Identity(cid: cid, firmwareHash: ModemEngine.firmwareHash), routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: web)
                var commands = 0
                let shell = DiagnosticSession(transport: "adb", reason: "selected USB", proof: proof, readIdentity: { proof }) { _, _ in commands += 1; throw Failure.assertion("Wrong IMEI reached shell") }
                let summary = ConnectionDeviceSummary(webIdentity: web)
                let session = ReadOnlyChannelSession(mode: mode, summary: summary, diagnosticSession: mode == .adb ? shell : nil) { summary }
                let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: mode, session: session, expectedIMEI: "353490068701230") }
                try check(commands == 0 && f.ssh.calls == 0 && !report.files.contains { $0.effectiveOutcome == .succeeded }, "Changing mode discarded known IMEI")
            }
        }
        try test("standalone IMEI conflicts with saved or web identity fail before collection") {
            let f = try Fixture(), web = try webIdentity()
            try rejects { _ = try DiagnosticDeviceExpectation.load(root: f.root, identity: nil, web: web, imei: "353490068701230") }
            try saveJSON(["identity": ["imei": imei]], f.root.appendingPathComponent("setup-pending.json"))
            try rejects { _ = try DiagnosticDeviceExpectation.load(root: f.root, identity: nil, web: nil, imei: "353490068701230") }
        }
        try test("collection requires the shared operation lock") {
            let f = try Fixture()
            try rejects { _ = try ConnectionDiagnostics.collect(engine: f.engine, mode: .adb) }
            try check(f.ssh.calls == 0, "Unlocked collection contacted modem")
        }
        print("Connection diagnostics: \(passed) passed; 0 failed")
    }
}
