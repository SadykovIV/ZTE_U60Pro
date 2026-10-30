import Foundation
private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private final class Transport: RemoteTransport {
    var firmwareHash = ModemEngine.firmwareHash
    var routerHash = ModemEngine.routerHash
    var calls: [String] = [], phase = "", enabled = true, wanted = false
    var recoveryReply: String? = nil
    var lostCleanup = false
    var recoveryDenied = false, foreignLock = false, wrongCID = false
    var recoveries = 0, ordinaryLocks = 0
    var absentStage = false, capabilityMissing = false, descriptorsMissing = false, b04Measured = true
    var identityReads=0, changeOnIdentityRead=Int.max
    var lostDispatch = false, lostACK = false, lostResult = false, outcome = "committed", changed = false
    var applies = 0, acks = 0, cleans = 0, cancels = 0
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        var reply = ""
        if command.contains("if mkdir /tmp/zte-imei-app.lock") {
            ordinaryLocks += 1
        } else if command == AccessIdentity.command {
            identityReads += 1
            reply = firmwareHash+"  /firmware/image/modem.b16\n"+routerHash+" /usr/bin/diag-router\n"+(wrongCID ? "1123456789abcdef0123456789abcdef" : "0123456789abcdef0123456789abcdef")+"\n"+(changed || identityReads >= changeOnIdentityRead ? "11111111-1111-1111-1111-111111111111" : "00000000-0000-0000-0000-000000000001")+"\n"
        } else if command == ADBControlManager.capabilityCommand || command.contains(ADBControlManager.b04CapabilityCommand) || command.contains(ADBControlManager.b27CapabilityCommand) {
            if (command.contains(ADBControlManager.b04CapabilityCommand) || command.contains(ADBControlManager.b27CapabilityCommand)) && !b04Measured { return .init(status:71,stdout:Data(),stderr:Data()) }
            if capabilityMissing { return .init(status:127,stdout:Data(),stderr:Data()) }
            reply="ADB_CAPABILITY_READY\n"
        } else if command.contains("ADB_STAGE_ABSENT") {
            return .init(status:absentStage && !foreignLock ? 0 : 71,stdout:Data((absentStage ? "ADB_STAGE_ABSENT\n" : "").utf8),stderr:Data())
        } else if command == ADBControlProtocol.command {
            reply = "ZTE_ADB_STATE_V1\nlinked=\(enabled ? 1 : 0)\nready=\(descriptorsMissing ? "unknown" : "1")\nbound=1\ndaemon=\(descriptorsMissing ? "0" : "1")\n"
        } else if command.contains("'reconcile'") {
            recoveries += 1
            try check(input != nil && digest(input!) == ADBControlManager.scriptHash && command.contains("exec /bin/sh -s --") && command.contains(ADBControlManager.previousScriptHash), "Recovery must execute current pinned stdin")
            let receipt = recoveryReply ?? (["prepared", "preparing"].contains(phase) ? "cancelled" : phase == "rolled-back" ? "settled-before" : phase == "committed" ? "settled-after" : "busy")
            if absentStage || foreignLock || recoveryDenied || receipt == "busy" { return .init(status:71,stdout:Data(),stderr:Data()) }
            reply = "ADB_RECOVERED=" + receipt + "\n"
        } else if input != nil {
            try check(digest(input!) == ADBControlManager.scriptHash,"Bad upload")
        } else if command.contains(" prepare ") {
            wanted = command.hasSuffix("'1'"); phase = "prepared"; reply = "ADB_PREPARED\n"
        } else if command.contains("nohup /bin/sh") {
            applies += 1; enabled = wanted; phase = "awaiting-ack"; reply = "ADB_DISPATCHED\n"
            if outcome != "committed" { phase = outcome; if outcome == "rolled-back" { enabled = !wanted } }
            if lostDispatch { throw IMEIError.message("transport lost") }
        } else if command.contains(" ack ") {
            acks += 1; phase = "committed"; reply = "ADB_ACKNOWLEDGED\n"
            if lostACK { throw IMEIError.message("reply lost") }
        } else if command.contains(" result ") {
            if lostResult { throw IMEIError.message("not connected") }
            reply = "ADB_PHASE="+phase+"\n"
        } else if command.contains(" cancel ") {
            cancels += 1; phase="cancelled"; reply="ADB_CANCELLED\n"
        } else if command.contains("ADB_STAGE_REMOVED") { cleans += 1; if lostCleanup { throw IMEIError.message("lost cleanup reply") }; reply="ADB_STAGE_REMOVED\n"
        } else { throw Failure.assertion("Unexpected remote operation") }
        return .init(status:0,stdout:Data(reply.utf8),stderr:Data())
    }
}
private final class Fixture {
    let root:URL, resources:URL, engine:ModemEngine
    let transport=Transport()
    var clock=Date(timeIntervalSince1970:0)
    init() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("zte-adb-tx-"+UUID().uuidString)
        resources=root.appendingPathComponent("Resources")
        try secureDirectory(resources.appendingPathComponent("Onboarding"))
        let script=try Data(contentsOf:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Onboarding/adb-toggle.sh"))
        try savePrivate(script,resources.appendingPathComponent("Onboarding/adb-toggle.sh"))
        engine=try ModemEngine(root:root,resources:resources,connection:.init(host:"192.0.2.1",port:"2222",keyPath:"/unused",knownHostsPath:"/unused"),transport:transport)
    }
    deinit {try? FileManager.default.removeItem(at:root)}
    var manager:ADBControlManager { .init(engine:engine,now:{self.clock},wait:{self.clock.addTimeInterval($0)}) }
    func pending(dispatched:Bool=true,phase:String="awaiting-ack") throws {
        let value:[String:Any] = ["schema":1,"token":"11111111-2222-3333-4444-555555555555","cid":"0123456789abcdef0123456789abcdef","boot":"00000000-0000-0000-0000-000000000001","firmware":transport.firmwareHash,"router":transport.routerHash,"enabled":false,"dispatched":dispatched]
        try savePrivate(JSONSerialization.data(withJSONObject:value),manager.pendingURL);transport.phase=phase
    }
}
@main enum ADBControlTransactionTests {
    static func main() throws {
        var n=0
        func test(_ name:String,_ body:()throws->Void)throws {try body();n+=1;print("PASS "+name)}
        func reject(_ body:()throws->Void)throws {do{try body()}catch let e as Failure{throw e}catch{return};throw Failure.assertion("Expected refusal")}
        try test("lost dispatch and ACK replies never repeat mutation") {
            let f=try Fixture();f.transport.lostDispatch=true;f.transport.lostACK=true
            let result=try f.engine.locked{try f.manager.setEnabled(false)}
            try check(result.enabled==false && result.supportsChange && f.transport.applies==1 && f.transport.acks==1 && f.transport.cleans==1,"Bad lifecycle")
        }
        try test("measured B28 uses descriptor capability and the same rollback transaction") {
            let f=try Fixture();f.transport.firmwareHash=ADBControlManager.b28FirmwareHash
            let result=try f.engine.locked{try f.manager.setEnabled(false)}
            try check(result.enabled==false && result.supportsChange && f.transport.applies==1 && f.transport.acks==1,"B28 path")
        }
        try test("B27 measured native tuple uses the verified USB transaction") {
            let f=try Fixture();f.transport.firmwareHash=ADBControlManager.b27FirmwareHash;f.transport.routerHash=ADBControlManager.b27RouterHash
            let result=try f.engine.locked{try f.manager.setEnabled(false)}
            try check(result.enabled==false && result.supportsChange && f.transport.applies==1 && f.transport.acks==1,"B27 path")
            try check(f.transport.calls.contains { $0.contains(ADBControlManager.b27CapabilityCommand) },"B27 native proof missing")
        }
        for component in ["router", "mdm"] {
            try test("B27 rejects mixed native \(component) before staging") {
                let f=try Fixture();f.transport.firmwareHash=ADBControlManager.b27FirmwareHash
                f.transport.routerHash=component == "router" ? ModemEngine.routerHash : ADBControlManager.b27RouterHash
                f.transport.b04Measured=component != "mdm"
                try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
                try check(f.transport.applies==0 && f.transport.calls.allSatisfy{!$0.contains("mkdir -m 700")},"Mixed native B27 writes")
            }
        }
        for image in ["absent", ADBControlManager.b04FirmwareHash] {
        try test("B04 image state \(image) requires native capability before switching") {
            let f=try Fixture();f.transport.firmwareHash=image
            let result=try f.engine.locked{try f.manager.setEnabled(false)}
            try check(result.enabled==false && result.supportsChange && f.transport.applies==1,"B04 path")
            try check(f.transport.calls.contains { $0.contains(ADBControlManager.b04CapabilityCommand) }, "B04 native proof missing")
        }
        try test("B04 image state \(image) alone never permits ADB changes") {
            let f=try Fixture();f.transport.firmwareHash=image;f.transport.b04Measured=false
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==0 && f.transport.calls.allSatisfy{!$0.contains("mkdir -m 700")},"Unmeasured B04 writes")
        }
        }
        try test("already runtime-off still sends preparation to clear boot activation") {
            let f=try Fixture();f.transport.enabled=false
            _=try f.engine.locked{try f.manager.setEnabled(false)}
            try check(f.transport.applies==1 && f.transport.cleans==1,"Persistence skipped due to runtime state")
        }
        try test("runtime off without descriptors still permits persistence-only disable") {
            let f=try Fixture();f.transport.enabled=false;f.transport.descriptorsMissing=true
            let result=try f.engine.locked{try f.manager.setEnabled(false)}
            try check(result.enabled==false && !result.supportsChange && f.transport.applies==1,"Persistence-only unavailable")
        }
        try test("worker rollback cleans only after verified terminal receipt") {
            let f=try Fixture();f.transport.outcome="rolled-back"
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==1&&f.transport.acks==0&&f.transport.cleans==1 && !FileManager.default.fileExists(atPath:f.manager.pendingURL.path),"Rollback lifecycle")
        }
        try test("unknown rollback retains journal and stage and blocks retry") {
            let f=try Fixture();f.transport.outcome="rollback-unknown"
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.cleans==0&&FileManager.default.fileExists(atPath:f.manager.pendingURL.path),"Unknown discarded")
            let calls=f.transport.calls.count;try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.calls.count==calls&&f.transport.applies==1,"Mutation retried")
        }
        try test("restarted app reconciles rollback without ACK or apply") {
            let f=try Fixture();try f.pending(phase:"rolled-back")
            let result=try f.engine.locked{try f.manager.status()}
            try check(result.enabled==true&&f.transport.applies==0&&f.transport.acks==0&&f.transport.cleans==1,"Restart replay")
        }
        try test("restarted awaiting ACK waits for rollback without reauthorization") {
            let f=try Fixture();try f.pending()
            let result=try f.engine.locked{try f.manager.status()}
            try check(!result.supportsChange&&f.transport.applies==0&&f.transport.acks==0&&f.transport.cleans==0,"Unexpected ACK")
        }
        try test("prepared undispatched transaction cancels and cleans only") {
            let f=try Fixture();try f.pending(dispatched:false,phase:"prepared")
            _=try f.engine.locked{try f.manager.status()}
            try check(f.transport.recoveries==1&&f.transport.cancels==0&&f.transport.applies==0&&f.transport.cleans==1,"Unlaunched recovery")
        }
        try test("prepared dispatch is cancelled only by proof-bearing recovery") {
            let f=try Fixture();try f.pending(dispatched:true,phase:"prepared")
            _=try f.engine.locked{try f.manager.status()}
            try check(f.transport.recoveries==1&&f.transport.cancels==0&&f.transport.cleans==1,"Recovery failed")
        }
        try test("deadline retains pending and does not resend apply") {
            let f=try Fixture();f.transport.lostResult=true
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==1&&f.transport.acks==0&&f.transport.cleans==0&&f.clock.timeIntervalSince1970>=95,"Deadline/replay")
        }
        try test("changed boot prevents pending reconciliation before any action") {
            let f=try Fixture();try f.pending(phase:"committed");f.transport.changed=true
            try reject{_=try f.engine.locked{try f.manager.status()}}
            try check(f.transport.applies==0 && f.transport.recoveries==0 && f.transport.cleans==0,"Changed device acted on")
        }
        try test("corrupt resource cannot grant capability or dispatch") {
            let f=try Fixture();try savePrivate(Data("bad".utf8),f.resources.appendingPathComponent("Onboarding/adb-toggle.sh"))
            try check(try !f.manager.status().supportsChange,"Corrupt source granted")
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==0,"Corrupt source dispatched")
        }
        try test("nonempty owned stage directory refuses cleanup before deleting any file") {
            let f=try Fixture();try f.pending(phase:"rolled-back")
            _=try f.engine.locked{try f.manager.status()}
            guard let generated=f.transport.calls.first(where:{$0.contains("ADB_STAGE_REMOVED")}) else { throw Failure.assertion("Missing cleanup") }
            let remote="/tmp/zte-adb-toggle-11111111-2222-3333-4444-555555555555"
            let local=f.root.appendingPathComponent("stage")
            try FileManager.default.createDirectory(at:local.appendingPathComponent("decision"),withIntermediateDirectories:true)
            try Data("retain".utf8).write(to:local.appendingPathComponent("decision/unexpected"))
            try Data("script".utf8).write(to:local.appendingPathComponent("adb-toggle.sh"))
            let wrapper="stat() { case \"$2\" in '%u:%a') printf '0:700\\n';; '%u:%a:%h') printf '0:600:1\\n';; *) return 99;; esac; }; "
            let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/sh")
            process.arguments=["-c",wrapper+generated.replacingOccurrences(of:remote,with:local.path)]
            process.standardOutput=Pipe();process.standardError=Pipe();try process.run();process.waitUntilExit()
            try check(process.terminationStatus != 0,"Unknown child accepted")
            try check(FileManager.default.fileExists(atPath:local.appendingPathComponent("adb-toggle.sh").path),"Cleanup deleted script before checking unknown descendants")
            try check(FileManager.default.fileExists(atPath:local.appendingPathComponent("decision/unexpected").path),"Unknown child deleted")
        }
        try test("missing launch tools cannot create pending or stage") {
            let f=try Fixture();f.transport.capabilityMissing=true
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==0 && !FileManager.default.fileExists(atPath:f.manager.pendingURL.path),"Capability failed after staging")
            try check(!f.transport.calls.contains(where:{$0.contains("mkdir -m 700")}),"Stage created despite missing tools")
        }
        try test("proved absent undispatched stage and lock clears only local pending") {
            let f=try Fixture();try f.pending(dispatched:false);f.transport.absentStage=true
            let state=try f.engine.locked{try f.manager.status()}
            try check(state.supportsChange && !FileManager.default.fileExists(atPath:f.manager.pendingURL.path),"Absence did not reconcile")
            try check(f.transport.applies==0 && f.transport.cancels==0 && f.transport.cleans==0,"Absent recovery mutated remote")
        }
        try test("possibly dispatched absent stage never clears pending") {
            let f=try Fixture();try f.pending(dispatched:true);f.transport.absentStage=true;f.transport.lostResult=true
            let state=try f.engine.locked{try f.manager.status()}
            try check(!state.supportsChange && FileManager.default.fileExists(atPath:f.manager.pendingURL.path),"Unknown dispatch cleared")
        }
        try test("target drift between status and authorization never creates pending") {
            let f=try Fixture();f.transport.changeOnIdentityRead=3
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==0 && !FileManager.default.fileExists(atPath:f.manager.pendingURL.path),"Changed target became authorized")
            try check(!f.transport.calls.contains(where:{$0.contains("mkdir -m 700")}),"Changed target staged")
        }
        try test("verified terminal survives lost cleanup response") {
            let f = try Fixture(); f.transport.lostCleanup = true
            let state = try f.engine.locked { try f.manager.setEnabled(false) }
            try check(state.enabled == false && !FileManager.default.fileExists(atPath:f.manager.pendingURL.path), "Cleanup loss retained terminal pending")
            try check(f.transport.applies == 1 && f.transport.acks == 1, "Cleanup loss replayed mutation")
        }
        for scenario in ["before", "after", "busy", "foreign", "wrong-cid", "reboot", "reboot-foreign"] {
            try test("proof-based recovery " + scenario) {
                let f = try Fixture(); try f.pending(phase: "rollback-unknown")
                let bytes = try Data(contentsOf: f.manager.pendingURL)
                f.transport.recoveryReply = scenario == "after" ? "settled-after" : "settled-before"
                f.transport.enabled = scenario != "after"
                f.transport.recoveryDenied = scenario == "busy"
                f.transport.foreignLock = ["foreign", "reboot-foreign"].contains(scenario)
                f.transport.wrongCID = scenario == "wrong-cid"
                f.transport.changed = scenario.hasPrefix("reboot")
                f.transport.absentStage = scenario.hasPrefix("reboot")
                if ["wrong-cid", "reboot-foreign"].contains(scenario) {
                    try reject { _ = try f.engine.locked { try f.manager.status() } }
                } else { _ = try f.engine.locked { try f.manager.status() } }
                if ["busy", "foreign", "wrong-cid", "reboot-foreign"].contains(scenario) {
                    try check(try Data(contentsOf: f.manager.pendingURL) == bytes, "Pending changed without proof")
                } else {
                    let archived = f.root.appendingPathComponent("adb-toggle-recovered-11111111-2222-3333-4444-555555555555.json")
                    try check(try Data(contentsOf: archived) == bytes, "Exact intent not preserved")
                    try check(!FileManager.default.fileExists(atPath:f.manager.pendingURL.path), "Settled intent still pending")
                }
                try check(f.transport.applies == 0 && f.transport.acks == 0 && f.transport.cancels == 0, "Recovery replayed USB or ACK")
            }
        }
        for image in [ModemEngine.firmwareHash, ADBControlManager.b04FirmwareHash, "absent"] {
        for resolved in [true, false] {
            try test("ordinary operation gate reconciles only proven pending " + String(resolved)) {
                let f = try Fixture(); f.transport.firmwareHash = image; try f.pending(phase: "rollback-unknown")
                f.transport.recoveryReply = "settled-before"; f.transport.recoveryDenied = !resolved
                if resolved { try f.engine.locked { try f.engine.acquireRemoteLock() } }
                else { try reject { try f.engine.locked { try f.engine.acquireRemoteLock() } } }
                try check(FileManager.default.fileExists(atPath:f.manager.pendingURL.path) != resolved, "Gate did not retain unknown intent")
                try check(f.transport.recoveries == 1 && f.transport.applies == 0 && f.transport.acks == 0, "Gate replayed USB")
                try check(f.transport.ordinaryLocks == (resolved ? 1 : 0), "Ordinary remote lock acquired without recovery proof")
            }
        }
        }
        print("\(n) transaction fixtures PASS; no modem access")
    }
}
