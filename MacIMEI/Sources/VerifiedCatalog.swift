import Foundation
import CryptoKit
import Combine

struct CatalogLocalizedText: Codable, Sendable {
    let ru: String
    let en: String
    func text(language: String) -> String { language.lowercased().hasPrefix("en") ? en : ru }
}
struct CatalogVerification: Codable, Sendable {
    let date: String, result: String, level: String, evidence: String, evidenceSHA256: String
    let summary: CatalogLocalizedText
}
struct VerifiedCatalogEntry: Codable, Identifiable, Sendable {
    let id: String, name: String, version: String, installerID: String
    let description: CatalogLocalizedText
    let firmware: [String], architecture: [String], openwrt: [String]
    let verification: CatalogVerification
    func description(language: String) -> String { description.text(language: language) }
}
struct VerifiedCatalogDocument: Codable, Sendable {
    let schemaVersion: Int, revision: Int
    let issuedAt: String, minimumManagerVersion: String
    let apps: [VerifiedCatalogEntry]
}
struct VerifiedCatalogEnvelope: Codable, Sendable {
    let payload: String, signature: String
}
enum VerifiedCatalogFailure: Error, LocalizedError {
    case invalid(String), notPublished, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Каталог отклонён: " + reason
        case .notPublished: return "Обновление каталога ещё не опубликовано. Сохранён проверенный локальный список."
        case .unavailable: return "Не удалось получить каталог. Сохранён проверенный локальный список."
        }
    }
}

