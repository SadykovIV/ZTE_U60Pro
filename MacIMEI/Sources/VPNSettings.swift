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
    var ssid = "ZTE-VPN"
    var profiles: [VPNProfile] = []
    var activeProfile = ""
    var recoveryPending = false
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
    static let launcherHash = "c35ea5dd20117a71e0824da047ec4aa3b50bda920559a4c0e495806bb0bc73eb"
    static let agentHash = "542072a91b46c9b789c249d195a6dc2cf649416c6b96448855ff710f7b797fda"
    static let dashboardIndexHash = "ef84080162bb31508515bfe6fb2aebd8f6bb7fa7df9eeadef78e7ef54125e800"
    static let helperHash = "28a7435f555cef46d31f5ea5a0efdc30898a293b8893cb98f7865a9044f66c9c"
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
    func request(_ value: [String: Any]) throws -> VPNStatus {
        _ = try engine.identity()
        let data = try JSONSerialization.data(withJSONObject: value)
        try require(data.count <= 65536, "Ссылка профиля слишком длинная")
        let accepted = value["action"] as? String == "status" ? [Self.helperHash, "e2ffd02708220d332bf31f7f1f4c3abe369fbc2af1665af885c1f4375a884ff0", "8f9e82ca45177fc19ffd4d7663764fa44750e05eed86ef83567ed2dec5ce7827", "96a4717fe085a80479675486d23b260c3254084638d195d933d4d9d944b98e88", "48b9af93098b4b1b31754a48707ac066a39977bcc0db0cc438ead64c62322bd4", "572e2e1133cebb690584bda8b5ac047336451bc26c6a5e37522a756b6254fac5", "80f16fafe203d661d6a90686c90a25c61eea38cf9e83e002c1cdffea85d02f23", "3c8a139d9ba6f3372b009e9e0fb5ed9ff27faf1675dcb654f09eedec851661f3"].joined(separator: "|") : Self.helperHash
        let command = "set -eu; test -d /data/zte-vpn; test ! -L /data/zte-vpn; test \"$(stat -c '%u:%a' /data/zte-vpn)\" = 0:700; test ! -L /data/zte-vpn/vpnctl; case \"$(sha256sum /data/zte-vpn/vpnctl | cut -d ' ' -f1)\" in " + accepted + ") ;; *) exit 1;; esac; exec /data/zte-vpn/vpnctl request"
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
