import Foundation
import Darwin

private enum Failure: Error { case check(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.check(message) }
}
private func rejects(_ fragment: String, _ work: () throws -> Void) throws {
    do { try work() } catch let error as Failure { throw error } catch {
        try check(error.localizedDescription.contains(fragment), "Unexpected rejection: " + error.localizedDescription)
        return
    }
    throw Failure.check("Expected rejection: " + fragment)
}

private final class MockDisplay: RemoteTransport {
    var commands = [String](), inputs = [String: Data]()
    var identityCalls = 0, swappedAt = 0, rebootAt = 0
    var firmware = ModemEngine.firmwareHash
    var ui = ModemDisplayManager.uiHashes.sorted()[0], initHash = ModemDisplayManager.initHashes.sorted()[0]
    var root = "0", integrity = "0", enabled = "0", failure = "0", service = "0", startup = "0", running = "0", transaction = "0"
    var malformed = false, badUpload = false, installerFails = false, falseSuccess = false
    var locked = false, stage = "", cleaned = false, installerCalls = 0
    var launcherPreflightFails = false, launcherPreflightWrongReceipt = false, launcherPreflightCalls = 0
    var sequence = [String]()
    var vpnPresence = "ABSENT", vpnPreflightFails = false
    var installedAgentHash = String(repeating: "0", count: 64)
    var libraryHash: String, manifestHash: String
    var layoutBytes: Data?, stagedLayout: Data?, layoutStage = "", layoutCommits = 0
    var unsafeLayout = false, oversizedLayout = false, badLayoutUpload = false, layoutCommitFails = false, badLayoutReadback = false
    var pagesBytes: Data?, stagedPages: Data?, pagesStage = "", pagesCommits = 0
    var unsafePages = false, oversizedPages = false, badPagesUpload = false, pagesCommitFails = false, badPagesReadback = false
    init(hashes: [String: String]) { libraryHash = hashes["launcher.so"]!; manifestHash = hashes["launcher.sha256"]! }
    func ready(running: Bool = true) {
        root = "1"; integrity = "1"; enabled = "1"; service = "1"; startup = "1"; failure = "0"; transaction = "0"
        self.running = running ? "1" : "0"
    }
    func output(_ value: String = "", status: Int32 = 0) -> CommandResult {
        CommandResult(status: status, stdout: status == 0 ? Data(value.utf8) : Data(), stderr: status == 0 ? Data() : Data(value.utf8))
    }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            identityCalls += 1
            let cid = String(repeating: swappedAt > 0 && identityCalls >= swappedAt ? "b" : "a", count: 32)
            let boot = rebootAt > 0 && identityCalls >= rebootAt ? "22345678-1234-1234-1234-123456789abc" : "12345678-1234-1234-1234-123456789abc"
            return output("\(firmware)  /firmware/image/modem.b16\n\(ModemEngine.routerHash)  /usr/bin/diag-router\n\(cid)\n\(boot)\n")
        }
        if command == ModemDisplayManager.probeCommand {
            return output("MODEM_DISPLAY uid=0 arch=aarch64 ui=\(ui) init=\(initHash) root=\(root) integrity=\(integrity) enabled=\(enabled) failure=\(failure) service=\(service) startup=\(startup) running=\(running) transaction=\(transaction) installed=\(root == "0" ? "missing" : libraryHash) manifest=\(root == "0" ? "missing" : manifestHash)\(malformed ? " root=0" : "")\n")
        }
        if command == ModemDisplayManager.layoutReadCommand {
            if unsafeLayout { return output("MODEM_DISPLAY_LAYOUT unsafe\n") }
            if oversizedLayout { return output("MODEM_DISPLAY_LAYOUT oversized\n") }
            if let bytes = layoutBytes { return output("MODEM_DISPLAY_LAYOUT data\n" + bytes.base64EncodedString() + "\n") }
            return output("MODEM_DISPLAY_LAYOUT missing\n")
        }
        if command.hasPrefix("# MODEM_DISPLAY_LAYOUT_STAGE\n") {
            try check(locked && input != nil && command.contains("/sys/block/mmcblk0/device/cid") && command.contains("/proc/sys/kernel/random/boot_id") && command.contains("0:600:1"), "Layout staging lacks target/path guards")
            let line = command.components(separatedBy: "\n").first { $0.hasPrefix("cat > ") }!
            layoutStage = line.components(separatedBy: "'")[1]
            stagedLayout = input!
            return output((badLayoutUpload ? String(repeating: "0", count: 64) : digest(input!)) + "  " + layoutStage + "\n")
        }
        if command.hasPrefix("# MODEM_DISPLAY_LAYOUT_COMMIT\n") {
            try check(locked && stagedLayout != nil && command.contains("mv -f '") && command.contains("0:600:1") && command.contains("stat -c %s") && command.contains("sha256sum -c launcher.sha256"), "Layout commit lacks atomicity/integrity guards")
            if layoutCommitFails { return output("fixture layout pre-rename failure", status: 73) }
            layoutCommits += 1
            let bytes = stagedLayout!
            layoutBytes = badLayoutReadback ? Data("invalid".utf8) : bytes
            return output(digest(bytes) + "  " + ModemDisplayManager.layoutPath + "\n")
        }
        if command.hasPrefix("# MODEM_DISPLAY_LAYOUT_CLEANUP\n") {
            try check(!command.contains("rm -rf") && command.contains("/sys/block/mmcblk0/device/cid") && command.contains("/proc/sys/kernel/random/boot_id"), "Unsafe layout cleanup")
            stagedLayout = nil; return output()
        }
        if command == ModemDisplayManager.pagesReadCommand {
            if unsafePages { return output("MODEM_DISPLAY_PAGES unsafe\n") }
            if oversizedPages { return output("MODEM_DISPLAY_PAGES oversized\n") }
            if let bytes = pagesBytes { return output("MODEM_DISPLAY_PAGES data\n" + bytes.base64EncodedString() + "\n") }
            return output("MODEM_DISPLAY_PAGES missing\n")
        }
        if command.hasPrefix("# MODEM_DISPLAY_PAGES_STAGE\n") {
            try check(locked && input != nil && command.contains("/sys/block/mmcblk0/device/cid") && command.contains("/proc/sys/kernel/random/boot_id") && command.contains("0:600:1"), "Layout staging lacks target/path guards")
            let line = command.components(separatedBy: "\n").first { $0.hasPrefix("cat > ") }!
            pagesStage = line.components(separatedBy: "'")[1]
            stagedPages = input!
            return output((badPagesUpload ? String(repeating: "0", count: 64) : digest(input!)) + "  " + pagesStage + "\n")
        }
        if command.hasPrefix("# MODEM_DISPLAY_PAGES_COMMIT\n") {
            try check(locked && stagedPages != nil && command.contains("mv -f '") && command.contains("0:600:1") && command.contains("stat -c %s") && command.contains("sha256sum -c launcher.sha256"), "Layout commit lacks atomicity/integrity guards")
            if pagesCommitFails { return output("fixture layout pre-rename failure", status: 73) }
            pagesCommits += 1
            let bytes = stagedPages!
            pagesBytes = badPagesReadback ? Data("invalid".utf8) : bytes
            return output(digest(bytes) + "  " + ModemDisplayManager.pagesPath + "\n")
        }
        if command.hasPrefix("# MODEM_DISPLAY_PAGES_CLEANUP\n") {
            try check(!command.contains("rm -rf") && command.contains("/sys/block/mmcblk0/device/cid") && command.contains("/proc/sys/kernel/random/boot_id"), "Unsafe layout cleanup")
            stagedPages = nil; return output()
        }
        if command.contains("if mkdir /tmp/zte-imei-app.lock") { locked = true; return output() }
        if command.contains("&& rm /tmp/zte-imei-app.lock/owner") { locked = false; return output() }
        if command.hasPrefix("umask 077; mkdir '/tmp/zte-vpn-agent-") {
            try check(locked && stage.isEmpty, "Stage without common remote lock")
            stage = command.components(separatedBy: "'")[1]; return output()
        }
        if command.hasPrefix("umask 077; cat > '/tmp/zte-vpn-agent-") {
            let path = command.components(separatedBy: "'")[1]
            try check(locked && path.hasPrefix(stage + "/") && input != nil, "Upload escaped locked stage")
            let name = URL(fileURLWithPath: path).lastPathComponent
            try check(ModemDisplayManager.fileNames.contains(name), "Unrelated payload uploaded")
            inputs[name] = input!
            return output((badUpload ? String(repeating: "0", count: 64) : digest(input!)) + "  " + path + "\n")
        }
        if command.hasPrefix("set -eu; test \"$(cat /tmp/zte-imei-app.lock/owner)") {
            try check(locked && inputs.count == 7 && command.contains("/sys/block/mmcblk0/device/cid") && command.contains("/proc/sys/kernel/random/boot_id") && command.contains(stage + "/install-launcher.sh"), "Installer lacks target/lock binding")
            if command.hasSuffix(" preflight") {
                launcherPreflightCalls += 1; sequence.append("preflight")
                return output(launcherPreflightWrongReceipt ? "WRONG" : "LAUNCHER_PREFLIGHT_OK",status:launcherPreflightFails ? 1 : 0)
            }
            sequence.append("install")
            installerCalls += 1
            if installerFails { return output("fixture launcher failure", status: 73) }
            if !falseSuccess { ready(running: false) }
            return output("LAUNCHER_INSTALLED\n")
        }
        if command.hasPrefix("rm -f '/tmp/zte-vpn-agent-") {
            try check(!command.contains("rm -rf") && command.contains("; rmdir '" + stage + "'"), "Unsafe cleanup")
            cleaned = true; stage = ""; return output()
        }
        if command.hasPrefix("if test -e /data/zte-vpn ||") { return output(vpnPresence) }
        if command.hasPrefix("test -d /data/zte-vpn &&") {
            return output(vpnPreflightFails ? "incomplete VPN integration" : "", status: vpnPreflightFails ? 1 : 0)
        }
        if command == "sha256sum /data/zte-agent | awk '{print $1}'" { return output(installedAgentHash) }
        throw Failure.check("Unexpected command: " + String(command.prefix(160)))
    }
}

