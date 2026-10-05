import Foundation

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw IMEIError.message("TEST: " + message) }
}
private func rejects(_ fragment: String = "", _ work: () throws -> Void) throws {
    do { try work() } catch {
        if error.localizedDescription.hasPrefix("TEST:") { throw error }
        try check(fragment.isEmpty || error.localizedDescription.contains(fragment), "Unexpected refusal: " + error.localizedDescription)
        return
    }
    throw IMEIError.message("TEST: Expected refusal")
}
private final class Remote: RemoteTransport {
    let cid = String(repeating: "a", count: 32), boot = "11111111-2222-3333-4444-555555555555"
    var commands: [String] = [], requests: [[String: Any]] = []
    var locked = false, installed = true, helperReady = true
    var helperLayoutReady = true
    var installedHelperHash: String?
    var installedAgentHash = VPNSettingsManager.agentHash
    var requestOverride: CommandResult?
    var badReceipt = false, enabledReceipt = false, mutateSSIDReceipt = false, bad2GReceipt = false
    var identityCalls = 0, swappedAt = 0, mutationError: String?
    var payload: [String: Any] = [
        "schema_version": 1, "installed": true, "version": "fixture", "core_version": "fixture", "core_available": true,
        "configured": false, "enabled": false, "core_running": false, "network_ok": false, "mesh_conflict": false,
        "ssid": "Guest 5G", "ssid_2g": "Guest 2G", "ssid_5g": "Guest 5G", "desired_ssid": "ZTE-VPN", "main_ssid": "Main WiFi",
        "password_mode": "main", "settings_supported": true, "wifi_settings_pending": false,
        "profiles": [], "active_profile": "", "recovery_pending": false
    ]
    func result(_ text: String = "", status: Int32 = 0) -> CommandResult { CommandResult(status: status, stdout: Data(text.utf8), stderr: Data()) }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") {
            identityCalls += 1
            let device = swappedAt > 0 && identityCalls >= swappedAt ? String(repeating: "b", count: 32) : cid
            return result(ModemEngine.firmwareHash + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + device + "\n" + boot + "\n")
        }
        if command.contains("if mkdir /tmp/zte-imei-app.lock") { locked = true; return result() }
        if command.contains("&& rm /tmp/zte-imei-app.lock/owner") { locked = false; return result() }
        if command.hasPrefix("for c in lua nft") {
            return result((installed ? "VPN\nHELPER:" + (installedHelperHash ?? (helperReady ? VPNSettingsManager.helperHash : String(repeating: "0", count: 64))) + "\n" : "") + (helperLayoutReady ? "HELPER_LAYOUT_READY\n" : "") + "AGENT:" + installedAgentHash + "\nDASHBOARD:" + VPNSettingsManager.dashboardIndexHash + "\n")
        }
        if command.hasPrefix("test -d /data/zte-launcher") { return result(VPNSettingsManager.launcherHash) }
        if command.contains("exec /data/zte-vpn/vpnctl request") {
            let request = try JSONSerialization.jsonObject(with: input ?? Data()) as! [String: Any]
            requests.append(request)
            let action = request["action"] as? String
            if let requestOverride { return requestOverride }
            if let installedHelperHash {
                // Execute the actual emitted case-pattern locally. The guard
                // stays before the fake helper response and any fixture write.
                let marker = "| cut -d ' ' -f1)\" in "
                guard let start = command.range(of: marker),
                      let end = command.range(of: "; exec /data/zte-vpn/vpnctl request", range: start.upperBound..<command.endIndex) else {
                    throw IMEIError.message("TEST: Missing helper hash guard")
                }
                let caseBody = String(command[start.upperBound..<end.lowerBound])
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "case \"$1\" in " + caseBody, "--", installedHelperHash]
                let errors = Pipe(); process.standardError = errors
                try process.run(); try? errors.fileHandleForWriting.close(); process.waitUntilExit()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0 { return .init(status: process.terminationStatus, stdout: Data(), stderr: stderr) }
            }
            if action == "configure_wifi" {
                try check(locked, "Mutation has no common remote lock")
                try check(command.contains(cid) && command.contains(boot) && command.contains(VPNSettingsManager.helperHash), "Mutation not bound to target and pinned helper")
                try check(UUID(uuidString: request["lock_token"] as? String ?? "") != nil, "Mutation omitted lock ownership token")
                if let mutationError { return result(String(decoding: try JSONSerialization.data(withJSONObject: ["ok": false, "code": mutationError]), as: UTF8.self), status: 1) }
                payload["desired_ssid"] = badReceipt ? "different" : request["ssid"]
                payload["password_mode"] = request["password_mode"]
                payload["wifi_settings_pending"] = true
                if payload["configured"] as? Bool == true && !mutateSSIDReceipt {
                    payload["ssid"] = request["ssid"]; payload["ssid_2g"] = bad2GReceipt ? "Old 2G name" : request["ssid"]; payload["ssid_5g"] = request["ssid"]
                }
                if enabledReceipt { payload["enabled"] = true }
            } else { try check(action == "status", "Unexpected VPN action") }
            return result(String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "data": payload]), as: UTF8.self))
        }
        throw IMEIError.message("TEST: Unexpected command: " + command)
    }
}
private final class Fixture {
    let root: URL, engine: ModemEngine, remote = Remote()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-vpn-settings-test-" + UUID().uuidString)
        engine = try ModemEngine(root: root, resources: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources"), connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/hosts"), transport: remote)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var manager: VPNSettingsManager { VPNSettingsManager(engine: engine) }
    func configure(_ config: VPNWiFiConfiguration) throws -> VPNInspection { try engine.locked { try manager.configureWiFi(config) } }
}
@main struct VPNSettingsTests {
    static func main() throws {
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); count += 1; print("PASS " + name) }
        try test("Upgrade errors expose only fixed causes and keep uncertain transport distinct") {
            func result(_ stderr: String, _ exit: Int32 = 1) -> CommandResult { .init(status: exit, stdout: Data(), stderr: Data(stderr.utf8)) }
            let codes = ["INVALID_STAGE", "UNSAFE_LAYOUT", "PAYLOAD", "VPN_PENDING", "SCREEN_BUSY", "CONTROLLER_UNKNOWN", "OLD_INTEGRITY", "DEVICE_CHANGED", "NETWORK_CHANGED", "SERVICE_CHANGED", "STARTUP_CHANGED", "STATE_UNSAFE", "SNAPSHOT", "WRITE", "NEW_INTEGRITY", "VERIFY", "RECOVERY_REQUIRED", "ROLLBACK_UNKNOWN"]
            for code in codes {
                let message = VPNSettingsManager.upgradeFailure(result("private-canary\nVPN_UPGRADE_ERROR " + code + "\n"))
                try check(message?.contains("VPN_UPGRADE_" + code) == true && message?.contains("private-canary") == false, "Known upgrade error or privacy lost")
            }
            for text in ["VPN_UPGRADE_ERROR PRIVATE_CANARY", "prefix VPN_UPGRADE_ERROR NETWORK_CHANGED", "VPN_UPGRADE_ERROR NETWORK_CHANGED private-canary"] {
                try check(VPNSettingsManager.upgradeFailure(result(text)) == nil, "Untrusted error text accepted")
            }
            for exit: Int32 in [-1, 0, 255] { try check(VPNSettingsManager.upgradeFailure(result("VPN_UPGRADE_ERROR NETWORK_CHANGED", exit)) == nil, "Unknown transport converted to helper refusal") }
            try check(VPNSettingsManager.upgradeFailure(result("VPN_UPGRADE_ERROR WRITE\nVPN_UPGRADE_ERROR ROLLBACK_UNKNOWN"))?.contains("VPN_UPGRADE_ROLLBACK_UNKNOWN") == true, "Unknown rollback was masked")
            try check(VPNSettingsManager.upgradeFailure(result("VPN_UPGRADE_ERROR WRITE\nVPN_UPGRADE_ERROR VERIFY")) == nil, "Conflicting helper causes presented as certain")
        }
        try test("Current helper readiness checks actual service startup links and network snapshot") {
            let fm = FileManager.default
            func ready(_ change: (URL) throws -> Void) throws -> Bool {
                let base = fm.temporaryDirectory.appendingPathComponent("vpn-ready-" + UUID().uuidString)
                defer { try? fm.removeItem(at: base) }
                for path in ["data/zte-vpn", "etc/init.d", "etc/rc.d", "bin"] {
                    try fm.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true)
                }
                let network = Data("#!/bin/sh\n# fixture network hook\n".utf8)
                for (name, bytes) in ["etc/init.d/zte_vpn":Data("fixture service\n".utf8), "data/zte-vpn/service.sh":Data("fixture service\n".utf8), "etc/init.d/network":network, "data/zte-vpn/configured":Data(), "data/zte-vpn/network-init.sha256":Data(digest(network).utf8)] {
                    let file = base.appendingPathComponent(name)
                    try bytes.write(to: file); try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
                }
                for link in ["S99zte_vpn", "K01zte_vpn"] {
                    try fm.createSymbolicLink(atPath:base.appendingPathComponent("etc/rc.d/" + link).path, withDestinationPath:"../init.d/zte_vpn")
                }
                let stat = "#!/bin/sh\ncase \"$2\" in %u:%h) printf '0:1\\n';; %u) printf '0\\n';; %a) exec /usr/bin/stat -f '%Lp' \"$3\";; *) exit 1;; esac\n"
                for (name, contents) in ["stat":stat, "sha256sum":"#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n"] {
                    let file=base.appendingPathComponent("bin/" + name)
                    try Data(contents.utf8).write(to:file);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
                }
                try change(base)
                let process=Process(), stdout=Pipe(), stderr=Pipe()
                process.executableURL=URL(fileURLWithPath:"/bin/sh")
                var command=VPNSettingsManager.helperReadinessCommand
                for path in ["/data/zte-vpn", "/etc/init.d", "/etc/rc.d"] { command=command.replacingOccurrences(of:path,with:base.path + path) }
                process.arguments=["-c", command]
                process.environment=["PATH":base.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
                process.standardOutput=stdout;process.standardError=stderr
                try process.run();try stdout.fileHandleForWriting.close();try stderr.fileHandleForWriting.close();process.waitUntilExit()
                let result=stdout.fileHandleForReading.readDataToEndOfFile()
                try check(process.terminationStatus==0, "Readiness inspection failed instead of returning not ready")
                try check(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty,"Readiness fixture had shell errors")
                return String(decoding:result,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)=="HELPER_LAYOUT_READY"
            }
            try check(try ready { _ in }, "Intact integration is not ready")
            try check(!(try ready { try fm.removeItem(at:$0.appendingPathComponent("etc/init.d/zte_vpn")) }), "Missing service accepted")
            try check(!(try ready { try Data("foreign".utf8).write(to:$0.appendingPathComponent("etc/init.d/zte_vpn")) }), "Foreign service accepted")
            try check(!(try ready { try fm.removeItem(at:$0.appendingPathComponent("etc/rc.d/K01zte_vpn")) }), "Missing stop link accepted")
            try check(!(try ready { base in
                let link=base.appendingPathComponent("etc/rc.d/S99zte_vpn")
                try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"../init.d/foreign")
            }), "Foreign startup link accepted")
            try check(!(try ready { try Data("#!/bin/sh\n# stock reset\n".utf8).write(to:$0.appendingPathComponent("etc/init.d/network")) }), "Reset network accepted as configured")
            try check(!(try ready { try fm.removeItem(at:$0.appendingPathComponent("data/zte-vpn/network-init.sha256")) }), "Missing configured network proof accepted")
            try check(try ready { try fm.removeItem(at:$0.appendingPathComponent("data/zte-vpn/configured")) }, "Unconfigured repaired integration requires old network state")
            let f=try Fixture();f.remote.helperLayoutReady=false
            try check(!(try f.manager.inspect()).helperReady,"Current binary hash hid missing integration")
        }
        try test("New status decodes both actual band SSIDs and desired settings") {
            let f = try Fixture(), status = try f.manager.request(["action": "status"])
            try check(status.ssid2G == "Guest 2G" && status.ssid5G == "Guest 5G" && status.actualSSID == "Guest 5G", "Snake-case radio keys were lost")
            try check(status.editableSSID == "ZTE-VPN" && status.mainSsid == "Main WiFi" && status.passwordMode == .main && status.settingsSupported == true, "New settings fields lost")
        }
        try test("Legacy status stays readable and preserves existing guest network") {
            let f = try Fixture()
            for key in ["ssid_2g", "ssid_5g", "desired_ssid", "main_ssid", "password_mode", "settings_supported", "wifi_settings_pending"] { f.remote.payload.removeValue(forKey: key) }
            f.remote.payload["configured"] = true
            let status = try f.manager.request(["action": "status"])
            try check(status.actualSSID == "Guest 5G" && status.editableSSID == "Guest 5G" && status.initialPasswordMode == .preserve && status.settingsSupported == nil, "Legacy guest would be renamed")
            try check(VPNStatus().editableSSID == "ZTE-VPN" && VPNStatus().actualSSID.isEmpty, "Absent default pretends to be a live SSID")
        }
        try test("Frozen .8 controller status is readable but mutation stays current-only") {
            let f = try Fixture()
            f.remote.installedHelperHash = "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231"
            f.remote.installedAgentHash = "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19"
            let inspection = try f.manager.inspect()
            try check(inspection.status.installed && !inspection.helperReady && !inspection.agentReady && inspection.missingCapabilities.isEmpty, "Old components falsely ready or unreadable")
            let before = try JSONSerialization.data(withJSONObject: f.remote.payload, options: .sortedKeys)
            try rejects { _ = try f.manager.request(["action": "configure_wifi"]) }
            try check(try JSONSerialization.data(withJSONObject: f.remote.payload, options: .sortedKeys) == before, "Old controller mutation reached helper")
        }
        try test("Nonzero empty or malformed command reply retains exit cause without raw output") {
            for status: Int32 in [1, 78, 255] {
                for body in ["", "PRIVATE_CANARY"] {
                    let f = try Fixture(); f.remote.requestOverride = .init(status: status, stdout: Data(body.utf8), stderr: Data("PRIVATE_STDERR".utf8))
                    do { _ = try f.manager.request(["action": "status"]); throw IMEIError.message("TEST: Failed command accepted") }
                    catch { try check(error.localizedDescription.contains("exit " + String(status)) && !error.localizedDescription.contains("PRIVATE"), "Failure lost exit or exposed raw output") }
                    try check(f.remote.requests.count == 1, "Failure retried")
                }
            }
        }
        try test("Previous .7 helper is accepted only for status, never mutation") {
            let f = try Fixture()
            f.remote.installedHelperHash = "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca"
            let status = try f.manager.request(["action": "status"])
            try check(status.installed, "Previous .7 status rejected before upgrade")
            let before = try JSONSerialization.data(withJSONObject: f.remote.payload, options: .sortedKeys)
            try rejects { _ = try f.manager.request(["action": "configure_wifi"]) }
            try check(try JSONSerialization.data(withJSONObject: f.remote.payload, options: .sortedKeys) == before, "Legacy helper mutation reached the fixture")
        }
        try test("Previous public 1.20 helper is accepted only for status, never mutation") {
            let f = try Fixture()
            f.remote.installedHelperHash = "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4"
            let status = try f.manager.request(["action": "status"])
            try check(status.installed, "Previous .7 status rejected before upgrade")
            let before = try JSONSerialization.data(withJSONObject: f.remote.payload, options: .sortedKeys)
            try rejects { _ = try f.manager.request(["action": "configure_wifi"]) }
            try check(try JSONSerialization.data(withJSONObject: f.remote.payload, options: .sortedKeys) == before, "Legacy helper mutation reached the fixture")
        }
        try test("Published build 42 controller remains readable, mutations require current") {
            let f = try Fixture()
            f.remote.installedHelperHash = "7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb"
            let inspection = try f.manager.inspect()
            try check(inspection.status.installed && !inspection.helperReady, "Published controller status blocked or falsely current")
            try rejects { _ = try f.manager.request(["action": "configure_wifi", "ssid": "must-not-change"]) }
            try check(f.remote.payload["desired_ssid"] as? String == "ZTE-VPN", "Legacy controller allowed mutation")
        }

        try test("Unknown helper remains rejected even for status") {
            let f = try Fixture(); f.remote.installedHelperHash = String(repeating: "0", count: 64)
            try rejects { _ = try f.manager.request(["action": "status"]) }
        }
        try test("Guard refusal is typed and never confused with invalid JSON") {
            let f = try Fixture(); f.remote.installedHelperHash = String(repeating: "0", count: 64)
            do { _ = try f.manager.request(["action": "status"]); throw IMEIError.message("TEST: Unknown helper accepted") }
            catch let error as VPNRequestFailure { try check(error == .unrecognizedController, "Hash refusal lost") }
            let layout = try Fixture(); layout.remote.requestOverride = .init(status: 78, stdout: Data(), stderr: Data("VPN_REQUEST_GUARD unsafe_layout\n".utf8))
            do { _ = try layout.manager.request(["action": "status"]); throw IMEIError.message("TEST: Unsafe layout accepted") }
            catch let error as VPNRequestFailure { try check(error == .unsafeControllerLayout, "Layout refusal lost") }
            let malformed = try Fixture(); malformed.remote.requestOverride = .init(status: 0, stdout: Data("not-json".utf8), stderr: Data())
            do { _ = try malformed.manager.request(["action": "status"]); throw IMEIError.message("TEST: Malformed success accepted") }
            catch let error as VPNRequestFailure { try check(error == .invalidResponse, "Malformed success classification") }
        }
        try test("Unknown helper codes never expose private or multiline values") {
            for (exitCode, code): (Int32, String) in [(1, "VPN_PRIVATE_CANARY"), (0, "PRIVATE_SECRET\nsecond line"), (0, "VPN_PRIVATE_CANARY")] {
                let f = try Fixture()
                let reply = try JSONSerialization.data(withJSONObject: ["ok": false, "code": code])
                f.remote.requestOverride = .init(status: exitCode, stdout: reply, stderr: Data("PRIVATE_STDERR".utf8))
                do { _ = try f.manager.request(["action": "status"]); throw IMEIError.message("TEST: Refusal accepted") }
                catch { try check(error.localizedDescription == "Не удалось завершить настройку VPN. Обновите состояние (VPN_OPERATION_FAILED).", "Unknown helper code escaped") }
                try check(f.remote.requests.count == 1, "Refusal retried")
            }
        }
        try test("Actual shell refuses unsafe layout before executing the helper") {
            let f = try Fixture(); _ = try f.manager.request(["action": "status"])
            guard let emitted = f.remote.commands.last(where: { $0.contains("exec /data/zte-vpn/vpnctl request") }) else { throw IMEIError.message("TEST: missing command") }
            let dir = f.root.appendingPathComponent("controller"); try secureDirectory(dir)
            let binary = dir.appendingPathComponent("vpnctl"); try savePrivate(Data("#!/bin/sh\necho EXECUTED\n".utf8), binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            for metadata in ["0:777", "1000:700", "0:700"] {
                let process = Process(), out = Pipe(), err = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                let functions = "stat() { printf '%s\\n' " + shellQuote(metadata) + "; }; sha256sum() { printf '%s  fixture\\n' " + shellQuote(VPNSettingsManager.helperHash) + "; }; "
                process.arguments = ["-c", functions + emitted.replacingOccurrences(of: "/data/zte-vpn", with: dir.path)]
                process.standardOutput = out; process.standardError = err
                try process.run(); try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close(); process.waitUntilExit()
                let stdout = out.fileHandleForReading.readDataToEndOfFile(), stderr = err.fileHandleForReading.readDataToEndOfFile()
                if metadata == "0:700" { try check(process.terminationStatus == 0 && String(decoding: stdout, as: UTF8.self) == "EXECUTED\n", "Safe layout refused") }
                else { try check(process.terminationStatus == 78 && stdout.isEmpty && String(decoding: stderr, as: UTF8.self) == "VPN_REQUEST_GUARD unsafe_layout\n", "Unsafe layout executed or lost marker") }
            }
        }
        try test("SSID validation uses UTF8 bytes and rejects controls without shell interpolation") {
            try VPNWiFiConfiguration(ssid: String(repeating: "я", count: 16), passwordMode: .main).validate(configured: false)
            for ssid in ["", String(repeating: "я", count: 17), "hello\nthere", "bad\0ssid"] {
                try rejects { try VPNWiFiConfiguration(ssid: ssid, passwordMode: .main).validate(configured: false) }
            }
            try VPNWiFiConfiguration(ssid: "$(touch /tmp/no); 'quoted'", passwordMode: .main).validate(configured: false)
        }
        try test("Custom password validates passphrases and 64hex keys") {
            for password in ["12345678", String(repeating: "~", count: 63), String(repeating: "AF", count: 32)] {
                try VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .custom, password: password).validate(configured: false)
            }
            for password in ["short", "парольпароль", "1234567\n", String(repeating: "z", count: 64), String(repeating: "a", count: 65)] {
                try rejects { try VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .custom, password: password).validate(configured: false) }
            }
            try rejects { try VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .preserve).validate(configured: false) }
        }
        try test("Main and preserve requests never send stale custom password") {
            for mode: VPNWiFiPasswordMode in [.main, .preserve] {
                let request = VPNWiFiConfiguration(ssid: "WiFi", passwordMode: mode, password: "STALE_SECRET").request
                try check(request["password"] == nil && request["password_mode"] as? String == mode.rawValue, "Stale password escaped in payload")
            }
        }
        try test("Refresh preserves edited draft while invalidation and success clear secrets") {
            var draft = VPNWiFiDraft(), status = VPNStatus(); status.configured = true; status.ssid = "Existing Guest"
            draft.refresh(status)
            try check(draft.ssid == "Existing Guest" && draft.passwordMode == .preserve, "Existing settings replaced by defaults")
            draft.ssid = "Draft"; draft.isDirty = true; draft.setPasswordMode(.custom); draft.password = "Secret123"; draft.confirmation = "Secret123"
            status.ssid = "Other name"; draft.refresh(status)
            try check(draft.ssid == "Draft" && draft.password == "Secret123", "Refresh erased user draft")
            draft.saved(status)
            try check(draft.password.isEmpty && draft.confirmation.isEmpty && !draft.isDirty && draft.ssid == "Other name", "Save did not clear secret")
            draft.password = "Secret123"; draft.isDirty = true; draft.refresh(nil)
            try check(draft.password.isEmpty && !draft.isDirty && draft.passwordMode == .main && draft.ssid == "ZTE-VPN", "Invalidation left stale draft")
        }
        try test("Draft confirmation prevents accidental password mismatch") {
            var draft = VPNWiFiDraft(); draft.setPasswordMode(.custom); draft.password = "Secret123"; draft.confirmation = "Secret124"
            try rejects("не совпадают") { try draft.validate(configured: false) }
            draft.setPasswordMode(.main)
            try check(draft.password.isEmpty && draft.confirmation.isEmpty, "Mode switch left password in memory")
        }
        try test("First configuration stores requested defaults while leaving network unconfigured and off") {
            let f = try Fixture(), after = try f.configure(VPNWiFiConfiguration(ssid: "ZTE-VPN", passwordMode: .main))
            try check(!after.status.configured && !after.status.enabled && after.status.desiredSsid == "ZTE-VPN" && after.status.actualSSID == "Guest 5G", "Save enabled or rewrote unconfigured network")
            try check(f.remote.requests.filter { $0["action"] as? String == "configure_wifi" }.count == 1 && !f.remote.locked, "Mutation count or lock release incorrect")
        }
        try test("Existing disabled network can be renamed while preserving its key") {
            let f = try Fixture(); f.remote.payload["configured"] = true
            let after = try f.configure(VPNWiFiConfiguration(ssid: "Existing renamed", passwordMode: .preserve))
            try check(after.status.actualSSID == "Existing renamed" && after.status.ssid2G == "Existing renamed" && after.status.passwordMode == .preserve && !after.status.enabled, "Rename receipt wrong")
        }
        try test("Custom password travels only in private stdin and never in command or journal") {
            let f = try Fixture(), password = "UniqueSecret932!"
            _ = try f.configure(VPNWiFiConfiguration(ssid: "Custom network", passwordMode: .custom, password: password))
            try check(f.remote.requests.last?["password"] as? String == password, "Password missing from private request")
            try check(!f.remote.commands.joined().contains(password), "Password in command")
            let paths = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in paths where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let data = try Data(contentsOf: file)
                try check(!String(decoding: data, as: UTF8.self).contains(password), "Password persisted to " + file.lastPathComponent)
            }
        }
        try test("Enabled network and legacy helper block save without any mutation") {
            for kind in 0...2 {
                let f = try Fixture()
                if kind == 0 { f.remote.payload["enabled"] = true }
                if kind == 1 { f.remote.payload.removeValue(forKey: "settings_supported") }
                if kind == 2 { f.remote.helperReady = false }
                try rejects { _ = try f.configure(VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .main)) }
                try check(!f.remote.requests.contains { $0["action"] as? String == "configure_wifi" }, "Refused state still mutated")
            }
        }
        try test("Bad receipt cannot report successful save") {
            for kind in 0...3 {
                let f = try Fixture(); f.remote.payload["configured"] = true
                f.remote.badReceipt = kind == 0; f.remote.enabledReceipt = kind == 1; f.remote.mutateSSIDReceipt = kind == 2
                f.remote.bad2GReceipt = kind == 3
                try rejects { _ = try f.configure(VPNWiFiConfiguration(ssid: "Updated", passwordMode: .main)) }
            }
        }
        try test("Device switch before write blocks mutation and switch after receipt blocks success") {
            let f = try Fixture(); f.remote.swappedAt = 4
            try rejects("Модем изменился") { _ = try f.configure(VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .main)) }
            try check(!f.remote.requests.contains { $0["action"] as? String == "configure_wifi" }, "Swapped target mutated")
            let after = try Fixture(); after.remote.swappedAt = 5
            try rejects("Модем изменился") { _ = try after.configure(VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .main)) }
        }
        try test("Remote refusal is localized and never retried as enable or reload") {
            let f = try Fixture(); f.remote.mutationError = "VPN_WIFI_SETTINGS_ENABLED"
            try rejects("Сначала выключите") { _ = try f.configure(VPNWiFiConfiguration(ssid: "WiFi", passwordMode: .main)) }
            try check(f.remote.requests.allSatisfy { ["status", "configure_wifi"].contains($0["action"] as? String ?? "") }, "Save invoked unrelated action")
            try check(!f.remote.commands.contains { $0.contains("wifi reload") || $0.contains("uci set") }, "Desktop changed live network directly")
        }
        print("\(count) VPN settings tests passed")
    }
}
