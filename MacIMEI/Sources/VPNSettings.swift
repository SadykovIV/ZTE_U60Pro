import Foundation

struct VPNProfile: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var transport: String
    var warnings: [String]
    var active: Bool
}
/// Profile credentials exist only in the request body sent through SSH stdin.
enum VPNOperation: Sendable {
    case importProfile(uri: String, name: String)
    case activate(String)
    case rename(String, String)
    case delete(String)
    case setEnabled(Bool)

    var request: [String: Any] {
        switch self {
        case .importProfile(let uri, let name):
            var value: [String: Any] = ["action": "import", "uri": uri.trimmingCharacters(in: .whitespacesAndNewlines)]
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            return value
        case .activate(let id): return ["action": "activate", "id": id]
        case .rename(let id, let name): return ["action": "rename", "id": id, "name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .delete(let id): return ["action": "delete", "id": id]
        case .setEnabled(let enabled): return ["action": "set_enabled", "enabled": enabled]
        }
    }
    var message: String {
        switch self {
        case .importProfile: return "Профиль VPN импортирован"
        case .activate: return "Активный профиль VPN изменён"
        case .rename: return "Название профиля VPN сохранено"
        case .delete: return "Профиль VPN удалён"
        case .setEnabled(let enabled): return enabled ? "Wi-Fi с VPN включён" : "Wi-Fi с VPN выключен"
        }
    }
    func validate() throws {
        let value = request
        if let id = value["id"] as? String { try require(id.utf8.count == 36 && UUID(uuidString: id) != nil, "Недопустимый идентификатор VPN-профиля.") }
        if let name = value["name"] as? String {
            try require(!name.isEmpty && name.unicodeScalars.count <= 64 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), VPNSettingsManager.message("VPN_INVALID_NAME"))
        }
        if let uri = value["uri"] as? String {
            try require(uri.hasPrefix("vless://") && uri.utf8.count <= 32768 && !uri.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), "Нужна одна ссылка vless:// длиной не больше 32 КиБ.")
        }
    }
    func verify(before: VPNStatus, after: VPNStatus) throws {
        let confirmed: Bool
        switch self {
        case .importProfile:
            confirmed = after.profiles.count == before.profiles.count + 1 && after.profiles.filter { profile in !before.profiles.contains { $0.id == profile.id } }.count == 1
        case .activate(let id): confirmed = after.activeProfile == id && after.profiles.contains { $0.id == id && $0.active }
        case .rename(let id, let name): confirmed = after.profiles.contains { $0.id == id && $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) }
        case .delete(let id): confirmed = !after.profiles.contains { $0.id == id }
        case .setEnabled(let enabled): confirmed = after.enabled == enabled
        }
        try require(confirmed, "Модем не подтвердил изменение VPN. Обновите состояние перед повтором.")
    }
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

enum VPNRequestFailure: LocalizedError, Equatable {
    case unsafeControllerLayout
    case unrecognizedController
    case commandFailed(Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsafeControllerLayout:
            return "Файлы менеджера VPN не прошли проверку типа и прав доступа. Команда не запускалась; проверьте установку компонентов."
        case .unrecognizedController:
            return "Сборка менеджера VPN не распознана. Команда не запускалась; проверьте установленный компонент перед обновлением."
        case .commandFailed(let code):
            return "Команда менеджера VPN завершилась с ошибкой (exit \(code)). Обновите состояние; подробности — в журнале."
        case .invalidResponse:
            return "Не удалось проверить ответ менеджера VPN. Обновите состояние."
        }
    }
}

