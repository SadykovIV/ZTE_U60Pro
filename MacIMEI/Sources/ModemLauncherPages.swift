import Foundation

enum ModemLauncherPage: String, CaseIterable, Codable, Sendable, Identifiable {
    case info, vpn, esim
    var id: String { rawValue }
    var title: String {
        switch self { case .info: return "Информация"; case .vpn: return "VPN"; case .esim: return "eSIM" }
    }
}

/// Only enabled extension pages are serialized, in screen order. Home and
/// Settings are stock pages and always remain outside this preference.
struct ModemLauncherPages: Equatable, Codable, Sendable {
    static let header = "ZTE_LAUNCHER_PAGES_V1"
    static let maximumBytes = 128
    static let defaultPages = ModemLauncherPages(pages: ModemLauncherPage.allCases)
    var pages: [ModemLauncherPage]

    func validate() throws {
        try require(pages.count <= 3 && Set(pages).count == pages.count, "Страницы лаунчера не должны повторяться")
    }
    func encoded() throws -> Data {
        try validate()
        return Data((Self.header + "\n" + pages.map { $0.rawValue + "\n" }.joined()).utf8)
    }
    static func decode(_ data: Data) throws -> Self {
        try require(!data.isEmpty && data.count <= maximumBytes && data.allSatisfy { $0 == 10 || (32...126).contains($0) }, "Повреждён формат списка страниц")
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        try require((2...5).contains(lines.count) && lines.first == header && lines.last == "", "Неизвестный или неполный список страниц")
        let pages = try lines.dropFirst().dropLast().map { value -> ModemLauncherPage in
            guard let page = ModemLauncherPage(rawValue: value) else { throw IMEIError.message("Неизвестная страница лаунчера") }
            return page
        }
        let value = Self(pages: pages)
        try value.validate()
        return value
    }
    func includingEsim() -> Self {
        pages.contains(.esim) ? self : Self(pages: pages + [.esim])
    }
}
