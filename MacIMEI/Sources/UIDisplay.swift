import SwiftUI
import AppKit

enum LauncherSection: String, CaseIterable, Identifiable {
    case information, vpn, esim
    var id: String { rawValue }
    var title: String {
        switch self { case .information: return "Информация о модеме"; case .vpn: return "Управление VPN"; case .esim: return "eSIM" }
    }
}

extension ContentView {
    var displayPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioCard {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("Плитки на экране модема")).font(.system(size: 18, weight: .semibold))
                        Text(L10n.text("Отметьте дополнительные страницы и задайте их порядок. Home и Settings остаются на экране всегда."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Button(L10n.text(displayInstallTitle), action: model.installDisplay)
                            .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!canInstallDisplay)
                            .help(L10n.text("Установить страницы лаунчера с выбранным оформлением информационной страницы"))
                        Button(L10n.text("Проверить лаунчер"), action: model.refreshDisplay)
                            .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    }
                }
                if let state = model.displayInspection {
                    informationRow("Состояние", state.title)
                    Text(L10n.text(state.detail)).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning = state.layoutWarning, !warning.isEmpty {
                        Label(L10n.text(warning), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let warning = state.pagesWarning, !warning.isEmpty {
                        Label(L10n.text(warning), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label(L10n.text(model.activeChannel == .ssh ? "Перед установкой приложение проверит совместимость и текущее состояние лаунчера." : "Для установки подключитесь по SSH в разделе «Подготовка модема». Настройки можно выбрать заранее."), systemImage: "cable.connector")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("Установка может перезапустить экран. Профили и текущий режим установленного VPN сохраняются."))
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.displayError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.displayError) }
            if !model.displayLayoutMessage.isEmpty { StudioNote(symbol: "info.circle", text: model.displayLayoutMessage) }
            if !model.displayPagesMessage.isEmpty { StudioNote(symbol: "info.circle", text: model.displayPagesMessage) }
            LauncherPagesEditor(model: model)
            Picker(L10n.text("Страница лаунчера"), selection: $launcherSection) {
                ForEach(LauncherSection.allCases) { section in Text(L10n.text(section.title)).tag(section) }
            }.pickerStyle(.segmented)
            switch launcherSection {
            case .information: DisplayLayoutEditor(model: model)
            case .vpn: launcherVPNPage
            case .esim: EsimLauncherCard(model: model)
            }
            StudioNote(symbol: "hand.draw", text: "Показатели прокручиваются вверх и вниз. Горизонтальный свайп переключает страницы лаунчера. Поддерживается проверенный дисплей B31, включая русификацию. Для B02 и других сборок нужна отдельная проверка совместимости.")
        }
    }

    private var launcherVPNPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioCard {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(L10n.text("Управление VPN"), systemImage: "network").font(.system(size: 17, weight: .semibold))
                        Text(L10n.text("На экране модема можно включить Wi-Fi с VPN и выбрать профиль. Смена профиля требует подтверждения и переподключает VPN."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let check = model.vpnInspection {
                            launcherVPNStatusRow("Компоненты VPN", check.helperReady && check.agentReady && check.dashboardReady ? "Готовы" : "Требуется установка или обновление")
                            launcherVPNStatusRow("Wi-Fi с VPN", check.status.enabled ? "Включён" : "Выключен")
                            launcherVPNStatusRow("Профили", String(check.status.profiles.count))
                            if let active = check.status.profiles.first(where: \.active) {
                                launcherVPNStatusRow("Активный профиль", active.name)
                            }
                            if !check.missingCapabilities.isEmpty {
                                Text(L10n.text("Отсутствуют системные компоненты: " + check.missingCapabilities.joined(separator: ", ")))
                                    .font(.system(size: 11)).foregroundStyle(StudioStyle.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(L10n.text("Проверьте VPN, чтобы увидеть установленные компоненты и профили."))
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        }
                        Button(L10n.text("Обновить состояние VPN"), action: model.refreshVPN)
                            .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                        if model.vpnInspection == nil || model.vpnInspection?.helperReady != true || model.vpnInspection?.agentReady != true || model.vpnInspection?.dashboardReady != true || model.vpnInspection?.launcherReady != true {
                            Button(L10n.text(model.vpnInspection?.status.installed == true ? "Обновить компоненты VPN" : "Установить компоненты VPN"), action: model.installVPN)
                                .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.vpnInspection?.missingCapabilities.isEmpty == false)
                        }
                        Divider().overlay(StudioStyle.line)
                        Text(L10n.text("Импорт, названия и параметры профилей задаются в панели агента. На плитке появятся те же профили; длинный список листается кнопками «Назад» и «Далее»."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.text("Настроить профили в агенте")) {
                            var address = URLComponents()
                            address.scheme = "http"; address.host = model.host; address.port = 8080
                            if let url = address.url { NSWorkspace.shared.open(url) }
                        }.buttonStyle(StudioButtonStyle(prominent: true))
                            .disabled(!model.connected || model.vpnInspection?.dashboardReady != true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 13) {
                        Text(L10n.text("ПРЕДПРОСМОТР ЭКРАНА"))
                            .font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(StudioStyle.secondary)
                        ModemVPNPagePreview(status: model.vpnInspection?.status)
                        Text(L10n.text(model.vpnInspection == nil ? "Состояние появится после проверки VPN." : "Последнее прочитанное состояние модема.\nУправление — на модеме или в агенте."))
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }.frame(width: 240)
                }
            }
            VPNWiFiEditor(model: model)
            if !model.vpnError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.vpnError) }
        }
    }

    private func launcherVPNStatusRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(title)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
            Text(L10n.text(value)).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayInstallTitle: String {
        guard let state = model.displayInspection else { return "Установить плитки" }
        switch state.state {
        case .ready: return state.running ? "Плитки установлены" : "Запустить плитки"
        case .outdated, .failed: return "Обновить плитки"
        case .recoveryPending: return "Восстановить установку"
        case .absent, .unsupported: return "Установить плитки"
        }
    }

    private var canInstallDisplay: Bool {
        guard model.canManage, (1...ModemDisplayLayout.maximumEnabled).contains(model.displayLayout.enabledCount) else { return false }
        guard let state = model.displayInspection else { return true }
        return state.canInstall && !(state.state == .ready && state.running)
    }
}

