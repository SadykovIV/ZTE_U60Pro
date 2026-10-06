import Foundation

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ reason: String) throws { if try !value() { throw Failure.assertion(reason) } }
private func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch let error as Failure { throw error } catch { return }
    throw Failure.assertion("unexpected success")
}
private let sampleCID = String(repeating: "a", count: 32)
private let sampleBoot = "11111111-1111-4111-8111-111111111111"
private let proof = SSHReadProof(uid: "1000", system: "Linux", architecture: "aarch64", cid: sampleCID, bootID: sampleBoot)
private func proofData(_ value: SSHReadProof) -> Data {
    Data((["ZTE_SSH_READ_V1", value.uid ?? "?", value.system ?? "?", value.architecture ?? "?", value.cid ?? "?", value.bootID ?? "?", "?", "?"].joined(separator: "\n") + "\n").utf8)
}
private func facts() -> [String: String] {
    var value = Dictionary(uniqueKeysWithValues: FirmwareSupportCollector.factKeys.map { ($0, "not_assessed") })
    value.merge(["uid": "1000", "os": "Linux", "architecture": "aarch64", "firmware": "FLY_CN_MU5250V1.0.0B13", "inner": "BD_FLYMODEMMU5250V1.0.0B28", "agent_present": "0", "agent_running_count": "0", "ui_mounts": "0", "http_health_status": "401", "http_capabilities_status": "403", "http_dashboard_status": "000"]) { _, new in new }
    return value
}
private func snapshot(_ files: [String: Data], states: [String: String] = [:], values: [String: String] = facts()) -> Data {
    var lines = ["FIRMWARE_SUPPORT_V1"]
    for key in values.keys.sorted() { lines.append("FACT\t" + key + "\t" + Data(values[key]!.utf8).base64EncodedString()) }
    for id in FirmwareSupportCollector.allIDs {
        if let data = files[id], states[id] == nil {
            lines.append("FILE\t\(id)\tpresent\t\(data.count)\t\(digest(data))\t0\t755\t1")
        } else { lines.append("FILE\t\(id)\t\(states[id] ?? "missing")\t-\t-\t-\t-\t-") }
    }
    lines.append("FIRMWARE_SUPPORT_END")
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}
private final class Wire: RemoteTransport, BackupStreamTransport {
    var files: [String: Data]
    var beforeProof = proof, afterProof = proof
    var states = [String: String]()
    var afterSnapshot: Data?
    var inspectOverride: Data?
    var quickCount = 0, inspectCount = 0, streamCount = 0
    var streamFailure = false, badReceipt = false, tamperFile = false, noSpace = false
    var temporaryFile: URL?
    var calls = [String](), inputs = [Data]()
    init() {
        var elf = Data(repeating: 0, count: 64); elf.replaceSubrange(0..<7, with: [127, 69, 76, 70, 2, 1, 1]); elf[16] = 2; elf[18] = 183
        files = ["ui": elf + Data([255, 0, 128, 42]), "english": Data("[UI]\nhello=Hello\n".utf8), "chinese": Data("[UI]\nhello=你好\n".utf8), "init": Data("#!/bin/sh\nexec /usr/bin/zte_topsw_devui\n".utf8)]
    }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        if command == SSHReadProof.quickCommand { quickCount += 1; return CommandResult(status: 0, stdout: proofData(quickCount == 1 ? beforeProof : afterProof), stderr: Data()) }
        try check(command == "sh -s -- inspect '192.0.2.1'" && input != nil, "unexpected command or absent helper")
        inspectCount += 1; inputs.append(input!)
        return CommandResult(status: 0, stdout: inspectOverride ?? (inspectCount == 2 ? afterSnapshot : nil) ?? snapshot(files, states: states), stderr: Data())
    }
    func stream(_ command: String, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        throw Failure.assertion("helper stdin required")
    }
    func stream(_ command: String, input: Data?, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        calls.append(command); streamCount += 1
        let matches = FirmwareSupportCollector.allIDs.filter { command.hasPrefix("sh -s -- file '\($0)' ") }
        try check(matches.count == 1 && input != nil, "unsafe command")
        let id = matches[0], data = files[id]!
        try check(maxBytes == FirmwareSupportCollector.limit(id), "wrong per-file bound")
        try check(command == "sh -s -- file '\(id)' '\(data.count)' '\(digest(data))'", "unbound file request")
        inputs.append(input!)
        temporaryFile = destination
        try savePrivate(tamperFile ? Data("corrupt".utf8) : data, destination)
        if noSpace { throw CocoaError(.fileWriteOutOfSpace) }
        if streamFailure { throw IMEIError.message("PRIVATE_STDERR_CANARY password=unsafe") }
        return BackupStreamResult(sha256: badReceipt ? String(repeating: "b", count: 64) : digest(data), bytes: Int64(data.count))
    }
}
private final class Fixture {
    let root: URL, output: URL, resources: URL, wire = Wire(), connection: Connection
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-support-tests-" + UUID().uuidString.lowercased())
        try secureDirectory(root)
        output = root.appendingPathComponent("export.zip")
        resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        for file in ["key", "known_hosts"] { try savePrivate(Data("test".utf8), root.appendingPathComponent(file)) }
        connection = Connection(host: "192.0.2.1", port: "2222", keyPath: root.appendingPathComponent("key").path, knownHostsPath: root.appendingPathComponent("known_hosts").path)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func collector(selected: SSHReadProof = proof, mode: ConnectionMode = .ssh, endpoint: String? = nil, selectionIsCurrent: @escaping @Sendable () -> Bool = { true }) throws -> FirmwareSupportCollector {
        let diagnostic = DiagnosticSession(reason: "test", proof: selected, readIdentity: { selected }, execute: { _, _ in throw Failure.assertion("no session executor calls") })
        let session = ReadOnlyChannelSession(mode: mode, summary: ConnectionDeviceSummary(), diagnosticSession: diagnostic,
            sshEndpoint: endpoint ?? ConnectionRouter.sshEndpoint(connection), readSummary: { ConnectionDeviceSummary() })
        return try FirmwareSupportCollector(root: root, resources: resources, connection: connection, session: session, remote: wire, streamer: wire, secrets: ["KNOWN_PASSWORD_CANARY"], selectionIsCurrent: selectionIsCurrent)
    }
    func payload(_ relative: String) throws -> Data {
        let reply = try HostProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", output.path, "ZTE-Firmware-Support/" + relative], timeout: 20)
        try check(reply.status == 0, "zip member missing: " + relative); return reply.stdout
    }
    func noArchive() throws { try check(!FileManager.default.fileExists(atPath: output.path), "failed collection published") }
}

