import Foundation
import Darwin
private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func rejects(_ text: String, _ body: () throws -> Void) throws {
    do { try body() } catch let e as Failure { throw e } catch { try check(text.isEmpty || error.localizedDescription.contains(text), "Unexpected: \(error.localizedDescription), expected \(text)"); return }
    throw Failure.assertion("Unexpected success")
}
private final class Flag: @unchecked Sendable { private var value = false; let lock = NSLock(); func set() { lock.lock(); value = true; lock.unlock() }; func get() -> Bool { lock.lock(); defer {lock.unlock()}; return value } }
private final class MockRemote: RemoteTransport {
    var identityCalls = 0, commands: [String] = []
    var changeIdentity = false, changeBoot = false
    var estimate = "BACKUP_ESTIMATE bytes=20971520\n"
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command); var text = ""
        if command.hasPrefix("sha256sum /firmware/image/modem.b16 ") {
            identityCalls += 1
            let cid = changeIdentity && identityCalls > 1 ? String(repeating: "f", count: 32) : "0123456789abcdef0123456789abcdef"
            let boot = changeBoot && identityCalls > 1 ? "e7d85c31-7c1a-43dc-9e72-0fd40ca78f77" : "00112233-4455-6677-8899-aabbccddeeff"
            text = "\(ModemEngine.firmwareHash) /firmware/image/modem.b16\n\(ModemEngine.routerHash) /usr/bin/diag-router\n\(cid)\n\(boot)\n"
        } else if command.contains("/tmp/zte-imei-app.lock") || command.hasPrefix("umask 077; mkdir '/tmp/zte-device-backup-") || command.contains("&& rm -rf '/tmp/zte-device-backup-") {}
        else if command.hasPrefix("umask 077; cat > "), let input { text = "\(digest(input))  \(command.split(separator: "'")[1])\n" }
        else if command.contains("'estimate'") { text = estimate }
        else { throw Failure.assertion("Unexpected remote command") }
        return CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data())
    }
}
private final class MockStream: BackupStreamTransport {
    var calls = 0
    var corruptReceipt = false, failAfterWrite = false
    var cancelFlag: Flag?
    func stream(_ command: String, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        calls += 1; try check(!command.contains(" of=") && !command.contains("--restore") && !command.contains("reboot"), "Write command")
        let output = try DeviceBackups.createFile(destination); defer { try? output.close() }
        let size = DeviceBackups.partitionBytes[destination.lastPathComponent] ?? 4096
        for _ in 0..<(size / 4096) { try output.write(contentsOf: Data(repeating: UInt8(calls), count: 4096)) }
        try output.synchronize()
        if failAfterWrite { throw IMEIError.message("stream interrupted") }
        cancelFlag?.set(); try DeviceBackups.checkCancelled(cancelled)
        var result = try DeviceBackups.hashFile(destination)
        if corruptReceipt { result.sha256 = String(repeating: "0", count: 64) }
        return result
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine
    let remote = MockRemote(), stream = MockStream()
    var backups: DeviceBackups { DeviceBackups(engine: engine, streamer: stream) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-device-backup-tests-" + UUID().uuidString.lowercased()); try secureDirectory(root)
        let resources = root.appendingPathComponent("Resources"); try secureDirectory(resources); try secureDirectory(resources.appendingPathComponent("DeviceBackups"))
        let original = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/DeviceBackups/reader.sh")
        try savePrivate(Data(contentsOf: original), resources.appendingPathComponent("DeviceBackups/reader.sh"))
        for name in ["key", "hosts"] { try savePrivate(Data("mock".utf8), root.appendingPathComponent(name)) }
        let connection = Connection(host: "192.0.2.1", port: "2222", keyPath: root.appendingPathComponent("key").path, knownHostsPath: root.appendingPathComponent("hosts").path)
        engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: remote)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func create(_ kind: DeviceBackupKind = .configuration, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> DeviceBackupItem { try engine.locked { try backups.create(kind, cancelled: cancelled) } }
    func noCopies() throws { try check(try DeviceBackups.list(root: root).isEmpty, "Failed copy is eligible"); let store = DeviceBackups.rootURL(root); if FileManager.default.fileExists(atPath: store.path) { try check(try FileManager.default.contentsOfDirectory(atPath: store.path).isEmpty, "Partial data retained") } }
}
@main struct DeviceBackupsTests {
    static func main() throws {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) { do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") } }
        test("scopes distinguish modem state from firmware and QCN") {
            try check(DeviceBackups.partitionBytes.values.reduce(0,+) == 20 * 1024 * 1024, "Modem scope")
            try check(DeviceBackupKind.modem.scope.contains("Не включает образы прошивки") && DeviceBackupKind.modem.scope.contains("QCN"), "Ambiguous scope")
            try check(DeviceBackupKind.configuration.limitations.contains("без шифрования"), "Encryption claim")
            try check(DeviceBackupKind.userData.exclusions.contains("data/local/tmp"), "Temporary backups included")
        }
        test("receipt rejects missing ambiguous or malformed confirmation") {
            let h = String(repeating: "a", count: 64)
            let result = try SSHBackupStreamTransport.parseReceipt("diagnostic\nBACKUP_RESULT sha256=\(h) bytes=4096\n")
            try check(result.bytes == 4096 && result.sha256 == h, "Receipt")
            for bad in ["", "BACKUP_RESULT sha256=bad bytes=4", "BACKUP_RESULT sha256=\(h) bytes=-1", "BACKUP_RESULT sha256=\(h) bytes=0", "BACKUP_RESULT sha256=\(h) bytes=4\nBACKUP_RESULT sha256=\(h) bytes=4"] { try rejects("") { _ = try SSHBackupStreamTransport.parseReceipt(bad) } }
        }
        test("stream failures explain cause and redact bounded diagnostics") {
            let unsupported = SSHBackupStreamTransport.failureMessage("tar: unrecognized option: exclude\nBACKUP_ERROR READ\n", exitCode: 1)
            try check(unsupported.contains("архиватор") && unsupported.contains("BACKUP_ERROR READ"), "Missing useful tar reason")
            let changed = SSHBackupStreamTransport.failureMessage("tar: file changed as we read it\nBACKUP_ERROR READ\n", exitCode: 1)
            try check(changed.contains("Данные изменились"), "Missing consistency reason")
            let privateError = SSHBackupStreamTransport.failureMessage("tar: password=super-secret-value\nssh: token=private-token\narbitrary secret output\nBACKUP_ERROR READ\n", exitCode: 1)
            for secret in ["super-secret-value", "private-token", "arbitrary secret output"] { try check(!privateError.contains(secret), "Private stderr leaked") }
            let long = SSHBackupStreamTransport.failureMessage(String(repeating: "tar: " + String(repeating: "x", count: 1000) + "\n", count: 100), exitCode: 9)
            try check(long.count < 1200 && long.contains("код 9"), "Unbounded stderr")
            try check(SSHBackupStreamTransport.failureMessage("BACKUP_ERROR DATA_MOUNTS", exitCode: 1).contains("монтирования"), "Missing mount reason")
        }
        test("estimates reject ambiguity overflow and invalid numbers") {
            try check(try DeviceBackups.parseEstimate("BACKUP_ESTIMATE bytes=20971520\n") == 20971520, "Estimate")
            for bad in ["bad", "BACKUP_ESTIMATE bytes=0", "BACKUP_ESTIMATE bytes=-1", "BACKUP_ESTIMATE bytes=1.5", "BACKUP_ESTIMATE bytes=999999999999999999999", "BACKUP_ESTIMATE bytes=5\nextra"] { try rejects("") { _ = try DeviceBackups.parseEstimate(bad) } }
        }
        test("creation requires native operation lock") { let f = try Fixture(); try rejects("блокировки") { _ = try f.backups.create(.configuration) }; try check(f.stream.calls == 0, "Stream before lock") }
        test("configuration streams into private files then verifies and lists") {
            let f = try Fixture(), item = try f.create()
            try check(item.kind == .configuration && item.bytes == 4096, "Item metadata")
            try check(try DeviceBackups.list(root: f.root).first?.id == item.id, "Missing inventory")
            _ = try DeviceBackups.verify(item)
            try check(try DeviceBackups.metadata(item.url).st_mode & 0o777 == 0o700, "Directory permissions")
            for name in ["configuration.tar", "manifest.json"] { try check(try DeviceBackups.metadata(item.url.appendingPathComponent(name)).st_mode & 0o777 == 0o600, "File permissions") }
            try check(f.remote.identityCalls == 2, "No final identity verification")
        }
        test("modem copy preserves all four pinned sizes") {
            let f = try Fixture(), item = try f.create(.modem)
            try check(f.stream.calls == 4 && item.bytes == 20 * 1024 * 1024, "Incomplete partitions")
            for file in try DeviceBackups.manifest(at: item.url).files { try check(file.bytes == DeviceBackups.partitionBytes[file.name], "Wrong size") }
            _ = try DeviceBackups.verify(item)
        }
        test("stream checksum mismatch cannot publish") { let f = try Fixture(); f.stream.corruptReceipt = true; try rejects("SHA256") { _ = try f.create() }; try f.noCopies() }
        test("interruption removes incomplete files") { let f = try Fixture(); f.stream.failAfterWrite = true; try rejects("interrupted") { _ = try f.create() }; try f.noCopies() }
        test("cancellation removes partial transfer") { let f = try Fixture(), flag = Flag(); f.stream.cancelFlag = flag; try rejects("отменено") { _ = try f.create(cancelled: {flag.get()}) }; try f.noCopies() }
        test("identity change or reboot invalidates completed data") {
            for boot in [false, true] { let f = try Fixture(); f.remote.changeIdentity = !boot; f.remote.changeBoot = boot; try rejects("изменился модем") { _ = try f.create() }; try f.noCopies() }
        }
        test("corruption prevents verification and export") {
            let f = try Fixture(), item = try f.create(); try savePrivate(Data("tampered".utf8), item.url.appendingPathComponent("configuration.tar"))
            try rejects("Повреждена") { _ = try DeviceBackups.verify(item) }; try rejects("Повреждена") { _ = try DeviceBackups.export(item, to: f.root) }
        }
        test("symlink payload and traversal manifest are rejected") {
            let f = try Fixture(), item = try f.create(), payload = item.url.appendingPathComponent("configuration.tar")
            try FileManager.default.removeItem(at: payload); try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: f.root.appendingPathComponent("key"))
            try rejects("ссылкой") { _ = try DeviceBackups.verify(item) }
            var manifest = try DeviceBackups.manifest(at: item.url); manifest.files[0].name = "../key"
            try FileManager.default.removeItem(at: item.url.appendingPathComponent("manifest.json")); try DeviceBackups.writeJSON(manifest, to: item.url.appendingPathComponent("manifest.json"))
            try rejects("состав") { _ = try DeviceBackups.verify(item) }
        }
        test("export verifies new copy and cannot overwrite") {
            let f = try Fixture(), item = try f.create(), destination = f.root.appendingPathComponent("Exports"); try secureDirectory(destination)
            let exported = try DeviceBackups.export(item, to: destination)
            var copy = item; copy.url = exported; _ = try DeviceBackups.verify(copy)
            try rejects("уже существует") { _ = try DeviceBackups.export(item, to: destination) }
        }
        test("cancelled export publishes nothing") {
            let f = try Fixture(), item = try f.create(), destination = f.root.appendingPathComponent("Exports"); try secureDirectory(destination)
            try rejects("отменено") { _ = try DeviceBackups.export(item, to: destination, cancelled: {true}) }
            try check(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Partial export")
        }
        test("insufficient local space rejects before transfer and removes staging") {
            let f = try Fixture()
            let manager = DeviceBackups(engine: f.engine, streamer: f.stream, spaceAvailable: { _ in 0 })
            try rejects("Недостаточно") { _ = try f.engine.locked { try manager.create(.configuration) } }
            try check(f.stream.calls == 0, "Stream started without disk space"); try f.noCopies()
        }
        test("bundled public reader is accepted only when its pinned hash matches") {
            let f = try Fixture(), source = f.engine.resources.appendingPathComponent("DeviceBackups/reader.sh")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
            _ = try f.create()
            try savePrivate(Data("tampered".utf8), source)
            try rejects("Повреждён встроенный") { _ = try f.create() }
            try check(f.stream.calls == 1, "Modified resource executed")
        }
        test("unsafe storage or pending operation stops before stream") {
            let f = try Fixture(); try FileManager.default.createSymbolicLink(at: DeviceBackups.rootURL(f.root), withDestinationURL: f.root)
            try rejects("0700") { _ = try f.create() }; try check(f.stream.calls == 0, "Unsafe storage")
            try FileManager.default.removeItem(at: DeviceBackups.rootURL(f.root)); try savePrivate(Data(), f.root.appendingPathComponent("pending.json"))
            try rejects("незавершённую") { _ = try f.create() }; try check(f.stream.calls == 0, "Pending ignored")
        }
        print("RESULT \(passed) passed; \(failed) failed"); if failed != 0 { exit(1) }
    }
}
