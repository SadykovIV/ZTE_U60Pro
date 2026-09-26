import Foundation

struct OpkgConsoleCommand: Equatable, Sendable {
    let arguments: [String]
    var display: String { "opkg " + arguments.map { $0.contains("*") || $0.contains("?") ? "'" + $0 + "'" : $0 }.joined(separator: " ") }
    static let help = "opkg update\nopkg list [шаблон]\nopkg search <шаблон>\nopkg info <пакет>\nopkg files <пакет>\nopkg install <пакет>\nopkg remove <пакет>\nopkg list-installed\nopkg status [пакет]"
    static func failureMessage(_ message: String) -> String {
        let explanations: [(String, String)] = [
            ("FREE_SPACE", "Недостаточно места для отдельной копии среды opkg."),
            ("TOOLS_RUNNING", "Завершите программы из среды opkg перед её изменением."),
            ("CUSTOM_MAINTAINER_SCRIPT", "Пакет требует собственного установочного сценария и не поддерживается в этой среде."),
            ("SERVICE_OR_SYSTEM_PAYLOAD", "Пакет содержит системные настройки или службу, которые эта среда не поддерживает."),
            ("UNSUPPORTED_DEPENDENCY", "Среди зависимостей обнаружен неподдерживаемый системный пакет."),
            ("CHANGED_GENERATION", "Файлы сохранённой среды opkg изменены. Автоматическая операция остановлена."),
            ("DATA_NOT_EXECUTABLE", "Раздел /data должен разрешать запись и запуск программ."),
            ("CAPABILITY", "На модеме отсутствует одна из команд, необходимых для отдельной среды opkg.")
        ]
        if let explanation = explanations.first(where: { message.contains("OPKG_ERROR " + $0.0) }) {
            return explanation.1 + "\n" + message
        }
        return message
    }
    static func parse(_ input: String) throws -> OpkgConsoleCommand {
        try require(!input.isEmpty && input.utf8.count <= 512, "Введите одну команду opkg длиной до 512 байт")
        try require(!input.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                    && !input.contains(where: { "$`<>|;&\\".contains($0) }), "Терминал принимает одну команду opkg без shell-операторов, подстановок и перенаправлений")
        var args: [String] = [], token = "", quote: Character?
        for character in input {
            if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" { quote = character }
            else if character.isWhitespace {
                if !token.isEmpty { args.append(token); token = "" }
            } else { token.append(character) }
        }
        try require(quote == nil, "Закройте кавычки в команде")
        if !token.isEmpty { args.append(token) }
        if args.first == "opkg" { args.removeFirst() }
        guard let verb = args.first, ["update", "list", "search", "info", "files", "install", "remove", "list-installed", "status"].contains(verb) else {
            throw IMEIError.message("Поддерживаются update, list, search, info, files, install, remove, list-installed и status")
        }
        let values = Array(args.dropFirst())
        switch verb {
        case "update": try require(values.isEmpty, "opkg update не принимает аргументы")
        case "install", "remove": try require((1...8).contains(values.count), "Укажите от 1 до 8 имён пакетов")
        case "info", "search", "files": try require(values.count == 1, "Укажите имя или шаблон одного пакета")
        default: try require(values.count <= 1, "Допускается один необязательный шаблон пакета")
        }
        for value in values {
            let wildcard = !["install", "remove", "files"].contains(verb)
            try require((1...100).contains(value.utf8.count) && !value.hasPrefix("-") && value.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || [43, 46, 95, 45].contains($0) || (wildcard && [42, 63].contains($0))
            }, "Допустимы имена пакетов или шаблоны; пути, URL и параметры изменения системного opkg запрещены")
        }
        try ExperimentalOpkgManager.validate(args)
        return .init(arguments: args)
    }
}
