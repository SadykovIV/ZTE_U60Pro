import Foundation
import Darwin

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case let .assertion(message): return message } }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.assertion(message) }
}

private func rejects(_ expected: String? = nil, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as TestFailure {
        throw error
    } catch {
        if let expected {
            try check(error.localizedDescription.contains(expected), "Unexpected rejection: \(error.localizedDescription); expected \(expected)")
        }
        return
    }
    throw TestFailure.assertion("Operation unexpectedly succeeded")
}

private final class TestSuite {
    var passed = 0
    var failed = 0
    func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
}

// These are synthetic 128-byte records with distinct tails, not data from a modem.
// The fixed BCD bytes encode the two known test IMEIs independently of IMEI.encode.
private func sampleRecords() -> [Data] {
    var first = Data(repeating: 0xa5, count: 128)
    var second = Data(repeating: 0x5a, count: 128)
    first.replaceSubrange(0..<9, with: [0x08, 0x3a, 0x35, 0x94, 0x00, 0x86, 0x07, 0x21, 0x22])
    second.replaceSubrange(0..<9, with: [0x08, 0x3a, 0x35, 0x94, 0x00, 0x86, 0x07, 0x21, 0x03])
    return [first, second]
}

private func syntheticConfig() -> Data {
    var data = Data(repeating: 0, count: 15073)
    data.put32(0, 0x78563412); data.put32(4, 249); data.put32(8, UInt32(data.count))
    var offset = 16
    for index in 0..<249 {
        let length = index < 4 ? 93 : index == 4 ? 95 : index == 5 ? 17 : index == 248 ? 15069 - offset : 16
        data.put32(offset, index == 5 ? 102 : UInt32(1000 + index))
        data.put32(offset + 4, UInt32(length)); data.put32(offset + 8, 0x18080820)
        offset += length
    }
    data.put32(data.count - 4, 0x21436587); data.put32(12, ConfigFile.crc(data))
    return data
}

private let testCID = "0123456789abcdef0123456789abcdef"
private let testBoot = "ee9f32b1-71f3-42df-b8fc-645f058b08b1"

/// Explicitly injected transport. It has no network implementation or Process invocation.
/// Unexpected commands fail closed. Persistent writes require an explicit test opt-in.
/// Uploads are scoped by remote path so a helper cannot accidentally consume an older plan.
private final class MockRemote: RemoteTransport {
    var cid = testCID
    var firmwareHash = ModemEngine.firmwareHash
    var routerHash = ModemEngine.routerHash
    var records = sampleRecords()
    var apiRecords: [Data]?
    let originalConfig: Data
    var config: Data
    var boot = testBoot
    var allowWrites = false
    var runtimeWriteGate = false
    var autoRestoreConfigOnBoot = true
    var cidAfterFirstReboot: String?
    var failAfterNVWriteOnce = false
    var uploads: [String: Data] = [:]
    var uploadedPlans: [Data] = []
    var nvApplyCalls = 0
    var configEnableCalls = 0
    var configRestoreCalls = 0
    var configCheckCalls = 0
    var observedAutomaticConfigRestore = false
    var commands: [String] = []
    var writeCommands: [String] = []
    var rebootCommands: [String] = []
    var snapshotCalls = 0
    var configReadCalls = 0

    init(config: Data) { self.originalConfig = config; self.config = config }

