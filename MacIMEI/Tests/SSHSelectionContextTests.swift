import Foundation

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws { if try !value() { throw Failure.assertion(text) } }
private func rejects(_ work: () throws -> Void) throws {
    do { try work() } catch let error as Failure { throw error } catch { return }
    throw Failure.assertion("Expected rejection before work")
}
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "00112233-4455-6677-8899-aabbccddeeff"
private let imei = "867123456789017"
private let identity = Identity(cid: cid, firmwareHash: ModemEngine.firmwareHash)
private final class Remote: RemoteTransport {
    var cidValue = cid, firmware = ModemEngine.firmwareHash, bootValue = boot, imeiValue = imei
    var calls = [String]()
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        try check(input == nil, "Target check sent input")
        let data: Data
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            data = Data((firmware + " /firmware/image/modem.b16\n" + ModemEngine.routerHash + " /usr/bin/diag-router\n" + cidValue + "\n" + bootValue + "\n").utf8)
        } else {
            try check(command == "ubus call zwrt_web device_info '{}'", "Target check issued a mutation")
            data = try JSONSerialization.data(withJSONObject:["imei":imeiValue,"integrate_version":"CN_ZTE_MU5250V1.0.0B31","wa_inner_version":"BD_CN_MU5250V1.0.0B31"])
        }
        return CommandResult(status:0,stdout:data,stderr:Data())
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine, remote = Remote()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-target-fixture-" + UUID().uuidString)
        engine = try ModemEngine(root:root,resources:root,connection:Connection(host:"192.0.2.1",port:"2222",keyPath:"/fixture/key",knownHostsPath:"/fixture/hosts"),transport:remote)
    }
    deinit { try? FileManager.default.removeItem(at:root) }
}
@main enum SSHSelectionContextTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ work: () throws -> Void) throws { try work(); passed += 1; print("PASS " + name) }
        try test("first explicit SSH read has no invented identity requirement") {
            let f = try Fixture()
            try SSHSelectionContext(identity:nil,imei:nil,session:nil).verify(f.engine)
            try check(f.remote.calls.isEmpty,"Unexpected preflight for unknown target")
        }
        try test("matching selected identity and IMEI permits work") {
            let f = try Fixture()
            try SSHSelectionContext(identity:identity,imei:imei,session:nil).verify(f.engine)
            try check(f.remote.calls.count == 2,"Identity or IMEI not checked")
        }
        try test("replaced CID or firmware rejects before work") {
            for firmware in [false,true] {
                let f = try Fixture(); var workRan = false
                if firmware { f.remote.firmware = String(repeating:"f",count:64) } else { f.remote.cidValue = String(repeating:"f",count:32) }
                try rejects { try SSHSelectionContext(identity:identity,imei:imei,session:nil).verify(f.engine); workRan = true }
                try check(!workRan && f.remote.calls.count == 1,"Work reached replaced modem")
            }
        }
        try test("cached boot change rejects before newly created engine is used") {
            let f = try Fixture()
            let proof = DiagnosticDeviceProof(identity:identity,routerHash:ModemEngine.routerHash,bootID:boot,webIdentity:nil)
            var changed = proof; changed.bootID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
            let shell = DiagnosticSession(transport:"ssh",reason:"fixture",proof:proof,readIdentity:{ changed }) { _,_ in throw Failure.assertion("Unexpected shell") }
            let summary = ConnectionDeviceSummary(identity:identity,bootID:boot)
            let selected = ReadOnlyChannelSession(mode:.ssh,summary:summary,diagnosticSession:shell) { summary }
            try rejects { try SSHSelectionContext(identity:identity,imei:imei,session:selected).verify(f.engine) }
            try check(f.remote.calls.isEmpty,"New engine used after stale session")
        }
        try test("a selected non-SSH session cannot authorize SSH management") {
            let f = try Fixture(), summary = ConnectionDeviceSummary(identity:identity)
            let selected = ReadOnlyChannelSession(mode:.adb,summary:summary) { summary }
            try rejects { try SSHSelectionContext(identity:identity,imei:imei,session:selected).verify(f.engine) }
            try check(f.remote.calls.isEmpty,"Silent manual-mode SSH fallback")
        }
        try test("agent-only IMEI expectation survives without a CID") {
            let f = try Fixture(); f.remote.imeiValue = "867123456789025"
            try rejects { try SSHSelectionContext(identity:nil,imei:imei,session:nil).verify(f.engine) }
            try check(f.remote.calls.count == 1,"Standalone IMEI was ignored")
        }
        try test("pending IMEI continuation binds CID while allowing its reboot") {
            let f = try Fixture(); f.remote.bootValue = "ffffffff-ffff-ffff-ffff-ffffffffffff"; f.remote.imeiValue = "867123456789025"
            try SSHSelectionContext(identity:identity,imei:nil,session:nil).verify(f.engine)
            try check(f.remote.calls.count == 1,"Pending continuation used stale IMEI")
        }
        print("RESULT \(passed) passed; 0 failed")
    }
}
