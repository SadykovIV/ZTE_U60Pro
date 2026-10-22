import Foundation
private func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw IMEIError.message("TEST: " + text) } }
private final class IntegrationRemote: RemoteTransport {
    var firmware = ModemEngine.firmwareHash
    var commands = [String](), uploaded = [String: Data]()
    var present = false, ready = false, fail = false, lost = false, invalidReceipt = false, ignoreInstall = false
    var missing = "", switched = false, switchBeforeWrite = false, performed = false
    var helperHash = VPNSettingsManager.helperHash
    var statusRequests = 0, statusBeforeInstall = 0
    var rejectOldStatus = false, upgradeRefusal = ""
    var integrityChecks = 0
    var integrityReply: CommandResult?
    var identityCalls = 0
    let cid = String(repeating: "a", count: 32), boot = "11111111-2222-3333-4444-555555555555"
    func output(_ text: String = "", _ code: Int32 = 0) -> CommandResult { .init(status:code,stdout:Data(text.utf8),stderr:Data()) }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command.contains("mkdir /tmp/zte-imei-app.lock") || command.contains("&& rm /tmp/zte-imei-app.lock/owner") { return output() }
        if command == AccessIdentity.command {
            identityCalls += 1
            let different = switched && (performed || (switchBeforeWrite && !uploaded.isEmpty))
            return output(firmware + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + (different ? String(repeating:"b", count:32) : cid) + "\n" + boot)
        }
        if command.hasPrefix("for c in lua nft") {
            return output((present ? "VPN\nHELPER:" + helperHash + "\n" : "") + (ready ? "HELPER_LAYOUT_READY\n" : "") + missing)
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
            if !performed {
                statusBeforeInstall += 1
                if rejectOldStatus { return output("", 71) }
            }
            let marker = "| cut -d ' ' -f1)\" in "
            guard let start = command.range(of: marker),
                  let end = command.range(of: "; exec /data/zte-vpn/vpnctl request", range: start.upperBound..<command.endIndex) else {
                throw IMEIError.message("TEST: Missing helper hash guard")
            }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "case \"$1\" in " + String(command[start.upperBound..<end.lowerBound]), "--", helperHash]
            let errors = Pipe(); process.standardError = errors
            try process.run(); try? errors.fileHandleForWriting.close(); process.waitUntilExit()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 { return .init(status: process.terminationStatus, stdout: Data(), stderr: stderr) }
            statusRequests += 1
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
            if !upgradeRefusal.isEmpty { return .init(status: 1, stdout: Data(), stderr: Data(("VPN_UPGRADE_ERROR " + upgradeRefusal + "\nPRIVATE_CANARY\n").utf8)) }
            if !ignoreInstall { present = true; ready = true; helperHash = VPNSettingsManager.helperHash }
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
        func completeUpgrade(_ remote: IntegrationRemote) throws {
            let names = Set(remote.uploaded.keys.map { URL(fileURLWithPath: $0).lastPathComponent })
            let runtime = Set(["upgrade-controller.sh", "vpnctl", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft"])
            try check(names == runtime, "Upgrade omitted a required runtime component")
            for path in remote.uploaded.keys {
                let original = try Data(contentsOf: resources.appendingPathComponent("VPN/" + URL(fileURLWithPath: path).lastPathComponent))
                try check(remote.uploaded[path] == original, "Upgrade staged altered runtime bytes")
            }
        }
        for firmware in [ModemEngine.firmwareHash, "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478", "absent", "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81"] {
            let fresh=IntegrationRemote();fresh.firmware=firmware;try run(fresh);try isolated(fresh)
            try check(fresh.present && fresh.ready && fresh.uploaded.count==12,"Fresh standalone VPN installation failed")
            for name in ["ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft"] {
                let original = try Data(contentsOf: resources.appendingPathComponent("VPN/" + name))
                try check(fresh.uploaded.first { URL(fileURLWithPath: $0.key).lastPathComponent == name }?.value == original, "Fresh install omitted or altered IKEv2 runtime bytes")
            }
            let upgrade=IntegrationRemote();upgrade.firmware=firmware;upgrade.present=true
            upgrade.helperHash="b2c3fcfafeccd50fa3000ad5f8f66f1e42ff157b295cdda11dddd31571612af7"
            try run(upgrade);try isolated(upgrade)
            try check(upgrade.ready && upgrade.helperHash == VPNSettingsManager.helperHash,"Shipped 1.24.18 controller repair failed")
            try completeUpgrade(upgrade)
            try check(fresh.commands.contains(AccessIdentity.command) && upgrade.commands.contains(AccessIdentity.command), "VPN install skipped measured identity")
        }
        let released=IntegrationRemote();released.present=true
        released.helperHash="fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48"
        try run(released);try isolated(released)
        try check(released.ready && released.helperHash == VPNSettingsManager.helperHash && released.statusRequests == 1 && released.statusBeforeInstall == 0, "1.24.20 status blocked its explicit upgrade")
        try completeUpgrade(released)
        for oldHash in ["1c0e3e6d308a6c4b161faf896a00437b8e011fe5b7eff7969b9870c85d8d0c5c", "fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48"] {
            let old=IntegrationRemote();old.present=true;old.helperHash=oldHash;old.rejectOldStatus=true
            try run(old);try isolated(old)
            try check(old.performed && old.ready && old.statusRequests == 1 && old.statusBeforeInstall == 0,
                      "Old or faulty status executed before the trusted controller upgrade")
        }
        for code in ["CONTROLLER_UNKNOWN", "UNSAFE_LAYOUT"] {
            let unsafe=IntegrationRemote();unsafe.present=true;unsafe.helperHash=String(repeating:"f",count:64);unsafe.upgradeRefusal=code
            do { try run(unsafe); throw IMEIError.message("TEST: Unsafe controller upgrade accepted") }
            catch { try check(!error.localizedDescription.hasPrefix("TEST:") && error.localizedDescription.contains("VPN_UPGRADE_" + code) && !error.localizedDescription.contains("PRIVATE_CANARY"), "Upgrade refusal lost or private output leaked") }
            try check(unsafe.statusBeforeInstall == 0 && unsafe.statusRequests == 0 && !unsafe.ready && unsafe.helperHash == String(repeating:"f",count:64), "Refused upgrade executed unknown controller or changed the installed state")
        }
        let release12422 = "b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a"
        try check(release12422 != VPNSettingsManager.helperHash, "Previous and current fixture hashes must differ")
        for firmware in [ModemEngine.firmwareHash, "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478", "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81"] {
            let old = IntegrationRemote(); old.present = true; old.ready = true; old.firmware = firmware; old.helperHash = release12422
            let engine = try ModemEngine(root:base.appendingPathComponent(UUID().uuidString),resources:resources,connection:Connection(host:"192.0.2.1",port:"2222",keyPath:"/fixture/key",knownHostsPath:"/fixture/hosts"),transport:old)
            let inspected = try engine.locked { try VPNSettingsManager(engine:engine).inspect() }
            try check(inspected.status.installed && old.statusRequests == 1 && old.uploaded.isEmpty && !old.performed, "1.24.22 read-only status blocked or upgraded silently")
            try run(old); try isolated(old)
            try check(old.helperHash == VPNSettingsManager.helperHash && old.statusRequests == 2 && old.statusBeforeInstall == 1, "1.24.22 did not upgrade after successful status")
            try completeUpgrade(old)
        }
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
        print("PASS 33 independent VPN install scenarios including B31, B28, B04 absent/image and 1.24.20/1.24.22 upgrade: absent optional components, fresh install, repair, repeat with core integrity, damaged core, malformed integrity, status-only reads, failures, transport loss and identity changes; fake SSH only")
    }
}
