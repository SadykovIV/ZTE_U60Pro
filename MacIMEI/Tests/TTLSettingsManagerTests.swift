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
    var installed = false, locked = false, cleaned = false, stage = ""
    var configuration = TTLConfiguration.disabled
    var capability = "supported", stateOverride: String?, persistenceOverride: String?
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
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            identityCalls += 1
            let actualCID = changeIdentityAt > 0 && identityCalls >= changeIdentityAt ? String(repeating: "b", count: 32) : cid
            return reply((badFirmware ? String(repeating: "0", count: 64) : ModemEngine.firmwareHash) + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + actualCID + "\n12345678-1234-1234-1234-123456789abc\n")
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
        test("both pending transaction types block before all remote work") {
            for name in ["pending.json", "setup-pending.json"] {
                let mock = MockTTL(), value = try manager(mock)
                try savePrivate(Data(), value.engine.root.appendingPathComponent(name))
                try rejects("Сначала завершите") { _ = try perform(value, TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
                try check(mock.commands.isEmpty, "Pending transaction bypassed")
            }
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
        test("firmware mismatch blocks before remote lock or staging") {
            let mock = MockTTL(); mock.badFirmware = true
            try rejects("Прошивка отличается") { _ = try perform(manager(mock), TTLConfiguration(outbound: 64, inboundIncrement: 1)) }
            try check(mock.commands.count == 1 && mock.stage.isEmpty, "Unknown firmware mutated")
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
