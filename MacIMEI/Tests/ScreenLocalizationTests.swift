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
private func status(_ state: String, language: String = "cn", mounted: Int? = nil, boot: Int? = nil, pid: Int = 42) -> String {
    "SCREEN_RU_STATUS state=\(state) language=\(language) mounted=\(mounted ?? (state == "enabled" ? 3 : 0)) boot=\(boot ?? (state == "enabled" ? 1 : 0)) pid=\(pid) revision=\(ScreenLocalization.revision)\n"
}

private final class MockScreen: RemoteTransport {
    var commands = [String]()
    var inputs = [String: Data]()
    var installed = false, enabled = false, badFirmware = false, badUpload = false
    var swapIdentityAt = 0, identityCalls = 0, managerMismatch = false, installFails = false
    var stalePID = false, corruptOriginal = false, staged = false, cleaned = false
    var remoteLocked = false, remoteLockRefused = false
    var quickReads = 0, quickDrift = "", errorReason: String?
    var stage = "", mutationActions = [String]()
    let original: Data
    init(original: Data) { self.original = original }
    func output(_ text: String, code: Int32 = 0) -> CommandResult {
        CommandResult(status: code, stdout: code == 0 ? Data(text.utf8) : Data(), stderr: code == 0 ? Data() : Data(text.utf8))
    }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command == SSHReadProof.quickCommand {
            quickReads += 1
            let cid = quickDrift == "cid" && quickReads > 1 ? String(repeating: "b", count: 32) : String(repeating: "a", count: 32)
            let boot = quickDrift == "boot" && quickReads > 1 ? "22345678-1234-1234-1234-123456789abc" : "12345678-1234-1234-1234-123456789abc"
            return output("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n" + cid + "\n" + boot + "\n?\n?\n")
        }
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            identityCalls += 1
            let cid = swapIdentityAt > 0 && identityCalls >= swapIdentityAt ? String(repeating: "b", count: 32) : String(repeating: "a", count: 32)
            return output((badFirmware ? String(repeating: "0", count: 64) : ModemEngine.firmwareHash) + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + cid + "\n12345678-1234-1234-1234-123456789abc\n")
        }
        if command.contains("if mkdir /tmp/zte-imei-app.lock") {
            if remoteLockRefused { return output("REMOTE_BUSY", code: 1) }
            remoteLocked = true; return output("")
        }
        if command.contains("&& rm /tmp/zte-imei-app.lock/owner") { remoteLocked = false; return output("") }
        if command == ScreenLocalization.probeCommand { return output(installed ? "SCREEN_RU_INSTALLED\n" : status("absent", language: "en", pid: 0)) }
        if command == "sha256sum /data/zte-imei-screen-ru/manager.sh" {
            return output(ScreenLocalization.resourceHashes["install.sh"]! + "  /data/zte-imei-screen-ru/manager.sh\n")
        }
        if command == ScreenLocalization.reasonCommand { return output(errorReason ?? "STATUS_UNVERIFIED") }
        if command.contains("sh /data/zte-imei-screen-ru/manager.sh ") {
            try check(command.contains("test ! -L") && command.contains("0$mode & 022") && command.contains(ScreenLocalization.resourceHashes["install.sh"]!), "Unverified manager execution")
            if managerMismatch { return output("manager hash mismatch", code: 1) }
            let action = command.components(separatedBy: "sh /data/zte-imei-screen-ru/manager.sh ")[1].split(separator: " ")[0]
            try check(action == "status" || remoteLocked, "Mutation without shared remote lock")
            if action == "enable" { enabled = true; mutationActions.append("enable") }
            if action == "disable" { enabled = false; mutationActions.append("disable") }
            return output(status(errorReason != nil ? "error" : enabled ? "enabled" : "disabled", language: enabled ? "cn" : "en", pid: stalePID ? 0 : 42))
        }
        if command == "cat /usr/bin/zte_topsw_devui" {
            var bytes = original
            if corruptOriginal { bytes[0] ^= 1 }
            return CommandResult(status: 0, stdout: bytes, stderr: Data())
        }
        if command.hasPrefix("umask 077; mkdir '/tmp/zte-screen-ru-install-") {
            try check(!staged && remoteLocked, "Created stage twice or without shared remote lock")
            stage = command.components(separatedBy: "'")[1]; staged = true; return output("")
        }
        if command.hasPrefix("umask 077; cat > '/tmp/zte-screen-ru-install-") {
            let path = command.components(separatedBy: "'")[1]
            try check(staged && path.hasPrefix(stage + "/") && input != nil, "Upload outside owned stage")
            inputs[URL(fileURLWithPath: path).lastPathComponent] = input!
            return output((badUpload ? String(repeating: "0", count: 64) : digest(input!)) + "  " + path + "\n")
        }
        if command.hasPrefix("sh '/tmp/zte-screen-ru-install-") {
            try check(staged && inputs.count == 6 && command.contains("' install '") && command.hasSuffix("'" + String(repeating: "a", count: 32) + "'"), "Installer arguments or incomplete upload")
            if installFails { return output("installer rejected unknown mount", code: 1) }
            installed = true; enabled = true; mutationActions.append("install")
            return output(status("enabled", pid: stalePID ? 0 : 42))
        }
        if command.hasPrefix("rm -f '/tmp/zte-screen-ru-install-") {
            try check(staged && command.contains("; rmdir '" + stage + "'") && !command.contains("rm -rf"), "Unsafe stage cleanup")
            cleaned = true; return output("")
        }
        throw Failure.check("Unexpected command: " + String(command.prefix(180)))
    }
}