    private func output(_ text: String) -> CommandResult {
        CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data())
    }

    private func captures(_ pattern: String, _ text: String) throws -> [String]? {
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    private func executeHelper(_ path: String, mode: String, planPath: String) throws -> CommandResult {
        let expectedName: String
        switch mode {
        case "--snapshot", "--apply-plan": expectedName = "zte_nv"
        case "--read-config": expectedName = "zte_config_read"
        case "--enable-flag", "--restore-original-config", "--check-original": expectedName = "zte_config"
        default: throw TestFailure.assertion("Unknown helper mode")
        }
        try check(uploads[path] == Data(("MOCK RESOURCE " + expectedName).utf8), "Wrong or missing helper binary for mode")
        if mode == "--snapshot" {
            try check(planPath.isEmpty, "Snapshot unexpectedly has a plan")
            snapshotCalls += 1
            return output("APP_NV index=0 data=\(records[0].hex)\nAPP_NV index=1 data=\(records[1].hex)\n")
        }
        if mode == "--read-config" {
            try check(planPath.isEmpty, "Config read unexpectedly has a plan")
            configReadCalls += 1
            return output("EFS_DATA_HEX offset=0 length=\(config.count) data=\(config.hex)\nEFS_FILE_COMPLETE path=/config length=15073 released=1\n")
        }
        try check(planPath == String(path.dropLast("helper".count)) + "plan", "Plan and helper directories differ")
        guard let plan = uploads[planPath] else { throw TestFailure.assertion("Plan was not uploaded for this helper") }
        if mode == "--apply-plan" {
            try check(allowWrites, "Unexpected persistent write attempt")
            try check(runtimeWriteGate, "NV write attempted before boot applied config flag")
            try check(plan.count == 512, "NV plan length mismatch")
            let slices = (0..<4).map { Data(plan[($0 * 128)..<(($0 + 1) * 128)]) }
            try check(Array(slices.prefix(2)) == records, "NV plan baseline is not the current full records")
            for slot in 0...1 {
                try check(slices[slot].dropFirst(9) == slices[slot + 2].dropFirst(9), "Plan changes NV tail")
                _ = try IMEI.decode(slices[slot + 2])
            }
            try check(try IMEI.decode(slices[2]) != IMEI.decode(slices[3]), "Plan IMEIs are identical")
            records = Array(slices.suffix(2)); nvApplyCalls += 1
            if failAfterNVWriteOnce {
                failAfterNVWriteOnce = false
                return CommandResult(status: 71, stdout: Data("MOCK: pair written; acknowledgement lost\n".utf8), stderr: Data())
            }
            return output("APP_PAIR_VERIFIED 1\n")
        }
        try check(plan.count == 2 * originalConfig.count, "Config plan length mismatch")
        let original = Data(plan.prefix(originalConfig.count)), candidate = Data(plan.suffix(originalConfig.count))
        try check(original == originalConfig, "Config plan original mismatch")
        try check(try candidate == ConfigFile.candidate(originalConfig), "Config candidate changes unapproved bytes")
        try check(config == original || config == candidate, "Config state outside the allowed pair")
        switch mode {
        case "--enable-flag":
            try check(allowWrites, "Unexpected config enable")
            config = candidate; configEnableCalls += 1
        case "--restore-original-config":
            try check(allowWrites, "Unexpected config restore")
            config = original; configRestoreCalls += 1
        case "--check-original":
            try check(config == original, "Final config was not restored")
            configCheckCalls += 1
        default: throw TestFailure.assertion("Unexpected config mode")
        }
        return output("APP_CONFIG_VERIFIED 1\n")
    }

    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command.contains("device_reboot") {
            rebootCommands.append(command)
            try check(allowWrites, "Unexpected reboot attempt")
            runtimeWriteGate = try ConfigFile.validate(config) == 1
            if runtimeWriteGate && autoRestoreConfigOnBoot {
                config = originalConfig
                observedAutomaticConfigRestore = true
            }
            boot = UUID().uuidString.lowercased()
            if rebootCommands.count == 1, let cidAfterFirstReboot { cid = cidAfterFirstReboot }
            return output("{}\n")
        }
        if ["'--enable-flag'", "'--apply-plan'", "'--restore-original-config'"].contains(where: command.contains) {
            writeCommands.append(command)
            try check(allowWrites, "Unexpected persistent write attempt")
        }
        if command.hasPrefix("sha256sum /firmware/image/modem.b16 ") {
            return output("\(firmwareHash)  /firmware/image/modem.b16\n\(routerHash)  /usr/bin/diag-router\n\(cid)\n\(boot)\n")
        }
        if command.contains("/tmp/zte-imei-app.lock") { return output("") }
        if command.hasPrefix("umask 077; mkdir '/tmp/zte-imei-") { return output("") }
        if let paths = try captures("^umask 077; cat > '([^']+)'", command), let input {
            let path = paths[0]
            try check(path.hasPrefix("/tmp/zte-imei-") && !path.contains("/../"), "Unexpected upload location")
            try check(uploads[path] == nil, "Remote path reused")
            uploads[path] = input
            if path.hasSuffix("/plan") { uploadedPlans.append(input) }
            return output("\(digest(input))  \(path)\n")
        }
        if let paths = try captures("^rm -f '([^']+)' '([^']+)'; rmdir '([^']+)'$", command) {
            try check(paths[0] == paths[2] + "/helper" && paths[1] == paths[2] + "/plan", "Cleanup paths cross directories")
            uploads.removeValue(forKey: paths[0]); uploads.removeValue(forKey: paths[1])
            return output("")
        }
        if let arguments = try captures("^'(/tmp/zte-imei-[^']+/helper)' '([^']+)'(?: '([^']+/plan)')?$", command) {
            return try executeHelper(arguments[0], mode: arguments[1], planPath: arguments[2])
        }
        if command.hasPrefix("ubus call zwrt_zte_mdm.api get_imei") {
            let index = command.hasSuffix("get_imei2") ? 1 : 0
            return output("{\"imei\":\"\(try IMEI.decode((apiRecords ?? records)[index]))\"}\n")
        }
        throw TestFailure.assertion("Unrecognised mock command: \(command)")
    }

    func assertNoPersistentWrites() throws {
        try check(writeCommands.isEmpty, "Persistent write command was attempted")
        try check(rebootCommands.isEmpty, "A reboot was attempted")
    }
}

