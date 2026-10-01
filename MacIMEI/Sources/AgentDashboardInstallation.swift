import Foundation

struct AgentDashboardPayload {
    static let names = ["dashboard.sh", "dashboard.tar.gz", "dashboard-uhttpd", "start-dashboard.sh", "dashboard-html.sh", "stop-owned-listener.sh", "update-rc-local.sh", "preserve-dashboard-assets.sh", "payload.sha256"]
    let files: [String: Data]
    static func load(_ resources: URL) throws -> Self {
        let directory = resources.appendingPathComponent("AgentDashboardInstall")
        let manifest = try readJSON([String: String].self, directory.appendingPathComponent("SHA256.json"))
        try require(Set(manifest.keys) == Set(names), "Неполный комплект веб-панели")
        var files = [String: Data]()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            try require(info.isRegularFile == true && info.isSymbolicLink != true && (1...67108864).contains(info.fileSize ?? 0), "Неверный компонент веб-панели")
            let bytes = try Data(contentsOf: url)
            try require(digest(bytes) == manifest[name], "Повреждён компонент веб-панели: " + name)
            files[name] = bytes
        }
        let script = files["dashboard.sh"]!
        try require(digest(script) == BundledAgent.dashboardInstallerSHA256, "Повреждён установщик веб-панели")
        let payloadLines = String(decoding: script, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("payload_sha=") }
        try require(payloadLines.count == 1 && String(payloadLines[0].dropFirst("payload_sha=".count)) == digest(files["payload.sha256"]!), "Повреждена ведомость файлов веб-панели")
        var seen = Set<String>()
        let expectedNames = Set(names).subtracting(["dashboard.sh", "payload.sha256"])
        for line in String(decoding: files["payload.sha256"]!, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            try require(fields.count == 2 && expectedNames.contains(fields[1]) && seen.insert(fields[1]).inserted && digest(files[fields[1]]!) == fields[0], "Не совпадает состав веб-панели")
        }
        try require(seen == expectedNames, "Неполная ведомость файлов веб-панели")
        return Self(files: files)
    }
}
