import SwiftUI
import AppKit

extension ContentView {
    var vpnPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "network", text: "VPN работает на самом модеме: профиль задаёт сервер и параметры подключения. Профили импортируются и выбираются в агенте. Отдельная сеть Wi-Fi с VPN направляет трафик через выбранный профиль; основная сеть Wi-Fi сохраняет обычное подключение. Профиль и WiFi с VPN можно переключать на экране модема.")
            StudioCard {
                HStack {
                    Text(L10n.text("Компоненты VPN")).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button(L10n.text("Проверить")) { model.refreshVPN() }.buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
                if let check = model.vpnInspection {
                    informationRow("Прошивка и системные компоненты", check.missingCapabilities.isEmpty ? "Готовы" : "Отсутствуют: " + check.missingCapabilities.joined(separator: ", "))
                    informationRow("SSClash-Go", check.ssclashInstalled ? "Установлен" : "Не установлен · для этого управления не требуется")
                    informationRow("Менеджер VPN", check.helperReady ? "Установлен · \(check.status.version)" : check.status.installed ? "Требуется обновление" : "Требуется установка")
                    informationRow("Ядро Mihomo", check.status.coreAvailable ? check.status.coreVersion : "Будет установлено из комплекта приложения")
                    informationRow("Агент с управлением VPN", check.agentReady ? "Готов" : "Требуется обновление")
                    informationRow("Веб-панель агента", check.dashboardReady ? "Готова" : "Требуется обновление")
                    informationRow("Страницы на экране модема", check.launcherReady ? "Установлены · информация и VPN" : "Требуется установка или восстановление")
                } else { Text(L10n.text("Проверка выполнится перед установкой компонентов.")).foregroundStyle(StudioStyle.secondary) }
                if model.vpnInspection == nil || model.vpnInspection?.helperReady != true || model.vpnInspection?.agentReady != true || model.vpnInspection?.dashboardReady != true || model.vpnInspection?.launcherReady != true {
                    Button(L10n.text(model.vpnInspection?.status.installed == true ? "Обновить компоненты VPN" : "Установить компоненты VPN"), action: model.installVPN)
                        .buttonStyle(StudioButtonStyle(prominent: true))
                        .disabled(!model.canManage || model.vpnInspection?.missingCapabilities.isEmpty == false)
                    Text(L10n.text("Установка добавит ядро VPN, управление в агенте и страницы Launcher. Она не включает сеть Wi-Fi с VPN. Название и пароль задаются в Launcher → Управление VPN; профиль импортируется в агенте."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.vpnError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.vpnError) }
            StudioCard {
                Text(L10n.text("Управление VPN — в агенте модема")).font(.system(size: 16, weight: .semibold))
                Text(L10n.text("Импорт, выбор, переименование и просмотр профилей, а также WiFi с VPN доступны в веб-панели агента. Всё работает на модеме, даже когда программа закрыта."))
                    .font(.system(size: 13)).foregroundStyle(StudioStyle.secondary)
                Button(L10n.text("Открыть агент модема")) {
                    var address = URLComponents()
                    address.scheme = "http"; address.host = model.host; address.port = 8080
                    if let url = address.url { NSWorkspace.shared.open(url) }
                }.buttonStyle(StudioButtonStyle()).disabled(!model.connected || model.vpnInspection?.dashboardReady != true)
            }
        }
    }
}
