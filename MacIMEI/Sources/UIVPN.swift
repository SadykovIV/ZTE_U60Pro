import SwiftUI
import AppKit

extension ContentView {
    var vpnPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "network", text: "VPN работает на самом модеме: профиль задаёт сервер и параметры подключения. Профили импортируются и выбираются в агенте. Отдельная сеть «ZTE-VPN» направляет трафик через выбранный профиль; основная сеть Wi-Fi сохраняет обычное подключение. Профиль и WiFi с VPN можно переключать на экране модема.")
            StudioCard {
                HStack {
                    Text("Компоненты VPN").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Проверить") { model.refreshVPN() }.buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
                if let check = model.vpnInspection {
                    informationRow("Прошивка и системные компоненты", check.missingCapabilities.isEmpty ? "Готовы" : "Отсутствуют: " + check.missingCapabilities.joined(separator: ", "))
                    informationRow("SSClash-Go", check.ssclashInstalled ? "Установлен" : "Не установлен · для этого управления не требуется")
                    informationRow("Менеджер VPN", check.helperReady ? "Установлен · \(check.status.version)" : check.status.installed ? "Требуется обновление" : "Требуется установка")
                    informationRow("Ядро Mihomo", check.status.coreAvailable ? check.status.coreVersion : "Будет установлено из комплекта приложения")
                    informationRow("Агент с управлением VPN", check.agentReady ? "Готов" : "Требуется обновление")
                    informationRow("Веб-панель агента", check.dashboardReady ? "Готова" : "Требуется обновление")
                    informationRow("Страницы на экране модема", check.launcherReady ? "Установлены · информация и VPN" : "Требуется установка или восстановление")
                    if !check.helperReady || !check.agentReady || !check.dashboardReady || !check.launcherReady {
                        Button("Установить необходимые компоненты") { model.installVPN() }
                            .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || !check.missingCapabilities.isEmpty)
                        Text("Компоненты входят в приложение. После установки импортируйте профиль в агенте модема. VPN будет работать на самом модеме.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                } else { Text("Сначала проверьте установленное на модеме ПО.").foregroundStyle(StudioStyle.secondary) }
            }
            if !model.vpnError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.vpnError) }
            StudioCard {
                Text("Управление VPN — в агенте модема").font(.system(size: 16, weight: .semibold))
                Text("Импорт, выбор, переименование и просмотр профилей, а также WiFi с VPN доступны в веб-панели агента. Всё работает на модеме, даже когда программа закрыта.")
                    .font(.system(size: 13)).foregroundStyle(StudioStyle.secondary)
                Button("Открыть агент модема") {
                    var address = URLComponents()
                    address.scheme = "http"; address.host = model.host; address.port = 8080
                    if let url = address.url { NSWorkspace.shared.open(url) }
                }.buttonStyle(StudioButtonStyle()).disabled(model.vpnInspection?.dashboardReady != true)
            }
        }.onAppear { if model.canManage { model.refreshVPN() } }
    }
}