/// Signed metadata can approve or withdraw a compiled installer. It cannot supply
/// commands, executable URLs, arbitrary versions, or bypass the device guards.
enum VerifiedCatalogPolicy {
    static let managerVersion = "1.20.0"
    static let endpoint = URL(string: "https://raw.githubusercontent.com/SadykovIV/ZTE_U60Pro/main/Catalog/verified-apps.json")!
    static let signatureEndpoint = URL(string: "https://raw.githubusercontent.com/SadykovIV/ZTE_U60Pro/main/Catalog/verified-apps.sig")!
    static let maxPayloadBytes = 131_072
    static let maxCacheBytes = 180_000
    static let publicKeyBase64 = "BMUqXhjGxY7o6keBHS1qOvTY7QR67c8mR+KHclTf8ut9LiHf3SHHqTgG4PRTPY9ILJvw06jSx4m7jJIUK7flva4="
    static let baselinePayload = "ewogICJzY2hlbWFWZXJzaW9uIjogMSwKICAicmV2aXNpb24iOiAxLAogICJpc3N1ZWRBdCI6ICIyMDI2LTA5LTI2VDAwOjAwOjAwWiIsCiAgIm1pbmltdW1NYW5hZ2VyVmVyc2lvbiI6ICIxLjIwLjAiLAogICJhcHBzIjogWwogICAgewogICAgICAiaWQiOiAiaHRvcCIsCiAgICAgICJuYW1lIjogImh0b3AiLAogICAgICAidmVyc2lvbiI6ICIzLjMuMC0xIiwKICAgICAgImluc3RhbGxlcklEIjogImh0b3AiLAogICAgICAiZGVzY3JpcHRpb24iOiB7CiAgICAgICAgInJ1IjogItCf0YDQvtGG0LXRgdGB0YssINC30LDQs9GA0YPQt9C60LAgQ1BVINC4INC40YHQv9C+0LvRjNC30L7QstCw0L3QuNC1INC/0LDQvNGP0YLQuC4iLAogICAgICAgICJlbiI6ICJQcm9jZXNzZXMsIENQVSBsb2FkIGFuZCBtZW1vcnkgdXNhZ2UuIgogICAgICB9LAogICAgICAiZmlybXdhcmUiOiBbCiAgICAgICAgIk1VNTI1MC1CMzEiCiAgICAgIF0sCiAgICAgICJhcmNoaXRlY3R1cmUiOiBbCiAgICAgICAgImFhcmNoNjRfY29ydGV4LWE1MyIKICAgICAgXSwKICAgICAgIm9wZW53cnQiOiBbCiAgICAgICAgIjIzLjA1LjQiCiAgICAgIF0sCiAgICAgICJ2ZXJpZmljYXRpb24iOiB7CiAgICAgICAgImRhdGUiOiAiMjAyNi0wOS0yNSIsCiAgICAgICAgInJlc3VsdCI6ICJwYXNzZWQiLAogICAgICAgICJsZXZlbCI6ICJwaHlzaWNhbC1tb2RlbS1pbnN0YWxsLWFuZC1sYXVuY2giLAogICAgICAgICJldmlkZW5jZSI6ICJldmlkZW5jZS9CMzEtYXBwcy0yMDI2MDkyNS5tZCIsCiAgICAgICAgImV2aWRlbmNlU0hBMjU2IjogIjA5OTQwNGQxN2VmYmI0ZGI3YzNjZjBiNWYzYzkyZWNjZTk5MTFiZGI1MWYzMzkyNjg5Y2MwYjY4YzQxNWFlZDIiLAogICAgICAgICJzdW1tYXJ5IjogewogICAgICAgICAgInJ1IjogItCd0LAgQjMxINC/0YDQvtCy0LXRgNC10L3RiyDRg9GB0YLQsNC90L7QstC60LAg0Lgg0LfQsNC/0YPRgdC6IC0tdmVyc2lvbi4g0JjQvdGC0LXRgNCw0LrRgtC40LLQvdCw0Y8g0YDQsNCx0L7RgtCwINC/0L7QutCwINC90LUg0L/RgNC+0LLQtdGA0LXQvdCwLiIsCiAgICAgICAgICAiZW4iOiAiSW5zdGFsbGF0aW9uIGFuZCAtLXZlcnNpb24gc3RhcnR1cCB2ZXJpZmllZCBvbiBCMzEuIEludGVyYWN0aXZlIG9wZXJhdGlvbiBoYXMgbm90IGJlZW4gdmVyaWZpZWQuIgogICAgICAgIH0KICAgICAgfQogICAgfSwKICAgIHsKICAgICAgImlkIjogIm9wa2ciLAogICAgICAibmFtZSI6ICJvcGtnIiwKICAgICAgInZlcnNpb24iOiAiMjAyMi0wMi0yNC1kMDM4ZTViNi0yIiwKICAgICAgImluc3RhbGxlcklEIjogIm9wa2ciLAogICAgICAiZGVzY3JpcHRpb24iOiB7CiAgICAgICAgInJ1IjogItCt0LrRgdC/0LXRgNC40LzQtdC90YLQsNC70YzQvdGL0Lkg0LzQtdC90LXQtNC20LXRgCDQv9Cw0LrQtdGC0L7QsiDQsiDQvtGC0LTQtdC70YzQvdC+0Lwg0YXRgNCw0L3QuNC70LjRidC1IC9kYXRhLiIsCiAgICAgICAgImVuIjogIkV4cGVyaW1lbnRhbCBwYWNrYWdlIG1hbmFnZXIgaW4gaXNvbGF0ZWQgL2RhdGEgc3RvcmFnZS4iCiAgICAgIH0sCiAgICAgICJmaXJtd2FyZSI6IFsKICAgICAgICAiTVU1MjUwLUIzMSIKICAgICAgXSwKICAgICAgImFyY2hpdGVjdHVyZSI6IFsKICAgICAgICAiYWFyY2g2NF9jb3J0ZXgtYTUzIgogICAgICBdLAogICAgICAib3BlbndydCI6IFsKICAgICAgICAiMjMuMDUuNCIKICAgICAgXSwKICAgICAgInZlcmlmaWNhdGlvbiI6IHsKICAgICAgICAiZGF0ZSI6ICIyMDI2LTA5LTI1IiwKICAgICAgICAicmVzdWx0IjogInBhc3NlZCIsCiAgICAgICAgImxldmVsIjogInBoeXNpY2FsLW1vZGVtLWluc3RhbGwtYW5kLWxhdW5jaCIsCiAgICAgICAgImV2aWRlbmNlIjogImV2aWRlbmNlL0IzMS1hcHBzLTIwMjYwOTI1Lm1kIiwKICAgICAgICAiZXZpZGVuY2VTSEEyNTYiOiAiMDk5NDA0ZDE3ZWZiYjRkYjdjM2NmMGI1ZjNjOTJlY2NlOTkxMWJkYjUxZjMzOTI2ODljYzBiNjhjNDE1YWVkMiIsCiAgICAgICAgInN1bW1hcnkiOiB7CiAgICAgICAgICAicnUiOiAi0J3QsCBCMzEg0L/RgNC+0LLQtdGA0LXQvdGLINGD0YHRgtCw0L3QvtCy0LrQsCDQsNC00LDQv9GC0LXRgNCwLCDQt9Cw0L/Rg9GB0Log0LggbGlzdC1pbnN0YWxsZWQuINCj0YHRgtCw0L3QvtCy0LrQsCDQv9Cw0LrQtdGC0L7QsiDQuNC3INC40L3RgtC10YDQvdC10YLQsCDQv9C+0LrQsCDQvdC1INC/0YDQvtCy0LXRgNC10L3QsC4iLAogICAgICAgICAgImVuIjogIkFkYXB0ZXIgaW5zdGFsbGF0aW9uLCBzdGFydHVwIGFuZCBsaXN0LWluc3RhbGxlZCB2ZXJpZmllZCBvbiBCMzEuIEludGVybmV0IHBhY2thZ2UgaW5zdGFsbGF0aW9uIGhhcyBub3QgYmVlbiB2ZXJpZmllZC4iCiAgICAgICAgfQogICAgICB9CiAgICB9CiAgXQp9Cg=="
    static let baselineSignature = "+yQWUhTZxMgYlrEi5PmC1fYqYzY4Qrrfq6JDeW6NdmxGGzTATuCRhQhcz8ea9SnM1TP+ELaGu/NK9wzfwNZJZw=="
    static let pinnedVersions = ["htop": "3.3.0-1", "iperf3": "3.17.1-4", "mtr": "0.95-3", "tcpdump": "4.99.4-1", "opkg": "2022-02-24-d038e5b6-2", "ssclash": "v6.4.1"]

