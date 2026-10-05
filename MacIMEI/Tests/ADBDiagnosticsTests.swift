import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func rejects(_ text: String = "", _ body: () throws -> Void) throws {
    do { try body() } catch let e as Failure { throw e } catch { try check(text.isEmpty || error.localizedDescription.contains(text), "Unexpected error: " + error.localizedDescription); return }
    throw Failure.assertion("Expected refusal")
}
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "00112233-4455-6677-8899-aabbccddeeff"
private let b02 = "7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e"
private let webInfo = #"{"imei":"867123456789017","integrate_version":"STD_PL_MU5250V1.0.0B02","wa_inner_version":"BD_STDPLMU5250V1.0.0B02"}"#
private func proof(_ identity: String = cid, web: Bool = false, changedBoot: Bool = false) -> String {
    "\(b02) /firmware/image/modem.b16\n\(ModemEngine.routerHash) /usr/bin/diag-router\n\(identity)\n\(changedBoot ? "ffffffff-ffff-ffff-ffff-ffffffffffff" : boot)\n" + (web ? webInfo + "\n" : "")
}
private final class SSH: RemoteTransport {
    var status: Int32 = 255, message = "ssh: connect: Connection refused", calls: [String] = []
    var thrown = false, changeAfterQuery = false, failQueries = false, producerStatus = 0, queryCount = 0
    var observedCID = cid
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        if thrown { throw IMEIError.message("Файл SSH не найден") }
        if status != 0 { return CommandResult(status: status, stdout: Data(), stderr: Data(message.utf8)) }
        let out: String
        if command.contains(DiagnosticTransportSelector.identityCommand) {
            out = proof(observedCID, web: command.contains("device_info"), changedBoot: changeAfterQuery && queryCount > 0)
        } else {
            queryCount += 1
            if failQueries { throw IMEIError.message("SSH disconnected") }
            out = "ssh result\npassword=TOP-SECRET\n__DIAGNOSTIC_RESULT__\(producerStatus)\n"
        }
        return CommandResult(status: 0, stdout: Data(out.utf8), stderr: Data())
    }
}
private final class ADB: HostCommandRunner {
    var devices = ["USB-A"], cids = ["USB-A": cid], usb = true
    var physicalSerial: String?
    var calls: [[String]] = [], queryCount = 0, identityReads = 0
    var changeAfterQuery = false, failQueries = false, producerStatus = 0
    var secretOutput = "usb result\npassword=TOP-SECRET\n"
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments)
        if arguments == ["devices", "-l"] {
            return CommandResult(status: 0, stdout: Data(("List of devices attached\n" + devices.map { $0 + " device " + (usb ? "usb:1 " : "") + "transport_id:1\n" }.joined()).utf8), stderr: Data())
        }
        if arguments == ["-d", "get-serialno"] { return CommandResult(status: physicalSerial == nil ? 1 : 0, stdout: Data((physicalSerial ?? "").utf8), stderr: Data()) }
        try check(arguments.count == 4 && arguments[0] == "-s" && arguments[2] == "shell", "Non-read-only ADB action")
        let command = arguments[3], serial = arguments[1]
        guard let marker = ADBClient.shellMarker(in: command) else { throw Failure.assertion("Missing footer nonce") }
        let output: String
        if command.contains(DiagnosticTransportSelector.identityCommand) {
            identityReads += 1
            output = proof(cids[serial] ?? String(repeating: "f", count: 32), web: command.contains("device_info"), changedBoot: changeAfterQuery && queryCount > 0)
        } else {
            queryCount += 1
            if failQueries { throw CommandFailure(message: "USB disconnected", partial: CommandResult(status: 1, stdout: Data(), stderr: Data("offline".utf8))) }
            output = secretOutput + "\n__DIAGNOSTIC_RESULT__\(producerStatus)\n"
        }
        return CommandResult(status: 0, stdout: Data((output + "\n" + marker + "0\n").utf8), stderr: Data())
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine
    let ssh = SSH(), adb = ADB()
    var client: ADBClient { ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: adb) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-adb-diag-test-" + UUID().uuidString)
        try secureDirectory(root)
        engine = try ModemEngine(root: root, resources: root, connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/missing/key", knownHostsPath: "/missing/hosts"), transport: ssh)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func collect(expected: Identity? = nil) throws -> DiagnosticReport {
        try engine.locked { try ModemInformationManager(engine: engine).collectDiagnostics(expectedIdentity: expected, adb: client) }
    }
}
@main enum ADBDiagnosticsTests {
    static func main() throws {
        var passed = 0
        func test(_ title: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + title) }
        try test("authenticated SSH is preferred without contacting ADB") {
            let f = try Fixture(); f.ssh.status = 0
            let report = try f.collect()
            try check(report.transport == "ssh" && report.identityVerified == true && f.adb.calls.isEmpty, "Wrong transport")
            try check(report.files.allSatisfy { $0.effectiveOutcome == .succeeded }, "Missing SSH data")
        }
        try test("SSH refusal never contacts existing ready USB") {
            let f = try Fixture(), report = try f.collect()
            try check(report.transport == "none" && report.identityVerified == false && f.adb.calls.isEmpty, "Ordinary collection fell back to USB")
            try check(f.ssh.calls.count == 1 && report.files.allSatisfy { $0.effectiveOutcome == .skipped }, "Repeated SSH or fake success")
        }
        try test("missing SSH configuration never starts USB discovery") {
            let f = try Fixture(); f.ssh.thrown = true
            try check(try f.collect().transport == "none" && f.adb.calls.isEmpty, "Missing SSH fell back")
        }
        try test("low-level bootstrap selector retains explicit independent USB support") {
            let f = try Fixture(); f.adb.usb = false; f.adb.physicalSerial = "USB-A"
            let selected = try DiagnosticTransportSelector.select(engine: f.engine, expected: DiagnosticDeviceExpectation(), adb: f.client)
            try check(selected.transport == "adb" && f.adb.calls.contains(["-d", "get-serialno"]), "Bootstrap USB selection changed")
            try selected.verify()
            try f.engine.locked { try rejects("SSH") { _ = try ModemInformationManager(engine: f.engine).collectDiagnostics(preferredSession: selected) } }
            try check(f.adb.queryCount == 0, "Ordinary collector accepted bootstrap ADB")
        }
        try test("host key mismatch never silently changes target or transport") {
            let f = try Fixture(); f.ssh.message = "WARNING REMOTE HOST IDENTIFICATION HAS CHANGED! Host key verification failed."
            let report = try f.collect()
            try check(report.transport == "none" && f.adb.calls.isEmpty && report.files.allSatisfy { $0.effectiveOutcome == .skipped }, "Trust failure bypassed")
            try check(report.connectionError != nil && report.outcomeSummary.contains("ошибки подключения: 1"), "Error classification missing")
        }
        try test("ordinary SSH rejects wrong CID without contacting USB") {
            let f = try Fixture(); f.ssh.status = 0; f.ssh.observedCID = String(repeating: "f", count: 32)
            let report = try f.collect(expected: Identity(cid: cid, firmwareHash: b02))
            try check(report.transport == "none" && f.ssh.queryCount == 0 && f.adb.calls.isEmpty, "Wrong SSH target read or fallback")
        }
        try test("damaged pending identity prevents all transports") {
            let f = try Fixture(); f.ssh.status = 0
            try savePrivate(Data("{}".utf8), f.root.appendingPathComponent("setup-pending.json"))
            let report = try f.collect()
            try check(report.transport == "none" && f.ssh.calls.isEmpty && f.adb.calls.isEmpty, "Malformed pending identity ignored")
        }
        try test("saved setup identity remains binding without firmware allowlist") {
            let f = try Fixture(); f.ssh.status = 0
            let saved: [String: Any] = ["cid": cid, "identity": try JSONSerialization.jsonObject(with: Data(webInfo.utf8))]
            try savePrivate(JSONSerialization.data(withJSONObject: saved), f.root.appendingPathComponent("setup-pending.json"))
            let report = try f.collect()
            try check(report.transport == "ssh" && report.identity?.firmwareHash == b02 && report.identityVerified == true && f.adb.calls.isEmpty, "Pending binding/unknown-firmware diagnostics changed")
            try check(!f.engine.connection.skipFirmwareCheck, "Read-only path changed write policy")
            let body = try String(contentsOf: report.url.appendingPathComponent("firmware.txt"))
            try check(!body.contains("TOP-SECRET"), "Secret leaked")
        }
        try test("saved diagnostic activation still binds SSH identity across restart") {
            let f = try Fixture(); f.ssh.status = 0
            let saved: [String: Any] = ["cid": cid, "identity": try JSONSerialization.jsonObject(with: Data(webInfo.utf8))]
            try savePrivate(JSONSerialization.data(withJSONObject: saved), f.root.appendingPathComponent("adb-access-pending.json"))
            let report = try f.collect()
            try check(report.transport == "ssh" && report.identityVerified == true && f.adb.calls.isEmpty, "Pending identity ignored")
        }
        try test("device reboot during a section discards output and skips later sections") {
            let f = try Fixture(); f.ssh.status = 0; f.ssh.changeAfterQuery = true
            let report = try f.collect()
            try check(report.identityVerified == false && f.ssh.queryCount == 1, "Reboot accepted or more diagnostics queried")
            try check(report.files.filter { $0.effectiveOutcome == .connectionError }.count == 3 && report.files.filter { $0.effectiveOutcome == .skipped }.count == report.files.count - 3, "Connection vs skipped conflated")
            try check(report.files.allSatisfy { $0.effectiveOutcome != .succeeded }, "Mixed-device data accepted")
        }
        try test("remote command failure remains distinct from local transport and skipped") {
            let f = try Fixture(); f.ssh.status = 0; f.ssh.producerStatus = 7
            let report = try f.collect()
            try check(report.files.allSatisfy { $0.effectiveOutcome == .commandFailed && $0.status == 7 }, "Remote failures misclassified")
            let g = try Fixture(); g.ssh.status = 0; g.ssh.failQueries = true
            let offline = try g.collect()
            try check(g.ssh.queryCount == 3 && offline.files.dropFirst(3).allSatisfy { $0.effectiveOutcome == .skipped }, "Unbounded retries")
        }
        try test("diagnostics are serialized and metadata commands never touch EFS or protection") {
            let f = try Fixture()
            try rejects("блокировки") { _ = try ModemInformationManager(engine: f.engine).collectDiagnostics(adb: f.client) }
            let all = ModemInformationManager.diagnosticCommands.map { $0.2 }.joined(separator: "\n") + DiagnosticTransportSelector.identityCommand
            for bad in ["sensor_id", "codec_id", "zte_config", "zte_nv", "iptables-restore", "setprop", "reboot", "dd if=", "cat /config"] { try check(!all.contains(bad), "Unsafe command: " + bad) }
            let metadata = ModemInformationManager.diagnosticCommands.first { $0.0 == "filesystem-layout.txt" }!.2
            try check(metadata.contains("Linux /config is NOT modem EFS /config") && metadata.contains("/data/local/tmp") && metadata.contains("stat -c") && metadata.contains("df -Pk"), "Incomplete metadata scope")
        }
        print("RESULT \(passed) passed; 0 failed")
    }
}
