import SwiftUI

extension ContentView {
    var agentPreparationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "network", text: "При первой автоматической подготовке приложение настраивает ADB и SSH и устанавливает агент из комплекта. Здесь можно проверить его состояние, обновить штатный агент или заменить его своим файлом. Для этих действий сначала подключитесь к модему.")
            StudioCard {
                HStack {
                    Text("Агент на модеме").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Проверить агент") { model.refreshAgent() }.buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
                if let state = model.agentInstallationStatus {
                    informationRow("Процесс", state.running ? "Запущен" : "Не запущен")
                    informationRow("Файл", state.hash == "absent" ? "Не установлен" : state.hash == VPNSettingsManager.agentHash ? "Из комплекта приложения · 2.7.0" : "Другая сборка / свой агент")
                    informationRow("SHA256", state.hash)
                    informationRow("Сценарий запуска", state.startupReady ? "Сценарий запуска доступен" : "Требуется автоматическая подготовка")
                    if state.recoveryPending { StudioNote(symbol: "arrow.uturn.backward", text: "Есть незавершённая замена. Сначала восстановите предыдущий агент.") }
                }
                Button("Установить / обновить штатный агент") { model.installAgent(custom: false) }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || model.agentInstallationStatus?.recoveryPending == true)
                Text("Устанавливается агент, включённый в приложение. Пароль и настройки его запуска сохраняются. Веб-панель и компоненты VPN проверяются в разделе VPN.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            StudioCard {
                Text("Свой агент").font(.system(size: 18, weight: .semibold))
                Text("Выберите исполняемый ELF-файл Linux ARM64. Он заменит /data/zte-agent и будет запускаться с текущими параметрами и правами root. Используйте только доверенный файл. Проверка ELF и запуска процесса не подтверждает совместимость его API с веб-панелью, VPN и экраном модема.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Выбрать свой файл…") { model.chooseCustomAgent() }.buttonStyle(StudioButtonStyle()).disabled(model.busy)
                if let candidate = model.customAgent {
                    informationRow("Файл", candidate.url.lastPathComponent)
                    informationRow("Размер", ByteCountFormatter.string(fromByteCount: Int64(candidate.bytes), countStyle: .file))
                    informationRow("SHA256", candidate.sha256)
                    informationRow("Загрузчик", candidate.interpreter ?? "Статический ELF")
                    Button("Установить выбранный агент") { model.installAgent(custom: true) }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || model.agentInstallationStatus?.recoveryPending == true)
                }
            }
            StudioCard {
                Text("Восстановление агента").font(.system(size: 18, weight: .semibold))
                Text("Перед каждой заменой предыдущий файл сохраняется на модеме с проверкой SHA256. Если новый процесс не запустится, установщик попробует вернуть его автоматически. При обрыве операции используйте восстановление. Сохраняется одна предыдущая версия.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                if let hash = model.agentInstallationStatus?.backupHash { informationRow("SHA256 резервной копии", hash) }
                Button("Восстановить предыдущий агент") { model.restoreAgent() }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.agentInstallationStatus?.backupHash == nil)
            }
        }
    }
}
