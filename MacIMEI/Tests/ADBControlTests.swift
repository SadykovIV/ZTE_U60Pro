import Foundation

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.assertion(message) }
}
private final class FakeSSH: RemoteTransport {
    var calls: [String] = [], reads = 0, changed = false, fail = false
    var reply = "ZTE_ADB_STATE_V1\nlinked=1\nready=1\nbound=1\ndaemon=1\n"
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        try check(input == nil, "Unexpected input")
        if command == AccessIdentity.command {
            reads += 1
            let boot = changed && reads > 1 ? "11111111-1111-1111-1111-111111111111" : "00000000-0000-0000-0000-000000000001"
            return .init(status: 0, stdout: Data("absent  /firmware/image/modem.b16\nabsent  /usr/bin/diag-router\n0123456789abcdef0123456789abcdef\n\(boot)\n".utf8), stderr: Data())
        }
        try check(command == ADBControlProtocol.command, "Unexpected operation")
        return .init(status: fail ? 71 : 0, stdout: Data(reply.utf8), stderr: Data("PRIVATE-STDERR-CANARY".utf8))
    }
}
@main enum ADBControlTests {
    static func main() throws {
        var passed = 0
        func test(_ title: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + title) }
        func wire(_ a: String = "1", _ b: String = "1", _ c: String = "1", _ d: String = "1") -> String { "ZTE_ADB_STATE_V1\nlinked=\(a)\nready=\(b)\nbound=\(c)\ndaemon=\(d)\n" }
        func parse(_ s: String) throws -> ADBControlStatus { try ADBControlProtocol.parse(Data(s.utf8)) }
        func reject(_ block: () throws -> Void) throws {
            do { try block() } catch let e as Failure { throw e } catch { return }
            throw Failure.assertion("Expected refusal")
        }
        try test("complete observations enable status only") { let s=try parse(wire()); try check(s.enabled == true && !s.supportsChange, "Incorrect grant") }
        try test("known missing function is off") { try check(try parse(wire("0","unknown","unknown","unknown")).enabled == false, "Incorrect off") }
        try test("no daemon and no descriptors is off") { try check(try parse(wire("1","0","1","0")).enabled == false,"Incorrect off") }
        for text in [wire("1","unknown"),wire("1","0","1","1"),wire("1","1","unknown"),wire("unknown"),wire("1","1","1","0")] {
            try test("incomplete/contradictory observations remain unknown") { try check(try parse(text).enabled == nil, "Fabricated state") }
        }
        for text in [wire()+"private=x\n",wire().replacingOccurrences(of:"ready=1",with:"linked=1"),wire("true"),String(wire().dropLast()),"\0"+wire(),String(repeating:"x",count:257)] {
            try test("strict schema refuses malformed") { try reject { _ = try parse(text) } }
        }
        for eol in ["\r\n","\r\r\n"] { try test("canonical CR framing handled") { try check(try parse(wire().replacingOccurrences(of:"\n",with:eol)).enabled == true,"Framing") } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-adb-control-"+UUID().uuidString)
        try secureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        func manager(_ fake: FakeSSH) throws -> ADBControlManager {
            .init(engine: try ModemEngine(root:root,resources:root,connection:.init(host:"192.0.2.1",port:"2222",keyPath:"/unused",knownHostsPath:"/unused"),transport:fake))
        }
        try test("unknown firmware read only with fresh binding") { let f=FakeSSH(); try check(try manager(f).status().enabled == true && f.reads == 2,"Binding missing") }
        try test("changed boot refuses observed state") { let f=FakeSSH(); f.changed=true; try reject { _ = try manager(f).status() } }
        try test("read failure exposes no raw error") {
            let f=FakeSSH(); f.fail=true
            do { _ = try manager(f).status(); throw Failure.assertion("Read failure accepted") }
            catch let e as Failure { throw e }
            catch { try check(!error.localizedDescription.contains("CANARY"),"Raw failure") }
        }
        for desired in [true,false] {
            try test("unsupported toggle emits no mutation") {
                let f=FakeSSH(); try reject { _ = try manager(f).setEnabled(desired) }
                try check(f.calls.allSatisfy { $0 == AccessIdentity.command || $0 == ADBControlProtocol.command },"Unexpected writes")
            }
        }
        try test("status contains no unsafe actuator") { try check(!ADBControlProtocol.command.contains("usb_op") && !ADBControlProtocol.command.contains("kill") && !ADBControlProtocol.command.contains("/etc/init.d"),"Unsafe status") }
        print("\(passed) tests PASS; no modem access")
    }
}
