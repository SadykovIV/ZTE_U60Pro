import Foundation
import Darwin
private func check(_ yes: @autoclosure () throws -> Bool, _ why: String) throws { if try !yes() { throw IMEIError.message(why) } }
private func reject(_ work: () throws -> Void) throws { do { try work() } catch { return }; throw IMEIError.message("Expected rejection") }
private final class Probe: RemoteTransport {
    var calls = [String](), unknown = false, fail = false, reboot = false, identities = 0, partial = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        if partial { throw CommandFailure(message: "timeout", partial: CommandResult(status: -1, stdout: Data("before timeout\npassword=TOP-SECRET\n".utf8), stderr: Data("link lost".utf8))) }
        if fail { throw IMEIError.message("unreachable") }
        if command.hasPrefix("sha256sum /firmware") || command == DiagnosticTransportSelector.identityCommand {
            identities += 1
            return CommandResult(status: 0, stdout: Data(((unknown ? String(repeating: "a", count: 64) : ModemEngine.firmwareHash) + " /firmware/image/modem.b16\n" + ModemEngine.routerHash + " /usr/bin/diag-router\n0123456789abcdef0123456789abcdef\n" + (reboot && identities > 1 ? "3a2fb1c5-1bbf-4d3b-92a8-3daaf5510601" : "2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601") + "\n").utf8), stderr: Data())
        }
        return CommandResult(status: 0, stdout: Data("normal output\n__DIAGNOSTIC_RESULT__0\n".utf8), stderr: Data())
    }
}
@main enum DiagnosticArchiveTests {
    static func main() throws {
        let fm = FileManager.default, temp = fm.temporaryDirectory.appendingPathComponent("zte-archive-tests-" + UUID().uuidString)
        try secureDirectory(temp); defer { try? fm.removeItem(at: temp) }
        var count = 0
        func test(_ title: String, _ work: () throws -> Void) throws { try work(); count += 1; print("PASS " + title) }
        func engine(_ probe: Probe) throws -> ModemEngine { try ModemEngine(root: temp.appendingPathComponent(UUID().uuidString), resources: temp, connection: Connection(host: "192.168.0.1", port: "2222", keyPath: "/dev/null", knownHostsPath: "/dev/null"), transport: probe) }
        try test("Unknown firmware permits diagnostics while the write identity guard still refuses") {
            let probe = Probe(); probe.unknown = true
            let e = try engine(probe)
            try reject { _ = try e.identity() }
            let report = try e.locked { try ModemInformationManager(engine: e).collectDiagnostics() }
            try check(report.files.allSatisfy { $0.status == 0 } && report.warnings?.isEmpty == false, "Unknown firmware not diagnosed")
            try check(!e.connection.skipFirmwareCheck && !probe.calls.contains(where: { $0.contains("zte_nv") || $0.contains("reboot") || $0.contains("iptables-restore") }), "Probe changed policy or device")
            try reject { _ = try e.identity() }
        }
        try test("Offline and rebooted devices preserve partial reports with explicit warnings") {
            let offline = Probe(); offline.fail = true
            let offlineEngine = try engine(offline)
            let report = try offlineEngine.locked { try ModemInformationManager(engine: offlineEngine).collectDiagnostics() }
            try check(report.identity == nil && report.files.allSatisfy { $0.status != 0 }, "Offline falsely complete")
            try check(offline.calls.count == 1 && fm.fileExists(atPath: report.url.appendingPathComponent("manifest.json").path), "Offline loop unbounded or manifest lost")
            let reboot = Probe(); reboot.reboot = true
            let rebootEngine = try engine(reboot)
            let changed = try rebootEngine.locked { try ModemInformationManager(engine: rebootEngine).collectDiagnostics() }
            try check(changed.warnings?.contains(where: { $0.contains("изменились") }) == true, "Reboot not reported")
        }
        try test("Partial SSH output and request correlation survive timeout without secrets") {
            let probe = Probe(); probe.partial = true
            let e = try engine(probe)
            try reject { _ = try e.transport.run("uname -a", input: Data("NEVER-LOG-STDIN".utf8), timeout: 1) }
            let events = try ActivityJournal(root: e.root).recent()
            let done = events.first { $0.result == "failed" }!
            try check(done.details["timedOut"] == "true" && done.details["requestID"] != nil, "Timeout metadata lost")
            let file = e.root.appendingPathComponent("Activity/Traces/" + e.logDirectory.lastPathComponent + "/" + done.details["requestID"]! + ".json")
            let text = try String(contentsOf: file, encoding: .utf8)
            try check(text.contains("before timeout") && text.contains("link lost") && !text.contains("TOP-SECRET") && !text.contains("NEVER-LOG-STDIN"), "Bad trace")
        }
        try test("Sanitization removes VPN links multiline private keys NV and nested auth fields") {
            let samples = ["vless://TOP-SECRET@example.com:443?encryption=none#vpn", "-----BEGIN OPENSSH PRIVATE KEY-----\nTOP-SECRET\n-----END OPENSSH PRIVATE KEY-----", "APP_NV index=0 data=" + String(repeating: "f", count: 256), "Authorization: Bearer TOP-SECRET", "password 'TOP-SECRET'"]
            for sample in samples { let text = ActivityJournal.sanitize(sample); try check(!text.contains("TOP-SECRET") && !text.contains(String(repeating: "f", count: 256)), "Secret leaked") }
            try check(!ActivityJournal.sanitize("EFS_CHUNK offset=0 length=4 data=deadbeef").contains("deadbeef"), "Short EFS data leaked")
            let object: [String: Any] = ["password": "TOP-SECRET", "nested": ["uuid": "TOP-SECRET", "firmware": "B99"], "output": "vless://TOP-SECRET@example.com"]
            let cleaned = try JSONSerialization.data(withJSONObject: ActivityJournal.sanitizeJSON(object))
            try check(!String(decoding: cleaned, as: UTF8.self).contains("TOP-SECRET") && String(decoding: cleaned, as: UTF8.self).contains("B99"), "Nested JSON")
            try check(ActivityJournal.diagnosticOutput(Data("UNLABELLED-SECRET".utf8), command: "cat /etc/shadow").contains("исключён"), "Credential store leaked")
        }
        try test("HTTP audit preserves method result and firmware without auth bodies or cookies") {
            final class Web: WebTransport {
                func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply {
                    WebReply(data: Data(#"[{"result":[0,{"integrate_version":"B99","password":"TOP-SECRET","token":"TOP-SECRET"}]}]"#.utf8), headers: ["set-cookie":"TOP-SECRET"])
                }
            }
            let root = temp.appendingPathComponent("web"), journal = try ActivityJournal(root: root)
            let transport = AuditedWebTransport(base: Web(), journal: journal, operationID: "web", endpoint: "192.168.0.1")
            let payload = Data(#"[{"params":["TOP-SECRET","zwrt_web","device_info",{"password":"TOP-SECRET"}]}]"#.utf8)
            _ = try transport.request(path: "/ubus/", data: payload, contentType: "application/json", cookie: "TOP-SECRET")
            let events = journal.recent(), text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
            try check(events.count == 2 && events.first?.details["rpcMethod"] == "device_info" && events.first?.details["integrate_version"] == "B99", "HTTP metadata lost")
            try check(!text.contains("TOP-SECRET"), "HTTP credentials leaked")
        }
        try test("Host command timeout retains output generated before termination") {
            do {
                _ = try HostProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf partial-output; exec sleep 10"], timeout: 0.2)
                throw IMEIError.message("Timeout missing")
            } catch let error as CommandFailure {
                try check(String(decoding: error.partial.stdout, as: UTF8.self) == "partial-output", "Partial output discarded")
            }
        }
        try test("ZIP allowlist omits backups keys symlinks and binary data; hashes verify after extraction") {
            let root = temp.appendingPathComponent("archive-root"), id = UUID().uuidString.lowercased()
            try secureDirectory(root)
            let journal = try ActivityJournal(root: root)
            try journal.record(operationID: "test", category: "test", title: "normal event", result: "completed")
            for path in ["SSH/id_ed25519", "Backups/" + id + "/nv0.bin", "SetupBackups/" + id + "/back_parameter.original", "connection.json", "profiles.json"] {
                let file = root.appendingPathComponent(path); try secureDirectory(file.deletingLastPathComponent()); try savePrivate(Data("TOP-SECRET".utf8), file)
            }
            let dir = root.appendingPathComponent("Diagnostics/" + id); try secureDirectory(dir)
            try savePrivate(Data(#"{"firmware":"B99","password":"TOP-SECRET","nested":{"token":"TOP-SECRET"}}"#.utf8), dir.appendingPathComponent("device.json"))
            try savePrivate(Data("normal modem ready\nvless://TOP-SECRET@example.com\n".utf8), dir.appendingPathComponent("system.log"))
            try savePrivate(Data([0, 1, 2]), dir.appendingPathComponent("kernel.log"))
            try fm.createSymbolicLink(at: dir.appendingPathComponent("memory.txt"), withDestinationURL: root.appendingPathComponent("SSH/id_ed25519"))
            let outside = temp.appendingPathComponent("outside"); try secureDirectory(outside); try savePrivate(Data("TOP-SECRET".utf8), outside.appendingPathComponent("storage.txt"))
            let symlinkID = UUID().uuidString.lowercased()
            try fm.createSymbolicLink(at: root.appendingPathComponent("Diagnostics/" + symlinkID), withDestinationURL: outside)
            try reject { _ = try DiagnosticArchive.readRegular(root: root, relative: "Diagnostics/" + symlinkID + "/storage.txt", limit: 100) }
            let zip = temp.appendingPathComponent("support.zip")
            let result = try DiagnosticArchive(root: root).export(to: zip, context: ["version": "test", "endpoint": "192.168.0.1:2222"])
            try check(result.warnings >= 2 && result.sha256 == digest(Data(contentsOf: zip)), "ZIP result incorrect: warnings=\(result.warnings) files=\(result.fileCount)")
            let output = temp.appendingPathComponent("unzipped")
            let unpacked = try HostProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, output.path], timeout: 20)
            try check(unpacked.status == 0, "Cannot extract")
            let folder = output.appendingPathComponent("ZTE-Diagnostics")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
            let entries = manifest["files"] as! [[String: String]]
            try check(entries.count + 1 == result.fileCount, "Manifest missing files")
            try check(entries.contains { $0["path"] == "Diagnostics/" + id + "/device.json" } && entries.contains { $0["path"]?.hasSuffix("/system.log") == true } && entries.contains { $0["path"]?.hasSuffix(".jsonl") == true }, "Ordinary diagnostic files were omitted: " + String(describing: manifest))
            for entry in entries {
                let path = entry["path"]!, bytes = try Data(contentsOf: folder.appendingPathComponent(entry["path"]!))
                try check(digest(bytes) == entry["sha256"], "Archive hash mismatch")
                let text = String(decoding: bytes, as: UTF8.self)
                try check(!text.contains("TOP-SECRET"), "Archive leaked secret in " + path)
                try check(!path.contains("id_ed25519") && !path.contains("nv0.bin") && !path.contains("back_parameter"), "Private file included")
            }
            let mode = try fm.attributesOfItem(atPath: zip.path)[.posixPermissions] as! NSNumber
            try check(mode.intValue == 0o600, "Public archive permissions")
        }
        try test("Large journals retain valid recent events and explicitly record truncation") {
            let root = temp.appendingPathComponent("large"), journal = try ActivityJournal(root: root)
            try journal.record(operationID: "end", category: "test", title: "LATEST-EVENT", result: "completed")
            let file = try fm.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil).first!
            let recent = try Data(contentsOf: file)
            var data = Data(repeating: 120, count: DiagnosticArchive.fileLimit + 200); data.append(10); data.append(recent)
            try savePrivate(data, file)
            let zip = temp.appendingPathComponent("large.zip")
            let result = try DiagnosticArchive(root: root).export(to: zip, context: [:])
            let diagnosticManifest = try HostProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", zip.path, "ZTE-Diagnostics/manifest.json"], timeout: 20)
            try check(result.warnings >= 2, "Truncation was silent: " + String(decoding: diagnosticManifest.stdout, as: UTF8.self))
            let listed = try HostProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", zip.path, "ZTE-Diagnostics/Activity/" + file.lastPathComponent], timeout: 20)
            try check(String(decoding: listed.stdout, as: UTF8.self).contains("LATEST-EVENT"), "Recent event lost")
        }
        func researchReport() -> FirmwareResearchReport {
            var report = FirmwareResearchReport(startedAt: "2026-10-05T09:00:00Z", specificationRevision: 8, application: ["version": "fixture", "password": "CACHE-SECRET"])
            report.warnings = ["-----BEGIN PRIVATE KEY-----\nPRIVATE-PEM-BODY\n-----END PRIVATE KEY-----", "https://example.invalid/private-subscription"]
            report.finishedAt = "2026-10-05T09:00:02Z"; report.transport = "ssh"; report.outcome = "partial"
            report.probes = [.init(id: "identity", title: .init(ru: "Устройство", en: "Device"), category: "identity", command: "id", outcome: "success", exitCode: 0,
                stdout: "aarch64\npassword=CACHE-SECRET\n867123456789017\n0123456789abcdef0123456789abcdef\n", stderr: "", durationSeconds: 0.1, facts: ["architecture": "aarch64", "iccid": "867123456789017"], localExitCode: 0, remoteExitCode: 0)]
            return report
        }
        func archive(_ root: URL) throws -> (DiagnosticArchiveResult, URL, [String: Any]) {
            let zip = temp.appendingPathComponent(UUID().uuidString + ".zip")
            let result = try DiagnosticArchive(root: root).export(to: zip, context: ["version": "fixture"])
            let output = temp.appendingPathComponent(UUID().uuidString)
            try check(try HostProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, output.path], timeout: 20).status == 0, "ZIP extraction failed")
            let folder = output.appendingPathComponent("ZTE-Diagnostics")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
            return (result, folder, manifest)
        }
        try test("Common ZIP contains cached research, probe evidence, timestamps and application activity with fresh hashes and redaction") {
            let root = temp.appendingPathComponent("combined"), report = researchReport()
            let journal = try ActivityJournal(root: root)
            try journal.record(operationID: "combined", category: "test", title: "APPLICATION-ACTION", result: "completed")
            _ = try FirmwareResearchArchive.save(report, root: root)
            try savePrivate(Data("NEIGHBOUR-SECRET".utf8), root.appendingPathComponent("FirmwareResearch/unlisted.txt"))
            let (_, folder, manifest) = try archive(root)
            let entries = manifest["files"] as! [[String: String]], prefix = "FirmwareResearch/" + report.id + "/"
            for file in ["report.json", "application.json", "REPORT.md", "probes/identity.json", "manifest-sha256.json"] {
                try check(entries.contains { $0["path"] == prefix + file }, "Cached research omitted from common ZIP: " + file)
            }
            var combined = ""
            for entry in entries {
                let data = try Data(contentsOf: folder.appendingPathComponent(entry["path"]!))
                try check(digest(data) == entry["sha256"], "Common manifest digest mismatch")
                combined += String(decoding: data, as: UTF8.self)
            }
            try check(combined.contains("APPLICATION-ACTION") && combined.contains(report.startedAt) && combined.contains(report.finishedAt) && combined.contains("aarch64"), "Saved evidence or application action lost")
            for secret in ["CACHE-SECRET", "NEIGHBOUR-SECRET", "PRIVATE-PEM-BODY", "private-subscription", "867123456789017", "0123456789abcdef0123456789abcdef"] { try check(!combined.contains(secret), "Cached research leaked " + secret) }
            let nested = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: folder.appendingPathComponent(prefix + "manifest-sha256.json")))
            for entry in nested { try check(try digest(Data(contentsOf: folder.appendingPathComponent(prefix + entry["path"]!))) == entry["sha256"], "Research manifest digest mismatch") }
        }
        try test("Common cached export redacts activation and matching credentials while preserving firmware SHA evidence") {
            let root = temp.appendingPathComponent("activation-privacy")
            var report = researchReport()
            let benign = String(repeating: "a", count: 64)
            report.application["activationCode"] = "SHORT-ACTIVATION"
            report.application["matchingID"] = "SHORT-MATCHING"
            report.application["smdpAddress"] = "PRIVATE-SMDP-HOST"
            let p = report.probes[0]
            report.probes = [.init(id: p.id, title: p.title, category: p.category, command: p.command, outcome: p.outcome, exitCode: p.exitCode,
                stdout: "LPA:1$example.invalid$SHORT-LPA-CODE\nmatchingID=TEXT-MATCHING\nactivation_code=TEXT-ACTIVATION\nSM-DP+ Address: PRIVATE-SMDP-TEXT\nfirmware_sha256=" + benign + "\nFR_FACT activation_code_hash=" + String(repeating: "f", count: 64),
                stderr: "", durationSeconds: p.durationSeconds,
                facts: ["firmware_sha256": benign, "activation_code_hash": String(repeating: "b", count: 64), "matching_id_hash": String(repeating: "c", count: 64), "confirmation_code_hash": String(repeating: "d", count: 64)])]
            report.observations = [.init(id: "private-fact", title: .init(ru: "Факт", en: "Fact"), probe: p.id, fact: "activation_code_hash", state: "known", value: String(repeating: "e", count: 64))]
            _ = try FirmwareResearchArchive.save(report, root: root)
            let (_, folder, manifest) = try archive(root)
            let entries = manifest["files"] as! [[String: String]]
            let text = try entries.map { String(decoding: try Data(contentsOf: folder.appendingPathComponent($0["path"]!)), as: UTF8.self) }.joined(separator: "\n")
            let canaries = ["SHORT-ACTIVATION", "SHORT-MATCHING", "PRIVATE-SMDP-HOST", "SHORT-LPA-CODE", "TEXT-MATCHING", "TEXT-ACTIVATION", "PRIVATE-SMDP-TEXT"] + ["b", "c", "d", "e", "f"].map { String(repeating: $0, count: 64) }
            try check(!canaries.contains(where: text.contains), "Cached activation/matching/SM-DP credential leaked")
            let saved = try JSONDecoder().decode(FirmwareResearchReport.self, from: Data(contentsOf: folder.appendingPathComponent("FirmwareResearch/" + report.id + "/report.json")))
            try check(saved.probes[0].facts["firmware_sha256"] == benign, "Benign firmware SHA evidence was removed")
        }
        try test("Missing, malformed, unsafe and oversized cached research is omitted without losing the common ZIP") {
            for kind in ["missing", "pointer-json", "pointer-path", "pointer-oversize", "pointer-symlink", "report-symlink", "parent-symlink", "report-hardlink", "report-fifo", "report-oversize", "identity-mismatch", "probe-path", "duplicate-probe"] {
                let root = temp.appendingPathComponent("omission-" + kind), report = researchReport()
                let journal = try ActivityJournal(root: root)
                try journal.record(operationID: "offline", category: "test", title: "APPLICATION-ACTION", result: "completed")
                let base = root.appendingPathComponent("FirmwareResearch"), pointer = base.appendingPathComponent("latest.json"), file = base.appendingPathComponent(report.id + "/report.json")
                if kind != "missing" { _ = try FirmwareResearchArchive.save(report, root: root) }
                switch kind {
                case "pointer-json": try savePrivate(Data("not-json CACHE-SECRET".utf8), pointer)
                case "pointer-path": try saveJSON(["id": "../CACHE-SECRET"], pointer)
                case "pointer-oversize": try savePrivate(Data(repeating: 32, count: 4097), pointer)
                case "pointer-symlink", "report-symlink":
                    let path = kind == "pointer-symlink" ? pointer : file
                    let outside = temp.appendingPathComponent(UUID().uuidString); try savePrivate(Data("CACHE-SECRET".utf8), outside)
                    try fm.removeItem(at: path); try fm.createSymbolicLink(at: path, withDestinationURL: outside)
                case "parent-symlink":
                    let outside = temp.appendingPathComponent(UUID().uuidString); try fm.moveItem(at: base, to: outside)
                    try fm.createSymbolicLink(at: base, withDestinationURL: outside)
                case "report-hardlink": try fm.linkItem(at: file, to: temp.appendingPathComponent(UUID().uuidString))
                case "report-fifo": try fm.removeItem(at: file); try check(mkfifo(file.path, 0o600) == 0, "FIFO fixture")
                case "report-oversize":
                    let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 32 * 1024 * 1024 + 1); try handle.close()
                case "identity-mismatch": var wrong = report; wrong.id = UUID().uuidString.lowercased(); try saveJSON(wrong, file)
                case "probe-path":
                    var wrong = report; let p = report.probes[0]
                    wrong.probes = [.init(id: "../escape", title: p.title, category: p.category, command: p.command, outcome: p.outcome, exitCode: p.exitCode, stdout: p.stdout, stderr: p.stderr, durationSeconds: p.durationSeconds, facts: p.facts)]
                    try saveJSON(wrong, file)
                case "duplicate-probe": var wrong = report; wrong.probes.append(report.probes[0]); try saveJSON(wrong, file)
                default: break
                }
                let (result, _, manifest) = try archive(root)
                let entries = manifest["files"] as! [[String: String]]
                try check(result.warnings > 0 && (manifest["warnings"] as! [String]).contains { $0.hasPrefix("FirmwareResearch:") }, "Research omission unreported: " + kind)
                try check(entries.contains { $0["path"]?.hasPrefix("Activity/") == true } && !entries.contains { $0["path"]?.hasPrefix("FirmwareResearch/") == true }, "Unsafe research included or activity lost: " + kind)
                try check(!String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self).contains("CACHE-SECRET"), "Omission leaked error contents")
            }
        }
        print("\(count) diagnostic archive tests passed")
    }
}