@MainActor
private struct LauncherPagesEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        StudioCard {
            Text(L10n.text("Страницы и порядок")).font(.system(size: 17, weight: .semibold))
            Text(L10n.text("Чекбоксы включают страницы. Стрелки меняют порядок выбранных страниц после Home и Settings."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.displayPageRows) { page in
                pageRow(page)
            }
            Divider().overlay(StudioStyle.line)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(model.displaySavedPages == nil ? "Выбор подготовлен локально" : model.displayPagesChanged ? "Есть неприменённые изменения страниц" : "Выбор совпадает с сохранённым на модеме"))
                        .font(.system(size: 12, weight: .medium))
                    if let saved = model.displaySavedPages {
                        Text(L10n.text("На модеме:") + " Home → Settings" + saved.pages.map { " → " + L10n.text($0.title) }.joined())
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    }
                    Text(L10n.text(model.displayPages.pages.isEmpty ? "Все дополнительные страницы отключены. Останутся только Home и Settings." : "Выбор и порядок сохраняются без перезапуска экрана. До первой установки используйте кнопку «Установить плитки»."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L10n.text("Применить страницы"), action: model.applyDisplayPages)
                    .buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!model.canManage || model.displayInspection?.canApplyPages != true || !model.displayPagesChanged)
            }
        }
    }

    private func pageRow(_ page: ModemLauncherPage) -> some View {
        let index = model.displayPages.pages.firstIndex(of: page)
        return HStack(spacing: 10) {
            Toggle(L10n.text(page.title), isOn: Binding(get: { model.displayPages.pages.contains(page) }, set: { model.setDisplayPage(page, enabled: $0) }))
                .toggleStyle(.checkbox).disabled(model.busy)
            Spacer()
            if let index {
                Text(String(index + 1)).font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.secondary)
            }
            Button { model.moveDisplayPage(page, by: -1) } label: { Image(systemName: "chevron.up") }
                .help(L10n.text("Переместить выше")).disabled(model.busy || index == nil || index == 0)
            Button { model.moveDisplayPage(page, by: 1) } label: { Image(systemName: "chevron.down") }
                .help(L10n.text("Переместить ниже")).disabled(model.busy || index == nil || index == model.displayPages.pages.count - 1)
        }.padding(.vertical, 5)
    }
}