    static func compatible(_ item: VerifiedCatalogEntry) -> Bool {
        item.id == item.installerID && pinnedVersions[item.id] == item.version &&
        item.firmware.contains("MU5250-B31") && item.architecture.contains("aarch64_cortex-a53") && item.openwrt.contains("23.05.4")
    }
    static func validate(payload: Data, signature: Data, minimumRevision: Int = 1,
                         currentPayload: Data? = nil, now: Date = Date()) throws -> VerifiedCatalogDocument {
        func check(_ condition: Bool, _ reason: String) throws { if !condition { throw VerifiedCatalogFailure.invalid(reason) } }
        try check(payload.count <= maxPayloadBytes && signature.count == 64, "размер или формат подписи")
        let key = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded: publicKeyBase64)!)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        try check(key.isValidSignature(sig, for: payload), "неверная цифровая подпись")
        let doc = try JSONDecoder().decode(VerifiedCatalogDocument.self, from: payload)
        try check(doc.schemaVersion == 1 && (1...2_147_483_647).contains(doc.revision), "неподдерживаемая схема")
        try check(doc.revision >= minimumRevision, "устаревшая ревизия")
        if doc.revision == minimumRevision, let currentPayload { try check(payload == currentPayload, "повтор ревизии с другим содержимым") }
        let formatter = ISO8601DateFormatter()
        guard let issued = formatter.date(from: doc.issuedAt) else { throw VerifiedCatalogFailure.invalid("дата публикации") }
        try check(issued <= now.addingTimeInterval(86400), "дата публикации находится в будущем")
        func version(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            return parts.count == 3 && numbers.count == 3 && numbers.allSatisfy { (0...9999).contains($0) } ? numbers : nil
        }
        guard let needed = version(doc.minimumManagerVersion), let current = version(managerVersion) else { throw VerifiedCatalogFailure.invalid("версия приложения") }
        try check(!current.lexicographicallyPrecedes(needed), "требуется новая версия программы")
        try check(doc.apps.count <= 100 && Set(doc.apps.map(\.id)).count == doc.apps.count, "состав каталога")
        func textOK(_ text: String, _ max: Int) -> Bool { !text.isEmpty && text.utf8.count <= max && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
        func localizedOK(_ text: CatalogLocalizedText) -> Bool { textOK(text.ru, 2048) && textOK(text.en, 2048) }
        for item in doc.apps {
            let idOK = item.id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
            try check(idOK && item.id == item.installerID && textOK(item.name, 100) && textOK(item.version, 64) && localizedOK(item.description), "поля приложения")
            try check([item.firmware, item.architecture, item.openwrt].allSatisfy { !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { textOK($0, 80) } }, "профиль совместимости")
            let proof = item.verification
            try check(proof.result == "passed" && proof.level == "physical-modem-install-and-launch" && localizedOK(proof.summary), "нет физической проверки")
            try check(proof.date.range(of: "^20[0-9]{2}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil && textOK(proof.evidence, 200) && proof.evidence.hasPrefix("evidence/") && !proof.evidence.contains("..") && !proof.evidence.contains("\\") && proof.evidenceSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "ссылка на результаты проверки")
        }
        return doc
    }
    static func readEnvelope(_ data: Data, minimumRevision: Int = 1, currentPayload: Data? = nil) throws -> (VerifiedCatalogDocument, Data, Data) {
        guard data.count <= maxCacheBytes else { throw VerifiedCatalogFailure.invalid("слишком большой кэш") }
        let envelope = try JSONDecoder().decode(VerifiedCatalogEnvelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature) else { throw VerifiedCatalogFailure.invalid("формат кэша") }
        return (try validate(payload: payload, signature: signature, minimumRevision: minimumRevision, currentPayload: currentPayload), payload, signature)
    }
    static func envelope(payload: Data, signature: Data) throws -> Data {
        try JSONEncoder().encode(VerifiedCatalogEnvelope(payload: payload.base64EncodedString(), signature: signature.base64EncodedString()))
    }
}

private final class CatalogHTTPPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect must not send catalog traffic to another endpoint or protocol.
        completionHandler(nil)
    }
}

