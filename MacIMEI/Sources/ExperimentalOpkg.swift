import Foundation

struct ExperimentalOpkgPackage: Identifiable, Equatable, Sendable {
    let name: String, version: String
    var summary: String = ""
    var id: String { name }
}
struct ExperimentalOpkgStatus: Equatable, Sendable {
    var installed: Bool
    var packages: [ExperimentalOpkgPackage]
    var freeKiB: UInt64
    var canRollback: Bool
    var generation: String?
    var previous: String?
    var running: Bool
}
struct ExperimentalOpkgFeeds: Equatable, Sendable {
    let text: String
    let generation: String
    let release: String
    let architecture: String
    let keyFingerprints: [String]
}
struct ExperimentalOpkgResult: Sendable {
    var output: String
    var status: ExperimentalOpkgStatus
}

/// Real opkg in a private chroot and offline package root. No system package DB.
final class ExperimentalOpkgManager {
    static let remoteRoot = "/data/zte-imei-apps/opkg-private"
    static let helperHash = "8a1659c18eabfd7da8f7201d722f674634e10f485b6cea41d2c2a569e628c17b"
    static let runtimeMetadataHash = "1ed406a3644f16bb7937ce11cb395a2520bdeb4eb36090b6d1d9d7753804a74a"
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }
    static let commands = ["update", "list", "search", "info", "install", "remove", "list-installed", "status", "files"]
    static func validate(_ args: [String]) throws {
        guard let command = args.first, commands.contains(command), args.count <= 9 else { throw IMEIError.message("Допустимы update, list, search, info, install, remove, list-installed, status, files") }
        let parameters = Array(args.dropFirst())
        if command == "update" { try require(parameters.isEmpty, "update не принимает параметры") }
        if ["install", "remove", "search", "info"].contains(command) { try require(!parameters.isEmpty, "Укажите имя пакета или шаблон") }
        if command == "files" { try require(parameters.count == 1, "files принимает одно имя пакета") }
        for name in parameters {
            let pattern = ["list", "search", "info", "status", "list-installed"].contains(command)
            try require((1...100).contains(name.utf8.count) && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [43, 46, 95, 45].contains($0) || (pattern && [42,63].contains($0)) } && !name.hasPrefix("-") && !name.contains(".."), "Разрешены только имена пакетов и шаблоны; флаги, URL и shell-команды запрещены")
            if ["install", "remove"].contains(command) { try require(!name.hasPrefix("kmod-") && !name.hasPrefix("luci-") && !["kernel","libc","libpthread","zte-private-musl","busybox","opkg","base-files","procd","netifd","firewall","firewall4"].contains(name), "Системный пакет, ядро или служба не поддерживаются в изолированной среде") }
        }
    }
    static func parse(_ data: Data) throws -> ExperimentalOpkgResult {
        try require(data.count <= 4 * 1024 * 1024, "Слишком большой ответ opkg")
        let text = String(decoding: data, as: UTF8.self), marker = "__ZTE_PRIVATE_OPKG_V1__\n"
        guard let start = text.range(of: marker, options: .backwards) else { throw IMEIError.message("Не получено подтверждённое состояние opkg") }
        let lines = text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
        try require(lines.count >= 8 && lines.last == "" && lines[lines.count - 2] == "__END__", "Неполное состояние opkg")
        var fields: [String:String] = [:], packages: [ExperimentalOpkgPackage] = []
        for line in lines.dropLast(2) {
            if line.hasPrefix("package=") {
                let pair = line.dropFirst(8).split(separator: "\t", omittingEmptySubsequences: false)
                try require((pair.count == 2 || pair.count == 3) && !pair[0].isEmpty && !pair[1].isEmpty && pair[0].utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [43,46,95,45].contains($0) } && pair[1].utf8.allSatisfy { (33...126).contains($0) }, "Неверный пакет в ответе opkg")
                let summary = pair.count == 3 ? String(pair[2].prefix(300)) : ""
                try require(!summary.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), "Неверное описание пакета")
                packages.append(.init(name: String(pair[0]), version: String(pair[1]), summary: summary))
            } else {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                try require(pair.count == 2 && fields[String(pair[0])] == nil, "Повторяющиеся поля состояния opkg")
                fields[String(pair[0])] = String(pair[1])
            }
        }
        try require(Set(fields.keys) == Set(["installed","generation","previous","rollback","free_kib","running"]) && Set(packages.map(\.name)).count == packages.count && packages.count <= 1024, "Некорректный состав состояния opkg")
        for field in ["installed","rollback","running"] { try require(["0","1"].contains(fields[field]!), "Неверные флаги opkg") }
        func generation(_ value: String) -> Bool { value == "none" || value == "unset" || (value.hasPrefix("g-") && UUID(uuidString: String(value.dropFirst(2))) != nil && value.count == 38 && value == value.lowercased()) }
        try require(generation(fields["generation"]!) && generation(fields["previous"]!), "Неверный идентификатор копии opkg")
        guard let free = UInt64(fields["free_kib"]!), fields["free_kib"]!.utf8.allSatisfy({ (48...57).contains($0) }) else { throw IMEIError.message("Неверный размер свободного места opkg") }
        let current = fields["generation"]!, previous = fields["previous"]!
        try require(current != "unset" && (fields["installed"] == "1") == current.hasPrefix("g-") && (fields["installed"] == "1" || packages.isEmpty), "Несогласованное состояние opkg")
        try require((fields["rollback"] == "1") == (previous != "unset") && current != previous, "Несогласованное состояние отката opkg")
        return .init(output: String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), status: .init(installed: fields["installed"] == "1", packages: packages, freeKiB: free, canRollback: fields["rollback"] == "1", generation: current.hasPrefix("g-") ? current : nil, previous: previous.hasPrefix("g-") ? previous : nil, running: fields["running"] == "1"))
    }
    /// Only feed declarations are editable; options, destinations and keys are not.
    static func normalizeFeeds(_ text: String) throws -> String {
        try require(text.utf8.count <= 16384, "Список источников должен быть не больше 16 КиБ")
        let input = text.replacingOccurrences(of: "\r\n", with: "\n")
        try require(!input.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }, "В источниках есть недопустимые управляющие символы")
        var names = Set<String>(), output: [String] = []
        for raw in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            try require(words.count == 3 && words[0] == "src/gz", "Каждая строка: src/gz имя http(s)://адрес; другие настройки opkg здесь не принимаются")
            let name = words[1], address = words[2]
            try require((1...48).contains(name.utf8.count) && name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_-]*$", options: .regularExpression) != nil && names.insert(name).inserted, "Имена источников должны быть уникальны: до 48 букв, цифр, _ или -")
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/._~%+[]=-".utf8)
            try require((1...1024).contains(address.utf8.count) && address.utf8.allSatisfy { allowed.contains($0) } && address.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil, "Недопустимый адрес источника: используйте HTTP(S) без параметров, пароля и shell-символов")
            guard let url = URLComponents(string: address), ["http", "https"].contains(url.scheme ?? ""), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw IMEIError.message("Источник должен иметь адрес http:// или https:// без учётных данных, query и fragment") }
            try require(url.port == nil || (1...65535).contains(url.port!), "Порт источника должен быть от 1 до 65535")
            let authority = address.components(separatedBy: "://")[1].split(separator: "/", omittingEmptySubsequences: false)[0]
            try require(authority.range(of: "^(?:[A-Za-z0-9][A-Za-z0-9.-]*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]{1,5})?$", options: .regularExpression) != nil, "Неверный host или port источника")
            output.append("src/gz " + name + " " + address)
        }
        try require(output.count <= 16, "Допускается до 16 источников")
        return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
    }
    static func parseFeeds(_ result: ExperimentalOpkgResult) throws -> ExperimentalOpkgFeeds {
        let lines = result.output.components(separatedBy: "\n")
        try require(lines.count >= 5 && lines.first == "__ZTE_OPKG_FEEDS_V1__" && lines.last == "__END_FEEDS__", "Неполное описание источников opkg")
        var fields: [String:String] = [:], keys: [String] = [], sources: [String] = []
        for line in lines.dropFirst().dropLast() {
            if line.hasPrefix("source=") { sources.append(String(line.dropFirst(7)));continue }
            if line.hasPrefix("key=") {
                let key = String(line.dropFirst(4))
                try require(key.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil && !keys.contains(key), "Неверный ключ источников opkg")
                keys.append(key);continue
            }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            try require(pair.count == 2 && fields[String(pair[0])] == nil, "Неверные поля источников opkg")
            fields[String(pair[0])] = String(pair[1])
        }
        try require(Set(fields.keys) == ["release", "architecture", "generation"] && fields["release"] == "23.05.4" && fields["architecture"] == "aarch64_cortex-a53" && !keys.isEmpty && keys.count <= 32 && result.status.installed && fields["generation"] == result.status.generation, "Состояние источников изменилось или не соответствует поддерживаемой платформе; загрузите его снова")
        return .init(text: try normalizeFeeds(sources.joined(separator: "\n")), generation: fields["generation"]!, release: fields["release"]!, architecture: fields["architecture"]!, keyFingerprints: keys)
    }
    static func failureMessage(_ message: String) -> String {
        let prefix = "OPKG_ERROR CAPABILITY_"
        if let range = message.range(of: prefix) {
            let name = message[range.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            if !name.isEmpty && name.count <= 40 { return "На модеме недоступна штатная команда «\(name)», необходимая для среды opkg. (CAPABILITY_\(name))" }
        }
        for (code, explanation) in [
            ("TIMEOUT_HELPER_FILE", "Не удалось проверить встроенный инструмент ограничения времени на модеме."),
            ("TIMEOUT_HELPER_HASH", "Повреждён переданный инструмент ограничения времени. Операция остановлена."),
            ("RUNNER_TIMEOUT", "Повреждён сохранённый инструмент ограничения времени opkg. Операция остановлена."),
            ("RUNNER_HASH", "Повреждён сохранённый установщик opkg. Операция остановлена."),
            ("CLI_CHANGED", "Приватная команда opkg изменена. Операция остановлена, данные пакетов сохранены."),
            ("FEEDS_STALE", "Среда opkg изменилась после открытия редактора. Загрузите источники снова."),
            ("FEEDS_FORMAT", "Неверный формат источников: допустимы уникальные строки src/gz имя http(s)://адрес."),
            ("FEEDS_HASH", "Содержимое переданного списка источников не прошло проверку целостности."),
            ("FEED_INDEX_UNVERIFIED", "Не получен подписанный индекс одного из источников. Выполните update; проверьте URL, доступность Packages.gz/Packages.sig и доверенный ключ."),
            ("FEED_SIGNATURE", "Подпись источника не подтверждена установленным доверенным ключом. Пользовательские ключи здесь пока не импортируются; проверка подписей не отключается."),
            ("NO_FEEDS", "Источники opkg не настроены. Добавьте источник и выполните update.")
        ] where message.contains("OPKG_ERROR " + code) { return explanation + " (" + code + ")" }
        return OpkgConsoleCommand.failureMessage(message)
    }
    func loadFeeds() throws -> ExperimentalOpkgFeeds { try Self.parseFeeds(perform("read-feeds")) }
    func saveFeeds(_ text: String, expectedGeneration: String) throws -> ExperimentalOpkgResult {
        try require(expectedGeneration.hasPrefix("g-") && expectedGeneration.count == 38 && expectedGeneration == expectedGeneration.lowercased() && UUID(uuidString: String(expectedGeneration.dropFirst(2))) != nil, "Загрузите текущее состояние источников перед сохранением")
        let normalized = try Self.normalizeFeeds(text)
        return try perform("save-feeds", [expectedGeneration], payload: Data(normalized.utf8))
    }
    func inspect() throws -> ExperimentalOpkgStatus { try perform("inspect").status }
    func installAdapter() throws -> ExperimentalOpkgResult { try perform("install-adapter") }
    func removeAdapter() throws -> ExperimentalOpkgResult { try perform("remove-adapter") }
    func rollback() throws -> ExperimentalOpkgResult { try perform("rollback") }
    func execute(_ arguments: [String]) throws -> ExperimentalOpkgResult { try Self.validate(arguments); return try perform("execute", arguments) }
    private func perform(_ action: String, _ arguments: [String] = [], payload: Data? = nil) throws -> ExperimentalOpkgResult {
        try require(engine.lockFD >= 0, "Операция opkg требует блокировки")
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] { try require(!engine.fm.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI") }
        try require(!SystemBackups.hasPendingRestore(root: engine.root), "Сначала завершите полное восстановление")
        let identity = try engine.identity()
        try require(identity.0.firmwareHash == ModemEngine.firmwareHash, "Экспериментальный opkg предназначен только для проверенной MU5250 B31")
        let readOnly = ["inspect", "read-feeds"].contains(action)
        if !readOnly { try engine.acquireRemoteLock() }
        let resources = engine.resources.appendingPathComponent("ExperimentalOpkg")
        let helper = try DeviceBackups.smallFile(resources.appendingPathComponent("manager.sh"), maximum: 131072, publicResource: true)
        try require(digest(helper) == Self.helperHash, "Повреждён адаптер opkg")
        let stage = "/tmp/zte-opkg-" + UUID().uuidString.lowercased()
        _ = try engine.remote("set -eu; umask 077; test ! -L /tmp; mkdir " + shellQuote(stage))
        defer { _ = try? engine.remote("test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) + " && rm -f " + shellQuote(stage + "/manager.sh") + " " + shellQuote(stage + "/runtime.tar.gz") + " " + shellQuote(stage + "/zte-timeout") + " " + shellQuote(stage + "/feeds.txt") + " && rmdir " + shellQuote(stage), timeout: 15) }
        func upload(_ data: Data, _ name: String, _ hash: String) throws {
            let path = stage + "/" + name
            let raw = try engine.remote("set -eu; umask 077; set -C; cat > " + shellQuote(path) + "; sha256sum " + shellQuote(path), input: data, timeout: 120)
            let pieces = String(decoding: raw, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            try require(pieces.count == 2 && pieces[0] == Substring(hash) && pieces[1] == Substring(path), "Не совпала SHA256 переданного адаптера opkg")
        }
        try upload(helper, "manager.sh", Self.helperHash)
        if !readOnly { try ModemHostTools.stageTimeout(engine: engine, stage: stage) }
        var call = [action, identity.0.cid, identity.1]
        if action == "install-adapter" {
            let metadata = try DeviceBackups.smallFile(resources.appendingPathComponent("runtime.json"), maximum: 16384, publicResource: true)
            try require(digest(metadata) == Self.runtimeMetadataHash, "Повреждён каталог runtime opkg")
            struct Runtime: Decodable { let sha256: String; let bytes: Int; let manifestSHA256: String }
            let info = try JSONDecoder().decode(Runtime.self, from: metadata)
            let archive = try DeviceBackups.smallFile(resources.appendingPathComponent("runtime.tar.gz"), maximum: 8 * 1024 * 1024, publicResource: true)
            try require(archive.count == info.bytes && digest(archive) == info.sha256 && DeviceBackups.validHash(info.manifestSHA256), "Повреждён runtime opkg")
            try upload(archive, "runtime.tar.gz", info.sha256)
            call += [stage, info.sha256, info.manifestSHA256]
        } else if action == "save-feeds", let payload {
            try upload(payload, "feeds.txt", digest(payload))
            call += [stage, digest(payload)] + arguments
        } else { call += arguments }
        let script = stage + "/manager.sh"
        let command = "set -eu; test ! -L " + shellQuote(script) + "; test \"$(sha256sum " + shellQuote(script) + " | cut -d ' ' -f1)\" = " + shellQuote(Self.helperHash) + "; sh " + shellQuote(script) + " " + call.map(shellQuote).joined(separator: " ")
        let response: Data
        do { response = try engine.remote(command, timeout: readOnly ? 60 : 600) }
        catch { throw IMEIError.message(Self.failureMessage(error.localizedDescription)) }
        let result = try Self.parse(response)
        try require(try engine.identity() == identity, "Модем или загрузка изменились во время операции opkg; обновите состояние")
        return result
    }
}
