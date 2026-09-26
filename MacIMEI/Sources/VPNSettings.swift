import Foundation

struct VPNProfile: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var transport: String
    var warnings: [String]
    var active: Bool
}
struct VPNStatus: Decodable, Sendable {
    var schemaVersion = 1
    var installed = false
    var version = ""
    var coreVersion = ""
    var coreAvailable = false
    var configured = false
    var enabled = false
    var coreRunning = false
    var networkOk = false
    var meshConflict = false
    var ssid = ""
    var ssid2G: String?
    var ssid5G: String?
    var desiredSsid: String?
    var mainSsid: String?
    var passwordMode: VPNWiFiPasswordMode?
    var settingsSupported: Bool?
    var wifiSettingsPending: Bool?
    var profiles: [VPNProfile] = []
    var activeProfile = ""
    var recoveryPending = false

    var actualSSID: String { [ssid5G, ssid2G, Optional(ssid)].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
    var editableSSID: String { desiredSsid.flatMap { $0.isEmpty ? nil : $0 } ?? (configured ? actualSSID : "ZTE-VPN") }
    var initialPasswordMode: VPNWiFiPasswordMode { configured ? .preserve : (passwordMode ?? .main) }
}

enum VPNWiFiPasswordMode: String, Decodable, CaseIterable, Identifiable, Sendable {
    case main, custom, preserve
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: return "Как у основной сети"
        case .custom: return "Задать свой пароль"
        case .preserve: return "Сохранить текущий пароль"
        }
    }
}

/// Secrets are sent only in the private request body and never persisted by the app.
struct VPNWiFiConfiguration: Sendable {
    var ssid: String
    var passwordMode: VPNWiFiPasswordMode
    var password = ""

    func validate(configured: Bool) throws {
        try require((1...32).contains(ssid.utf8.count) && !ssid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), "Название Wi-Fi должно содержать от 1 до 32 байт UTF-8 без управляющих символов.")
        try require(passwordMode != .preserve || configured, "Текущий пароль можно сохранить только у настроенной VPN-сети.")
        if passwordMode == .custom {
            let bytes = Array(password.utf8)
            let passphrase = (8...63).contains(bytes.count) && bytes.allSatisfy { (32...126).contains($0) }
            let key = bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
            try require(passphrase || key, "Пароль должен содержать 8–63 печатных символа ASCII или 64 шестнадцатеричных символа.")
        }
    }
    var request: [String: Any] {
        var value: [String: Any] = ["action": "configure_wifi", "ssid": ssid, "password_mode": passwordMode.rawValue]
        if passwordMode == .custom { value["password"] = password }
        return value
    }
}
/// A refreshed status must not overwrite a name or password currently being edited.
struct VPNWiFiDraft {
    var ssid = "ZTE-VPN"
    var passwordMode: VPNWiFiPasswordMode = .main
    var password = ""
    var confirmation = ""
    var isDirty = false

    var configuration: VPNWiFiConfiguration { VPNWiFiConfiguration(ssid: ssid, passwordMode: passwordMode, password: password) }
    mutating func refresh(_ status: VPNStatus?) {
        guard let status else { self = VPNWiFiDraft(); return }
        guard !isDirty else { return }
        ssid = status.editableSSID; passwordMode = status.initialPasswordMode
        password = ""; confirmation = ""
    }
    mutating func saved(_ status: VPNStatus?) {
        isDirty = false; password = ""; confirmation = ""; refresh(status)
    }
    mutating func setPasswordMode(_ mode: VPNWiFiPasswordMode) {
        passwordMode = mode; password = ""; confirmation = ""; isDirty = true
    }
    func validate(configured: Bool) throws {
        try configuration.validate(configured: configured)
        try require(passwordMode != .custom || password == confirmation, "Пароли не совпадают.")
    }
}

struct VPNInspection: Sendable {
    var status: VPNStatus
    var missingCapabilities: [String]
    var ssclashInstalled: Bool
    var helperReady: Bool = false
    var agentReady: Bool = false
    var dashboardReady: Bool = false
    var launcherReady: Bool = false
}