@MainActor
private struct VPNWiFiEditor: View {
    @ObservedObject var model: AppModel
    @StudioState private var draft = VPNWiFiDraft()
    @StudioState private var saved = false

    private var status: VPNStatus? { model.vpnInspection?.status }
    private var editable: Bool { model.canManage && model.vpnInspection?.helperReady == true && status?.settingsSupported == true && status?.enabled == false }
    private var validationMessage: String? {
        do { try draft.validate(configured: status?.configured == true); return nil }
        catch { return error.localizedDescription }
    }
    private var endpoint: String { model.host + ":" + model.port + ":" + String(model.connected) + ":" + String(describing: model.activeChannel) }

    var body: some View {
        StudioCard {
            Label(L10n.text("Сеть Wi-Fi с VPN"), systemImage: "wifi").font(.system(size: 17, weight: .semibold))
            if let status {
                if status.configured {
                    Text(L10n.text("SSID на модеме: ") + (status.actualSSID.isEmpty ? L10n.text("не прочитан") : status.actualSSID))
                        .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    if let second = status.ssid2G, let fifth = status.ssid5G, second != fifth {
                        Text(L10n.text("2,4 ГГц: ", "2.4 GHz: ") + second + L10n.text(" · 5 ГГц: ", " · 5 GHz: ") + fifth).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    }
                } else {
                    Text(L10n.text("VPN-сеть ещё не создана. По умолчанию: ZTE-VPN, пароль основной сети."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("Название сети (SSID)")).font(.system(size: 12, weight: .medium))
                    TextField(L10n.text("ZTE-VPN"), text: Binding(get: { draft.ssid }, set: { draft.ssid = $0; draft.isDirty = true; saved = false }))
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.text("До 32 байт UTF-8; одно название для 2,4 и 5 ГГц."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("Пароль VPN-сети")).font(.system(size: 12, weight: .medium))
                    Picker(L10n.text("Пароль VPN-сети"), selection: Binding(get: { draft.passwordMode }, set: { draft.setPasswordMode($0); saved = false })) {
                        if status?.configured == true { Text(L10n.text(VPNWiFiPasswordMode.preserve.title)).tag(VPNWiFiPasswordMode.preserve) }
                        Text(L10n.text(VPNWiFiPasswordMode.main.title)).tag(VPNWiFiPasswordMode.main)
                        Text(L10n.text(VPNWiFiPasswordMode.custom.title)).tag(VPNWiFiPasswordMode.custom)
                    }.labelsHidden()
                    Text(L10n.text(passwordDetail)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!editable)
            if draft.passwordMode == .custom {
                HStack(spacing: 20) {
                    SecureField(L10n.text("Новый пароль"), text: Binding(get: { draft.password }, set: { draft.password = $0; draft.isDirty = true; saved = false }))
                    SecureField(L10n.text("Повторите пароль"), text: Binding(get: { draft.confirmation }, set: { draft.confirmation = $0; draft.isDirty = true; saved = false }))
                }.textFieldStyle(.roundedBorder).disabled(!editable)
            }
            if let message = validationMessage, draft.isDirty {
                Text(L10n.text(message)).font(.system(size: 11)).foregroundStyle(StudioStyle.warning)
            }
            if status?.enabled == true {
                Label(L10n.text("Сначала выключите Wi-Fi с VPN на экране модема или в агенте. После этого обновите состояние."), systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.warning)
            } else if status?.settingsSupported != true {
                Text(L10n.text("Для настройки сети установите или обновите компоненты VPN кнопкой выше."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            HStack(alignment: .center, spacing: 16) {
                Text(L10n.text(saved ? "Настройки сохранены. Wi-Fi с VPN остаётся выключенным." : status?.wifiSettingsPending == true ? "Сохранённые настройки применятся при следующем включении Wi-Fi с VPN." : "Сохранение не включает сеть. Новое имя и пароль будут использоваться при следующем включении Wi-Fi с VPN."))
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.text("Сохранить настройки сети")) {
                    model.saveVPNWiFi(draft.configuration) { success in
                        if success { draft.saved(model.vpnInspection?.status); saved = true }
                    }
                }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(!editable || validationMessage != nil)
            }
        }
        .onReceive(model.$vpnInspection) { inspection in draft.refresh(inspection?.status); if inspection == nil { saved = false } }
        .onChange(of: endpoint) { _ in draft = VPNWiFiDraft(); saved = false }
        .onDisappear { draft.password = ""; draft.confirmation = "" }
    }
    private var passwordDetail: String {
        switch draft.passwordMode {
        case .main:
            let network = status?.mainSsid.flatMap { $0.isEmpty ? nil : $0 }.map { " «" + $0 + "»" } ?? ""
            return "Модем скопирует пароль и тип защиты основной сети" + network + ". Пароль не передаётся в приложение."
        case .custom: return "8–63 печатных символа ASCII или 64 символа HEX. Защита WPA2-PSK (CCMP)."
        case .preserve: return "Изменится только имя сети; текущие пароль и тип защиты сохранятся."
        }
    }
}

@MainActor
private struct DisplayLayoutEditor: View {
    @ObservedObject var model: AppModel
    @StudioState private var draggedMetric: ModemDisplayMetric?
    @StudioState private var dropTarget: ModemDisplayMetric?
    @StudioState private var dropAfter = false

    private let rowHeight: CGFloat = 72

    var body: some View {
        StudioCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(L10n.text("Информация о модеме"), systemImage: "chart.bar.xaxis")
                        .font(.system(size: 17, weight: .semibold))
                    Text(L10n.text("Отметьте показатели и перетащите их за ручку справа, чтобы изменить порядок на экране модема."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L10n.text("По умолчанию"), action: model.resetDisplayLayout)
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy || model.displayLayout == .defaultLayout)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(L10n.text("ПОКАЗАТЕЛИ")).font(.system(size: 9, weight: .semibold)).tracking(1.1)
                        Spacer()
                        Text(L10n.text("\(model.displayLayout.enabledCount) из 12"))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.accent)
                    }.foregroundStyle(StudioStyle.secondary)
                    VStack(spacing: 5) {
                        ForEach(model.displayLayout.items, id: \.id) { item in
                            metricRow(item)
                        }
                    }.coordinateSpace(name: "displayMetricRows")
                    Text(L10n.text(limitMessage))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .center, spacing: 13) {
                    Text(L10n.text("ПРЕДПРОСМОТР ЭКРАНА"))
                        .font(.system(size: 9, weight: .semibold)).tracking(1.1)
                        .foregroundStyle(StudioStyle.secondary)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("Тип страницы на модеме")).font(.system(size: 12, weight: .medium))
                        Picker(L10n.text("Тип страницы на модеме"), selection: Binding(get: { model.displayLayout.style }, set: { model.setDisplayStyle($0) })) {
                            ForEach(ModemDisplayPageStyle.allCases) { style in Text(L10n.text(style.title)).tag(style) }
                        }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
                    }
                    ModemDisplayLayoutPreview(layout: model.displayLayout)
                    Text(L10n.text("Выбранное оформление будет на модеме.\nДанные для примера."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Label(L10n.text("Листайте вверх и вниз"), systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                }.frame(width: 240)
            }
            Divider().overlay(StudioStyle.line)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(saveStatus)).font(.system(size: 12, weight: .medium))
                    Text(L10n.text(actionDetail)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L10n.text("Применить настройки"), action: performAction)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!canPerformAction)
            }
            Text(L10n.text("Недоступные значения на модеме обозначаются прочерком, устаревшие — звёздочкой. Несущие показывают активные подключения, а не разрешённые диапазоны."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: model.busy) { if $0 { clearDrag() } }
    }

