import Foundation
import Darwin

private enum Failure: Error { case check(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.check(message) }
}
private func rejects(_ contains: String, _ body: () throws -> Void) throws {
    do { try body() } catch let e as Failure { throw e } catch {
        try check(error.localizedDescription.contains(contains), "Unexpected rejection: \(error.localizedDescription)"); return
    }
    throw Failure.check("Expected rejection containing \(contains)")
}

private final class MockTTL: RemoteTransport {
    var commands = [String](), invocations = [[String]](), uploaded = [String: Data]()
    var managerHash = TTLSettingsManager.resourceHashes["manager.sh"]!
    var failUpgrade = false
    var installed = false, locked = false, cleaned = false, stage = ""
    var configuration = TTLConfiguration.disabled
    var capability = "supported", stateOverride: String?, persistenceOverride: String?
    var firmwareHash = ModemEngine.firmwareHash
    var badFirmware = false, badUpload = false, wrongUploadPath = false, badManager = false
    var failMutation = false, loseAcknowledgement = false, wrongResult = false
    var identityCalls = 0, changeIdentityAt = 0
    let cid = String(repeating: "a", count: 32)

    func reply(_ text: String, code: Int32 = 0) -> CommandResult {
        CommandResult(status: code, stdout: code == 0 ? Data(text.utf8) : Data(), stderr: code == 0 ? Data() : Data(text.utf8))
    }
    func status() -> CommandResult {
        let state = stateOverride ?? (configuration.isDisabled ? "disabled" : capability == "supported" ? "configured" : "error")
        let verification = configuration.isDisabled ? "not-applicable" : "unverified"
        let persistence = persistenceOverride ?? (installed ? "boot" : "none")
        return reply("TTL_STATUS state=\(state) outbound=\(configuration.outbound.map(String.init) ?? "off") inbound_inc=\(configuration.inboundIncrement.map(String.init) ?? "off") capability=\(capability) verification=\(verification) persistence=\(persistence)\n")
    }
    func quotedValues(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "'([^']*)'")
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range(at: 1), in: value)!])
        }
    }
    func invoke(_ arguments: [String], staged: Bool) throws -> CommandResult {
        invocations.append(arguments)
        guard let action = arguments.first else { throw Failure.check("No action") }
        if action == "status" {
            try check(arguments == ["status", cid], "Unsafe status arguments")
            return status()
        }
        try check(locked, "Mutation without shared remote lock")
        if failMutation { return reply("TTL_ERROR TEST_FAILURE", code: 1) }
        if action == "upgrade" {
            try check(staged && arguments == ["upgrade", stage, cid], "Unexpected upgrade")
            if failUpgrade { return reply("TTL_ERROR UPGRADE_PENDING", code: 1) }
            managerHash = TTLSettingsManager.resourceHashes["manager.sh"]!
            return status()
        }
        if action == "disable" {
            try check(!staged && arguments == ["disable", cid], "Disable not independent of capability")
            configuration = .disabled
        } else {
            let values: [String]
            if action == "install" {
                try check(staged && arguments.count == 5 && arguments[1] == stage && arguments[2] == cid && uploaded.count == 4, "Incomplete install or wrong device")
                values = Array(arguments.suffix(2)); installed = true
            } else {
                try check(action == "apply" && !staged && arguments.count == 4 && arguments[1] == cid, "Unexpected apply arguments")
                values = Array(arguments.suffix(2))
            }
            configuration = TTLConfiguration(outbound: values[0] == "off" ? nil : Int(values[0]), inboundIncrement: values[1] == "off" ? nil : Int(values[1]))
            try configuration.validate()
        }
        if wrongResult { configuration = TTLConfiguration(outbound: 99, inboundIncrement: nil) }
        if loseAcknowledgement { return reply("SSH acknowledgement lost", code: 255) }
        return status()
    }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command == TTLSettingsManager.installedManagerHashCommand { return reply(managerHash) }
        if command == AccessIdentity.command {
            identityCalls += 1
            let actualCID = changeIdentityAt > 0 && identityCalls >= changeIdentityAt ? String(repeating: "b", count: 32) : cid
            return reply((badFirmware ? String(repeating: "0", count: 64) : firmwareHash) + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + actualCID + "\n12345678-1234-1234-1234-123456789abc\n")
        }
        if command.contains("if mkdir /tmp/zte-imei-app.lock") { locked = true; return reply("") }
        if command.contains("&& rm /tmp/zte-imei-app.lock/owner") { locked = false; return reply("") }
        if command == "if test -e /data/zte-imei-ttl || test -L /data/zte-imei-ttl; then printf installed; else printf absent; fi" { return reply(installed ? "installed" : "absent") }
        if command.contains("sh /data/zte-imei-ttl/manager.sh ") {
            try check(command.contains("test ! -L") && command.contains("0$mode & 022") && command.contains(TTLSettingsManager.resourceHashes["manager.sh"]!), "Unverified installed manager")
            if badManager { return reply("manager hash mismatch", code: 1) }
            let suffix = command.components(separatedBy: "sh /data/zte-imei-ttl/manager.sh ")[1]
            return try invoke(quotedValues(suffix), staged: false)
        }
        if command.hasPrefix("umask 077; mkdir '/tmp/zte-imei-ttl-") {
            try check(stage.isEmpty, "Stage reused")
            stage = quotedValues(command)[0]; return reply("")
        }
        if command.hasPrefix("umask 077; cat > '/tmp/zte-imei-ttl-") {
            let path = quotedValues(command)[0]
            try check(!stage.isEmpty && path.hasPrefix(stage + "/") && input != nil, "Upload outside owned stage")
            uploaded[URL(fileURLWithPath: path).lastPathComponent] = input!
            return reply((badUpload ? String(repeating: "0", count: 64) : digest(input!)) + "  " + (wrongUploadPath ? "/tmp/wrong-file" : path) + "\n")
        }
        if command.hasPrefix("sh '/tmp/zte-imei-ttl-") {
            let values = quotedValues(command)
            try check(values.first == stage + "/manager.sh" && uploaded.count == 4, "Unverified staged manager")
            return try invoke(Array(values.dropFirst()), staged: true)
        }
        if command.hasPrefix("rm -f '/tmp/zte-imei-ttl-") {
            try check(!stage.isEmpty && command.contains("; rmdir '" + stage + "'") && !command.contains("rm -rf"), "Unsafe cleanup")
            cleaned = true; return reply("")
        }
        throw Failure.check("Unexpected command: " + String(command.prefix(180)))
    }
}