/// Both the desktop and agent send private JSON on stdin to the same modem helper.
final class VPNSettingsManager {
    static let root = "/data/zte-vpn"
    static let launcherHash = "9af1b9f4455f2443be2da38be10412a1597f043e54d00d2a52da62c92bcc21ab"
    static let agentHash = "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346"
    static let dashboardIndexHash = "ef84080162bb31508515bfe6fb2aebd8f6bb7fa7df9eeadef78e7ef54125e800"
    static let helperHash = "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4"
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }

    static func message(_ code: String) -> String {
        let messages = [
            "VPN_BUSY": "На модеме выполняется другая операция. Повторите после её завершения.",
            "VPN_OTHER_TRANSACTION": "Сначала завершите обновление или настройку модема.",
            "VPN_VLESS_ONLY": "Вставьте ссылку профиля, начинающуюся с vless://.",
            "VPN_INVALID_URI": "Ссылка профиля повреждена. Скопируйте её полностью.",
            "VPN_INVALID_UUID": "В профиле неверный идентификатор VLESS.",
            "VPN_INVALID_KEY": "В профиле неверный ключ шифрования или short ID.",
            "VPN_INVALID_PORT": "Порт сервера должен быть от 1 до 65535.",
            "VPN_INVALID_NAME": "Название должно содержать от 1 до 64 символов без переносов строк.",
            "VPN_UNSUPPORTED_OPTION": "Профиль содержит неподдерживаемый параметр. Он не был изменён или применён.",
            "VPN_UNSUPPORTED_TRANSPORT": "Поддерживаются VLESS с TCP, WebSocket, gRPC и XHTTP.",
            "VPN_CONFLICTING_OPTION": "В профиле указаны несовместимые параметры.",
            "VPN_DUPLICATE_OPTION": "В ссылке повторяется параметр. Исправьте профиль.",
            "VPN_VALIDATION_FAILED": "Ядро VPN не приняло конфигурацию. Действующий профиль сохранён.",
            "VPN_PROFILE_EXISTS": "Этот профиль уже импортирован.",
            "VPN_PROFILE_LIMIT": "Можно хранить до 32 профилей. Удалите ненужный профиль.",
            "VPN_ACTIVE_PROFILE_DELETE": "Активный профиль удалить нельзя. Сначала выберите другой.",
            "VPN_NO_ACTIVE_PROFILE": "Сначала импортируйте и активируйте профиль.",
            "VPN_GUEST_IN_USE": "Гостевой Wi-Fi уже используется. Выключите его перед первой настройкой VPN.",
            "VPN_MESH_CONFLICT": "VPN-сеть использует гостевые интерфейсы. Сначала выключите Mesh.",
            "VPN_IPA_ENABLED": "Для защищённой VPN-сети требуется отключённое аппаратное ускорение IPA.",
            "VPN_OTHER_PROXY": "Другое ядро прокси уже работает. Остановите его перед настройкой.",
            "VPN_SUBNET_CONFLICT": "Подсеть 192.168.50.0/24 уже занята.",
            "VPN_OPERATION_TIMEOUT": "Операция ещё не подтверждена. Обновите состояние перед повтором.",
            "VPN_INTEGRITY": "Компоненты VPN изменены или относятся к другой версии.",
            "VPN_CORE_INTEGRITY": "Ядро VPN не прошло проверку контрольной суммы.",
            "VPN_INVALID_WIFI_SSID": "Название Wi-Fi должно содержать от 1 до 32 байт UTF-8 без управляющих символов.",
            "VPN_INVALID_WIFI_PASSWORD": "Пароль Wi-Fi должен содержать 8–63 печатных символа ASCII или 64 шестнадцатеричных символа.",
            "VPN_INVALID_WIFI_SETTINGS": "Модем не принял параметры Wi-Fi. Обновите компоненты VPN и проверьте настройки.",
            "VPN_WIFI_NOT_CONFIGURED": "VPN-сеть ещё не настроена. Выберите пароль основной сети или задайте свой.",
            "VPN_WIFI_CONFIGURATION_CHANGED": "Настройки Wi-Fi на модеме изменились. Обновите состояние перед повтором.",
            "VPN_WIFI_SETTINGS_PENDING": "Предыдущее сохранение сети не завершено. Проверьте параметры и сохраните их заново; до этого Wi-Fi с VPN не включится.",
            "VPN_WIFI_SETTINGS_ENABLED": "Сначала выключите Wi-Fi с VPN на модеме или в агенте. Настройки сети можно менять только после выключения.",
            "VPN_WIFI_NOT_READY": "VPN-сеть не запустилась вовремя и была выключена. Настройки сохранены для проверки."
        ]
        return messages[code] ?? "Не удалось завершить настройку VPN. Обновите состояние. Код: \(code)"
    }
    func inspect() throws -> VPNInspection {
        _ = try engine.identity()
        let probe = try engine.text("for c in lua nft iptables ip6tables ebtables dnsmasq ip ubus flock jsonfilter; do command -v \"$c\" >/dev/null 2>&1 || printf 'MISSING:%s\\n' \"$c\"; done; test -c /dev/net/tun || echo MISSING:TUN; test ! -e /data/zte-imei-apps/ssclash/bin/ssclash || echo SSCLASH; test ! -e /data/zte-vpn || echo VPN; test ! -e /data/zte-vpn/controller-upgrade || echo UPGRADE_PENDING; sha256sum /data/zte-vpn/vpnctl 2>/dev/null | awk '{print \"HELPER:\" $1}'; sha256sum /data/zte-agent 2>/dev/null | awk '{print \"AGENT:\" $1}'; sha256sum /data/www.current/index.html 2>/dev/null | awk '{print \"DASHBOARD:\" $1}'")
        let launcherProbe = try engine.text("test -d /data/zte-launcher && test ! -L /data/zte-launcher && test \"$(stat -c %u:%a /data/zte-launcher)\" = 0:700 && test -f /data/zte-launcher/enabled && test ! -e /data/zte-launcher/failed && test ! -e /data/zte-launcher-update && (cd /data/zte-launcher && sha256sum -c launcher.sha256 >/dev/null 2>&1) && cmp -s /etc/init.d/zte_launcher /data/zte-launcher/launcher-service.sh && sha256sum /data/zte-launcher/launcher.so | awk '{print $1}'; true")
        let lines = probe.split(separator: "\n").map(String.init)
        var status = VPNStatus()
        if lines.contains("UPGRADE_PENDING") { status.installed = true }
        else if lines.contains("VPN") { status = try request(["action": "status"]) }
        return VPNInspection(status: status, missingCapabilities: lines.filter { $0.hasPrefix("MISSING:") }.map { String($0.dropFirst(8)) }, ssclashInstalled: lines.contains("SSCLASH"), helperReady: lines.contains("HELPER:" + Self.helperHash) && !lines.contains("UPGRADE_PENDING"), agentReady: lines.contains("AGENT:" + Self.agentHash), dashboardReady: lines.contains("DASHBOARD:" + Self.dashboardIndexHash), launcherReady: launcherProbe.trimmingCharacters(in: .whitespacesAndNewlines) == Self.launcherHash)
    }
    func request(_ value: [String: Any], expectedTarget: (Identity, String)? = nil) throws -> VPNStatus {
        let current = try engine.identity()
        if let expectedTarget { try require(current.0 == expectedTarget.0 && current.1 == expectedTarget.1, "Модем изменился или перезагрузился. Проверьте подключение заново.") }
        let data = try JSONSerialization.data(withJSONObject: value)
        try require(data.count <= 65536, "Ссылка профиля слишком длинная")
        let accepted = value["action"] as? String == "status" ? [Self.helperHash, "9c2e3c21eecace7031c4029c969efdec44241f000716447df805f3020dfce95e", "8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827", "96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88", "48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4", "572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5", "80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23", "3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3"].joined(separator: "|") : Self.helperHash
        let targetGuard = expectedTarget.map { target in
            "test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(target.0.cid) + "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(target.1) + "; "
        } ?? ""
        let command = "set -eu; " + targetGuard + "test -d /data/zte-vpn; test ! -L /data/zte-vpn; test \"$(stat -c '%u:%a' /data/zte-vpn)\" = 0:700; test ! -L /data/zte-vpn/vpnctl; case \"$(sha256sum /data/zte-vpn/vpnctl | cut -d ' ' -f1)\" in " + accepted + ") ;; *) exit 1;; esac; exec /data/zte-vpn/vpnctl request"
        let result = try engine.transport.run(command, input: data, timeout: 240)
        guard let reply = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw IMEIError.message("Не удалось проверить ответ менеджера VPN. Обновите состояние.")
        }
        guard result.status == 0, reply["ok"] as? Bool == true, let payload = reply["data"] else {
            throw IMEIError.message(Self.message(reply["code"] as? String ?? "VPN_OPERATION_FAILED"))
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(VPNStatus.self, from: JSONSerialization.data(withJSONObject: payload))
        try require(status.schemaVersion == 1 && status.profiles.count <= 32, "Неизвестный формат состояния VPN")
        return status
    }
    func configureWiFi(_ configuration: VPNWiFiConfiguration) throws -> VPNInspection {
        try require(engine.lockFD >= 0, "Настройка Wi-Fi требует блокировки операции")
        let target = try engine.identity()
        try engine.acquireRemoteLock()
        let before = try inspect()
        try require(before.status.installed && before.helperReady && before.status.settingsSupported == true, "Сначала установите или обновите компоненты VPN.")
        try require(!before.status.enabled, Self.message("VPN_WIFI_SETTINGS_ENABLED"))
        try configuration.validate(configured: before.status.configured)
        var requestBody = configuration.request; requestBody["lock_token"] = engine.remoteLockToken
        let after = try request(requestBody, expectedTarget: target)
        let confirmed = try engine.identity()
        try require(confirmed.0 == target.0 && confirmed.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
        try require(after.installed && after.settingsSupported == true && !after.enabled && after.configured == before.status.configured && after.activeProfile == before.status.activeProfile && after.desiredSsid == configuration.ssid && after.passwordMode == configuration.passwordMode, "Модем не подтвердил сохранение настроек Wi-Fi. Обновите состояние VPN перед повтором.")
        if after.configured {
            try require(after.ssid2G == configuration.ssid && after.ssid5G == configuration.ssid && after.actualSSID == configuration.ssid, "SSID на модеме не совпал с сохранёнными настройками. Обновите состояние VPN.")
        }
        var result = before; result.status = after
        return result
    }

    func install() throws -> VPNInspection {
        let before = try inspect()
        try require(before.missingCapabilities.isEmpty, "В прошивке отсутствуют необходимые компоненты: " + before.missingCapabilities.joined(separator: ", "))
        try engine.acquireRemoteLock()
        if before.status.installed {
            if !before.helperReady || !before.agentReady || !before.dashboardReady || !before.launcherReady { try updateAgent() }
            return try inspect()
        }
        let directory = engine.resources.appendingPathComponent("VPN")
        let manifest = try readJSON([String:String].self, directory.appendingPathComponent("SHA256.json"))
        let names = ["install.sh", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "vpnctl", "mihomo"]
        try require(manifest["vpnctl"] == Self.helperHash, "Повреждён комплект VPN")
        let stage = "/tmp/zte-vpn-install-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer { _ = try? engine.remote("rm -f " + names.map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), timeout: 15) }
        for (i, name) in names.enumerated() {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            try require(digest(bytes) == manifest[name], "Повреждён компонент VPN: " + name)
            engine.update("Устанавливаю компоненты VPN: \(i + 1) из \(names.count)", Double(i + 1) / Double(names.count + 1))
            let target = shellQuote(stage + "/" + name)
            let result = try engine.remote("umask 077; cat > " + target + " && chmod 700 " + target + " && sha256sum " + target, input: bytes, timeout: 180)
            try require(String(decoding: result, as: UTF8.self).split(separator: " ").first == Substring(digest(bytes)), "Компонент VPN повреждён при передаче")
        }
        _ = try engine.remote("sh " + shellQuote(stage + "/install.sh") + " " + shellQuote(stage), timeout: 120)
        try updateAgent()
        return try inspect()
    }
    /// The controller pins the display library and the agent pins the controller.
    /// Upgrade that existing chain together; never configure or enable a VPN here.
    func updateDisplayIntegrationIfNeeded() throws -> Bool {
        try require(engine.lockFD >= 0 && engine.remoteLockToken != nil, "Обновление дисплея требует блокировки операции")
        let presence = try engine.text("if test -e /data/zte-vpn || test -L /data/zte-vpn; then printf PRESENT; else printf ABSENT; fi")
        if presence == "ABSENT" { return false }
        try require(presence == "PRESENT", "Не удалось определить состояние компонентов VPN")
        _ = try engine.remote("test -d /data/zte-vpn && test ! -L /data/zte-vpn && test -f /data/zte-vpn/vpnctl && test ! -L /data/zte-vpn/vpnctl && test -f /data/zte-agent && test ! -L /data/zte-agent && test ! -e /data/zte-vpn/transaction")
        // Reject a custom agent before replacing its controller: the existing
        // update script would reject it later, leaving mismatched components.
        let bundle = engine.resources.appendingPathComponent("VPN")
        let manifest = try readJSON([String: String].self, bundle.appendingPathComponent("SHA256.json"))
        let script = try Data(contentsOf: bundle.appendingPathComponent("update-agent.sh"))
        try require(digest(script) == manifest["update-agent.sh"], "Повреждён установщик компонентов дисплея")
        let prefix = "case \"$(hash /data/zte-agent)\" in "
        guard let row = String(decoding: script, as: UTF8.self).components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
              let pattern = row.dropFirst(prefix.count).split(separator: ")", maxSplits: 1).first else {
            throw IMEIError.message("Неизвестный формат проверки совместимости агента")
        }
        let supported = pattern.split(separator: "|").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .map { $0 == "$agent_sha" ? Self.agentHash : $0 }
        try require(!supported.isEmpty && supported.allSatisfy(DeviceBackups.validHash), "Повреждён список совместимых агентов")
        let installed = try engine.text("sha256sum /data/zte-agent | awk '{print $1}'")
        try require(supported.contains(installed), "Установлен сторонний агент. Обновление дисплея остановлено до изменения компонентов VPN; требуется проверка совместимости этого агента.")
        engine.update("Обновляю связь дисплея с установленными компонентами VPN", 0.2)
        try updateAgent()
        return true
    }
    private func updateAgent() throws {
        let root = engine.resources.appendingPathComponent("VPN")
        let manifest = try readJSON([String:String].self, root.appendingPathComponent("SHA256.json"))
        let files = ["upgrade-controller.sh", "vpnctl", "manager.sh", "configure.lua", "update-agent.sh", "agent-transaction.sh", "dashboard.tar.gz", "dashboard-uhttpd", "start-dashboard.sh", "dashboard-html.sh", "preserve-dashboard-assets.sh", "stop-owned-listener.sh", "update-rc-local.sh", "launcher.so", "launcher-run.sh", "launcher-watch.sh", "launcher-service.sh", "launcher-start.sh", "launcher.sha256", "install-launcher.sh"]
        let stage = "/tmp/zte-vpn-agent-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer { _ = try? engine.remote("rm -f " + (files + ["zte-agent"]).map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage)) }
        for name in files + ["zte-agent"] {
            let file = name == "zte-agent" ? engine.resources.appendingPathComponent("Onboarding/zte-agent") : root.appendingPathComponent(name)
            let data = try Data(contentsOf: file)
            let expected = name == "zte-agent" ? Self.agentHash : manifest[name]
            try require(digest(data) == expected, "Повреждён компонент агента: " + name)
            let remote = shellQuote(stage + "/" + name)
            let proof = try engine.remote("umask 077; cat > " + remote + " && chmod 700 " + remote + " && sha256sum " + remote, input: data, timeout: 120)
            try require(String(decoding: proof, as: UTF8.self).split(separator: " ").first == Substring(digest(data)), "Компонент агента повреждён при передаче")
        }
        engine.update("Обновляю агент и его веб-панель с сохранением учётных данных", 0.9)
        _ = try engine.remote("sh " + shellQuote(stage + "/upgrade-controller.sh") + " " + shellQuote(stage), timeout: 120)
        _ = try engine.remote("sh " + shellQuote(stage + "/update-agent.sh") + " " + shellQuote(stage), timeout: 180)
        engine.update("Добавляю страницы в штатный лаунчер модема", 0.97)
        _ = try engine.remote("sh " + shellQuote(stage + "/install-launcher.sh") + " " + shellQuote(stage), timeout: 120)
    }

}
