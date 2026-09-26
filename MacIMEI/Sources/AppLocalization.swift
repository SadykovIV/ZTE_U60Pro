import Foundation

/// Presentation-only localization. Device protocols, stored IDs and command output remain unchanged.
enum L10n {
    static let preferenceKey = "manager.interfaceLanguage"
    static var language: String { UserDefaults.standard.string(forKey: preferenceKey) == "en" ? "en" : "ru" }
    static func text(_ russian: String, _ english: String) -> String { language == "en" ? english : russian }
    static func text(_ source: String) -> String {
        guard language == "en", source.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil else { return source }
        if let value = translations[source] { return value }
        for template in templates {
            let range = NSRange(source.startIndex..., in: source)
            guard let match = template.pattern.firstMatch(in: source, range: range) else { continue }
            var result = template.english
            for i in 1..<match.numberOfRanges {
                if let capture = Range(match.range(at: i), in: source) {
                    result = result.replacingOccurrences(of: "{{\(i - 1)}}", with: text(String(source[capture])))
                }
            }
            return result
        }
        return source
    }
    private static let translations: [String: String] = {
        let roots = [Bundle.main.resourceURL?.appendingPathComponent("Localization"),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("MacIMEI/Resources/Localization"),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Localization")]
        for root in roots.compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            var merged: [String: String] = [:]
            for file in files.filter({ $0.lastPathComponent.hasPrefix("en") && $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([String: String].self, from: data) {
                    merged.merge(values) { _, newer in newer }
                }
            }
            if !merged.isEmpty { return merged }
        }
        return [:]
    }()
    private struct Template { let pattern: NSRegularExpression; let english: String }
    private static let templates: [Template] = translations.keys.filter { $0.contains("{{0}}") }.sorted { $0.count > $1.count }.compactMap { key in
        var pattern = NSRegularExpression.escapedPattern(for: key)
        for i in 0..<16 {
            pattern = pattern.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{{\(i)}}"), with: "([\\s\\S]*?)")
        }
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return nil }
        return Template(pattern: regex, english: translations[key]!)
    }
}
