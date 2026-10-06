import Foundation
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw IMEIError.message("TEST: " + message) }
}
private func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { if error.localizedDescription.hasPrefix("TEST:") { throw error }; return }
    throw IMEIError.message("TEST: Expected refusal")
}
private final class FakeRemote: RemoteTransport {
    let cid = String(repeating: "a", count: 32), boot = "11111111-2222-3333-4444-555555555555"
    var calls = [String](), uploaded = [String: Data](), identities = 0, dashboardCalls = 0, preflightCalls = 0, managerCalls = 0
    var failPreflight = false, oldAgent = false, agentSSHUnknown = false
    var changeAt = 0, badUpload = false, badReceipt = false, failDashboard = false, sshLost = false
    var firmware = ModemEngine.firmwareHash, router = ModemEngine.routerHash
    var firstAgentAbsent = false, allowInstall = false, installed = false, installs = 0
    func output(_ text: String = "", _ status: Int32 = 0) -> CommandResult {
        CommandResult(status: status, stdout: Data(text.utf8), stderr: Data())
    }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") || command == AccessIdentity.command {
            identities += 1
            return output(firmware + " /firmware/image/modem.b16\n" + router + " /usr/bin/diag-router\n" + (changeAt == identities ? String(repeating: "b", count: 32) : cid) + "\n" + boot)
        }
        if command.hasPrefix("if test -e /data/zte-vpn || test -L /data/zte-vpn;") { return output("ABSENT") }
        if command.contains("mkdir /tmp/zte-imei-app.lock") || command.contains("&& rm /tmp/zte-imei-app.lock/owner") { return output() }
        if command.hasPrefix("umask 077; mkdir ") || command.hasPrefix("rm -f ") { return output() }
        if command.hasPrefix("umask 077; cat > "), let bytes = input {
            let path = command.components(separatedBy: "'")[1]
            uploaded[path] = bytes
            let wrong = badUpload && path.contains("zte-dashboard-stage-")
            return output((wrong ? String(repeating: "0", count: 64) : digest(bytes)) + "  " + path)
        }
        if command.contains("/manager.sh' status") {
            managerCalls += 1
            if firstAgentAbsent {
                return output("AGENT_SHA " + (installed ? BundledAgent.sha256 : "absent") + "\nAGENT_STARTUP yes\n" + (installed ? "AGENT_RUNNING yes\n" : ""))
            }
            return output("AGENT_SHA " + (oldAgent ? String(repeating:"1",count:64) : BundledAgent.sha256) + "\nAGENT_RUNNING yes\nAGENT_STARTUP yes\nAGENT_BACKUP " + String(repeating:"2",count:64) + "\n")
        }
        if command.contains("/manager.sh' install "), allowInstall {
            installs += 1; installed = true
            return output("AGENT_INSTALLED " + BundledAgent.sha256 + "\n")
        }
        if command.contains("/manager.sh' install ") || command.contains("/manager.sh' restore") { return output("",agentSSHUnknown ? 255 : 1) }
        if command.hasPrefix("sh '/tmp/zte-dashboard-stage-") {
            try check(command.contains(cid) && command.contains(BundledAgent.sha256), "Dashboard command is not identity bound")
            let stage = command.components(separatedBy: "'")[3]
            try check(AgentDashboardPayload.names.allSatisfy { uploaded[stage + "/" + $0] != nil }, "Incomplete dashboard upload")
            let id = String(stage.dropFirst("/tmp/zte-dashboard-stage-".count))
            if command.hasSuffix(" preflight") {
                preflightCalls += 1
                return failPreflight ? output("", 1) : output("DASHBOARD_PREFLIGHT " + id + "\n")
            }
            dashboardCalls += 1
            if sshLost { return output("", 255) }
            if failDashboard { return output("", 1) }
            return output("DASHBOARD_INSTALLED " + (badReceipt ? "wrong" : id) + "\n")
        }
        throw IMEIError.message("TEST: Unexpected remote command: " + command)
    }
}
@main enum AgentDashboardTests {
    static func main() throws {
        let fm = FileManager.default, root = URL(fileURLWithPath: fm.currentDirectoryPath), resources = root.appendingPathComponent("Resources")
        let candidate = try AgentCandidate.inspect(resources.appendingPathComponent("Onboarding/zte-agent"))
        let base = fm.temporaryDirectory.appendingPathComponent("zte-dashboard-tests-" + UUID().uuidString)
        try secureDirectory(base); defer { try? fm.removeItem(at: base) }
        var count = 0
        func test(_ title: String, _ body: () throws -> Void) throws { try body(); count += 1; print("PASS " + title) }
        func run(_ remote: FakeRemote, resources override: URL? = nil, custom: Bool = false, skipFirmwareCheck: Bool = false) throws {
            let engine = try ModemEngine(root: base.appendingPathComponent(UUID().uuidString), resources: override ?? resources,
                connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/known_hosts", skipFirmwareCheck: skipFirmwareCheck), transport: remote)
            try engine.locked {
                let manager = AgentInstallationManager(engine: engine)
                _ = try custom ? manager.install(candidate) : manager.installBundled(candidate)
            }
        }
        try test("failed readonly dashboard preflight precedes agent installation") {
            let r = FakeRemote(); r.failPreflight = true
            try rejects { try run(r) }
            try check(r.preflightCalls == 1 && r.dashboardCalls == 0 && !r.calls.contains { $0.contains("/manager.sh' install ") }, "Agent replacement preceded failed preflight")
        }
        try test("current bundled agent still installs matching dashboard without VPN") {
            let r = FakeRemote(); try run(r)
            try check(r.dashboardCalls == 1 && r.preflightCalls == 1 && r.identities == 6, "Dashboard path or before/after guards missing")
            try check(!r.calls.contains { $0.contains("upgrade-controller.sh") || $0.contains(" install ") }, "Current agent unexpectedly replaced or VPN installer invoked")
            try check(r.calls.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-dashboard-stage-") }, "Temporary payload not cleaned")
        }
        try test("B28 agent first install and repeat refresh the dashboard without VPN or launcher") {
            let r = FakeRemote(); r.firmware = String(repeating: "3", count: 64); r.router = String(repeating: "4", count: 64)
            r.firstAgentAbsent = true; r.allowInstall = true
            try run(r, skipFirmwareCheck: true)
            try run(r, skipFirmwareCheck: true)
            try check(r.installs == 1 && r.installed && r.dashboardCalls == 2, "First or repeated B28 agent installation failed")
            try check(!r.calls.contains { $0.contains("upgrade-controller.sh") || $0.contains("install-launcher.sh") }, "Agent-only installation invoked display ABI or VPN update")
        }
        try test("custom agent path does not load or install a dashboard") {
            let r = FakeRemote(); try run(r, custom: true); try check(r.dashboardCalls == 0 && r.identities == 1, "Custom path installed bundled panel")
        }
        try test("corrupt dashboard rejected before any remote operation") {
            let copied = base.appendingPathComponent("bad-resources"); try secureDirectory(copied)
            try fm.copyItem(at: resources.appendingPathComponent("AgentDashboardInstall"), to: copied.appendingPathComponent("AgentDashboardInstall"))
            try Data("corrupt".utf8).write(to: copied.appendingPathComponent("AgentDashboardInstall/dashboard.tar.gz"))
            let r = FakeRemote(); try rejects { try run(r, resources: copied) }; try check(r.calls.isEmpty, "Mutation preceded local resource validation")
        }
        try test("upload hash mismatch stops before script and cleans own stage") {
            let r = FakeRemote(); r.badUpload = true; try rejects { try run(r) }
            try check(r.dashboardCalls == 0 && r.calls.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-dashboard-stage-") }, "Upload refusal cleanup")
        }
        try test("device change prevents dashboard execution") {
            let r = FakeRemote(); r.changeAt = 2; try rejects { try run(r) }; try check(r.dashboardCalls == 0, "Changed target executed")
        }
        try test("wrong receipt and helper failure cannot report completion") {
            for badReceipt in [true, false] {
                let r = FakeRemote(); r.badReceipt = badReceipt; r.failDashboard = !badReceipt
                try rejects { try run(r) }; try check(r.dashboardCalls == 1 && r.calls.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-dashboard-stage-") }, "Failure cleanup missing")
            }
        }
        try test("SSH loss retains staging tools for a possibly running rollback") {
            let r = FakeRemote(); r.sshLost = true; try rejects { try run(r) }
            try check(r.dashboardCalls == 1 && !r.calls.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-dashboard-stage-") }, "Unknown remote exit removed rollback tools")
        }
        try test("unknown common agent install or restore preserves its own stage") {
            let r = FakeRemote(); r.oldAgent = true; r.agentSSHUnknown = true
            try rejects { try run(r,custom:true) }
            try check(!r.calls.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-agent-stage-") },"Unknown install removed agent tools")
            let restore = FakeRemote(); restore.agentSSHUnknown = true
            let engine = try ModemEngine(root:base.appendingPathComponent(UUID().uuidString),resources:resources,
                connection:Connection(host:"192.0.2.1",port:"2222",keyPath:"/fixture/key",knownHostsPath:"/fixture/hosts"),transport:restore)
            try rejects { try engine.locked { _ = try AgentInstallationManager(engine:engine).restore() } }
            try check(!restore.calls.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-agent-stage-") },"Unknown restore removed agent tools")
        }
        print("\(count) dashboard tests passed; fake SSH only, no device operations")
    }
}
