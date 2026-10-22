import Foundation

/// Passwords are write-only; profile details contain only a password-presence flag.
struct VPNIKEv2Configuration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "IKEv2 configuration (private)" }
    var debugDescription: String { description }
    var server = ""
    var serverID = ""
    var username = ""
    var password = ""
    var caCertificate = ""
    var dns = "10.0.2.1"

    var request: [String: Any] {
        var value: [String: Any] = ["server": server.trimmingCharacters(in: .whitespacesAndNewlines), "server_id": serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? server.trimmingCharacters(in: .whitespacesAndNewlines) : serverID.trimmingCharacters(in: .whitespacesAndNewlines), "username": username, "ca_certificate": caCertificate, "dns": dns.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !password.isEmpty { value["password"] = password }
        return value
    }
    func validate(editing: Bool) throws {
        func validHost(_ value: String) -> Bool {
            guard value.utf8.count <= 253 && value.contains(".") else { return false }
            let labels = value.split(separator: ".", omittingEmptySubsequences: false)
            if value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                return labels.count == 4 && labels.allSatisfy { label in Int(label).map { (0...255).contains($0) && String($0) == label } ?? false }
            }
            return labels.allSatisfy { $0.utf8.count <= 63 && $0.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil }
        }
        let value = request
        try require(validHost(value["server"] as! String), VPNSettingsManager.message("VPN_IKEV2_INVALID_SERVER"))
        try require(validHost(value["server_id"] as! String), VPNSettingsManager.message("VPN_IKEV2_INVALID_ID"))
        try require(!username.isEmpty && username.utf8.count <= 256 && !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), VPNSettingsManager.message("VPN_IKEV2_INVALID_USERNAME"))
        try require((editing || !password.isEmpty) && password.utf8.count <= 1024 && !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), VPNSettingsManager.message("VPN_IKEV2_INVALID_PASSWORD"))
        try require(caCertificate.utf8.count <= 65536 && caCertificate.contains("-----BEGIN CERTIFICATE-----") && caCertificate.contains("-----END CERTIFICATE-----") && !caCertificate.contains("PRIVATE KEY") && !caCertificate.contains("\0"), VPNSettingsManager.message("VPN_IKEV2_INVALID_CERTIFICATE"))
        let parts = (value["dns"] as! String).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(part), (0...255).contains(n), String(n) == part else { return nil }; return n
        }
        try require(numbers.count == 4 && !(numbers[0] == 192 && numbers[1] == 168 && numbers[2] == 50) && (numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1])) || (numbers[0] == 192 && numbers[1] == 168)), VPNSettingsManager.message("VPN_IKEV2_INVALID_DNS"))
    }
}

struct VPNIKEv2Profile: Sendable {
    var id: String
    var name: String
    var configuration: VPNIKEv2Configuration
}

struct VPNProfile: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var transport: String
    var warnings: [String]
    var active: Bool
    var protocolName: String? = nil
    var subscriptionId: String? = nil
    var updateAvailable: Bool? = nil
    var removedFromSubscription: Bool? = nil
    var canActivate: Bool { protocolName == "ikev2" || !active || updateAvailable == true }
    enum CodingKeys: String, CodingKey { case id, name, transport, warnings, active, protocolName = "protocol", subscriptionId, updateAvailable, removedFromSubscription }
}
struct VPNSubscription: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var host: String
    var updatedAt: UInt64
    var profileCount: Int
}
struct VPNImportSummary: Decodable, Sendable {
    struct Skipped: Decodable, Sendable { var index: Int; var code: String }
    var added: Int; var updated: Int; var removed: Int; var duplicates: Int; var retainedActive: Int
    var skipped: [Skipped]
}
/// Profile credentials exist only in the request body sent through SSH stdin.
enum VPNOperation: Sendable {
    case saveIKEv2(id: String?, name: String, configuration: VPNIKEv2Configuration)
    case importProfile(uri: String, name: String)
    case importConfiguration(config: String, name: String)
    case importSubscription(url: String, name: String, documents: [String]? = nil)
    case updateSubscription(String, documents: [String]? = nil)
    case deleteSubscription(String)
    case activate(String)
    case rename(String, String)
    case delete(String)
    case setEnabled(Bool)