private final class EngineFixture {
    let directory: URL
    let engine: ModemEngine
    let remote: MockRemote
    let config: Data
    var connection = Connection(host: "192.0.2.1", port: "2222", keyPath: "/unused/mock-key", knownHostsPath: "/unused/mock-hosts")

    init(config: Data, skipFirmwareCheck: Bool = false) throws {
        self.config = config
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("zte-engine-tests-" + UUID().uuidString)
        try secureDirectory(directory)
        let resources = directory.appendingPathComponent("Resources")
        try secureDirectory(resources)
        var hashes: [String: String] = [:]
        for name in ["zte_nv", "zte_config", "zte_config_read"] {
            let bytes = Data(("MOCK RESOURCE " + name).utf8)
            try savePrivate(bytes, resources.appendingPathComponent(name))
            hashes[name] = digest(bytes)
        }
        try saveJSON(hashes, resources.appendingPathComponent("helpers.json"))
        remote = MockRemote(config: config)
        connection.skipFirmwareCheck = skipFirmwareCheck
        engine = try ModemEngine(root: directory.appendingPathComponent("AppData"), resources: resources, connection: connection, transport: remote)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func backup(records: [Data] = sampleRecords(), cid: String = testCID) throws -> URL {
        let id = UUID().uuidString.lowercased()
        let url = engine.backupsURL.appendingPathComponent(id)
        try secureDirectory(url)
        let files = ["nv0.bin": records[0], "nv1.bin": records[1], "config.bin": config]
        for (name, bytes) in files { try savePrivate(bytes, url.appendingPathComponent(name)) }
        let manifest = BackupManifest(id: id, created: "2026-01-01T00:00:00Z", identity: Identity(cid: cid, firmwareHash: ModemEngine.firmwareHash), imeis: try records.map(IMEI.decode), hashes: files.mapValues(digest))
        try saveJSON(manifest, url.appendingPathComponent("manifest.json"))
        return url
    }

    func transaction(backup: URL, desired: [Data], cid: String = testCID) throws {
        let transaction = Transaction(id: UUID().uuidString.lowercased(), backupID: backup.lastPathComponent,
            identity: Identity(cid: cid, firmwareHash: ModemEngine.firmwareHash), targetHex: desired.map(\.hex),
            connection: connection, phase: "prepared")
        try saveJSON(transaction, engine.pendingURL)
    }
}

@main
struct AppTests {
    static func main() throws {
        // No modem backup is needed: generate the default fixture in memory.
        // An explicitly supplied local fixture remains available for private verification.
        let config: Data
        if CommandLine.arguments.count == 2 { config = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) }
        else { config = syntheticConfig() }
        let tests = TestSuite()

