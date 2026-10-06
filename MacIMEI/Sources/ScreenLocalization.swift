import Foundation

enum ScreenLocalizationState: String, Sendable {
    case absent, enabled, disabled, error
}

struct ScreenLocalizationStatus: Sendable {
    var revision: String = "20260924"
    var state: ScreenLocalizationState
    var language: String
    var detail: String = ""
    var mounted: Int = 0
    var bootEnabled: Bool = false
    var pid: Int = 0

    var title: String {
        switch state {
        case .absent: return "Русификация не установлена"
        case .enabled: return "Русификация включена"
        case .disabled: return "Штатный интерфейс восстановлен"
        case .error: return "Не удалось подтвердить состояние"
        }
    }
    var languageTitle: String {
        switch language {
        case "en": return "English"
        case "cn": return state == .enabled ? "Русский" : "中文"
        default: return "Не определён"
        }
    }
    var summary: String {
        if state == .error { return detail.isEmpty ? "Нажмите «Проверить», чтобы повторить проверку." : detail }
        return title + ". Текущий язык: " + languageTitle + "."
    }
}

enum ScreenLocalizationAction: String, Sendable { case status, enable, disable }

struct ScreenFontPatch: Decodable {
    struct Edit: Decodable {
        var offset: Int
        var originalHex: String
        var replacementHex: String
    }
    var version: Int
    var inputSHA256: String
    var outputSHA256: String
    var inputSize: Int
    var outputSize: Int
    var patches: [Edit]
}

