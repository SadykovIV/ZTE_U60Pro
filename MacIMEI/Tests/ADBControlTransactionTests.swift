import Foundation
private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private final class Transport: RemoteTransport {
    var calls: [String] = [], phase = "", enabled = true, wanted = false
    var absentStage = false, capabilityMissing = false
    var identityReads=0, changeOnIdentityRead=Int.max
    var lostDispatch = false, lostACK = false, lostResult = false, outcome = "committed", changed = false
    var applies = 0, acks = 0, cleans = 0, cancels = 0
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        var reply = ""
        if command == AccessIdentity.command {
            identityReads += 1
            reply = ModemEngine.firmwareHash+" /firmware/image/modem.b16\n"+ModemEngine.routerHash+" /usr/bin/diag-router\n0123456789abcdef0123456789abcdef\n"+(changed || identityReads >= changeOnIdentityRead ? "11111111-1111-1111-1111-111111111111" : "00000000-0000-0000-0000-000000000001")+"\n"
        } else if command == ADBControlManager.capabilityCommand {
            if capabilityMissing { return .init(status:127,stdout:Data(),stderr:Data()) }
            reply="ADB_CAPABILITY_READY\n"
        } else if command.contains("ADB_STAGE_ABSENT") {
            return .init(status:absentStage ? 0 : 71,stdout:Data((absentStage ? "ADB_STAGE_ABSENT\n" : "").utf8),stderr:Data())
        } else if command == ADBControlProtocol.command {
            reply = "ZTE_ADB_STATE_V1\nlinked=\(enabled ? 1 : 0)\nready=1\nbound=1\ndaemon=1\n"
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
        } else if command.contains("ADB_STAGE_REMOVED") { cleans += 1; reply="ADB_STAGE_REMOVED\n"
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
        let value:[String:Any] = ["schema":1,"token":"11111111-2222-3333-4444-555555555555","cid":"0123456789abcdef0123456789abcdef","boot":"00000000-0000-0000-0000-000000000001","firmware":ModemEngine.firmwareHash,"router":ModemEngine.routerHash,"enabled":false,"dispatched":dispatched]
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
            try check(f.transport.cancels==1&&f.transport.applies==0&&f.transport.cleans==1,"Unlaunched recovery")
        }
        try test("prepared but possibly dispatched remains pending") {
            let f=try Fixture();try f.pending(dispatched:true,phase:"prepared")
            _=try f.engine.locked{try f.manager.status()}
            try check(f.transport.cancels==0&&f.transport.cleans==0,"Unsafe cancel")
        }
        try test("deadline retains pending and does not resend apply") {
            let f=try Fixture();f.transport.lostResult=true
            try reject{_=try f.engine.locked{try f.manager.setEnabled(false)}}
            try check(f.transport.applies==1&&f.transport.acks==0&&f.transport.cleans==0&&f.clock.timeIntervalSince1970>=95,"Deadline/replay")
        }
        try test("changed boot prevents pending reconciliation before any action") {
            let f=try Fixture();try f.pending(phase:"committed");f.transport.changed=true
            try reject{_=try f.engine.locked{try f.manager.status()}}
            try check(f.transport.calls==[AccessIdentity.command],"Changed device acted on")
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
        print("\(n) transaction fixtures PASS; no modem access")
    }
}
