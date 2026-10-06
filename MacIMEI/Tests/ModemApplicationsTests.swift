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
private func inventoryText(rootMode: String = "ro", extraMount: String = "", installed: Bool = false, proxy: Bool = false, unmanaged: Bool = false) -> String {
    """
    __ZTE_RELEASE__
    DISTRIB_RELEASE='23.05.4'
    DISTRIB_ARCH='aarch64_cortex-a53'
    __ZTE_STORAGE__
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/root 800000 430000 347000 55% /
    /dev/data 1900000 8000 1876000 1% /data
    /dev/overlay 3924 12 3752 1% /overlay
    overlay 170000 1000 169000 1% /etc
    __ZTE_MEMORY__
    MemTotal: 865280 kB
    MemAvailable: 344576 kB
    __ZTE_MOUNTS__
    /dev/root / ext4 \(rootMode),relatime 0 0
    /dev/data /data ext4 rw,relatime 0 0
    overlay /etc overlay rw,relatime 0 0
    \(extraMount)
    __ZTE_PACKAGES__
    Package: curl
    Version: 8.15.0-1
    Status: install ok installed

    Package: half-installed
    Version: 1
    Status: install ok unpacked

    Package: libc
    Version: 1.2.4-4
    Status: install hold installed

    __ZTE_APPLICATION_STORAGE__
    managedUsedKiB=12000
    __ZTE_FLAGS__
    opkgWritable=1
    ssclashInstalled=\(installed ? 1 : 0)
    ssclashRunning=0
    ssclashProxyRunning=\(proxy ? 1 : 0)
    ssclashPresent=\(installed || unmanaged ? 1 : 0)
    """
}

