import Foundation

@main struct Tests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = root.appendingPathComponent("tests/fixtures")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zte-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "TestFailure: " + name, code: 1) }
            count += 1; print("PASS Swift " + name)
        }
        func rejected(_ name: String, _ work: () throws -> Void) throws {
            do { try work() } catch { try check(true, name); return }
            try check(false, name)
        }
        func data(_ name: String) throws -> (Data, Data) {
            let file = fixtures.appendingPathComponent(name)
            let payload = try Data(contentsOf: file.appendingPathExtension("json"))
            let sig = try String(contentsOf: file.appendingPathExtension("sig"), encoding: .utf8)
            return (payload, Data(base64Encoded: sig.trimmingCharacters(in: .whitespacesAndNewlines))!)
        }
        let baseline = Data(base64Encoded: VerifiedCatalogPolicy.baselinePayload)!
        let signature = Data(base64Encoded: VerifiedCatalogPolicy.baselineSignature)!
        let initial = try VerifiedCatalogPolicy.validate(payload: baseline, signature: signature)
        try check(initial.apps.map(\.id) == ["htop", "opkg"], "cross-runtime baseline signature and physical whitelist")
        var modified = baseline; modified[modified.startIndex] ^= 1
        try rejected("tampered payload rejected") { _ = try VerifiedCatalogPolicy.validate(payload: modified, signature: signature) }
        try rejected("tampered signature rejected") { _ = try VerifiedCatalogPolicy.validate(payload: baseline, signature: Data(repeating: 0, count: 64)) }
        try rejected("oversized payload rejected") { _ = try VerifiedCatalogPolicy.validate(payload: Data(repeating: 1, count: VerifiedCatalogPolicy.maxPayloadBytes + 1), signature: signature) }
        try rejected("rollback revision rejected") { _ = try VerifiedCatalogPolicy.validate(payload: baseline, signature: signature, minimumRevision: 2) }
        let next = try data("new-revision"), empty = try data("empty-list")
        let update = try VerifiedCatalogPolicy.validate(payload: next.0, signature: next.1, minimumRevision: 1, currentPayload: baseline)
        try check(update.revision == 2 && update.apps.count == 1, "signed approval withdrawal accepted")
        try rejected("same-revision equivocation rejected") { _ = try VerifiedCatalogPolicy.validate(payload: empty.0, signature: empty.1, minimumRevision: 2, currentPayload: next.0) }
        for name in ["duplicate-id", "too-new-manager", "future-date"] {
            let value = try data(name)
            try rejected(name + " rejected") { _ = try VerifiedCatalogPolicy.validate(payload: value.0, signature: value.1) }
        }
        for name in ["unknown-installer", "unpinned-version", "incompatible-architecture"] {
            let value = try data(name)
            let doc = try VerifiedCatalogPolicy.validate(payload: value.0, signature: value.1)
            try check(doc.apps.filter(VerifiedCatalogPolicy.compatible).map(\.id) == ["opkg"], name + " not installable")
        }
        let cache = directory.appendingPathComponent("cache.json")
        let validEnvelope = try VerifiedCatalogPolicy.envelope(payload: next.0, signature: next.1)
        try validEnvelope.write(to: cache)
        let saved = VerifiedCatalogStore(cacheURL: cache)
        try check(saved.revision == 2 && saved.entries.count == 1, "verified cache restored")
        try Data("corrupt".utf8).write(to: cache)
        let corrupt = VerifiedCatalogStore(cacheURL: cache)
        try check(corrupt.revision == 1 && corrupt.entries.count == 2 && !corrupt.error.isEmpty, "corrupt cache retains signed offline baseline")
        try? FileManager.default.removeItem(at: cache)
        var mode = "update"
        let store = VerifiedCatalogStore(cacheURL: cache) { url, maximum in
            if mode == "404" { throw VerifiedCatalogFailure.notPublished }
            if mode == "tamper" { return url.pathExtension == "sig" ? Data("AAAA".utf8) : next.0 }
            return url.pathExtension == "sig" ? Data(next.1.base64EncodedString().utf8) : next.0
        }
        await store.refresh()
        try check(store.revision == 2 && store.allows("htop") && !store.allows("opkg") && store.error.isEmpty, "refresh accepts approved exact versions only")
        let committed = try Data(contentsOf: cache)
        try check(try VerifiedCatalogPolicy.readEnvelope(committed).0.revision == 2, "atomic cache contains payload and signature")
        mode = "tamper"; await store.refresh()
        try check(store.revision == 2 && !store.error.isEmpty && (try Data(contentsOf: cache)) == committed, "invalid update preserves current cache and document")
        mode = "404"; await store.refresh()
        try check(store.revision == 2 && store.error.contains("не опубликовано") && (try Data(contentsOf: cache)) == committed, "unpublished endpoint preserves last approved list")
        print("\(count) Swift catalog tests passed")
    }
}
