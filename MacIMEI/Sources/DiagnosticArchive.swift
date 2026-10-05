import Foundation
import Darwin

struct DiagnosticArchiveResult: Sendable {
    let url: URL
    let fileCount: Int
    let warnings: Int
    let sha256: String
}

/// An allowlist snapshot, never a ZIP of Application Support (which holds keys and backups).
struct DiagnosticArchive {
    let root: URL
    static let fileLimit = 2 * 1024 * 1024
    static let totalLimit = 64 * 1024 * 1024
    static func allowed(_ relative: String) -> Bool {
        let p = relative.split(separator: "/").map(String.init)
        guard !p.contains("..") else { return false }
        if p.count == 2 && p[0] == "Activity" {
            return p[1] == "incomplete.txt" || p[1].range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil
        }
        if p.count == 4 && p[0] == "Activity" && p[1] == "Traces" {
            return p[2].range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil && UUID(uuidString: String(p[3].dropLast(5))) != nil && p[3].hasSuffix(".json")
        }
        guard p.count == 3 && UUID(uuidString: p[1]) != nil else { return false }
        if p[0] == "Diagnostics" { return p[2] == "manifest.json" || ModemInformationManager.diagnosticCommands.contains { $0.0 == p[2] } }
        if p[0] == "Logs" { return p[2].hasSuffix(".log") }
        return p[0] == "SetupBackups" && p[2] == "installation.log"
    }
    /// openat on every component prevents symlink substitution in parent directories.
    static func readRegular(root: URL, relative: String, limit: Int) throws -> (Data, Bool) {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(fd >= 0, "Каталог диагностики недоступен")
        defer { close(fd) }
        let parts = relative.split(separator: "/").map(String.init)
        try require(!parts.isEmpty && !relative.hasPrefix("/") && !parts.contains("..") && !parts.contains("."), "Небезопасный путь")
        for (index, part) in parts.enumerated() {
            let next = openat(fd, part, O_RDONLY | O_NOFOLLOW | (index + 1 < parts.count ? O_DIRECTORY : 0) | O_NONBLOCK)
            try require(next >= 0, "Файл недоступен или является ссылкой")
            close(fd); fd = next
        }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1, "Необычный тип или владелец файла")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let truncated = info.st_size > limit
        // Journals keep their most recent records; other files keep a bounded prefix.
        if truncated && relative.hasSuffix(".jsonl") { try handle.seek(toOffset: UInt64(info.st_size - Int64(limit))) }
        let data = try handle.read(upToCount: limit) ?? Data()
        return (data, truncated)
    }
    func export(to destination: URL, context: [String: String]) throws -> DiagnosticArchiveResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("zte-support-" + UUID().uuidString.lowercased())
        try secureDirectory(work); defer { try? fm.removeItem(at: work) }
        let snapshot = work.appendingPathComponent("ZTE-Diagnostics")
        try secureDirectory(snapshot)
        var issues = [String](), entries = [[String: String]](), total = 0, omitted = 0
        func issue(_ value: String) { omitted += 1; if issues.count < 500 { issues.append(ActivityJournal.redact(value)) } }
        func write(_ data: Data, _ relative: String) throws {
            let file = snapshot.appendingPathComponent(relative)
            try secureDirectory(file.deletingLastPathComponent()); try savePrivate(data, file)
            entries.append(["path": relative, "bytes": String(data.count), "sha256": digest(data)])
            total += data.count
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(encoder.encode(context.mapValues(ActivityJournal.sanitize)), "application.json")
        var candidates = [(String, Date)]()
        for folder in ["Activity", "Diagnostics", "Logs", "SetupBackups"] {
            let base = root.appendingPathComponent(folder)
            if (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { issue(folder + ": ссылка пропущена"); continue }
            guard let enumerator = fm.enumerator(atPath: base.path) else { continue }
            var scanned = 0
            for case let child as String in enumerator {
                scanned += 1
                if scanned > 20000 { issue(folder + ": достигнут предел обхода файлов"); break }
                // The path enumerator returns names relative to base, avoiding
                // macOS URL alias normalization (/var vs /private/var) altogether.
                if child.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                    if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { enumerator.skipDescendants() }
                    continue
                }
                let relative = folder + "/" + child
                let file = root.appendingPathComponent(relative)
                let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
                // DirectoryEnumerator does not descend symlinks. Calling
                // skipDescendants on a file can skip its remaining siblings on macOS.
                if values?.isSymbolicLink == true { issue(relative + ": ссылка пропущена"); continue }
                if values?.isRegularFile == true && Self.allowed(relative) { candidates.append((relative, values?.contentModificationDate ?? .distantPast)) }
            }
        }
        for (relative, _) in candidates.sorted(by: { $0.1 > $1.1 }) {
            if entries.count >= 10000 || total >= Self.totalLimit { issue(relative + ": достигнут предел архива"); continue }
            do {
                let (raw, truncated) = try Self.readRegular(root: root, relative: relative, limit: Self.fileLimit)
                if truncated { issue(relative + ": файл сокращён до 2 МиБ") }
                let clean: Data
                if relative.hasSuffix(".jsonl") {
                    var lines = Data(), invalid = 0
                    for line in raw.split(separator: 10) {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)), let data = try? JSONSerialization.data(withJSONObject: ActivityJournal.sanitizeJSON(object), options: [.sortedKeys, .withoutEscapingSlashes]) else { invalid += 1; continue }
                        lines.append(data); lines.append(10)
                    }
                    if invalid > 0 { issue(relative + ": неполных записей пропущено \(invalid)") }
                    clean = lines
                } else if relative.hasSuffix(".json"), let object = try? JSONSerialization.jsonObject(with: raw) {
                    clean = try JSONSerialization.data(withJSONObject: ActivityJournal.sanitizeJSON(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                } else {
                    guard !raw.contains(0), let text = String(data: raw, encoding: .utf8) else { issue(relative + ": нетекстовый или обрезанный UTF-8 файл исключён"); continue }
                    clean = Data(ActivityJournal.sanitize(text).utf8)
                }
                if total + clean.count > Self.totalLimit { issue(relative + ": превышен общий размер"); continue }
                try write(clean, relative)
            } catch { issue(relative + ": " + error.localizedDescription) }
        }
        // Only the validated latest pointer and its report are read. Historical reports,
        // neighbouring cache files and linked paths are never recursively collected.
        do {
            let report = try FirmwareResearchArchive.latest(root: root)
            let payloads = try FirmwareResearchArchive.textPayloads(report)
            let bytes = payloads.reduce(0) { $0 + $1.data.count }
            try require(total + bytes <= Self.totalLimit && entries.count + payloads.count <= 10000, "Research exceeds archive budget")
            for payload in payloads { try write(payload.data, "FirmwareResearch/" + report.id + "/" + payload.path) }
        } catch {
            // Cache errors may contain untrusted saved strings: emit only a fixed omission.
            issue("FirmwareResearch: сохранённое исследование отсутствует, недоступно, повреждено или превышает предел архива; пропущено")
        }
        let readme = """
        Диагностика ZTE IMEI Studio \(DiagnosticsContext.version)

        application.json: состояние приложения, версия macOS, адрес и состояние подключения.
        Activity: журнал всех доступных сеансов. sessionID связывает сеанс, operationID — операцию,
        requestID — запуск и результат запроса. Traces содержит очищенные команды и вывод,
        длительность, exitCode, размеры и SHA256. Ввод команд и тела HTTP-запросов не сохраняются.
        Diagnostics: ранее собранные отчёты модема, включая версии прошивки и компонентов,
        память, маршруты, firewall, журналы, USB, службы и доступные методы ubus.
        FirmwareResearch/<id>: последнее сохранённое исследование, его проверки и исходные
        startedAt/finishedAt; частичные результаты сохраняют свой outcome. Новый сбор не запускается.
        Это сохранённые сведения: они могут относиться к другому устройству или сеансу.
        При отсутствии, повреждении, небезопасном пути или превышении лимита набор пропускается
        с причиной в manifest.json. Остальные сохранённые исследования не обходятся.
        Logs и installation.log: очищенные текстовые журналы прежних операций.

        Это диагностический архив, а не резервная копия для восстановления модема.
        Ключи SSH, бэкапы NV/EFS/конфигураций и файлы VPN-профилей в него не включаются.
        Известные секретные поля, VPN-ссылки и номера SIM/IMEI скрываются. Адреса сети, CID,
        имена устройств и пути могут оставаться в диагностике. Просмотрите файлы перед передачей.
        Произвольные секреты без узнаваемого формата автоматически распознать невозможно.

        Пределы: 2 МиБ на обычный файл, 32 МиБ на сохранённый отчёт исследования;
        64 МиБ и 10000 файлов на набор. Сначала новые обычные файлы, затем исследование целиком.
        Журнал при сокращении сохраняет последние записи, прочие файлы — начало.
        Отсутствующие службы и несовместимые методы отмечены кодами ошибок в отчётах.
        Незавершённый запрос может иметь только событие started. Старые сеансы до 1.9.0
        не содержат подробных трассировок. Диагностика не отключает проверки перед записью.
        SHA256 в manifest.json относится к файлам именно этого архива после очистки.
        Вложенные старые manifest.json описывают исходный локальный набор до повторной очистки.
        Свежесть каждого набора определяется его created; экспорт без сбора не обращается к модему.
        """
        try write(Data(readme.utf8), "README.txt")
        let manifest: [String: Any] = ["schema": 1, "created": ISO8601DateFormatter().string(from: Date()), "files": entries, "warnings": issues, "warningCount": omitted, "totalUncompressedBytes": total, "sessionID": DiagnosticsContext.sessionID]
        try savePrivate(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), snapshot.appendingPathComponent("manifest.json"))
        let zip = work.appendingPathComponent("diagnostics.zip"), runner = HostProcessRunner()
        let packed = try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", snapshot.path, zip.path], timeout: 90)
        try require(packed.status == 0, "Не удалось создать ZIP: " + ActivityJournal.redact(String(decoding: packed.stderr, as: UTF8.self)))
        let check = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-tq", zip.path], timeout: 60)
        try require(check.status == 0, "Созданный ZIP не прошёл проверку целостности")
        let bytes = try Data(contentsOf: zip)
        try savePrivate(bytes, destination)
        return DiagnosticArchiveResult(url: destination, fileCount: entries.count + 1, warnings: omitted, sha256: digest(bytes))
    }
}
