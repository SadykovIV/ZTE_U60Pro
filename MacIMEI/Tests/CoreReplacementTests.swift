import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.assertion(message) }
}
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "12345678-1234-1234-1234-123456789abc"
private final class Host: HostCommandRunner {
    var calls = 0
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls += 1
        guard executable.lastPathComponent == "ssh-keygen" else { throw Failure.assertion("Unexpected USB/bootstrap command") }
        if arguments.contains("-q"), let index = arguments.firstIndex(of: "-f") {
            try Data("synthetic private key".utf8).write(to: URL(fileURLWithPath: arguments[index+1]))
        }
        return CommandResult(status: 0, stdout: Data("ssh-ed25519 c3ludGhldGlj\n".utf8), stderr: Data())
    }
}
private final class Remote: RemoteTransport {
    var commands = [String](), uploads = [String:Data](), installs = 0, commits = 0, authentications = 0
    var agentSHA = "", currentSHA = "", currentBoot = boot, journal = "", state = "ready", lost = false, busy = false, settingsMissing = false, dead = false, unproven = false, wrongDevice = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        var text = ""
        if command == AccessIdentity.command {
            text = "absent  /firmware/image/modem.b16\nabsent  /usr/bin/diag-router\n\(wrongDevice ? String(repeating: "f", count: 32) : cid)\n\(currentBoot)\n"
        } else if command == SSHReadProof.command {
            text = "ZTE_SSH_READ_V1\n0\nLinux\naarch64\n\(cid)\n\(currentBoot)\nabsent\nabsent\n"
        } else if command.contains("'--preflight'") {
            if settingsMissing { settingsMissing = false; return CommandResult(status: 1, stdout: Data(), stderr: Data("INSTALL_ERROR AGENT_SETTINGS_REQUIRED\n".utf8)) }
            if busy { return CommandResult(status: 1, stdout: Data(), stderr: Data("INSTALL_ERROR CORE_RECOVERY_BUSY\nPRIVATE\n".utf8)) }
            text = "INSTALL_PREFLIGHT linux-arm64-access imei_config=unknown\n"
        } else if command.contains("INSTALL_STAGE_READY") { text = "INSTALL_STAGE_READY\n" }
        else if let input, command.contains("; sha256sum '") {
            let target = String(command.components(separatedBy: "; sha256sum '").last!.dropLast())
            uploads[target] = input
            text = digest(input) + "  " + target + "\n"
        } else if command.contains("ZTE_INSTALL_STATE_PROBE") { text = "INSTALL_STATE " + state + "\n" }
        else if command.contains("'--commit'") { commits += 1; text = "INSTALL_COMMITTED " + journal + "\n" }
        else if command.contains("/setup-agent.sh' ") {
            installs += 1; agentSHA = currentSHA; dead = false
            let stage = command.split(separator: "'").map(String.init).first { $0.hasPrefix("/data/zte-imei-studio/stage-") && $0.hasSuffix("setup-agent.sh") }!
            journal = stage.replacingOccurrences(of: "/stage-", with: "/installations/").replacingOccurrences(of: "/setup-agent.sh", with: "")
            if lost { lost = false; return CommandResult(status: 255, stdout: Data(), stderr: Data("PRIVATE lost reply".utf8)) }
            text = "INSTALL_READY " + journal + "\n"
        } else if command.contains("AGENT_ACCESS_ABSENT") {
            if unproven { return CommandResult(status:73,stdout:Data(),stderr:Data()) }
            text="AGENT_ACCESS_ABSENT "+agentSHA+"\n"
        } else if command.contains("AGENT_ACCESS_READY") {
            if dead { return CommandResult(status:72,stdout:Data(),stderr:Data()) }
            text = "AGENT_ACCESS_READY 123 456 " + agentSHA + " " + agentSHA + "\n" }
        else if command.contains("/api/auth/login") { authentications += 1; text = "{\"ok\":true,\"data\":{\"token\":\"synthetic\"}}" }
        else if command.contains("/.install-requested'") { }
        else { throw Failure.assertion("Unexpected SSH command") }
        return CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data())
    }
}

