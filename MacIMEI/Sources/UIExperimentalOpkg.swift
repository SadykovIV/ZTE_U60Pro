import SwiftUI

extension ContentView {
    var opkgApplicationCard: some View {
        ApplicationTile(name: "opkg", version: "Экспериментально",
                        summary: "Адаптер менеджера пакетов OpenWrt для отдельного хранилища на /data.",
                        installed: model.experimentalOpkgStatus?.installed) {
            if model.experimentalOpkgStatus?.installed == true {
                HStack(spacing: 8) {
                    Button("Терминал") { applicationSection = .opkg }.buttonStyle(StudioButtonStyle())
                    Spacer(minLength: 0)
                    Button("Удалить", action: model.removeExperimentalOpkg).buttonStyle(StudioButtonStyle())
                        .disabled(!model.canManage || model.experimentalOpkgStatus?.running == true)
                }
            } else {
                Button("Установить", action: model.installExperimentalOpkg).buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!model.canManage || model.experimentalOpkgStatus == nil)
            }
        }
    }
    func experimentalPackageCard(_ package: ExperimentalOpkgPackage) -> some View {
        ApplicationTile(name: package.name, version: package.version,
                        summary: package.summary.isEmpty ? "Пакет из отдельного хранилища opkg. Подробности: opkg info \(package.name)." : package.summary, installed: true, statusText: "Установлено через opkg") {
            HStack(spacing: 8) {
                Button("Подробнее") { model.opkgCommand = "opkg info " + package.name; applicationSection = .opkg }
                    .buttonStyle(StudioButtonStyle())
                Spacer(minLength: 0)
                Button("Удалить") { model.removeExperimentalPackage(package.name) }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canUseOpkgConsole || model.experimentalOpkgStatus?.running == true)
            }
        }
    }
    var experimentalOpkgPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Terminal").font(.system(size: 18, weight: .semibold))
                Text("SSH-терминал модема без списка разрешённых команд. Можно работать с shell и устанавливать пакеты через opkg.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            TerminalConsoleCard(model: model, session: model.terminalSession)
            if !model.terminalError.isEmpty { applicationError(model.terminalError) }
            if model.experimentalOpkgStatus?.installed != true { opkgApplicationCard }
            if !model.experimentalOpkgError.isEmpty { applicationError(model.experimentalOpkgError) }
            HStack {
                Text(model.experimentalOpkgStatus?.installed == true ? "Адаптер opkg установлен · пакетов: \(model.experimentalOpkgStatus?.packages.count ?? 0)" : "Установите адаптер opkg для пакетов в /data")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                Spacer()
                Button("Проверить opkg", action: model.refreshExperimentalOpkg).buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                if model.experimentalOpkgStatus?.canRollback == true {
                    Button("Откатить", action: model.rollbackExperimentalOpkg).buttonStyle(StudioButtonStyle())
                        .disabled(!model.canManage || model.experimentalOpkgStatus?.running == true)
                }
            }
            DisclosureGroup("Установка пакетов через opkg") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Среда адаптера: OpenWrt \(model.opkgFeeds?.release ?? "23.05.4") · архитектура \(model.opkgFeeds?.architecture ?? "aarch64_cortex-a53").")
                        .font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                    Text("1. Установите адаптер opkg кнопкой выше.\n2. Откройте Terminal и обновите список пакетов.\n3. Найдите пакет, прочитайте описание и установите его.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    Text("opkg update\nopkg list '*iperf*'\nopkg info iperf3\nopkg install iperf3\nopkg list-installed\n# Удаление: opkg remove iperf3")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text("В этом сеансе opkg — функция для адаптера /data/zte-imei-apps/opkg-private/opkg. Он устанавливает совместимые пользовательские пакеты в отдельное хранилище и сохраняет откат. Штатный менеджер доступен как /bin/opkg; он работает с системной базой. Остальные команды выполняются обычным shell с правами root. Для своих команд доступны перенаправления, конвейеры, скрипты и интерактивные программы.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    Text("Для адаптера выбирайте пакеты OpenWrt 23.05.4 / aarch64_cortex-a53. Модули ядра и системные службы требуют отдельной совместимости с прошивкой модема. Настройки источников ниже относятся только к приватному адаптеру.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                }.padding(.top, 8)
            }.font(.system(size: 12))
            DisclosureGroup("Источники пакетов opkg") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Формат: src/gz имя https://адрес/каталога. Сохранение создаёт новую конфигурацию адаптера и очищает кэш доступных пакетов; затем выполните opkg update.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    TextEditor(text: $model.opkgFeedsDraft).font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 145).scrollContentBackground(.hidden).padding(8)
                        .background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!model.canUseOpkgConsole || model.opkgFeeds == nil)
                    HStack {
                        Button("Прочитать с модема", action: model.loadOpkgFeeds).buttonStyle(StudioButtonStyle()).disabled(!model.canUseOpkgConsole)
                        Button("Сохранить источники", action: model.saveOpkgFeeds).buttonStyle(StudioButtonStyle(prominent: true))
                            .disabled(!model.canUseOpkgConsole || model.opkgFeeds == nil || model.opkgFeedsDraft == model.opkgFeeds?.text)
                    }
                    if !model.opkgFeedsMessage.isEmpty { Text(model.opkgFeedsMessage).font(.system(size: 12)).textSelection(.enabled) }
                    if let feeds = model.opkgFeeds {
                        Text("Ключи подписи: " + feeds.keyFingerprints.joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.secondary).textSelection(.enabled)
                    }
                    Text("Проверка подписи сохраняется. Источник с другим ключом можно записать, но загрузка его индекса завершится ошибкой: импорт дополнительных ключей в этом редакторе пока не поддерживается.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    if model.terminalActive { Text("Для изменения источников и операций приложения завершите открытый сеанс Terminal.").font(.system(size: 11)).foregroundStyle(StudioStyle.accent) }
                }.padding(.top, 8)
            }.font(.system(size: 12))
        }
    }
}

private struct TerminalConsoleCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ModemTerminalSession
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(session.status, systemImage: session.connected ? "terminal.fill" : "terminal")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Очистить") { session.clear() }.buttonStyle(.plain).font(.system(size: 11))
                if session.active {
                    Button("Отключить", action: model.closeTerminal).buttonStyle(StudioButtonStyle())
                } else {
                    Button("Открыть Terminal", action: model.openTerminal).buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage)
                }
            }.padding(12).background(StudioStyle.elevated)
            ModemTerminalView(session: session, resources: model.resources).frame(minHeight: 310, idealHeight: 350)
            HStack(spacing: 8) {
                Text("$").foregroundStyle(StudioStyle.accent)
                TextField("Команда shell", text: $model.opkgCommand).textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced)).onSubmit(model.sendTerminalCommand).disabled(!session.connected)
                Button("Ctrl+C") { session.send(Data([3])) }.buttonStyle(StudioButtonStyle()).disabled(!session.connected)
                Button("Выполнить", action: model.sendTerminalCommand).buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!session.connected || model.opkgCommand.isEmpty)
            }.padding(12)
        }.background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.line, lineWidth: 1))
    }
}
