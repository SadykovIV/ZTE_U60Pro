import Foundation
private func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw IMEIError.message("TEST: " + text) } }
private final class IntegrationRemote: RemoteTransport {
    var commands = [String](), uploaded = [String: Data]()
    var preflightFails = false, invalidReceipt = false, lostAt = "", failedAt = "", installed = BundledAgent.sha256, vpnPresent = true
    var backupHash: String?
    var badFinalAgentState = "", chainFinished = false
    let cid = String(repeating:"a",count:32), boot = "11111111-2222-3333-4444-555555555555"
    func output(_ text: String = "", _ code: Int32 = 0) -> CommandResult { .init(status:code,stdout:Data(text.utf8),stderr:Data()) }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command.contains("mkdir /tmp/zte-imei-app.lock") || command.contains("&& rm /tmp/zte-imei-app.lock/owner") { return output() }
        if command.hasPrefix("if test -e /data/zte-vpn") { return output(vpnPresent ? "PRESENT" : "ABSENT") }
        if command.hasPrefix("test -d /data/zte-vpn") { return output() }
        if command.hasPrefix("for c in lua nft") { return output("AGENT:" + BundledAgent.sha256 + "\n") }
        if command.hasPrefix("test -d /data/zte-launcher") { return output() }
        if command == "sha256sum /data/zte-agent | awk '{print $1}'" { return output(installed) }
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") || command == AccessIdentity.command { return output(ModemEngine.firmwareHash + " /firmware/image/modem.b16\n" + ModemEngine.routerHash + " /usr/bin/diag-router\n" + cid + "\n" + boot) }
        if command.hasPrefix("umask 077; mkdir ") || command.hasPrefix("rm -f ") { return output() }
        if command.hasPrefix("umask 077; cat > "), let bytes = input {
            let path = command.components(separatedBy:"'")[1]; uploaded[path] = bytes
            return output(digest(bytes) + "  " + path)
        }
        if command.contains("/manager.sh' status") {
            let finalHash = chainFinished && badFinalAgentState == "hash" ? String(repeating:"0",count:64) : installed
            let running = chainFinished && badFinalAgentState == "stopped" ? "no" : "yes"
            let pending = chainFinished && badFinalAgentState == "pending" ? "AGENT_PENDING yes\n" : ""
            return output("AGENT_SHA " + finalHash + "\nAGENT_RUNNING " + running + "\nAGENT_STARTUP yes\n" + pending + (backupHash.map { "AGENT_BACKUP " + $0 + "\n" } ?? ""))
        }
        if command.contains("/manager.sh' install ") { backupHash=installed; installed=BundledAgent.sha256; return output("AGENT_INSTALLED " + installed + "\n") }
        if command.hasPrefix("sh '/tmp/zte-dashboard-stage-") {
            let path = command.components(separatedBy:"'")[1]
            let id = URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent.replacingOccurrences(of:"zte-dashboard-stage-",with:"")
            return output((command.hasSuffix(" preflight") ? "DASHBOARD_PREFLIGHT " : "DASHBOARD_INSTALLED ") + id)
        }
        if command.hasPrefix("sh '/tmp/zte-vpn-agent-") {
            let name = URL(fileURLWithPath:command.components(separatedBy:"'")[1]).lastPathComponent
            if command.hasSuffix(" preflight") { return output(invalidReceipt ? "WRONG" : "VPN_AGENT_PREFLIGHT_OK",preflightFails ? 1 : 0) }
            if name == lostAt { return output("",255) }
            if name == failedAt { return output("",1) }
            guard ["upgrade-controller.sh","update-agent.sh","install-launcher.sh"].contains(name) else { throw IMEIError.message("TEST: unexpected helper") }
            if name == "install-launcher.sh" { chainFinished = true }
            return output(name == "update-agent.sh" ? "VPN_AGENT_UPDATED" : "")
        }
        throw IMEIError.message("TEST: unexpected command")
    }
}
@main enum VPNIntegrationTests {
    static func main() throws {
        let fm = FileManager.default, resources = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Resources")
        let base = fm.temporaryDirectory.appendingPathComponent("vpn-integration-" + UUID().uuidString)
        try secureDirectory(base); defer { try? fm.removeItem(at:base) }
        func run(_ remote: IntegrationRemote, fresh: Bool = false, bundledAgent: Bool = false) throws {
            let engine = try ModemEngine(root:base.appendingPathComponent(UUID().uuidString),resources:resources,connection:Connection(host:"192.0.2.1",port:"2222",keyPath:"/fixture/key",knownHostsPath:"/fixture/hosts"),transport:remote)
            try engine.locked {
                try engine.acquireRemoteLock()
                if bundledAgent {
                    let candidate = try AgentCandidate.inspect(resources.appendingPathComponent("Onboarding/zte-agent"))
                    _ = try AgentInstallationManager(engine:engine).installBundled(candidate)
                } else if fresh { _ = try VPNSettingsManager(engine:engine).install() }
                else { _ = try VPNSettingsManager(engine:engine).updateDisplayIntegrationIfNeeded() }
            }
        }
        func reject(_ remote: IntegrationRemote, bundledAgent: Bool = false) throws { do { try run(remote, bundledAgent:bundledAgent) } catch { if error.localizedDescription.hasPrefix("TEST:") { throw error }; return }; throw IMEIError.message("TEST: expected refusal") }
        func helper(_ r: IntegrationRemote,_ n:String) -> Int? { r.commands.firstIndex { $0.hasPrefix("sh '") && $0.contains("/"+n+"'") && !$0.hasSuffix(" preflight") } }
        for badReceipt in [false,true] {
            let r=IntegrationRemote();r.preflightFails = !badReceipt;r.invalidReceipt=badReceipt;try reject(r)
            try check(!r.commands.contains { $0.contains("/manager.sh' status") } && helper(r,"upgrade-controller.sh") == nil,"Failed preflight followed by mutation")
        }
        let good=IntegrationRemote();try run(good)
        let preflight=good.commands.firstIndex { $0.hasSuffix(" preflight") }!, agent=good.commands.firstIndex { $0.contains("/manager.sh' status") }!
        try check(preflight < agent && agent < helper(good,"upgrade-controller.sh")! && helper(good,"upgrade-controller.sh")! < helper(good,"update-agent.sh")! && helper(good,"update-agent.sh")! < helper(good,"install-launcher.sh")!,"Wrong update ordering")
        for unknown in [false,true] {
            let r=IntegrationRemote();if unknown { r.lostAt="upgrade-controller.sh" } else { r.failedAt="update-agent.sh" };try reject(r)
            let cleanup=r.commands.contains { $0.hasPrefix("rm -f ") && $0.contains("zte-vpn-agent-") }
            try check(cleanup != unknown && helper(r,"install-launcher.sh") == nil,"Unknown process lost recovery tools or failed update continued")
        }
        let previous=IntegrationRemote(); previous.installed="e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19"; previous.preflightFails=true
        try reject(previous)
        try check(previous.commands.contains { $0.hasSuffix(" preflight") } && !previous.commands.contains { $0.contains("/manager.sh' status") } && helper(previous,"upgrade-controller.sh") == nil,"Frozen .8 did not reach preflight or bypassed failure")
        try check(BundledAgent.description(for: previous.installed).hasPrefix("2.7.0-esim.8"),"Frozen .8 version not recognized")
        let legacy=IntegrationRemote(); legacy.installed="e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19"; try run(legacy)
        let legacyPreflight=legacy.commands.firstIndex { $0.hasSuffix(" preflight") }!, legacyAgent=legacy.commands.firstIndex { $0.contains("/manager.sh' install ") }!
        try check(legacyPreflight < legacyAgent && legacyAgent < helper(legacy,"upgrade-controller.sh")! && legacy.backupHash == "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19" && legacy.installed == BundledAgent.sha256,"Frozen .8 bypassed preflight, backup or ordered update")
        let custom=IntegrationRemote();custom.installed=String(repeating:"0",count:64);try reject(custom);try check(custom.uploaded.isEmpty,"Unknown agent reached upload")
        let fresh=IntegrationRemote();fresh.preflightFails=true
        do { try run(fresh,fresh:true);throw IMEIError.message("TEST: fresh install accepted failed preflight") }
        catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
        try check(fresh.commands.contains { $0.hasSuffix(" preflight") } && !fresh.commands.contains { $0.hasPrefix("sh '") && $0.contains("/install.sh'") },"Initial VPN install preceded failed preflight")
        let bundled=IntegrationRemote();bundled.installed="e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19";try run(bundled,bundledAgent:true)
        try check(helper(bundled,"upgrade-controller.sh") != nil && helper(bundled,"install-launcher.sh") != nil && bundled.backupHash != nil,"Direct bundled-agent update left a mismatched VPN/display chain")
        try check(!bundled.commands.contains { $0.contains("/vpnctl request") },"Direct agent update configured or enabled VPN")
        let bundledRefused=IntegrationRemote();bundledRefused.preflightFails=true;try reject(bundledRefused,bundledAgent:true)
        try check(!bundledRefused.commands.contains { $0.contains("/manager.sh' install ") } && helper(bundledRefused,"upgrade-controller.sh") == nil,"Direct bundled-agent update bypassed preflight")
        let withoutVPN=IntegrationRemote();withoutVPN.vpnPresent=false;withoutVPN.installed="e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19";try run(withoutVPN,bundledAgent:true)
        try check(withoutVPN.installed==BundledAgent.sha256 && withoutVPN.commands.contains { $0.hasPrefix("sh '/tmp/zte-dashboard-stage-") && !$0.hasSuffix(" preflight") } && helper(withoutVPN,"upgrade-controller.sh")==nil && helper(withoutVPN,"install-launcher.sh")==nil,"Agent update without VPN installed unrelated components")
        for state in ["hash","stopped","pending"] {
            let badFinal=IntegrationRemote();badFinal.badFinalAgentState=state;try reject(badFinal,bundledAgent:true)
            try check(badFinal.chainFinished,"Final agent verification fixture failed before chain completion")
        }
        print("PASS 15 VPN integration scenarios: ordered updates, refusal/recovery, coherent bundled installation and final-state verification; fake SSH only")
    }
}
