import Foundation
import Darwin
import CryptoKit

struct SystemBackupDevice: Codable, Equatable, Sendable {
    var name: String
    var source: String
    var bytes: Int64
    var sectors: Int64? = nil
    var logicalSectorBytes: Int64? = nil
    var physicalSectorBytes: Int64? = nil
    var fileName: String { name + ".bin" }
}
struct SystemBackupPartition: Codable, Equatable, Sendable {
    var device: String
    var name: String
    var number: Int
    var startSector: Int64
    var sectors: Int64
}
struct SystemInventory: Codable, Equatable, Sendable {
    var schema: Int
    var cid: String
    var bootID: String
    var firmwareHash: String
    var layoutHash: String
    var diskBytes: Int64
    var offline: Bool
    var offlineReason: String
    var devices: [SystemBackupDevice]
    var partitions: [SystemBackupPartition]? = nil
    var totalBytes: Int64 { devices.reduce(0) { $0 + $1.bytes } }
    func sameDevice(as other: SystemInventory) -> Bool {
        cid == other.cid && layoutHash == other.layoutHash && diskBytes == other.diskBytes && devices == other.devices && partitions == other.partitions
    }
    var offlineExplanation: String {
        if offline { return "Среда восстановления работает в RAM; eMMC свободна, модемная подсистема остановлена." }
        switch offlineReason {
        case "ROOT_NOT_RAM": return "Текущая система загружена с накопителя. Для полного восстановления загрузите отдельную среду в RAM."
        case "EMMC_MOUNTED": return "Разделы eMMC смонтированы. Среда восстановления должна отключить их во всех процессах."
        case "SWAP_ACTIVE": return "Используется swap. Для восстановления его необходимо отключить."
        case "BASEBAND_ONLINE": return "Модемная подсистема работает и может записывать служебные разделы."
        case "BASEBAND_UNKNOWN": return "Не удалось подтвердить остановку модемной подсистемы."
        case "BLOCK_HOLDER", "RAW_DEVICE_OPEN", "STORAGE_WRITER_ACTIVE": return "Накопитель занят другим процессом или драйвером."
        case "HOLDERS_UNKNOWN", "PROCESS_UNKNOWN": return "Не удалось подтвердить отсутствие процессов, использующих eMMC."
        case "FLASH_INTERFACE_INCOMPLETE": return "Интерфейс защиты записи неполон; безопасное переключение не подтверждено."
        default: return "Не выполнены условия отдельной среды восстановления в RAM."
        }
    }
}
struct SystemBackupManifest: Codable, Sendable {
    var schema = 1
    var id: String
    var created: String
    var inventory: SystemInventory
    var capture: String
    var files: [DeviceBackupFile]
    var chunks: [SystemRestoreChunk]
    var complete = true
    var scope = "Полный образ пользовательской области eMMC, включая GPT, разделы и промежутки, и аппаратных областей boot0/boot1. RPMB и OTP не включены."
    var limitations = "Снимок работающего модема не атомарен: согласованность разделов и файлов не гарантируется. Восстановление допускается только из отдельной среды в RAM с остановленным модемом и отключёнными разделами eMMC. Среда восстановления в комплект не входит. Копия не зашифрована."
}
struct SystemBackupItem: Identifiable, Sendable {
    var id: String
    var created: String
    var bytes: Int64
    var url: URL
    var inventory: SystemInventory
    var capture: String
    var scope: String
    var isLiveCapture: Bool { capture == "live-non-atomic" }
}
struct SystemRestorePlan: Sendable {
    var id: String
    var backup: SystemBackupItem
    var inventory: SystemInventory
    var isResume: Bool
    var canRestore: Bool { inventory.offline }
    var requiresLiveCaptureAcknowledgement: Bool { backup.isLiveCapture }
}
struct SystemRestoreResult: Sendable {
    var transactionID: String
    var beforeBackupID: String
    var bytes: Int64
    var resumed: Bool
}
struct SystemRestoreChunk: Codable, Equatable, Sendable {
    var target: String
    var offset: Int64
    var bytes: Int64
    var sha256: String
}
struct SystemRestoreTransaction: Codable, Sendable {
    var schema = 1
    var id: String
    var backupID: String
    var backupManifestHash: String
    var inventory: SystemInventory
    var beforeBackupID: String
    var chunks: [SystemRestoreChunk]
    var complete: Bool
    var previousBootIDs: [String] = []
}

