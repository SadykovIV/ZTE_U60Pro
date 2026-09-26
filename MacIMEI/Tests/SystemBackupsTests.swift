import Foundation
import Darwin

private enum TestFailure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure.assertion(message) }
}
private func rejects(_ message: String = "", _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as TestFailure { throw error }
    catch { try check(message.isEmpty || error.localizedDescription.contains(message), "Expected \(message), got \(error.localizedDescription)"); return }
    throw TestFailure.assertion("Unexpected success")
}
private final class SystemMockRemote: RemoteTransport {
    var images: [String: Data] = ["mmcblk0": Data(repeating: 1, count: 1024), "mmcblk0boot0": Data(repeating: 2, count: 512), "mmcblk0boot1": Data(repeating: 3, count: 512)]
    var cid = "0123456789abcdef0123456789abcdef"
    var boot = "00112233-4455-6677-8899-aabbccddeeff"
    var layout = String(repeating: "a", count: 64)
    var offline = true
    var uploaded = Data()
    var writes = 0, relocks = 0, wholeHashes = 0
    var failWrite: Int?, badWholeHash = false
    var commands: [String] = []
    var helpers: [String: String] = [:]
    var helperUploads = 0
    var mutateAtHash: (() throws -> Void)?
    var inventory: SystemInventory {
        SystemInventory(schema: 1, cid: cid, bootID: boot, firmwareHash: ModemEngine.firmwareHash, layoutHash: layout, diskBytes: Int64(images["mmcblk0"]!.count), offline: offline, offlineReason: offline ? "OK" : "EMMC_MOUNTED", devices: SystemBackups.targetNames.map { SystemBackupDevice(name: $0, source: "/dev/" + $0, bytes: Int64(images[$0]!.count)) })
    }
    func reply(_ string: String) -> CommandResult { CommandResult(status: 0, stdout: Data(string.utf8), stderr: Data()) }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command == "cat /sys/block/mmcblk0/device/cid" { return reply(cid + "\n") }
        if command.hasPrefix("if test -e '") {
            let path = command.components(separatedBy: "'")[1]
            if let hash = helpers[path] { return reply("\(hash)  \(path)\n") }
            return reply("SYSTEM_HELPER_ABSENT\n")
        }
        if let input, let tail = command.components(separatedBy: "cat > '").dropFirst().first {
            let path = String(tail.prefix { $0 != "'" })
            if path.hasSuffix("chunk.bin") { uploaded = input }
            if path.hasSuffix("device.sh") { helpers[path] = digest(input); helperUploads += 1 }
            return reply("\(digest(input))  \(path)\n")
        }
        guard let call = command.components(separatedBy: "; sh ").dropFirst().first else { return reply("") }
        let parts = call.components(separatedBy: "'")
        let arguments = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
        let args = Array(arguments.dropFirst())
        switch args[0] {
        case "inventory", "preflight":
            if args[1] != "-" && args[1] != cid { return CommandResult(status: 1, stdout: Data(), stderr: Data("CID".utf8)) }
            if args[0] == "preflight" && (!offline || args[3] != boot || args[4] != layout) { return CommandResult(status: 1, stdout: Data(), stderr: Data("OFFLINE_REQUIRED".utf8)) }
            return CommandResult(status: 0, stdout: try JSONEncoder().encode(inventory), stderr: Data())
        case "relock": relocks += 1; return reply("SYSTEM_RELOCKED\n")
        case "hash-device":
            wholeHashes += 1
            let name = args[5], bytes = images[name]!
            return reply("SYSTEM_HASH target=\(name) bytes=\(bytes.count) sha256=\(badWholeHash ? String(repeating: "0", count: 64) : digest(bytes))\n")
        case "hash-chunk", "restore-chunk":
            let name = args[5], offset = Int(args[6])!, length = Int(args[7])!
            if args[0] == "restore-chunk" {
                try check(offline, "Write on live modem")
                try check(uploaded.count == length && digest(uploaded) == args[8] && length <= SystemBackups.chunkBytes, "Unverified upload")
                images[name]!.replaceSubrange(offset..<(offset + length), with: uploaded)
                writes += 1
                if writes == failWrite { throw IMEIError.message("lost SSH response") }
            } else if let action = mutateAtHash { mutateAtHash = nil; try action() }
            let data = images[name]!.subdata(in: offset..<(offset + length))
            return reply("RESTORE_RESULT target=\(name) offset=\(offset) bytes=\(length) sha256=\(digest(data))\n")
        default: throw TestFailure.assertion("Unknown helper mode \(args)")
        }
    }
    func changeImages() { for name in SystemBackups.targetNames { images[name] = Data(repeating: 99, count: images[name]!.count) } }
}
private final class SystemMockStream: BackupStreamTransport {
    let remote: SystemMockRemote
    var calls = 0, fail = false
    var truncateBytes = 0, appendBytes = 0, claimExpectedSize = false, wrongHash = false
    var beforeCapture: (() throws -> Void)?
    init(_ remote: SystemMockRemote) { self.remote = remote }
    func stream(_ command: String, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        calls += 1
        if calls == 4 { try beforeCapture?() }
        try DeviceBackups.checkCancelled(cancelled)
        let target = String(destination.lastPathComponent.dropLast(4))
        var data = remote.images[target]!
        if truncateBytes > 0 { data.removeLast(min(truncateBytes, data.count)) }
        if appendBytes > 0 { data.append(Data(repeating: 0, count: appendBytes)) }
        let output = try DeviceBackups.createFile(destination)
        defer { try? output.close() }
        try output.write(contentsOf: data); try output.synchronize()
        if fail { throw IMEIError.message("capture interrupted") }
        return BackupStreamResult(sha256: wrongHash ? String(repeating: "0", count: 64) : digest(data), bytes: claimExpectedSize ? maxBytes : Int64(data.count))
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine, remote: SystemMockRemote, stream: SystemMockStream
    var manager: SystemBackups { SystemBackups(engine: engine, streamer: stream) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-system-tests-" + UUID().uuidString.lowercased())
        try secureDirectory(root)
        let resources = root.appendingPathComponent("Resources")
        try secureDirectory(resources); try secureDirectory(resources.appendingPathComponent("SystemBackups"))
        let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/SystemBackups/device.sh")
        try savePrivate(Data(contentsOf: bundled), resources.appendingPathComponent("SystemBackups/device.sh"))
        for name in ["key", "hosts"] { try savePrivate(Data("fixture".utf8), root.appendingPathComponent(name)) }
        remote = SystemMockRemote(); stream = SystemMockStream(remote)
        let connection = Connection(host: "192.0.2.1", port: "2222", keyPath: root.appendingPathComponent("key").path, knownHostsPath: root.appendingPathComponent("hosts").path)
        engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: remote)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func create() throws -> SystemBackupItem { try engine.locked { try manager.create() } }
    func prepare(_ item: SystemBackupItem) throws -> SystemRestorePlan { try engine.locked { try manager.prepareRestore(item) } }
    func restore(_ plan: SystemRestorePlan, allowLive: Bool = false) throws -> SystemRestoreResult { try engine.locked { try manager.restore(plan, allowLiveCapture: allowLive) } }
    func journal(_ plan: SystemRestorePlan) throws -> SystemRestoreTransaction {
        try JSONDecoder().decode(SystemRestoreTransaction.self, from: DeviceBackups.smallFile(root.appendingPathComponent("SystemRestoreTransactions/" + plan.id + ".json"), maximum: 2_097_152))
    }
}
@main struct SystemBackupsTests {
    static func main() throws {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        test("new installation has an empty full backup list") {
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try check(try SystemBackups.list(root: missing).isEmpty, "Expected empty list")
        }
        test("full snapshot includes three verified private images and chunk hashes") {
            let f = try Fixture(), item = try f.create()
            try check(item.bytes == 2048 && !item.isLiveCapture && f.remote.writes == 0, "Wrong snapshot")
            try check(try SystemBackups.list(root: f.root).count == 1, "Missing snapshot")
            let m = try SystemBackups.manifest(at: item.url)
            try check(m.chunks.count == 3 && m.files.count == 3 && m.scope.contains("RPMB"), "Coverage or chunk metadata")
            _ = try SystemBackups.verify(item)
            for file in m.files { try check(try DeviceBackups.metadata(item.url.appendingPathComponent(file.name)).st_mode & 0o777 == 0o600, "Private permissions") }
        }
        test("catalog reports a corrupt manifest while retaining valid backups") {
            let f = try Fixture(), valid = try f.create(), invalid = try f.create()
            try savePrivate(Data("invalid JSON".utf8), invalid.url.appendingPathComponent("manifest.json"))
            var rejected: [(String, String)] = []
            let items = try SystemBackups.list(root: f.root, onInvalid: { rejected.append(($0, $1)) })
            try check(items.map(\.id) == [valid.id], "Valid backup hidden or invalid one accepted")
            try check(rejected.count == 1 && rejected[0].0 == invalid.id && !rejected[0].1.isEmpty, "Missing rejected backup diagnostic")
            try rejects { _ = try SystemBackups.verify(invalid) }
            try rejects { _ = try f.prepare(invalid) }
            try check(f.remote.writes == 0, "Invalid catalog entry was restored")
        }
        test("stream failure and insufficient storage cannot publish") {
            let f = try Fixture(); f.stream.fail = true
            try rejects("capture interrupted") { _ = try f.create() }
            try check(try SystemBackups.list(root: f.root).isEmpty, "Published incomplete snapshot")
            f.stream.fail = false
            let noSpace = SystemBackups(engine: f.engine, streamer: f.stream, spaceAvailable: { _ in 0 })
            try rejects("Недостаточно") { _ = try f.engine.locked { try noSpace.create() } }
            try check(f.stream.calls == 1, "Read began without space")
        }
        test("truncated oversized and wrong-hash streams cannot publish even with a full-size receipt") {
            for kind in 0..<3 {
                let f = try Fixture()
                f.stream.claimExpectedSize = true
                if kind == 0 { f.stream.truncateBytes = 512 }
                if kind == 1 { f.stream.appendBytes = 512 }
                if kind == 2 { f.stream.wrongHash = true }
                try rejects { _ = try f.create() }
                try check(try SystemBackups.list(root: f.root).isEmpty, "Invalid stream published")
                let entries = try FileManager.default.contentsOfDirectory(atPath: SystemBackups.rootURL(f.root).path)
                try check(entries.isEmpty && f.remote.writes == 0, "Partial image retained or device written")
                let events = try ActivityJournal(root: f.root).recent()
                try check(events.contains { $0.category == "system-backup" && $0.result == "failed" && $0.details["expectedBytes"] == "1024" && $0.details["receivedBytes"] != nil }, "Missing failed byte counts")
            }
        }
        test("full image receipt and geometry preserve sizes beyond a 32-bit counter") {
            let bytes: Int64 = 7_755_268_096
            let receipt = try SSHBackupStreamTransport.parseReceipt("BACKUP_RESULT sha256=\(String(repeating: "a", count: 64)) bytes=\(bytes)\n")
            try check(receipt.bytes == bytes && receipt.bytes > Int64(UInt32.max), "Receipt truncated")
            let f = try Fixture()
            var inventory = f.remote.inventory
            inventory.diskBytes = bytes; inventory.devices[0].bytes = bytes
            try SystemBackups.validate(inventory)
            let encoded = try JSONEncoder().encode(inventory)
            let decoded = try JSONDecoder().decode(SystemInventory.self, from: encoded)
            try check(decoded.diskBytes == bytes && decoded.totalBytes == bytes + 1024, "Geometry truncated")
        }
        test("import export enforce verified private files without overwriting") {
            let f = try Fixture(), item = try f.create(), destination = f.root.appendingPathComponent("Export")
            try secureDirectory(destination)
            let exported = try SystemBackups.export(item, to: destination)
            let another = f.root.appendingPathComponent("Another"); try secureDirectory(another)
            let imported = try SystemBackups.importBackup(from: exported, root: another)
            try check(imported.id == item.id, "Import identity")
            try rejects("уже существует") { _ = try SystemBackups.importBackup(from: exported, root: another) }
            try FileManager.default.removeItem(at: exported.appendingPathComponent("mmcblk0.bin"))
            try FileManager.default.createSymbolicLink(at: exported.appendingPathComponent("mmcblk0.bin"), withDestinationURL: item.url.appendingPathComponent("mmcblk0.bin"))
            try rejects("ссылкой") { _ = try SystemBackups.importBackup(from: exported, root: another) }
        }
        test("manifest traversal malformed layout and unknown file cannot restore") {
            let f = try Fixture(), item = try f.create()
            var m = try SystemBackups.manifest(at: item.url); m.files[0].name = "../key"
            try saveJSON(m, item.url.appendingPathComponent("manifest.json"))
            try rejects("состав") { _ = try f.prepare(item) }
            try check(f.remote.writes == 0, "Write before validation")
            var inventory = f.remote.inventory; inventory.devices[0].source = "/dev/other"
            try rejects("путь") { try SystemBackups.validate(inventory) }
        }
        test("CID and layout mismatch are rejected before any write") {
            let f = try Fixture(), item = try f.create()
            f.remote.cid = String(repeating: "f", count: 32)
            try rejects { _ = try f.prepare(item) }
            f.remote.cid = item.inventory.cid; f.remote.layout = String(repeating: "b", count: 64)
            try rejects("разметка") { _ = try f.prepare(item) }
            try check(f.remote.writes == 0, "Mismatched device written")
        }
        test("live plan remains reviewable but restore refuses offline gate") {
            let f = try Fixture(); f.remote.offline = false
            let item = try f.create(), plan = try f.prepare(item)
            try check(!plan.canRestore && plan.requiresLiveCaptureAcknowledgement, "Live capture mislabelled")
            try rejects("Подтвердите") { _ = try f.restore(plan) }
            try rejects("OFFLINE_REQUIRED") { _ = try f.restore(plan, allowLive: true) }
            try check(f.remote.writes == 0 && f.stream.calls == 3, "Unsafe restore")
        }
        test("restore makes fresh before copy and independently hashes all devices") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages()
            let plan = try f.prepare(item), result = try f.restore(plan)
            try check(f.stream.calls == 6 && result.beforeBackupID != item.id, "Missing before snapshot")
            try check(f.remote.writes == 3 && f.remote.wholeHashes == 3 && f.remote.relocks >= 4, "Incomplete verification")
            try check(!SystemBackups.hasPendingRestore(root: f.root), "Pending not cleared")
            try check(try f.journal(plan).complete, "Journal incomplete")
            try check(f.remote.images["mmcblk0"] == Data(repeating: 1, count: 1024), "Wrong device content")
        }
        test("all source hashes are checked before before-snapshot or write") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages()
            let plan = try f.prepare(item)
            try savePrivate(Data(repeating: 17, count: 512), item.url.appendingPathComponent("mmcblk0boot1.bin"))
            try rejects("Повреждён") { _ = try f.restore(plan) }
            try check(f.remote.writes == 0 && f.stream.calls == 3, "Partial write before full source validation")
        }
        test("source mutation after validation is rejected before affected chunk") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages()
            let plan = try f.prepare(item)
            f.stream.beforeCapture = { try savePrivate(Data(repeating: 18, count: 1024), item.url.appendingPathComponent("mmcblk0.bin")) }
            try rejects("Исходный блок изменился") { _ = try f.restore(plan) }
            try check(f.remote.writes == 0 && SystemBackups.hasPendingRestore(root: f.root), "Mutation was written or journal missing")
        }
        test("lost receipt retains journal and resumes without duplicate writes or new before copy") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages(); f.remote.failWrite = 2
            let plan = try f.prepare(item)
            try rejects("lost SSH") { _ = try f.restore(plan) }
            try check(try f.journal(plan).chunks.count == 1, "Unacknowledged offset persisted")
            try check(SystemBackups.hasPendingRestore(root: f.root), "No pending journal")
            f.remote.failWrite = nil
            let helperUploads = f.remote.helperUploads
            let resumed = try f.prepare(item)
            try check(resumed.isResume && resumed.id == plan.id, "Wrong resume plan")
            let result = try f.restore(resumed)
            try check(result.resumed && f.remote.writes == 3 && f.stream.calls == 6, "Blind rewrite or fresh before copy on resume")
            try check(f.remote.helperUploads == helperUploads, "Existing pending helper was overwritten")
        }
        test("new recovery boot revalidates acknowledged prefix and preserves original before copy") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages(); f.remote.failWrite = 2
            let plan = try f.prepare(item)
            try rejects { _ = try f.restore(plan) }
            let original = try f.journal(plan).beforeBackupID
            f.remote.failWrite = nil; f.remote.boot = "e7d85c31-7c1a-43dc-9e72-0fd40ca78f77"
            let resumed = try f.prepare(item), result = try f.restore(resumed)
            try check(result.beforeBackupID == original && f.stream.calls == 6, "Lost original rollback snapshot")
            try check(try f.journal(plan).previousBootIDs == [item.inventory.bootID], "Missing recovery boot history")
        }
        test("changed acknowledged prefix refuses resume on new boot") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages(); f.remote.failWrite = 2
            let plan = try f.prepare(item)
            try rejects { _ = try f.restore(plan) }
            f.remote.failWrite = nil; f.remote.boot = "e7d85c31-7c1a-43dc-9e72-0fd40ca78f77"; f.remote.images["mmcblk0"]![0] = 8
            let resumed = try f.prepare(item)
            try rejects("ручное восстановление") { _ = try f.restore(resumed) }
            try check(f.remote.writes == 2 && SystemBackups.hasPendingRestore(root: f.root), "Changed prefix overwritten")
        }
        test("source corruption during pending recovery still relocks protection") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages(); f.remote.failWrite = 1
            let plan = try f.prepare(item)
            try rejects { _ = try f.restore(plan) }
            let relocks = f.remote.relocks
            try savePrivate(Data(repeating: 19, count: 1024), item.url.appendingPathComponent("mmcblk0.bin"))
            try rejects("Повреждён") { _ = try f.prepare(item) }
            try check(f.remote.relocks > relocks && f.remote.writes == 1, "Protection not restored before corrupted source rejection")
        }
        test("final whole-device mismatch retains recoverable pending state") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages(); f.remote.badWholeHash = true
            let plan = try f.prepare(item)
            try rejects("Итоговая SHA256") { _ = try f.restore(plan) }
            try check(SystemBackups.hasPendingRestore(root: f.root) && !(try f.journal(plan).complete), "Premature success")
            f.remote.badWholeHash = false
            _ = try f.restore(f.prepare(item))
            try check(f.remote.writes == 3, "Already verified bytes rewritten")
        }
        test("pending recovery endpoint migration retains token and requires same physical CID") {
            let f = try Fixture(), item = try f.create(); f.remote.changeImages(); f.remote.failWrite = 1
            let plan = try f.prepare(item)
            try rejects { _ = try f.restore(plan) }
            let token = "00112233-4455-6677-8899-aabbccddeeff", foreign = "192.0.2.2:2222"
            try saveJSON(["endpoint": foreign, "token": token], f.engine.tokenURL)
            f.remote.cid = String(repeating: "f", count: 32)
            try rejects("другому модему") { _ = try f.prepare(item) }
            var saved = try readJSON([String: String].self, f.engine.tokenURL)
            try check(saved["endpoint"] == foreign && saved["token"] == token, "Wrong device changed lock")
            f.remote.cid = item.inventory.cid
            _ = try f.prepare(item)
            saved = try readJSON([String: String].self, f.engine.tokenURL)
            try check(saved["endpoint"] == "192.0.2.1:2222" && saved["token"] == token, "Lost owner token during migration")
        }
        test("receipt refuses ambiguity oversized or unaligned blocks") {
            let hash = String(repeating: "a", count: 64)
            let good = "RESTORE_RESULT target=mmcblk0 offset=0 bytes=512 sha256=\(hash)"
            try check(try SystemBackups.parseChunkReceipt(Data(good.utf8)).bytes == 512, "Receipt")
            for bad in [good + "\n" + good, good.replacingOccurrences(of: "offset=0", with: "offset=1"), good.replacingOccurrences(of: "bytes=512", with: "bytes=9000000"), good.replacingOccurrences(of: "mmcblk0", with: "../../disk") ] {
                try rejects { _ = try SystemBackups.parseChunkReceipt(Data(bad.utf8)) }
            }
        }
        print("RESULT \(passed) passed; \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