@main struct ModemDisplayTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        let hashes = try readJSON([String: String].self, resources.appendingPathComponent("VPN/SHA256.json"))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zte-display-tests-" + UUID().uuidString)
        try secureDirectory(temp); defer { try? FileManager.default.removeItem(at: temp) }
        let key = temp.appendingPathComponent("key"), hosts = temp.appendingPathComponent("known_hosts")
        try savePrivate(Data("fixture".utf8), key); try savePrivate(Data("fixture".utf8), hosts)
        var mocks = [MockDisplay]()
        func make(_ mock: MockDisplay, resources custom: URL? = nil, updater: (() throws -> Bool)? = { false }, prepareAgent: (() throws -> Void)? = nil, checkedFirmware: Bool = false) throws -> ModemDisplayManager {
            mocks.append(mock)
            let connection = Connection(host: "192.168.0.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path, skipFirmwareCheck: !checkedFirmware)
            let engine = try ModemEngine(root: temp.appendingPathComponent(UUID().uuidString), resources: custom ?? resources, connection: connection, transport: mock)
            return ModemDisplayManager(engine: engine, updateVPNIntegration: updater, prepareEsimAgent: prepareAgent)
        }
        func install(_ manager: ModemDisplayManager) throws -> ModemDisplayInspection { try manager.engine.locked { try manager.install() } }
        func apply(_ manager: ModemDisplayManager, _ layout: ModemDisplayLayout) throws -> ModemDisplayInspection {
            try manager.engine.locked { try manager.applyLayout(layout) }
        }
        func reorderedLayout() -> ModemDisplayLayout {
            var value = ModemDisplayLayout.defaultLayout
            value.items.swapAt(0, 8)
            value.items[0].enabled = true
            value.items[8].enabled = false
            return value
        }
        func resourceCopy() throws -> URL {
            let root = temp.appendingPathComponent(UUID().uuidString), directory = root.appendingPathComponent("VPN")
            try secureDirectory(directory)
            for name in ModemDisplayManager.fileNames + ["SHA256.json"] {
                try FileManager.default.copyItem(at: resources.appendingPathComponent("VPN/" + name), to: directory.appendingPathComponent(name))
            }
            return root
        }
        func integrationResources(script: String, corrupt: Bool = false) throws -> URL {
            let root = temp.appendingPathComponent(UUID().uuidString), directory = root.appendingPathComponent("VPN")
            try secureDirectory(directory)
            let data = Data(script.utf8)
            try savePrivate(data, directory.appendingPathComponent("update-agent.sh"))
            try saveJSON(["update-agent.sh": corrupt ? String(repeating: "0", count: 64) : digest(data)], directory.appendingPathComponent("SHA256.json"))
            return root
        }
        func updateIntegration(_ value: ModemDisplayManager) throws -> Bool {
            try value.engine.locked {
                try value.engine.acquireRemoteLock()
                return try VPNSettingsManager(engine: value.engine).updateDisplayIntegrationIfNeeded()
            }
        }
        var passed = 0, failed = 0
        func test(_ name: String, _ work: () throws -> Void) {
            do { try work(); passed += 1; print("PASS " + name) }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        test("absent inspection reads only metadata and binds both identity samples") {
            let mock = MockDisplay(hashes: hashes), result = try make(mock).inspect()
            try check(result.state == .absent && result.canInstall && !result.running, "False readiness")
            try check(mock.commands.count == 3 && mock.identityCalls == 2 && !mock.locked && mock.inputs.isEmpty, "Inspection mutated device")
        }
        test("ready requires exact packaged hashes and actual mapped extension") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let value = try make(mock)
            try check(value.inspect().state == .ready && value.inspect().running, "Current running extension not recognized")
            mock.running = "0"
            let waiting = try value.inspect()
            try check(waiting.state == .ready && !waiting.running && waiting.detail.contains("ещё не подтверждена"), "Installation mislabeled as running")
        }
        test("old library or old companion manifest is outdated") {
            for library in [true, false] {
                let mock = MockDisplay(hashes: hashes); mock.ready()
                if library { mock.libraryHash = String(repeating: "0", count: 64) } else { mock.manifestHash = String(repeating: "0", count: 64) }
                try check(make(mock).inspect().state == .outdated, "Mixed/old components not reported")
            }
        }
        test("B02 is unsupported despite disabled general firmware check") {
            let mock = MockDisplay(hashes: hashes); mock.firmware = "7f1905a2844337640c08b66edffbde147adf20b3ab3e1e54fefe4939c40e633e"
            let value = try make(mock)
            try check(value.inspect().state == .unsupported, "B02 granted display ABI")
            try rejects("только для экранного") { _ = try install(value) }
            try check(mock.inputs.isEmpty && mock.stage.isEmpty && !mock.commands.contains(where: { $0.contains("if mkdir") }), "Unsupported firmware reached write")
        }
        test("unknown screen binary or stock init rejects before write") {
            for ui in [true, false] {
                let mock = MockDisplay(hashes: hashes)
                if ui { mock.ui = String(repeating: "0", count: 64) } else { mock.initHash = String(repeating: "0", count: 64) }
                try rejects("только для экранного") { _ = try install(make(mock)) }
                try check(mock.stage.isEmpty && mock.inputs.isEmpty, "Unknown ABI uploaded")
            }
        }
        test("unowned paths and corrupt files block automatic repair") {
            for cause in ["owner", "integrity", "service", "transaction"] {
                let mock = MockDisplay(hashes: hashes); mock.ready()
                if cause == "owner" { mock.root = "2" }
                if cause == "integrity" { mock.integrity = "0" }
                if cause == "service" { mock.service = "0" }
                if cause == "transaction" { mock.transaction = "2" }
                let state = try make(mock).inspect()
                try check(state.state == .failed && !state.canInstall, "Untrusted state repair enabled")
            }
        }
        test("owned intact launcher with absent service is reinstallable after reset") {
            let mock = MockDisplay(hashes: hashes); mock.ready(running: false)
            mock.service = "2"; mock.startup = "0"
            mock.layoutBytes = try reorderedLayout().encoded()
            let saved = mock.layoutBytes
            let value = try make(mock)
            let state = try value.inspect()
            try check(state.state == .failed && state.canInstall && !state.running, "Missing service cannot be repaired")
            let repaired = try install(value)
            try check(repaired.state == .ready && mock.installerCalls == 1 && mock.layoutBytes == saved, "Reset repair changed layout or skipped installer")
        }
        test("absent service never authorizes corrupt or unsafe launcher data") {
            for cause in ["integrity", "layout", "pages"] {
                let mock = MockDisplay(hashes: hashes); mock.ready(); mock.service = "2"
                if cause == "integrity" { mock.integrity = "0" }
                if cause == "layout" { mock.unsafeLayout = true }
                if cause == "pages" { mock.unsafePages = true }
                try check(!make(mock).inspect().canInstall, "Missing service bypassed " + cause)
            }
        }
        test("owned interrupted transaction offers checked recovery") {
            let mock = MockDisplay(hashes: hashes); mock.transaction = "1"
            let value = try make(mock)
            try check(value.inspect().state == .recoveryPending && value.inspect().canInstall, "Owned journal blocked")
            try check(install(value).state == .ready && mock.installerCalls == 1, "Recovery was not delegated to verified installer")
        }
        test("watchdog failure remains explicit and repairable") {
            let mock = MockDisplay(hashes: hashes); mock.ready(); mock.failure = "1"
            let result = try make(mock).inspect()
            try check(result.state == .failed && result.canInstall && !result.running, "Watchdog error hidden")
        }
        test("duplicate probe fields are rejected") {
            let mock = MockDisplay(hashes: hashes); mock.malformed = true
            try rejects("Повтор") { _ = try make(mock).inspect() }
        }
        test("corrupt bundled component rejects before SSH") {
            let copy = try resourceCopy()
            try savePrivate(Data("bad".utf8), copy.appendingPathComponent("VPN/launcher.so"))
            let mock = MockDisplay(hashes: hashes)
            try rejects("Повреждён встроенный") { _ = try install(make(mock, resources: copy)) }
            try check(mock.commands.isEmpty, "Untrusted bundle reached SSH")
        }
        test("manifest traversal or inconsistent payload checksums reject before SSH") {
            let copy = try resourceCopy(), file = copy.appendingPathComponent("VPN/launcher.sha256")
            let bytes = Data((String(repeating: "0", count: 64) + "  ../../launcher.so\n").utf8)
            try savePrivate(bytes, file)
            var manifest = hashes; manifest["launcher.sha256"] = digest(bytes)
            try saveJSON(manifest, copy.appendingPathComponent("VPN/SHA256.json"))
            let mock = MockDisplay(hashes: hashes)
            try rejects("список контрольных сумм") { _ = try install(make(mock, resources: copy)) }
            try check(mock.commands.isEmpty, "Unsafe payload manifest used")
        }
        test("standalone install uploads exactly seven launcher files under both locks") {
            let mock = MockDisplay(hashes: hashes), value = try make(mock, updater: nil)
            let result = try install(value)
            try check(result.state == .ready && !result.running && mock.cleaned && mock.installerCalls == 1 && !mock.locked, "Incomplete standalone install")
            try check(Set(mock.inputs.keys) == Set(ModemDisplayManager.fileNames) && mock.identityCalls == 8, "Unrelated files or missing target checks")
            try check(!mock.commands.contains(where: { $0.contains("update-agent.sh") || $0.contains("upgrade-controller.sh") || $0.contains("/install.sh") }), "Absent VPN installed dependencies")
        }
        test("already current running display requires no upload or integration update") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let value = try make(mock, updater: { throw Failure.check("Redundant VPN update") })
            try check(install(value).running && mock.inputs.isEmpty && mock.installerCalls == 0, "Current installation overwritten")
        }
        test("eSIM page preflight failure or wrong receipt prevents component updates") {
            for wrongReceipt in [false,true] {
                let mock = MockDisplay(hashes:hashes); mock.launcherPreflightFails = !wrongReceipt; mock.launcherPreflightWrongReceipt = wrongReceipt
                let manager = try make(mock,updater:{throw Failure.check("Preflight failure updated VPN")},prepareAgent:{throw Failure.check("Preflight failure updated agent")},checkedFirmware:true)
                try rejects(wrongReceipt ? "Предварительная проверка" : "LAUNCHER_PREFLIGHT_OK") { _ = try manager.engine.locked { try manager.installEsimPage() } }
                try check(mock.launcherPreflightCalls == 1 && mock.installerCalls == 0 && mock.cleaned,"Preflight refusal reached launcher mutation")
            }
        }
        test("eSIM standalone page prepares agent after preflight and never installs VPN") {
            let mock = MockDisplay(hashes:hashes)
            let manager = try make(mock,updater:{mock.sequence.append("vpn-absent");return false},prepareAgent:{mock.sequence.append("agent")},checkedFirmware:true)
            let result = try manager.engine.locked { try manager.installEsimPage() }
            try check(result.state == .ready && mock.sequence == ["preflight","vpn-absent","agent","install"],"eSIM standalone update order")
            try check(mock.layoutCommits == 0 && !mock.commands.contains{$0.contains("upgrade-controller.sh") || $0.contains("/install.sh")},"eSIM page installed VPN or local layout")
        }
        test("eSIM page existing VPN uses one integration and preserves saved layout") {
            let mock=MockDisplay(hashes:hashes);mock.ready();mock.layoutBytes=try reorderedLayout().encoded()
            let manager=try make(mock,updater:{mock.sequence.append("vpn-existing");return true},prepareAgent:{throw Failure.check("Duplicate agent update")},checkedFirmware:true)
            let result=try manager.engine.locked { try manager.installEsimPage() }
            try check(result.layout == reorderedLayout() && mock.sequence == ["preflight","vpn-existing"] && mock.installerCalls == 0 && mock.layoutCommits == 0,"eSIM page duplicated integration or changed layout")
        }
        test("eSIM page refuses malformed layout and detects changed layout after integration") {
            let invalid=MockDisplay(hashes:hashes);invalid.ready();invalid.layoutBytes=Data("invalid".utf8)
            let a=try make(invalid,updater:{throw Failure.check("Invalid layout updated components")},checkedFirmware:true)
            try rejects("настройка дисплея повреждена") { _ = try a.engine.locked { try a.installEsimPage() } }
            try check(invalid.inputs.isEmpty,"Malformed layout reached stage")
            let changed=MockDisplay(hashes:hashes);changed.ready();changed.layoutBytes=try reorderedLayout().encoded()
            let b=try make(changed,updater:{changed.layoutBytes=nil;return true},checkedFirmware:true)
            try rejects("сохранение раскладки не подтверждено") { _ = try b.engine.locked { try b.installEsimPage() } }
        }
        test("existing VPN integration completes under common lock and is rechecked") {
            let mock = MockDisplay(hashes: hashes)
            let value = try make(mock, updater: { try check(mock.locked, "Integration update unlocked"); mock.ready(running: false); return true })
            try check(install(value).state == .ready && mock.stage.isEmpty && mock.identityCalls == 6, "Integration result not independently checked")
        }
        test("CID change during status or before staging stops writes") {
            for index in [2, 3] {
                let mock = MockDisplay(hashes: hashes); mock.swappedAt = index
                try rejects("модем изменился") { _ = try install(make(mock)) }
                try check(mock.stage.isEmpty && mock.inputs.isEmpty, "Changed target reached upload")
            }
        }
        test("reboot after upload stops installer and cleans owned stage") {
            let mock = MockDisplay(hashes: hashes); mock.rebootAt = 5
            try rejects("модем изменился") { _ = try install(make(mock)) }
            try check(mock.installerCalls == 0 && mock.cleaned, "Rebooted target used")
        }
        test("upload hash mismatch stops installer and cleans only owned stage") {
            let mock = MockDisplay(hashes: hashes); mock.badUpload = true
            try rejects("При передаче повреждён") { _ = try install(make(mock)) }
            try check(mock.installerCalls == 0 && mock.cleaned && mock.inputs.count == 1, "Corrupt upload executed")
        }
        test("installer error is retained without false readiness") {
            let mock = MockDisplay(hashes: hashes); mock.installerFails = true
            try rejects("fixture launcher failure") { _ = try install(make(mock)) }
            try check(mock.cleaned && mock.root == "0", "Installer failure hidden")
        }
        test("success marker alone does not establish successful install") {
            let mock = MockDisplay(hashes: hashes); mock.falseSuccess = true
            try rejects("не подтвердил ожидаемое") { _ = try install(make(mock)) }
        }
        test("local operation lock and pending transactions block writes") {
            let mock = MockDisplay(hashes: hashes), value = try make(mock)
            try rejects("общей блокировки") { _ = try value.install() }
            try savePrivate(Data(), value.engine.root.appendingPathComponent("setup-pending.json"))
            try rejects("Сначала завершите") { _ = try install(value) }
            try check(mock.commands.isEmpty, "Pending setup reached modem")
        }
        test("VPN integration helper requires both locks and absent VPN is read only") {
            let mock = MockDisplay(hashes: hashes), value = try make(mock), vpn = VPNSettingsManager(engine: value.engine)
            try rejects("блокировки") { _ = try vpn.updateDisplayIntegrationIfNeeded() }
            try value.engine.locked {
                try rejects("блокировки") { _ = try vpn.updateDisplayIntegrationIfNeeded() }
                try value.engine.acquireRemoteLock()
                try check(vpn.updateDisplayIntegrationIfNeeded() == false, "Absent VPN upgraded")
            }
            try check(mock.inputs.isEmpty && mock.stage.isEmpty, "Absent VPN mutated")
        }
        test("incomplete VPN dependencies stop before stage") {
            let mock = MockDisplay(hashes: hashes); mock.vpnPresence = "PRESENT"; mock.vpnPreflightFails = true
            let value = try make(mock, updater: nil)
            try rejects("incomplete VPN integration") { _ = try install(value) }
            try check(mock.inputs.isEmpty && mock.stage.isEmpty, "Broken VPN integration overwritten")
        }
        test("unknown installed agent stops before controller replacement or payload staging") {
            let script = "#!/bin/sh\ncase \"$(hash /data/zte-agent)\" in " + String(repeating: "1", count: 64) + "|\"$agent_sha\") ;; *) exit 1;; esac\n"
            let fixture = try integrationResources(script: script)
            let mock = MockDisplay(hashes: hashes); mock.vpnPresence = "PRESENT"
            let value = try make(mock, resources: fixture, updater: nil)
            try rejects("Установлен сторонний агент") { _ = try updateIntegration(value) }
            try check(mock.commands.contains("sha256sum /data/zte-agent | awk '{print $1}'"), "Installed agent was not checked")
            try check(mock.stage.isEmpty && mock.inputs.isEmpty && mock.installerCalls == 0 && !mock.locked, "Unknown agent reached mutation or retained lock")
        }
        test("corrupt integration installer fails before installed-agent read or any payload") {
            let fixture = try integrationResources(script: "#!/bin/sh\nexit 0\n", corrupt: true)
            let mock = MockDisplay(hashes: hashes); mock.vpnPresence = "PRESENT"
            let value = try make(mock, resources: fixture, updater: nil)
            try rejects("Повреждён установщик компонентов дисплея") { _ = try updateIntegration(value) }
            try check(!mock.commands.contains("sha256sum /data/zte-agent | awk '{print $1}'") && mock.stage.isEmpty && mock.inputs.isEmpty && mock.installerCalls == 0, "Corrupt installer affected integration")
        }
        test("compiled agent policy cannot be expanded by shell formatting or wildcard") {
            for script in ["#!/bin/sh\nexit 0\n", "#!/bin/sh\ncase anything in *) exit 0;; esac\n"] {
                let fixture = try integrationResources(script: script)
                let mock = MockDisplay(hashes: hashes); mock.vpnPresence = "PRESENT"
                let value = try make(mock, resources: fixture, updater: nil)
                try rejects("Установлен сторонний агент") { _ = try updateIntegration(value) }
                try check(mock.commands.contains("sha256sum /data/zte-agent | awk '{print $1}'") && mock.stage.isEmpty && mock.inputs.isEmpty, "Unknown binary escaped compiled policy")
            }
            try check(BundledAgent.supportedUpgradeHashes.contains(BundledAgent.sha256) && !BundledAgent.supportedUpgradeHashes.contains(String(repeating:"0",count:64)), "Compiled policy boundary")
        }
        test("layout default contains twelve IDs with exactly the original first six enabled") {
            let value = ModemDisplayLayout.defaultLayout
            try check(value.items.count == 12 && value.style == .list && value.enabledCount == 6 && value.items.prefix(6).allSatisfy(\.enabled), "Changed default")
            try check(ModemDisplayLayout.decode(value.encoded()) == value, "Wire format round trip failed")
        }
        test("layout reorder and selection persist exactly without dropping disabled rows") {
            let value = reorderedLayout(), data = try value.encoded()
            try check(ModemDisplayLayout.decode(data) == value && data.count <= 512 && data.last == 10, "Reorder lost on wire")
            try check(String(decoding: data, as: UTF8.self).hasPrefix("ZTE_INFO_LAYOUT_V2\nstyle=list\nuptime=1\n"), "Display order not encoded")
        }
        test("layout accepts all twelve metrics for physical scrolling and rejects zero") {
            let all = ModemDisplayLayout(items: ModemDisplayMetric.allCases.map { ModemDisplayLayoutItem(metric: $0, enabled: true) })
            try check(ModemDisplayLayout.decode(all.encoded()) == all && all.enabledCount == 12, "Scrollable layout rejected")
            let none = ModemDisplayLayout(items: all.items.map { ModemDisplayLayoutItem(metric: $0.metric, enabled: false) })
            try rejects("Выберите от 1 до 12") { try none.validate() }
        }
        test("both page styles preserve twelve metrics order and selection") {
            for style in ModemDisplayPageStyle.allCases {
                var value = reorderedLayout(); value.style = style
                let bytes = try value.encoded()
                try check(ModemDisplayLayout.decode(bytes) == value && bytes.count <= 512, "Page style lost in wire round trip")
                try check(String(decoding: bytes, as: UTF8.self).hasPrefix("ZTE_INFO_LAYOUT_V2\nstyle=" + style.rawValue + "\n"), "Wrong style header")
            }
        }
        test("legacy V1 migrates order and selection to list with new metrics disabled") {
            let oldItems = Array(reorderedLayout().items.filter { ![.battery, .rsrq, .sinr].contains($0.metric) })
            let old = "ZTE_INFO_LAYOUT_V1\n" + oldItems.map { $0.metric.rawValue + "=" + ($0.enabled ? "1" : "0") + "\n" }.joined()
            let migrated = try ModemDisplayLayout.decode(Data(old.utf8))
            try check(migrated.style == .list && Array(migrated.items.prefix(9)) == oldItems && migrated.items.suffix(3).allSatisfy { !$0.enabled }, "Legacy settings changed during migration")
            try check(migrated.items.suffix(3).map(\.metric) == [.battery, .rsrq, .sinr], "Missing newly available metrics")
            let invalid = old.replacingOccurrences(of: "signal=1", with: "battery=1")
            try rejects("предыдущей версии") { _ = try ModemDisplayLayout.decode(Data(invalid.utf8)) }
        }
        test("saved JSON without page style remains compatible and defaults to list") {
            struct LegacyLayout: Encodable { var items: [ModemDisplayLayoutItem] }
            let old = LegacyLayout(items: Array(ModemDisplayLayout.defaultLayout.items.prefix(9)))
            let migrated = try JSONDecoder().decode(ModemDisplayLayout.self, from: JSONEncoder().encode(old))
            try check(migrated == .defaultLayout, "Stored JSON lost backwards compatibility")
            var tiles = reorderedLayout(); tiles.style = .tiles
            try check(JSONDecoder().decode(ModemDisplayLayout.self, from: JSONEncoder().encode(tiles)) == tiles, "Stored JSON lost grid style")
        }
        test("layout rejects duplicates missing unknown malformed oversized and non-ASCII data") {
            let valid = String(decoding: try ModemDisplayLayout.defaultLayout.encoded(), as: UTF8.self)
            let bad = [valid.replacingOccurrences(of: "signal=1", with: "cpu=1"),
                       valid.replacingOccurrences(of: "signal=1\n", with: ""),
                       valid.replacingOccurrences(of: "signal=1", with: "unknown=1"),
                       valid.replacingOccurrences(of: "signal=1", with: "signal=true"),
                       valid.replacingOccurrences(of: "V2", with: "V3"),
                       valid.replacingOccurrences(of: "style=list", with: "style=grid"),
                       valid.replacingOccurrences(of: "style=list\n", with: ""),
                       valid.replacingOccurrences(of: "style=list", with: "style=list\nstyle=tiles"),
                       valid.replacingOccurrences(of: "cpu=1", with: "cpu=1 "),
                       String(valid.dropLast()), valid + "\n", valid + String(repeating: "x", count: 513),
                       valid.replacingOccurrences(of: "cpu=1", with: "cpu=é"), valid.replacingOccurrences(of: "\n", with: "\r\n")]
            for string in bad {
                do { _ = try ModemDisplayLayout.decode(Data(string.utf8)); throw Failure.check("Malformed layout accepted") }
                catch let error as Failure { throw error } catch { }
            }
        }
        test("inspection reads saved order while absent config reports explicit defaults") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let manager = try make(mock), initial = try manager.inspect()
            try check(initial.layoutIsDefault && initial.layout == .defaultLayout && initial.layoutWarning == nil, "Missing config not distinguished")
            mock.layoutBytes = try reorderedLayout().encoded()
            let saved = try manager.inspect()
            try check(saved.layout == reorderedLayout() && !saved.layoutIsDefault && saved.canApplyLayout, "Saved device order ignored")
        }
        test("malformed safe config is explicit and can be repaired without reinstall") {
            let mock = MockDisplay(hashes: hashes); mock.ready(); mock.layoutBytes = Data("invalid".utf8)
            let manager = try make(mock), invalid = try manager.inspect()
            try check(invalid.layout == nil && invalid.layoutWarning != nil && !invalid.layoutIsDefault && invalid.canApplyLayout, "Invalid config silently treated as loaded defaults")
            let result = try apply(manager, reorderedLayout())
            try check(result.layout == reorderedLayout() && result.layoutWarning == nil && mock.installerCalls == 0, "Malformed config repair failed")
        }
        test("unsafe symlink owner permissions or oversized config blocks installation and save") {
            for tooLarge in [false, true] {
                let mock = MockDisplay(hashes: hashes); mock.ready(); mock.unsafeLayout = !tooLarge; mock.oversizedLayout = tooLarge
                let manager = try make(mock), state = try manager.inspect()
                try check(state.layout == nil && !state.canInstall && !state.canApplyLayout && !state.layoutIsSafe, "Unsafe config writable")
                try rejects("заблокирована") { _ = try apply(manager, reorderedLayout()) }
                try rejects("заблокирована") { _ = try install(manager) }
                try check(mock.layoutCommits == 0 && mock.layoutStage.isEmpty && mock.inputs.isEmpty && mock.stage.isEmpty, "Unsafe path reached mutation")
            }
            try check(ModemDisplayManager.layoutReadCommand.contains("test -L \"$file\"") && ModemDisplayManager.layoutReadCommand.contains("0:600:1"), "Symlink/owner/link-count checks missing")
        }
        test("configuration-only save verifies atomic replacement without service or VPN update") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let manager = try make(mock, updater: { throw Failure.check("Configuration updated VPN") })
            let result = try apply(manager, reorderedLayout())
            try check(result.layout == reorderedLayout() && mock.layoutCommits == 1 && mock.installerCalls == 0 && mock.inputs.isEmpty && mock.stagedLayout == nil && !mock.locked, "Configuration workflow mutated unrelated components")
            try check(!mock.commands.contains { $0.contains("/install-launcher.sh") || $0.contains(" restart") || $0.contains("update-agent.sh") }, "Configuration restarted/reinstalled services")
        }
        test("style-only save reaches modem and readback without reinstall") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let original = ModemDisplayLayout.defaultLayout
            mock.layoutBytes = try original.encoded()
            var tiles = original; tiles.style = .tiles
            let manager = try make(mock, updater: { throw Failure.check("Style change updated VPN") })
            let result = try apply(manager, tiles)
            try check(result.layout == tiles && result.layout?.style == .tiles && mock.layoutCommits == 1 && mock.installerCalls == 0, "Selected native style was not saved")
        }
        test("unchanged explicit layout requires no upload") {
            let mock = MockDisplay(hashes: hashes); mock.ready(); mock.layoutBytes = try reorderedLayout().encoded()
            _ = try apply(make(mock), reorderedLayout())
            try check(mock.layoutStage.isEmpty && mock.layoutCommits == 0, "Unchanged configuration rewritten")
        }
        test("install on current running launcher applies selected layout without reinstall") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let manager = try make(mock, updater: { throw Failure.check("Current display updated VPN") })
            let result = try manager.engine.locked { try manager.install(layout: reorderedLayout()) }
            try check(result.layout == reorderedLayout() && mock.layoutCommits == 1 && mock.installerCalls == 0, "Running launcher ignored configuration")
        }
        test("fresh installation applies selected layout after confirmed install") {
            let mock = MockDisplay(hashes: hashes), manager = try make(mock)
            let result = try manager.engine.locked { try manager.install(layout: reorderedLayout()) }
            try check(result.layout == reorderedLayout() && mock.layoutCommits == 1 && mock.installerCalls == 1, "Installed without selected layout")
        }
        test("config-only unsupported old absent or pending installation never reaches writes") {
            for cause in ["unsupported", "old", "absent", "pending"] {
                let mock = MockDisplay(hashes: hashes); mock.ready()
                if cause == "unsupported" { mock.ui = String(repeating: "0", count: 64) }
                if cause == "old" { mock.libraryHash = String(repeating: "0", count: 64) }
                if cause == "absent" { mock.root = "0" }
                if cause == "pending" { mock.transaction = "1" }
                try rejects("Сначала установите") { _ = try apply(make(mock), reorderedLayout()) }
                try check(mock.layoutStage.isEmpty && mock.layoutCommits == 0 && !mock.commands.contains(where: { $0.contains("if mkdir") }), "Untrusted install reached config write")
            }
        }
        test("invalid selection is rejected before even reading modem") {
            let mock = MockDisplay(hashes: hashes), manager = try make(mock)
            let value = ModemDisplayLayout(items: [])
            try rejects("каждый показатель") { _ = try apply(manager, value) }
            try check(mock.commands.isEmpty, "Invalid local selection reached device")
        }
        test("CID change and reboot before configuration commit preserve existing file") {
            for reboot in [false, true] {
                let mock = MockDisplay(hashes: hashes); mock.ready(); mock.layoutBytes = try ModemDisplayLayout.defaultLayout.encoded()
                if reboot { mock.rebootAt = 5 } else { mock.swappedAt = 5 }
                try rejects("модем изменился") { _ = try apply(make(mock), reorderedLayout()) }
                try check(mock.layoutCommits == 0 && mock.layoutBytes == ModemDisplayLayout.defaultLayout.encoded(), "Changed target replaced config")
            }
        }
        test("bad upload and pre-rename failure preserve existing configuration") {
            for upload in [true, false] {
                let mock = MockDisplay(hashes: hashes); mock.ready(); mock.layoutBytes = try ModemDisplayLayout.defaultLayout.encoded()
                mock.badLayoutUpload = upload; mock.layoutCommitFails = !upload
                try rejects(upload ? "При передаче повреждена" : "fixture layout pre-rename failure") { _ = try apply(make(mock), reorderedLayout()) }
                try check(mock.layoutCommits == 0 && mock.layoutBytes == ModemDisplayLayout.defaultLayout.encoded() && mock.stagedLayout == nil, "Pre-rename failure damaged existing configuration")
            }
        }
        test("hash acknowledgement without matching readback cannot report success") {
            let mock = MockDisplay(hashes: hashes); mock.ready(); mock.badLayoutReadback = true
            try rejects("Проверка сохранённой") { _ = try apply(make(mock), reorderedLayout()) }
            try check(mock.layoutCommits == 1, "Fixture did not reach readback")
        }
        test("page grammar covers ordered subsets empty selection and malformed inputs") {
            let all = ModemLauncherPage.allCases
            let variants: [[ModemLauncherPage]] = [[]] + all.map { [$0] } + all.flatMap { a in all.filter { $0 != a }.map { [a, $0] } } + all.flatMap { a in all.filter { $0 != a }.flatMap { b in all.filter { $0 != a && $0 != b }.map { [a, b, $0] } } }
            try check(variants.count == 16, "Missing ordered subset fixture")
            for pages in variants {
                let value = ModemLauncherPages(pages: pages)
                try check(ModemLauncherPages.decode(value.encoded()) == value, "Pages did not round-trip")
            }
            for raw in ["", "ZTE_LAUNCHER_PAGES_V1", "ZTE_LAUNCHER_PAGES_V1\ninfo\ninfo\n", "ZTE_LAUNCHER_PAGES_V1\nunknown\n", "ZTE_LAUNCHER_PAGES_V1\n\n", "ZTE_LAUNCHER_PAGES_V1\r\n", "ZTE_LAUNCHER_PAGES_V1\n info\n", String(repeating: "x", count: 129)] {
                do { _ = try ModemLauncherPages.decode(Data(raw.utf8)); throw Failure.check("Malformed page list accepted") }
                catch let failure as Failure { throw failure } catch { }
            }
        }
        test("page defaults differ from explicit no additional pages") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let manager = try make(mock)
            let initial = try manager.inspect()
            try check(initial.pagesIsDefault && initial.pages == .defaultPages, "Missing page config is not all three")
            mock.pagesBytes = try ModemLauncherPages(pages: []).encoded()
            let empty = try manager.inspect()
            try check(!empty.pagesIsDefault && empty.pages?.pages == [] && empty.canApplyPages, "Explicit zero selection replaced by defaults")
        }
        test("pages save is atomic and does not reinstall restart or call agent") {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            let manager = try make(mock, updater: { throw Failure.check("Pages updated VPN") })
            let pages = ModemLauncherPages(pages: [.vpn, .info])
            let result = try manager.engine.locked { try manager.applyPages(pages) }
            try check(result.pages == pages && mock.pagesCommits == 1 && mock.stagedPages == nil && !mock.locked, "Pages were not verified and cleaned")
            try check(mock.layoutCommits == 0 && mock.installerCalls == 0 && mock.inputs.isEmpty && !mock.commands.contains { $0.contains(" restart") || $0.contains("/install-launcher.sh") || $0.contains("--esim") }, "Preferences changed components")
        }
        test("invalid unsafe and oversized page config refuses install and save") {
            for cause in 0...2 {
                let mock = MockDisplay(hashes: hashes); mock.ready()
                if cause == 0 { mock.pagesBytes = Data("invalid".utf8) }
                if cause == 1 { mock.unsafePages = true }
                if cause == 2 { mock.oversizedPages = true }
                let manager = try make(mock), value = try manager.inspect()
                try check(!value.canInstall && !value.canApplyPages && value.pages == nil, "Invalid pages accepted")
                do { _ = try manager.engine.locked { try manager.applyPages(.defaultPages) }; throw Failure.check("Unsafe page write allowed") }
                catch let failure as Failure { throw failure } catch { }
                try check(mock.pagesStage.isEmpty && mock.pagesCommits == 0, "Invalid page path reached mutation")
            }
        }
        test("page upload rename and readback failures cannot report success") {
            for cause in 0...2 {
                let mock = MockDisplay(hashes: hashes); mock.ready()
                mock.badPagesUpload = cause == 0; mock.pagesCommitFails = cause == 1; mock.badPagesReadback = cause == 2
                let manager = try make(mock)
                do { _ = try manager.engine.locked { try manager.applyPages(ModemLauncherPages(pages: [])) }; throw Failure.check("Page failure reported success") }
                catch let failure as Failure { throw failure } catch { }
                try check(mock.stagedPages == nil && !mock.locked, "Page failure leaked staging or lock")
                if cause < 2 { try check(mock.pagesBytes == nil && mock.pagesCommits == 0, "Precommit failure changed pages") }
            }
        }
        test("dedicated eSIM preserves saved order and appends only when absent") {
            for original in [[.vpn, .info], [.esim, .info], []] as [[ModemLauncherPage]] {
                let mock = MockDisplay(hashes: hashes); mock.ready(); mock.pagesBytes = try ModemLauncherPages(pages: original).encoded()
                let manager = try make(mock, updater: { true }, checkedFirmware: true)
                let result = try manager.engine.locked { try manager.installEsimPage() }
                try check(result.pages?.pages == (original.contains(.esim) ? original : original + [.esim]), "eSIM disturbed existing selection")
                try check(mock.pagesCommits == (original.contains(.esim) ? 0 : 1) && mock.layoutCommits == 0, "eSIM changed info layout or rewrote unchanged pages")
            }
        }
        test("first install saves chosen pages after confirmed installation") {
            let mock = MockDisplay(hashes: hashes), manager = try make(mock)
            let pages = ModemLauncherPages(pages: [.vpn, .info])
            let result = try manager.engine.locked { try manager.install(pages: pages) }
            try check(result.pages == pages && mock.installerCalls == 1 && mock.pagesCommits == 1, "First installation ignored selected pages")
        }
        test("generic selected eSIM prepares agent once and applies exact selected order") {
            let mock = MockDisplay(hashes: hashes)
            let manager = try make(mock, updater: { mock.sequence.append("vpn-absent"); return false }, prepareAgent: { mock.sequence.append("agent") }, checkedFirmware: true)
            let pages = ModemLauncherPages(pages: [.esim, .info])
            let result = try manager.engine.locked { try manager.install(pages: pages) }
            try check(result.pages == pages && mock.sequence == ["preflight", "vpn-absent", "agent", "install"] && mock.installerCalls == 1 && mock.pagesCommits == 1, "Generic eSIM install missed prerequisites or recursed")
        }
        test("page configuration target drift refuses commit and preserves prior bytes") {
            for reboot in [false, true] {
                let mock = MockDisplay(hashes: hashes); mock.ready(); mock.pagesBytes = try ModemLauncherPages.defaultPages.encoded()
                if reboot { mock.rebootAt = 5 } else { mock.swappedAt = 5 }
                let manager = try make(mock)
                try rejects("модем изменился") { _ = try manager.engine.locked { try manager.applyPages(ModemLauncherPages(pages: [])) } }
                try check(mock.pagesCommits == 0 && mock.pagesBytes == ModemLauncherPages.defaultPages.encoded(), "Target drift changed saved pages")
            }
        }
        test("actual shell guards preserve old config on unsafe metadata corruption and target drift") {
            for pageMode in [false, true] {
            let mock = MockDisplay(hashes: hashes); mock.ready()
            if pageMode {
                mock.pagesBytes = try ModemLauncherPages.defaultPages.encoded()
                let manager = try make(mock)
                _ = try manager.engine.locked { try manager.applyPages(ModemLauncherPages(pages: [.esim, .info])) }
            } else { _ = try apply(make(mock), reorderedLayout()) }
            let marker = pageMode ? "MODEM_DISPLAY_PAGES" : "MODEM_DISPLAY_LAYOUT"
            let stageCommand = mock.commands.first { $0.hasPrefix("# " + marker + "_STAGE\n") }!
            let commitCommand = mock.commands.first { $0.hasPrefix("# " + marker + "_COMMIT\n") }!
            let tokenLine = stageCommand.components(separatedBy: "\n").first { $0.hasPrefix("test \"$(cat /tmp/zte-imei-app.lock/owner)") }!
            let token = tokenLine.components(separatedBy: "'")[1]
            let selected = try pageMode ? ModemLauncherPages(pages: [.esim, .info]).encoded() : reorderedLayout().encoded()
            let previous = try pageMode ? ModemLauncherPages.defaultPages.encoded() : ModemDisplayLayout.defaultLayout.encoded()
            for scenario in ["valid", "symlink", "mode", "owner", "hardlink", "oversized-stage", "corrupt-stage", "changed-cid", "changed-boot", "changed-lock", "stage-symlink"] + (pageMode ? ["changed-saved-pages"] : []) {
                let fixture = temp.appendingPathComponent("shell-" + String(pageMode) + "-" + scenario), root = fixture.appendingPathComponent("launcher")
                let bin = fixture.appendingPathComponent("bin"), lock = fixture.appendingPathComponent("lock")
                try secureDirectory(root); try secureDirectory(bin); try secureDirectory(lock)
                let config = root.appendingPathComponent(pageMode ? "page-layout.conf" : "info-layout.conf")
                try savePrivate(previous, config)
                for name in ModemDisplayManager.payloadNames + ["launcher.sha256"] {
                    try FileManager.default.copyItem(at: resources.appendingPathComponent("VPN/" + name), to: root.appendingPathComponent(name))
                }
                try savePrivate(Data("zte-native-launcher-v1".utf8), root.appendingPathComponent("owner"))
                try savePrivate(Data(String(repeating: "a", count: 32).utf8), root.appendingPathComponent("cid"))
                try savePrivate(Data(String(repeating: "a", count: 32).utf8), fixture.appendingPathComponent("cid"))
                try savePrivate(Data("12345678-1234-1234-1234-123456789abc".utf8), fixture.appendingPathComponent("boot"))
                try savePrivate(Data(token.utf8), lock.appendingPathComponent("owner"))
                // Adapt only stat's platform syntax and fixture UID to the modem.
                // File types, symlinks, modes, hard-link counts and contents are real.
                let statScript = #"""
                #!/usr/bin/python3
                import os, stat, sys
                fmt, path = sys.argv[2:]
                s = os.stat(path)
                values = {'%u': '123' if os.path.exists(path + '.wrong-owner') else '0', '%a': oct(stat.S_IMODE(s.st_mode))[2:], '%h': str(s.st_nlink), '%s': str(s.st_size)}
                for key, value in values.items(): fmt = fmt.replace(key, value)
                print(fmt)
                """#
                try savePrivate(Data(statScript.utf8), bin.appendingPathComponent("stat"))
                try savePrivate(Data("#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n".utf8), bin.appendingPathComponent("sha256sum"))
                // Durability is tested structurally; avoid syncing the host disk.
                try savePrivate(Data("#!/bin/sh\nexit 0\n".utf8), bin.appendingPathComponent("sync"))
                for name in ["stat", "sha256sum", "sync"] { chmod(bin.appendingPathComponent(name).path, 0o700) }
                func translated(_ command: String) -> String {
                    command.replacingOccurrences(of: "/data/zte-launcher", with: root.path)
                        .replacingOccurrences(of: "/tmp/zte-imei-app.lock", with: lock.path)
                        .replacingOccurrences(of: "/sys/block/mmcblk0/device/cid", with: fixture.appendingPathComponent("cid").path)
                        .replacingOccurrences(of: "/proc/sys/kernel/random/boot_id", with: fixture.appendingPathComponent("boot").path)
                }
                func runShell(_ command: String, input: Data = Data()) throws -> (Int32, String) {
                    let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", translated(command)]
                    process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
                    process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = stdoutPipe
                    try process.run()
                    try stdinPipe.fileHandleForWriting.write(contentsOf: input); try stdinPipe.fileHandleForWriting.close()
                    let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
                }
                let outside = fixture.appendingPathComponent("outside")
                if scenario == "symlink" {
                    try FileManager.default.moveItem(at: config, to: outside)
                    try FileManager.default.createSymbolicLink(at: config, withDestinationURL: outside)
                }
                if scenario == "mode" { chmod(config.path, 0o644) }
                if scenario == "owner" { try savePrivate(Data(), URL(fileURLWithPath: config.path + ".wrong-owner")) }
                if scenario == "hardlink" { try check(link(config.path, outside.path) == 0, "Cannot create hardlink fixture") }
                if ["symlink", "mode", "owner", "hardlink"].contains(scenario) {
                    let read = try runShell(pageMode ? ModemDisplayManager.pagesReadCommand : ModemDisplayManager.layoutReadCommand)
                    try check(read.0 == 0 && read.1.contains(marker + " unsafe"), "Actual unsafe read failed: " + scenario + read.1)
                    let failed = try runShell(stageCommand, input: selected)
                    try check(failed.0 != 0 && Data(contentsOf: config) == previous, "Unsafe staging changed config: " + scenario)
                    continue
                }
                let staged = try runShell(stageCommand, input: selected)
                try check(staged.0 == 0 && staged.1.contains(digest(selected)), "Actual staging failed: " + staged.1)
                let stageFile = URL(fileURLWithPath: translated(pageMode ? mock.pagesStage : mock.layoutStage))
                if scenario == "oversized-stage" { try savePrivate(Data(repeating: 65, count: 513), stageFile) }
                if scenario == "corrupt-stage" { try savePrivate(Data(repeating: 65, count: selected.count), stageFile) }
                if scenario == "changed-cid" { try savePrivate(Data("changed".utf8), fixture.appendingPathComponent("cid")) }
                if scenario == "changed-boot" { try savePrivate(Data("changed".utf8), fixture.appendingPathComponent("boot")) }
                if scenario == "changed-lock" { try savePrivate(Data("changed".utf8), lock.appendingPathComponent("owner")) }
                if scenario == "stage-symlink" {
                    try FileManager.default.moveItem(at: stageFile, to: outside)
                    try FileManager.default.createSymbolicLink(at: stageFile, withDestinationURL: outside)
                }
                let currentBytes = scenario == "changed-saved-pages" ? try ModemLauncherPages(pages: [.vpn]).encoded() : previous
                if scenario == "changed-saved-pages" { try savePrivate(currentBytes, config) }
                let committed = try runShell(commitCommand)
                if scenario == "valid" {
                    try check(committed.0 == 0 && Data(contentsOf: config) == selected, "Valid atomic replacement failed: " + committed.1)
                } else {
                    try check(committed.0 != 0 && Data(contentsOf: config) == currentBytes, "Guard failed to preserve config: " + scenario)
                }
            }
        }
        }
        test("display workflows never invoke NV writes radio or remount") {
            for command in mocks.flatMap(\.commands) {
                for forbidden in ["zte_nv", "get_imei", "zte_config", "remount", "opkg", "modem_nv", "uci set", "ifconfig", "iptables"] {
                    try check(!command.contains(forbidden), "Unrelated operation: " + forbidden)
                }
            }
        }
        print("\(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
