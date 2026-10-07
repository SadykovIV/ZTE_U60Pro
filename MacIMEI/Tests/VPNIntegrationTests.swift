import Foundation
private func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw IMEIError.message("TEST: " + text) } }
private final class IntegrationRemote: RemoteTransport {
    var commands = [String](), uploaded = [String: Data]()
    var present = false, ready = false, fail = false, lost = false, invalidReceipt = false, ignoreInstall = false
    var missing = "", switched = false, switchBeforeWrite = false, performed = false
    var integrityChecks = 0
    var integrityReply: CommandResult?
    var identityCalls = 0
    let cid = String(repeating: "a", count: 32), boot = "11111111-2222-3333-4444-555555555555"
    func output(_ text: String = "", _ code: Int32 = 0) -> CommandResult { .init(status:code,stdout:Data(text.utf8),stderr:Data()) }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command.contains("mkdir /tmp/zte-imei-app.lock") || command.contains("&& rm /tmp/zte-imei-app.lock/owner") { return output() }
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            identityCalls += 1
            let different = switched && (performed || (switchBeforeWrite && !uploaded.isEmpty))
            return output(ModemEngine.firmwareHash + " /firmware/image/modem.b16\n" + ModemEngine.routerHash + " /usr/bin/diag-router\n" + (different ? String(repeating:"b", count:32) : cid) + "\n" + boot)
        }
        if command.hasPrefix("for c in lua nft") {
            return output((present ? "VPN\nHELPER:" + VPNSettingsManager.helperHash + "\n" : "") + (ready ? "HELPER_LAYOUT_READY\n" : "") + missing)
        }
        if command.hasPrefix("umask 077; mkdir ") || command.hasPrefix("rm -f ") { return output() }
        if command.hasPrefix("umask 077; cat > "), let bytes = input {
            let path = command.components(separatedBy:"'")[1]; uploaded[path] = bytes
            return output(digest(bytes) + "  " + path)
        }
        if command.hasSuffix("exec /data/zte-vpn/vpnctl integrity") {
            integrityChecks += 1
            try check(command.contains(VPNSettingsManager.helperHash), "Integrity check executed an unpinned controller")
            return integrityReply ?? output("{\"ok\":true,\"data\":{\"verified\":true}}")
        }
        if command.contains("exec /data/zte-vpn/vpnctl request") {
            let request = try JSONSerialization.jsonObject(with: input!) as! [String:Any]
            try check(request["action"] as? String == "status", "Installer changed a profile or enabled VPN")
            let data: [String:Any] = ["schema_version":1,"installed":true,"version":"fixture","core_version":"fixture","core_available":true,"configured":false,"enabled":false,"core_running":false,"network_ok":false,"mesh_conflict":false,"ssid":"","profiles":[],"active_profile":"","recovery_pending":false]
            return output(String(decoding:try JSONSerialization.data(withJSONObject:["ok":true,"data":data]),as:UTF8.self))
        }
        if command.contains("; sh '/tmp/zte-vpn-") {
            try check(command.contains(cid) && command.contains(boot), "Installer lost selected device guard")
            let fresh = command.contains("/install.sh'")
            try check(fresh || command.contains("/upgrade-controller.sh'"), "Unexpected installer")
            performed = true
            if lost { return output("",255) }
            if fail { return output("",1) }
            if !ignoreInstall { present = true; ready = true }
            return output(invalidReceipt ? "INVALID" : fresh ? "VPN_COMPONENTS_INSTALLED\n" : "VPN_CONTROLLER_UPDATED\n")
        }
        throw IMEIError.message("TEST: Unexpected SSH command: " + command)
    }
}
@main enum VPNIntegrationTests {
    static func main() throws {
        let fm = FileManager.default, resources = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Resources")
        let base = fm.temporaryDirectory.appendingPathComponent("vpn-independent-install-" + UUID().uuidString)
        try secureDirectory(base); defer { try? fm.removeItem(at:base) }
        func run(_ remote: IntegrationRemote) throws {
            let engine = try ModemEngine(root:base.appendingPathComponent(UUID().uuidString),resources:resources,connection:Connection(host:"192.0.2.1",port:"2222",keyPath:"/fixture/key",knownHostsPath:"/fixture/hosts"),transport:remote)
            try engine.locked { _ = try VPNSettingsManager(engine:engine).install() }
        }
        func reject(_ remote: IntegrationRemote) throws {
            do { try run(remote) } catch { if error.localizedDescription.hasPrefix("TEST:") { throw error }; return }
            throw IMEIError.message("TEST: Expected refusal")
        }
        func isolated(_ remote: IntegrationRemote) throws {
            try check(!remote.commands.contains { $0.contains("/data/zte-agent") || $0.contains("/data/zte-launcher") || $0.contains("/data/zte-dashboard") }, "VPN installation accessed an optional component")
            try check(remote.uploaded.keys.allSatisfy { !["zte-agent","launcher.so","dashboard.tar.gz","update-agent.sh","install-launcher.sh"].contains(URL(fileURLWithPath:$0).lastPathComponent) }, "VPN uploaded optional components")
        }
        let fresh=IntegrationRemote();try run(fresh);try isolated(fresh)
        try check(fresh.present && fresh.ready && fresh.uploaded.count==9,"Fresh standalone VPN installation failed")
        let upgrade=IntegrationRemote();upgrade.present=true;try run(upgrade);try isolated(upgrade)
        try check(upgrade.ready && upgrade.uploaded.count==4,"Controller-only repair failed")
        let ready=IntegrationRemote();ready.present=true;ready.ready=true;try run(ready);try isolated(ready)
        try check(ready.uploaded.isEmpty && !ready.performed && ready.integrityChecks == 1,"Current installation was reinstalled or its core integrity was not verified")
        let damaged=IntegrationRemote();damaged.present=true;damaged.ready=true
        damaged.integrityReply=damaged.output("{\"ok\":false,\"code\":\"VPN_CORE_INTEGRITY\",\"detail\":\"PRIVATE_CANARY\"}",1)
        do { try run(damaged); throw IMEIError.message("TEST: Damaged core reported successful install") }
        catch {
            try check(!error.localizedDescription.hasPrefix("TEST:") && error.localizedDescription.contains("VPN_CORE_INTEGRITY") && !error.localizedDescription.contains("PRIVATE_CANARY"), "Core error was lost or private payload leaked")
        }
        try check(damaged.integrityChecks == 1 && damaged.uploaded.isEmpty && !damaged.performed,"Damaged core caused an unrelated reinstall")
        for response in [ready.output("{\"ok\":true,\"data\":{\"verified\":false}}"),ready.output("PRIVATE_CANARY"),ready.output("{\"ok\":true,\"data\":{\"verified\":true}}",255)] {
            let unconfirmed=IntegrationRemote();unconfirmed.present=true;unconfirmed.ready=true;unconfirmed.integrityReply=response
            try reject(unconfirmed)
            try check(unconfirmed.integrityChecks == 1 && !unconfirmed.performed,"Invalid integrity result was retried or caused writes")
        }
        let statusOnly=IntegrationRemote();statusOnly.present=true;statusOnly.ready=true
        let statusEngine=try ModemEngine(root:base.appendingPathComponent(UUID().uuidString),resources:resources,connection:Connection(host:"192.0.2.1",port:"2222",keyPath:"/fixture/key",knownHostsPath:"/fixture/hosts"),transport:statusOnly)
        _ = try VPNSettingsManager(engine:statusEngine).inspect()
        try check(statusOnly.integrityChecks == 0,"Ordinary status refresh added a core integrity check")
        let missing=IntegrationRemote();missing.missing="MISSING:TUN\n";try reject(missing)
        try check(missing.uploaded.isEmpty && !missing.performed,"Missing VPN prerequisite caused writes")
        for existing in [false,true] {
            for outcome in ["failure","lost","receipt","unconfirmed"] {
                let remote=IntegrationRemote();remote.present=existing
                remote.fail=outcome=="failure";remote.lost=outcome=="lost";remote.invalidReceipt=outcome=="receipt";remote.ignoreInstall=outcome=="unconfirmed"
                try reject(remote);try isolated(remote)
                let cleaned=remote.commands.contains { $0.hasPrefix("rm -f ") }
                try check(cleaned != remote.lost,"Unknown transport outcome lost recovery stage")
            }
        }
        let changed=IntegrationRemote();changed.switched=true;changed.switchBeforeWrite=true;try reject(changed)
        try check(!changed.performed,"Device changed before installation but writes continued")
        let changedAfter=IntegrationRemote();changedAfter.switched=true;try reject(changedAfter)
        try check(changedAfter.performed,"Final identity fixture did not exercise post-install check")
        print("PASS 19 independent VPN install scenarios: absent optional components, fresh install, repair, repeat with core integrity, damaged core, malformed integrity, status-only reads, failures, transport loss and identity changes; fake SSH only")
    }
}
