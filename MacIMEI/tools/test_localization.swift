import Foundation

@main
struct LocalizationChecks {
    static func main() throws {
        func select(_ language: String) {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language], forName: UserDefaults.argumentDomain)
        }
        func check(_ actual: String, _ expected: String) {
            precondition(actual == expected, "Localization mismatch: \(actual) != \(expected)")
        }
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        select("ru")
        check(L10n.text("Подготовка модема"), "Подготовка модема")
        check(L10n.text("Русский текст", "English text"), "Русский текст")
        select("en")
        check(L10n.text("Подготовка модема"), "Modem preparation")
        check(L10n.text("Русский текст", "English text"), "English text")
        check(L10n.text("Подключено · SSH"), "Connected · SSH")
        check(L10n.text("8 из 12"), "8 of 12")
        check(L10n.text("2 д. 3 ч. 4 мин."), "2 d 3 h 4 min")
        check(L10n.text("Выше: Температура процессора"), "Move up: CPU temperature")
        check(L10n.text("Для подтверждения введите: ВОССТАНОВИТЬ aabbccdd"), "To confirm, type: ВОССТАНОВИТЬ aabbccdd")
        check(L10n.text("ssh -p 2222 root@192.168.0.1"), "ssh -p 2222 root@192.168.0.1")
        check(L10n.text("Незнакомое имя пользователя"), "Незнакомое имя пользователя")
        check(L10n.text("Как выполняется подготовка модема"), "How modem preparation works")
        select("ru")
        check(L10n.text("8 из 12"), "8 из 12")
        print("PASS: 13 localization checks (RU/EN, runtime switching, templates, confirmation token and raw fallback)")
    }
}