@main struct ScreenLocalizationTests {
    static func main() throws {
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = project.appendingPathComponent("Resources")
        let originalPath = ProcessInfo.processInfo.environment["ZTE_SCREEN_TEST_ORIGINAL"].map { URL(fileURLWithPath: $0) }
            ?? project.deletingLastPathComponent().appendingPathComponent("evidence/russian-ui-trial-20260922/zte_topsw_devui")
        let original = try Data(contentsOf: originalPath)
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zte-screen-tests-" + UUID().uuidString)
        try secureDirectory(testRoot); defer { try? FileManager.default.removeItem(at: testRoot) }
        let key = testRoot.appendingPathComponent("key"), hosts = testRoot.appendingPathComponent("hosts")
        try savePrivate(Data("fixture".utf8), key); try savePrivate(Data("fixture".utf8), hosts)
        let connection = Connection(host: "192.168.0.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path)
        var mocks = [MockScreen]()
        func manager(_ mock: MockScreen, resourceRoot: URL? = nil) throws -> ScreenLocalization {
            mocks.append(mock)
            let root = testRoot.appendingPathComponent(UUID().uuidString)
            return ScreenLocalization(engine: try ModemEngine(root: root, resources: resourceRoot ?? resources, connection: connection, transport: mock))
        }
        func perform(_ manager: ScreenLocalization, _ action: ScreenLocalizationAction) throws -> ScreenLocalizationStatus {
            try manager.engine.locked { try manager.perform(action) }
        }
        let source = Data((0..<128).map(UInt8.init))
        var target = source; target[10] = 200; target[100] = 201
        func patch() -> ScreenFontPatch {
            ScreenFontPatch(version: 1, inputSHA256: digest(source), outputSHA256: digest(target), inputSize: source.count, outputSize: target.count,
                patches: [.init(offset: 10, originalHex: "0a", replacementHex: "c8"), .init(offset: 100, originalHex: "64", replacementHex: "c9")])
        }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        test("parse all four installation states and actual language") {
            for state in ["absent", "enabled", "disabled", "error"] {
                let result = try ScreenLocalization.parseStatus(status(state))
                try check(result.state.rawValue == state, "State mismatch")
                try check(result.languageTitle == (state == "enabled" ? "Русский" : "中文"), "Chinese slot mislabeled")
            }
            try check(ScreenLocalization.parseStatus(status("enabled", language: "en")).languageTitle == "English", "English hidden")
        }
        test("status rejects duplicate, incomplete, incompatible and unknown fields") {
            try rejects("неоднозначный") { _ = try ScreenLocalization.parseStatus(status("enabled") + status("enabled")) }
            try rejects("Повтор") { _ = try ScreenLocalization.parseStatus(status("enabled").trimmingCharacters(in: .newlines) + " state=disabled") }
            try rejects("Неполный") { _ = try ScreenLocalization.parseStatus(status("enabled").replacingOccurrences(of: " pid=42", with: "")) }
            try rejects("Несогласованное") { _ = try ScreenLocalization.parseStatus(status("enabled", mounted: 2)) }
            try rejects("Неизвестная") { _ = try ScreenLocalization.parseStatus(status("enabled", language: "ru")) }
            try rejects("Неизвестная") { _ = try ScreenLocalization.parseStatus(status("enabled").replacingOccurrences(of: ScreenLocalization.revision, with: "20990101")) }
        }
        test("all seven fixed optional failure reasons retain error state and unknown reason is rejected") {
            try check(ScreenLocalization.statusReasons.count == 7, "Unexpected reason catalog")
            for (reason, text) in ScreenLocalization.statusReasons {
                let result = try ScreenLocalization.parseStatus(status("error").trimmingCharacters(in: .newlines) + " reason=" + reason)
                try check(result.state == .error && result.detail == text, "Fixed reason lost")
            }
            try rejects("Неизвестная причина") { _ = try ScreenLocalization.parseStatus(status("error").trimmingCharacters(in: .newlines) + " reason=PRIVATE_CANARY") }
        }
        test("partial mount error stays an explicit error") {
            let result = try ScreenLocalization.parseStatus(status("error", mounted: 2, boot: 1))
            try check(result.state == .error && result.mounted == 2, "Partial state reported installed")
        }
        test("local patch applies exact guarded byte edits") { try check(ScreenLocalization.applyFontPatch(source, manifest: patch()) == target, "Incorrect result") }
        test("patch rejects altered source and preimage") {
            var changed = source; changed[0] ^= 1
            try rejects("исходного") { _ = try ScreenLocalization.applyFontPatch(changed, manifest: patch()) }
            var manifest = patch(); manifest.patches[0].originalHex = "ff"
            try rejects("Исходные байты") { _ = try ScreenLocalization.applyFontPatch(source, manifest: manifest) }
        }
        test("patch rejects overlap out of bounds resizing and wrong final digest") {
            var manifest = patch(); manifest.patches[1].offset = 10
            try rejects("пересекающиеся") { _ = try ScreenLocalization.applyFontPatch(source, manifest: manifest) }
            manifest = patch(); manifest.patches[1].offset = Int.max
            try rejects("пересекающиеся") { _ = try ScreenLocalization.applyFontPatch(source, manifest: manifest) }
            manifest = patch(); manifest.outputSize += 1
            try rejects("Размер") { _ = try ScreenLocalization.applyFontPatch(source, manifest: manifest) }
            manifest = patch(); manifest.outputSHA256 = String(repeating: "0", count: 64)
            try rejects("подготовленного") { _ = try ScreenLocalization.applyFontPatch(source, manifest: manifest) }
        }
        test("packaged patch reproduces the reviewed font binary") {
            let manifest = try readJSON(ScreenFontPatch.self, resources.appendingPathComponent("ScreenLocalization/font.patch.json"))
            let result = try ScreenLocalization.applyFontPatch(original, manifest: manifest)
            try check(digest(result) == "16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4", "Unexpected production font patch")
        }
        test("status is read only and does not read the executable or NV") {
            let mock = MockScreen(original: original); let result = try perform(manager(mock), .status)
            try check(result.state == .absent && mock.commands == [SSHReadProof.quickCommand, ScreenLocalization.probeCommand, SSHReadProof.quickCommand], "Read-only status mutated or hashed unrelated binaries")
        }
        test("status ignores local recovery and missing assets") {
            let mock = MockScreen(original: original); mock.badFirmware = true
            let value = try manager(mock, resourceRoot: testRoot.appendingPathComponent("missing-assets"))
            try savePrivate(Data("saved-pending".utf8), value.engine.root.appendingPathComponent("setup-pending.json"))
            try check(perform(value, .status).state == .absent && mock.identityCalls == 0 && !mock.remoteLocked && !mock.staged, "Unrelated setup resource or firmware prerequisite blocked status")
            try check(mock.commands.count == 3 && Data(contentsOf: value.engine.root.appendingPathComponent("setup-pending.json")) == Data("saved-pending".utf8), "Read changed pending intent")
        }
        test("status refuses changed CID and boot without writes") {
            for fact in ["cid", "boot"] {
                let mock = MockScreen(original: original); mock.quickDrift = fact
                try rejects("сеанс SSH изменились") { _ = try perform(manager(mock), .status) }
                try check(mock.commands.count == 3 && !mock.staged && !mock.remoteLocked, "Drift caused status writes")
            }
        }
        test("installed reset state returns the scoped fixed reason without upload") {
            let mock = MockScreen(original: original); mock.installed = true; mock.errorReason = "BOOT_HOOK_MISSING"
            let result = try perform(manager(mock, resourceRoot: testRoot.appendingPathComponent("missing-assets")), .status)
            try check(result.state == .error && result.detail == ScreenLocalization.statusReasons["BOOT_HOOK_MISSING"] && mock.quickReads == 2 && mock.identityCalls == 0 && mock.inputs.isEmpty && !mock.remoteLocked, "Installed reset status was hidden or mutated")
        }
        test("unsupported firmware fails before upload or installation") {
            let mock = MockScreen(original: original); mock.badFirmware = true
            try rejects("Прошивка отличается") { _ = try perform(manager(mock), .enable) }
            try check(mock.commands.count == 1 && !mock.staged, "Unsupported firmware reached writes")
        }
        test("unrelated IMEI and setup journals do not block verified screen installation") {
            for name in ["pending.json", "setup-pending.json"] {
                let mock = MockScreen(original: original), value = try manager(mock)
                let path = value.engine.root.appendingPathComponent(name), bytes = Data("saved-unrelated-intent".utf8)
                try savePrivate(bytes, path)
                try check(perform(value, .enable).state == .enabled && mock.mutationActions == ["install"], "Unrelated journal blocked component installation")
                try check(Data(contentsOf: path) == bytes && mock.commands.contains { $0.contains("if mkdir /tmp/zte-imei-app.lock") } && !mock.remoteLocked, "Component installation changed unrelated journal or skipped its live lock")
            }
        }
        test("a live foreign remote operation still refuses screen changes") {
            let mock = MockScreen(original: original); mock.remoteLockRefused = true
            try rejects("REMOTE_BUSY") { _ = try perform(manager(mock), .enable) }
            try check(mock.mutationActions.isEmpty && !mock.staged && mock.inputs.isEmpty, "Active remote owner was bypassed")
        }
        test("corrupt bundled asset fails before SSH") {
            let altered = testRoot.appendingPathComponent("altered-resources")
            try secureDirectory(altered)
            try FileManager.default.copyItem(at: resources.appendingPathComponent("ScreenLocalization"), to: altered.appendingPathComponent("ScreenLocalization"))
            try savePrivate(Data("corrupt".utf8), altered.appendingPathComponent("ScreenLocalization/Chinese.ini"))
            let mock = MockScreen(original: original)
            try rejects("Повреждён встроенный") { _ = try perform(manager(mock, resourceRoot: altered), .enable) }
            try check(mock.commands.isEmpty, "Bad resource reached SSH")
        }
        test("first install transfers only locally verified files and cleans its stage") {
            let mock = MockScreen(original: original); let result = try perform(manager(mock), .enable)
            try check(result.state == .enabled && mock.mutationActions == ["install"] && mock.cleaned, "Incomplete install")
            try check(mock.identityCalls == 3 && digest(mock.inputs["zte_topsw_devui"]!) == "16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4", "Missing CID/hash checks")
        }
        test("repeated enable reuses the installed manager without repatching") {
            let mock = MockScreen(original: original); mock.installed = true; mock.enabled = true
            _ = try perform(manager(mock), .enable)
            try check(mock.mutationActions == ["enable"] && !mock.staged && !mock.commands.contains("cat /usr/bin/zte_topsw_devui"), "Existing install was replaced")
        }
        test("disabled installation can be re-enabled without reading the stock executable") {
            let mock = MockScreen(original: original); mock.installed = true
            try check(perform(manager(mock), .enable).state == .enabled && !mock.staged, "Enable recreated assets")
        }
        test("restore and repeated restore are idempotent") {
            let mock = MockScreen(original: original); mock.installed = true; mock.enabled = true
            let value = try manager(mock)
            try check(perform(value, .disable).state == .disabled, "Disable failed")
            try check(perform(value, .disable).state == .disabled && mock.mutationActions == ["disable", "disable"], "Second disable changed behavior")
            let absent = MockScreen(original: original)
            try check(perform(manager(absent), .disable).state == .absent && absent.mutationActions.isEmpty, "Disable installed absent resources")
        }
        test("source corruption fails before staging") {
            let mock = MockScreen(original: original); mock.corruptOriginal = true
            try rejects("SHA-256 исходного") { _ = try perform(manager(mock), .enable) }
            try check(!mock.staged, "Corrupt executable uploaded")
        }
        test("CID change before staging or after upload stops installation") {
            for call in [2, 3] {
                let mock = MockScreen(original: original); mock.swapIdentityAt = call
                try rejects("другой модем") { _ = try perform(manager(mock), .enable) }
                try check(mock.mutationActions.isEmpty && (call == 2 ? !mock.staged : mock.cleaned), "CID mismatch reached install")
            }
        }
        test("upload corruption never starts installer and removes stage") {
            let mock = MockScreen(original: original); mock.badUpload = true
            try rejects("При передаче повреждён") { _ = try perform(manager(mock), .enable) }
            try check(mock.mutationActions.isEmpty && mock.cleaned, "Corrupt upload reached installer")
        }
        test("unknown installed manager is never executed") {
            let mock = MockScreen(original: original); mock.installed = true; mock.managerMismatch = true
            try rejects("manager hash mismatch") { _ = try perform(manager(mock), .enable) }
            try check(mock.mutationActions.isEmpty && !mock.staged, "Unknown manager overwritten")
        }
        test("installer rejection preserves error and removes only its stage") {
            let mock = MockScreen(original: original); mock.installFails = true
            try rejects("unknown mount") { _ = try perform(manager(mock), .enable) }
            try check(mock.cleaned && !mock.installed, "Failed install incorrectly confirmed")
        }
        test("successful command without running UI is not success") {
            let mock = MockScreen(original: original); mock.installed = true; mock.stalePID = true
            try rejects("не подтвердил") { _ = try perform(manager(mock), .enable) }
        }
        test("all screen workflows avoid NV and system remount operations") {
            for command in mocks.flatMap(\.commands) {
                for forbidden in ["zte_nv", "get_imei", "get_imei2", "zte_config", "remount", "opkg", "modem_nv", "nv550"] {
                    try check(!command.contains(forbidden), "Unexpected modem operation: " + forbidden)
                }
            }
        }
        print("\(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
