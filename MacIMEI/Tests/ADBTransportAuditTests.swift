import Foundation

private final class AuditRunnerFixture: HostCommandRunner {
    var local: Int32 = 0
    var remote: Int32 = 0
    var malformed = false
    var output = "directory ready\n"
    var eol = "\n"
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let marker = ADBClient.shellMarker(in: arguments.last ?? "")!
        return CommandResult(status: local,
            stdout: Data((output + (malformed ? "" : "\n" + marker + String(remote) + "\n")).replacingOccurrences(of: "\n", with: eol).utf8),
            stderr: Data())
    }
}

@main struct ADBTransportAuditTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-adb-audit-" + UUID().uuidString)
        try secureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ActivityJournal(root: root), fixture = AuditRunnerFixture()
        func run(_ name: String) throws -> ActivityEvent {
            let runner = AuditedHostRunner(base: fixture, journal: journal, operationID: name)
            let client = ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: runner)
            _ = try? client.shell("fixture-usb", "mkdir /data/local/tmp/test")
            guard let event = journal.recent().first(where: { $0.operationID == name && $0.result != "started" }) else {
                throw IMEIError.message("Missing audit event")
            }
            return event
        }
        fixture.remote = 1
        fixture.output = "mkdir: can't create directory '/data/local/tmp/test': No such file or directory\npassword=private-fixture-value\n"
        let failed = try run("remote-failed")
        try require(failed.result == "failed" && failed.details["localExitCode"] == "0" && failed.details["remoteExitCode"] == "1", "Remote failure was reported as local success")
        try require(failed.details["remoteError"]?.contains("No such file or directory") == true, "Missing actual directory error")
        try require(!failed.details.description.contains("private-fixture-value"), "Secret leaked into audit")
        print("PASS local ADB success and remote failure have distinct statuses and sanitized cause")

        fixture.remote = 0; fixture.output = "ok\n"
        let success = try run("remote-completed")
        try require(success.result == "completed" && success.details["remoteExitCode"] == "0", "Remote success not confirmed")
        print("PASS confirmed remote success is completed")

        fixture.eol = "\r\r\n"
        let legacySuccess = try run("crcrlf-completed")
        try require(legacySuccess.result == "completed" && legacySuccess.details["localExitCode"] == "0" && legacySuccess.details["remoteExitCode"] == "0", "CRCRLF remote success stayed unconfirmed")
        print("PASS CRCRLF audit confirms local and remote success separately")
        fixture.remote = 1; fixture.output = "mkdir: No such file or directory\npassword=private-fixture-value\n"
        let legacyFailure = try run("crcrlf-failed")
        try require(legacyFailure.result == "failed" && legacyFailure.details["remoteExitCode"] == "1" && legacyFailure.details["remoteError"]?.contains("No such file") == true && !legacyFailure.details.description.contains("private-fixture-value"), "CRCRLF failure lost or exposed cause")
        print("PASS CRCRLF audit preserves a rejected command and redacts its cause")
        fixture.eol = "\n"; fixture.remote = 0
        fixture.malformed = true
        let missing = try run("missing-footer")
        try require(missing.result == "failed" && missing.details["localExitCode"] == "0" && missing.details["remoteExitCode"] == nil && missing.details["remoteStatus"] == "unconfirmed", "Missing footer was reported successful")
        print("PASS missing remote footer cannot become completed")

        fixture.malformed = false; fixture.local = 1
        let local = try run("local-failed")
        try require(local.result == "failed" && local.details["localExitCode"] == "1" && local.details["remoteExitCode"] == nil, "Local failure was mistaken for a remote result")
        print("PASS local transport failure never trusts remote footer")

        let traces = root.appendingPathComponent("Activity/Traces")
        let enumerator = FileManager.default.enumerator(at: traces, includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            try require(!text.contains("private-fixture-value"), "Secret leaked into trace")
        }
        print("PASS detailed traces omit secret fixture values")
        let preflight = ActivityJournal.diagnosticOutput(Data("INSTALL_ERROR MOUNT_LAYOUT\npassword=private-fixture-value\nINSTALL_ERROR secret-with-spaces private-fixture-value\n".utf8), command: "sh -c 'start_zte_agent.sh' -- --preflight")
        try require(preflight.contains("INSTALL_ERROR MOUNT_LAYOUT") && !preflight.contains("private-fixture-value"), "Inline preflight either hid the error or disclosed unrelated output")
        print("PASS inline preflight retains fixed installer errors without credential output")
        print("RESULT 8 passed; 0 failed")
    }
}