    private var limitMessage: String {
        if model.displayLayout.enabledCount == 1 {
            return "На странице должен остаться хотя бы один показатель. Можно выбрать все 12."
        }
        return "Можно выбрать все 12 показателей. И список, и плитки прокручиваются на модеме; неотмеченные показатели скрыты."
    }

    private var saveStatus: String {
        guard let state = model.displayInspection else { return "Макет подготовлен локально" }
        if state.state == .absent { return "Выбранный набор будет установлен на модем" }
        if model.displaySavedLayout != nil {
            return model.displayLayoutChanged ? "Есть неприменённые изменения" : "Настройки совпадают с сохранёнными на модеме"
        }
        return "Выберите показатели для экрана модема"
    }

    private var actionDetail: String {
        guard let state = model.displayInspection else {
            return "Кнопка «Установить плитки» находится вверху. Если они уже установлены, нажмите «Проверить лаунчер», чтобы прочитать их настройки."
        }
        if state.state == .ready {
            return "Тип страницы, состав и порядок показателей сохраняются на модеме без переустановки плиток."
        }
        if state.state == .unsupported { return state.detail }
        return "Сначала установите или обновите плитки кнопкой вверху. Выбранные показатели будут сохранены при установке."
    }

    private var canPerformAction: Bool {
        guard model.canManage, let state = model.displayInspection,
              (1...ModemDisplayLayout.maximumEnabled).contains(model.displayLayout.enabledCount) else { return false }
        return state.canApplyLayout && model.displayLayoutChanged
    }

