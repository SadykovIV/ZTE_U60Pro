import Foundation

struct DiagnosticTool: Identifiable, Sendable {
    let id: String, name: String, purpose: String
    static let catalog: [DiagnosticTool] = [
        .init(id: "htop", name: "htop", purpose: "Процессы, загрузка CPU и использование памяти."),
        .init(id: "iperf3", name: "iperf3", purpose: "Измерение скорости до выбранного вами сервера."),
        .init(id: "mtr", name: "mtr", purpose: "Маршрут, задержки и потери пакетов; вариант без JSON."),
        .init(id: "tcpdump", name: "tcpdump", purpose: "Захват пакетов для диагностики по вашей команде.")
    ]
    static var ids: Set<String> { Set(catalog.map(\.id)) }
    static func selectionText(_ selected: Set<String>) -> String {
        let names = catalog.map(\.id).filter { selected.contains($0) }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}
struct DiagnosticToolsBundle: Decodable, Sendable {
    let schema: Int, id: String, archiveSHA256: String, archiveBytes: Int, unpackedBytes: Int, fileCount: Int
    let versions: [String: String], programs: [String: String]
    func version(_ tool: String) -> String { versions[tool == "mtr" ? "mtr-nojson" : tool] ?? "—" }
}
struct DiagnosticToolsStatus: Equatable, Sendable {
    var active: String?
    var previous: String?
    var canRollback: Bool
    var running: Bool
    var freeKiB: UInt64
    var selected: Set<String>
    var previousSelected: Set<String>
    var installed: Bool { active != nil && !selected.isEmpty }
    func isInstalled(_ toolID: String) -> Bool { active != nil && selected.contains(toolID) }
    init(active: String?, previous: String?, canRollback: Bool, running: Bool, freeKiB: UInt64,
         selected: Set<String>? = nil, previousSelected: Set<String>? = nil) {
        self.active = active; self.previous = previous; self.canRollback = canRollback
        self.running = running; self.freeKiB = freeKiB
        self.selected = selected ?? (active == nil ? [] : DiagnosticTool.ids)
        self.previousSelected = previousSelected ?? (previous == nil ? [] : DiagnosticTool.ids)
    }
}
struct DiagnosticToolsPlan: Sendable {
    let identity: Identity, bootID: String, before: DiagnosticToolsStatus, bundleID: String
    let toolID: String?
    var selected: Set<String> { toolID.map { before.selected.union([$0]) } ?? DiagnosticTool.ids }
    init(identity: Identity, bootID: String, before: DiagnosticToolsStatus, bundleID: String, toolID: String? = nil) {
        self.identity = identity; self.bootID = bootID; self.before = before; self.bundleID = bundleID; self.toolID = toolID
    }
}

/// A single, pinned, isolated tool set. No opkg operations or system library replacement.
final class DiagnosticToolsManager {
    static let remoteRoot = "/data/zte-imei-apps/diagnostics"
    static let bundleMetadataHash = "eca4ce7778bf5d14a0e9000850c32e620a7b4f286a7764b5acbd8507cdcd0426"
    static let helperHash = "257806f52e9d53beee33d58b991e47e8b1379536d34815efd5836ae713484eb1"
    let engine: ModemEngine
    init(engine: ModemEngine) { self.engine = engine }