        tests.run("Firmware override: session-only, absent from saved settings and journals") {
            var connection = Connection(host: "192.0.2.1", port: "2222", keyPath: "/a", knownHostsPath: "/b")
            try check(!connection.skipFirmwareCheck, "Override on by default")
            connection.skipFirmwareCheck = true
            let bytes = try JSONEncoder().encode(connection)
            try check(!String(decoding: bytes, as: UTF8.self).contains("skipFirmwareCheck"), "Risk consent persisted")
            try check(try !JSONDecoder().decode(Connection.self, from: bytes).skipFirmwareCheck, "Override restored")
            let malicious = Data(#"{"host":"192.0.2.1","port":"2222","keyPath":"/a","knownHostsPath":"/b","skipFirmwareCheck":true}"#.utf8)
            try check(try !JSONDecoder().decode(Connection.self, from: malicious).skipFirmwareCheck, "JSON enabled bypass")
        }
        tests.run("Firmware override: unknown valid hashes accepted and preserved in identity") {
            let fixture = try EngineFixture(config: config, skipFirmwareCheck: true)
            fixture.remote.firmwareHash = String(repeating: "a", count: 64)
            fixture.remote.routerHash = String(repeating: "b", count: 64)
            let state = try fixture.engine.locked { try fixture.engine.inspect() }
            try check(state.identity.firmwareHash == fixture.remote.firmwareHash, "Real firmware identity lost")
            try check(try ActivityJournal(root: fixture.engine.root).recent().contains { $0.category == "firmware" && $0.result == "warning" }, "Bypass missing from audit")
            let strict = try ModemEngine(root: fixture.engine.root, resources: fixture.engine.resources, connection: Connection(host:"192.0.2.1",port:"2222",keyPath:"/a",knownHostsPath:"/b"), transport:fixture.remote)
            try rejects("Прошивка отличается") { _ = try strict.identity() }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Firmware override: malformed hashes CID and boot still reject") {
            for choice in 0..<3 {
                let fixture = try EngineFixture(config: config, skipFirmwareCheck: true)
                if choice == 0 { fixture.remote.firmwareHash = "invalid" }
                if choice == 1 { fixture.remote.cid = "invalid" }
                if choice == 2 { fixture.remote.boot = "invalid" }
                try rejects { _ = try fixture.engine.locked { try fixture.engine.inspect() } }
                try fixture.remote.assertNoPersistentWrites()
            }
        }
        tests.run("Firmware override: IMEI transaction keeps actual identity over both reboots") {
            let fixture = try EngineFixture(config: config, skipFirmwareCheck: true)
            fixture.remote.firmwareHash = String(repeating: "a", count: 64)
            fixture.remote.allowWrites = true
            let result = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) }
            try check(result.identity.firmwareHash == fixture.remote.firmwareHash && fixture.remote.rebootCommands.count == 2, "Unsafe identity across reboots")
            let items = try FileManager.default.contentsOfDirectory(at: fixture.engine.backupsURL, includingPropertiesForKeys: nil)
            try check(items.count == 1 && (try fixture.engine.loadBackup(items[0])).0.identity == result.identity, "Missing fresh real-identity backup")
        }
        tests.run("Firmware override: malformed EFS still stops before any write") {
            let fixture = try EngineFixture(config: config, skipFirmwareCheck: true)
            fixture.remote.firmwareHash = String(repeating: "a", count: 64)
            fixture.remote.config[100] ^= 1
            try rejects { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("IMEI: known valid values and Luhn failure") {
            try check(IMEI.valid("353490068701222"), "Known first IMEI rejected")
            try check(IMEI.valid("353490068701230"), "Known second IMEI rejected")
            try check(!IMEI.valid("353490068701223"), "Bad check digit accepted")
        }
        tests.run("IMEI: ASCII only, exact length, no whitespace") {
            for value in ["٣٥٣٤٩٠٠٦٨٧٠١٢٢٢", "３５３４９００６８７０１２２２", "35349006870122", "3534900687012222", "353490068701222 ", " 353490068701222", "35349006870122x"] {
                try check(!IMEI.valid(value), "Invalid input accepted")
            }
        }
        tests.run("IMEI: derived second retains TAC and advances serial") {
            try check(try IMEI.second("353490068701222") == "353490068701230", "Wrong generated second IMEI")
        }
        tests.run("IMEI: second generation refuses serial overflow") {
            let base = "35349006" + "999999"
            guard let last = (0...9).map({ base + String($0) }).first(where: IMEI.valid) else { throw TestFailure.assertion("No valid final serial") }
            try rejects("999999") { _ = try IMEI.second(last) }
        }
        tests.run("NV: fixed independent BCD fixture decodes") {
            try check(try sampleRecords().map(IMEI.decode) == ["353490068701222", "353490068701230"], "BCD fixture decode failed")
        }
        tests.run("NV: encoding preserves every one of the 119 tail bytes") {
            let original = sampleRecords()[0]
            let changed = try IMEI.encode("353490068701230", preserving: original)
            try check(changed.count == 128 && changed.dropFirst(9) == original.dropFirst(9), "Tail or length changed")
            try check(changed.prefix(9) == sampleRecords()[1].prefix(9), "Encoded BCD is wrong")
        }
        tests.run("NV: malformed length, prefix and BCD reject") {
            try rejects { _ = try IMEI.decode(Data(repeating: 0, count: 127)) }
            var bad = sampleRecords()[0]; bad[0] = 9
            try rejects { _ = try IMEI.decode(bad) }
            bad = sampleRecords()[0]; bad[8] = 0xff
            try rejects { _ = try IMEI.decode(bad) }
            try rejects { _ = try IMEI.encode("353490068701223", preserving: sampleRecords()[0]) }
        }
        tests.run("Config: fixture matches independent golden SHA256") {
            // Synthetic goldens computed independently with Python struct/hashlib
            // and a bitwise CRC implementation; private fixture pin is opt-in.
            let expected = CommandLine.arguments.count == 2 ? "758b9b34e553409492f86dea6cb0e28e1e7fae6d6529a763711c7496e9130cc8" : "b8e2bc69cbef2881369d582b69b5b0676a2448ca505f17d1b7f6e8109beb6f59"
            try check(digest(config) == expected, "Fixture differs from the independent golden")
            try check(try ConfigFile.validate(config) == 0, "Original config flag is not zero")
        }
        tests.run("Config: candidate changes only flag and four CRC bytes") {
            let candidate = try ConfigFile.candidate(config)
            try check(try ConfigFile.validate(candidate) == 1, "Candidate flag not enabled")
            let changed = Set(config.indices.filter { config[$0] != candidate[$0] })
            try check(changed == Set([12, 13, 14, 15, 499]), "Unexpected config byte changes")
            let expected = CommandLine.arguments.count == 2 ? "785d188ced651895797daeeff3babc999c35780931d7d3fb32750e0d79130b72" : "afcd0ff768b51e41252d60e7806fea58498c281ecd564f52639caee01a988e4f"
            try check(digest(candidate) == expected, "Candidate differs from the independent golden")
            try rejects { _ = try ConfigFile.candidate(candidate) }
        }
        tests.run("Config: truncated and corrupt CRC reject") {
            try rejects { _ = try ConfigFile.validate(Data(config.dropLast())) }
            var bad = config; bad[600] ^= 1
            try rejects("CRC") { _ = try ConfigFile.validate(bad) }
        }
        tests.run("Config: missing, repeated, malformed ID102 reject with valid CRC") {
            var bad = config; bad.put32(483, 0xffff); bad.put32(12, ConfigFile.crc(bad))
            try rejects("config102") { _ = try ConfigFile.validate(bad) }
            bad = config; bad.put32(483, config.u32(16)); bad.put32(12, ConfigFile.crc(bad))
            try rejects("Повтор ID") { _ = try ConfigFile.validate(bad) }
            bad = config; bad[499] = 2; bad.put32(12, ConfigFile.crc(bad))
            try rejects("config102") { _ = try ConfigFile.validate(bad) }
            bad = config; bad.put32(495, 1); bad.put32(12, ConfigFile.crc(bad))
            try rejects("config102") { _ = try ConfigFile.validate(bad) }
        }
        tests.run("Config: oversized record and damaged trailer reject") {
            var bad = config; bad.put32(20, UInt32.max); bad.put32(12, ConfigFile.crc(bad))
            try rejects("запись config") { _ = try ConfigFile.validate(bad) }
            bad = config; bad[bad.count - 1] ^= 1; bad.put32(12, ConfigFile.crc(bad))
            try rejects("конец config") { _ = try ConfigFile.validate(bad) }
        }

        tests.run("Engine: pending diagnostic ADB blocks writes before any remote command") {
            let fixture = try EngineFixture(config: config)
            let pending = fixture.engine.root.appendingPathComponent("adb-access-pending.json")
            try savePrivate(Data("{\"intent\":\"diagnostic-adb\"}".utf8), pending)
            try rejects("включение ADB") {
                try fixture.engine.locked { try fixture.engine.acquireRemoteLock() }
            }
            try rejects("включение ADB") {
                _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) }
            }
            try check(fixture.remote.commands.isEmpty, "Pending ADB allowed a remote command")
            try check(FileManager.default.fileExists(atPath: pending.path), "Pending ADB journal was discarded")
            try check(!FileManager.default.fileExists(atPath: fixture.engine.tokenURL.path), "Pending ADB acquired a device lock")
        }
        tests.run("Engine: unknown firmware refuses before helpers or writes") {
            let fixture = try EngineFixture(config: config)
            fixture.remote.firmwareHash = String(repeating: "0", count: 64)
            try rejects("Прошивка отличается") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) } }
            try check(fixture.remote.snapshotCalls == 0, "A helper ran on unknown firmware")
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: invalid target IMEI refuses before config write") {
            let fixture = try EngineFixture(config: config)
            try rejects("контрольную цифру") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701223", "353490068701230"]) } }
            try fixture.remote.assertNoPersistentWrites()
            try check(!FileManager.default.fileExists(atPath: fixture.engine.pendingURL.path), "Invalid request created pending transaction")
        }
        tests.run("Engine: duplicate input IMEIs refuse before writes") {
            let fixture = try EngineFixture(config: config)
            try rejects("два разных IMEI") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701222", "353490068701222"]) } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: malformed NV snapshot refuses before writes") {
            let fixture = try EngineFixture(config: config)
            fixture.remote.records[0][0] = 0
            try rejects("Неизвестный формат NV550") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: API and NV disagreement refuses before writes") {
            let fixture = try EngineFixture(config: config)
            fixture.remote.apiRecords = [sampleRecords()[1], sampleRecords()[0]]
            try rejects("API и NV отличаются") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: corrupt backup hash refuses before writes") {
            let fixture = try EngineFixture(config: config), backup = try fixture.backup()
            var damaged = sampleRecords()[0]; damaged[90] ^= 1
            try savePrivate(damaged, backup.appendingPathComponent("nv0.bin"))
            try rejects("Повреждён бэкап") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: nil, restore: backup) } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: backup for different eMMC CID refuses before writes") {
            let fixture = try EngineFixture(config: config), backup = try fixture.backup(cid: String(repeating: "f", count: 32))
            try rejects("другому модему") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: nil, restore: backup) } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: unknown current NV during resume refuses before writes") {
            let fixture = try EngineFixture(config: config), backup = try fixture.backup()
            let originals = sampleRecords()
            let desired = [try IMEI.encode("353490068701230", preserving: originals[0]), try IMEI.encode("353490068701248", preserving: originals[1])]
            try fixture.transaction(backup: backup, desired: desired)
            fixture.remote.records[0] = try IMEI.encode("353490068701248", preserving: originals[0])
            try rejects("ни с исходным, ни с целевым") { _ = try fixture.engine.locked { try fixture.engine.resume() } }
            try fixture.remote.assertNoPersistentWrites()
            try check(FileManager.default.fileExists(atPath: fixture.engine.pendingURL.path), "Rejected resume discarded the recovery journal")
        }
        tests.run("Engine: same IMEI with different NV tails is refused in journal") {
            let fixture = try EngineFixture(config: config), backup = try fixture.backup()
            let desired = try sampleRecords().map { try IMEI.encode("353490068701248", preserving: $0) }
            try check(desired[0] != desired[1], "Fixture does not exercise distinct tails")
            try fixture.transaction(backup: backup, desired: desired)
            try rejects("одинаковые IMEI") { _ = try fixture.engine.locked { try fixture.engine.resume() } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: unknown tail changes in journal refuse before writes") {
            let fixture = try EngineFixture(config: config), backup = try fixture.backup()
            var desired = sampleRecords(); desired[1][100] ^= 1
            try fixture.transaction(backup: backup, desired: desired)
            try rejects("посторонние байты NV") { _ = try fixture.engine.locked { try fixture.engine.resume() } }
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: wrong connected CID refuses resume before helpers") {
            let fixture = try EngineFixture(config: config), backup = try fixture.backup()
            try fixture.transaction(backup: backup, desired: sampleRecords())
            fixture.remote.cid = String(repeating: "a", count: 32)
            try rejects("другой модем") { _ = try fixture.engine.locked { try fixture.engine.resume() } }
            try check(fixture.remote.snapshotCalls == 0, "NV helper ran on different modem")
            try fixture.remote.assertNoPersistentWrites()
        }
        tests.run("Engine: tampered helper rejects before upload") {
            let fixture = try EngineFixture(config: config)
            try savePrivate(Data("corrupt helper".utf8), fixture.engine.resources.appendingPathComponent("zte_nv"))
            try rejects("Повреждён встроенный инструмент") { _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) } }
            try check(!fixture.remote.commands.contains { $0.hasPrefix("umask 077; cat > ") }, "Corrupt helper uploaded")
            try fixture.remote.assertNoPersistentWrites()
        }

        tests.run("Engine: failed mandatory backup stops before any persistent write") {
            let fixture = try EngineFixture(config: config)
            try FileManager.default.removeItem(at: fixture.engine.backupsURL)
            try savePrivate(Data("blocked backup destination".utf8), fixture.engine.backupsURL)
            try rejects {
                _ = try fixture.engine.locked {
                    try fixture.engine.begin(targets: ["353490068701230", "353490068701248"])
                }
            }
            try fixture.remote.assertNoPersistentWrites()
            try check(fixture.remote.configEnableCalls == 0 && fixture.remote.nvApplyCalls == 0, "Write occurred before backup succeeded")
            try check(!FileManager.default.fileExists(atPath: fixture.engine.pendingURL.path), "Failed backup created a resumable write journal")
        }

        tests.run("Engine: full pair workflow, automatic config restore and two reboots") {
            let fixture = try EngineFixture(config: config)
            fixture.remote.allowWrites = true
            let targets = ["353490068701230", "353490068701248"]
            let expectedRecords = try zip(targets, sampleRecords()).map { try IMEI.encode($0.0, preserving: $0.1) }
            let final = try fixture.engine.locked { try fixture.engine.begin(targets: targets) }
            try check(final.records == expectedRecords && final.imeis == targets, "Final full records or IMEI pair mismatch")
            try check(final.boot != testBoot && final.boot == fixture.remote.boot, "Final boot not verified")
            try check(fixture.remote.rebootCommands.count == 2, "Workflow did not perform exactly two reboots")
            try check(fixture.remote.nvApplyCalls == 1, "Pair was written more or fewer than once")
            try check(fixture.remote.configEnableCalls == 1 && fixture.remote.configRestoreCalls == 1 && fixture.remote.configCheckCalls == 1, "Config sequence incomplete")
            try check(fixture.remote.observedAutomaticConfigRestore, "Mock did not exercise B31 automatic config restoration")
            try check(fixture.remote.config == config && !fixture.remote.runtimeWriteGate, "Final boot did not load original protection state")
            try check(fixture.remote.uploads.isEmpty, "Uploaded helper or plan was not cleaned up")
            try check(!FileManager.default.fileExists(atPath: fixture.engine.pendingURL.path), "Successful transaction still pending")
            let completed = try readJSON(Transaction.self, fixture.engine.logDirectory.appendingPathComponent("completed.json"))
            try check(completed.completed && completed.phase == "complete", "Completion receipt missing")
            let backupURL = fixture.engine.backupsURL.appendingPathComponent(completed.backupID)
            let (_, backedUp, backedUpConfig) = try fixture.engine.loadBackup(backupURL)
            try check(backedUp == sampleRecords() && backedUpConfig == config, "Backup did not preserve pre-write records")
            let result = try readJSON([String: String].self, fixture.engine.logDirectory.appendingPathComponent("result.json"))
            try check(result["imei1"] == targets[0] && result["imei2"] == targets[1] && result["bootID"] == final.boot, "Result receipt mismatch")
        }
        tests.run("Engine: lost acknowledgement after NV write resumes without another NV write") {
            let fixture = try EngineFixture(config: config)
            fixture.remote.allowWrites = true
            fixture.remote.failAfterNVWriteOnce = true
            let targets = ["353490068701230", "353490068701248"]
            try rejects("Инструмент zte_nv остановился") {
                _ = try fixture.engine.locked { try fixture.engine.begin(targets: targets) }
            }
            try check(fixture.remote.nvApplyCalls == 1 && fixture.remote.rebootCommands.count == 1, "Interruption did not occur after first write")
            try check(FileManager.default.fileExists(atPath: fixture.engine.pendingURL.path), "Interruption lost durable journal")
            let interrupted = try readJSON(Transaction.self, fixture.engine.pendingURL)
            try check(interrupted.phase == "writing" && !interrupted.completed, "Unexpected interrupted phase")
            // A fresh engine instance represents reopening the application after process loss.
            let reopened = try ModemEngine(root: fixture.engine.root, resources: fixture.engine.resources,
                connection: fixture.connection, transport: fixture.remote)
            let final = try reopened.locked { try reopened.resume() }
            try check(final.imeis == targets, "Resumed final pair mismatch")
            try check(fixture.remote.nvApplyCalls == 1 && fixture.remote.configEnableCalls == 1, "Resume repeated NV write or permission enable")
            try check(fixture.remote.rebootCommands.count == 2, "Resume did not perform exactly one remaining reboot")
            try check(fixture.remote.config == config && !fixture.remote.runtimeWriteGate, "Resume did not finish original protection boot")
            try check(fixture.remote.uploads.isEmpty, "Resume left temporary remote payloads")
            try check(!FileManager.default.fileExists(atPath: reopened.pendingURL.path), "Completed resume still pending")
        }
        tests.run("Engine: device CID changes after reboot, no NV or follow-up config write") {
            let fixture = try EngineFixture(config: config)
            fixture.remote.allowWrites = true
            fixture.remote.cidAfterFirstReboot = String(repeating: "f", count: 32)
            try rejects("После перезагрузки подключён другой модем") {
                _ = try fixture.engine.locked { try fixture.engine.begin(targets: ["353490068701230", "353490068701248"]) }
            }
            try check(fixture.remote.rebootCommands.count == 1, "Wrong device caused a second reboot")
            try check(fixture.remote.configEnableCalls == 1 && fixture.remote.nvApplyCalls == 0 && fixture.remote.configRestoreCalls == 0, "A write was sent after CID mismatch")
            try check(fixture.remote.writeCommands.count == 1, "Unexpected additional write helper invocation")
            try check(fixture.remote.records == sampleRecords(), "NV changed on wrong device")
            try check(FileManager.default.fileExists(atPath: fixture.engine.pendingURL.path), "CID mismatch lost recovery journal")
        }

        print("RESULT passed=\(tests.passed) failed=\(tests.failed) network=mock-only")
        if tests.failed != 0 { exit(1) }
    }
}
