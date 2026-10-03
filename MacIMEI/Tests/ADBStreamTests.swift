import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func rejects(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw Failure.assertion("Expected rejection") }
private final class OnceRunner: HostCommandRunner {
    var calls = 0
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult { throw Failure.assertion("Unexpected short path") }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: ADBStreamInput?) throws -> CommandResult {
        calls += 1
        guard input != nil else { throw Failure.assertion("No stream") }
        throw CommandFailure(message: "fixed failure", partial: .init(status: -1, stdout: Data(), stderr: Data()))
    }
}
@main enum ADBStreamTests {
    static func main() throws {
        let template = URL(fileURLWithPath: "Resources/Onboarding/adb-stream.sh")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adb-stream-tests-" + UUID().uuidString)
        try secureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) { do { try body(); passed += 1; print("PASS " + name) } catch { failed += 1; print("FAIL \(name): \(error)") } }
        func plan(_ body: String) throws -> ADBShellPlan { try .make("#" + String(repeating: "p", count: 4096) + "\n" + body, templateURL: template) }
        func run(_ plan: ADBShellPlan, input: ADBStreamInput? = nil, timeout: Double = 3, limit: Int = 65536) throws -> ResearchCommandResult {
            try ADBStreamProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", plan.command], input: input ?? plan.input!, timeout: timeout, maxBytes: limit, cancellation: ResearchCancellation())
        }
        func decode(_ plan: ADBShellPlan, _ value: ResearchCommandResult) throws -> CommandResult {
            try check(value.outcome == "success", "Transport outcome " + value.outcome)
            return try plan.decode(.init(status: value.status, stdout: value.stdout, stderr: value.stderr), original: plan.input!.auditOriginal)
        }
        func changed(_ source: ADBStreamInput, _ bytes: Data) -> ADBStreamInput { .init(data: bytes, ready: source.ready, begin: source.begin, result: source.result, auditOriginal: source.auditOriginal) }
        test("threshold selected before dispatch and bounded UTF8 input") {
            let short = try ADBShellPlan.make("printf test", templateURL: root.appendingPathComponent("missing"))
            try check(short.input == nil, "Short command loaded template")
            let long = try plan("printf test")
            try check(long.input != nil && long.command.utf8.count < 4096, "Long command argv not bounded")
            try rejects { _ = try ADBShellPlan.make("a\0b", templateURL: template) }
            try rejects { _ = try ADBShellPlan.make(String(repeating: "я", count: 65537), templateURL: template) }
            let bad = root.appendingPathComponent("bad"); try savePrivate(Data("corrupt".utf8), bad)
            try rejects { _ = try ADBShellPlan.make(String(repeating: "p", count: 4096), templateURL: bad) }
        }
        test("exact octal packet lengths and terminal nonce") {
            let p = try plan("printf 'Привет'\n\n"), input = p.input!
            let lines = String(decoding: input.data, as: UTF8.self).split(separator: "\n")
            try check(lines.dropLast(2).allSatisfy { $0.utf8.count == 320 }, "Packet too long")
            try check(lines.last!.hasPrefix("__ZTE_END_") && lines.last!.hasSuffix("__"), "No end nonce")
            try check(input.ready != input.begin && input.begin != input.result, "Shared nonce")
            let value = try decode(p, run(p)); try check(value.status == 0 && value.stdout == Data("Привет".utf8), "UTF8 changed")
        }
        test("trailing newlines preserved before eval and payload CR stays raw") {
            let p = try plan("printf 'A\\r'\n\n\n")
            let value = try decode(p, run(p)); try check(value.stdout == Data([65,13]), "Trailing CR changed")
        }
        test("set-e and explicit exit retain remote code") {
            for body in ["set -e; false; printf SHOULD_NOT_RUN", "exit 7; printf SHOULD_NOT_RUN"] {
                let p = try plan(body), value = try decode(p, run(p))
                try check(value.status == (body.hasPrefix("exit") ? 7 : 1) && value.stdout.isEmpty, "Eval escaped outer wrapper")
            }
        }
        test("stdin consumer receives devnull, not protocol input") {
            let p = try plan("if IFS= read -r x; then printf BAD; else printf EMPTY; fi")
            try check(try decode(p, run(p)).stdout == Data("EMPTY".utf8), "Child consumed transfer")
        }
        test("last packet truncation and corruption never execute body") {
            let p = try plan("printf BODY_RAN"), input = p.input!
            var lines = String(decoding: input.data, as: UTF8.self).components(separatedBy: "\n")
            lines[lines.count - 3].removeLast()
            let truncated = changed(input, Data(lines.joined(separator: "\n").utf8))
            let value = try decode(p, run(p, input: truncated))
            try check(value.status == 70 && !String(decoding: value.stdout, as: UTF8.self).contains("BODY_RAN"), "Partial body executed")
            lines = String(decoding: input.data, as: UTF8.self).components(separatedBy: "\n")
            lines[lines.count - 3].replaceSubrange(lines[lines.count - 3].startIndex..<lines[lines.count - 3].index(lines[lines.count - 3].startIndex, offsetBy: 5), with: "\\0141")
            let corrupt = changed(input, Data(lines.joined(separator: "\n").utf8))
            let corrupted = try decode(p, run(p, input: corrupt))
            try check(corrupted.status == 70 && String(decoding: corrupted.stdout, as: UTF8.self).contains("BODY_HASH"), "Corruption not refused")
        }
        test("missing END and timed-out body are unknown without retry") {
            let p = try plan("printf BODY_RAN"), input = p.input!
            let lines = String(decoding: input.data, as: UTF8.self).components(separatedBy: "\n")
            let partial = changed(input, Data(lines.dropLast(2).joined(separator: "\n").utf8))
            let result = try run(p, input: partial, timeout: 0.2)
            try check(!String(decoding: result.stdout, as: UTF8.self).contains("BODY_RAN"), "Partial executed")
            if result.outcome == "success" { try check(try decode(p, result).status == 70, "Missing END claimed execution") }
            let slow = try plan("sleep 2; printf LATE"), slowResult = try run(slow, timeout: 0.15)
            try check(slowResult.outcome == "timeout", "No shared timeout")
            let fixture = OnceRunner(), adb = ADBClient(binary: template.deletingLastPathComponent().appendingPathComponent("adb"), runner: fixture)
            try rejects { _ = try adb.shell("synthetic", p.input!.auditOriginal) }
            try check(fixture.calls == 1, "Failure replayed")
        }
        test("no bytes before exact READY and READY duplication refuses") {
            let p = try plan("printf ok"), input = p.input!
            let gate = "if IFS= read -r x; then exit 8; fi"
            let result = try ADBStreamProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", gate], input: input, timeout: 0.15, maxBytes: 1024, cancellation: ResearchCancellation())
            try check(result.outcome == "timeout" && result.stdout.isEmpty, "Input released without READY")
            let duplicate = "printf '\\n" + input.ready + "\\n" + input.ready + "\\n'; sleep 1"
            let repeated = try ADBStreamProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", duplicate], input: input, timeout: 0.2, maxBytes: 1024, cancellation: ResearchCancellation())
            try check(repeated.outcome == "failed", "Repeated READY accepted")
        }
        test("BEGIN must be unique full line; LF CRLF CRCRLF preserve payload") {
            let p = try plan("true"), i = p.input!
            for eol in ["\n", "\r\n", "\r\r\n"] {
                let payload = Data([0,255,13])
                let raw = Data(("echo" + eol + i.begin + eol).utf8) + payload + Data((eol + i.result + "0" + eol).utf8)
                try check(try p.decode(.init(status: 0, stdout: raw, stderr: Data()), original: i.auditOriginal).stdout == payload, "Payload normalized")
                for bad in [i.begin + eol + i.begin + eol, i.begin + "\r\r\r\n", "x" + i.begin + eol] {
                    try rejects { _ = try p.decode(.init(status: 0, stdout: Data((bad + "\n" + i.result + "0\n").utf8), stderr: Data()), original: i.auditOriginal) }
                }
            }
        }
        test("bounded concurrent stdout stderr and cancellation") {
            let p = try plan("i=0; while test $i -lt 2000; do printf abcdefghijklmnopqrstuvwxyz; printf abcdefghijklmnopqrstuvwxyz >&2; i=$((i+1)); done")
            let result = try run(p, limit: 512)
            try check(result.outcome == "truncated" && result.stdout.count + result.stderr.count <= 512, "Capture unbounded")
            let token = ResearchCancellation(); token.cancel()
            let cancelled = try ADBStreamProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", p.command], input: p.input!, timeout: 1, maxBytes: 512, cancellation: token)
            try check(cancelled.outcome == "cancelled", "Cancellation ignored")
        }
        test("actual canonical PTY echo is concurrently drained and excluded") {
            let bridge = root.appendingPathComponent("synthetic_pty_bridge.py")
            let source = #"""
            import os, pty, select, sys
            pid, fd = pty.fork()
            if pid == 0:
                os.execl('/bin/sh', 'sh', '-c', sys.argv[1])
            os.set_blocking(fd, False)
            pending = bytearray()
            stdin = True
            while True:
                rr, ww, _ = select.select(([0] if stdin and len(pending)<32768 else [])+[fd], [fd] if pending else [], [], 0.1)
                if 0 in rr:
                    data = os.read(0, 4096)
                    if data: pending.extend(data)
                    else: stdin = False
                if fd in ww:
                    try:
                        n = os.write(fd, pending); del pending[:n]
                    except BlockingIOError: pass
                if fd in rr:
                    try: data = os.read(fd, 8192)
                    except OSError: break
                    if not data: break
                    os.write(1, data)
            os.close(fd)
            _, status = os.waitpid(pid, 0)
            sys.exit(os.waitstatus_to_exitcode(status))
            """#
            try savePrivate(Data(source.utf8), bridge)
            let body = "#" + String(repeating: "synthetic-secret-", count: 1600) + "\nprintf 'PTY_OK'"
            let p = try ADBShellPlan.make(body, templateURL: template)
            let value = try ADBStreamProcess.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: [bridge.path, p.command], input: p.input!, timeout: 8, maxBytes: 1024, cancellation: ResearchCancellation())
            try check(value.outcome == "success", "PTY outcome " + value.outcome + " local=" + String(value.status) + " stderr=" + String(decoding: value.stderr, as: UTF8.self))
            try check(try decode(p, value).stdout == Data("PTY_OK".utf8), "PTY stream failed or echo retained")
            try check(value.stdout.count < 200 && !String(decoding: value.stdout, as: UTF8.self).contains("synthetic-secret-"), "Echo retained")
        }
        test("pre-BEGIN stderr octal echo and partial canary never survive timeout") {
            let p = try plan("printf SYNTHETIC_PRIVATE_CANARY"), i = p.input!
            let echo = String(decoding: i.data.prefix(640), as: UTF8.self)
            let script = "printf '%s' " + shellQuote(echo + "SYNTHETIC_PRIVATE_CANARY") + " >&2; sleep 1"
            let value = try ADBStreamProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], input: i, timeout: 0.15, maxBytes: 1024, cancellation: ResearchCancellation())
            try check(value.outcome == "timeout" && value.stderr.isEmpty && value.stdout.isEmpty, "Pre-BEGIN stderr survived")
            let known = "printf '%s\\n' 'error: shell command too long' >&2; exit 1"
            let failure = try ADBStreamProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", known], input: i, timeout: 1, maxBytes: 1024, cancellation: ResearchCancellation())
            try check(failure.outcome == "failed" && failure.stderr == Data("error: shell command too long\n".utf8), "Known client error disappeared")
        }
        test("sensitive-operation fixed ADB error survives, arbitrary output does not") {
            let text = ActivityJournal.diagnosticOutput(Data("error: shell command too long\r\r\nprivate-value\nerror: shell command too long private-value\n".utf8), command: "cat profiles.json")
            try check(text.contains("error: shell command too long") && !text.contains("private-value"), "Known error allowlist leaked")
            try check(ADBClient.errorExcerpt(Data("error: shell command too long\n".utf8), command: "cat profiles.json").contains("shell command too long"), "UI lacks fixed error")
        }
        test("saved readable legacy trust stays selected without copying or registration") {
            let legacy = root.appendingPathComponent("Old.app/Contents/Resources/trusted_known_hosts")
            let managed = root.appendingPathComponent("SSH/known_hosts")
            try secureDirectory(legacy.deletingLastPathComponent()); try savePrivate(Data("synthetic trusted host".utf8), legacy)
            try check(Connection.restoredKnownHostsPath(legacy.path, fallback: managed.path) == legacy.path, "Readable explicit trust was remapped")
            try check(!FileManager.default.fileExists(atPath: managed.path), "Trust was silently copied")
            try check(Connection.restoredKnownHostsPath(managed.path, fallback: legacy.path) == managed.path, "Custom missing selection was replaced")
            try FileManager.default.removeItem(at: legacy)
            try check(Connection.restoredKnownHostsPath(legacy.path, fallback: managed.path) == managed.path, "Removed old app did not retain managed fallback")
        }
        test("stream audit never records original or octal body") {
            let p = try plan("# unlabelled-private-fixture-value\ncat profiles.json"), fixture = OnceRunner(), journal = try ActivityJournal(root: root.appendingPathComponent("audit"))
            let audited = AuditedHostRunner(base: fixture, journal: journal, operationID: "stream-secret")
            try rejects { _ = try audited.run(URL(fileURLWithPath: "/fixture/adb"), ["-s", "synthetic", "shell", p.command], timeout: 1, input: p.input) }
            for case let file as URL in FileManager.default.enumerator(at: journal.directory, includingPropertiesForKeys: nil)! where file.pathExtension == "json" || file.pathExtension == "jsonl" {
                let content = try String(contentsOf: file, encoding: .utf8)
                try check(!content.contains("unlabelled-private-fixture-value") && !content.contains(String(decoding: p.input!.data.prefix(320), as: UTF8.self)), "Body logged")
            }
            let events = journal.recent(); try check(events.contains { $0.details["transferMode"] == "stdin-octal-v1" && $0.details["inputBytes"] != nil && $0.details["inputSHA256"] != nil }, "Missing safe transfer metadata")
        }
        print("RESULT \(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