    static func isProfileLink(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["vless://", "hy2://", "hysteria2://"].contains { value.hasPrefix($0) }
    }

    var request: [String: Any] {
        switch self {
        case .saveIKEv2(let id, let name, let configuration):
            var value: [String: Any] = ["action": "save_ikev2", "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "ikev2": configuration.request]
            if let id { value["id"] = id }
            return value
        case .importProfile(let uri, let name):
            var value: [String: Any] = ["action": "import", "uri": uri.trimmingCharacters(in: .whitespacesAndNewlines)]
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            return value
        case .importConfiguration(let config, let name):
            var value: [String: Any] = ["action": "import_config", "config": config]
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            return value
        case .importSubscription(let url, let name, let documents):
            var value: [String: Any] = ["action": "subscription_import", "url": url.trimmingCharacters(in: .whitespacesAndNewlines)]
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let documents { value["documents"] = documents }
            return value
        case .updateSubscription(let id, let documents):
            var value: [String: Any] = ["action": "subscription_update", "id": id]
            if let documents { value["documents"] = documents }
            return value
        case .deleteSubscription(let id): return ["action": "subscription_delete", "id": id]
        case .activate(let id): return ["action": "activate", "id": id]
        case .rename(let id, let name): return ["action": "rename", "id": id, "name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .delete(let id): return ["action": "delete", "id": id]
        case .setEnabled(let enabled): return ["action": "set_enabled", "enabled": enabled]
        }
    }
    var message: String {
        switch self {
        case .saveIKEv2: return "Профиль IKEv2 сохранён. Выберите «Сделать активным», чтобы применить настройки."
        case .importProfile, .importConfiguration: return "Профиль VPN импортирован"
        case .importSubscription: return "Подписка VPN импортирована"
        case .updateSubscription: return "Подписка VPN обновлена; действующее подключение сохранено"
        case .deleteSubscription: return "Подписка VPN удалена; её профили сохранены"
        case .activate: return "Активный профиль VPN изменён"
        case .rename: return "Название профиля VPN сохранено"
        case .delete: return "Профиль VPN удалён"
        case .setEnabled(let enabled): return enabled ? "Wi-Fi с VPN включён" : "Wi-Fi с VPN выключен"
        }
    }
    func validate() throws {
        if case .saveIKEv2(let id, _, let configuration) = self { try configuration.validate(editing: id != nil) }
        let value = request
        if let id = value["id"] as? String { try require(id.utf8.count == 36 && UUID(uuidString: id) != nil, "Недопустимый идентификатор VPN-профиля.") }
        if let name = value["name"] as? String {
            try require(!name.isEmpty && name.unicodeScalars.count <= 64 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), VPNSettingsManager.message("VPN_INVALID_NAME"))
        }
        if let uri = value["uri"] as? String {
            try require(Self.isProfileLink(uri) && uri.utf8.count <= 32768 && !uri.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), "Нужна одна ссылка vless://, hy2:// или hysteria2:// длиной не больше 32 КиБ.")
        }
        if let config = value["config"] as? String {
            try require(!config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && config.utf8.count <= 8 * 1024 * 1024 && !config.contains("\0"), "Нужна конфигурация WireGuard или AmneziaWG в формате .conf, не больше 8 МиБ.")
        }
        if let url = value["url"] as? String { _ = try VPNSubscriptionDownload.validatedURL(url) }
        if let documents = value["documents"] as? [String] {
            try require((1...2).contains(documents.count) && documents.allSatisfy { !$0.isEmpty && $0.utf8.count <= 8 * 1024 * 1024 }, "Содержимое подписки превышает 8 МиБ или пусто.")
        }
    }
    func verify(before: VPNStatus, after: VPNStatus) throws {
        let confirmed: Bool
        switch self {
        case .saveIKEv2(let id, let name, _):
            if let id {
                confirmed = after.profiles.count == before.profiles.count && after.profiles.contains { $0.id == id && $0.protocolName == "ikev2" && $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) } && after.activeProfile == before.activeProfile && after.enabled == before.enabled
            } else {
                confirmed = after.profiles.count == before.profiles.count + 1 && after.profiles.filter { profile in !before.profiles.contains { $0.id == profile.id } && profile.protocolName == "ikev2" && profile.name == name.trimmingCharacters(in: .whitespacesAndNewlines) }.count == 1 && after.activeProfile == before.activeProfile && after.enabled == before.enabled
            }
        case .importProfile, .importConfiguration:
            confirmed = after.profiles.count == before.profiles.count + 1 && after.profiles.filter { profile in !before.profiles.contains { $0.id == profile.id } }.count == 1
        case .importSubscription:
            confirmed = (after.subscriptions?.count ?? 0) == (before.subscriptions?.count ?? 0) + 1 && after.lastImport != nil && after.activeProfile == before.activeProfile && after.enabled == before.enabled
        case .updateSubscription(let id, _):
            confirmed = after.subscriptions?.contains { $0.id == id } == true && after.lastImport != nil && after.activeProfile == before.activeProfile && after.enabled == before.enabled
        case .deleteSubscription(let id):
            confirmed = after.subscriptions?.contains { $0.id == id } != true && Set(after.profiles.map(\.id)) == Set(before.profiles.map(\.id)) && after.activeProfile == before.activeProfile && after.enabled == before.enabled
        case .activate(let id): confirmed = after.activeProfile == id && after.profiles.contains { $0.id == id && $0.active && $0.updateAvailable != true }
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
    var ikev2Connected: Bool?
    var ikev2State: String?
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
    var subscriptions: [VPNSubscription]?
    var lastImport: VPNImportSummary?

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

    /// Status requests contain no import receipt. Keep the latest receipt only
    /// for this model's current device; selection changes clear vpnInspection.
    func preservingImportSummary(from previous: VPNInspection?) -> VPNInspection {
        var result = self
        if status.installed && previous?.status.installed == true && status.lastImport == nil {
            result.status.lastImport = previous?.status.lastImport
        }
        return result
    }
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
    static let launcherHash = "6e24686d0310c710c734ccc7c21469858e42a2e474f4a3c073bf1c476b460c50"
    static let agentHash = BundledAgent.sha256
    static let dashboardIndexHash = "870b88a3725b3b989d82a6a117e7077f74c927ca7dab25667d12be6165ea0b2a"
    static let helperHash = "46257e8e24397f097b3ce3e53067ad59b265803f66aeb2da6d216b05dd2e5db7"
    // Exact previously shipped controllers may serve read-only status before upgrade.
    // Mutations continue to require the current controller hash.
    static let supportedStatusHashes: Set<String> = [
        helperHash,
        "61ccaf5fa0361178dd6fe4a0104d964168f4f79a8453a8617a80a7403240d393",
        "4e8b92cc5089200f3fced24130e47e0918bf8931989af034f709344a42cd5b0d",
        "ff5859edb44d83fad9723ccdc142f28ce918b02fae3da929667726d32746986c",
        "a35d788005d4150cd909f85afc667073a03febd24b50a708facf506b051c8a65",
        "3b572cf943d16a66dae1d62515b216eceaf77d397035320eb3c08a5db0e21fc4",
        "8aaece533e2503c7a501497bb1bf191f37a0ffbba067e7a7ff3a4c6f9623673f",
        "e00749ed2a6273c95a4b0563212313c81e54928f6564fdbd8f9616d12a4df6ba",
        "b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a",
        "82a8b6655ff6cd43938ffe3735e8841599ef6116bf33079d8d203db9415ca3f2",
        "fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48",
        "b2c3fcfafeccd50fa3000ad5f8f66f1e42ff157b295cdda11dddd31571612af7",
        "cf15a6290316dd6832873e35972831a590d70cf0734eb93dbcd96aab87fab6f1",
        "f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c",
        "7a8b84c3502e711c6b66c943f883a984dd9ed82da41455fc083ed0cc7d44b6fb",
        "1cc33e3825a556a825e83392675c254ef22f738660d1016ae1413f7669f88231",
        "f620dab27f951c7de2de77a89376975b51c79f57f8a8a24cec95392c9c61eea4",
        "3142fb503e64ddba79d523be3c87f0344d6efa78673e30a4b740714d8e9389ca",
        "cdb01d27775d61bcb3ae14a8d124ccbab683f940f1dcfd2adffa43a6b7b462f0",
        "9e8b1a737888468a4be6a010a915524b84440037802c6cfc6a5e251abf0e81ce",
        "9c2e3c21eecace7031c4029c969efdec44241f000716447df805f3020dfce95e",
        "8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827",
        "96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88",
        "48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4",
        "572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5",
        "80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23",
        "3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3"
    ]
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }

