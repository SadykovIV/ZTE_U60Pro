import Foundation
import Darwin

struct FirmwareSupportFile: Codable, Equatable, Sendable {
    let id: String
    let status: String
    let bytes: Int64?
    let sha256: String?
    let uid: UInt32?
    let mode: String?
    let links: UInt32?
}

struct FirmwareSupportSnapshot: Codable, Equatable, Sendable {
    let facts: [String: String]
    let files: [FirmwareSupportFile]
}

struct FirmwareSupportResult: Sendable {
    let url: URL
    let complete: Bool
    let fileCount: Int
    let omissions: Int
    let sha256: String
}

/// Explicit, read-only export. It never loads an NV helper, agent credentials,
/// firmware allowlist, remote lock, or a fallback transport.
final class FirmwareSupportCollector {
    static let helperSHA256 = "0b041b33cdd3879d8245375c9126eb4a9b8d2e60038bae6c6041da79406dbbc6"
    static let requiredIDs = ["ui", "english", "chinese", "init"]
    static let allIDs = requiredIDs + ["original_ui", "original_english", "original_chinese", "original_init"]
    static let sources = ["ui": "/usr/bin/zte_topsw_devui", "english": "/usr/ui/language/English.ini", "chinese": "/usr/ui/language/Chinese.ini", "init": "/etc/init.d/zte_topsw_devui",
        "original_ui": "/data/zte-imei-screen-ru/backup/zte_topsw_devui", "original_english": "/data/zte-imei-screen-ru/backup/English.ini", "original_chinese": "/data/zte-imei-screen-ru/backup/Chinese.ini", "original_init": "/data/zte-imei-screen-ru/backup/zte_topsw_devui.init"]
    static let factKeys: Set<String> = ["uid", "os", "architecture", "firmware", "inner", "openwrt_version", "target", "agent_present", "agent_sha256", "agent_running_count", "agent_mode", "agent_mapped_matches_disk", "http_health_status", "http_capabilities_status", "http_dashboard_status", "ui_mounts"]
    static let metadataLimit = 65_536
    static let totalLimit: Int64 = 600 * 1024 * 1024
    static func limit(_ id: String) -> Int64 {
        switch id.replacingOccurrences(of: "original_", with: "") {
        case "ui": return 256 * 1024 * 1024
        case "english", "chinese": return 16 * 1024 * 1024
        case "init": return 4 * 1024 * 1024
        default: return 0
        }
    }
    let root: URL, resources: URL, connection: Connection
    let selectedProof: SSHReadProof
    let remote: RemoteTransport
    let streamer: BackupStreamTransport
    let secrets: [String]
    let selectionIsCurrent: @Sendable () -> Bool
    let update: @Sendable (String, Double) -> Void

    init(root: URL, resources: URL, connection: Connection, session: ReadOnlyChannelSession,
         remote: RemoteTransport? = nil, streamer: BackupStreamTransport? = nil, secrets: [String] = [],
         selectionIsCurrent: @escaping @Sendable () -> Bool = { true },
         update: @escaping @Sendable (String, Double) -> Void = { _, _ in }) throws {
        try require(session.mode == .ssh && session.diagnosticSession?.transport == "ssh" &&
                    session.sshEndpoint == ConnectionRouter.sshEndpoint(connection), "Для сбора данных требуется выбранное SSH-подключение")
        guard let proof = session.diagnosticSession?.readProof else { throw IMEIError.message("Для сбора данных требуется выбранное SSH-подключение") }
        self.root = root; self.resources = resources; self.connection = connection; self.selectedProof = proof
        self.remote = remote ?? SSHTransport(connection); self.streamer = streamer ?? SSHBackupStreamTransport(connection)
        self.secrets = secrets; self.selectionIsCurrent = selectionIsCurrent; self.update = update
    }

