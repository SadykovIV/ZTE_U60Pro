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
private final class SessionFixture {
    var proof: DiagnosticDeviceProof
    var reads = 0, commands = 0, failed = false
    init() throws {
        proof = DiagnosticDeviceProof(identity: Identity(cid: cid, firmwareHash: String(repeating: "b", count: 64)), routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: try webIdentity())
    }
    func channel(_ mode: ConnectionMode = .ssh, transport: String? = nil) -> ReadOnlyChannelSession {
        let shell = DiagnosticSession(transport: transport ?? mode.rawValue, reason: "fixture", proof: proof, readIdentity: {
            self.reads += 1
            if self.failed { throw IMEIError.message("SSH disconnected") }
            return self.proof
        }) { _, _ in
            self.commands += 1
            return CommandResult(status: 0, stdout: Data("password=PRIVATE-CANARY\n__DIAGNOSTIC_RESULT__0\n".utf8), stderr: Data())
        }
        let summary = ConnectionDeviceSummary(identity: proof.identity, webIdentity: proof.webIdentity, bootID: boot)
        return ReadOnlyChannelSession(mode: mode, summary: summary, diagnosticSession: shell) { self.reads += 1; return summary }
    }
}
@main enum ConnectionDiagnosticsTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + name) }
        try test("automatic ordinary collection selects SSH only and accepts unknown firmware read-only") {
            let f = try Fixture(), s = try SessionFixture(); var probes = [ConnectionMode]()
            var probeMap = [ConnectionMode: ConnectionRouter.Probe]()
            for mode in [ConnectionMode.ssh, .adb, .agent, .web] { probeMap[mode] = { _ in probes.append(mode); return s.channel(mode) } }
            let router = ConnectionRouter(probes: probeMap)
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .automatic, expectedIdentity: s.proof.identity, router: router) }
            try check(probes == [.ssh] && f.ssh.calls == 0 && s.commands == ModemInformationManager.diagnosticCommands.count, "Wrong transport or incomplete report")
            try check(report.transport == "ssh" && report.identityVerified == true && report.files.allSatisfy { $0.effectiveOutcome == .succeeded }, "Invalid provenance")
            try check(!f.engine.connection.skipFirmwareCheck && report.warnings?.isEmpty == false, "Read-only unknown firmware widened write permission")
            for file in report.files {
                let data = try Data(contentsOf: report.url.appendingPathComponent(file.name))
                try check(digest(data) == file.sha256 && !String(decoding: data, as: UTF8.self).contains("PRIVATE-CANARY"), "Checksum or redaction regression")
            }
        }
        try test("explicit non-SSH modes refuse before all probes") {
            for mode in [ConnectionMode.adb, .agent, .web] {
                let f = try Fixture(); var probes = 0
                let router = ConnectionRouter(probes: [mode: { _ in probes += 1; throw Failure.assertion("Disallowed probe") }])
                try rejects { _ = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: mode, router: router) } }
                try check(probes == 0 && f.ssh.calls == 0, "Non-SSH mode probed")
            }
        }
        try test("supplied non-SSH sessions refuse before identity or data reads") {
            for mode in [ConnectionMode.adb, .agent, .web] {
                for requested in [ConnectionMode.automatic, .ssh] {
                    let f = try Fixture(), s = try SessionFixture()
                    try rejects { _ = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: requested, session: s.channel(mode)) } }
                    try check(s.reads == 0 && s.commands == 0 && f.ssh.calls == 0, "Disallowed supplied session consumed")
                }
            }
        }
        try test("SSH wrapper cannot smuggle an ADB shell") {
            let f = try Fixture(), s = try SessionFixture()
            try rejects { _ = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .automatic, session: s.channel(.ssh, transport: "adb")) } }
            try check(s.reads == 0 && s.commands == 0 && f.ssh.calls == 0, "Mismatched shell consumed")
        }
        try test("SSH refusal does not probe available alternatives") {
            let f = try Fixture(), s = try SessionFixture(); var probes = [ConnectionMode]()
            let router = ConnectionRouter(probes: [.ssh: { _ in probes.append(.ssh); throw IMEIError.message("SSH refused") }, .adb: { _ in probes.append(.adb); return s.channel(.adb) }, .web: { _ in probes.append(.web); return s.channel(.web) }])
            try rejects { _ = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .automatic, router: router) } }
            try check(probes == [.ssh] && s.reads == 0 && f.ssh.calls == 0, "Fallback after refusal")
        }
        try test("cached SSH disconnect produces local partial report without selecting another session") {
            let f = try Fixture(), s = try SessionFixture(); s.failed = true; var probes = 0
            let router = ConnectionRouter(probes: [.ssh: { _ in probes += 1; throw Failure.assertion("Retry") }])
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .automatic, session: s.channel(), router: router) }
            try check(probes == 0 && s.commands == 0 && f.ssh.calls == 0 && report.identityVerified == false, "Disconnected session retried")
            try check(report.files.allSatisfy { $0.effectiveOutcome == .skipped } && report.connectionError != nil, "Disconnect reported success")
        }
        try test("new pending CID still binds cached SSH before queries") {
            let f = try Fixture(), s = try SessionFixture()
            try saveJSON(["cid": String(repeating: "f", count: 32)], f.root.appendingPathComponent("setup-pending.json"))
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .ssh, session: s.channel()) }
            try check(s.commands == 0 && s.reads == 0 && report.identityVerified == false, "Cached session bypassed pending identity")
            try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("setup-pending.json").path), "Pending state changed")
        }
        try test("expected IMEI still binds SSH before queries") {
            let f = try Fixture(), s = try SessionFixture()
            let report = try f.engine.locked { try ConnectionDiagnostics.collect(engine: f.engine, mode: .ssh, session: s.channel(), expectedIMEI: "353490068701230") }
            try check(s.reads == 0 && s.commands == 0 && report.identityVerified == false, "Expected IMEI bypassed")
        }
        try test("conflicting saved IMEI refuses before collection") {
            let f = try Fixture(), web = try webIdentity()
            try rejects { _ = try DiagnosticDeviceExpectation.load(root: f.root, identity: nil, web: web, imei: "353490068701230") }
            try saveJSON(["identity": ["imei": imei]], f.root.appendingPathComponent("setup-pending.json"))
            try rejects { _ = try DiagnosticDeviceExpectation.load(root: f.root, identity: nil, web: nil, imei: "353490068701230") }
        }
        try test("collection requires shared lock before probing") {
            let f = try Fixture(), s = try SessionFixture()
            try rejects { _ = try ConnectionDiagnostics.collect(engine: f.engine, mode: .ssh, session: s.channel()) }
            try check(s.reads == 0 && f.ssh.calls == 0, "Unlocked collection contacted modem")
        }
        print("Connection diagnostics: \(passed) passed; 0 failed")
    }
}