@MainActor final class VerifiedCatalogStore: ObservableObject {
    static let shared = VerifiedCatalogStore()
    @Published private(set) var document: VerifiedCatalogDocument
    @Published private(set) var status = "Встроенный проверенный каталог"
    @Published private(set) var error = ""
    @Published private(set) var isUpdating = false
    var revision: Int { document.revision }
    var entries: [VerifiedCatalogEntry] { document.apps.filter(VerifiedCatalogPolicy.compatible) }
    func allows(_ id: String) -> Bool { entry(id) != nil }
    func entry(_ id: String) -> VerifiedCatalogEntry? { entries.first { $0.id == id } }
    func statusText(language: String) -> String { Self.translated(status, language: language) }
    func errorText(language: String) -> String { Self.translated(error, language: language) }
    private static func translated(_ text: String, language: String) -> String {
        guard language.lowercased().hasPrefix("en") else { return text }
        let messages = [
            "Встроенный проверенный каталог": "Bundled verified catalog",
            "Сохранённый проверенный каталог": "Cached verified catalog",
            "Каталог актуален": "Catalog is up to date",
            "Каталог обновлён": "Catalog updated",
            "Обновление каталога ещё не опубликовано. Сохранён проверенный локальный список.": "Catalog updates have not been published yet. The verified local list is retained.",
            "Не удалось получить каталог. Сохранён проверенный локальный список.": "Unable to retrieve the catalog. The verified local list is retained.",
            "Сохранённый каталог повреждён или устарел. Используется встроенный список.": "The cached catalog is invalid or outdated. Using the bundled list.",
            "размер или формат подписи": "invalid signature size or format",
            "неверная цифровая подпись": "invalid digital signature",
            "неподдерживаемая схема": "unsupported schema",
            "устаревшая ревизия": "outdated revision",
            "повтор ревизии с другим содержимым": "different contents for the same revision",
            "дата публикации": "invalid publication date",
            "дата публикации находится в будущем": "publication date is in the future",
            "версия приложения": "invalid application version",
            "требуется новая версия программы": "a newer application version is required",
            "состав каталога": "invalid catalog entries",
            "поля приложения": "invalid application metadata",
            "профиль совместимости": "invalid compatibility profile",
            "нет физической проверки": "physical modem verification is missing",
            "ссылка на результаты проверки": "invalid verification evidence reference",
            "слишком большой кэш": "cache exceeds the size limit",
            "формат кэша": "invalid cache format",
            "формат подписи": "invalid signature format",
            "каталог превышает допустимый размер": "catalog exceeds the size limit"
        ]
        if let translated = messages[text] { return translated }
        let prefix = "Каталог отклонён: "
        if text.hasPrefix(prefix) { return "Catalog rejected: " + (messages[String(text.dropFirst(prefix.count))] ?? "invalid metadata") }
        return text.isEmpty ? "" : "Catalog update failed. The verified local list is retained."
    }
    private let cacheURL: URL
    private var payload: Data
    private var signature: Data
    private let fetchOverride: ((URL, Int) async throws -> Data)?

