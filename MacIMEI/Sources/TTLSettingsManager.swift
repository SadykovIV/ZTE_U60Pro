import Foundation

/// Uses only the application's own IPv4 rules and persistence hooks.
/// The caller holds ModemEngine.locked; changing settings also takes the device lock.
final class TTLSettingsManager {
    static let remoteRoot = "/data/zte-imei-ttl"
    // Updated from reviewed resources before each release.
    static let resourceHashes: [String: String] = [
        "manager.sh": "b6588072c82ddd7678093a29b983ec4417c6807562819e3bda69cd6534637b7c",
        "firewall.sh": "7610ef7955d21dd21532ce7149a57418daedd7dfcac1887350eb3223ba943600",
        "hotplug.sh": "5943e73d5f09a19b920f0ca3687a4f4a3215f9bd972d619af3a0b7d780dee30a",
        "boot.sh": "d13e69f8b9471ac6ab11fbace62cac1d5b64a16770c02d728bbebae3bd898040"
    ]
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }

    private func assets() throws -> [String: Data] {
        let names = Set(["manager.sh", "firewall.sh", "hotplug.sh", "boot.sh"])
        try require(Set(Self.resourceHashes.keys) == names, "Неполный встроенный комплект настройки TTL")
        var result = [String: Data]()
        for name in names.sorted() {
            let bytes = try Data(contentsOf: engine.resources.appendingPathComponent("TTL/" + name))
            try require(digest(bytes) == Self.resourceHashes[name], "Повреждён встроенный файл настройки TTL: " + name)
            result[name] = bytes
        }
        return result
    }

    static func managerCommand(arguments: [String], hash: String) -> String {
        let manager = remoteRoot + "/manager.sh"
        return "set -eu; " +
            "for dir in /data " + remoteRoot + "; do test -d \"$dir\"; test ! -L \"$dir\"; test \"$(stat -c '%u' \"$dir\")\" = 0; mode=$(stat -c '%a' \"$dir\"); test \"$((0$mode & 022))\" = 0; done; " +
            "test -f " + manager + "; test ! -L " + manager + "; test \"$(stat -c '%u' " + manager + ")\" = 0; " +
            "mode=$(stat -c '%a' " + manager + "); test \"$((0$mode & 022))\" = 0; " +
            "test \"$(sha256sum " + manager + " | cut -d ' ' -f1)\" = " + shellQuote(hash) + "; " +
            "sh " + manager + " " + arguments.map(shellQuote).joined(separator: " ")
    }

    private func invoke(_ command: String, timeout: TimeInterval = 90) throws -> TTLStatus {
        let response = try engine.transport.run(command, input: nil, timeout: timeout)
        try savePrivate(response.stdout + response.stderr, engine.logDirectory.appendingPathComponent("ttl-" + UUID().uuidString + ".log"))
        let reason = String(decoding: response.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(response.status == 0, "Настройка TTL остановлена (код \(response.status)). " + String(reason.prefix(500)) + " Нажмите «Проверить», чтобы прочитать текущее состояние.")
        var result = try TTLSettings.parseStatus(String(decoding: response.stdout, as: UTF8.self))
        if result.state == .error { result.detail = reason.isEmpty ? "Сохранённые настройки и активные правила различаются." : String(reason.prefix(500)) }
        return result
    }

    func perform(configuration: TTLConfiguration?) throws -> TTLStatus {
        try engine.connection.validate()
        try configuration?.validate()
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI")
        }
        let bundle = try assets()
        let identity = try engine.identity().0
        if configuration != nil { try engine.acquireRemoteLock() }
        let installed = try engine.text("if test -e " + Self.remoteRoot + " || test -L " + Self.remoteRoot + "; then printf installed; else printf absent; fi")
        let hash = Self.resourceHashes["manager.sh"]!
        if installed == "installed" {
            let arguments: [String]
            if let configuration {
                arguments = configuration.isDisabled ? ["disable", identity.cid] :
                    ["apply", identity.cid, configuration.outbound.map(String.init) ?? "off", configuration.inboundIncrement.map(String.init) ?? "off"]
                try require(try engine.identity().0 == identity, "Перед изменением подключён другой модем")
                engine.update("Применяю настройки TTL", 0.6)
            } else {
                arguments = ["status", identity.cid]
                engine.update("Проверяю правила TTL", 0.5)
            }
            let result = try invoke(Self.managerCommand(arguments: arguments, hash: hash))
            try validate(result, requested: configuration)
            return result
        }
        try require(installed == "absent", "Не удалось проверить установку TTL")
        // A staged status command is read-only on the device, so an inspection
        // does not silently install hooks or turn on the initial field values.
        let stage = "/tmp/zte-imei-ttl-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer {
            _ = try? engine.remote("rm -f " + bundle.keys.sorted().map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), timeout: 15)
        }
        for name in bundle.keys.sorted() {
            let path = stage + "/" + name, bytes = bundle[name]!
            let response = try engine.remote("umask 077; cat > " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: bytes)
            let fields = String(decoding: response, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            try require(fields.count == 2 && fields[0] == Substring(digest(bytes)) && fields[1] == Substring(path), "При передаче повреждён файл TTL: " + name)
        }
        try require(try engine.identity().0 == identity, "После передачи подключён другой модем")
        let arguments: [String]
        if let configuration, !configuration.isDisabled {
            engine.update("Сохраняю настройки TTL на модеме", 0.8)
            arguments = ["install", stage, identity.cid, configuration.outbound.map(String.init) ?? "off", configuration.inboundIncrement.map(String.init) ?? "off"]
        } else {
            arguments = ["status", identity.cid]
        }
        let result = try invoke("sh " + shellQuote(stage + "/manager.sh") + " " + arguments.map(shellQuote).joined(separator: " "))
        try validate(result, requested: configuration)
        return result
    }

    private func validate(_ status: TTLStatus, requested: TTLConfiguration?) throws {
        guard let requested else { return }
        try require(status.configuration == requested, "Модем не подтвердил запрошенные значения TTL")
        try require(requested.isDisabled ? status.state == .disabled : status.state == .configured && status.persistence == .boot,
                    "Не удалось подтвердить применение и сохранение TTL")
    }
}
