import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func reject(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure.assertion("Expected refusal")
}
private let nonce = "__ZTE_RESULT_00112233445566778899AABBCCDDEEFF__"
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "00112233-4455-6677-8899-aabbccddeeff"
private let web = #"{"imei":"867123456789017","integrate_version":"CN_ZTE_MU5250V1.0.0B31","wa_inner_version":"BD_CNMU5250V1.0.0B31"}"#
private let identity = ModemEngine.firmwareHash + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + cid + "\n"
private func wire(_ text: String, _ eol: String) -> String { text.replacingOccurrences(of: "\n", with: eol) }
private final class Runner: HostCommandRunner {
    var output = "first\nsecond\n", eol = "\r\r\n", code = 0, local: Int32 = 0, calls = 0
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls += 1
        try check(arguments.count == 4 && arguments[0] == "-s" && arguments[2] == "shell", "Unexpected command")
        guard let marker = ADBClient.shellMarker(in: arguments[3]) else { throw Failure.assertion("Missing nonce") }
        return .init(status: local, stdout: Data(wire(output + "\n" + marker + String(code) + "\n", eol).utf8), stderr: Data())
    }
}
@main enum ADBLineEndingsTests {
    static func main() throws {
        var passed = 0, failed = 0
        func test(_ title: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS " + title) }
            catch { failed += 1; print("FAIL " + title + ": " + error.localizedDescription) }
        }
        func decode(_ raw: Data, local: Int32 = 0, marker: String = nonce) throws -> CommandResult {
            try ADBClient.decodeShellResult(.init(status: local, stdout: raw, stderr: Data("warning".utf8)), marker: marker)
        }
        for (name, eol) in [("LF", "\n"), ("CRLF", "\r\n"), ("CRCRLF", "\r\r\n")] {
            test(name + " framing preserves raw payload and canonical remote status") {
                let payload = Data([0, 255, 13, 13, 10, 65, 13])
                for code in [0, 1, 7, 255] {
                    let result = try decode(payload + Data((eol + nonce + String(code) + eol).utf8))
                    try check(result.status == Int32(code) && result.stdout == payload && result.stderr == Data("warning".utf8), "Raw bytes or status changed")
                }
            }
            test(name + " shell and onboarding identity text parse") {
                let runner = Runner(); runner.eol = eol
                let client = ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: runner)
                try check(try client.shell("synthetic-usb", "printf lines") == "first\nsecond", "Line endings leaked to text consumer")
                runner.output = identity + web
                let expected = try WebIdentity(JSONSerialization.jsonObject(with: Data(web.utf8)) as! [String: Any])
                try check(try client.identityDetails("synthetic-usb", expected: expected).identity.cid == cid, "Onboarding identity failed")
                runner.code = 1
                try reject { _ = try client.shell("synthetic-usb", "false") }
                try check(runner.calls == 3, "Unexpected replay")
            }
            test(name + " diagnostic identity and USB discovery") {
                let proof = try DiagnosticTransportSelector.parseIdentity(Data(wire(identity + boot + "\n" + web + "\n", eol).utf8), requireWeb: true)
                try check(proof.identity.cid == cid && proof.bootID == boot, "Diagnostic identity changed")
                let discovery = try ADBDiscovery.parse(Data(wire("List of devices attached\nSYNTHETIC device usb:1\n", eol).utf8))
                try check(discovery.readyUSBSerials == ["SYNTHETIC"], "Discovery failed")
            }
            test(name + " firmware facts and binding retain exact values") {
                let facts = FirmwareResearchCollector.facts(wire("FR_FACT architecture=aarch64\nFR_FACT root=1\n", eol))
                try check(facts == ["architecture": "aarch64", "root": "1"], "Fact values contain transport CR")
                try check(FirmwareResearchCollector.facts(wire("FR_FACT root=1\nFR_FACT root=0\n", eol)).isEmpty, "Duplicate fact became trusted")
                let fingerprint = String(repeating: "a", count: 64)
                let binding = FirmwareResearchCollector.binding(Data(wire("uid=0\narchitecture=aarch64\ncid=" + fingerprint + "\nboot=" + fingerprint + "\n", eol).utf8))
                try check(binding == ["uid": "0", "architecture": "aarch64", "cid": fingerprint, "boot": fingerprint], "Binding failed")
            }
            test(name + " diagnostic and audit text are normalized and sanitized") {
                let out = wire("safe line\npassword=synthetic-private-value\n\n__DIAGNOSTIC_RESULT__0\n", eol)
                let diagnostic = ModemInformationManager.decodeDiagnostic(.init(status: 0, stdout: Data(out.utf8), stderr: Data()))
                let text = String(decoding: diagnostic.body, as: UTF8.self)
                try check(diagnostic.status == 0 && !text.contains("\r") && !text.contains("synthetic-private-value"), "Diagnostic normalization/redaction failed")
                let journal = ActivityJournal.diagnosticOutput(Data(wire("INSTALL_ERROR MOUNT_LAYOUT\npassword=synthetic-private-value\n", eol).utf8), command: "setup-agent.sh --preflight")
                try check(journal.contains("INSTALL_ERROR MOUNT_LAYOUT") && !journal.contains("\r") && !journal.contains("synthetic-private-value"), "Safe installer error lost/leaked")
            }
        }
        test("nonzero local exit never trusts a valid remote footer") {
            for eol in ["\n", "\r\n", "\r\r\n"] { try reject { _ = try decode(Data((eol + nonce + "0" + eol).utf8), local: 1) } }
        }
        test("missing duplicate noncanonical truncated and mismatched nonce footers refuse") {
            let bad = ["payload", "\n" + nonce + "0\n" + nonce + "0\n", "\n" + nonce + "0\ntrailing", "\n" + nonce + "0", "\n" + nonce + "0\r", "\n" + nonce + "0\r\r\r\n", "x" + nonce + "0\n", "\n__ZTE_RESULT_FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF__0\n"]
            for text in bad { try reject { _ = try decode(Data(text.utf8)) } }
            for code in ["", "00", "01", "-1", "+0", "256", "999", "0 ", " 0", "0\r1"] {
                try reject { _ = try decode(Data(("\r\r\n" + nonce + code + "\r\r\n").utf8)) }
            }
            try reject { _ = try decode(Data(("\n" + nonce + "0\n").utf8), marker: "prefix" + nonce) }
        }
        test("text normalization preserves spaces, lone CR and unsupported CR runs") {
            try check(CommandText.normalize("  a\r\r\nb\r\nc\rd\n  ") == "  a\nb\nc\rd\n  ", "Text values were trimmed or lone CR changed")
            try check(CommandText.normalize("a\r\r\r\nb\r") == "a\r\r\r\nb\r", "Unsupported controls hidden")
        }
        test("normalized identity still rejects another modem") {
            let runner = Runner(); runner.output = identity + web.replacingOccurrences(of: "867123456789017", with: "353490068701230")
            let expected = try WebIdentity(JSONSerialization.jsonObject(with: Data(web.utf8)) as! [String: Any])
            try reject { _ = try ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: runner).identity("synthetic-usb", expected: expected) }
            try check(runner.calls == 1, "Identity failure replayed")
        }
        print("RESULT \(passed) passed; \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