@main struct CoreReplacementTests {
    static func main() throws {
        var passed = 0
        for mode in ["prepare", "install", "lost", "dashboard", "old-pending", "foreign", "busy", "settings", "lost-missing", "bundle-ready", "bundle-complete", "reboot-complete", "old-prepared", "cleanup-reboot", "dead", "dead-unproven"] {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-replacement-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let assets = root.appendingPathComponent("resources"), onboard = assets.appendingPathComponent("Onboarding")
            try secureDirectory(onboard); try secureDirectory(root.appendingPathComponent("SSH"))
            var hashes = [String:String]()
            for name in ["adb", "zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] {
                let bytes = Data(("synthetic-" + name).utf8); hashes[name] = digest(bytes)
                try bytes.write(to: onboard.appendingPathComponent(name))
            }
            try saveJSON(hashes,onboard.appendingPathComponent("SHA256.json"))
            try secureDirectory(assets.appendingPathComponent("HostTools"))
            let timeout = Data("synthetic timeout".utf8)
            try timeout.write(to: assets.appendingPathComponent("HostTools/zte-timeout"))
            try saveJSON(["zte-timeout":digest(timeout)],assets.appendingPathComponent("HostTools/SHA256.json"))
            let key = root.appendingPathComponent("SSH/id_ed25519"), known = root.appendingPathComponent("SSH/known_hosts")
            try Data("synthetic key".utf8).write(to:key)
            try Data("[192.0.2.1]:2222 ssh-ed25519 synthetic\n".utf8).write(to:known)
            let connection = Connection(host:"192.0.2.1",port:"2222",keyPath:key.path,knownHostsPath:known.path)
            let host=Host(),remote=Remote(); remote.agentSHA=hashes["zte-agent"]!; remote.currentSHA=remote.agentSHA; remote.lost=["lost","lost-missing","bundle-ready"].contains(mode);remote.busy=mode=="busy";remote.settingsMissing=mode=="settings"
            let engine=try OnboardingEngine(root:root,resources:assets,connection:connection,runner:host,sshFactory:{_ in remote})
            var dashboards=0
            engine.replacementDashboard={_ in dashboards += 1; if ["dashboard","bundle-complete","reboot-complete","dead","dead-unproven"].contains(mode) && dashboards==1 {throw Failure.assertion("synthetic dashboard failure")} }
            var old: Data?
            if mode=="old-pending" || mode=="foreign" {
                old=try JSONSerialization.data(withJSONObject:["installRequested":true,"cid":mode=="foreign" ? String(repeating:"f",count:32):cid,"firmwareHash":"absent","routerHash":"absent","forceReinstall":false,"cleanComponents":false,"phase":"install-requested"])
                try savePrivate(old!,engine.pending)
            }
            if mode=="old-prepared" {
                let id=UUID().uuidString.lowercased()
                let plan=AccessSetupJournal(id:id,cid:cid,bootID:boot,firmwareHash:"absent",routerHash:"absent",installerProfile:"linux-arm64-access",directory:root.appendingPathComponent("SetupBackups/"+id).path,adbSerial:"synthetic")
                old=try JSONEncoder().encode(plan);try savePrivate(old!,engine.pending)
            }
            if mode=="cleanup-reboot" {
                let id=UUID().uuidString.lowercased(),directory=root.appendingPathComponent("ComponentBackups/"+id)
                try secureDirectory(directory)
                let plan=ComponentCleanupPlan(id:id,cid:cid,bootID:boot,firmwareHash:"absent",routerHash:"absent",connection:connection,setupReceipt:root.appendingPathComponent("SetupBackups/"+id+"/setup-result.json").path,backupDirectory:directory.path)
                try saveJSON(plan,ComponentCleanup.pendingURL(root))
                var complete=AccessSetupJournal(id:id,cid:cid,bootID:boot,firmwareHash:"absent",routerHash:"absent",installerProfile:"linux-arm64-access",directory:root.appendingPathComponent("SetupBackups/"+id).path,adbSerial:"synthetic")
                complete.phase="complete";complete.installRequested=true;complete.forceReinstall=true;complete.cleanComponents=true;complete.remoteStage=SetupRemotePaths.anchor+"/stage-"+id;complete.remoteJournal=SetupRemotePaths.anchor+"/installations/"+id
                let oldSetup=try JSONEncoder().encode(complete)
                try savePrivate(oldSetup,engine.pending)
                remote.currentBoot="22345678-1234-1234-1234-123456789abc"
            }
            let preserve=mode != "prepare"
            var failed=false
            do { _=try engine.replaceCore(webPassword:"",agentPassword:preserve ? "":"TEST_PASSWORD",preserveSettings:preserve,expectedIdentity:Identity(cid:cid,firmwareHash:"absent")) }
            catch { failed=true; if !["lost","dashboard","foreign","busy","settings","lost-missing","bundle-ready","bundle-complete","reboot-complete","dead","dead-unproven"].contains(mode) {throw error} }
            try check(failed == ["lost","dashboard","foreign","busy","settings","lost-missing","bundle-ready","bundle-complete","reboot-complete","dead","dead-unproven"].contains(mode),"Unexpected outcome: "+mode)
            if ["lost","dashboard","settings","lost-missing","bundle-ready","bundle-complete","reboot-complete","dead","dead-unproven"].contains(mode) {
                if mode=="lost-missing" { remote.state="MISSING" }
                if mode.hasPrefix("bundle-") {
                    var plan=try readJSON(CoreReplacementPlan.self,engine.replacementPending)
                    plan.agentSHA=String(repeating:"b",count:64);remote.agentSHA=plan.agentSHA
                    try saveJSON(plan,engine.replacementPending)
                }
                if mode=="dead" || mode=="dead-unproven" { remote.dead=true;remote.unproven=mode=="dead-unproven" }
                if mode=="reboot-complete" { remote.currentBoot="22345678-1234-1234-1234-123456789abc" }
                if mode=="settings" {
                    _=try engine.replaceCore(webPassword:"",agentPassword:"TEST_PASSWORD",preserveSettings:false,expectedIdentity:Identity(cid:cid,firmwareHash:"absent"))
                } else {
                    do { _=try engine.replaceCore(webPassword:"",agentPassword:"",preserveSettings:true,expectedIdentity:Identity(cid:cid,firmwareHash:"absent"));try check(mode != "dead-unproven","Unproven absence accepted") }
                    catch { if mode != "dead-unproven" { throw error } }
                }
                let expectedInstalls = (mode=="lost-missing" || mode.hasPrefix("bundle-") || mode=="dead") ? 2:1
                let expectedCommits = (mode.hasPrefix("bundle-") || mode=="dead") ? 2:1
                try check(remote.installs==expectedInstalls && remote.commits==expectedCommits,"Retry replayed installer/commit: "+mode)
            }
            if mode=="dead-unproven" {
                try check(remote.installs==1 && remote.commits==1 && FileManager.default.fileExists(atPath:engine.replacementPending.path),"Unproven absence replayed installation or lost complete journal")
            } else if mode=="foreign" || mode=="busy" {
                try check(remote.installs==0 && remote.uploads.isEmpty,"Refusal wrote staged payloads")
                if let old { try check(try Data(contentsOf:engine.pending)==old,"Old refused journal changed") }
            } else {
                try check(remote.installs==((mode=="lost-missing" || mode.hasPrefix("bundle-") || mode=="dead") ? 2:1) && remote.commits==((mode.hasPrefix("bundle-") || mode=="dead") ? 2:1) && !FileManager.default.fileExists(atPath:engine.replacementPending.path),"Replacement did not finish once")
                try check(remote.authentications == ((!preserve || mode=="settings") ? 1:0),"Preserved settings were read or authenticated on host")
                try check(remote.commands.allSatisfy{ !$0.contains("TEST_PASSWORD") && !$0.contains("clean-components.sh") && !$0.contains("--clean-reinstall") },"Secret or optional cleanup entered command")
                if mode=="cleanup-reboot" {
                    let folders=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("ComponentBackups"),includingPropertiesForKeys:nil)
                    let files=try FileManager.default.contentsOfDirectory(atPath:folders[0].path)
                    try check(!ComponentCleanup.hasPending(root:root) && files.contains("previous-setup-before-replacement.json") && files.contains(where:{$0.hasPrefix("cleanup-before-reset-")}),"Reboot cleanup intent and completed setup were not archived")
                }
                if let old {
                    let folders=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("CoreReplacementBackups"),includingPropertiesForKeys:nil)
                    try check(try Data(contentsOf:folders[0].appendingPathComponent("previous-setup.json"))==old && !FileManager.default.fileExists(atPath:engine.pending.path),"Old dispatched journal was changed or discarded")
                }
            }
            passed += 1; print("PASS replacement " + mode)
        }
        print("Core replacement tests: \(passed) passed; no device")
    }
}
