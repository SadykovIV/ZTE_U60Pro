import Foundation
import Darwin

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw IMEIError.message(message) }
}
private final class AgentStatusRemote: RemoteTransport {
    var commands = [String](), inputs = [Data]()
    var reads = 0, drift = "", response = "AGENT_SHA absent\n", exitCode: Int32 = 0
    var stderr = "", unknownFacts = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command == SSHReadProof.quickCommand {
            reads += 1
            let cid = drift == "cid" && reads > 1 ? String(repeating: "b", count: 32) : String(repeating: "a", count: 32)
            let boot = drift == "boot" && reads > 1 ? "22222222-2222-2222-2222-222222222222" : "11111111-1111-1111-1111-111111111111"
            let facts = unknownFacts ? "?\n?\n" : cid + "\n" + boot + "\n"
            return .init(status: 0, stdout: Data(("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n" + facts + "?\n?\n").utf8), stderr: Data())
        }
        try check(command == "unset ZTE_AGENT_TEST_ROOT; sh -s -- status" && input != nil, "Status attempted an unexpected remote operation")
        inputs.append(input!)
        return .init(status: exitCode, stdout: Data(response.utf8), stderr: Data(stderr.utf8))
    }
}

@main enum AgentReadonlyStatusTests {
    static func main() throws {
        let fm = FileManager.default, resources = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")
        let root = fm.temporaryDirectory.appendingPathComponent("zte-agent-status-" + UUID().uuidString)
        try secureDirectory(root); defer { try? fm.removeItem(at: root) }
        let key = root.appendingPathComponent("key"), hosts = root.appendingPathComponent("hosts")
        try savePrivate(Data("synthetic-key".utf8), key); try savePrivate(Data("synthetic-hosts".utf8), hosts)
        let connection = Connection(host: "192.0.2.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path)
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS " + name) }
            catch { failed += 1; print("FAIL " + name + ": " + error.localizedDescription) }
        }
        func manager(_ remote: AgentStatusRemote, assets: URL? = nil) throws -> AgentInstallationManager {
            try AgentInstallationManager(engine: ModemEngine(root: root.appendingPathComponent(UUID().uuidString), resources: assets ?? resources, connection: connection, transport: remote))
        }
        test("read-only status uses exactly quick proof stdin manager quick proof without operation locks") {
            let remote = AgentStatusRemote(), value = try manager(remote)
            let result = try value.inspect()
            try check(result.hash == "absent" && !result.running && !result.recoveryPending, "Absent status was misclassified")
            try check(remote.commands == [SSHReadProof.quickCommand, "unset ZTE_AGENT_TEST_ROOT; sh -s -- status", SSHReadProof.quickCommand], "Status created a stage, lock or unrelated identity probe")
            try check(remote.inputs == [Data(contentsOf: resources.appendingPathComponent("AgentInstallation/manager.sh"))], "Pinned manager bytes were not sent via stdin")
        }
        test("all local recovery journals allow status and remain unchanged") {
            let remote = AgentStatusRemote(), value = try manager(remote)
            let names = ["pending.json", "setup-pending.json", "adb-access-pending.json", "adb-toggle-pending.json", "component-cleanup-pending.json"]
            for name in names { try savePrivate(Data("synthetic-pending".utf8), value.engine.root.appendingPathComponent(name)) }
            _ = try value.inspect()
            for name in names { try check(Data(contentsOf: value.engine.root.appendingPathComponent(name)) == Data("synthetic-pending".utf8), "Status altered recovery intent") }
            try check(remote.commands.count == 3, "Pending status performed extra operations")
        }
        for fact in ["cid", "boot"] {
            test("changed " + fact + " refuses status") {
                let remote = AgentStatusRemote(); remote.drift = fact
                var refused = false
                do { _ = try manager(remote).inspect() } catch { refused = true }
                try check(refused && remote.commands.count == 3, "Changed device facts were accepted")
            }
        }
        test("missing attribution facts remain readable without granting recovery") {
            let remote = AgentStatusRemote(); remote.unknownFacts = true
            let result = try manager(remote).inspect()
            try check(result.hash == "absent" && result.backupHash == nil && remote.commands.count == 3, "Unknown facts were fabricated or blocked status")
        }
        test("unknown installer owner is a fixed warning while binary status remains visible") {
            let remote = AgentStatusRemote()
            remote.response = "AGENT_WARNING OWNER\nAGENT_SHA " + String(repeating: "a", count: 64) + "\nAGENT_RUNNING yes\nAGENT_PENDING yes\n"
            let result = try manager(remote).inspect()
            try check(result.warningCode == "OWNER" && result.recoveryPending && result.running, "Owner warning lost or authorized recovery")
        }
        test("unknown warning code is rejected") {
            let remote = AgentStatusRemote(); remote.response = "AGENT_SHA absent\nAGENT_WARNING PRIVATE_CANARY\n"
            var refused = false
            do { _ = try manager(remote).inspect() } catch { refused = true }
            try check(refused, "Unrecognized warning accepted")
        }
        for code: Int32 in [1, 255] {
            test("failed status " + String(code) + " rejects otherwise valid stdout without exposing stderr") {
                let remote = AgentStatusRemote(); remote.exitCode = code; remote.stderr = "PRIVATE_CANARY\n"
                var message = ""
                do { _ = try manager(remote).inspect() } catch { message = error.localizedDescription }
                try check(!message.isEmpty && !message.contains("PRIVATE_CANARY"), "Status failure leaked or accepted output")
            }
        }
        test("tampered bundled manager fails before the first remote call") {
            let remote = AgentStatusRemote(), assets = root.appendingPathComponent("bad-assets")
            try secureDirectory(assets.appendingPathComponent("AgentInstallation"))
            try savePrivate(Data("tampered".utf8), assets.appendingPathComponent("AgentInstallation/manager.sh"))
            var refused = false
            do { _ = try manager(remote, assets: assets).inspect() } catch { refused = true }
            try check(refused && remote.commands.isEmpty, "Unpinned manager reached SSH")
        }
        print("RESULT \(passed) passed; \(failed) failed; no device")
        if failed != 0 { exit(1) }
    }
}
