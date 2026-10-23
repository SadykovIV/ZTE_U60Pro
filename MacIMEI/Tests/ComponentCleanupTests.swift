import Foundation
import Darwin
private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func rejects(_ body: () throws -> Void) throws { do { try body() } catch let e as Failure { throw e } catch { return }; throw Failure.assertion("Unexpected success") }
private let testCID = "0123456789abcdef0123456789abcdef"
private let testBoot = "12345678-1234-1234-1234-123456789abc"
private let archive = Data("ARCHIVE_PRIVATE_PROFILE_CANARY".utf8)
private final class Remote: RemoteTransport {
    var calls = [String](), ready = false, complete = false, cleanCalls = 0, prepareCalls = 0, pendingStatus = false, changeBoot = false, failClean = false
    var firmwareHash = ModemEngine.firmwareHash, routerHash = ModemEngine.routerHash, cid = testCID, bootID = testBoot
    var rebindMode = "", rebindCalls = 0
    var cleanMode = "", statusCalls = 0
    var lockTokens = Set<String>()
    var onClean: (() throws -> Void)?
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        let text: String
        if command == AccessIdentity.command {
            text = "\(firmwareHash)  /firmware/image/modem.b16\n\(routerHash)  /usr/bin/diag-router\n\(cid)\n\(changeBoot ? "23456789-2345-2345-2345-23456789abcd" : bootID)\n"
        } else {
            try check(command.hasPrefix("sh -s -- ") && command.utf8.count < 1024 && input?.starts(with: Data("#!/bin/sh".utf8)) == true, "Helper must use short SSH argv and stdin source")
            let arguments = command.components(separatedBy: " -- ").last ?? ""
            let fields = arguments.split(separator: " ")
            if arguments.hasPrefix("'status'") || arguments.hasPrefix("'rebind'") { try check(timeout==300,"Archive readback requires bounded 300-second budget") }
            try check(fields.count >= 8 && lockTokens.insert(String(fields[7])).inserted, "Invocation reused stale lock token")
            if arguments.hasPrefix("'status'") {
                statusCalls += 1
                if cleanMode == "lost-status" && cleanCalls > 0 { return .init(status: 255, stdout: Data(), stderr: Data("PRIVATE status".utf8)) }
                text = complete ? "CLEAN_COMPLETE" : ready ? "\(pendingStatus ? "CLEAN_PENDING" : "CLEAN_PREPARED") \(digest(archive)) \(archive.count)" : "CLEAN_ABSENT" }
            else if arguments.hasPrefix("'prepare'") { prepareCalls += 1; ready = true; text = "CLEAN_PREPARED \(digest(archive)) \(archive.count)" }
            else if arguments.hasPrefix("'rebind'") {
                rebindCalls += 1
                let args=fields.map { String($0.dropFirst().dropLast()) }
                try check(args.count==10 && args[4]==testBoot && args[9]==bootID && args[8]==(ready || complete ? digest(archive) : "none"),"Rebind lost original owner/archive proof")
                if rebindMode=="lost" { return .init(status:255,stdout:Data(),stderr:Data("PRIVATE lost rebind".utf8)) }
                text="CLEAN_REBOUND \(bootID) "+(ready || complete ? "\(rebindMode=="wrong-receipt" ? String(repeating:"f",count:64) : digest(archive)) \(archive.count)" : "none 0")
                if rebindMode=="changed-again" { bootID="34567890-3456-3456-3456-34567890abcd" }
            }
            else if arguments.hasPrefix("'clean'") {
                cleanCalls += 1; try onClean?()
                if failClean { return .init(status: 1, stdout: Data(), stderr: Data("CLEAN_ERROR PRIVATE_PASSWORD_CANARY\n".utf8)) }
                complete = true; text = "CLEAN_COMPLETE"
                if cleanMode == "pending" { complete = false; pendingStatus = true }
                if ["lost-reply", "lost-status", "pending"].contains(cleanMode) { return .init(status: 255, stdout: Data(), stderr: Data("PRIVATE lost reply".utf8)) }
                if cleanMode == "timeout" { throw CommandFailure(message: "PRIVATE timeout", partial: .init(status: -1, stdout: Data(), stderr: Data())) }
                if cleanMode == "protocol" { return .init(status: 0, stdout: Data("PRIVATE receipt".utf8), stderr: Data()) }
                if cleanMode == "service" { return .init(status: 1, stdout: Data(), stderr: Data("CLEAN_ERROR SERVICE\nPRIVATE".utf8)) }
            } else { throw Failure.assertion("Unexpected command") }
        }
        return .init(status: 0, stdout: Data(text.utf8), stderr: Data())
    }
}
private final class Stream: BackupStreamTransport {
    var calls = 0, corruptReceipt = false, corruptData = false, onStream: (() -> Void)?
    func stream(_ command: String, input: Data?, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        try check(command.hasPrefix("sh -s -- ") && command.utf8.count < 1024 && input?.starts(with: Data("#!/bin/sh".utf8)) == true, "Stream helper must use stdin")
        return try stream(command, to: destination, maxBytes: maxBytes, timeout: timeout, cancelled: cancelled)
    }
    func stream(_ command: String, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        calls += 1
        try check(command.components(separatedBy: " -- ").last?.hasPrefix("'stream'") == true, "Unreviewed stream")
        let f = try DeviceBackups.createFile(destination); defer { try? f.close() }
        try f.write(contentsOf: corruptData ? Data("bad archive".utf8) : archive); try f.synchronize(); onStream?()
        return .init(sha256: corruptReceipt ? String(repeating: "0", count: 64) : digest(archive), bytes: Int64(archive.count))
    }
}
private final class Fixture {
    let root: URL, resources: URL, connection: Connection, id = UUID().uuidString.lowercased()
    let remote = Remote(), stream = Stream()
    init(firmwareHash: String = ModemEngine.firmwareHash) throws {
        remote.firmwareHash = firmwareHash
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("clean-host-" + UUID().uuidString.lowercased()); try secureDirectory(root)
        resources = root.appendingPathComponent("Resources"); try secureDirectory(resources); try secureDirectory(resources.appendingPathComponent("Onboarding"))
        let source = try Data(contentsOf: URL(fileURLWithPath: "Resources/Onboarding/clean-components.sh"))
        try savePrivate(source, resources.appendingPathComponent("Onboarding/clean-components.sh")); try saveJSON(["clean-components.sh": digest(source)], resources.appendingPathComponent("Onboarding/SHA256.json"))
        for name in ["key", "hosts"] { try savePrivate(Data("fixture".utf8), root.appendingPathComponent(name)) }
        connection = .init(host: "192.0.2.1", port: "2222", keyPath: root.appendingPathComponent("key").path, knownHostsPath: root.appendingPathComponent("hosts").path)
        try secureDirectory(root.appendingPathComponent("SetupBackups")); try secureDirectory(root.appendingPathComponent("SetupBackups/" + id))
        try ComponentCleanup.schedule(root: root, connection: connection, setupID: id, setupDirectory: root.appendingPathComponent("SetupBackups/" + id), expectedIdentity: .init(cid: testCID, firmwareHash: firmwareHash), transport: remote)
        remote.calls.removeAll()
    }
    var cleanup: ComponentCleanup { .init(root: root, resources: resources, connection: connection, sshFactory: { _ in self.remote }, streamer: stream) }
    deinit { try? FileManager.default.removeItem(at: root) }
}
@main struct ComponentCleanupTests {
 static func main() throws {
  var passed=0,failed=0
  func test(_ name: String, _ body: () throws -> Void) { do { try body();passed+=1;print("PASS \(name)") } catch { failed+=1;print("FAIL \(name): \(error)") } }
  test("download and actual local hash precede cleanup; ack separate") {
   let f=try Fixture();f.remote.onClean = { try check(try Data(contentsOf:f.root.appendingPathComponent("ComponentBackups/\(f.id)/components.tar")) == archive,"Clean before verified backup") }
   let r=try f.cleanup.run();try check(r.setupID==f.id && f.stream.calls==1 && f.remote.cleanCalls==1,"Unexpected flow")
   try check(ComponentCleanup.hasPending(root:f.root),"Caller ack required")
   _ = try f.cleanup.run();try check(f.stream.calls==1 && f.remote.cleanCalls==1,"Completed retry replays mutation")
   try ComponentCleanup.acknowledge(root:f.root,setupID:f.id);try check(!ComponentCleanup.hasPending(root:f.root),"Ack")
  }
  test("observed missing firmware permits backed-up cleanup without fabricating a hash") {
   let f=try Fixture(firmwareHash:"absent")
   let result=try f.cleanup.run()
   try check(result.identity.firmwareHash=="absent" && f.remote.cleanCalls==1 && f.stream.calls==1,"B04 cleanup rejected observed absence")
   try ComponentCleanup.acknowledge(root:f.root,setupID:f.id)
  }
  test("new boot archives only undispatched cleanup while preserving its exact journal and backup") {
   for scenario in ["prepared", "verified", "same-boot", "wrong-cid", "wrong-firmware", "wrong-router", "wrong-host", "corrupt-backup", "dispatched", "complete", "foreign-setup"] {
    let f=try Fixture(firmwareHash:"absent")
    var plan=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root))
    let directory=URL(fileURLWithPath:plan.backupDirectory)
    try DeviceBackups.directory(f.root.appendingPathComponent("ComponentBackups"),create:true)
    try DeviceBackups.directory(directory,create:true)
    if ["verified","corrupt-backup","dispatched","complete"].contains(scenario) {
     plan.phase=scenario=="dispatched" ? "clean-requested" : scenario=="complete" ? "complete" : "backup-verified"
     plan.archiveSha=digest(archive);plan.archiveBytes=Int64(archive.count)
     try savePrivate(scenario=="corrupt-backup" ? Data("corrupt".utf8) : archive,directory.appendingPathComponent("components.tar"))
     try saveJSON(plan,ComponentCleanup.pendingURL(f.root))
    }
    if scenario=="foreign-setup" {try savePrivate(try JSONSerialization.data(withJSONObject:["id":"foreign","phase":"complete","cleanComponents":true,"forceReinstall":true]),f.root.appendingPathComponent("setup-pending.json"))}
    let original=try Data(contentsOf:ComponentCleanup.pendingURL(f.root))
    var proof=DiagnosticDeviceProof(identity:plan.identity,routerHash:plan.routerHash,bootID:scenario=="same-boot" ? testBoot : "23456789-2345-2345-2345-23456789abcd")
    if scenario=="wrong-cid" {proof.identity.cid=String(repeating:"b",count:32)}
    if scenario=="wrong-firmware" {proof.identity.firmwareHash=String(repeating:"c",count:64)}
    if scenario=="wrong-router" {proof.routerHash=String(repeating:"d",count:64)}
    var connection=f.connection;if scenario=="wrong-host" {connection.host="192.0.2.2"}
    let eligible=try ComponentCleanup.undispatchedRecoveryPlan(root:f.root)
    try check((eligible != nil) == !["dispatched","complete"].contains(scenario),"Only predispatch metadata is eligible: \(scenario)")
    var retired=false
    do {retired=try ComponentCleanup.archiveUndispatchedAfterReboot(root:f.root,connection:connection,proof:proof)} catch {}
    let allowed=["prepared","verified"].contains(scenario)
    try check(retired==allowed && ComponentCleanup.hasPending(root:f.root) == !allowed,"Retirement eligibility: \(scenario)")
    let history=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("cleanup-before-reset-")}
    try check(history.count == (allowed ? 1 : 0),"Unexpected retirement history: \(scenario)")
    try check(try Data(contentsOf:allowed ? history[0] : ComponentCleanup.pendingURL(f.root)) == original,"Original journal bytes lost: \(scenario)")
    if plan.archiveSha != nil {try check(try Data(contentsOf:directory.appendingPathComponent("components.tar")) == (scenario=="corrupt-backup" ? Data("corrupt".utf8) : archive),"Backup changed: \(scenario)")}
    try check(f.remote.calls.isEmpty && f.stream.calls==0,"Metadata retirement touched the modem: \(scenario)")
   }
  }
  test("incorrect stream receipt prevents deletion") { let f=try Fixture();f.stream.corruptReceipt=true;try rejects{_ = try f.cleanup.run()};try check(f.remote.cleanCalls==0,"Clean dispatched") }
  test("actual file hash independently verified") { let f=try Fixture();f.stream.corruptData=true;try rejects{_ = try f.cleanup.run()};try check(f.remote.cleanCalls==0,"Clean dispatched") }
  test("changed boot after transfer prevents deletion") { let f=try Fixture();f.stream.onStream={f.remote.changeBoot=true};try rejects{_ = try f.cleanup.run()};try check(f.remote.cleanCalls==0,"Clean dispatched") }
  test("helper error is fixed and pending retained") {
   let f=try Fixture();f.remote.failClean=true
   do {_ = try f.cleanup.run();throw Failure.assertion("Expected refusal")} catch let e as Failure {throw e} catch {try check(!error.localizedDescription.contains("PRIVATE_PASSWORD_CANARY"),"Private stderr leaked")}
   try check(ComponentCleanup.hasPending(root:f.root),"Failure lost pending")
  }
  test("lost clean response is reconciled once without repeating mutations") {
   for mode in ["lost-reply", "timeout", "protocol", "pending", "lost-status"] {
    let f=try Fixture(); f.remote.cleanMode=mode
    let accepted=["lost-reply", "timeout", "protocol"].contains(mode)
    do { _ = try f.cleanup.run(); try check(accepted,"Unconfirmed result accepted") }
    catch let e as Failure { throw e }
    catch { try check(!accepted && !error.localizedDescription.contains("PRIVATE"),"Unexpected failure or leaked stderr") }
    try check(f.remote.lockTokens.count==4,"Each reconciliation command needs a fresh lock token")
    try check(f.remote.cleanCalls==1 && f.remote.prepareCalls==1 && f.remote.statusCalls==2 && f.stream.calls==1,"Repeated mutation or unbounded reconciliation: \(mode)")
    let plan=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root))
    try check(plan.phase == (accepted ? "complete" : "clean-requested"),"Outcome lost durable phase")
    try check(try Data(contentsOf:URL(fileURLWithPath:plan.backupDirectory).appendingPathComponent("components.tar"))==archive,"Backup changed")
    if mode=="lost-status" {
     f.remote.cleanMode=""; _ = try f.cleanup.run()
     try check(f.remote.cleanCalls==1 && f.remote.prepareCalls==1 && f.stream.calls==1,"Explicit retry replayed mutation")
    }
   }
  }
  test("known helper refusal keeps code and does not reconcile or replay") {
   let f=try Fixture(); f.remote.cleanMode="service"
   do { _ = try f.cleanup.run(); throw Failure.assertion("Expected refusal") }
   catch let e as Failure { throw e }
   catch { try check(error.localizedDescription.contains("[SERVICE]") && !error.localizedDescription.contains("PRIVATE"),"Missing fixed reason") }
   try check(f.remote.statusCalls==1 && f.remote.cleanCalls==1,"Known failure retried")
  }
  test("completion still requires fresh identity and unchanged local archive") {
   for scenario in ["changed-boot", "tampered-backup"] {
    let f=try Fixture(); f.remote.cleanMode="lost-reply"
    f.remote.onClean = {
     if scenario=="changed-boot" { f.remote.changeBoot=true }
     else { try Data("changed".utf8).write(to:f.root.appendingPathComponent("ComponentBackups/\(f.id)/components.tar")) }
    }
    try rejects { _ = try f.cleanup.run() }
    try check(f.remote.cleanCalls==1 && ComponentCleanup.hasPending(root:f.root),"Guard bypassed after missing response")
   }
  }
  test("resuming pending never persists an earlier phase") {
   let f=try Fixture(); f.remote.ready=true; f.remote.pendingStatus=true
   var p=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root)); p.phase="clean-requested"; p.archiveSha=digest(archive); p.archiveBytes=Int64(archive.count)
   try DeviceBackups.directory(f.root.appendingPathComponent("ComponentBackups"),create:true)
   let directory=URL(fileURLWithPath:p.backupDirectory); try DeviceBackups.directory(directory,create:true)
   try savePrivate(archive,directory.appendingPathComponent("components.tar")); try saveJSON(p,ComponentCleanup.pendingURL(f.root))
   f.remote.onClean = {
    let receipt=try readJSON(ComponentCleanupPlan.self,directory.appendingPathComponent("backup-receipt.json"))
    try check(receipt.phase=="clean-requested","Recovery went backwards before dispatch")
    throw CommandFailure(message:"PRIVATE interrupted",partial:.init(status:-1,stdout:Data(),stderr:Data()))
   }
   try rejects { _ = try f.cleanup.run() }
   try check(try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root)).phase=="clean-requested","Interrupted retry lost phase")
   f.remote.onClean=nil; _ = try f.cleanup.run()
   try check(f.remote.prepareCalls==0 && f.stream.calls==0,"Interrupted recovery repeated preparation")
  }
  test("explicit reboot continuation preserves owner and archive through every host phase") {
   for phase in ["prepared", "backup-verified", "clean-requested", "complete"] {
    let f=try Fixture(); var p=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root))
    if phase != "prepared" {
     p.phase=phase;p.archiveSha=digest(archive);p.archiveBytes=Int64(archive.count)
     try DeviceBackups.directory(f.root.appendingPathComponent("ComponentBackups"),create:true)
     let directory=URL(fileURLWithPath:p.backupDirectory);try DeviceBackups.directory(directory,create:true);try savePrivate(archive,directory.appendingPathComponent("components.tar"));try saveJSON(p,ComponentCleanup.pendingURL(f.root))
     f.remote.ready=true; f.remote.pendingStatus=phase=="clean-requested"; f.remote.complete=phase=="complete"
    }
    f.remote.bootID="23456789-2345-2345-2345-23456789abcd"
    _ = try f.cleanup.run()
    var saved=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root))
    try check(saved.bootID==testBoot && saved.acceptedBootID==f.remote.bootID && f.remote.rebindCalls==1 && saved.phase=="complete","Reboot proof lost original owner: \(phase)")
    try check(f.stream.calls == (phase=="prepared" ? 1 : 0) && f.remote.cleanCalls == (phase=="complete" ? 0 : 1),"Reboot replays preparation or clean: \(phase)")
    f.remote.bootID="34567890-3456-3456-3456-34567890abcd"; _ = try f.cleanup.run()
    saved=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root))
    try check(saved.bootID==testBoot && saved.acceptedBootID==f.remote.bootID && f.remote.rebindCalls==2 && f.remote.cleanCalls == (phase=="complete" ? 0 : 1),"Second reboot replays completed clean")
   }
  }
  test("rebind rejects foreign identity, corrupt archive and unconfirmed receipt") {
   for mode in ["foreign-cid", "foreign-firmware", "foreign-router", "corrupt-archive", "lost", "wrong-receipt", "changed-again"] {
    let f=try Fixture();var p=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root));p.phase="clean-requested";p.archiveSha=digest(archive);p.archiveBytes=Int64(archive.count)
    try DeviceBackups.directory(f.root.appendingPathComponent("ComponentBackups"),create:true)
    let directory=URL(fileURLWithPath:p.backupDirectory);try DeviceBackups.directory(directory,create:true);try savePrivate(mode=="corrupt-archive" ? Data("changed".utf8) : archive,directory.appendingPathComponent("components.tar"));try saveJSON(p,ComponentCleanup.pendingURL(f.root))
    f.remote.ready=true;f.remote.pendingStatus=true;f.remote.bootID="23456789-2345-2345-2345-23456789abcd";f.remote.rebindMode=mode
    if mode=="foreign-cid" {f.remote.cid=String(repeating:"f",count:32)}
    if mode=="foreign-firmware" {f.remote.firmwareHash=String(repeating:"f",count:64)}
    if mode=="foreign-router" {f.remote.routerHash=String(repeating:"f",count:64)}
    try rejects {_ = try f.cleanup.run()}
    try check(try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root)).acceptedBootID==nil,"Unconfirmed rebind persisted")
    try check(f.remote.cleanCalls==0 && f.remote.prepareCalls==0 && f.stream.calls==0,"Rejected rebind touched components")
    try check(f.remote.rebindCalls == (["lost","wrong-receipt","changed-again"].contains(mode) ? 1 : 0),"Rebind ran without prior local identity/archive proof")
    if mode=="lost" {
     f.remote.rebindMode="";f.remote.bootID="34567890-3456-3456-3456-34567890abcd";_ = try f.cleanup.run()
     let saved=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root))
     try check(saved.bootID==testBoot && saved.acceptedBootID==f.remote.bootID && f.remote.rebindCalls==2 && f.remote.cleanCalls==1 && f.stream.calls==0,"Dropped receipt followed by another reboot lost original proof")
    }
   }
  }
  test("cancellation never rebinds a changed boot") {
   let f=try Fixture();f.remote.bootID="23456789-2345-2345-2345-23456789abcd"
   try rejects {_ = try f.cleanup.cancelBeforeDispatch()}
   try check(f.remote.rebindCalls==0 && f.remote.cleanCalls==0 && ComponentCleanup.hasPending(root:f.root),"Cancellation rebound boot")
  }
  test("every bundled producer code has a fixed host diagnostic") {
   let body=try String(contentsOfFile:"Resources/Onboarding/clean-components.sh",encoding:.utf8)
   let pattern=try NSRegularExpression(pattern:#"(?:\bfail |\bclean_stage=|CLEAN_ERROR )([A-Z][A-Z0-9_]*)\b"#)
   let matches=pattern.matches(in:body,range:NSRange(body.startIndex...,in:body))
   let codes=Set(matches.map { String(body[Range($0.range(at:1),in:body)!]) })
   try check(codes.count>20,"Missing producer fixture")
   for code in codes { try check(ComponentCleanup.errorCodes.contains(code),"Unhandled bundled producer code: \(code)") }
   for code in ["SERVICE", "PATH", "OWNER", "CHANGED", "VPN_INTEGRITY", "PENDING_AGENT"] {
    let message=ComponentCleanup.message(code)
    try check(message.contains("диагностический отчёт") && !message.contains("продолжите"),"Permanent guard prescribes futile retry: \(code)")
   }
  }
  test("fixed helper codes and protocol errors never expose arbitrary output") {
   for code in ComponentCleanup.errorCodes {
    do { _ = try ComponentCleanup.parseReply(.init(status:1,stdout:Data(),stderr:Data("PRIVATE detail\nCLEAN_ERROR \(code)\r\n".utf8)),action:"prepare"); throw Failure.assertion("Expected refusal") }
    catch let e as Failure { throw e }
    catch { try check(error.localizedDescription.contains("[\(code)]") && error.localizedDescription.contains("подготовка копии") && !error.localizedDescription.contains("PRIVATE"),"Fixed reason missing: \(code)") }
   }
   for raw in ["CLEAN_ERROR PRIVATE", "prefix CLEAN_ERROR BUSY", "CLEAN_ERROR BUSY suffix", "CLEAN_ERROR BUSY\nCLEAN_ERROR CHANGED", "CLEAN_ERROR BUSY\nCLEAN_ERROR BUSY", "CLEAN_ERROR BUSY\nCLEAN_ERROR PRIVATE"] {
    do { _ = try ComponentCleanup.parseReply(.init(status:1,stdout:Data(),stderr:Data(raw.utf8)),action:"status"); throw Failure.assertion("Expected refusal") }
    catch let e as Failure { throw e }
    catch { try check(error.localizedDescription.contains("[REMOTE_FAILURE]") && !error.localizedDescription.contains("PRIVATE"),"Forged helper reason accepted") }
   }
   for raw in [Data("CLEAN_COMPLETE\nPRIVATE".utf8), Data("CLEAN_COMPLETE\n\n".utf8), Data(" CLEAN_COMPLETE".utf8), Data("CLEAN_COMPLETE\0".utf8), Data([255]), Data(("CLEAN_COMPLETE"+String(repeating:" ",count:513)).utf8), Data("CLEAN_PREPARED \(digest(archive)) 17179869185".utf8), Data("CLEAN_PREPARED \(digest(archive)) 01".utf8)] {
    do { _ = try ComponentCleanup.parseReply(.init(status:0,stdout:raw,stderr:Data()),action:"status"); throw Failure.assertion("Expected refusal") }
    catch let e as Failure { throw e }
    catch { try check(error.localizedDescription.contains("[PROTOCOL]") && !error.localizedDescription.contains("PRIVATE"),"Malformed receipt accepted") }
   }
   for ending in ["", "\n", "\r\n"] { try check(try ComponentCleanup.parseReply(.init(status:0,stdout:Data(("CLEAN_COMPLETE"+ending).utf8),stderr:Data()),action:"clean")=="CLEAN_COMPLETE","Exact receipt rejected") }
  }
  test("foreign completed setup journal refuses before remote") {
   let f=try Fixture();try savePrivate(try JSONSerialization.data(withJSONObject:["id":"foreign","phase":"complete","cleanComponents":true,"forceReinstall":true]),f.root.appendingPathComponent("setup-pending.json"));try rejects{_ = try f.cleanup.run()};try check(f.remote.calls.isEmpty,"Foreign setup reached modem")
  }
  test("invalid pending does not contact modem") {
   let f=try Fixture();var p=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root));p.phase="foreign";try saveJSON(p,ComponentCleanup.pendingURL(f.root));try rejects{_ = try f.cleanup.run()};try check(f.remote.calls.isEmpty,"Invalid journal reached modem")
  }
  test("different selected host refuses before remote") {
   let f=try Fixture();var c=f.connection;c.host="192.0.2.2";let runner=ComponentCleanup(root:f.root,resources:f.resources,connection:c,sshFactory:{_ in f.remote},streamer:f.stream);try rejects{_ = try runner.run()};try check(f.remote.calls.isEmpty,"Wrong host reached modem")
  }
  test("corrupt helper refuses before remote") {
   let f=try Fixture();try savePrivate(Data("corrupt".utf8),f.resources.appendingPathComponent("Onboarding/clean-components.sh"));try rejects{_ = try f.cleanup.run()};try check(f.remote.calls.isEmpty,"Unpinned helper reached modem")
  }
  test("missing dispatched transaction never prepares again") {
   let f=try Fixture();var p=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root));p.phase="clean-requested";p.archiveSha=digest(archive);p.archiveBytes=Int64(archive.count);try saveJSON(p,ComponentCleanup.pendingURL(f.root));try rejects{_ = try f.cleanup.run()};try check(f.remote.prepareCalls==0 && f.remote.cleanCalls==0,"Remote transaction recreated")
  }
  test("remote pending requires local dispatched clean") {
   let f=try Fixture();f.remote.ready=true;f.remote.pendingStatus=true;try rejects{_ = try f.cleanup.run()};try check(f.stream.calls==0 && f.remote.cleanCalls==0,"Unknown pending continued")
  }
  test("remote complete cannot authorize an undispatched clean") {
   let f=try Fixture();f.remote.complete=true;try rejects{_ = try f.cleanup.run()};try check(f.remote.prepareCalls==0 && f.remote.cleanCalls==0,"Unknown completion accepted")
  }
  test("cancel before remote preparation uses status only") {
   let f=try Fixture();try check(ComponentCleanup.canCancel(root:f.root),"Cancel unavailable")
   let result=try f.cleanup.cancelBeforeDispatch();try check(result.cancelled && f.remote.prepareCalls==0 && f.remote.cleanCalls==0 && f.stream.calls==0,"Cancel mutated")
   let resumed=try f.cleanup.run();try check(resumed.cancelled,"Terminal cancel replay")
   try ComponentCleanup.acknowledge(root:f.root,setupID:f.id);try check(!ComponentCleanup.hasPending(root:f.root),"Cancelled pending retained")
  }
  test("cancel prepared archive does not delete it remotely") {
   let f=try Fixture();f.remote.ready=true;_ = try f.cleanup.cancelBeforeDispatch();try check(f.remote.cleanCalls==0 && f.remote.prepareCalls==0 && f.stream.calls==0,"Cancel dispatched")
  }
  test("cancel dispatched cleanup rejects before transport") {
   let f=try Fixture();var p=try readJSON(ComponentCleanupPlan.self,ComponentCleanup.pendingURL(f.root));p.phase="clean-requested";p.archiveSha=digest(archive);p.archiveBytes=Int64(archive.count);try saveJSON(p,ComponentCleanup.pendingURL(f.root));try rejects{_ = try f.cleanup.cancelBeforeDispatch()};try check(f.remote.calls.isEmpty,"Dispatched cancel used remote")
  }
  test("cancel remote pending refuses and preserves journal") {
   let f=try Fixture();f.remote.ready=true;f.remote.pendingStatus=true;try rejects{_ = try f.cleanup.cancelBeforeDispatch()};try check(ComponentCleanup.hasPending(root:f.root) && f.remote.cleanCalls==0,"Unsafe cancel")
  }
  test("cancel foreign setup refuses before transport") {
   let f=try Fixture();try savePrivate(try JSONSerialization.data(withJSONObject:["id":"foreign","phase":"complete","cleanComponents":true,"forceReinstall":true]),f.root.appendingPathComponent("setup-pending.json"));try rejects{_ = try f.cleanup.cancelBeforeDispatch()};try check(f.remote.calls.isEmpty,"Foreign cancel reached modem")
  }
  test("dangling leftover setup refuses before transport") {
   let f=try Fixture();try FileManager.default.createSymbolicLink(atPath:f.root.appendingPathComponent("setup-pending.json").path,withDestinationPath:f.root.appendingPathComponent("missing").path);try rejects{_ = try f.cleanup.run()};try rejects{_ = try f.cleanup.cancelBeforeDispatch()};try check(f.remote.calls.isEmpty,"Dangling setup ignored")
  }
  test("real stream process receives large stdin and keeps short argv") {
   let f=try Fixture(), file=f.root.appendingPathComponent("fake-ssh.sh"), output=f.root.appendingPathComponent("stream.tar")
   let input=Data(repeating:65,count:131072)
   let script="#!/bin/sh\nbytes=$(wc -c | tr -d ' ')\ntest \"$bytes\" = 131072 || exit 2\nprintf '%s' ARCHIVE_PRIVATE_PROFILE_CANARY\nprintf 'BACKUP_RESULT sha256=\(digest(archive)) bytes=\(archive.count)\\n' >&2\n"
   try savePrivate(Data(script.utf8),file);chmod(file.path,0o700)
   let transport=SSHBackupStreamTransport(f.connection,sshExecutable:file)
   let result=try transport.stream("sh -s -- stream",input:input,to:output,maxBytes:1024,timeout:5,cancelled:{false})
   try check(result.sha256==digest(archive),"Stdin stream")
   let names=try FileManager.default.contentsOfDirectory(atPath:f.root.path);try check(!names.contains(where:{$0.hasPrefix(".stdin-")}),"Temporary stdin retained")
  }
  test("stream helper refusal preserves fixed reason and removes partial archive") {
   let f=try Fixture(), executable=f.root.appendingPathComponent("fake-stream-error.sh")
   try savePrivate(Data("#!/bin/sh\ncat >/dev/null\nprintf 'PRIVATE canary\\nCLEAN_ERROR CHANGED\\n' >&2\nexit 1\n".utf8),executable); chmod(executable.path,0o700)
   let transport=SSHBackupStreamTransport(f.connection,sshExecutable:executable,failureFormatter:ComponentCleanup.streamFailureMessage)
   let runner=ComponentCleanup(root:f.root,resources:f.resources,connection:f.connection,sshFactory:{_ in f.remote},streamer:transport)
   do { _ = try runner.run(); throw Failure.assertion("Expected stream refusal") }
   catch let e as Failure { throw e }
   catch { try check(error.localizedDescription.contains("[CHANGED]") && error.localizedDescription.contains("сохранение копии") && !error.localizedDescription.contains("PRIVATE"),"Stream reason lost or leaked") }
   let names=try FileManager.default.contentsOfDirectory(atPath:f.root.appendingPathComponent("ComponentBackups/\(f.id)").path)
   try check(!names.contains(where:{$0.hasPrefix(".partial-") || $0.hasPrefix(".stderr-") || $0.hasPrefix(".stdin-")}) && f.remote.cleanCalls==0,"Stream failure left temporary data or dispatched clean")
  }
  test("archive bytes absent from activity journal") {
   let f=try Fixture();_ = try f.cleanup.run()
   let journalURL=f.root.appendingPathComponent("Activity")
   if let enumerator=FileManager.default.enumerator(at:journalURL,includingPropertiesForKeys:[.isRegularFileKey]) { for case let url as URL in enumerator { if (try?url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true {let d=try Data(contentsOf:url);try check(!String(decoding:d,as:UTF8.self).contains("ARCHIVE_PRIVATE_PROFILE_CANARY"),"Archive leaked")} } }
  }
  print("\(passed) passed, \(failed) failed");if failed>0{exit(1)}
 }
}
