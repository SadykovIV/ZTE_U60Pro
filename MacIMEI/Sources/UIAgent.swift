import SwiftUI

extension ContentView {
    var agentPreparationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "network", text: "При первой автоматической подготовке приложение настраивает ADB и SSH и устанавливает агент из комплекта. Здесь можно проверить его состояние, обновить штатный агент или заменить его своим файлом. Для этих действий сначала подключитесь к модему.")
            StudioCard {
                HStack {
                    Text(L10n.text("Агент на модеме")).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button(L10n.text("Проверить агент")) { model.refreshAgent() }.buttonStyle(StudioButtonStyle()).disabled(!model.canReadModem)
                }
                informationRow("Поставляемый агент", BundledAgent.version + " · eSIM")
                if let state = model.agentInstallationStatus {
                    informationRow("Процесс", state.running ? "Запущен" : "Не запущен")
                    informationRow("Файл", BundledAgent.description(for: state.hash))
                    informationRow("SHA256", state.hash)
                    informationRow("Сценарий запуска", state.startupReady ? "Сценарий запуска доступен" : "Требуется автоматическая подготовка")
                    if state.warningCode == "OWNER" {
                        StudioNote(symbol: "exclamationmark.triangle", text: L10n.text("Файл и процесс агента проверены, но история установки не подтверждена. Сохранённые данные оставлены без изменений; установка требует восстановления.", "The agent file and process were checked, but installation history could not be verified. Saved data was preserved; installation requires recovery."))
                    } else if state.recoveryPending { StudioNote(symbol: "arrow.uturn.backward", text: "Есть незавершённая замена. Сначала восстановите предыдущий агент.") }
                }
                Button(L10n.text("Установить / обновить агент и веб-панель")) { model.installAgent(custom: false) }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || model.agentInstallationStatus?.recoveryPending == true)
                Text(L10n.text("Устанавливается агент с eSIM и его веб-панель. Пароль и настройки запуска сохраняются. VPN устанавливать не требуется. При первой автоматической подготовке ставится агент; эта кнопка также добавляет панель. Для загрузки профиля из браузера нужен интернет модема; раздел eSIM приложения использует интернет Mac."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            StudioCard {
                Text(L10n.text("Свой агент")).font(.system(size: 18, weight: .semibold))
                Text(L10n.text("Выберите исполняемый ELF-файл Linux ARM64. Он заменит /data/zte-agent и будет запускаться с текущими параметрами и правами root. Используйте только доверенный файл. Проверка ELF и запуска процесса не подтверждает совместимость его API с веб-панелью, VPN и экраном модема."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Выбрать свой файл…")) { model.chooseCustomAgent() }.buttonStyle(StudioButtonStyle()).disabled(model.busy)
                if let candidate = model.customAgent {
                    informationRow("Файл", candidate.url.lastPathComponent)
                    informationRow("Размер", ByteCountFormatter.string(fromByteCount: Int64(candidate.bytes), countStyle: .file))
                    informationRow("SHA256", candidate.sha256)
                    informationRow("Загрузчик", candidate.interpreter ?? "Статический ELF")
                    Button(L10n.text("Установить выбранный агент")) { model.installAgent(custom: true) }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || model.agentInstallationStatus?.recoveryPending == true)
                }
            }
            StudioCard {
                Text(L10n.text("Восстановление агента")).font(.system(size: 18, weight: .semibold))
                Text(L10n.text("Перед каждой заменой предыдущий файл сохраняется на модеме с проверкой SHA256. Если новый процесс не запустится, установщик попробует вернуть его автоматически. При обрыве операции используйте восстановление. Сохраняется одна предыдущая версия."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                if let hash = model.agentInstallationStatus?.backupHash { informationRow("SHA256 резервной копии", hash) }
                Button(L10n.text("Восстановить предыдущий агент")) { model.restoreAgent() }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.agentInstallationStatus?.backupHash == nil)
            }
        }
    }
}