    init(cacheURL: URL? = nil, fetch: ((URL, Int) async throws -> Data)? = nil) {
        self.fetchOverride = fetch
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZTE U60Pro Manager/Catalog", isDirectory: true)
        self.cacheURL = cacheURL ?? directory.appendingPathComponent("verified-envelope.json")
        payload = Data(base64Encoded: VerifiedCatalogPolicy.baselinePayload)!
        signature = Data(base64Encoded: VerifiedCatalogPolicy.baselineSignature)!
        // A source/build inconsistency is never silently accepted as approved data.
        // A wrong local clock must not crash offline startup. Future-date checks
        // apply to updates; the embedded baseline has already passed release validation.
        document = try! VerifiedCatalogPolicy.validate(payload: payload, signature: signature, now: Date.distantFuture)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: self.cacheURL.path),
           let bytes = attributes[.size] as? NSNumber, bytes.intValue <= VerifiedCatalogPolicy.maxCacheBytes,
           attributes[.type] as? FileAttributeType == .typeRegular {
            do {
                let verified = try VerifiedCatalogPolicy.readEnvelope(Data(contentsOf: self.cacheURL), minimumRevision: document.revision, currentPayload: payload)
                document = verified.0; payload = verified.1; signature = verified.2
                status = "Сохранённый проверенный каталог"
            } catch { self.error = "Сохранённый каталог повреждён или устарел. Используется встроенный список." }
        }
    }

    func refresh() async {
        guard !isUpdating else { return }
        isUpdating = true; error = ""
        defer { isUpdating = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: CatalogHTTPPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            func fetch(_ url: URL, _ maximum: Int) async throws -> Data {
                if let fetchOverride { return try await fetchOverride(url, maximum) }
                return try await Self.download(url, maximum: maximum, session: session)
            }
            let nextPayload = try await fetch(VerifiedCatalogPolicy.endpoint, VerifiedCatalogPolicy.maxPayloadBytes)
            let sigBytes = try await fetch(VerifiedCatalogPolicy.signatureEndpoint, 256)
            guard let sigText = String(data: sigBytes, encoding: .utf8), let nextSignature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VerifiedCatalogFailure.invalid("формат подписи") }
            let next = try VerifiedCatalogPolicy.validate(payload: nextPayload, signature: nextSignature, minimumRevision: document.revision, currentPayload: payload)
            let envelope = try VerifiedCatalogPolicy.envelope(payload: nextPayload, signature: nextSignature)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try envelope.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            let unchanged = next.revision == document.revision
            document = next; payload = nextPayload; signature = nextSignature
            status = unchanged ? "Каталог актуален" : "Каталог обновлён"
        } catch let failure as VerifiedCatalogFailure { error = failure.localizedDescription }
        catch { self.error = VerifiedCatalogFailure.unavailable.localizedDescription }
    }
    private static func download(_ url: URL, maximum: Int, session: URLSession) async throws -> Data {
        guard url.scheme == "https" && url.host == "raw.githubusercontent.com" else { throw VerifiedCatalogFailure.unavailable }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw VerifiedCatalogFailure.unavailable }
        if response.statusCode == 404 { throw VerifiedCatalogFailure.notPublished }
        guard response.statusCode == 200 && response.url == url && (response.expectedContentLength < 0 || response.expectedContentLength <= maximum) else { throw VerifiedCatalogFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw VerifiedCatalogFailure.invalid("каталог превышает допустимый размер") }
            data.append(byte)
        }
        return data
    }
}