    static func parseSnapshot(_ data: Data) throws -> FirmwareSupportSnapshot {
        let invalid = "Некорректный ответ сбора данных для адаптации"
        try require(data.count <= metadataLimit && !data.contains(0), invalid)
        guard let text = String(data: data, encoding: .utf8) else { throw IMEIError.message(invalid) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines.last == "" ? Array(lines.dropLast()) : lines
        try require(body.first == "FIRMWARE_SUPPORT_V1" && body.last == "FIRMWARE_SUPPORT_END", invalid)
        var facts = [String: String](), files = [String: FirmwareSupportFile]()
        for line in body.dropFirst().dropLast() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "FACT" {
                try require(parts.count == 3 && factKeys.contains(parts[1]) && facts[parts[1]] == nil, invalid)
                guard let decoded = Data(base64Encoded: parts[2]), decoded.base64EncodedString() == parts[2],
                      let value = String(data: decoded, encoding: .utf8), decoded.count <= 4096,
                      !decoded.contains(where: { $0 < 32 || $0 == 127 }) else { throw IMEIError.message(invalid) }
                try require(validFact(parts[1], value), invalid)
                facts[parts[1]] = value
            } else if parts.first == "FILE" {
                try require(parts.count == 8 && allIDs.contains(parts[1]) && files[parts[1]] == nil, invalid)
                let id = parts[1], status = parts[2]
                try require(["present", "missing", "not_assessed", "symlink", "not_regular", "unreadable", "empty"].contains(status), invalid)
                if status == "present" {
                    guard let bytes = Int64(parts[3]), String(bytes) == parts[3], bytes > 0,
                          DeviceBackups.validHash(parts[4]), let uid = UInt32(parts[5]), String(uid) == parts[5],
                          parts[6].range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil,
                          let links = UInt32(parts[7]), String(links) == parts[7], links > 0 else { throw IMEIError.message(invalid) }
                    files[id] = FirmwareSupportFile(id: id, status: status, bytes: bytes, sha256: parts[4], uid: uid, mode: parts[6], links: links)
                } else {
                    try require(parts[3...].allSatisfy { $0 == "-" }, invalid)
                    files[id] = FirmwareSupportFile(id: id, status: status, bytes: nil, sha256: nil, uid: nil, mode: nil, links: nil)
                }
            } else { throw IMEIError.message(invalid) }
        }
        try require(Set(files.keys) == Set(allIDs) && Set(facts.keys) == factKeys, invalid)
        return FirmwareSupportSnapshot(facts: facts, files: allIDs.map { files[$0]! })
    }