    static func warning(_ code: String) -> String? {
        switch code {
        case "VPN_SPX_PRESERVED": return "Параметр spx сохранён в исходной ссылке, но не используется этим ядром VPN."
        case "NAME_TRUNCATED": return "Название профиля сокращено до 64 символов."
        case "VPN_INSECURE_TLS": return "В ссылке отключена проверка TLS-сертификата"
        case "VPN_IPV6_GUEST_DISABLED": return "Сеть Wi-Fi с VPN использует IPv4. Параметры IPv6 туннеля сохранены."
        default: return nil
        }
    }

    static func message(_ code: String) -> String {
        let messages = [
            "VPN_IKEV2_INVALID_SERVER": "Укажите имя или IPv4-адрес сервера IKEv2 без https:// и порта.",
            "VPN_IKEV2_INVALID_ID": "Укажите имя сервера из сертификата. Шаблоны и %any не допускаются.",
            "VPN_IKEV2_INVALID_USERNAME": "Введите логин IKEv2 до 256 байт без управляющих символов.",
            "VPN_IKEV2_INVALID_PASSWORD": "Введите пароль IKEv2 до 1024 байт без управляющих символов. При редактировании пустое поле сохраняет прежний пароль.",
            "VPN_IKEV2_INVALID_CERTIFICATE": "Нужен сертификат центра сертификации в формате PEM до 64 КиБ, без закрытого ключа.",
            "VPN_IKEV2_INVALID_DNS": "DNS должен быть IPv4-адресом из частных сетей 10/8, 172.16/12 или 192.168/16.",
            "VPN_IKEV2_UNAVAILABLE": "Компоненты strongSwan IKEv2 недоступны в прошивке модема.",
            "VPN_IKEV2_CONFLICT": "На модеме уже работает другая служба IPsec. Завершите её перед включением IKEv2.",
            "VPN_IKEV2_NOT_READY": "Туннель IKEv2 не подключён. Проверьте сервер, логин, пароль и сертификат.",
            "VPN_IKEV2_INVALID_PROFILE": "Параметры профиля IKEv2 повреждены. Откройте и сохраните профиль заново.",
            "VPN_BUSY": "На модеме выполняется другая операция. Повторите после её завершения.",
            "VPN_OTHER_TRANSACTION": "Сначала завершите обновление или настройку модема.",
            "VPN_VLESS_ONLY": "Вставьте ссылку профиля VLESS или Hysteria2 (vless://, hy2://, hysteria2://).",
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
            "VPN_PROFILE_LIMIT": "Можно хранить до 1024 профилей. Удалите ненужные профили.",
            "VPN_ACTIVE_PROFILE_DELETE": "Активный профиль удалить нельзя. Сначала выберите другой.",
            "VPN_NO_ACTIVE_PROFILE": "Сначала импортируйте и активируйте профиль.",
            "VPN_GUEST_IN_USE": "Гостевой Wi-Fi уже используется. Выключите его перед первой настройкой VPN.",
            "VPN_MESH_CONFLICT": "VPN-сеть использует гостевые интерфейсы. Сначала выключите Mesh.",
            "VPN_IPA_ENABLED": "Обновите компоненты VPN для автоматического переключения IPA.",
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
            "VPN_DHCP_NOT_READY": "Не запустилась служба выдачи IP-адресов VPN. Откройте «Логи и журналы»: подробности сохранены в vpn.log.",
            "VPN_WIFI_NOT_READY": "VPN-сеть не запустилась вовремя и была выключена. Настройки сохранены для проверки.",
            "VPN_SUBSCRIPTION_FILE_REFERENCE": "Профиль подписки ссылается на локальный файл сертификата или ключа. Нужны встроенные данные PEM.",
            "VPN_SUBSCRIPTION_EXISTS": "Такая подписка уже добавлена.",
            "VPN_AWG_DUPLICATE_OPTION": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_DUPLICATE_PEER": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_HEADER_PADDING_REQUIRED": "Для защиты заголовков AWG значения S1–S4 должны быть не меньше 12.",
            "VPN_AWG_INVALID_ADDRESS": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_BOOLEAN": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_CONFIG": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_DNS": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_ENDPOINT": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_JUNK_SIZE": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_KEY": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_LIST": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_MTU": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_NUMBER": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_RANGE": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_SECTION": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_INVALID_SIGNATURE": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_IPV4_ADDRESS_REQUIRED": "Для VPN-сети модема требуется IPv4-адрес туннеля.",
            "VPN_AWG_IPV6_ADDRESS_REQUIRED": "IPv6 DNS требует IPv6-адрес туннеля.",
            "VPN_AWG_MISSING_FIELD": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_MULTIPLE_LOCAL_ADDRESSES": "Это VPN-ядро поддерживает один локальный IPv4 и один IPv6-адрес туннеля.",
            "VPN_AWG_OVERLAPPING_HEADERS": "Диапазоны заголовков AWG H1–H4 пересекаются.",
            "VPN_AWG_OVERLAPPING_PEERS": "Маршруты разных узлов WireGuard пересекаются.",
            "VPN_AWG_PEER_KEEPALIVE_DIFFERS": "Это VPN-ядро требует одинаковый PersistentKeepalive для всех узлов.",
            "VPN_AWG_SIGNATURE_TOO_LARGE": "Некорректный параметр в файле WireGuard/AmneziaWG. Проверьте исходную конфигурацию.",
            "VPN_AWG_UNSUPPORTED_OPTION": "Файл WireGuard/AmneziaWG содержит неподдерживаемый параметр. Он не был импортирован.",
            "VPN_IPA_NOT_RUNNING": "Служба IPA не найдена. Проверьте журнал модема.",
            "VPN_IPA_PREPARE_FAILED": "Не удалось автоматически отключить IPA для VPN. Подробности — в журнале модема.",
            "VPN_IPA_RESTORE_FAILED": "Не удалось восстановить параметры IPA. Подробности — в журнале модема.",
            "VPN_IPA_STATE_INVALID": "Сохранённые параметры IPA повреждены. Проверьте журнал модема.",
            "VPN_IPA_UNSUPPORTED": "Реализация IPA в этой прошивке ещё не поддерживается.",
            "VPN_PROFILE_NOT_FOUND": "Профиль не найден. Обновите список.",
            "VPN_REQUEST_TOO_LARGE": "Запрос VPN превышает 32 МиБ.",
            "VPN_SUBSCRIPTION_DOCUMENT": "Документ подписки пуст или превышает 8 МиБ.",
            "VPN_SUBSCRIPTION_EMPTY": "В подписке нет поддерживаемых профилей.",
            "VPN_SUBSCRIPTION_ENTRY": "Запись подписки повреждена или не поддерживается.",
            "VPN_SUBSCRIPTION_FETCH": "Не удалось загрузить подписку. Проверьте доступ к интернету и ссылку.",
            "VPN_SUBSCRIPTION_FORMAT": "Формат подписки не распознан. Нужен список ссылок, Base64 или конфигурация Mihomo.",
            "VPN_SUBSCRIPTION_NOT_FOUND": "Подписка не найдена. Обновите список.",
            "VPN_SUBSCRIPTION_ROUTING": "Профиль подписки задаёт собственную маршрутизацию и не может быть применён к VPN-сети модема.",
            "VPN_SUBSCRIPTION_URL": "Нужна корректная HTTPS-ссылка подписки без имени пользователя и фрагмента.",
            "VPN_UNSUPPORTED_PROTOCOL": "Протокол профиля не поддерживается.",
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
    func inspect() throws -> VPNInspection { try inspect(readControllerStatus: true) }

    private func inspect(readControllerStatus: Bool) throws -> VPNInspection {
        _ = try engine.diagnosticIdentity()
        let probe = try engine.text("for c in lua nft iptables ip6tables ebtables dnsmasq ip ubus flock jsonfilter; do command -v \"$c\" >/dev/null 2>&1 || printf 'MISSING:%s\\n' \"$c\"; done; test -c /dev/net/tun || echo MISSING:TUN; test ! -e /data/zte-imei-apps/ssclash/bin/ssclash || echo SSCLASH; test ! -e /data/zte-vpn || echo VPN; test ! -e /data/zte-vpn/controller-upgrade || echo UPGRADE_PENDING; sha256sum /data/zte-vpn/vpnctl 2>/dev/null | awk '{print \"HELPER:\" $1}'; " + Self.helperReadinessCommand)
        let lines = probe.split(separator: "\n").map(String.init)
        var status = VPNStatus()
        if lines.contains("UPGRADE_PENDING") || (!readControllerStatus && lines.contains("VPN")) { status.installed = true }
        else if lines.contains("VPN") { status = try request(["action": "status"]) }
        return VPNInspection(status: status,
            missingCapabilities: lines.filter { $0.hasPrefix("MISSING:") }.map { String($0.dropFirst(8)) },
            ssclashInstalled: lines.contains("SSCLASH"),
            helperReady: lines.contains("HELPER:" + Self.helperHash) && lines.contains("HELPER_LAYOUT_READY") && !lines.contains("UPGRADE_PENDING"))
    }
    func request(_ value: [String: Any], expectedTarget: (Identity, String)? = nil) throws -> VPNStatus {
        let payload = try requestPayload(value, expectedTarget: expectedTarget)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(VPNStatus.self, from: JSONSerialization.data(withJSONObject: payload))
        try require(status.schemaVersion == 1 && status.profiles.count <= 1024, "Неизвестный формат состояния VPN")
        return status
    }
    func subscriptionURL(_ id: String) throws -> String {
        try VPNOperation.updateSubscription(id).validate()
        let target = try engine.diagnosticIdentity()
        let payload = try requestPayload(["action": "subscription_details", "id": id], expectedTarget: target)
        let current = try engine.diagnosticIdentity()
        try require(current.0 == target.0 && current.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
        guard let subscription = payload["subscription"] as? [String: Any], subscription["id"] as? String == id, let url = subscription["url"] as? String else { throw VPNRequestFailure.invalidResponse }
        _ = try VPNSubscriptionDownload.validatedURL(url)
        return url
    }
    func ikev2Profile(_ id: String) throws -> VPNIKEv2Profile {
        try VPNOperation.activate(id).validate()
        let target = try engine.diagnosticIdentity()
        let payload = try requestPayload(["action": "details", "id": id], expectedTarget: target)
        let current = try engine.diagnosticIdentity()
        try require(current.0 == target.0 && current.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
        guard let profile = payload["profile"] as? [String: Any], profile["id"] as? String == id, profile["protocol"] as? String == "ikev2",
              let name = profile["name"] as? String, let proxy = profile["proxy"] as? [String: Any], proxy["password"] == nil,
              let server = proxy["server"] as? String, let serverID = proxy["server_id"] as? String, let username = proxy["username"] as? String,
              let ca = proxy["ca_certificate"] as? String, let dns = proxy["dns"] as? String else { throw VPNRequestFailure.invalidResponse }
        let configuration = VPNIKEv2Configuration(server: server, serverID: serverID, username: username, caCertificate: ca, dns: dns)
        try configuration.validate(editing: true)
        return VPNIKEv2Profile(id: id, name: name, configuration: configuration)
    }
    private func requestPayload(_ value: [String: Any], expectedTarget: (Identity, String)? = nil) throws -> [String: Any] {
        let current = try engine.diagnosticIdentity()
        if let expectedTarget { try require(current.0 == expectedTarget.0 && current.1 == expectedTarget.1, "Модем изменился или перезагрузился. Проверьте подключение заново.") }
        let data = try JSONSerialization.data(withJSONObject: value)
        try require(data.count <= 32 * 1024 * 1024, "Запрос VPN превышает 32 МиБ.")
        if value["action"] as? String == "save_ikev2" { try require(data.count <= 256 * 1024, Self.message("VPN_REQUEST_TOO_LARGE")) }
        let accepted = value["action"] as? String == "status" ? Self.supportedStatusHashes.sorted().joined(separator: "|") : Self.helperHash
        let targetGuard = expectedTarget.map { target in
            "test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(target.0.cid) + "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(target.1) + "; "
        } ?? ""
        let command = "set -eu; " + targetGuard +
            "test -d /data/zte-vpn && test ! -L /data/zte-vpn && test \"$(stat -c '%u:%a' /data/zte-vpn)\" = 0:700 && test ! -L /data/zte-vpn/vpnctl || { printf 'VPN_REQUEST_GUARD unsafe_layout\\n' >&2; exit 78; }; " +
            "case \"$(sha256sum /data/zte-vpn/vpnctl | cut -d ' ' -f1)\" in " + accepted +
            ") ;; *) printf 'VPN_REQUEST_GUARD controller_hash\\n' >&2; exit 78;; esac; exec /data/zte-vpn/vpnctl request"
        let result = try engine.transport.run(command, input: data, timeout: 240)
        try require(result.stdout.count <= 2 * 1024 * 1024, "Ответ VPN превышает 2 МиБ.")
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
        guard reply["ok"] as? Bool == true, let payload = reply["data"] as? [String: Any] else {
            throw IMEIError.message(Self.message(reply["code"] as? String ?? "VPN_OPERATION_FAILED"))
        }
        return payload
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
        let target = try engine.diagnosticIdentity()
        try engine.acquireRemoteLock()
        let before = try inspect()
        try require(before.status.installed && before.helperReady && before.status.settingsSupported == true, "Сначала установите или обновите компоненты VPN.")
        try require(!before.status.enabled, Self.message("VPN_WIFI_SETTINGS_ENABLED"))
        try configuration.validate(configured: before.status.configured)
        var requestBody = configuration.request; requestBody["lock_token"] = engine.remoteLockToken
        let after = try request(requestBody, expectedTarget: target)
        let confirmed = try engine.diagnosticIdentity()
        try require(confirmed.0 == target.0 && confirmed.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
        try require(after.installed && after.settingsSupported == true && !after.enabled && after.configured == before.status.configured && after.activeProfile == before.status.activeProfile && after.desiredSsid == configuration.ssid && after.passwordMode == configuration.passwordMode, "Модем не подтвердил сохранение настроек Wi-Fi. Обновите состояние VPN перед повтором.")
        if after.configured {
            try require(after.ssid2G == configuration.ssid && after.ssid5G == configuration.ssid && after.actualSSID == configuration.ssid, "SSID на модеме не совпал с сохранёнными настройками. Обновите состояние VPN.")
        }
        var result = before; result.status = after
        return result
    }

    func install() throws -> VPNInspection {
        // The pinned upgrade script checks old controller hashes and layout.
        // An old status implementation must not block its own explicit upgrade.
        let before = try inspect(readControllerStatus: false)
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
        let names = ["install.sh", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft", "vpnctl", "mihomo"]
        try runInstaller(names: names, prefix: "zte-vpn-install", script: "install.sh", receipt: "VPN_COMPONENTS_INSTALLED")
    }

    private func upgradeController() throws {
        let names = ["upgrade-controller.sh", "vpnctl", "manager.sh", "firewall.sh", "configure.lua", "nft-guard.nft", "dnsmasq.conf", "service.sh", "ikev2.sh", "ikev2-updown.sh", "nft-ikev2-guard.nft"]
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
        if result.status != 0, let refusal = Self.installFailure(result) ?? Self.upgradeFailure(result) { throw IMEIError.message(refusal) }
        try require(result.status == 0 && String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").contains(Substring(receipt)),
                    "Установка компонентов VPN не подтверждена (exit \(result.status)). Подробности — в журнале. При потере связи файлы восстановления сохранены.")
        let confirmed = try engine.diagnosticIdentity()
        try require(confirmed.0 == target.0 && confirmed.1 == target.1, "Модем изменился или перезагрузился. Обновите состояние VPN.")
    }

    static func installFailure(_ result: CommandResult) -> String? {
        guard result.status > 0 && result.status < 255 else { return nil }
        let messages = [
            "INVALID_STAGE": "Не удалось проверить путь временных файлов установки VPN.",
            "PLATFORM": "Для установки VPN нужны root и ARM64.",
            "UNSAFE_STAGE": "Временные файлы VPN не прошли проверку владельца и прав.",
            "ALREADY_PRESENT": "Компоненты или служба VPN уже существуют. Обновите состояние и выполните обновление компонентов.",
            "UNSUPPORTED_FIRMWARE": "Компоненты VPN рассчитаны на исследованные MU5250 CN B31, FLY B28 (B13) и XCBZ HK B04. Соберите данные для адаптации этой прошивки.",
            "RUNTIME_TOOLS": "В прошивке отсутствует одна из необходимых команд VPN: lua, nft, iptables, ip6tables, ebtables, dnsmasq, ip, ubus, sha256sum или flock.",
            "TUN_UNAVAILABLE": "Для VPN недоступно устройство /dev/net/tun.",
            "LUA_MODULES": "Не удалось загрузить модули Lua uci и luci.jsonc, необходимые для настройки VPN.",
            "NO_SPACE": "Для установки VPN требуется не менее 128 МиБ свободного места в /data.",
            "PAYLOAD": "Файлы установки VPN отсутствуют или не прошли проверку контрольной суммы.",
            "WRITE": "Не удалось записать компоненты VPN в /data. Проверьте место и доступность записи.",
            "INTEGRITY": "Записанные компоненты VPN не прошли проверку целостности.",
            "SERVICE": "Не удалось установить службу или автозапуск VPN. Обновите состояние и повторите обновление компонентов."
        ]
        let prefix = "VPN_INSTALL_ERROR "
        let codes = Set(CommandText.decode(result.stderr).split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            let code = String(line.dropFirst(prefix.count))
            return messages[code] == nil ? nil : code
        })
        guard codes.count == 1, let code = codes.first, let message = messages[code] else { return nil }
        return message + " (VPN_INSTALL_" + code + ")"
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
