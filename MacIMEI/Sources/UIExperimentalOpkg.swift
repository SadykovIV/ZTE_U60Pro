import SwiftUI

extension ContentView {
    var opkgApplicationCard: some View {
        ApplicationTile(name: "opkg", version: "Экспериментально",
                        summary: verifiedCatalog.entry("opkg")?.description(language: L10n.language) ?? "Адаптер менеджера пакетов OpenWrt для отдельного хранилища на /data.",
                        installed: model.experimentalOpkgStatus?.installed,
                        verification: verifiedCatalog.entry("opkg")?.verification.summary.text(language: L10n.language)) {
            if model.experimentalOpkgStatus?.installed == true {
                HStack(spacing: 8) {
                    Button(L10n.text("Терминал")) { applicationSection = .opkg }.buttonStyle(StudioButtonStyle())
                    Spacer(minLength: 0)
                    Button(L10n.text("Удалить"), action: model.removeExperimentalOpkg).buttonStyle(StudioButtonStyle())
                        .disabled(!model.canManage || model.experimentalOpkgStatus?.running == true)
                }
            } else {
                Button(L10n.text("Установить"), action: model.installExperimentalOpkg).buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!verifiedCatalog.allows("opkg") || !model.canManage || model.experimentalOpkgStatus == nil)
            }
        }
    }
    func experimentalPackageCard(_ package: ExperimentalOpkgPackage) -> some View {
        ApplicationTile(name: package.name, version: package.version,
                        summary: package.summary.isEmpty ? "Пакет из отдельного хранилища opkg. Подробности: opkg info \(package.name)." : package.summary, installed: true, statusText: "Установлено через opkg") {
            HStack(spacing: 8) {
                Button(L10n.text("Подробнее")) { model.opkgCommand = "opkg info " + package.name; applicationSection = .opkg }
                    .buttonStyle(StudioButtonStyle())
                Spacer(minLength: 0)
                Button(L10n.text("Удалить")) { model.removeExperimentalPackage(package.name) }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canUseOpkgConsole || model.experimentalOpkgStatus?.running == true)
            }
        }
    }
    var experimentalOpkgPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Terminal")).font(.system(size: 18, weight: .semibold))
                Text(L10n.text("Для установки приложений через терминал на модеме должен быть установлен opkg. SSH-сеанс открывается автоматически при входе в этот раздел.", "To install applications from the terminal, opkg must be installed on the modem. The SSH session opens automatically when you enter this section."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                if model.experimentalOpkgStatus?.installed != true && model.terminalActive {
                    Button(L10n.text("Отключить терминал для установки opkg", "Disconnect terminal to install opkg"), action: model.closeTerminal)
                        .buttonStyle(StudioButtonStyle())
                }
                if !model.connected || model.activeChannel != .ssh {
                    StudioNote(symbol: "cable.connector", text: L10n.text("Для терминала подключитесь к модему по SSH в разделе «Настройка подключения».", "Connect to the modem over SSH in Connection settings to use the terminal."))
                }
            }
            TerminalConsoleCard(model: model, session: model.terminalSession)
            if !model.terminalError.isEmpty { applicationError(model.terminalError) }
            if model.experimentalOpkgStatus?.installed != true {
                opkgApplicationCard
                if !verifiedCatalog.allows("opkg") {
                    StudioNote(symbol: "info.circle", text: L10n.text("Установка opkg сейчас недоступна в проверенном каталоге.", "opkg installation is currently unavailable in the verified catalog."))
                }
            }
            if !model.experimentalOpkgError.isEmpty { applicationError(model.experimentalOpkgError) }
            HStack {
                Text(L10n.text(model.experimentalOpkgStatus?.installed == true ? "Адаптер opkg установлен · пакетов: \(model.experimentalOpkgStatus?.packages.count ?? 0)" : "Установите адаптер opkg для пакетов в /data"))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                Spacer()
                Button(L10n.text("Проверить opkg"), action: model.refreshExperimentalOpkg).buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                if model.experimentalOpkgStatus?.canRollback == true {
                    Button(L10n.text("Откатить"), action: model.rollbackExperimentalOpkg).buttonStyle(StudioButtonStyle())
                        .disabled(!model.canManage || model.experimentalOpkgStatus?.running == true)
                }
            }
            DisclosureGroup(L10n.text("Установка пакетов через opkg")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Среда адаптера: OpenWrt \(model.opkgFeeds?.release ?? "23.05.4") · архитектура \(model.opkgFeeds?.architecture ?? "aarch64_cortex-a53")."))
                        .font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                    Text(L10n.text("1. Установите адаптер opkg. Если терминал открыт, сначала отключите сеанс.\n2. В терминале обновите список пакетов.\n3. Найдите пакет, прочитайте описание и установите его.", "1. Install the opkg adapter. Disconnect the terminal session first if it is open.\n2. Update the package list in the terminal.\n3. Find a package, read its description and install it."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    Text(L10n.text("opkg update\nopkg list '*iperf*'\nopkg info iperf3\nopkg install iperf3\nopkg list-installed\n# Удаление: opkg remove iperf3"))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(L10n.text("В этом сеансе opkg — функция для адаптера /data/zte-imei-apps/opkg-private/opkg. Он устанавливает совместимые пользовательские пакеты в отдельное хранилище и сохраняет откат. Штатный менеджер доступен как /bin/opkg; он работает с системной базой. Остальные команды выполняются обычным shell с правами root. Для своих команд доступны перенаправления, конвейеры, скрипты и интерактивные программы."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    Text(L10n.text("Для адаптера выбирайте пакеты OpenWrt 23.05.4 / aarch64_cortex-a53. Модули ядра и системные службы требуют отдельной совместимости с прошивкой модема. Настройки источников ниже относятся только к приватному адаптеру."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                }.padding(.top, 8)
            }.font(.system(size: 12))
            DisclosureGroup(L10n.text("Источники пакетов opkg")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Формат: src/gz имя https://адрес/каталога. Сохранение создаёт новую конфигурацию адаптера и очищает кэш доступных пакетов; затем выполните opkg update."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    TextEditor(text: $model.opkgFeedsDraft).font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 145).scrollContentBackground(.hidden).padding(8)
                        .background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!model.canUseOpkgConsole || model.opkgFeeds == nil)
                    HStack {
                        Button(L10n.text("Прочитать с модема"), action: model.loadOpkgFeeds).buttonStyle(StudioButtonStyle()).disabled(!model.canUseOpkgConsole)
                        Button(L10n.text("Сохранить источники"), action: model.saveOpkgFeeds).buttonStyle(StudioButtonStyle(prominent: true))
                            .disabled(!model.canUseOpkgConsole || model.opkgFeeds == nil || model.opkgFeedsDraft == model.opkgFeeds?.text)
                    }
                    if !model.opkgFeedsMessage.isEmpty { Text(L10n.text(model.opkgFeedsMessage)).font(.system(size: 12)).textSelection(.enabled) }
                    if let feeds = model.opkgFeeds {
                        Text(L10n.text("Ключи подписи: " + feeds.keyFingerprints.joined(separator: ", ")))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.secondary).textSelection(.enabled)
                    }
                    Text(L10n.text("Проверка подписи сохраняется. Источник с другим ключом можно записать, но загрузка его индекса завершится ошибкой: импорт дополнительных ключей в этом редакторе пока не поддерживается."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    if model.terminalActive { Text(L10n.text("Для изменения источников и операций приложения завершите открытый сеанс Terminal.")).font(.system(size: 11)).foregroundStyle(StudioStyle.accent) }
                }.padding(.top, 8)
            }.font(.system(size: 12))
        }
    }
}

private struct TerminalConsoleCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ModemTerminalSession
    @StudioState private var autoOpenAttempted = false
    private func openWhenReady() {
        guard !autoOpenAttempted else { return }
        if session.active { autoOpenAttempted = true; return }
        guard model.canManage else { return }
        autoOpenAttempted = true
        model.openTerminal()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L10n.text(session.status), systemImage: session.connected ? "terminal.fill" : "terminal")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.text("Очистить")) { session.clear() }.buttonStyle(.plain).font(.system(size: 11))
                if session.active {
                    Button(L10n.text("Отключить"), action: model.closeTerminal).buttonStyle(StudioButtonStyle())
                } else {
                    Button(L10n.text("Открыть Terminal"), action: model.openTerminal).buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage)
                }
            }.padding(12).background(StudioStyle.elevated)
            ModemTerminalView(session: session, resources: model.resources).frame(minHeight: 310, idealHeight: 350)
            HStack(spacing: 8) {
                Text(L10n.text("$")).foregroundStyle(StudioStyle.accent)
                TextField(L10n.text("Команда shell"), text: $model.opkgCommand).textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced)).onSubmit(model.sendTerminalCommand).disabled(!session.connected)
                Button(L10n.text("Ctrl+C")) { session.send(Data([3])) }.buttonStyle(StudioButtonStyle()).disabled(!session.connected)
                Button(L10n.text("Выполнить"), action: model.sendTerminalCommand).buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!session.connected || model.opkgCommand.isEmpty)
            }.padding(12)
        }.background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.line, lineWidth: 1))
            .onAppear(perform: openWhenReady)
            .onChange(of: model.canManage) { _ in openWhenReady() }
    }
}