    private static func validFact(_ key: String, _ value: String) -> Bool {
        if value == "not_assessed" { return true }
        switch key {
        case "uid", "agent_running_count", "ui_mounts":
            return value.range(of: #"^(0|[1-9][0-9]{0,9})$"#, options: .regularExpression) != nil
        case "agent_present": return ["0", "1"].contains(value)
        case "agent_sha256": return DeviceBackups.validHash(value)
        case "agent_mode": return ["normal", "discovery", "default", "ambiguous", "unknown"].contains(value)
        case "agent_mapped_matches_disk": return ["yes", "no"].contains(value)
        case "http_health_status", "http_capabilities_status", "http_dashboard_status":
            return value.range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil
        default: return value.range(of: #"^[A-Za-z0-9._/ -]{1,256}$"#, options: .regularExpression) != nil
        }
    }

    private func quickProof() throws -> SSHReadProof {
        do {
            let reply = try remote.run(SSHReadProof.quickCommand, input: nil, timeout: 30)
            try require(reply.status == 0, "Проверка выбранного SSH-сеанса не завершена")
            return try SSHReadProof.parse(reply.stdout)
        } catch { throw IMEIError.message("Проверка выбранного SSH-сеанса не завершена; архив не сохранён") }
    }
    private func inspect(_ helper: Data) throws -> FirmwareSupportSnapshot {
        do {
            let reply = try remote.run("sh -s -- inspect " + shellQuote(connection.host), input: helper, timeout: 90)
            try require(reply.status == 0, "Сбор технических сведений не завершён")
            return try Self.parseSnapshot(reply.stdout)
        } catch { throw IMEIError.message("Сбор технических сведений не завершён; архив не сохранён") }
    }
    private func helper() throws -> Data {
        let directory = resources.appendingPathComponent("FirmwareSupport")
        let data = try DeviceBackups.smallFile(directory.appendingPathComponent("collect.sh"), maximum: 128 * 1024, publicResource: true)
        let manifest = try readJSON([String: String].self, directory.appendingPathComponent("SHA256.json"))
        try require(digest(data) == Self.helperSHA256 && manifest["collect.sh"] == Self.helperSHA256,
                    "Повреждён встроенный сборщик данных для адаптации")
        return data
    }

    func collect(to destination: URL, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> FirmwareSupportResult {
        let started = ISO8601DateFormatter().string(from: Date())
        try connection.validate()
        let script = try helper()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("zte-firmware-support-" + UUID().uuidString.lowercased())
        try secureDirectory(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = work.appendingPathComponent("ZTE-Firmware-Support"), filesRoot = folder.appendingPathComponent("files")
        try secureDirectory(filesRoot)
        func checkCancelled() throws { try require(!cancelled(), "Сбор данных для адаптации отменён") }
        try checkCancelled()
        update("Читаю сведения выбранного SSH-сеанса…", 0.05)
        let beforeProof = try quickProof()
        // The selected session may predate the quick-proof format. Compare only
        // fields this lightweight read observes; this export grants no writes.
        let selectedQuick = SSHReadProof(uid: selectedProof.uid, system: selectedProof.system, architecture: selectedProof.architecture, cid: selectedProof.cid, bootID: selectedProof.bootID)
        try selectedQuick.verify(beforeProof)
        let before = try inspect(script)
        var entries = [[String: String]](), total: Int64 = 0
        let present = before.files.filter { $0.status == "present" && ($0.bytes ?? Int64.max) <= Self.limit($0.id) }
        for (index, item) in present.enumerated() {
            try checkCancelled()
            update("Читаю экранные файлы для адаптации…", 0.15 + 0.6 * Double(index) / Double(max(1, present.count)))
            let path = filesRoot.appendingPathComponent(item.id)
            let command = "sh -s -- file " + [item.id, String(item.bytes!), item.sha256!].map(shellQuote).joined(separator: " ")
            let result: BackupStreamResult
            do { result = try streamer.stream(command, input: script, to: path, maxBytes: Self.limit(item.id), timeout: 180, cancelled: cancelled) }
            catch { try checkCancelled(); throw IMEIError.message("Передача экранного файла не подтверждена; архив не сохранён") }
            let local = try DeviceBackups.hashFile(path, cancelled: cancelled)
            try require(result.bytes == item.bytes && result.sha256 == item.sha256 && local.bytes == item.bytes && local.sha256 == item.sha256,
                        "Контрольная сумма экранного файла не совпала; архив не сохранён")
            total += local.bytes
            try require(total <= Self.totalLimit, "Данные для адаптации превышают допустимый размер")
            entries.append(["path": "files/" + item.id, "sha256": local.sha256, "bytes": String(local.bytes)])
        }
        try checkCancelled()
        update("Проверяю неизменность файлов и SSH-сеанса…", 0.8)
        let after = try inspect(script), afterProof = try quickProof()
        try beforeProof.verify(afterProof)
        try selectedQuick.verify(afterProof)
        try require(before.files == after.files, "Экранные файлы изменились во время чтения; архив не сохранён")
        for key in ["uid", "os", "architecture", "firmware", "inner", "openwrt_version", "target"] {
            try require(before.facts[key] == after.facts[key], "Система изменилась во время чтения; архив не сохранён")
        }
        let omissions = before.files.filter { $0.status != "present" || ($0.bytes ?? Int64.max) > Self.limit($0.id) }
        let missing = omissions.filter { Self.requiredIDs.contains($0.id) }
        let complete = missing.isEmpty
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func add(_ data: Data, _ name: String) throws {
            try savePrivate(data, folder.appendingPathComponent(name))
            entries.append(["path": name, "sha256": digest(data), "bytes": String(data.count)])
        }
        var elf = [String: [String: String]]()
        for id in ["ui", "original_ui"] where present.contains(where: { $0.id == id }) {
            let file = try DeviceBackups.openFile(filesRoot.appendingPathComponent(id)); defer { try? file.close() }
            elf[id] = Self.elfMetadata(try file.read(upToCount: 64) ?? Data())
        }
        let binding = beforeProof.cid != nil && beforeProof.bootID != nil ? "full" : (beforeProof.cid != nil || beforeProof.bootID != nil ? "partial" : "transport-only")
        let metadata: [String: Any] = ["schema": 1, "applicationVersion": DiagnosticsContext.version, "applicationBuild": DiagnosticsContext.build,
            "startedAt": started, "finishedAt": ISO8601DateFormatter().string(from: Date()), "complete": complete, "writeAuthorization": "none", "elf": elf,
            "transport": "ssh", "helperSHA256": Self.helperSHA256, "sources": Self.sources, "bindingStrength": binding,
            "continuity": ["selectedSSH": true, "observedFactsStable": true, "identityStable": binding == "full", "cidCompared": beforeProof.cid != nil, "bootCompared": beforeProof.bootID != nil,
                           "filesCompared": true, "firmwareCompared": before.facts["firmware"] != "not_assessed" && before.facts["inner"] != "not_assessed"],
            "before": try JSONSerialization.jsonObject(with: encoder.encode(before)),
            "after": try JSONSerialization.jsonObject(with: encoder.encode(after)), "missingRequired": missing.map(\.id),
            "omissions": omissions.map { ["id": $0.id, "reason": $0.status == "present" ? "over_limit" : $0.status] }]
        try add(JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]), "metadata.json")
        try add(Self.activityPayload(root: root, secrets: secrets), "activities.jsonl")
        try add(Data("""
        Firmware adaptation data / Данные для адаптации прошивки
        Complete: \(complete). Required files: ui, english, chinese, init.
        Missing or inaccessible files are listed in metadata.json. An incomplete
        archive does not prove compatibility or authorize installation.
        File bytes are unchanged. Original_* files are included only when a
        verified localization backup is available. Current files may be mounted
        localized copies; consult ui_mounts and original_* before patch analysis.
        Only fixed screen files, projected safe metadata and sanitized activity
        events are included. No agent startup/password, configuration, NV, SIM
        profiles or complete firmware image is collected. No device changes.
        SSH continuity compares available observations; unavailable CID or boot
        stays unavailable, and no device identifier is included in this metadata.
        Agent/HTTP states are observations, not a firmware compatibility claim.
        The activity log can contain events from earlier sessions. Details and
        raw commands are omitted. Files may be copyrighted by their vendor:
        share privately for diagnosis, do not redistribute as application assets.
        The archive is saved locally and is not automatically uploaded.
        """.utf8), "README.txt")
        try add(JSONSerialization.data(withJSONObject: ["schema": 1, "files": entries], options: [.prettyPrinted, .sortedKeys]), "manifest.json")
        try checkCancelled()
        let zip = work.appendingPathComponent("support.zip"), runner = HostProcessRunner()
        let packed = try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", folder.path, zip.path], timeout: 180)
        try require(packed.status == 0, "Не удалось создать архив данных для адаптации")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
        let checked = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-tq", zip.path], timeout: 90)
        try require(checked.status == 0, "Архив данных для адаптации не прошёл проверку целостности")
        try checkCancelled()
        let hash = try DeviceBackups.hashFile(zip, cancelled: cancelled)
        try Self.publish(zip, to: destination, expected: hash, cancelled: cancelled, selectionIsCurrent: selectionIsCurrent)
        return FirmwareSupportResult(url: destination, complete: complete, fileCount: present.count, omissions: missing.count, sha256: hash.sha256)
    }

    static func elfMetadata(_ data: Data) -> [String: String] {
        let bytes = Array(data)
        guard bytes.count >= 20, Array(bytes.prefix(4)) == [127, 69, 76, 70], [1, 2].contains(bytes[4]), [1, 2].contains(bytes[5]) else {
            return ["status": "not_assessed"]
        }
        func word(_ index: Int) -> Int { bytes[5] == 1 ? Int(bytes[index]) + 256 * Int(bytes[index + 1]) : 256 * Int(bytes[index]) + Int(bytes[index + 1]) }
        return ["status": "known", "class": bytes[4] == 1 ? "32" : "64", "byteOrder": bytes[5] == 1 ? "little" : "big", "type": String(word(16)), "machine": String(word(18))]
    }

    static func activityPayload(root: URL, secrets: [String]) -> Data {
        let directory = root.appendingPathComponent("Activity")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl$"#, options: .regularExpression) != nil }.sorted(by: >).prefix(2)
        var events = [ActivityEvent]()
        for name in names {
            guard let (data, _) = try? DiagnosticArchive.readRegular(root: root, relative: "Activity/" + name, limit: 2 * 1024 * 1024) else { continue }
            events.append(contentsOf: data.split(separator: 10).suffix(500).compactMap { try? JSONDecoder().decode(ActivityEvent.self, from: Data($0)) })
        }
        let redactor = ResearchRedactor(secrets: secrets)
        func clean(_ value: String) -> String {
            let text = redactor.clean(value)
                .replacingOccurrences(of: #"(?i)\b(?:https?|ftp|ssh|socks[45]?)://[^\s\"<>]+"#, with: "[url-redacted]", options: .regularExpression)
                .replacingOccurrences(of: #"(?im)^.*(?:\bLPA\s*:|activation|confirmation|matching[_ -]?id|sm[-_ ]?dp).*$"#, with: "[private-data-redacted]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\b[0-9a-f]{32}\b"#, with: "[identifier-redacted]", options: .regularExpression)
            return String(text.prefix(1024))
        }
        var output = Data()
        for event in events.sorted(by: { $0.timestamp > $1.timestamp }).prefix(500).reversed() {
            let value = ["timestamp": clean(event.timestamp), "category": clean(event.category), "title": clean(event.title), "result": clean(event.result)]
            guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), output.count + encoded.count < 1_048_576 else { continue }
            output.append(encoded); output.append(10)
        }
        return output
    }

    private static func publish(_ source: URL, to destination: URL, expected: BackupStreamResult, cancelled: @escaping @Sendable () -> Bool, selectionIsCurrent: @Sendable () -> Bool) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".zte-support-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = try DeviceBackups.openFile(source), output = try DeviceBackups.createFile(temp)
        defer { try? input.close(); try? output.close() }
        while true {
            try require(!cancelled(), "Сбор данных для адаптации отменён")
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }; try output.write(contentsOf: data)
        }
        try output.synchronize(); try output.close()
        let saved = try DeviceBackups.hashFile(temp, cancelled: cancelled)
        try require(saved.bytes == expected.bytes && saved.sha256 == expected.sha256, "Архив данных для адаптации не прошёл проверку целостности")
        try require(selectionIsCurrent(), "Параметры SSH изменились. Подключитесь заново.")
        try require(rename(temp.path, destination.path) == 0, "Не удалось сохранить архив данных для адаптации")
    }
}
