import Foundation
import CryptoKit
import Darwin

/// IMEI backups retain their separate Engine.makeBackup/loadBackup/restore flow.
enum DeviceBackupKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case modem, userData, configuration
    var id: String { rawValue }
    var title: String {
        switch self { case .modem: return "Модемная часть"; case .userData: return "Пользовательская часть"; case .configuration: return "Конфигурация" }
    }
    var scope: String {
        switch self {
        case .modem: return "Снимки modemst1, modemst2, fsg и persist: 20 МиБ. Не включает образы прошивки и не является QCN."
        case .userData: return "Архив /data: установленные приложения и пользовательские файлы. Исключены local/tmp, cache, log, logs, известные папки резервных копий и временного обновления."
        case .configuration: return "Настройки /etc/config, службы и автозапуск, учётные записи и SSH, профили VPN, настройки SSClash, конфигурация и ресурсы TTL и русификации."
        }
    }
    var limitations: String {
        "Копия работающего устройства: согласованность всех файлов в один момент не гарантируется. Содержит конфиденциальные данные; хранится без шифрования, с доступом только владельцу. Автоматическое восстановление этих копий не предусмотрено."
    }
    var fileNames: [String] {
        switch self { case .modem: return ["modemst1.bin", "modemst2.bin", "fsg.bin", "persist.bin"]; case .userData: return ["user-data.tar"]; case .configuration: return ["configuration.tar"] }
    }
    var exclusions: [String] {
        self == .userData ? ["data/local/tmp", "data/cache", "data/log", "data/logs", "data/open-u60-agent-backups", "data/zte-imei-admin/backups", "data/zte-imei-ttl/backup", "data/zte-imei-screen-ru/backup", "data/.open-u60-switch.*"] : []
    }
}
struct DeviceBackupFile: Codable, Equatable, Sendable {
    var name: String
    var source: String
    var bytes: Int64
    var sha256: String
}
struct DeviceBackupManifest: Codable, Sendable {
    var schema = 1
    var id: String
    var kind: DeviceBackupKind
    var created: String
    var identity: Identity
    var bootID: String
    var scope: String
    var limitations: String
    var exclusions: [String]
    var files: [DeviceBackupFile]
    var complete = true
}
struct DeviceBackupItem: Identifiable, Sendable {
    var id: String
    var kind: DeviceBackupKind
    var created: String
    var bytes: Int64
    var scope: String
    var url: URL
    var identity: Identity
    var date: String { created }
}
struct BackupStreamResult: Sendable { var sha256: String; var bytes: Int64 }
protocol BackupStreamTransport {
    func stream(_ command: String, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult
}

/// The OS streams SSH stdout directly into a private file. No archive-sized Data
/// or in-memory buffer exists; hashing is incremental in 1 MiB blocks.
final class SSHBackupStreamTransport: BackupStreamTransport {
    let connection: Connection
    init(_ connection: Connection) { self.connection = connection }
    func stream(_ command: String, to destination: URL, maxBytes: Int64, timeout: TimeInterval, cancelled: @escaping @Sendable () -> Bool) throws -> BackupStreamResult {
        try connection.validate()
        try DeviceBackups.checkCancelled(cancelled)
        let output = try DeviceBackups.createFile(destination)
        let errorURL = destination.deletingLastPathComponent().appendingPathComponent(".stderr-" + UUID().uuidString.lowercased())
        let errors = try DeviceBackups.createFile(errorURL)
        defer { try? output.close(); try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-F", "/dev/null", "-T", "-p", connection.port, "-i", connection.keyPath,
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"" + connection.knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"",
            "-o", "GlobalKnownHostsFile=/dev/null", "root@" + connection.host, command]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var stopped: String?
        while process.isRunning {
            if cancelled() { stopped = "Создание резервной копии отменено"; break }
            if Date() >= deadline { stopped = "Истекло время передачи резервной копии"; break }
            var outStat = stat(), errStat = stat()
            if fstat(output.fileDescriptor, &outStat) != 0 || fstat(errors.fileDescriptor, &errStat) != 0 || outStat.st_size > maxBytes || errStat.st_size > 1_048_576 {
                stopped = "Превышен допустимый размер резервной копии или ответа SSH"; break
            }
            if (try? DeviceBackups.freeBytes(at: destination.deletingLastPathComponent())) ?? 0 < DeviceBackups.reserveBytes {
                stopped = "Недостаточно свободного места для резервной копии"; break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let stopped {
            process.terminate(); let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let killed = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killed { Thread.sleep(forTimeInterval: 0.02) }
            throw IMEIError.message(stopped + ". Незавершённая копия не сохранена.")
        }
        process.waitUntilExit(); try output.synchronize(); try errors.synchronize()
        let diagnostic = try DeviceBackups.smallFile(errorURL, maximum: 1_048_576)
        try require(process.terminationStatus == 0, Self.failureMessage(String(decoding: diagnostic, as: UTF8.self), exitCode: process.terminationStatus))
        let remote = try Self.parseReceipt(String(decoding: diagnostic, as: UTF8.self))
        let local = try DeviceBackups.hashFile(destination, cancelled: cancelled)
        try require(local.bytes <= maxBytes && local.bytes == remote.bytes && local.sha256 == remote.sha256, "Контрольная сумма или размер переданной копии не совпали")
        return local
    }
    static func failureMessage(_ diagnostic: String, exitCode: Int32) -> String {
        // Keep only recognizable producer/transport diagnostics, redact before
        // truncation, and never echo arbitrary remote output or credential data.
        let safe = ActivityJournal.redact(String(diagnostic.prefix(16_384)))
        let details = safe.split(whereSeparator: \.isNewline).filter {
            $0.hasPrefix("BACKUP_ERROR ") || $0.hasPrefix("tar:") || $0.hasPrefix("dd:") ||
            $0.hasPrefix("ssh:") || $0.hasPrefix("Permission denied") || $0.hasPrefix("Host key verification failed")
        }.prefix(4).map { String($0.prefix(240)) }.joined(separator: "; ")
        let reason: String
        if safe.contains("unrecognized option") || safe.contains("illegal option") { reason = "Встроенный архиватор не поддерживает команду резервного копирования." }
        else if safe.contains("file changed") || safe.contains("File changed") || safe.contains("CHANGED_PARTITION") { reason = "Данные изменились во время чтения. Повторите создание копии после завершения других операций." }
        else if safe.contains("DATA_MOUNTS") { reason = "В /data обнаружена дополнительная точка монтирования; состав копии требует проверки." }
        else if safe.contains("PENDING") { reason = "На модеме есть незавершённая операция." }
        else if safe.contains("Permission denied") { reason = "SSH отказал в доступе при чтении данных." }
        else { reason = "Не удалось прочитать данные модема (код \(exitCode))." }
        return reason + (details.isEmpty ? "" : " " + details) + " Копия не сохранена; исходные данные не изменены."
    }
    static func parseReceipt(_ text: String) throws -> BackupStreamResult {
        let lines = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("BACKUP_RESULT ") }
        try require(lines.count == 1, "Не получена однозначная контрольная сумма потока")
        let fields = lines[0].split(separator: " ")
        try require(fields.count == 3 && fields[1].hasPrefix("sha256=") && fields[2].hasPrefix("bytes="), "Неверный формат подтверждения копии")
        let hash = String(fields[1].dropFirst(7)), rawBytes = String(fields[2].dropFirst(6))
        try require(DeviceBackups.validHash(hash) && !rawBytes.isEmpty && rawBytes.utf8.allSatisfy { (48...57).contains($0) }, "Неверная контрольная сумма копии")
        guard let bytes = Int64(rawBytes), bytes > 0 else { throw IMEIError.message("Неверный размер копии") }
        return BackupStreamResult(sha256: hash, bytes: bytes)
    }
}

final class DeviceBackups {
    static let reserveBytes: Int64 = 64 * 1024 * 1024
    static let maximumBytes: Int64 = 16 * 1024 * 1024 * 1024
    static let partitionBytes: [String: Int64] = ["modemst1.bin": 4_194_304, "modemst2.bin": 4_194_304, "fsg.bin": 4_194_304, "persist.bin": 8_388_608]
    static let partitionSources = ["modemst1.bin": "/dev/mmcblk0p8", "modemst2.bin": "/dev/mmcblk0p9", "fsg.bin": "/dev/mmcblk0p10", "persist.bin": "/dev/mmcblk0p56"]
    // Updated from the reviewed read-only producer resource.
    static let readerHash = "59009e4c32eb52f67c6f318974e3410bc7b5b7561003647b1984496e5de8c778"
    let engine: ModemEngine
    let streamer: BackupStreamTransport
    let spaceAvailable: (URL) throws -> Int64
    init(engine: ModemEngine, streamer: BackupStreamTransport? = nil, spaceAvailable: @escaping (URL) throws -> Int64 = DeviceBackups.freeBytes) {
        self.engine = engine; self.streamer = streamer ?? SSHBackupStreamTransport(engine.connection); self.spaceAvailable = spaceAvailable
    }
    static func rootURL(_ root: URL) -> URL { root.appendingPathComponent("DeviceBackups", isDirectory: true) }
    static func checkCancelled(_ cancelled: @Sendable () -> Bool) throws { try require(!cancelled(), "Создание резервной копии отменено") }
    static func validHash(_ text: String) -> Bool { text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func metadata(_ url: URL) throws -> stat {
        var info = stat(); try require(lstat(url.path, &info) == 0, "Не удалось прочитать файл резервной копии"); return info
    }
    static func directory(_ url: URL, create: Bool = false) throws {
        if create && !FileManager.default.fileExists(atPath: url.path) {
            try require(mkdir(url.path, 0o700) == 0, "Не удалось создать приватную папку резервных копий")
        }
        let info = try metadata(url)
        try require(info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700, "Папка резервных копий должна принадлежать пользователю, иметь права 0700 и не быть ссылкой")
    }
    static func createFile(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "Нельзя создать файл копии: имя уже занято или путь небезопасен")
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func openFile(_ url: URL, publicResource: Bool = false) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(fd >= 0, "Файл копии недоступен или является ссылкой")
        var info = stat()
        guard fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && (info.st_uid == getuid() || (publicResource && info.st_uid == 0)) && (publicResource ? info.st_mode & 0o022 == 0 : info.st_mode & 0o777 == 0o600) else {
            close(fd); throw IMEIError.message("В копии допускаются только приватные обычные файлы с правами 0600")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func smallFile(_ url: URL, maximum: Int, publicResource: Bool = false) throws -> Data {
        let file = try openFile(url, publicResource: publicResource); defer { try? file.close() }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        try require(bytes.count <= maximum, "Слишком большой служебный файл резервной копии"); return bytes
    }
    static func freeBytes(at url: URL) throws -> Int64 {
        let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let free = values[.systemFreeSize] as? NSNumber else { throw IMEIError.message("Не удалось проверить свободное место") }
        return free.int64Value
    }
    static func hashFile(_ url: URL, cancelled: @Sendable () -> Bool = { false }) throws -> BackupStreamResult {
        let file = try openFile(url); defer { try? file.close() }
        var hash = SHA256(); var total: Int64 = 0
        while true {
            try checkCancelled(cancelled)
            let chunk = try file.read(upToCount: 1_048_576) ?? Data(); if chunk.isEmpty { break }
            total += Int64(chunk.count); try require(total <= maximumBytes, "Слишком большой файл резервной копии")
            hash.update(data: chunk)
        }
        return BackupStreamResult(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: total)
    }
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = try createFile(url); defer { try? file.close() }; try file.write(contentsOf: encoder.encode(value)); try file.synchronize()
    }
    private func record(_ title: String, _ result: String, _ details: [String: String] = [:]) {
        try? ActivityJournal(root: engine.root).record(operationID: engine.logDirectory.lastPathComponent, category: "backup", title: title, result: result, details: details)
    }
    private func invoke(_ stage: String, _ arguments: [String]) -> String {
        let script = stage + "/reader.sh"
        return "set -eu; test -f " + shellQuote(script) + "; test ! -L " + shellQuote(script) + "; test \"$(sha256sum " + shellQuote(script) + " | cut -d ' ' -f1)\" = " + shellQuote(Self.readerHash) + "; sh " + shellQuote(script) + " " + arguments.map(shellQuote).joined(separator: " ")
    }
    /// Caller must hold engine.locked throughout creation, including cleanup.
    func create(_ kind: DeviceBackupKind, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> DeviceBackupItem {
        try require(engine.lockFD >= 0, "Создание копии требует блокировки операции")
        try Self.checkCancelled(cancelled); try engine.connection.validate()
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] { try require(!engine.fm.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите незавершённую операцию модема") }
        try Self.directory(engine.root)
        let store = Self.rootURL(engine.root); try Self.directory(store, create: true)
        let identity = try engine.identity(); try engine.acquireRemoteLock()
        let source = try Self.smallFile(engine.resources.appendingPathComponent("DeviceBackups/reader.sh"), maximum: 65536, publicResource: true)
        try require(digest(source) == Self.readerHash, "Повреждён встроенный инструмент резервного копирования")
        let id = UUID().uuidString.lowercased(), stage = "/tmp/zte-device-backup-" + id
        let staging = store.appendingPathComponent(".partial-" + id), final = store.appendingPathComponent(id)
        try Self.directory(staging, create: true)
        var published = false
        defer { if !published { try? engine.fm.removeItem(at: staging) } }
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer { _ = try? engine.remote("test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) + " && rm -rf " + shellQuote(stage), timeout: 15) }
        let transferred = try engine.remote("umask 077; cat > " + shellQuote(stage + "/reader.sh") + " && sha256sum " + shellQuote(stage + "/reader.sh"), input: source)
        let uploadFields = String(decoding: transferred, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(uploadFields.count == 2 && uploadFields[0] == Substring(Self.readerHash) && uploadFields[1] == Substring(stage + "/reader.sh"), "Повреждён переданный инструмент резервного копирования")
        let estimateResult = try engine.remote(invoke(stage, ["estimate", identity.0.cid, kind.rawValue]), timeout: 90)
        let estimate = try Self.parseEstimate(String(decoding: estimateResult, as: UTF8.self))
        let limit = min(Self.maximumBytes, estimate + max(Self.reserveBytes, estimate / 2))
        try require(try spaceAvailable(store) >= limit + Self.reserveBytes, "Недостаточно свободного места: требуется размер копии и запас 64 МиБ")
        record("Создание копии: " + kind.title, "started", ["kind": kind.rawValue, "estimatedBytes": String(estimate)])
        do {
            var files: [DeviceBackupFile] = []
            for (index, name) in kind.fileNames.enumerated() {
                try Self.checkCancelled(cancelled)
                engine.update("Сохраняю «" + kind.title + "»: " + name, 0.1 + Double(index) / Double(kind.fileNames.count) * 0.7)
                let args = kind == .modem ? ["partition", identity.0.cid, String(name.dropLast(4))] : [kind.rawValue, identity.0.cid]
                let maximum = Self.partitionBytes[name] ?? limit
                let started = Date()
                let result = try streamer.stream(invoke(stage, args), to: staging.appendingPathComponent(name), maxBytes: maximum, timeout: kind == .modem ? 180 : 2400, cancelled: cancelled)
                let checked = try Self.hashFile(staging.appendingPathComponent(name), cancelled: cancelled)
                try require(result.sha256 == checked.sha256 && result.bytes == checked.bytes && result.bytes > 0 && result.bytes <= maximum, "Переданная копия не прошла независимую проверку SHA256")
                if let bytes = Self.partitionBytes[name] { try require(result.bytes == bytes, "Размер раздела отличается от проверенного B31") }
                files.append(DeviceBackupFile(name: name, source: Self.partitionSources[name] ?? (kind == .userData ? "/data" : "configuration allowlist"), bytes: result.bytes, sha256: result.sha256))
                record("Файл копии проверен", "completed", ["file": name, "bytes": String(result.bytes), "sha256": result.sha256, "durationSeconds": String(Int(Date().timeIntervalSince(started)))])
            }
            let after = try engine.identity()
            try require(after.0 == identity.0 && after.1 == identity.1, "Во время копирования изменился модем или произошла перезагрузка")
            try Self.checkCancelled(cancelled)
            let manifest = DeviceBackupManifest(id: id, kind: kind, created: ISO8601DateFormatter().string(from: Date()), identity: identity.0, bootID: identity.1, scope: kind.scope, limitations: kind.limitations, exclusions: kind.exclusions, files: files)
            try Self.writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))
            _ = try Self.verifyDirectory(staging, expectedID: id, cancelled: cancelled)
            try engine.fm.moveItem(at: staging, to: final); published = true
            let item = Self.item(manifest, at: final)
            record("Копия создана и проверена", "completed", ["backupID": id, "kind": kind.rawValue, "bytes": String(item.bytes)])
            engine.update("Резервная копия создана и проверена", 1)
            return item
        } catch {
            record("Создание копии остановлено", "failed", ["kind": kind.rawValue])
            throw error
        }
    }
    static func parseEstimate(_ text: String) throws -> Int64 {
        let text = text.trimmingCharacters(in: .newlines), prefix = "BACKUP_ESTIMATE bytes="
        try require(text.hasPrefix(prefix), "Не удалось оценить размер резервной копии")
        let value = String(text.dropFirst(prefix.count))
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let bytes = Int64(value), bytes > 0, bytes <= maximumBytes - reserveBytes else { throw IMEIError.message("Неизвестный или слишком большой размер резервной копии") }
        return bytes
    }
    static func manifest(at url: URL, expectedID: String? = nil) throws -> DeviceBackupManifest {
        try directory(url)
        let manifest = try JSONDecoder().decode(DeviceBackupManifest.self, from: smallFile(url.appendingPathComponent("manifest.json"), maximum: 65536))
        try require(manifest.schema == 1 && manifest.complete && UUID(uuidString: manifest.id) != nil && manifest.id == (expectedID ?? url.lastPathComponent), "Неверный формат или незавершённая резервная копия")
        try require(manifest.identity.cid.count == 32 && manifest.identity.cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && manifest.identity.firmwareHash == ModemEngine.firmwareHash && UUID(uuidString: manifest.bootID) != nil, "Неверный идентификатор модема или прошивки в копии")
        try require(ISO8601DateFormatter().date(from: manifest.created) != nil, "Неверная дата резервной копии")
        try require(manifest.files.count == manifest.kind.fileNames.count && Set(manifest.files.map(\.name)) == Set(manifest.kind.fileNames), "Неверный состав резервной копии")
        for file in manifest.files {
            try require(file.bytes > 0 && file.bytes <= maximumBytes && validHash(file.sha256), "Неверный размер или SHA256 в манифесте")
            if let expected = partitionBytes[file.name] { try require(file.bytes == expected && file.source == partitionSources[file.name], "Неверное описание раздела") }
        }
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == Set(manifest.kind.fileNames + ["manifest.json"]), "В папке копии есть посторонние или незавершённые файлы")
        return manifest
    }
    private static func item(_ manifest: DeviceBackupManifest, at url: URL) -> DeviceBackupItem {
        DeviceBackupItem(id: manifest.id, kind: manifest.kind, created: manifest.created, bytes: manifest.files.reduce(0) { $0 + $1.bytes }, scope: manifest.scope, url: url, identity: manifest.identity)
    }
    static func list(root: URL) throws -> [DeviceBackupItem] {
        try directory(root); let store = rootURL(root)
        if !FileManager.default.fileExists(atPath: store.path) { return [] }
        try directory(store)
        return try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { item(try manifest(at: $0), at: $0) }.sorted { $0.created > $1.created }
    }
    private static func verifyDirectory(_ url: URL, expectedID: String? = nil, cancelled: @Sendable () -> Bool) throws -> DeviceBackupItem {
        let manifest = try manifest(at: url, expectedID: expectedID)
        for file in manifest.files {
            let result = try hashFile(url.appendingPathComponent(file.name), cancelled: cancelled)
            try require(result.sha256 == file.sha256 && result.bytes == file.bytes, "Повреждена резервная копия: " + file.name)
        }
        return item(manifest, at: url)
    }
    static func verify(_ item: DeviceBackupItem, cancelled: @Sendable () -> Bool = { false }) throws -> DeviceBackupItem {
        try verifyDirectory(item.url, expectedID: item.id, cancelled: cancelled)
    }
    /// Exports a verified private directory; no automatic extraction or restore.
    static func export(_ item: DeviceBackupItem, to directory: URL, cancelled: @Sendable () -> Bool = { false }) throws -> URL {
        let verified = try verify(item, cancelled: cancelled)
        let target = directory.standardizedFileURL
        let info = try metadata(target)
        try require(info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid(), "Выберите существующую папку владельца, не символическую ссылку")
        try require(try freeBytes(at: target) >= verified.bytes + reserveBytes, "Недостаточно места для экспорта")
        let stage = target.appendingPathComponent(".partial-" + UUID().uuidString.lowercased()), final = target.appendingPathComponent(item.id)
        try require(!FileManager.default.fileExists(atPath: final.path), "Копия с таким именем уже существует в выбранной папке")
        try Self.directory(stage, create: true); var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage) } }
        let manifest = try manifest(at: item.url, expectedID: item.id)
        for name in manifest.kind.fileNames + ["manifest.json"] {
            let input = try openFile(item.url.appendingPathComponent(name)); defer { try? input.close() }
            let output = try createFile(stage.appendingPathComponent(name)); defer { try? output.close() }
            while true {
                try checkCancelled(cancelled)
                let data = try input.read(upToCount: 1_048_576) ?? Data(); if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        }
        _ = try verifyDirectory(stage, expectedID: item.id, cancelled: cancelled)
        try FileManager.default.moveItem(at: stage, to: final); published = true
        return final
    }
}