/// Full raw images are deliberately separate from the legacy IMEI/configuration
/// formats. A verified transport hash is not a promise of live-disk consistency.
final class SystemBackups {
    static let chunkBytes = 8 * 1024 * 1024
    static let helperHash = "1614c2834530441daa2ae9927625be4dac2718709de98e214d5e0ac7bcf83aef"
    static let targetNames = ["mmcblk0", "mmcblk0boot0", "mmcblk0boot1"]
    static let pendingName = "system-restore-pending.json"
    let engine: ModemEngine
    let streamer: BackupStreamTransport
    let spaceAvailable: (URL) throws -> Int64
    init(engine: ModemEngine, streamer: BackupStreamTransport? = nil, spaceAvailable: @escaping (URL) throws -> Int64 = DeviceBackups.freeBytes) {
        self.engine = engine
        self.streamer = streamer ?? SSHBackupStreamTransport(engine.connection)
        self.spaceAvailable = spaceAvailable
    }
    static func rootURL(_ root: URL) -> URL { root.appendingPathComponent("SystemBackups", isDirectory: true) }
    static func hasPendingRestore(root: URL) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(pendingName).path, &info) == 0
    }
    static func validID(_ value: String) -> Bool { UUID(uuidString: value) != nil && value == value.lowercased() && value.count == 36 }
    static func validate(_ value: SystemInventory) throws {
        try require(value.schema == 1 && value.cid.count == 32 && value.cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Неверный CID полной копии")
        try require(validID(value.bootID) && DeviceBackups.validHash(value.layoutHash), "Неверный идентификатор загрузки или разметки")
        try require(value.firmwareHash.isEmpty || value.firmwareHash == ModemEngine.firmwareHash, "Прошивка полной копии отличается от проверенной B31")
        try require(value.offline || value.firmwareHash == ModemEngine.firmwareHash, "Для снимка работающего модема обязательна проверенная B31")
        try require(value.offlineReason.utf8.count <= 4096 && value.devices.map(\.name) == targetNames, "Неверный состав eMMC")
        for device in value.devices {
            try require(device.source == "/dev/" + device.name && device.bytes > 0 && device.bytes <= DeviceBackups.maximumBytes && device.bytes % 512 == 0, "Неверный размер или путь области eMMC")
            if let sectors = device.sectors { try require(sectors == device.bytes / 512, "Неверное число секторов eMMC") }
            if let logical = device.logicalSectorBytes { try require([512, 4096].contains(logical) && device.bytes % logical == 0, "Неверный логический сектор eMMC") }
            if let physical = device.physicalSectorBytes { try require([512, 4096].contains(physical), "Неверный физический сектор eMMC") }
        }
        try require(value.diskBytes == value.devices[0].bytes && value.totalBytes <= DeviceBackups.maximumBytes, "Неверная общая геометрия eMMC")
        if let partitions = value.partitions {
            try require(!partitions.isEmpty && partitions.count <= 512 && Set(partitions.map(\.number)).count == partitions.count, "Неверная таблица разделов")
            for part in partitions {
                try require(part.number > 0 && part.device == "mmcblk0p\(part.number)" && !part.name.isEmpty && part.name.count <= 64 && part.name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [95, 58, 45].contains($0) }, "Неверное имя раздела")
                try require(part.startSector >= 0 && part.sectors > 0 && part.startSector < value.diskBytes / 512 && part.sectors <= value.diskBytes / 512 - part.startSector, "Раздел за пределами eMMC")
            }
        }
    }
    private func locked() throws {
        try require(engine.lockFD >= 0, "Полная копия требует блокировки операции")
        try engine.connection.validate()
        try DeviceBackups.directory(engine.root)
        for name in ["pending.json", "setup-pending.json"] {
            try require(!engine.fm.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите незавершённую операцию модема")
        }
        // A recovery runtime may expose a different SSH address. Keep the same
        // operation token and migrate only after an authenticated read proves
        // this is the pending transaction's physical eMMC.
        if let pending = try pendingID(), engine.fm.fileExists(atPath: engine.tokenURL.path) {
            let saved = try JSONDecoder().decode([String: String].self, from: DeviceBackups.smallFile(engine.tokenURL, maximum: 4096))
            let endpoint = engine.connection.host + ":" + engine.connection.port
            try require(saved.count == 2 && Self.validID(saved["token"] ?? "") && saved["endpoint"] != nil, "Повреждена блокировка восстановления")
            if saved["endpoint"] != endpoint {
                let state = try transaction(pending)
                let actual = String(decoding: try engine.remote("cat /sys/block/mmcblk0/device/cid"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                try require(actual == state.inventory.cid, "Новый SSH-адрес относится к другому модему; блокировка не перенесена")
                try Self.durableJSON(["endpoint": endpoint, "token": saved["token"]!], to: engine.tokenURL)
            }
        }
        try engine.acquireRemoteLock(allowSystemRestore: true)
    }
    private func scriptCommand(_ stage: String, _ arguments: [String]) -> String {
        let file = stage + "/device.sh"
        return "set -eu; test -f " + shellQuote(file) + "; test ! -L " + shellQuote(file) + "; test \"$(sha256sum " + shellQuote(file) + " | cut -d ' ' -f1)\" = " + shellQuote(Self.helperHash) + "; sh " + shellQuote(file) + " " + arguments.map(shellQuote).joined(separator: " ")
    }
    private func stage(_ id: String) throws -> String {
        try require(Self.validID(id), "Неверный идентификатор операции")
        let path = "/tmp/zte-system-backup-" + id
        let script = try DeviceBackups.smallFile(engine.resources.appendingPathComponent("SystemBackups/device.sh"), maximum: 131072, publicResource: true)
        try require(digest(script) == Self.helperHash, "Повреждён встроенный инструмент полного резервного копирования")
        _ = try engine.remote("umask 077; if test ! -e " + shellQuote(path) + "; then mkdir " + shellQuote(path) + "; fi; test -d " + shellQuote(path) + " && test ! -L " + shellQuote(path) + " && test \"$(stat -c %u " + shellQuote(path) + ")\" = 0 && test \"$(stat -c %a " + shellQuote(path) + ")\" = 700")
        let file = path + "/device.sh"
        // A timed-out SSH process can still be executing this script. Never
        // truncate an existing staged helper when reconnecting to its journal.
        let existing = try engine.remote("if test -e " + shellQuote(file) + " || test -L " + shellQuote(file) + "; then test -f " + shellQuote(file) + " && test ! -L " + shellQuote(file) + " && test \"$(stat -c %u " + shellQuote(file) + ")\" = 0 && test \"$(stat -c %a " + shellQuote(file) + ")\" = 600 && sha256sum " + shellQuote(file) + "; else printf 'SYSTEM_HELPER_ABSENT\\n'; fi")
        let absent = String(decoding: existing, as: UTF8.self) == "SYSTEM_HELPER_ABSENT\n"
        let receipt = try absent ? engine.remote("umask 077; set -C; cat > " + shellQuote(file) + " && chmod 600 " + shellQuote(file) + " && sha256sum " + shellQuote(file), input: script) : existing
        let fields = String(decoding: receipt, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(fields.count == 2 && fields[0] == Substring(Self.helperHash) && fields[1] == Substring(file), "Переданный инструмент повреждён")
        return path
    }
    private func cleanup(_ stage: String) {
        _ = try? engine.remote("test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) + " && rm -rf " + shellQuote(stage), timeout: 15)
    }
    private var token: String { engine.remoteLockToken! }
    private func inventory(_ stage: String, cid: String = "-", preflight: SystemInventory? = nil) throws -> SystemInventory {
        let args = preflight.map { ["preflight", cid, token, $0.bootID, $0.layoutHash] } ?? ["inventory", cid, token]
        let data = try engine.remote(scriptCommand(stage, args), timeout: 60)
        try require(data.count <= 131072, "Слишком большой ответ геометрии eMMC")
        let result = try JSONDecoder().decode(SystemInventory.self, from: data)
        try Self.validate(result)
        try require(cid == "-" || cid == result.cid, "Подключён другой модем")
        return result
    }
    private func record(_ title: String, result: String, details: [String: String] = [:]) {
        try? ActivityJournal(root: engine.root).record(operationID: engine.logDirectory.lastPathComponent, category: "system-backup", title: title, result: result, details: details)
    }
    func create(cancelled: @escaping @Sendable () -> Bool = { false }) throws -> SystemBackupItem {
        try locked()
        try require(!Self.hasPendingRestore(root: engine.root), "Сначала завершите незавершённое полное восстановление")
        return try capture(cancelled: cancelled)
    }
    private func capture(expected: SystemInventory? = nil, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> SystemBackupItem {
        try DeviceBackups.checkCancelled(cancelled)
        let id = UUID().uuidString.lowercased(), remote = try stage(id)
        defer { cleanup(remote) }
        let first = try inventory(remote, cid: expected?.cid ?? "-")
        if let expected { try require(first.sameDevice(as: expected) && first.bootID == expected.bootID && first.offline, "Устройство или среда восстановления изменились") }
        let store = Self.rootURL(engine.root)
        try DeviceBackups.directory(store, create: true)
        try require(try spaceAvailable(store) >= first.totalBytes + DeviceBackups.reserveBytes, "Недостаточно места для полного образа eMMC и запаса 64 МиБ")
        let partial = store.appendingPathComponent(".partial-" + id), final = store.appendingPathComponent(id)
        try DeviceBackups.directory(partial, create: true)
        var published = false
        defer { if !published { try? engine.fm.removeItem(at: partial) } }
        record("Создание полной копии eMMC", result: "started")
        var files: [DeviceBackupFile] = []
        var chunks: [SystemRestoreChunk] = []
        for (index, device) in first.devices.enumerated() {
            try DeviceBackups.checkCancelled(cancelled)
            engine.update("Сохраняю полный образ: " + device.name, 0.05 + Double(index) * 0.27)
            let file = partial.appendingPathComponent(device.fileName)
            do {
                let result = try streamer.stream(scriptCommand(remote, ["capture", first.cid, token, device.name]), to: file, maxBytes: device.bytes, timeout: 7200, cancelled: cancelled)
                // A remote receipt declares the sysfs size and hashes the bytes
                // actually sent. Independently count the file here using Int64;
                // embedded wc builds may wrap counters above 4 GiB.
                let checked = try Self.inspectImage(file, device: device, cancelled: cancelled)
                try require(result.bytes == device.bytes && result.bytes == checked.0.bytes && result.sha256 == checked.0.sha256, "Полный образ не прошёл проверку размера и SHA256")
                files.append(DeviceBackupFile(name: device.fileName, source: device.source, bytes: result.bytes, sha256: result.sha256))
                chunks += checked.1
            } catch {
                let received = (try? DeviceBackups.metadata(file)).map { Int64($0.st_size) }
                record("Не удалось сохранить полный образ " + device.name, result: "failed", details: [
                    "target": device.name, "expectedBytes": String(device.bytes),
                    "receivedBytes": received.map(String.init) ?? "unknown", "error": error.localizedDescription
                ])
                let size = received.map { " Получено \($0) из \(device.bytes) байт." } ?? ""
                throw IMEIError.message(device.name + ": " + error.localizedDescription + size)
            }
        }
        let after = try inventory(remote, cid: first.cid)
        try require(first.sameDevice(as: after) && first.bootID == after.bootID && first.offline == after.offline, "Во время копирования изменилось устройство, разметка или загрузка")
        let manifest = SystemBackupManifest(id: id, created: ISO8601DateFormatter().string(from: Date()), inventory: first, capture: first.offline ? "offline" : "live-non-atomic", files: files, chunks: chunks)
        try DeviceBackups.writeJSON(manifest, to: partial.appendingPathComponent("manifest.json"))
        _ = try Self.verifyDirectory(partial, expectedID: id, cancelled: cancelled)
        try Self.syncDirectory(partial)
        try engine.fm.moveItem(at: partial, to: final)
        try Self.syncDirectory(store)
        published = true
        record("Полная копия создана и проверена", result: "completed", details: ["backupID": id, "capture": manifest.capture])
        engine.update("Полная копия eMMC сохранена и проверена", 1)
        return Self.item(manifest, at: final)
    }
    static func manifest(at url: URL, expectedID: String? = nil) throws -> SystemBackupManifest {
        try DeviceBackups.directory(url)
        let manifest = try JSONDecoder().decode(SystemBackupManifest.self, from: DeviceBackups.smallFile(url.appendingPathComponent("manifest.json"), maximum: 2_097_152))
        try require(manifest.schema == 1 && manifest.complete && validID(manifest.id) && manifest.id == (expectedID ?? url.lastPathComponent), "Неверная или незавершённая полная копия")
        try validate(manifest.inventory)
        try require(ISO8601DateFormatter().date(from: manifest.created) != nil && manifest.capture == (manifest.inventory.offline ? "offline" : "live-non-atomic"), "Неверные сведения о снимке")
        try require(manifest.scope.utf8.count <= 4096 && manifest.limitations.utf8.count <= 8192, "Неверное описание снимка")
        try require(manifest.files.map(\.name) == manifest.inventory.devices.map(\.fileName), "Неверный состав полного образа")
        for (file, device) in zip(manifest.files, manifest.inventory.devices) {
            try require(file.source == device.source && file.bytes == device.bytes && DeviceBackups.validHash(file.sha256), "Неверное описание файла образа")
        }
        var index = 0
        for device in manifest.inventory.devices {
            var offset: Int64 = 0
            while offset < device.bytes {
                let length = min(Int64(chunkBytes), device.bytes - offset)
                try require(index < manifest.chunks.count, "Отсутствуют контрольные суммы блоков")
                let chunk = manifest.chunks[index]
                try require(chunk.target == device.name && chunk.offset == offset && chunk.bytes == length && DeviceBackups.validHash(chunk.sha256), "Неверная последовательность блоков образа")
                offset += length; index += 1
            }
        }
        try require(index == manifest.chunks.count, "Лишние блоки в манифесте")
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == Set(manifest.files.map(\.name) + ["manifest.json"]), "В полной копии есть посторонние файлы")
        return manifest
    }
    private static func item(_ manifest: SystemBackupManifest, at url: URL) -> SystemBackupItem {
        SystemBackupItem(id: manifest.id, created: manifest.created, bytes: manifest.inventory.totalBytes, url: url, inventory: manifest.inventory, capture: manifest.capture, scope: manifest.scope)
    }
    static func list(root: URL, onInvalid: (String, String) -> Void = { _, _ in }) throws -> [SystemBackupItem] {
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) != 0 && errno == ENOENT { return [] }
        try DeviceBackups.directory(root)
        let store = rootURL(root)
        if !FileManager.default.fileExists(atPath: store.path) { return [] }
        try DeviceBackups.directory(store)
        let entries = try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil).filter { validID($0.lastPathComponent) }
        var items: [SystemBackupItem] = []
        for entry in entries {
            do { items.append(item(try manifest(at: entry), at: entry)) }
            catch { onInvalid(entry.lastPathComponent, error.localizedDescription) }
        }
        return items.sorted { $0.created > $1.created }
    }
    private static func inspectImage(_ url: URL, device: SystemBackupDevice, cancelled: @Sendable () -> Bool = { false }) throws -> (BackupStreamResult, [SystemRestoreChunk]) {
        let input = try DeviceBackups.openFile(url)
        defer { try? input.close() }
        var hash = SHA256(), offset: Int64 = 0
        var chunks: [SystemRestoreChunk] = []
        while offset < device.bytes {
            try DeviceBackups.checkCancelled(cancelled)
            let length = Int(min(Int64(chunkBytes), device.bytes - offset))
            let data = try input.read(upToCount: length) ?? Data()
            try require(data.count == length, "Полный образ обрезан: " + device.fileName)
            hash.update(data: data)
            chunks.append(SystemRestoreChunk(target: device.name, offset: offset, bytes: Int64(length), sha256: digest(data)))
            offset += Int64(length)
        }
        try require((try input.read(upToCount: 1) ?? Data()).isEmpty, "Слишком большой полный образ")
        return (BackupStreamResult(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: offset), chunks)
    }
    private static func verifyImages(_ manifest: SystemBackupManifest, at url: URL, cancelled: @Sendable () -> Bool = { false }) throws {
        var allChunks: [SystemRestoreChunk] = []
        for (file, device) in zip(manifest.files, manifest.inventory.devices) {
            let result = try inspectImage(url.appendingPathComponent(file.name), device: device, cancelled: cancelled)
            try require(result.0.bytes == file.bytes && result.0.sha256 == file.sha256, "Повреждён полный образ: " + file.name)
            allChunks += result.1
        }
        try require(allChunks == manifest.chunks, "Контрольные суммы блоков образа не совпали")
    }
    private static func verifyDirectory(_ url: URL, expectedID: String? = nil, cancelled: @Sendable () -> Bool = { false }) throws -> SystemBackupItem {
        let manifest = try manifest(at: url, expectedID: expectedID)
        try verifyImages(manifest, at: url, cancelled: cancelled)
        return item(manifest, at: url)
    }
    static func verify(_ item: SystemBackupItem, cancelled: @Sendable () -> Bool = { false }) throws -> SystemBackupItem {
        try verifyDirectory(item.url, expectedID: item.id, cancelled: cancelled)
    }
    private static func copy(_ item: SystemBackupItem, to destination: URL, cancelled: @Sendable () -> Bool) throws -> SystemBackupItem {
        let source = try verify(item, cancelled: cancelled)
        let meta = try DeviceBackups.metadata(destination)
        try require(meta.st_mode & S_IFMT == S_IFDIR && meta.st_uid == getuid(), "Выберите папку владельца без символической ссылки")
        try require(try DeviceBackups.freeBytes(at: destination) >= source.bytes + DeviceBackups.reserveBytes, "Недостаточно места для полной копии")
        let partial = destination.appendingPathComponent(".partial-" + UUID().uuidString.lowercased()), final = destination.appendingPathComponent(source.id)
        var existing = stat()
        try require(lstat(final.path, &existing) != 0 && errno == ENOENT, "Полная копия с таким ID уже существует")
        try DeviceBackups.directory(partial, create: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: partial) } }
        for name in targetNames.map({ $0 + ".bin" }) + ["manifest.json"] {
            let input = try DeviceBackups.openFile(source.url.appendingPathComponent(name))
            defer { try? input.close() }
            let output = try DeviceBackups.createFile(partial.appendingPathComponent(name))
            defer { try? output.close() }
            while true {
                try DeviceBackups.checkCancelled(cancelled)
                let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        }
        let verified = try verifyDirectory(partial, expectedID: source.id, cancelled: cancelled)
        try syncDirectory(partial)
        try FileManager.default.moveItem(at: partial, to: final)
        try syncDirectory(destination)
        published = true
        var result = verified; result.url = final
        return result
    }
    static func importBackup(from url: URL, root: URL, cancelled: @Sendable () -> Bool = { false }) throws -> SystemBackupItem {
        try DeviceBackups.directory(root)
        let source = try verifyDirectory(url, cancelled: cancelled), store = rootURL(root)
        try DeviceBackups.directory(store, create: true)
        return try copy(source, to: store, cancelled: cancelled)
    }
    static func export(_ item: SystemBackupItem, to directory: URL, cancelled: @Sendable () -> Bool = { false }) throws -> URL {
        try copy(item, to: directory, cancelled: cancelled).url
    }
    private var transactionStore: URL { engine.root.appendingPathComponent("SystemRestoreTransactions", isDirectory: true) }
    private var pendingURL: URL { engine.root.appendingPathComponent(Self.pendingName) }
    /// Atomic replace + fsync both the file and containing directory. A saved
    /// offset always denotes an independently reread, verified remote chunk.
    static func durableJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try DeviceBackups.directory(url.deletingLastPathComponent())
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            try require(existing.st_mode & S_IFMT == S_IFREG && existing.st_uid == getuid() && existing.st_mode & 0o777 == 0o600, "Небезопасный журнал восстановления")
        } else { try require(errno == ENOENT, "Не удалось проверить журнал") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".journal-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temp) }
        try DeviceBackups.writeJSON(value, to: temp)
        try require(rename(temp.path, url.path) == 0, "Не удалось сохранить журнал восстановления")
        try syncDirectory(url.deletingLastPathComponent())
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(fd >= 0, "Не удалось синхронизировать папку журнала")
        defer { close(fd) }
        try require(fsync(fd) == 0, "Не удалось синхронизировать журнал восстановления")
    }
    private func transaction(_ id: String) throws -> SystemRestoreTransaction {
        try require(Self.validID(id), "Неверный ID журнала восстановления")
        try DeviceBackups.directory(transactionStore)
        let value = try JSONDecoder().decode(SystemRestoreTransaction.self, from: DeviceBackups.smallFile(transactionStore.appendingPathComponent(id + ".json"), maximum: 2_097_152))
        try require(value.schema == 1 && value.id == id && Self.validID(value.backupID) && Self.validID(value.beforeBackupID) && DeviceBackups.validHash(value.backupManifestHash), "Повреждён журнал восстановления")
        try Self.validate(value.inventory)
        try require(value.inventory.offline && value.chunks.count <= 4096, "Неверная среда или размер журнала")
        try require(value.previousBootIDs.count <= 128 && value.previousBootIDs.allSatisfy(Self.validID), "Повреждена история загрузок восстановления")
        return value
    }
    private func pendingID() throws -> String? {
        guard Self.hasPendingRestore(root: engine.root) else { return nil }
        let values = try JSONDecoder().decode([String: String].self, from: DeviceBackups.smallFile(pendingURL, maximum: 4096))
        try require(values.count == 1 && Self.validID(values["id"] ?? ""), "Повреждён указатель восстановления")
        return values["id"]!
    }
    func prepareRestore(_ item: SystemBackupItem) throws -> SystemRestorePlan {
        try locked()
        let pending = try pendingID()
        let id = pending ?? UUID().uuidString.lowercased(), remote = try stage(id)
        defer { if pending == nil { cleanup(remote) } }
        if pending != nil { try relock(remote, transaction(id).inventory.cid) }
        let checked = try Self.verify(item)
        let current = try inventory(remote, cid: checked.inventory.cid)
        try require(current.sameDevice(as: checked.inventory), "CID, размер или разметка модема не совпадают с полной копией")
        if pending != nil {
            let saved = try transaction(id)
            try require(saved.backupID == checked.id && saved.inventory.sameDevice(as: current), "Журнал относится к другой копии или устройству")
        }
        return SystemRestorePlan(id: id, backup: checked, inventory: current, isResume: pending != nil)
    }
    static func parseChunkReceipt(_ data: Data) throws -> SystemRestoreChunk {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        try require(lines.count == 1, "Неоднозначное подтверждение блока восстановления")
        let fields = lines[0].split(separator: " ")
        try require(fields.count == 5 && fields[0] == "RESTORE_RESULT" && fields[1].hasPrefix("target=") && fields[2].hasPrefix("offset=") && fields[3].hasPrefix("bytes=") && fields[4].hasPrefix("sha256="), "Неверный ответ проверки блока")
        let target = String(fields[1].dropFirst(7)), rawOffset = String(fields[2].dropFirst(7)), rawBytes = String(fields[3].dropFirst(6)), hash = String(fields[4].dropFirst(7))
        try require(Self.targetNames.contains(target) && rawOffset.utf8.allSatisfy { (48...57).contains($0) } && rawBytes.utf8.allSatisfy { (48...57).contains($0) } && DeviceBackups.validHash(hash), "Неверное описание проверенного блока")
        guard let offset = Int64(rawOffset), let bytes = Int64(rawBytes), offset >= 0, offset % 512 == 0, bytes > 0, bytes <= chunkBytes, bytes % 512 == 0 else { throw IMEIError.message("Неверные границы блока") }
        return SystemRestoreChunk(target: target, offset: offset, bytes: bytes, sha256: hash)
    }
    private func remoteHash(_ stage: String, _ inventory: SystemInventory, _ chunk: SystemRestoreChunk) throws -> SystemRestoreChunk {
        let result = try Self.parseChunkReceipt(engine.remote(scriptCommand(stage, ["hash-chunk", inventory.cid, token, inventory.bootID, inventory.layoutHash, chunk.target, String(chunk.offset), String(chunk.bytes)]), timeout: 180))
        try require(result.target == chunk.target && result.offset == chunk.offset && result.bytes == chunk.bytes, "Проверен другой блок устройства")
        return result
    }
    private func relock(_ stage: String, _ cid: String) throws {
        let response = try engine.remote(scriptCommand(stage, ["relock", cid, token]), timeout: 30)
        try require(String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "SYSTEM_RELOCKED", "Не подтверждено восстановление защитных настроек")
    }
    func restore(_ plan: SystemRestorePlan, allowLiveCapture: Bool = false) throws -> SystemRestoreResult {
        try locked()
        try require(Self.validID(plan.id), "Неверный ID плана восстановления")
        let pending = try pendingID()
        if let pending { try require(pending == plan.id, "Уже начата другая операция восстановления") }
        let remote = try stage(plan.id)
        if pending != nil { try relock(remote, transaction(plan.id).inventory.cid) }
        let sourceManifest = try Self.manifest(at: plan.backup.url, expectedID: plan.backup.id)
        try Self.verifyImages(sourceManifest, at: plan.backup.url) // All hashes are checked before any write.
        let source = Self.item(sourceManifest, at: plan.backup.url)
        try require(!source.isLiveCapture || allowLiveCapture, "Подтвердите восстановление неатомарного снимка работающего модема")
        var completed = false
        defer { if completed { cleanup(remote) } }
        let current = try inventory(remote, cid: source.inventory.cid, preflight: plan.inventory)
        try require(current.offline && current.sameDevice(as: source.inventory) && current.sameDevice(as: plan.inventory) && current.bootID == plan.inventory.bootID, "Полное восстановление требует неизменной отдельной среды в RAM и остановленного модема")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceHash = digest(try encoder.encode(sourceManifest))
        try DeviceBackups.directory(transactionStore, create: true)
        var saved: SystemRestoreTransaction
        if let pending {
            try require(pending == plan.id, "Уже начата другая операция восстановления")
            saved = try transaction(pending)
            try require(saved.backupID == source.id && saved.backupManifestHash == sourceHash && saved.inventory.sameDevice(as: current), "Изменились исходная копия или устройство восстановления")
            let before = try Self.verifyDirectory(Self.rootURL(engine.root).appendingPathComponent(saved.beforeBackupID))
            let originalBoot = saved.previousBootIDs.first ?? saved.inventory.bootID
            try require(before.inventory.sameDevice(as: current) && before.inventory.bootID == originalBoot && !before.isLiveCapture, "Нет проверенной исходной копии перед восстановлением")
        } else {
            try require(!plan.isResume, "Журнал продолжения восстановления отсутствует")
            engine.update("Создаю обязательную полную копию перед восстановлением", 0.02)
            let before = try capture(expected: current)
            saved = SystemRestoreTransaction(id: plan.id, backupID: source.id, backupManifestHash: sourceHash, inventory: current, beforeBackupID: before.id, chunks: [], complete: false)
            try Self.durableJSON(saved, to: transactionStore.appendingPathComponent(plan.id + ".json"))
            try Self.durableJSON(["id": plan.id], to: pendingURL)
        }
        do {
            try require(saved.chunks.count <= sourceManifest.chunks.count && Array(sourceManifest.chunks.prefix(saved.chunks.count)) == saved.chunks, "Неверная последовательность блоков журнала")
            if saved.inventory.bootID != current.bootID {
                // A new RAM recovery boot may resume only after the entire
                // acknowledged prefix has been reread on this physical device.
                for chunk in saved.chunks {
                    try require(try remoteHash(remote, current, chunk) == chunk, "Ранее записанный блок изменился после перезагрузки; требуется ручное восстановление")
                }
                saved.previousBootIDs.append(saved.inventory.bootID)
                saved.inventory = current
                try Self.durableJSON(saved, to: transactionStore.appendingPathComponent(plan.id + ".json"))
            }
            var chunkIndex = 0
            var written: Int64 = 0
            // Also reread previously verified chunks on resume. Never trust an
            // offset alone, nor assume a lost SSH reply means a failed write.
            for device in source.inventory.devices {
                let input = try DeviceBackups.openFile(source.url.appendingPathComponent(device.fileName))
                defer { try? input.close() }
                var offset: Int64 = 0
                while offset < device.bytes {
                    let length = Int(min(Int64(Self.chunkBytes), device.bytes - offset))
                    let data = try input.read(upToCount: length) ?? Data()
                    try require(data.count == length, "Исходный образ изменился или обрезан")
                    let expected = SystemRestoreChunk(target: device.name, offset: offset, bytes: Int64(length), sha256: digest(data))
                    try require(expected == sourceManifest.chunks[chunkIndex], "Исходный блок изменился после проверки; запись остановлена")
                    let observed = try remoteHash(remote, current, expected)
                    if chunkIndex < saved.chunks.count {
                        try require(saved.chunks[chunkIndex] == expected && observed == expected, "Ранее проверенный блок изменился; автоматическое продолжение остановлено")
                    } else {
                        if observed != expected {
                            let chunkFile = remote + "/chunk.bin"
                            let upload = try engine.remote("umask 077; test ! -L " + shellQuote(chunkFile) + "; cat > " + shellQuote(chunkFile) + " && sha256sum " + shellQuote(chunkFile), input: data, timeout: 180)
                            let fields = String(decoding: upload, as: UTF8.self).split(whereSeparator: \.isWhitespace)
                            try require(fields.count == 2 && fields[0] == Substring(expected.sha256) && fields[1] == Substring(chunkFile), "Переданный блок повреждён")
                            let receipt = try Self.parseChunkReceipt(engine.remote(scriptCommand(remote, ["restore-chunk", current.cid, token, current.bootID, current.layoutHash, device.name, String(offset), String(length), expected.sha256, chunkFile]), timeout: 300))
                            try require(receipt == expected, "Запись блока не подтверждена")
                            try require(try remoteHash(remote, current, expected) == expected, "Повторная проверка записанного блока не совпала")
                        }
                        try relock(remote, current.cid)
                        saved.chunks.append(expected)
                        try Self.durableJSON(saved, to: transactionStore.appendingPathComponent(plan.id + ".json"))
                    }
                    chunkIndex += 1
                    offset += Int64(length)
                    written += Int64(length)
                    engine.update("Восстановление и проверка " + device.name, Double(written) / Double(source.bytes))
                }
                try require((try input.read(upToCount: 1) ?? Data()).isEmpty, "Исходный образ увеличился во время восстановления")
            }
            try require(saved.chunks.count == chunkIndex, "В журнале присутствуют лишние блоки")
            for file in sourceManifest.files {
                let target = String(file.name.dropLast(4))
                let data = try engine.remote(scriptCommand(remote, ["hash-device", current.cid, token, current.bootID, current.layoutHash, target]), timeout: 7200)
                let expected = "SYSTEM_HASH target=\(target) bytes=\(file.bytes) sha256=\(file.sha256)"
                try require(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected, "Итоговая SHA256 всей области eMMC не совпала: " + target)
            }
            try relock(remote, current.cid)
            saved.complete = true
            try Self.durableJSON(saved, to: transactionStore.appendingPathComponent(plan.id + ".json"))
            try engine.fm.removeItem(at: pendingURL)
            let directoryFD = open(engine.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            try require(directoryFD >= 0, "Не удалось синхронизировать завершение восстановления")
            let syncResult = fsync(directoryFD); close(directoryFD)
            try require(syncResult == 0, "Не удалось сохранить завершение восстановления")
            completed = true
            record("Восстановление проверено; восстановление защитных настроек завершено", result: "completed", details: ["transactionID": plan.id, "beforeBackupID": saved.beforeBackupID])
            return SystemRestoreResult(transactionID: plan.id, beforeBackupID: saved.beforeBackupID, bytes: written, resumed: pending != nil)
        } catch {
            do { try relock(remote, current.cid) }
            catch { throw IMEIError.message("Восстановление остановлено, журнал сохранён. Не удалось подтвердить восстановление защитных настроек: " + error.localizedDescription) }
            record("Полное восстановление прервано; журнал сохранён", result: "failed", details: ["transactionID": plan.id])
            throw error
        }
    }
}
