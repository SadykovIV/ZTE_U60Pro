import Foundation

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw IMEIError.message("TEST: " + message) }
}
private func rejects(_ work: () throws -> Void) throws {
    do { try work() }
    catch { if error.localizedDescription.hasPrefix("TEST:") { throw error }; return }
    throw IMEIError.message("TEST: expected refusal")
}
private final class HostToolsRemote: RemoteTransport {
    var uploads = 0
    var corruptReceipt = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        guard let input else { throw IMEIError.message("TEST: unexpected command") }
        try check(command.contains("set -C") && command.contains("chmod 700") && command.contains(" = 0:700"), "Private staging safeguards")
        let path = command.components(separatedBy: "cat > '").last!.components(separatedBy: "'").first!
        try check(path.hasSuffix("/zte-timeout"), "Unexpected uploaded file")
        try check(digest(input) == ModemHostTools.timeoutHash, "Unpinned upload")
        uploads += 1
        let receipt = (corruptReceipt ? String(repeating: "0", count: 64) : digest(input)) + "  " + path + "\n"
        return .init(status: 0, stdout: Data(receipt.utf8), stderr: Data())
    }
}

@main struct ModemHostToolsTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zte-host-tools-test-" + UUID().uuidString)
        try secureDirectory(root)
        defer { try? fm.removeItem(at: root) }
        let resources = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")
        let remote = HostToolsRemote()
        let engine = try ModemEngine(root: root, resources: resources,
                                    connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/hosts"), transport: remote)
        let stage = "/tmp/zte-diag-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try rejects { try ModemHostTools.stageTimeout(engine: engine, stage: stage) }
        try check(remote.uploads == 0, "Unlocked invocation transmitted bytes")
        print("PASS Unlocked staging refused before transport")
        try engine.locked {
            for path in ["/data/zte-diag-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "/tmp/zte-diag-../escape", stage + "/child", stage.uppercased()] {
                try rejects { try ModemHostTools.stageTimeout(engine: engine, stage: path) }
            }
        }
        try check(remote.uploads == 0, "Invalid stage transmitted bytes")
        print("PASS Non-private and malformed staging paths refused")
        try engine.locked { try ModemHostTools.stageTimeout(engine: engine, stage: stage) }
        try engine.locked { try ModemHostTools.stageTimeout(engine: engine, stage: stage.replacingOccurrences(of: "zte-diag", with: "zte-opkg")) }
        try check(remote.uploads == 2, "Both installers stage their supervisor")
        print("PASS Both installer namespaces upload pinned bytes with private mode")
        remote.corruptReceipt = true
        try rejects { try engine.locked { try ModemHostTools.stageTimeout(engine: engine, stage: stage) } }
        print("PASS Corrupt upload acknowledgement refused")
        let altered = root.appendingPathComponent("resources")
        try secureDirectory(altered.appendingPathComponent("HostTools"))
        try Data("corrupted".utf8).write(to: altered.appendingPathComponent("HostTools/zte-timeout"))
        let broken = try ModemEngine(root: root, resources: altered, connection: engine.connection, transport: remote)
        let before = remote.uploads
        try rejects { try broken.locked { try ModemHostTools.stageTimeout(engine: broken, stage: stage) } }
        try check(before == remote.uploads, "Corrupt local helper was transmitted")
        print("PASS Corrupt local binary refused before transport")
        print("ModemHostToolsTests: 5 PASS")
    }
}