    private func performAction() {
        clearDrag()
        model.applyDisplayLayout()
    }

    private func metricRow(_ item: ModemDisplayLayoutItem) -> some View {
        let metric = item.metric
        let index = model.displayLayout.items.firstIndex { $0.metric == metric } ?? 0
        let checkboxDisabled = model.busy || (item.enabled && model.displayLayout.enabledCount == 1)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { item.enabled }, set: { model.setDisplayMetric(metric, enabled: $0) })) {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: metric.symbol).foregroundStyle(item.enabled ? StudioStyle.accent : StudioStyle.secondary)
                        .font(.system(size: 13)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text(metric.title)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.enabled ? StudioStyle.text : StudioStyle.secondary)
                            .lineLimit(2)
                        Text(L10n.text(metric.detail)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                            .lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.checkbox).disabled(checkboxDisabled)
            .help(L10n.text(checkboxDisabled && !model.busy ? limitMessage : "Показывать на информационной странице модема"))
            VStack(spacing: 3) {
                Button { move(metric, delta: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(model.busy || index == 0)
                    .accessibilityLabel(L10n.text("Выше: \(metric.title)")).help(L10n.text("Переместить выше"))
                Button { move(metric, delta: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(model.busy || index == model.displayLayout.items.count - 1)
                    .accessibilityLabel(L10n.text("Ниже: \(metric.title)")).help(L10n.text("Переместить ниже"))
            }
            .font(.system(size: 9, weight: .semibold)).buttonStyle(.borderless)
            .foregroundStyle(StudioStyle.secondary)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(StudioStyle.secondary)
                .frame(width: 23, height: 44).contentShape(Rectangle())
                .help(L10n.text("Перетащите, чтобы изменить порядок"))
                .accessibilityLabel(L10n.text("Перетащить: \(metric.title)"))
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("displayMetricRows"))
                    .onChanged { value in
                        guard !model.busy else { return }
                        draggedMetric = metric
                        updateDragTarget(at: value.location.y)
                    }
                    .onEnded { value in
                        guard !model.busy else { clearDrag(); return }
                        updateDragTarget(at: value.location.y)
                        if let target = dropTarget, let index = model.displayLayout.items.firstIndex(where: { $0.metric == target }) {
                            let order = model.displayLayout.items.map(\.metric)
                            let before = dropAfter ? (index + 1 < order.count ? order[index + 1] : nil) : target
                            if metric != target && before != metric { model.moveDisplayMetric(metric, before: before) }
                        }
                        clearDrag()
                    })
                .allowsHitTesting(!model.busy)
        }
        .padding(.horizontal, 10).frame(height: rowHeight)
        .background(item.enabled ? StudioStyle.elevated : StudioStyle.canvas.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: dropAfter ? .bottom : .top) {
            if dropTarget == metric && draggedMetric != metric {
                RoundedRectangle(cornerRadius: 1).fill(StudioStyle.accent).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .opacity(draggedMetric == metric ? 0.65 : 1)
    }

    private func move(_ metric: ModemDisplayMetric, delta: Int) {
        let order = model.displayLayout.items.map(\.metric)
        guard let index = order.firstIndex(of: metric) else { return }
        let destination = index + delta
        guard order.indices.contains(destination) else { return }
        let before = delta < 0 ? order[destination] : (destination + 1 < order.count ? order[destination + 1] : nil)
        model.moveDisplayMetric(metric, before: before)
    }

    private func updateDragTarget(at y: CGFloat) {
        let items = model.displayLayout.items
        guard y.isFinite, !items.isEmpty else { return }
        let index = min(items.count - 1, max(0, Int(y / (rowHeight + 5))))
        dropTarget = items[index].metric
        dropAfter = y - CGFloat(index) * (rowHeight + 5) >= rowHeight / 2
    }

    private func clearDrag() {
        draggedMetric = nil; dropTarget = nil; dropAfter = false
    }
}
