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
        if p[0] == "Diagnostics" { return p[2] == "manifest.json" || ModemInformationManager.logCommands.contains { $0.0 == p[2] } }
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
    /// Inspect only the fixed allowlist depth. Do not stop an unordered directory
    /// walk before sorting: old traces must not hide newer files beyond a scan cap.
    func candidateFiles(issue: (String) -> Void) -> [(relative: String, modified: Date)] {
        let fm = FileManager.default
        var result = [(relative: String, modified: Date)]()
        func children(_ relative: String) -> [String] {
            let directory = root.appendingPathComponent(relative)
            guard let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return [] }
            if values.isSymbolicLink == true { issue(relative + ": ссылка пропущена"); return [] }
            guard values.isDirectory == true else { return [] }
            do { return try fm.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") } }
            catch { issue(relative + ": " + error.localizedDescription); return [] }
        }
        func append(_ relative: String) {
            guard Self.allowed(relative) else { return }
            let file = root.appendingPathComponent(relative)
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]) else {
                issue(relative + ": файл недоступен"); return
            }
            if values.isSymbolicLink == true { issue(relative + ": ссылка пропущена"); return }
            if values.isRegularFile == true { result.append((relative, values.contentModificationDate ?? .distantPast)) }
        }
        for name in children("Activity") {
            if name == "Traces" {
                for operation in children("Activity/Traces") where operation.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil {
                    let folder = "Activity/Traces/" + operation
                    for file in children(folder) { append(folder + "/" + file) }
                }
            } else { append("Activity/" + name) }
        }
        for folder in ["Diagnostics", "Logs", "SetupBackups"] {
            for id in children(folder) where UUID(uuidString: id) != nil {
                let directory = folder + "/" + id
                for file in children(directory) { append(directory + "/" + file) }
            }
        }
        return result
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
        let freshReportID = context["freshReportID"].flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        let candidates = candidateFiles(issue: issue).sorted { lhs, rhs in
            func priority(_ path: String) -> Int {
                if let freshReportID, path.hasPrefix("Diagnostics/" + freshReportID + "/") { return 0 }
                return path.hasPrefix("Activity/Traces/") ? 2 : 1
            }
            let left = priority(lhs.relative), right = priority(rhs.relative)
            if left != right { return left < right }
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.relative < rhs.relative
        }
        for (relative, _) in candidates {
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
        let readme = """
        Диагностика ZTE IMEI Studio \(DiagnosticsContext.version)

        application.json: состояние приложения, версия macOS, адрес и состояние подключения.
        Activity: журнал всех доступных сеансов. sessionID связывает сеанс, operationID — операцию,
        requestID — запуск и результат запроса. Traces содержит очищенные команды и вывод,
        длительность, exitCode, размеры и SHA256. Ввод команд и тела HTTP-запросов не сохраняются.
        Diagnostics: сохранённые системные журналы, журнал ядра и журналы компонентов модема.
        Время сбора и ошибки чтения указаны в manifest.json каждого набора.
        Исследование устройства и файлы прошивки собираются отдельно пунктом
        «Данные для адаптации прошивки» и в архив журналов не включаются.
        Logs и installation.log: очищенные текстовые журналы прежних операций.

        Это диагностический архив, а не резервная копия для восстановления модема.
        Ключи SSH, бэкапы NV/EFS/конфигураций и файлы VPN-профилей в него не включаются.
        Известные секретные поля, VPN-ссылки и номера SIM/IMEI скрываются. Адреса сети, CID,
        имена устройств и пути могут оставаться в диагностике. Просмотрите файлы перед передачей.
        Произвольные секреты без узнаваемого формата автоматически распознать невозможно.

        Пределы: 2 МиБ на исходный файл, 64 МиБ данных и до 10000 файлов данных;
        README.txt и итоговый manifest.json добавляются отдельно.
        Сначала свежий набор Diagnostics, указанный в application.json, затем дневные
        Activity, сохранённые Diagnostics, Logs и installation.log; подробные Traces — последними.
        В каждой группе сначала новые файлы; при одинаковом времени — по имени.
        При достижении пределов старая история может не войти. warningCount учитывает все
        пропуски и сокращения; warnings содержит первые 500 подробностей. complete=false
        означает неполный экспорт истории, даже если свежие журналы модема получены целиком.
        Журнал при сокращении сохраняет последние записи, прочие файлы — начало.
        Отсутствующие службы и несовместимые методы отмечены кодами ошибок в отчётах.
        Незавершённый запрос может иметь только событие started. Старые сеансы до 1.9.0
        не содержат подробных трассировок. Диагностика не отключает проверки перед записью.
        SHA256 в manifest.json относится к файлам именно этого архива после очистки.
        Вложенные старые manifest.json описывают исходный локальный набор до повторной очистки.
        Свежесть каждого набора определяется его created; экспорт без сбора не обращается к модему.
        """
        try write(Data(readme.utf8), "README.txt")
        let manifest: [String: Any] = ["schema": 1, "created": ISO8601DateFormatter().string(from: Date()), "complete": omitted == 0, "files": entries, "warnings": issues, "warningCount": omitted, "warningDetailsTruncated": omitted > issues.count, "totalUncompressedBytes": total, "sessionID": DiagnosticsContext.sessionID]
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