@main struct TTLSettingsManagerTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zte-ttl-manager-tests-" + UUID().uuidString)
        try secureDirectory(testRoot); defer { try? FileManager.default.removeItem(at: testRoot) }
        let key = testRoot.appendingPathComponent("key"), hosts = testRoot.appendingPathComponent("hosts")
        try savePrivate(Data("test".utf8), key); try savePrivate(Data("test".utf8), hosts)
        let connection = Connection(host: "192.168.0.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path)
        var mocks = [MockTTL]()
        func manager(_ mock: MockTTL, resourceRoot: URL? = nil) throws -> TTLSettingsManager {
            mocks.append(mock)
            return TTLSettingsManager(engine: try ModemEngine(root: testRoot.appendingPathComponent(UUID().uuidString), resources: resourceRoot ?? resources, connection: connection, transport: mock))
        }
        func perform(_ manager: TTLSettingsManager, _ configuration: TTLConfiguration? = nil) throws -> TTLStatus {
            try manager.engine.locked { try manager.perform(configuration: configuration) }
        }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        test("absent status stages only read-only status and never applies defaults") {
            let mock = MockTTL(); let result = try perform(manager(mock))
            try check(result.configuration == .disabled && mock.invocations == [["status", mock.cid]] && !mock.installed && mock.cleaned, "Check installed or changed settings")
            try check(!mock.commands.contains { $0.contains("if mkdir /tmp/zte-imei-app.lock") }, "Status took configuration mutation lock")
        }
        test("installed status reads current SET and INC without staging or writes") {
            let mock = MockTTL(); mock.installed = true; mock.configuration = TTLConfiguration(outbound: 65, inboundIncrement: 3)
            let result = try perform(manager(mock))
            try check(result.configuration == mock.configuration && mock.stage.isEmpty && mock.invocations == [["status", mock.cid]], "Status altered configuration")
        }
        test("explicit install preserves outbound SET and inbound INC arguments") {
            let mock = MockTTL(), request = TTLConfiguration(outbound: 65, inboundIncrement: 2)
            let result = try perform(manager(mock), request)
            try check(result.configuration == request && mock.invocations == [["install", mock.stage, mock.cid, "65", "2"]], "Arguments changed or swapped")
            try check(mock.cleaned && mock.identityCalls == 2 && !mock.locked, "Missing identity recheck or lock cleanup")
        }
        test("independent directions pass off instead of inventing another value") {
            for request in [TTLConfiguration(outbound: 64, inboundIncrement: nil), TTLConfiguration(outbound: nil, inboundIncrement: 1)] {
                let mock = MockTTL(); mock.installed = true
                _ = try perform(manager(mock), request)
                try check(mock.invocations == [["apply", mock.cid, request.outbound.map(String.init) ?? "off", request.inboundIncrement.map(String.init) ?? "off"]], "Disabled direction gained a TTL value")
            }
        }
        test("disable uses dedicated command even when capability is unsupported") {
            let mock = MockTTL(); mock.installed = true; mock.capability = "unsupported"; mock.configuration = TTLConfiguration(outbound: 64, inboundIncrement: 1)
            let result = try perform(manager(mock), .disabled)
            try check(result.state == .disabled && mock.invocations == [["disable", mock.cid]], "Disable routed through capability-gated apply")
        }
        test("disable on absent device is an idempotent status operation") {
            let mock = MockTTL(); let result = try perform(manager(mock), .disabled)
            try check(result.state == .disabled && mock.invocations == [["status", mock.cid]] && !mock.installed, "Off request installed persistence")
        }
        test("invalid numeric values fail before SSH") {
            for request in [TTLConfiguration(outbound: 0, inboundIncrement: nil), TTLConfiguration(outbound: nil, inboundIncrement: 256)] {
                let mock = MockTTL()
                try rejects("от 1 до 255") { _ = try perform(manager(mock), request) }
                try check(mock.commands.isEmpty, "Invalid value reached remote shell")
            }
        }
        test("unrelated IMEI and preparation journals do not block TTL status or apply") {
            for name in ["pending.json", "setup-pending.json"] {
                let mock = MockTTL(); mock.installed = true; let value = try manager(mock)
                try savePrivate(Data("preserved".utf8), value.engine.root.appendingPathComponent(name))
                _ = try perform(value)
                _ = try perform(value, TTLConfiguration(outbound: 64, inboundIncrement: 1))
                try check(mock.installed && mock.configuration == TTLConfiguration(outbound: 64, inboundIncrement: 1), "Unrelated journal blocked TTL")
                try check(Data(contentsOf: value.engine.root.appendingPathComponent(name)) == Data("preserved".utf8), "TTL changed unrelated journal")
            }
        }
        test("pending ADB recovery does not block read-only TTL status") {
            for installed in [false, true] {
                let mock = MockTTL(); mock.installed = installed; let value = try manager(mock)
                let journal = value.engine.root.appendingPathComponent("adb-access-pending.json")
                try savePrivate(Data("preserved".utf8), journal)
                _ = try perform(value)
                try check(mock.invocations == [["status", mock.cid]] && mock.installed == installed && !mock.locked,
                          "Read-only TTL status changed settings or acquired a write lock")
                try check(Data(contentsOf: journal) == Data("preserved".utf8), "Status modified the recovery journal")
            }
        }
        test("active access recovery blocks TTL writes") {
            let mock = MockTTL(), value = try manager(mock)
            try savePrivate(Data(), value.engine.root.appendingPathComponent("adb-access-pending.json"))
            try rejects("Сначала завершите") { _ = try perform(value, TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.commands.isEmpty, "Access recovery bypassed")
        }
        test("resource corruption blocks before reading or changing modem") {
            let altered = testRoot.appendingPathComponent("altered")
            try secureDirectory(altered)
            try FileManager.default.copyItem(at: resources.appendingPathComponent("TTL"), to: altered.appendingPathComponent("TTL"))
            try savePrivate(Data("bad".utf8), altered.appendingPathComponent("TTL/boot.sh"))
            let mock = MockTTL()
            try rejects("Повреждён встроенный") { _ = try perform(manager(mock, resourceRoot: altered)) }
            try check(mock.commands.isEmpty, "Untrusted script reached modem")
        }
        test("B28 TTL reaches its component helper without a B31 override") {
            let mock = MockTTL(); mock.firmwareHash = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478"
            let result = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1))
            try check(result.state == .configured && mock.invocations.first?.first == "install", "B28 stopped at unrelated B31 gate")
        }
        test("B04 captured modem image reaches the independently checked TTL component") {
            let mock = MockTTL(); mock.firmwareHash = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81"
            let result = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1))
            try check(result.state == .configured && mock.invocations.first?.first == "install", "B04 stopped at unrelated modem image gate")
        }
        test("previous 1.24.20 refresh stays read-only") {
            let mock = MockTTL(); mock.installed = true; mock.managerHash = TTLSettingsManager.previous12420ManagerHash
            _ = try perform(manager(mock))
            try check(mock.uploaded.isEmpty && mock.invocations == [["status", mock.cid]] && mock.managerHash == TTLSettingsManager.previous12420ManagerHash, "Refresh upgraded a manager")
        }
        test("explicit apply upgrades 1.24.20 once before changing settings") {
            let mock = MockTTL(); mock.installed = true; mock.managerHash = TTLSettingsManager.previous12420ManagerHash
            let value = try manager(mock)
            _ = try perform(value, TTLConfiguration(outbound: 65, inboundIncrement: 2))
            try check(mock.invocations.map { $0[0] } == ["upgrade", "apply"] && mock.uploaded.count == 4 && mock.cleaned, "Old manager not upgraded before apply")
            _ = try perform(value, TTLConfiguration(outbound: 66, inboundIncrement: 2))
            try check(mock.invocations.map { $0[0] } == ["upgrade", "apply", "apply"], "Upgraded helper installed repeatedly")
        }
        test("explicit apply and disable upgrade every exact known manager; refresh does not") {
            for hash in TTLSettingsManager.upgradableManagerHashes {
                for configuration in [TTLConfiguration.disabled, TTLConfiguration(outbound: 65, inboundIncrement: 2)] {
                    let mock = MockTTL(); mock.installed = true; mock.managerHash = hash
                    let value = try manager(mock)
                    _ = try perform(value)
                    try check(mock.managerHash == hash && mock.uploaded.isEmpty, "Refresh upgraded a previous manager")
                    _ = try perform(value, configuration)
                    try check(mock.invocations.map { $0[0] } == ["status", "upgrade", configuration == .disabled ? "disable" : "apply"], "Known previous manager not upgraded for mutation")
                }
            }
        }
        test("failed upgrade prevents configuration changes") {
            let mock = MockTTL(); mock.installed = true; mock.managerHash = TTLSettingsManager.previous12420ManagerHash; mock.failUpgrade = true
            try rejects("UPGRADE_PENDING") { _ = try perform(manager(mock), TTLConfiguration(outbound: 65, inboundIncrement: 2)) }
            try check(mock.invocations.map { $0[0] } == ["upgrade"] && mock.configuration == .disabled && mock.cleaned, "Failure still applied TTL")
        }
        test("installed B31 manager stays usable without staging or replacement") {
            let mock = MockTTL(); mock.installed = true
            _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1))
            try check(mock.stage.isEmpty && mock.commands.contains { $0.contains(TTLSettingsManager.previousManagerHash) }, "Previous B31 helper no longer trusted")
            try check(mock.commands.contains { $0.contains(TTLSettingsManager.previous12418ManagerHash) }, "1.24.18 B31/B28 helper no longer trusted")
            try check(mock.commands.contains { $0.contains(TTLSettingsManager.previous12420ManagerHash) }, "1.24.20 B31/B28/B04 helper no longer trusted")
        }
        test("CID change after upload prevents all staged execution") {
            let mock = MockTTL(); mock.changeIdentityAt = 2
            try rejects("другой модем") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.invocations.isEmpty && mock.cleaned, "Changed CID reached install")
        }
        test("CID change before existing apply prevents execution") {
            let mock = MockTTL(); mock.installed = true; mock.changeIdentityAt = 2
            try rejects("другой модем") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.invocations.isEmpty, "Changed CID reached apply")
        }
        test("upload digest and pathname are both checked before execution") {
            for badPath in [false, true] {
                let mock = MockTTL(); mock.badUpload = !badPath; mock.wrongUploadPath = badPath
                try rejects("При передаче повреждён") { _ = try perform(manager(mock)) }
                try check(mock.invocations.isEmpty && mock.cleaned, "Untrusted uploaded script executed")
            }
        }
        test("installed manager hash failure blocks operation") {
            let mock = MockTTL(); mock.installed = true; mock.badManager = true
            try rejects("manager hash mismatch") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.invocations.isEmpty, "Changed manager executed")
        }
        test("wrong resulting values never report successful apply") {
            let mock = MockTTL(); mock.installed = true; mock.wrongResult = true
            try rejects("не подтвердил запрошенные") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
        }
        test("session-only rules cannot satisfy persistent apply") {
            let mock = MockTTL(); mock.installed = true; mock.persistenceOverride = "session"
            try rejects("применение и сохранение") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
        }
        test("failed mutation does not retry or silently downgrade configuration") {
            let mock = MockTTL(); mock.installed = true; mock.failMutation = true
            try rejects("TEST_FAILURE") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.invocations.count == 1 && mock.configuration == .disabled && !mock.locked, "Unexpected retry or lock leak")
        }
        test("lost acknowledgement remains an error even if modem applied values") {
            let mock = MockTTL(); mock.installed = true; mock.loseAcknowledgement = true
            try rejects("acknowledgement lost") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.invocations.count == 1 && mock.configuration == TTLConfiguration(outbound: 64, inboundIncrement: 1), "Uncertain operation was retried")
        }
        test("read status can honestly report unresolved active settings") {
            let mock = MockTTL(); mock.installed = true; mock.capability = "unsupported"; mock.configuration = TTLConfiguration(outbound: 64, inboundIncrement: 1)
            let result = try perform(manager(mock))
            try check(result.state == .error && result.configuration == mock.configuration && !result.detail.isEmpty, "Error hidden or active settings erased")
        }
        test("generated commands avoid NV IMEI stock config and global rule flushing") {
            for command in mocks.flatMap(\.commands) {
                for forbidden in ["zte_nv", "get_imei", "zte_config", "nv550", "sysctl", "iptables -F", "iptables-restore", "uci set", "/etc/config/firewall"] {
                    try check(!command.contains(forbidden), "Unexpected direct management operation: " + forbidden)
                }
            }
            try check(!TTLSettingsManager.managerCommand(arguments: ["status", String(repeating: "a", count: 32)], hash: String(repeating: "b", count: 64)).contains("--ttl-dec"), "Wrong inbound mode")
        }
        print("\(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
