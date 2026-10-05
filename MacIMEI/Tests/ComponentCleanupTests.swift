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
    var onClean: (() throws -> Void)?
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        let text: String
        if command == AccessIdentity.command {
            text = "\(ModemEngine.firmwareHash)  /firmware/image/modem.b16\n\(ModemEngine.routerHash)  /usr/bin/diag-router\n\(testCID)\n\(changeBoot ? "23456789-2345-2345-2345-23456789abcd" : testBoot)\n"
        } else {
            try check(command.hasPrefix("sh -s -- ") && command.utf8.count < 1024 && input?.starts(with: Data("#!/bin/sh".utf8)) == true, "Helper must use short SSH argv and stdin source")
            let arguments = command.components(separatedBy: " -- ").last ?? ""
            if arguments.hasPrefix("'status'") { text = complete ? "CLEAN_COMPLETE" : ready ? "\(pendingStatus ? "CLEAN_PENDING" : "CLEAN_PREPARED") \(digest(archive)) \(archive.count)" : "CLEAN_ABSENT" }
            else if arguments.hasPrefix("'prepare'") { prepareCalls += 1; ready = true; text = "CLEAN_PREPARED \(digest(archive)) \(archive.count)" }
            else if arguments.hasPrefix("'clean'") {
                cleanCalls += 1; try onClean?()
                if failClean { return .init(status: 1, stdout: Data(), stderr: Data("CLEAN_ERROR PRIVATE_PASSWORD_CANARY\n".utf8)) }
                complete = true; text = "CLEAN_COMPLETE"
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
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("clean-host-" + UUID().uuidString.lowercased()); try secureDirectory(root)
        resources = root.appendingPathComponent("Resources"); try secureDirectory(resources); try secureDirectory(resources.appendingPathComponent("Onboarding"))
        let source = try Data(contentsOf: URL(fileURLWithPath: "Resources/Onboarding/clean-components.sh"))
        try savePrivate(source, resources.appendingPathComponent("Onboarding/clean-components.sh")); try saveJSON(["clean-components.sh": digest(source)], resources.appendingPathComponent("Onboarding/SHA256.json"))
        for name in ["key", "hosts"] { try savePrivate(Data("fixture".utf8), root.appendingPathComponent(name)) }
        connection = .init(host: "192.0.2.1", port: "2222", keyPath: root.appendingPathComponent("key").path, knownHostsPath: root.appendingPathComponent("hosts").path)
        try secureDirectory(root.appendingPathComponent("SetupBackups")); try secureDirectory(root.appendingPathComponent("SetupBackups/" + id))
        try ComponentCleanup.schedule(root: root, connection: connection, setupID: id, setupDirectory: root.appendingPathComponent("SetupBackups/" + id), expectedIdentity: .init(cid: testCID, firmwareHash: ModemEngine.firmwareHash), transport: remote)
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
  test("incorrect stream receipt prevents deletion") { let f=try Fixture();f.stream.corruptReceipt=true;try rejects{_ = try f.cleanup.run()};try check(f.remote.cleanCalls==0,"Clean dispatched") }
  test("actual file hash independently verified") { let f=try Fixture();f.stream.corruptData=true;try rejects{_ = try f.cleanup.run()};try check(f.remote.cleanCalls==0,"Clean dispatched") }
  test("changed boot after transfer prevents deletion") { let f=try Fixture();f.stream.onStream={f.remote.changeBoot=true};try rejects{_ = try f.cleanup.run()};try check(f.remote.cleanCalls==0,"Clean dispatched") }
  test("helper error is fixed and pending retained") {
   let f=try Fixture();f.remote.failClean=true
   do {_ = try f.cleanup.run();throw Failure.assertion("Expected refusal")} catch let e as Failure {throw e} catch {try check(!error.localizedDescription.contains("PRIVATE_PASSWORD_CANARY"),"Private stderr leaked")}
   try check(ComponentCleanup.hasPending(root:f.root),"Failure lost pending")
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
  test("archive bytes absent from activity journal") {
   let f=try Fixture();_ = try f.cleanup.run()
   let journalURL=f.root.appendingPathComponent("Activity")
   if let enumerator=FileManager.default.enumerator(at:journalURL,includingPropertiesForKeys:[.isRegularFileKey]) { for case let url as URL in enumerator { if (try?url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true {let d=try Data(contentsOf:url);try check(!String(decoding:d,as:UTF8.self).contains("ARCHIVE_PRIVATE_PROFILE_CANARY"),"Archive leaked")} } }
  }
  print("\(passed) passed, \(failed) failed");if failed>0{exit(1)}
 }
}
