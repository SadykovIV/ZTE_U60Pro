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
            return result((installed ? "VPN\nHELPER:" + (helperReady ? VPNSettingsManager.helperHash : String(repeating: "0", count: 64)) + "\n" : "") + "AGENT:" + VPNSettingsManager.agentHash + "\nDASHBOARD:" + VPNSettingsManager.dashboardIndexHash + "\n")
        }
        if command.hasPrefix("test -d /data/zte-launcher") { return result(VPNSettingsManager.launcherHash) }
        if command.contains("exec /data/zte-vpn/vpnctl request") {
            let request = try JSONSerialization.jsonObject(with: input ?? Data()) as! [String: Any]
            requests.append(request)
            let action = request["action"] as? String
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