private final class MockApplications: RemoteTransport {
    var commands = [String](), inputs = [Data?]()
    var identityCalls = 0, changeIdentity = false, uploadBadHash = false
    var failPassword = false, anonymousOpen = false, proxyRunning = false
    var badLogin = false, serviceACKLost = false, startACKLost = false
    var firmware = ModemEngine.firmwareHash, router = ModemEngine.routerHash
    var platformFailure = false, absentFiles = false, drift = "", driftAt = 2
    var release = "23.05.4", architecture = "aarch64_cortex-a53"
    var installed = false, rootMode = "ro", serviceHash = "", serviceBadHash = false
    var removalPrepared = false, removalCommitted = false, archiveRead = false, archiveCorrupt = false, removalACKLost = false
    var hugeArchive = false, unmanaged = false, optionalReaderUnavailable = false
    var localLogDirectory: URL?
    let archiveData = Data("private recovery archive fixture".utf8)
    var staged = false, passwordSet = false, promoted = false, serviceCreated = false, started = false, stopped = false
    func output(_ text: String, status: Int32 = 0) -> CommandResult { CommandResult(status: status, stdout: Data(text.utf8), stderr: status == 0 ? Data() : Data(text.utf8)) }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command); inputs.append(input)
        if command == ModemApplications.inventoryCommand { return output(inventoryText(rootMode: rootMode, installed: installed, proxy: proxyRunning, unmanaged: unmanaged).replacingOccurrences(of: "23.05.4", with: release).replacingOccurrences(of: "aarch64_cortex-a53", with: architecture)) }
        if command == AccessIdentity.command || command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            identityCalls += 1
            if command == AccessIdentity.command && platformFailure { return output("PLATFORM", status: 71) }
            let changed = identityCalls >= driftAt
            let cid = (changeIdentity || drift == "cid") && changed ? String(repeating: "b", count: 32) : String(repeating: "a", count: 32)
            let fw = changed && drift == "firmware" ? String(repeating: "c", count: 64) : (absentFiles ? "absent" : firmware)
            let rh = changed && drift == "router" ? String(repeating: "d", count: 64) : (absentFiles ? "absent" : router)
            let boot = changed && drift == "boot" ? "22345678-1234-1234-1234-123456789abc" : "12345678-1234-1234-1234-123456789abc"
            return output(fw + "  /firmware/image/modem.b16\n" + rh + "  /usr/bin/diag-router\n" + cid + "\n" + boot + "\n")
        }
        if command.hasPrefix("sh -s -- 'prepare'") {
            try check(installed && input.map(digest) == ModemApplications.removalScriptHash, "Unverified remover executed")
            if serviceBadHash { return output("SSClash service has changed", status: 1) }
            removalPrepared = true; stopped = true
            return output("SSCLASH_ARCHIVE sha256=" + digest(archiveData) + " bytes=" + String(hugeArchive ? 300 * 1024 * 1024 : archiveData.count) + "\n")
        }
        if command.contains("; cat '/data/zte-imei-apps/.removals/") {
            try check(removalPrepared, "Archive read before prepared")
            archiveRead = true
            return CommandResult(status: 0, stdout: archiveCorrupt ? Data("broken".utf8) : archiveData, stderr: Data())
        }
        if command.hasPrefix("sh -s -- 'commit'") {
            try check(removalPrepared && archiveRead, "Commit before archive transfer")
            let files = try FileManager.default.contentsOfDirectory(at: localLogDirectory!, includingPropertiesForKeys: nil)
            let archives = files.filter { $0.pathExtension == "gz" }
            try check(archives.count == 1 && Data(contentsOf: archives[0]) == archiveData, "Commit before verified local backup")
            removalCommitted = true; installed = false
            if removalACKLost { return output("SSH acknowledgement lost", status: 255) }
            let args = command.components(separatedBy: "'")
            let token = args[3]
            return output("SSCLASH_REMOVED archive=/data/zte-imei-apps/.removals/" + token + "/archive.tar.gz\n")
        }
        if optionalReaderUnavailable && (command.contains("/tmp/zte-diag-") || command.hasPrefix("sh -s -- 'inspect'")) { return output("FIXTURE_OPTIONAL_READER_UNAVAILABLE", status: 71) }
        if command.contains("/tmp/zte-imei-app.lock") { return output("") }
        if command.hasPrefix("opkg --noaction install ") { return output("Unknown package. No index loaded.", status: 1) }
        if command.contains("safe_dir()") {
            try check(command.contains("safe_dir /data") && command.contains("safe_dir /etc/init.d") && command.contains("safe_dir /data/zte-imei-apps"), "Ownership guards absent")
            try check(command.contains("0$mode & 022") && command.contains("ip -o -4 addr show") && command.contains("/proc") == false, "Filesystem/LAN guards absent")
            try check(command.contains("test ! -L /data/zte-imei-apps/ssclash"), "Target symlink guard")
            staged = true; return output("")
        }
        if command.contains("cat > /data/zte-imei-apps/.ssclash-") {
            try check(staged && input?.count == 11_010_232, "Upload outside owned stage")
            return output((uploadBadHash ? String(repeating: "0", count: 64) : ModemApplications.ssclashHash) + "  /stage/bin/ssclash\n")
        }
        if command.hasSuffix("/bin/ssclash version") { try check(staged, "No stage"); return output("ssclash v6.4.1\n") }
        if command.hasSuffix("/bin/ssclash setpass") {
            try check(!started && input == Data("strong-secret-123\n".utf8), "Password stdin/order")
            if failPassword { return output("password provisioning failed", status: 1) }
            passwordSet = true; return output("New admin password: Password updated.\n")
        }
        if command.contains("; mv /data/zte-imei-apps/.ssclash-") {
            try check(passwordSet && command.contains("test ! -e") && command.contains("/bin/clash"), "Promotion before auth or core exclusion")
            promoted = true; return output("")
        }
        if command.contains("cat > /etc/init.d/.zte-imei-ssclash-") {
            try check(promoted && command.contains("; ln "), "Service before promoted password store")
            let script = String(decoding: input!, as: UTF8.self)
            try check(script.contains("SSCLASH_ADDR=\"192.168.0.1:9091\"") && script.contains("test") == false, "Service LAN bind")
            try check(!script.contains("enable") && !script.contains("fw start"), "Unrequested proxy/autostart")
            serviceCreated = true
            return serviceACKLost ? output("SSH acknowledgement lost", status: 255) : output("")
        }
        if command.contains("for dir in /data /data/zte-imei-apps") {
            try check(command.contains(".ssclash/password") && command.contains("zte-imei-ssclash-v1"), "Start ownership/password guards")
            serviceCreated = true
            return output(ModemApplications.ssclashHash + "  binary\n" + (serviceBadHash ? "bad" : serviceHash) + "  service\n")
        }
        if command == ModemApplications.servicePath + " start" { try check(serviceCreated, "Start before service"); started = true; return startACKLost ? output("SSH start acknowledgement lost", status: 255) : output("") }
        if command == ModemApplications.servicePath + " stop" { stopped = true; started = false; return output("") }
        if command == "curl --config -" {
            try check(started, "HTTP before start")
            let config = String(decoding: input!, as: UTF8.self)
            if config.contains("/login\"") {
                if config.contains("data = ") {
                    try check(config.contains("csrf=csrf-token&password=strong-secret-123"), "Login form encoding")
                    if badLogin { return output("HTTP/1.1 200 OK\r\n\r\nIncorrect password") }
                    return output("HTTP/1.1 303 See Other\r\nSet-Cookie: ssclash_session=authenticated; HttpOnly\r\nLocation: /\r\n\r\n")
                }
                return output("HTTP/1.1 200 OK\r\nSet-Cookie: csrf=guest; HttpOnly\r\n\r\n<form action=\"/login\"><input name=\"csrf\" value=\"csrf-token\"></form>")
            }
            if config.contains("/api/status\"") {
                if config.contains("Cookie: ssclash_session=authenticated") { return output("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"running\":\(proxyRunning ? "true" : "false")}") }
                return output(anonymousOpen ? "HTTP/1.1 200 OK\r\n\r\n{\"running\":false}" : "HTTP/1.1 401 Unauthorized\r\n\r\n{}")
            }
        }
        throw Failure.check("Unexpected remote command: \(command.prefix(180))")
    }
}