@main struct FirmwareSupportTests {
    static func main() throws {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) { do { try body(); passed += 1; print("PASS " + name) } catch { failed += 1; print("FAIL \(name): \(error)") } }
        test("metadata accepts unknown firmware, no agent and authentication-needed HTTP") {
            let f = try Fixture(), value = try FirmwareSupportCollector.parseSnapshot(snapshot(f.wire.files))
            try check(value.facts["inner"] == "BD_FLYMODEMMU5250V1.0.0B28" && value.facts["http_health_status"] == "401", "firmware or HTTP gate")
        }
        test("metadata rejects missing, duplicate, secret and malformed fields") {
            let f = try Fixture(), good = String(decoding: snapshot(f.wire.files), as: UTF8.self)
            for text in [good.replacingOccurrences(of: "FIRMWARE_SUPPORT_END", with: "FACT\tpassword\tU0VDUkVU\nFIRMWARE_SUPPORT_END"),
                         good.replacingOccurrences(of: "FIRMWARE_SUPPORT_END", with: "FACT\tuid\tMA==\nFIRMWARE_SUPPORT_END"),
                         good.replacingOccurrences(of: "FIRMWARE_SUPPORT_END", with: "FILE\t../../escape\tmissing\t-\t-\t-\t-\t-\nFIRMWARE_SUPPORT_END"),
                         good.replacingOccurrences(of: "FILE\tui\tpresent", with: "FILE\tui\tother"), String(good.dropLast(22)), good + "PRIVATE\n"] {
                try rejects { _ = try FirmwareSupportCollector.parseSnapshot(Data(text.utf8)) }
            }
            var invalid = facts(); invalid["agent_mode"] = "password=CANARY"; try rejects { _ = try FirmwareSupportCollector.parseSnapshot(snapshot(f.wire.files, values: invalid)) }
            invalid = facts(); invalid["firmware"] = "line\nsecret"; try rejects { _ = try FirmwareSupportCollector.parseSnapshot(snapshot(f.wire.files, values: invalid)) }
            try rejects { _ = try FirmwareSupportCollector.parseSnapshot(Data(repeating: 32, count: 65_537)) }
        }
        test("unknown firmware nonroot read publishes exact binaries without agent or NV") {
            let f = try Fixture(), result = try f.collector().collect(to: f.output)
            try check(result.complete && result.fileCount == 4 && result.omissions == 0, "false incompleteness")
            for (id, data) in f.wire.files { try check(try f.payload("files/" + id) == data, "binary changed") }
            let metadataData = try f.payload("metadata.json"), metadata = try JSONSerialization.jsonObject(with: metadataData) as! [String: Any]
            try check(metadata["writeAuthorization"] as? String == "none", "write authorization")
            try check(!String(decoding: metadataData, as: UTF8.self).contains(sampleCID) && !String(decoding: metadataData, as: UTF8.self).contains(sampleBoot), "private device identifiers exported")
            try check(f.wire.quickCount == 2 && f.wire.inspectCount == 2 && f.wire.streamCount == 4 && f.wire.calls.count == 8, "unexpected calls")
            try check(f.wire.inputs.allSatisfy { digest($0) == FirmwareSupportCollector.helperSHA256 }, "unverified helper")
            try check(try DeviceBackups.hashFile(f.output).sha256 == result.sha256, "archive hash")
        }
        test("missing and unsafe required files export a marked incomplete dataset") {
            for state in ["missing", "not_assessed", "symlink", "not_regular", "unreadable", "empty"] {
                let f = try Fixture(); f.wire.states["english"] = state
                let result = try f.collector().collect(to: f.output)
                try check(!result.complete && result.omissions == 1 && result.fileCount == 3 && f.wire.streamCount == 3, "missing file treated as complete")
                let value = try JSONSerialization.jsonObject(with: f.payload("metadata.json")) as! [String: Any]
                try check(value["missingRequired"] as? [String] == ["english"], "omission not reported")
            }
        }
        test("present original backup files are explicitly included") {
            let f = try Fixture(); f.wire.files["original_ui"] = Data("original binary".utf8)
            let result = try f.collector().collect(to: f.output)
            try check(result.complete && result.fileCount == 5 && (try f.payload("files/original_ui")) == Data("original binary".utf8), "original not captured")
        }
        test("a file over the byte budget is reported without downloading it") {
            let f = try Fixture()
            let raw = String(decoding: snapshot(f.wire.files), as: UTF8.self).replacingOccurrences(of: "FILE\tui\tpresent\t\(f.wire.files["ui"]!.count)\t", with: "FILE\tui\tpresent\t\(FirmwareSupportCollector.limit("ui") + 1)\t")
            f.wire.inspectOverride = Data(raw.utf8)
            let result = try f.collector().collect(to: f.output)
            try check(!result.complete && result.omissions == 1 && f.wire.streamCount == 3, "oversized file was read or not reported")
            try check(String(decoding: try f.payload("metadata.json"), as: UTF8.self).contains("over_limit"), "limit omission not exported")
        }
        test("readable session without CID and boot stays transport-bound") {
            let f = try Fixture(); f.wire.beforeProof.cid = nil; f.wire.beforeProof.bootID = nil; f.wire.afterProof = f.wire.beforeProof
            _ = try f.collector(selected: f.wire.beforeProof).collect(to: f.output)
            let metadata = try JSONSerialization.jsonObject(with: f.payload("metadata.json")) as! [String: Any]
            let continuity = metadata["continuity"] as! [String: Bool]
            try check(continuity["cidCompared"] == false && continuity["bootCompared"] == false && continuity["identityStable"] == false && continuity["observedFactsStable"] == true && metadata["bindingStrength"] as? String == "transport-only", "fabricated binding")
        }
        test("selected target mismatch is rejected before file reads") {
            let f = try Fixture(); f.wire.beforeProof.cid = String(repeating: "b", count: 32)
            try rejects { _ = try f.collector().collect(to: f.output) }
            try check(f.wire.streamCount == 0 && f.wire.inspectCount == 0, "read after mismatch"); try f.noArchive()
        }
        test("post-read reboot or changed files refuses publication") {
            for fileChange in [false, true] {
                let f = try Fixture()
                if fileChange { var files = f.wire.files; files["init"] = Data("changed".utf8); f.wire.afterSnapshot = snapshot(files) }
                else { f.wire.afterProof.bootID = "22222222-2222-4222-8222-222222222222" }
                try rejects { _ = try f.collector().collect(to: f.output) }; try f.noArchive()
            }
        }
        test("receipt mismatch, tampered local output and partial transport cannot publish") {
            for kind in 0..<3 {
                let f = try Fixture(); f.wire.badReceipt = kind == 0; f.wire.tamperFile = kind == 1; f.wire.streamFailure = kind == 2
                do { _ = try f.collector().collect(to: f.output); throw Failure.assertion("unexpected success") }
                catch let error as Failure { throw error }
                catch { try check(!error.localizedDescription.contains("PRIVATE_STDERR_CANARY"), "stderr leak") }
                try f.noArchive()
            }
        }
        test("cancellation preserves an existing destination and performs no remote read") {
            let f = try Fixture(); try savePrivate(Data("previous archive".utf8), f.output)
            try rejects { _ = try f.collector().collect(to: f.output, cancelled: { true }) }
            try check(f.wire.calls.isEmpty && (try Data(contentsOf: f.output)) == Data("previous archive".utf8), "cancellation changed destination")
        }
        test("out-of-space after partial output removes local staging and preserves the prior archive") {
            let f = try Fixture(); f.wire.noSpace = true
            try savePrivate(Data("previous archive".utf8), f.output)
            try rejects { _ = try f.collector().collect(to: f.output) }
            try check(f.wire.streamCount == 1 && (try Data(contentsOf: f.output)) == Data("previous archive".utf8), "out-of-space replaced the destination")
            try check(f.wire.temporaryFile != nil && !FileManager.default.fileExists(atPath: f.wire.temporaryFile!.path), "partial file retained")
        }
        test("a changed UI selection refuses final rename and preserves prior archive") {
            let f = try Fixture(); try savePrivate(Data("previous archive".utf8), f.output)
            try rejects { _ = try f.collector(selectionIsCurrent: { false }).collect(to: f.output) }
            try check(f.wire.streamCount == 4 && f.wire.quickCount == 2 && (try Data(contentsOf: f.output)) == Data("previous archive".utf8), "stale context published")
        }
        test("wrong selected transport or endpoint never dispatches") {
            let f = try Fixture()
            try rejects { _ = try f.collector(mode: .adb) }; try rejects { _ = try f.collector(endpoint: "other") }
            try check(f.wire.calls.isEmpty, "fallback used")
        }
        test("ELF summaries describe bytes without assuming supported ABI") {
            let f = try Fixture(), elf = FirmwareSupportCollector.elfMetadata(f.wire.files["ui"]!)
            try check(elf["class"] == "64" && elf["byteOrder"] == "little" && elf["machine"] == "183", "ELF64")
            var data = f.wire.files["ui"]!; data[4] = 1; data[5] = 2; data[18] = 0; data[19] = 40
            let elf32 = FirmwareSupportCollector.elfMetadata(data)
            try check(elf32["class"] == "32" && elf32["machine"] == "40", "ELF32")
            try check(FirmwareSupportCollector.elfMetadata(Data("garbage".utf8))["status"] == "not_assessed", "unknown ELF accepted")
        }
        test("activity projection strips secrets and excludes arbitrary details and traces") {
            let f = try Fixture(), journal = try ActivityJournal(root: f.root)
            try journal.record(operationID: "test", category: "test", title: "KNOWN_PASSWORD_CANARY https://private.example/SECRET_URL LPA:1$server$SHORT", result: "failed", details: ["argv": "PRIVATE_ARGV", "environ": "PRIVATE_ENV", "password": "PRIVATE_PASSWORD"])
            let result = String(decoding: FirmwareSupportCollector.activityPayload(root: f.root, secrets: ["KNOWN_PASSWORD_CANARY"]), as: UTF8.self)
            for canary in ["KNOWN_PASSWORD_CANARY", "private.example", "SHORT", "PRIVATE_ARGV", "PRIVATE_ENV", "PRIVATE_PASSWORD"] { try check(!result.contains(canary), "privacy leak") }
            try check(result.contains("timestamp") && result.contains("failed"), "events missing")
        }
        print("FirmwareSupportTests: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