/// Runs inside ModemEngine.locked. Only screen resources, its service and language are changed.
final class ScreenLocalization {
    static let remoteRoot = "/data/zte-imei-screen-ru"
    static let revision = "20260924"
    static let legacyManagerHashes = ["20260922": "6aed6654afb7a4fde7792a5f6034aa41e15b0fd77d794ed04d3a12c111c95fd2", "20260923": "586a7727fb24a5701990c7cd82889887220c1c5566261c53ca21f3bb12549bfa"]
    static let resourceHashes: [String: String] = [
        "install.sh": "810aae3c07c8019f2d0657f2bad6f1ee38f1dea5f1081210ab144478dd87c7b8",
        "service.sh": "8b25166707a21bb3b55f77d9af34822a39aa5e8058b5c521431f0379386051e9",
        "English.ini": "d97925e40f9c119e05dd692e8fbce36593b55aa3faf718af373b2cb57075981a",
        "Chinese.ini": "5c4b6e3896593172608f2d8890da56c7ff521667129375d0a52383243bb760df",
        "font.patch.json": "f171291a83b269e605e70747a7799eae53f35e1e6488db30a41d37dd87146e18"
    ]
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }

    static func parseStatus(_ output: String) throws -> ScreenLocalizationStatus {
        let lines = output.split(whereSeparator: \.isNewline)
        try require(lines.count == 1, "Получен неполный или неоднозначный статус русификации")
        let fields = lines[0].split(separator: " ")
        try require(fields.first == "SCREEN_RU_STATUS", "Неизвестный формат статуса русификации")
        var values = [String: String]()
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            try require(pair.count == 2 && values[String(pair[0])] == nil, "Повтор или повреждение поля статуса русификации")
            values[String(pair[0])] = String(pair[1])
        }
        let required: Set<String> = ["state", "language", "mounted", "boot", "pid", "revision"]
        try require(Set(values.keys) == required || Set(values.keys) == required.union(["reason"]), "Неполный статус русификации")
        if let reason = values["reason"] { try require(Self.statusReasons[reason] != nil, "Неизвестная причина ошибки русификации") }
        guard let state = ScreenLocalizationState(rawValue: values["state"]!),
              let mounted = Int(values["mounted"]!), (0...3).contains(mounted),
              let pid = Int(values["pid"]!), pid >= 0,
              ["en", "cn", "other"].contains(values["language"]!),
              ["0", "1"].contains(values["boot"]!), ([revision] + Array(legacyManagerHashes.keys)).contains(values["revision"]!) else {
            throw IMEIError.message("Неизвестная версия или значения статуса русификации")
        }
        let boot = values["boot"] == "1"
        try require(state == .error || (state == .enabled ? mounted == 3 && boot : mounted == 0 && !boot), "Несогласованное состояние русификации")
        return ScreenLocalizationStatus(revision: values["revision"]!, state: state, language: values["language"]!,
            detail: state == .error ? Self.statusReasons[values["reason"] ?? "STATUS_UNVERIFIED"]! : "",
            mounted: mounted, bootEnabled: boot, pid: pid)
    }

    static let statusReasons = [
        "STOCK_INIT_MISSING": "Отсутствует штатный скрипт запуска экрана /etc/init.d/zte_topsw_devui.",
        "STOCK_INIT_CHANGED": "Скрипт запуска экрана отличается от совместимого штатного или русифицированного варианта.",
        "LEFTOVER_HOOK_OR_MOUNT": "Каталог русификации отсутствует, но остались её служба или подключённые файлы. Нужно восстановить установку.",
        "BOOT_HOOK_MISSING": "После сброса отсутствует запуск русификации. Повторное включение восстановит его из установленного комплекта.",
        "TRANSACTION_PENDING": "Предыдущее изменение русификации не завершено; журнал сохранён на модеме.",
        "UI_NOT_RUNNING": "Процесс экранного интерфейса не запущен.",
        "STATUS_UNVERIFIED": "Состояние файлов или запуска экрана не подтверждено. Подробности команды сохранены в журнале."
    ]

    static let reasonCommand = #"""
    set -eu
    reason=STATUS_UNVERIFIED
    if test ! -f /etc/init.d/zte_topsw_devui || test -L /etc/init.d/zte_topsw_devui; then reason=STOCK_INIT_MISSING
    elif test -e /data/zte-imei-screen-ru/.transaction; then reason=TRANSACTION_PENDING
    elif test -d /data/zte-imei-screen-ru && test -f /data/zte-imei-screen-ru/.enabled && { test ! -f /etc/init.d/zte_imei_screen_ru || test ! -L /etc/rc.d/S47zte_imei_screen_ru; }; then reason=BOOT_HOOK_MISSING
    elif ! pidof zte_topsw_devui >/dev/null 2>&1; then reason=UI_NOT_RUNNING
    fi
    printf '%s\n' "$reason"
    """#

    static func applyFontPatch(_ original: Data, manifest: ScreenFontPatch) throws -> Data {
        func validHash(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        try require(manifest.version == 1 && validHash(manifest.inputSHA256) && validHash(manifest.outputSHA256), "Неизвестный формат патча шрифта")
        try require(manifest.inputSize > 0 && manifest.inputSize == original.count && manifest.outputSize == original.count,
                    "Размер экранного интерфейса отличается от проверенного")
        try require(digest(original) == manifest.inputSHA256, "SHA-256 исходного экранного интерфейса не совпадает с проверенной B31")
        try require(!manifest.patches.isEmpty && manifest.patches.count <= 1024, "Некорректный список изменений шрифта")
        var result = original, previousEnd = 0
        for edit in manifest.patches {
            let before = try Data(hex: edit.originalHex), after = try Data(hex: edit.replacementHex)
            try require(!before.isEmpty && before.count == after.count && edit.offset >= previousEnd && edit.offset <= original.count && before.count <= original.count - edit.offset,
                        "Патч шрифта содержит пересекающиеся или выходящие за файл изменения")
            let end = edit.offset + before.count
            try require(original.subdata(in: edit.offset..<end) == before, "Исходные байты патча шрифта не совпали")
            result.replaceSubrange(edit.offset..<end, with: after)
            previousEnd = end
        }
        try require(result.count == manifest.outputSize && digest(result) == manifest.outputSHA256, "SHA-256 подготовленного экранного интерфейса не совпадает")
        return result
    }

    private func assets() throws -> [String: Data] {
        let required = Set(["install.sh", "service.sh", "English.ini", "Chinese.ini", "font.patch.json"])
        try require(Set(Self.resourceHashes.keys) == required, "Неполный встроенный комплект русификации")
        var files = [String: Data]()
        for name in required.sorted() {
            let data = try Data(contentsOf: engine.resources.appendingPathComponent("ScreenLocalization/" + name))
            try require(digest(data) == Self.resourceHashes[name], "Повреждён встроенный файл русификации: " + name)
            files[name] = data
        }
        return files
    }

    static let probeCommand = #"""
    set -eu
    if test -e /data/zte-imei-screen-ru || test -L /data/zte-imei-screen-ru; then
        printf 'SCREEN_RU_INSTALLED\n'
    else
        language=$(uci -q get zwrt_deviceui.Device.device_language || true)
        case "$language" in en|cn) ;; *) language=other;; esac
        mounted=$(awk '$5=="/usr/ui/language/English.ini" || $5=="/usr/ui/language/Chinese.ini" || $5=="/usr/bin/zte_topsw_devui" {n++} END {print n+0}' /proc/self/mountinfo)
        state=absent; reason=
        if test "$mounted" != 0 || test -e /etc/init.d/zte_imei_screen_ru || test -L /etc/init.d/zte_imei_screen_ru || test -e /etc/rc.d/S47zte_imei_screen_ru || test -L /etc/rc.d/S47zte_imei_screen_ru; then state=error; reason=LEFTOVER_HOOK_OR_MOUNT; fi
        if test ! -f /etc/init.d/zte_topsw_devui || test -L /etc/init.d/zte_topsw_devui; then state=error; reason=STOCK_INIT_MISSING
        elif test "$(sha256sum /etc/init.d/zte_topsw_devui 2>/dev/null | awk '{print $1}')" != a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35; then state=error; reason=STOCK_INIT_CHANGED; fi
        pid=$(pidof zte_topsw_devui 2>/dev/null | awk '{print $1}' || true)
        case "$pid" in ''|*[!0-9]*) pid=0;; esac
        printf 'SCREEN_RU_STATUS state=%s language=%s mounted=%s boot=0 pid=%s revision=20260924' "$state" "$language" "$mounted" "$pid"
        if test -n "$reason"; then printf ' reason=%s' "$reason"; fi
        printf '\n'
    fi
    """#

    static func managerCommand(_ action: ScreenLocalizationAction, cid: String, hash: String) -> String {
        let manager = remoteRoot + "/manager.sh"
        return "set -eu; " +
            "for dir in /data " + remoteRoot + "; do test -d \"$dir\"; test ! -L \"$dir\"; test \"$(stat -c '%u' \"$dir\")\" = 0; mode=$(stat -c '%a' \"$dir\"); test \"$((0$mode & 022))\" = 0; done; " +
            "test -f " + manager + "; test ! -L " + manager + "; test \"$(stat -c '%u' " + manager + ")\" = 0; " +
            "mode=$(stat -c '%a' " + manager + "); test \"$((0$mode & 022))\" = 0; " +
            "test \"$(sha256sum " + manager + " | cut -d ' ' -f1)\" = " + shellQuote(hash) + "; " +
            "sh " + manager + " " + action.rawValue + " " + shellQuote(cid)
    }

    private func invoke(_ command: String, timeout: TimeInterval = 240) throws -> ScreenLocalizationStatus {
        let response = try engine.transport.run(command, input: nil, timeout: timeout)
        try savePrivate(response.stdout + response.stderr, engine.logDirectory.appendingPathComponent("screen-localization-" + UUID().uuidString + ".log"))
        let reason = String(decoding: response.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(response.status == 0, "Русификация остановлена (код \(response.status)). " + String(reason.prefix(500)) + " Проверка покажет текущее состояние.")
        var result = try Self.parseStatus(String(decoding: response.stdout, as: UTF8.self))
        if result.state == .error && !reason.isEmpty { result.detail = String(reason.prefix(500)) }
        return result
    }

    private func inspect(cid: String, managerHash: String) throws -> ScreenLocalizationStatus {
        let probe = try engine.text(Self.probeCommand)
        if probe == "SCREEN_RU_INSTALLED" {
            let installedHash = try engine.text("sha256sum /data/zte-imei-screen-ru/manager.sh").split(separator: " ").first.map(String.init) ?? ""
            try require(([managerHash] + Array(Self.legacyManagerHashes.values)).contains(installedHash), "Неизвестная версия менеджера русификации")
            var result = try invoke(Self.managerCommand(.status, cid: cid, hash: installedHash), timeout: 30)
            if result.state == .error {
                let reason = try engine.text(Self.reasonCommand)
                result.detail = Self.statusReasons[reason] ?? Self.statusReasons["STATUS_UNVERIFIED"]!
            }
            return result
        }
        return try Self.parseStatus(probe)
    }

    func perform(_ action: ScreenLocalizationAction) throws -> ScreenLocalizationStatus {
        try engine.connection.validate()
        if action == .status {
            let before = try SSHReadProof.parse(engine.remote(SSHReadProof.quickCommand))
            let status = try inspect(cid: "", managerHash: Self.resourceHashes["install.sh"]!)
            try before.verify(SSHReadProof.parse(engine.remote(SSHReadProof.quickCommand)))
            return status
        }
        let bundle = try assets()
        let identity = try engine.identity().0
        if action != .status { try engine.acquireRemoteLock() }
        let managerHash = Self.resourceHashes["install.sh"]!
        let current = try inspect(cid: identity.cid, managerHash: managerHash)
        if action == .status { return current }
        if action == .disable && current.state == .absent { return current }
        if current.state != .absent && (current.revision == Self.revision || action == .disable) {
            try require(try engine.identity().0 == identity, "Перед изменением подключён другой модем")
            engine.update(action == .enable ? "Включаю русский интерфейс модема" : "Возвращаю штатный интерфейс модема", 0.5)
            let result = try invoke(Self.managerCommand(action, cid: identity.cid, hash: current.revision == Self.revision ? managerHash : Self.legacyManagerHashes[current.revision]!))
            try validateResult(result, action: action)
            return result
        }
        engine.update("Читаю исходный экранный интерфейс и проверяю патч шрифта", 0.15)
        let original = try engine.remote(current.state == .absent ? "cat /usr/bin/zte_topsw_devui" : "cat /data/zte-imei-screen-ru/backup/zte_topsw_devui", timeout: 120)
        let manifest = try JSONDecoder().decode(ScreenFontPatch.self, from: bundle["font.patch.json"]!)
        let patched = try Self.applyFontPatch(original, manifest: manifest)
        try require(try engine.identity().0 == identity, "Перед установкой подключён другой модем")
        let stage = "/tmp/zte-screen-ru-install-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        let names = ["install.sh", "service.sh", "English.ini", "Chinese.ini", "font.patch.json", "zte_topsw_devui"]
        defer {
            _ = try? engine.remote("rm -f " + names.map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), timeout: 15)
        }
        var payload = bundle
        payload["zte_topsw_devui"] = patched
        for (index, name) in names.enumerated() {
            let path = shellQuote(stage + "/" + name), data = payload[name]!
            let response = String(decoding: try engine.remote("umask 077; cat > " + path + " && sha256sum " + path, input: data, timeout: 120), as: UTF8.self)
            let hashFields = response.split(whereSeparator: \.isWhitespace)
            try require(hashFields.count == 2 && hashFields[0] == Substring(digest(data)) && hashFields[1] == Substring(stage + "/" + name), "При передаче повреждён файл русификации: " + name)
            engine.update("Передаю проверенные файлы русификации", 0.25 + Double(index + 1) / Double(names.count) * 0.45)
        }
        try require(try engine.identity().0 == identity, "После передачи подключён другой модем")
        engine.update("Устанавливаю русский интерфейс с сохранением после перезагрузки", 0.8)
        let result = try invoke("sh " + shellQuote(stage + "/install.sh") + " install " + shellQuote(stage) + " " + shellQuote(identity.cid))
        try validateResult(result, action: .enable)
        return result
    }

    private func validateResult(_ result: ScreenLocalizationStatus, action: ScreenLocalizationAction) throws {
        let expected: ScreenLocalizationState = action == .enable ? .enabled : .disabled
        try require(result.state == expected && result.pid > 0 && result.language == (action == .enable ? "cn" : "en"),
                    "Интерфейс после изменения не подтвердил ожидаемое состояние. Нажмите «Проверить».")
    }
}