@main struct ModemApplicationsTests {
    static func main() throws {
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = project.appendingPathComponent("Resources")
        guard let assetPath = ProcessInfo.processInfo.environment["ZTE_SSCLASH_TEST_ASSET"] else {
            print("SKIP: set ZTE_SSCLASH_TEST_ASSET to the separately downloaded official binary"); return
        }
        let binary = try Data(contentsOf: URL(fileURLWithPath: assetPath))
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zte-apps-tests-" + UUID().uuidString)
        try secureDirectory(testRoot); defer { try? FileManager.default.removeItem(at: testRoot) }
        let key = testRoot.appendingPathComponent("test-key"), hosts = testRoot.appendingPathComponent("test-hosts")
        try savePrivate(Data("test".utf8), key); try savePrivate(Data("test".utf8), hosts)
        let connection = Connection(host: "192.168.0.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path)
        var allMocks = [MockApplications]()
        func app(_ remote: MockApplications, data: Data? = nil) throws -> ModemApplications {
            allMocks.append(remote)
            let root = testRoot.appendingPathComponent(UUID().uuidString)
            let engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: remote)
            remote.localLogDirectory = engine.logDirectory
            let template = try String(contentsOf: resources.appendingPathComponent("Applications/ssclash-service.sh"), encoding: .utf8)
            remote.serviceHash = digest(Data(template.replacingOccurrences(of: "__ZTE_LAN_IPV4__", with: connection.host).utf8))
            return ModemApplications(engine: engine, assetLoader: { _ in data ?? binary })
        }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        test("storage and physical memory are independent; etc included") {
            let value = try ModemApplications.parseInventory(inventoryText())
            try check(value.storage.count == 4 && value.memoryTotalKiB == 865280 && value.memoryAvailableKiB == 344576, "Storage/RAM confusion")
            try check(value.installedPackages.map(\.name) == ["curl", "libc"], "Unpacked package included")
        }
        test("root -w true cannot override a read-only filesystem") {
            try check(!ModemApplications.parseInventory(inventoryText()).opkgWritable, "RO root accepted")
        }
        test("longest matching read-only mount overrides rw root") {
            let state = try ModemApplications.parseInventory(inventoryText(rootMode: "rw", extraMount: "ro /usr ext4 ro 0 0"))
            try check(!state.opkgWritable, "Nested readonly /usr accepted")
        }
        test("missing mount identity fails closed") {
            let fixture = inventoryText().replacingOccurrences(of: "/dev/root / ext4 ro,relatime 0 0", with: "")
            try check(!ModemApplications.parseInventory(fixture).opkgWritable, "Absent mount assumed writable")
        }
        test("writable does not promise supported package installer") {
            let state = try ModemApplications.parseInventory(inventoryText(rootMode: "rw"))
            try check(state.opkgWritable && !state.opkgInstallationSupported, "Unsupported installation advertised")
        }
        test("bad RAM and missing storage rejected") {
            try rejects("оперативную") { _ = try ModemApplications.parseInventory(inventoryText().replacingOccurrences(of: "MemAvailable: 344576", with: "MemAvailable: 9999999")) }
            try rejects("файловых") { _ = try ModemApplications.parseInventory(inventoryText().replacingOccurrences(of: "overlay 170000 1000 169000 1% /etc", with: "")) }
        }
        test("package and password injection rejected") {
            for name in ["curl;reboot", "curl\n", "--force-depends", "$(id)", "kmod-tun", "libc", "../curl"] { try rejects(name == "kmod-tun" || name == "libc" ? "Системные" : "имя") { try ModemApplications.validatePackageName(name) } }
            for password in ["short", " password-long", "password-long\nsecond"] { try rejects("Пароль") { try ModemApplications.validateSSClashPassword(password: password) } }
        }
        test("preview reports stock read-only restriction without update") {
            let mock = MockApplications(); let value = try app(mock).previewPackage("curl")
            try check(value.contains("заблокирована") && !mock.commands.contains { $0.contains("opkg update") }, "Preview mutates indices")
        }
        test("install package blocks before opkg write") {
            let mock = MockApplications(); try rejects("только для чтения") { _ = try app(mock).installPackage("curl") }
            try check(mock.commands.count == 1, "Unexpected opkg mutation")
        }
        test("corrupt asset blocked before staging") {
            let mock = MockApplications(); try rejects("SHA-256") { _ = try app(mock, data: Data([1,2,3])).installSSClash(password: "strong-secret-123") }
            try check(!mock.staged, "Staged corrupt asset")
        }
        test("CID rechecked after download before first write") {
            let mock = MockApplications(); mock.changeIdentity = true
            try rejects("изменились") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(mock.identityCalls == 2 && !mock.staged, "Identity change crossed write boundary")
        }
        let b28Firmware = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478"
        for profile in ["B28", "B31", "absent"] {
            test("default connection installs SSClash for measured " + profile) {
                let mock = MockApplications(); mock.firmware = profile == "B28" ? b28Firmware : ModemEngine.firmwareHash; mock.absentFiles = profile == "absent"
                let manager = try app(mock)
                try check(!manager.engine.connection.skipFirmwareCheck, "Fixture bypassed firmware policy")
                _ = try manager.installSSClash(password: "strong-secret-123")
                try check(mock.started && mock.passwordSet && mock.identityCalls >= 3, "Measured install lacked final identity")
                try check(!mock.commands.contains { $0.hasPrefix("sha256sum /firmware/image/modem.b16") }, "Strict global firmware gate was called")
            }
            test("default connection starts SSClash for measured " + profile) {
                let mock = MockApplications(); mock.firmware = profile == "B28" ? b28Firmware : ModemEngine.firmwareHash; mock.absentFiles = profile == "absent"
                _ = try app(mock).startSSClash()
                try check(mock.started && !mock.passwordSet && mock.identityCalls == 3, "Start lacked bound proof or reset password")
            }
            test("default connection removes SSClash for measured " + profile) {
                let mock = MockApplications(); mock.installed = true; mock.firmware = profile == "B28" ? b28Firmware : ModemEngine.firmwareHash; mock.absentFiles = profile == "absent"
                _ = try app(mock).removeSSClash()
                try check(mock.removalCommitted && mock.archiveRead && mock.identityCalls >= 4, "Measured removal lacked identity/backup")
            }
        }
        for field in ["cid", "boot", "firmware", "router"] {
            test("install blocks " + field + " drift before stage") {
                let mock = MockApplications(); mock.drift = field
                try rejects("изменились") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
                try check(!mock.staged, "Device drift crossed first write")
            }
            test("remove blocks " + field + " drift before prepare") {
                let mock = MockApplications(); mock.installed = true; mock.drift = field
                try rejects("изменились") { _ = try app(mock).removeSSClash() }
                try check(!mock.removalPrepared && !mock.stopped && !mock.archiveRead, "Device drift crossed prepare")
            }
            test("remove blocks " + field + " drift before commit") {
                let mock = MockApplications(); mock.installed = true; mock.drift = field; mock.driftAt = 3
                try rejects("изменились") { _ = try app(mock).removeSSClash() }
                try check(mock.archiveRead && !mock.removalCommitted && mock.installed, "Device drift crossed commit")
            }
        }
        test("install final identity drift cannot claim success or stop another modem") {
            let mock = MockApplications(); mock.drift = "boot"; mock.driftAt = 3
            let manager = try app(mock)
            try rejects("изменились") { _ = try manager.installSSClash(password: "strong-secret-123") }
            try check(mock.started && !mock.stopped, "Final drift claimed success or wrote to changed modem")
            let journal = try readJSON([String: String].self, manager.engine.logDirectory.appendingPathComponent("ssclash-install.json"))
            try check(journal["phase"] == "needs-inspection-stop-not-requested", "Journal falsely claimed a cleanup command")
        }
        test("remove final identity drift retains verified recovery archive") {
            let mock = MockApplications(); mock.installed = true; mock.drift = "router"; mock.driftAt = 4
            let manager = try app(mock)
            try rejects("изменились") { _ = try manager.removeSSClash() }
            let files = try FileManager.default.contentsOfDirectory(at: manager.engine.logDirectory, includingPropertiesForKeys: nil)
            try check(mock.removalCommitted && files.contains { $0.pathExtension == "gz" }, "Final check lost local archive")
        }
        for action in ["install", "remove", "start"] {
            test(action + " fails platform proof before inventory or writes") {
                let mock = MockApplications(); mock.platformFailure = true; mock.installed = action == "remove"
                try rejects("PLATFORM") { if action == "install" { _ = try app(mock).installSSClash(password: "strong-secret-123") } else if action == "remove" { _ = try app(mock).removeSSClash() } else { _ = try app(mock).startSSClash() } }
                try check(mock.commands.count == 1 && !mock.staged && !mock.removalPrepared, "Platform failure reached mutation")
            }
        }
        for abi in ["release", "architecture"] {
            test("SSClash retains " + abi + " component ABI guard") {
                let mock = MockApplications(); if abi == "release" { mock.release = "99.99" } else { mock.architecture = "x86_64" }
                try rejects("SSClash") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
                try check(!mock.staged && !mock.passwordSet, "Wrong ABI reached writes")
            }
        }
        for profile in ["B28", "B31", "absent"] {
            test("managed application inventory reads " + profile + " with unrelated IMEI/setup journals") {
                let mock = MockApplications(); mock.firmware = profile == "B28" ? b28Firmware : ModemEngine.firmwareHash; mock.absentFiles = profile == "absent"; mock.optionalReaderUnavailable = true
                let manager = try app(mock)
                for name in ["pending.json", "setup-pending.json"] { try savePrivate(Data("fixture".utf8), manager.engine.root.appendingPathComponent(name)) }
                let value = try manager.engine.locked { try manager.inventoryWithManagedApps() }
                try check(value.managedAppsChecked && value.applicationStorage != nil && value.managedAppErrors.count == 2, "Inventory or optional failure attribution lost")
                try check(!mock.commands.contains { $0.hasPrefix("sha256sum /firmware/image/modem.b16") || $0.contains("/tmp/zte-imei-app.lock") }, "Inventory required global B31 policy or mutation lock")
                try check(mock.identityCalls >= 3 && !mock.staged && !mock.removalPrepared && !mock.started, "Inventory changed SSClash or omitted identity checks")
            }
        }
        for field in ["cid", "boot", "firmware", "router"] {
            test("managed application inventory rejects " + field + " drift") {
                let mock = MockApplications(); mock.drift = field; mock.optionalReaderUnavailable = true
                let manager = try app(mock)
                try rejects("изменилось") { _ = try manager.engine.locked { try manager.inventoryWithManagedApps() } }
                try check(!mock.staged && !mock.removalPrepared && !mock.started, "Inventory drift reached SSClash write")
            }
        }
        test("UI SSClash preparation accepts B28 with unrelated IMEI and setup journals") {
            let mock = MockApplications(); mock.firmware = b28Firmware
            let manager = try app(mock)
            for name in ["pending.json", "setup-pending.json"] { try savePrivate(Data("fixture".utf8), manager.engine.root.appendingPathComponent(name)) }
            try manager.engine.locked { try manager.prepareSSClashOperation(); _ = try manager.installSSClash(password: "strong-secret-123") }
            try check(mock.started && mock.commands.contains { $0.contains("mkdir /tmp/zte-imei-app.lock") }, "UI preparation did not use remote lock")
            try check(mock.commands.contains { $0.contains("rmdir /tmp/zte-imei-app.lock") }, "Remote lock was not released")
        }
        test("UI SSClash preparation binds device across lock acquisition") {
            let mock = MockApplications(); mock.drift = "boot"
            let manager = try app(mock)
            try rejects("изменились") { try manager.engine.locked { try manager.prepareSSClashOperation(); _ = try manager.installSSClash(password: "strong-secret-123") } }
            try check(!mock.staged && !mock.started, "Lock acquisition lost device binding")
        }
        for name in ["adb-access-pending.json", "adb-toggle-pending.json", "component-cleanup-pending.json", "system-restore-pending.json"] {
            test("UI SSClash preparation retains " + name + " exclusion") {
                let mock = MockApplications(); let manager = try app(mock)
                try savePrivate(Data("fixture".utf8), manager.engine.root.appendingPathComponent(name))
                try rejects("Сначала") { try manager.engine.locked { try manager.prepareSSClashOperation(); _ = try manager.installSSClash(password: "strong-secret-123") } }
                try check(!mock.staged && !mock.started && !mock.commands.contains { $0.contains("mkdir /tmp/zte-imei-app.lock") }, "ADB recovery crossed mutation gate")
            }
        }
        test("start rejects boot drift before service mutation") {
            let mock = MockApplications(); mock.drift = "boot"
            try rejects("изменились") { _ = try app(mock).startSSClash() }
            try check(!mock.started && !mock.stopped, "Changed device received start/stop")
        }
        test("start final drift avoids success and stop on changed device") {
            let mock = MockApplications(); mock.drift = "router"; mock.driftAt = 3
            try rejects("изменились") { _ = try app(mock).startSSClash() }
            try check(mock.started && !mock.stopped, "Final changed device received cleanup")
        }
        test("successful mocked install auth before bind and no proxy") {
            let mock = MockApplications(); let manager = try app(mock)
            _ = try manager.installSSClash(password: "strong-secret-123")
            try check(mock.started && mock.passwordSet && mock.promoted && !mock.stopped, "Missing ordered stages")
            try check(!mock.commands.contains { $0.contains("strong-secret-123") || $0.contains(" enable") || $0.contains("opkg update") || $0.contains("remount") }, "Password/unsupported write in command")
            let files = try FileManager.default.contentsOfDirectory(at: manager.engine.logDirectory, includingPropertiesForKeys: nil)
            for file in files { try check(!String(decoding: Data(contentsOf: file), as: UTF8.self).contains("strong-secret-123"), "Password leaked to journal") }
        }
        test("remote corruption never executes binary") {
            let mock = MockApplications(); mock.uploadBadHash = true
            try rejects("повреждён") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(!mock.passwordSet && !mock.started, "Bad remote binary executed")
        }
        test("password provisioning failure never starts web service") {
            let mock = MockApplications(); mock.failPassword = true
            try rejects("password provisioning") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(!mock.promoted && !mock.started, "Password failure exposed web UI")
        }
        test("uncertain service upload acknowledgement never starts service") {
            let mock = MockApplications(); mock.serviceACKLost = true
            try rejects("acknowledgement lost") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(mock.serviceCreated && !mock.started, "Unacknowledged service was started")
        }
        test("actual HTTP password rejection stops UI") {
            let mock = MockApplications(); mock.badLogin = true
            try rejects("не подтвердил вход") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(mock.stopped, "Failed authentication did not stop UI")
        }
        test("unprotected API stops newly installed service") {
            let mock = MockApplications(); mock.anonymousOpen = true
            try rejects("без авторизации") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(mock.stopped, "Unprotected API remained running")
        }
        test("unexpected proxy startup stops installation") {
            let mock = MockApplications(); mock.proxyRunning = true
            try rejects("выключенное состояние") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(mock.stopped, "Unexpected proxy remained running")
        }
        test("existing installation is never overwritten") {
            let mock = MockApplications(); mock.installed = true
            try rejects("уже установлен") { _ = try app(mock).installSSClash(password: "strong-secret-123") }
            try check(!mock.staged, "Existing installation mutated")
        }
        test("restart requires known binary and service hashes") {
            let mock = MockApplications(); mock.serviceBadHash = true
            try rejects("изменены") { _ = try app(mock).startSSClash() }
            try check(!mock.started, "Changed service started")
        }
        test("restart preserves password and verifies login gate") {
            let mock = MockApplications(); _ = try app(mock).startSSClash()
            try check(mock.started && !mock.passwordSet, "Restart reset password")
        }
        test("lost start acknowledgement still requests safe service stop") {
            let mock = MockApplications(); mock.startACKLost = true
            try rejects("acknowledgement lost") { _ = try app(mock).startSSClash() }
            try check(mock.stopped && !mock.started && !mock.passwordSet, "Uncertain start bypassed cleanup")
        }
        test("application storage measures /data and managed directory, not RAM or system volumes") {
            let value = try ModemApplications.parseInventory(inventoryText(installed: true))
            try check(value.applicationStorage?.totalKiB == 1900000 && value.applicationStorage?.availableKiB == 1876000 && value.applicationStorage?.managedUsedKiB == 12000, "Wrong application storage")
            try check(value.installedApplications.count == 1 && value.installedApplications[0].canRemove, "Managed application absent")
            try check(value.installedPackages.allSatisfy { !$0.canRemove && !$0.removalBlockReason.isEmpty }, "System package removability")
            try check(ModemApplications.catalog.count == 1 && !ModemApplications.catalog[0].isBundled, "Catalog missing offline payload")
        }
        test("application storage rejects missing or impossible measurement") {
            for value in ["managedUsedKiB=-1", "managedUsedKiB=99999999", "managedUsedKiB=abc"] {
                try rejects("место установки") { _ = try ModemApplications.parseInventory(inventoryText().replacingOccurrences(of: "managedUsedKiB=12000", with: value)) }
            }
        }
        test("public catalog does not bundle the proprietary executable") {
            try check(!FileManager.default.fileExists(atPath: resources.appendingPathComponent("Applications/ssclash-linux-arm64").path), "Proprietary executable bundled")
            try rejects("Неизвестный источник") { _ = try ModemApplications.downloadOfficialAsset(URL(string: "https://example.test/ssclash")!) }
        }
        test("unmanaged app and running proxy cannot be removed") {
            let unknown = try ModemApplications.parseInventory(inventoryText(unmanaged: true))
            try check(unknown.installedApplications.count == 1 && !unknown.installedApplications[0].canRemove, "Unknown installation removable")
            let mock = MockApplications(); mock.installed = true; mock.proxyRunning = true
            try rejects("остановите прокси") { _ = try app(mock).removeSSClash() }
            try check(!mock.removalPrepared && !mock.stopped, "Active proxy touched")
        }
        test("removal saves a verified local backup before committing") {
            let mock = MockApplications(); mock.installed = true
            let manager = try app(mock); let message = try manager.removeSSClash()
            try check(mock.removalCommitted && message.contains("Резервная копия"), "Removal did not finish")
            let files = try FileManager.default.contentsOfDirectory(at: manager.engine.logDirectory, includingPropertiesForKeys: nil)
            let archive = files.first { $0.pathExtension == "gz" }!
            let mode = (try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue
            try check(mode == 0o600, "Private archive has unsafe permissions")
        }
        test("changed service is blocked before stop or archive") {
            let mock = MockApplications(); mock.installed = true; mock.serviceBadHash = true
            try rejects("service has changed") { _ = try app(mock).removeSSClash() }
            try check(!mock.removalPrepared && !mock.stopped && !mock.removalCommitted, "Changed service executed")
        }
        test("corrupt archive blocks deletion") {
            let mock = MockApplications(); mock.installed = true; mock.archiveCorrupt = true
            try rejects("повреждена") { _ = try app(mock).removeSSClash() }
            try check(!mock.removalCommitted && mock.installed, "No verified backup but files removed")
        }
        test("oversized recovery archive is not transferred or committed") {
            let mock = MockApplications(); mock.installed = true; mock.hugeArchive = true
            try rejects("256 МиБ") { _ = try app(mock).removeSSClash() }
            try check(!mock.archiveRead && !mock.removalCommitted, "Unbounded archive transfer")
        }
        test("device identity changes block removal commit") {
            let mock = MockApplications(); mock.installed = true; mock.changeIdentity = true; mock.driftAt = 3
            try rejects("изменились") { _ = try app(mock).removeSSClash() }
            try check(mock.archiveRead && !mock.removalCommitted, "Wrong modem committed")
        }
        test("lost commit acknowledgement retains recoverable local archive") {
            let mock = MockApplications(); mock.installed = true; mock.removalACKLost = true
            let manager = try app(mock)
            try rejects("acknowledgement lost") { _ = try manager.removeSSClash() }
            let files = try FileManager.default.contentsOfDirectory(at: manager.engine.logDirectory, includingPropertiesForKeys: nil)
            try check(mock.removalCommitted && files.contains { $0.pathExtension == "gz" }, "Uncertain removal lost archive")
            let journal = files.first { $0.lastPathComponent.hasPrefix("ssclash-remove-") }!
            let record = try readJSON([String: String].self, journal)
            try check(record["archive_sha256"] == digest(mock.archiveData) && record["phase"] == "needs-inspection", "Recovery journal lost verified archive hash")
        }
        test("form encoding does not create additional fields") {
            try check(ModemApplications.formEscape("a&b= +\"é") == "a%26b%3D%20%2B%22%C3%A9", "Incorrect percent encoding")
        }
        print("\(passed) passed; \(failed) failed")
        let generated = project.appendingPathComponent(".build/test-commands"); try secureDirectory(generated)
        try saveJSON(allMocks.flatMap(\.commands), generated.appendingPathComponent("modem-applications.json"))
        if failed > 0 { exit(1) }
    }
}