    static func bundle(resources: URL, verifyArchive: Bool = false) throws -> DiagnosticToolsBundle {
        let directory = resources.appendingPathComponent("DiagnosticTools")
        let metadata = try DeviceBackups.smallFile(directory.appendingPathComponent("bundle.json"), maximum: 32768, publicResource: true)
        try require(digest(metadata) == bundleMetadataHash, "Повреждён каталог диагностических утилит")
        let value = try JSONDecoder().decode(DiagnosticToolsBundle.self, from: metadata)
        try require(value.schema == 1 && DeviceBackups.validHash(value.id) && DeviceBackups.validHash(value.archiveSHA256)
                    && (1...8_388_608).contains(value.archiveBytes) && (1...33_554_432).contains(value.unpackedBytes)
                    && (5...500).contains(value.fileCount), "Некорректные параметры диагностического набора")
        try require(Set(value.programs.keys) == Set(["htop", "iperf3", "mtr", "tcpdump", "mtr-packet"]), "Неверный состав диагностического набора")
        if verifyArchive {
            let data = try DeviceBackups.smallFile(directory.appendingPathComponent("bundle.tar.gz"), maximum: 8_388_608, publicResource: true)
            try require(data.count == value.archiveBytes && digest(data) == value.archiveSHA256, "Повреждён архив диагностических утилит")
        }
        return value
    }
    static func parse(_ data: Data) throws -> DiagnosticToolsStatus {
        try require(data.count <= 4096, "Слишком большой ответ проверки приложений")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let legacy = lines.first == "ZTE_DIAG_TOOLS_V1"
        try require((legacy ? lines.count == 6 : lines.count == 8 && lines.first == "ZTE_DIAG_TOOLS_V2") && lines.last == "", "Неполный ответ проверки диагностического набора")
        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast() {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            try require(pair.count == 2 && fields[String(pair[0])] == nil, "Некорректные поля проверки приложений")
            fields[String(pair[0])] = String(pair[1])
        }
        let keys = Set(["active", "previous", "running", "free_kib"] + (legacy ? [] : ["selected", "previous_selected"]))
        try require(Set(fields.keys) == keys, "Неизвестный формат состояния диагностического набора")
        let active = fields["active"]!, previous = fields["previous"]!
        try require(active == "none" || DeviceBackups.validHash(active), "Неверная активная версия утилит")
        try require(["none", "unset"].contains(previous) || DeviceBackups.validHash(previous), "Неверная версия отката утилит")
        try require(["0", "1"].contains(fields["running"]!) && fields["free_kib"]!.allSatisfy(\.isNumber)
                    && fields["free_kib"]!.utf8.allSatisfy({ (48...57).contains($0) }), "Неверные флаги диагностического набора")
        guard let free = UInt64(fields["free_kib"]!) else { throw IMEIError.message("Некорректный размер свободного места") }
        func selection(_ text: String) throws -> Set<String> {
            if text == "none" { return [] }
            let selected = Set(text.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
            try require(!selected.isEmpty && selected.isSubset(of: DiagnosticTool.ids) && DiagnosticTool.selectionText(selected) == text,
                        "Неверный список установленных приложений")
            return selected
        }
        let selected = try legacy ? (active == "none" ? [] : DiagnosticTool.ids) : selection(fields["selected"]!)
        let previousSelected = try legacy ? (["none", "unset"].contains(previous) ? [] : DiagnosticTool.ids)
            : (fields["previous_selected"] == "unset" ? [] : selection(fields["previous_selected"]!))
        try require((active == "none") == selected.isEmpty && (["none", "unset"].contains(previous)) == previousSelected.isEmpty,
                    "Версия и состав установленных приложений не совпадают")
        if !legacy { try require((previous == "unset") == (fields["previous_selected"] == "unset"), "Неверный состав состояния отката") }
        return .init(active: active == "none" ? nil : active, previous: ["none", "unset"].contains(previous) ? nil : previous,
                     canRollback: previous != "unset", running: fields["running"] == "1", freeKiB: free,
                     selected: selected, previousSelected: previousSelected)
    }
    private func guardOperation(mutation: Bool) throws -> (Identity, String) {
        try require(engine.lockFD >= 0, "Проверка приложений требует блокировки операции")
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!engine.fm.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI")
        }
        try require(!SystemBackups.hasPendingRestore(root: engine.root), "Сначала завершите восстановление модема")
        let value = try engine.identity()
        if mutation { try engine.acquireRemoteLock() }
        return value
    }
    private func staged<T>(requiresTimeout: Bool = false, _ work: (String) throws -> T) throws -> T {
        let script = try DeviceBackups.smallFile(engine.resources.appendingPathComponent("DiagnosticTools/manager.sh"), maximum: 131072, publicResource: true)
        try require(digest(script) == Self.helperHash, "Повреждён установщик диагностических утилит")
        let stage = "/tmp/zte-diag-" + UUID().uuidString.lowercased(), file = "/manager.sh"
        _ = try engine.remote("set -eu; umask 077; test ! -L /tmp; mkdir " + shellQuote(stage) + "; test \"$(stat -c %u " + shellQuote(stage) + ")\" = 0; test \"$(stat -c %a " + shellQuote(stage) + ")\" = 700")
        defer {
            // Delete only this invocation's known temporary files, never a tree.
            _ = try? engine.remote("test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) + " && test \"$(stat -c %u " + shellQuote(stage) + ")\" = 0 && rm -f " + shellQuote(stage + file) + " " + shellQuote(stage + "/zte-timeout") + " " + shellQuote(stage + "/bundle.tar.gz") + " " + shellQuote(stage + "/bundle.tar") + " " + shellQuote(stage + "/archive.files") + " && rmdir " + shellQuote(stage), timeout: 15)
        }
        try upload(script, path: stage + file, expected: Self.helperHash)
        if requiresTimeout { try ModemHostTools.stageTimeout(engine: engine, stage: stage) }
        return try work(stage)
    }
    private func upload(_ data: Data, path: String, expected: String) throws {
        let result = try engine.remote("set -eu; umask 077; set -C; cat > " + shellQuote(path) + "; chmod 600 " + shellQuote(path) + "; sha256sum " + shellQuote(path), input: data, timeout: 120)
        let fields = String(decoding: result, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(fields.count == 2 && fields[0] == Substring(expected) && fields[1] == Substring(path), "Переданный файл диагностических утилит повреждён")
    }
    private func run(_ stage: String, _ args: [String], timeout: TimeInterval = 60) throws -> DiagnosticToolsStatus {
        let file = stage + "/manager.sh"
        let command = "set -eu; test -f " + shellQuote(file) + "; test ! -L " + shellQuote(file) + "; test \"$(sha256sum " + shellQuote(file) + " | cut -d ' ' -f1)\" = " + shellQuote(Self.helperHash) + "; sh " + shellQuote(file) + " " + args.map(shellQuote).joined(separator: " ")
        do { return try Self.parse(engine.remote(command, timeout: timeout)) }
        catch {
            let text = ActivityJournal.redact(error.localizedDescription)
            if let detail = Self.capabilityExplanation(text) { throw IMEIError.message(detail) }
            let explanations = [
                "UNSUPPORTED_PLATFORM": "Нужна проверенная OpenWrt 23.05.4 для ARM64 Cortex-A53.",
                "DATA_NOT_EXECUTABLE": "Раздел /data должен разрешать запись и запуск файлов; приложение не меняет его режим.",
                "CAPABILITY": "На модеме недоступна одна из необходимых штатных команд.",
                "SUPERVISOR_PATH": "Неверный временный каталог средства ограничения времени запуска.",
                "SUPERVISOR_FILE": "Средство ограничения времени запуска не передано или недоступно для выполнения.",
                "SUPERVISOR_HASH": "Повреждено средство ограничения времени запуска. Установка остановлена.",
                "FREE_SPACE": "Для установки требуется минимум 32 МиБ свободного места на /data.",
                "TOOLS_RUNNING": "Завершите работающие диагностические утилиты перед изменением набора.",
                "DEVICE_CHANGED": "Модем или его загрузка изменились. Повторно подключитесь и проверьте набор.",
                "SELF_TEST": "Утилиты не прошли проверку запуска. Действующий набор не переключён.",
                "CONTENT_HASH": "Файлы сохранённого набора изменены. Автоматическая перезапись остановлена.",
                "MANIFEST_HASH": "Контрольный список набора изменён. Автоматическая перезапись остановлена.",
                "BUSY": "Другая операция с диагностическим набором ещё выполняется.",
                "SHARED_VERSION_CONFLICT": "Индивидуальная установка изменила бы общую версию других приложений. Их автоматическое обновление остановлено.",
                "UNKNOWN_OWNER": "Каталог приложений создан или изменён вне программы. Он не перезаписывается."
            ]
            if let match = explanations.first(where: { text.contains("DIAG_ERROR " + $0.key) }) {
                throw IMEIError.message(match.value + " (" + match.key + ")")
            }
            throw error
        }
    }
    static func capabilityExplanation(_ text: String) -> String? {
        let prefix = "DIAG_ERROR CAPABILITY_"
        guard let match = text.range(of: prefix + "[a-z0-9_]+", options: .regularExpression) else { return nil }
        let utility = text[match].dropFirst(prefix.count)
        return "На модеме недоступна штатная команда «\(utility)». (CAPABILITY_\(utility))"
    }
    func inspect() throws -> DiagnosticToolsStatus {
        let identity = try guardOperation(mutation: false)
        return try staged { stage in
            let status = try run(stage, ["inspect"])
            try require(try engine.identity() == identity, "Устройство или загрузка изменились во время проверки приложений")
            return status
        }
    }
    func prepare(toolID: String? = nil) throws -> DiagnosticToolsPlan {
        if let toolID { try require(DiagnosticTool.ids.contains(toolID), "Неизвестное диагностическое приложение") }
        let bundle = try Self.bundle(resources: engine.resources, verifyArchive: true)
        let identity = try guardOperation(mutation: false)
        let status = try inspect()
        try require(!status.running, "Сначала завершите запущенные утилиты; приложение не останавливает их принудительно")
        try require(status.freeKiB >= 32 * 1024, "Для установки требуется не менее 32 МиБ на /data")
        if let toolID, let active = status.active, active != bundle.id {
            try require(status.selected.subtracting([toolID]).isEmpty, "Индивидуальная установка изменила бы общую версию других приложений. Автоматическое обновление остановлено.")
        }
        try require(try engine.identity() == identity, "Модем изменился во время подготовки установки")
        return .init(identity: identity.0, bootID: identity.1, before: status, bundleID: bundle.id, toolID: toolID)
    }
    func install(_ plan: DiagnosticToolsPlan) throws -> DiagnosticToolsStatus {
        if let toolID = plan.toolID { try require(DiagnosticTool.ids.contains(toolID), "Неизвестное диагностическое приложение") }
        let bundle = try Self.bundle(resources: engine.resources, verifyArchive: true)
        try require(bundle.id == plan.bundleID, "Набор изменился после проверки; повторите проверку")
        let identity = try guardOperation(mutation: true)
        try require(identity.0 == plan.identity && identity.1 == plan.bootID, "Устройство или загрузка изменились после проверки")
        return try staged(requiresTimeout: true) { stage in
            let before = try run(stage, ["inspect"])
            try require(before.active == plan.before.active && before.previous == plan.before.previous && before.canRollback == plan.before.canRollback && before.selected == plan.before.selected && before.previousSelected == plan.before.previousSelected && !before.running,
                        "Состав набора изменился после проверки; повторите проверку")
            let data = try DeviceBackups.smallFile(engine.resources.appendingPathComponent("DiagnosticTools/bundle.tar.gz"), maximum: 8_388_608, publicResource: true)
            try require(digest(data) == bundle.archiveSHA256, "Архив изменился во время установки")
            try upload(data, path: stage + "/bundle.tar.gz", expected: bundle.archiveSHA256)
            let result = try run(stage, ["install", stage, bundle.id, bundle.archiveSHA256, plan.toolID ?? "all", identity.0.cid, identity.1], timeout: 180)
            let changed = before.active != bundle.id || before.selected != plan.selected
            try require(try engine.identity() == identity && result.active == bundle.id && result.selected == plan.selected &&
                        result.previous == (changed ? before.active : before.previous) &&
                        result.previousSelected == (changed ? before.selected : before.previousSelected) &&
                        result.canRollback == (changed || before.canRollback),
                        "Установка не подтвердила выбранное приложение и состояние отката на том же модеме")
            engine.update("Приложение проверено и установлено. Предыдущее состояние сохранено для отката.", 1)
            return result
        }
    }
    func change(_ action: String, toolID: String? = nil) throws -> DiagnosticToolsStatus {
        try require(["remove", "rollback"].contains(action), "Неизвестная операция с диагностическим набором")
        if let toolID { try require(action == "remove" && DiagnosticTool.ids.contains(toolID), "Неизвестное диагностическое приложение") }
        let identity = try guardOperation(mutation: true)
        return try staged(requiresTimeout: action == "rollback") { stage in
            let before = try run(stage, ["inspect"])
            try require(!before.running, "Сначала завершите работающие утилиты")
            try require(action == "remove" ? before.installed : before.canRollback, "Для этой операции нет сохранённого состояния")
            if let toolID { try require(before.isInstalled(toolID), "Приложение не установлено") }
            let args = action == "remove" ? [action, toolID ?? "all", identity.0.cid, identity.1] : [action, identity.0.cid, identity.1]
            let result = try run(stage, args, timeout: 180)
            try require(try engine.identity() == identity, "Устройство изменилось во время изменения набора")
            let selected = action == "remove" ? (toolID.map { before.selected.subtracting([$0]) } ?? []) : before.previousSelected
            let active = action == "remove" ? (selected.isEmpty ? nil : before.active) : before.previous
            try require(result.active == active && result.selected == selected && result.previous == before.active && result.previousSelected == before.selected && result.canRollback,
                        "Новое состояние приложений не подтверждено")
            return result
        }
    }
}
