import Foundation

private enum Failure: Error { case check(String) }
private func check(_ ok: @autoclosure () throws -> Bool, _ text: String) throws { if try !ok() { throw Failure.check(text) } }
private func reject(_ body: () throws -> Void) throws { do { try body() } catch is Failure { throw Failure.check("fixture failure") } catch { return }; throw Failure.check("Expected refusal") }
private let boot = "11111111-1111-1111-1111-111111111111"
private let cid = String(repeating: "a", count: 32)
private func wire(uid: String = "0", arch: String = "aarch64", id: String = "?", bootID: String = boot, fw: String = "?", router: String = "absent") -> Data {
    Data(("ZTE_SSH_READ_V1\n" + [uid,"Linux",arch,id,bootID,fw,router].joined(separator:"\n") + "\n").utf8)
}
private final class Remote: RemoteTransport {
    var data = wire(), calls = [String](), changed = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        try check(input == nil && timeout <= 30, "Missing finite readonly bounds")
        if command == SSHReadProof.command { return CommandResult(status: 0, stdout: changed ? wire(bootID: "22222222-2222-2222-2222-222222222222") : data, stderr: Data()) }
        if command == ModemInformationManager.command { return CommandResult(status: 1, stdout: Data(), stderr: Data()) }
        throw Failure.check("Unexpected remote dispatch")
    }
}
@main enum SSHReadAccessTests {
    static func main() throws {
        var count = 0
        func test(_ title: String, _ body: () throws -> Void) throws { try body(); count += 1; print("PASS " + title) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-read-access-" + UUID().uuidString)
        try secureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key"), hosts = root.appendingPathComponent("known_hosts")
        try savePrivate(Data("fixture".utf8), key); try savePrivate(Data("fixture".utf8), hosts)
        let connection = Connection(host:"192.0.2.1",port:"2222",keyPath:key.path,knownHostsPath:hosts.path)
        try test("root unknown firmware without MMC CID is a readonly SSH session") {
            let remote = Remote(), engine = try ModemEngine(root: root.appendingPathComponent("root"), resources: root, connection: connection, transport: remote)
            let chosen = try ConnectionRouter(engine:engine).connect(mode:.ssh)
            try check(chosen.actualMode == .ssh && chosen.session?.summary.identity == nil && chosen.session?.summary.fields["accessProfile"] == "read-only-ssh", "Unknown facts became false write compatibility")
            _ = try chosen.session!.requireSSH()
            try check(remote.calls.allSatisfy { $0 == SSHReadProof.command }, "Read required agent/USB/helper")
        }
        try test("non-root ARM32 read succeeds but supplies no ARM64 install proof") {
            let remote = Remote(); remote.data = wire(uid:"1000",arch:"armv7l")
            let engine = try ModemEngine(root:root.appendingPathComponent("nonroot"),resources:root,connection:connection,transport:remote)
            let chosen = try ConnectionRouter(engine:engine).connect(mode:.ssh)
            try check(chosen.actualMode == .ssh && chosen.session?.diagnosticSession?.proof == nil, "Read fabricated install identity")
            try reject { _ = try AccessIdentity.parse(remote.data) }
        }
        try test("actual prepare run reuses SSH without passwords assets agent or CID") {
            for uid in ["0", "1000"] {
                let remote = Remote(); remote.data = wire(uid:uid,arch:"armv7l")
                let engine = try OnboardingEngine(root:root.appendingPathComponent("reuse-" + uid),resources:root.appendingPathComponent("missing-resources"),connection:connection,sshFactory:{ _ in remote })
                let result = try engine.run(webPassword:"",agentPassword:"")
                try check(result.identity == nil && result.state == nil && result.connection.host == connection.host, "Reuse fabricated identity/readiness")
                try check(remote.calls == [SSHReadProof.command, SSHReadProof.command], "Reuse needed installer/agent/HTTP")
            }
        }
        try test("unknown all optional facts is valid; malformed known facts are refused") {
            let unknown = Data("ZTE_SSH_READ_V1\n?\n?\n?\n?\n?\n?\n?\n".utf8)
            try check(try SSHReadProof.parse(unknown).identity == nil, "Unknown generated CID")
            try reject { _ = try SSHReadProof.parse(wire(id:"malformed")) }
            try reject { _ = try SSHReadProof.parse(unknown + Data("extra\n".utf8)) }
        }
        try test("observed CID mismatch and disappearing boot still fail closed") {
            let proof = try SSHReadProof.parse(wire(id:cid))
            try check(!proof.matches(DiagnosticDeviceExpectation(cids:[String(repeating:"b",count:32)])), "Known mismatch ignored")
            try reject { try proof.verify(SSHReadProof.parse(wire(id:cid,bootID:"?"))) }
        }
        try test("partial readonly selection verifies original endpoint and current boot") {
            let remote = Remote(), engine = try ModemEngine(root:root.appendingPathComponent("target"),resources:root,connection:connection,transport:remote)
            let session = try ConnectionRouter(engine:engine).connect(mode:.ssh).session!
            let target = SSHSelectionContext(identity:nil,imei:nil,session:session)
            try target.verify(engine)
            remote.changed = true
            try reject { try target.verify(engine) }
        }
        try test("actual shell can observe a non-Linux host without files or root prerequisites") {
            let result = try HostProcessRunner().run(URL(fileURLWithPath:"/bin/sh"),["-c",SSHReadProof.command],timeout:10)
            try check(result.status == 0, "Observation shell failed")
            let proof = try SSHReadProof.parse(result.stdout)
            try check(proof.system == "Darwin" && proof.cid == nil && proof.bootID == nil, "Host observation fabricated modem identity")
        }
        try test("readonly metadata hashes readable files through parent aliases; unavailable stays unknown") {
            let dir = root.appendingPathComponent("metadata"), alias = root.appendingPathComponent("alias")
            try secureDirectory(dir)
            let file = dir.appendingPathComponent("firmware")
            try savePrivate(Data("abc".utf8), file)
            try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:dir)
            func read(_ path:String) throws -> SSHReadProof {
                let script = SSHReadProof.command.replacingOccurrences(of:"/firmware/image/modem.b16",with:path)
                    .replacingOccurrences(of:"sha256sum ",with:"/usr/bin/shasum -a 256 ")
                let result = try HostProcessRunner().run(URL(fileURLWithPath:"/bin/sh"),["-c",script],timeout:10)
                try check(result.status == 0,"Metadata read failed")
                return try SSHReadProof.parse(result.stdout)
            }
            try check(try read(alias.appendingPathComponent("firmware").path).firmwareHash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Readonly parent alias rejected")
            try check(try read(dir.appendingPathComponent("missing").path).firmwareHash == "absent", "Missing file not observed")
            let link = dir.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
            try check(try read(link.path).firmwareHash == nil, "Symlink file trusted")
            try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path) }
            try check(try read(dir.appendingPathComponent("missing").path).firmwareHash == nil, "Inaccessible parent reported absence")
        }
        print("RESULT \(count) passed; no device used")
    }
}