/// Both the desktop and agent send private JSON on stdin to the same modem helper.
final class VPNSettingsManager {
    static let root = "/data/zte-vpn"
    static let launcherHash = "c04c5c1d0cccb0a2964a1500e6fdc3c549c9eac6125fe591b9cdf25d39dff3c2"
    static let agentHash = BundledAgent.sha256
    static let dashboardIndexHash = "c804a8ecced9ed3478ee50021b95d3bcd02394f23ba09f10c5c3691f44cd9546"
    static let helperHash = "f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c"
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
        return messages[code] ?? "Не удалось завершить настройку VPN. Обновите состояние (VPN_OPERATION_FAILED)."
    }
    static let helperReadinessCommand = #"""
    vpn_ready_file() {
        test -f "$1" && test ! -L "$1" && test "$(stat -c %u:%h "$1")" = 0:1 || return 1
        vpn_ready_perm=$(stat -c %a "$1") || return 1
        test "$((0$vpn_ready_perm & 022))" = 0
    }
    if vpn_ready_file /etc/init.d/zte_vpn && vpn_ready_file /data/zte-vpn/service.sh &&
       cmp -s /etc/init.d/zte_vpn /data/zte-vpn/service.sh &&
       test -L /etc/rc.d/S99zte_vpn && test "$(stat -c %u /etc/rc.d/S99zte_vpn)" = 0 &&
       test "$(readlink /etc/rc.d/S99zte_vpn)" = ../init.d/zte_vpn &&
       test -L /etc/rc.d/K01zte_vpn && test "$(stat -c %u /etc/rc.d/K01zte_vpn)" = 0 &&
       test "$(readlink /etc/rc.d/K01zte_vpn)" = ../init.d/zte_vpn; then
        if test ! -e /data/zte-vpn/configured && test ! -L /data/zte-vpn/configured; then
            echo HELPER_LAYOUT_READY
        elif vpn_ready_file /data/zte-vpn/configured && vpn_ready_file /etc/init.d/network &&
             vpn_ready_file /data/zte-vpn/network-init.sha256 &&
             test "$(sha256sum /etc/init.d/network | cut -d ' ' -f1)" = "$(cat /data/zte-vpn/network-init.sha256)"; then
            echo HELPER_LAYOUT_READY
        fi
    fi
    true
    """#
    func inspect() throws -> VPNInspection {
        _ = try engine.diagnosticIdentity()
        let probe = try engine.text("for c in lua nft iptables ip6tables ebtables dnsmasq ip ubus flock jsonfilter; do command -v \"$c\" >/dev/null 2>&1 || printf 'MISSING:%s\\n' \"$c\"; done; test -c /dev/net/tun || echo MISSING:TUN; test ! -e /data/zte-imei-apps/ssclash/bin/ssclash || echo SSCLASH; test ! -e /data/zte-vpn || echo VPN; test ! -e /data/zte-vpn/controller-upgrade || echo UPGRADE_PENDING; sha256sum /data/zte-vpn/vpnctl 2>/dev/null | awk '{print \"HELPER:\" $1}'; " + Self.helperReadinessCommand)
        let lines = probe.split(separator: "\n").map(String.init)
        var status = VPNStatus()
        if lines.contains("UPGRADE_PENDING") { status.installed = true }
        else if lines.contains("VPN") { status = try request(["action": "status"]) }
        return VPNInspection(status: status,
            missingCapabilities: lines.filter { $0.hasPrefix("MISSING:") }.map { String($0.dropFirst(8)) },
            ssclashInstalled: lines.contains("SSCLASH"),
            helperReady: lines.contains("HELPER:" + Self.helperHash) && lines.contains("HELPER_LAYOUT_READY") && !lines.contains("UPGRADE_PENDING"))
    }
    func request(_ value: [String: Any], expectedTarget: (Identity, String)? = nil) throws -> VPNStatus {
        let current = try engine.diagnosticIdentity()
        if let expectedTarget { try require(current.0 == expectedTarget.0 && current.1 == expectedTarget.1, "Модем изменился или перезагрузился. Проверьте подключение заново.") }
        let data = try JSONSerialization.data(withJSONObject: value)
        try require(data.count <= 65536, "Ссылка профиля слишком длинная")
        let accepted = value["action"] as? String == "status" ? [Self.helperHash, "7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb", "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231", "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4", "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca", "cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0", "9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce", "9c2e3c21eecace7031c4029c969efdec44241f000716447df805f3020dfce95e", "8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827", "96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88", "48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4", "572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5", "80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23", "3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3"].joined(separator: "|") : Self.helperHash
        let targetGuard = expectedTarget.map { target in
            "test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(target.0.cid) + "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(target.1) + "; "
        } ?? ""
        let command = "set -eu; " + targetGuard +
            "test -d /data/zte-vpn && test ! -L /data/zte-vpn && test \"$(stat -c '%u:%a' /data/zte-vpn)\" = 0:700 && test ! -L /data/zte-vpn/vpnctl || { printf 'VPN_REQUEST_GUARD unsafe_layout\\n' >&2; exit 78; }; " +
            "case \"$(sha256sum /data/zte-vpn/vpnctl | cut -d ' ' -f1)\" in " + accepted +
            ") ;; *) printf 'VPN_REQUEST_GUARD controller_hash\\n' >&2; exit 78;; esac; exec /data/zte-vpn/vpnctl request"
        let result = try engine.transport.run(command, input: data, timeout: 240)
        if result.status == 78 {
            switch CommandText.decode(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines) {
            case "VPN_REQUEST_GUARD unsafe_layout": throw VPNRequestFailure.unsafeControllerLayout
            case "VPN_REQUEST_GUARD controller_hash": throw VPNRequestFailure.unrecognizedController
            default: break
            }
        }
        if result.status != 0 {
            // A helper may return a structured refusal with a nonzero exit.
            // Preserve that fixed VPN code; never expose arbitrary output.
            if let reply = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
               reply["ok"] as? Bool == false, let code = reply["code"] as? String,
               code.range(of: #"^VPN_[A-Z0-9_]{1,64}$"#, options: .regularExpression) != nil {
                throw IMEIError.message(Self.message(code))
            }
            throw VPNRequestFailure.commandFailed(result.status)
        }
        guard let reply = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw VPNRequestFailure.invalidResponse
        }
        guard reply["ok"] as? Bool == true, let payload = reply["data"] else {
            throw IMEIError.message(Self.message(reply["code"] as? String ?? "VPN_OPERATION_FAILED"))
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(VPNStatus.self, from: JSONSerialization.data(withJSONObject: payload))
        try require(status.schemaVersion == 1 && status.profiles.count <= 32, "Неизвестный формат состояния VPN")
        return status
    }
    func perform(_ operation: VPNOperation) throws -> VPNInspection {
        try operation.validate()
        try require(engine.lockFD >= 0, "Операция VPN требует локальной блокировки")
        let target = try engine.diagnosticIdentity()
        var result = try inspect()
        try require(result.helperReady, "Сначала установите или обновите компоненты VPN.")
        // vpnctl owns the shared modem lock for profile operations. Acquiring
        // that lock here too would make every request fail with VPN_BUSY.
        let after = try request(operation.request, expectedTarget: target)
        let current = try engine.diagnosticIdentity()
        try require(current.0 == target.0 && current.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
        try operation.verify(before: result.status, after: after)
        result.status = after
        return result
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
            if !before.helperReady { try upgradeController() }
            else { try verifyInstalledComponents() }
        } else {
            try installComponents()
        }
        let after = try inspect()
        try require(after.status.installed && after.helperReady, "Установка компонентов VPN не подтверждена. Обновите состояние; подробности — в журнале.")
        return after
    }

    /// Only an explicit install checks the already installed core checksum.
    /// Routine status refreshes keep using the lightweight status request.
    private func verifyInstalledComponents() throws {
        let command = "set -eu; test -d /data/zte-vpn && test ! -L /data/zte-vpn && test \"$(stat -c '%u:%a' /data/zte-vpn)\" = 0:700; test -f /data/zte-vpn/vpnctl && test ! -L /data/zte-vpn/vpnctl; test \"$(sha256sum /data/zte-vpn/vpnctl | cut -d ' ' -f1)\" = " + shellQuote(Self.helperHash) + "; exec /data/zte-vpn/vpnctl integrity"
        let result = try engine.transport.run(command, input: nil, timeout: 60)
        let reply = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        if result.status != 0 {
            let known = ["VPN_NOT_INSTALLED", "VPN_FILE_UNAVAILABLE", "VPN_UNSAFE_FILE", "VPN_INTEGRITY", "VPN_DEVICE_CHANGED", "VPN_CORE_INTEGRITY", "VPN_UNSUPPORTED_FIRMWARE"]
            if reply?["ok"] as? Bool == false, let code = reply?["code"] as? String, known.contains(code) {
                throw IMEIError.message(Self.message(code == "VPN_CORE_INTEGRITY" ? code : "VPN_INTEGRITY") + " (" + code + ")")
            }
            throw VPNRequestFailure.commandFailed(result.status)
        }
        guard reply?["ok"] as? Bool == true, let data = reply?["data"] as? [String: Any], data["verified"] as? Bool == true else {
            throw VPNRequestFailure.invalidResponse
        }
    }

    private func installComponents() throws {
        let names = ["install.sh", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "vpnctl", "mihomo"]
        try runInstaller(names: names, prefix: "zte-vpn-install", script: "install.sh", receipt: "VPN_COMPONENTS_INSTALLED")
    }

    private func upgradeController() throws {
        let names = ["upgrade-controller.sh", "vpnctl", "manager.sh", "configure.lua"]
        try runInstaller(names: names, prefix: "zte-vpn-agent", script: "upgrade-controller.sh", receipt: "VPN_CONTROLLER_UPDATED")
    }

    /// Install only the controller/core. Agent, dashboard and display have their
    /// own installers; none is a prerequisite for desktop VPN management.
    private func runInstaller(names: [String], prefix: String, script: String, receipt: String) throws {
        let target = try engine.diagnosticIdentity()
        let directory = engine.resources.appendingPathComponent("VPN")
        let manifest = try readJSON([String:String].self, directory.appendingPathComponent("SHA256.json"))
        try require(manifest["vpnctl"] == Self.helperHash, "Повреждён комплект VPN")
        let stage = "/tmp/" + prefix + "-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        var cleanupSafe = true
        defer {
            if cleanupSafe { _ = try? engine.remote("rm -f " + names.map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), timeout: 15) }
        }
        for (index, name) in names.enumerated() {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            try require(digest(bytes) == manifest[name], "Повреждён компонент VPN: " + name)
            engine.update("Устанавливаю компоненты VPN: \(index + 1) из \(names.count)", Double(index + 1) / Double(names.count + 1))
            let remote = shellQuote(stage + "/" + name)
            let output = try engine.remote("umask 077; cat > " + remote + " && chmod 700 " + remote + " && sha256sum " + remote, input: bytes, timeout: 180)
            try require(String(decoding: output, as: UTF8.self).split(separator: " ").first == Substring(digest(bytes)), "Компонент VPN повреждён при передаче")
        }
        let current = try engine.diagnosticIdentity()
        try require(current.0 == target.0 && current.1 == target.1, "Модем изменился или перезагрузился. Проверьте подключение заново.")
        guard let lockToken = engine.remoteLockToken else { throw IMEIError.message("Установка VPN требует блокировки операции") }
        cleanupSafe = false
        let result = try engine.transport.run("set -eu; test \"$(cat /tmp/zte-imei-app.lock/owner)\" = " + shellQuote(lockToken) + "; test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(target.0.cid) + "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(target.1) + "; sh " + shellQuote(stage + "/" + script) + " " + shellQuote(stage), input: nil, timeout: 180)
        cleanupSafe = result.status >= 0 && result.status < 255
        if result.status != 0, let refusal = Self.upgradeFailure(result) { throw IMEIError.message(refusal) }
        try require(result.status == 0 && String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").contains(Substring(receipt)),
                    "Установка компонентов VPN не подтверждена (exit \(result.status)). Подробности — в журнале. При потере связи файлы восстановления сохранены.")
        let confirmed = try engine.diagnosticIdentity()
        try require(confirmed.0 == target.0 && confirmed.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
    }

    /// A verified script emits a finite error catalog. Arbitrary stderr remains
    /// out of UI text, and a lost SSH channel never becomes a confirmed refusal.
    static func upgradeFailure(_ result: CommandResult) -> String? {
        guard result.status > 0 && result.status < 255 else { return nil }
        let messages = [
            "INVALID_STAGE": "Не удалось проверить временные файлы обновления VPN.",
            "UNSAFE_LAYOUT": "Каталоги компонентов VPN не прошли проверку владельца и прав.",
            "PAYLOAD": "Компоненты обновления VPN не прошли проверку контрольных сумм.",
            "VPN_PENDING": "Сначала завершите предыдущую настройку VPN.",
            "SCREEN_BUSY": "Закройте временную страницу VPN на модеме и повторите обновление.",
            "CONTROLLER_UNKNOWN": "Установлен неизвестный контроллер VPN. Автоматическая замена остановлена.",
            "OLD_INTEGRITY": "Установленные компоненты VPN не прошли проверку целостности.",
            "DEVICE_CHANGED": "Модем изменился во время обновления VPN. Проверьте подключение.",
            "NETWORK_CHANGED": "Сценарий запуска сети изменён и не совпадает со штатным или сохранённым. Обновление VPN остановлено.",
            "SERVICE_CHANGED": "Служба VPN изменена. Посторонний файл не заменён.",
            "STARTUP_CHANGED": "Автозапуск VPN изменён. Посторонние ссылки не заменены.",
            "STATE_UNSAFE": "Сохранённое состояние VPN не прошло проверку. Исходные данные сохранены.",
            "SNAPSHOT": "Не удалось подтвердить резервную копию компонентов VPN.",
            "WRITE": "Не удалось завершить замену компонентов VPN. Проверьте состояние перед повтором.",
            "NEW_INTEGRITY": "Новые компоненты VPN не прошли проверку целостности.",
            "VERIFY": "Результат обновления VPN не подтверждён. Проверьте состояние перед повтором.",
            "RECOVERY_REQUIRED": "Предыдущее обновление VPN требует восстановления; его журнал сохранён.",
            "ROLLBACK_UNKNOWN": "Откат компонентов VPN не подтверждён. Журнал и средства восстановления сохранены."
        ]
        let lines = CommandText.decode(result.stderr).split(separator: "\n").map(String.init)
        let prefix = "VPN_UPGRADE_ERROR "
        let codes = lines.compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            let code = String(line.dropFirst(prefix.count))
            return messages[code] == nil ? nil : code
        }
        guard let code = codes.contains("ROLLBACK_UNKNOWN") ? "ROLLBACK_UNKNOWN" : (Set(codes).count == 1 ? codes.first : nil),
              let message = messages[code] else { return nil }
        return message + " (VPN_UPGRADE_" + code + ")"
    }

}
