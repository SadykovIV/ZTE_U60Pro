import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
    var vpnPage: some View { VPNPanel(model: model) }
}

@MainActor private struct VPNPanel: View {
    @ObservedObject var model: AppModel
    @StudioState private var uri = ""
    @StudioState private var importName = ""
    @StudioState private var importKind = "uri"
    @StudioState private var configuration = ""
    @StudioState private var subscriptionURL = ""
    @StudioState private var subscriptionName = ""
    @StudioState private var profileSearch = ""
    @StudioState private var selectedID = ""
    @StudioState private var renameName = ""
    @StudioState private var inputError = ""
    @StudioState private var pending: VPNOperation?
    @StudioState private var confirmationText = ""
    @StudioState private var confirmationPresented = false
    @StudioState private var wifi = VPNWiFiDraft()
    private var status: VPNStatus? { model.vpnInspection?.status }
    private var selected: VPNProfile? { status?.profiles.first { $0.id == selectedID } }
    private var ready: Bool { model.canManage && model.vpnInspection?.helperReady == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "network", text: "Профили VPN хранятся на модеме. Программа управляет ими по SSH; те же профили доступны в агенте и на экране модема. Wi-Fi с VPN использует выбранный профиль, основная сеть сохраняет обычное подключение.")
            components
            profiles
            importer
            subscriptions
            wifiSettings
            if !model.vpnError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.vpnError) }
            if !inputError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: inputError) }
        }
        .alert(L10n.text("Подтверждение операции VPN"), isPresented: $confirmationPresented) {
            Button(L10n.text("Отмена"), role: .cancel) { pending = nil }
            Button(L10n.text("Подтвердить")) { if let operation = pending { pending = nil; model.performVPNProfile(operation) } }
        } message: { Text(confirmationText) }
        .onChange(of: selectedID) { _ in renameName = selected?.name ?? "" }
        .onChange(of: model.busy) { busy in
            if !busy { wifi.refresh(status); if selected == nil { selectedID = "" }; renameName = selected?.name ?? "" }
        }
        .onAppear { wifi.refresh(status) }
        .onDisappear { uri = ""; configuration = ""; subscriptionURL = ""; wifi.password = ""; wifi.confirmation = ""; pending = nil }
    }

    private var components: some View {
        StudioCard {
            HStack {
                Text(L10n.text("Компоненты VPN")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(L10n.text("Обновить состояние VPN"), action: model.refreshVPN).buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
            }
            if let check = model.vpnInspection {
                Text(L10n.text(check.helperReady ? "Менеджер VPN установлен" : check.status.installed ? "Компоненты VPN требуют обновления" : "Компоненты VPN не установлены"))
                if !check.missingCapabilities.isEmpty { Text(L10n.text("В прошивке отсутствуют необходимые компоненты: ") + check.missingCapabilities.joined(separator: ", ")).foregroundStyle(StudioStyle.warning) }
            }
            if model.vpnInspection?.helperReady != true {
                Button(L10n.text("Установить / обновить компоненты VPN"), action: model.installVPN)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage)
            }
            Text(L10n.text("Установка добавляет контроллер и ядро VPN. Агент и страницы экрана устанавливаются отдельно в своих разделах."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        }
    }

    private var profiles: some View {
        StudioCard {
            Text(L10n.text("Профили VPN")).font(.system(size: 18, weight: .semibold))
            if let status {
                Text(L10n.text(status.enabled ? "Wi-Fi с VPN включён" : "Wi-Fi с VPN выключен"))
                    .foregroundStyle(status.enabled ? StudioStyle.accent : StudioStyle.secondary)
                if status.profiles.isEmpty { Text(L10n.text("Профили не добавлены")).foregroundStyle(StudioStyle.secondary) }
                TextField(L10n.text("Поиск профилей"), text: $profileSearch).textFieldStyle(.roundedBorder)
                ForEach(status.profiles.filter { profileSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(profileSearch) || ($0.protocolName ?? "vless").localizedCaseInsensitiveContains(profileSearch) }) { profile in
                    let warnings = profile.warnings.compactMap(VPNSettingsManager.warning)
                    Button { selectedID = profile.id } label: {
                        HStack {
                            Image(systemName: selectedID == profile.id ? "largecircle.fill.circle" : "circle")
                            Text(profile.name).fontWeight(.semibold)
                            Text((profile.protocolName ?? "vless").uppercased()).font(.caption).foregroundStyle(StudioStyle.secondary)
                            if !profile.transport.isEmpty { Text(profile.transport).font(.caption).foregroundStyle(StudioStyle.secondary) }
                            if !warnings.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioStyle.warning)
                                    .help(warnings.map { L10n.text($0) }.joined(separator: "\n"))
                            }
                            Spacer()
                            if profile.subscriptionId != nil { Text(L10n.text("Подписка")).font(.caption) }
                            if profile.updateAvailable == true { Text(L10n.text("Есть обновление")).font(.caption).foregroundStyle(StudioStyle.warning) }
                            if profile.removedFromSubscription == true { Text(L10n.text("Сохранён из прежней подписки")).font(.caption).foregroundStyle(StudioStyle.secondary) }
                            if profile.active { Text(L10n.text("Активен")).foregroundStyle(StudioStyle.accent) }
                        }.padding(12).background(StudioStyle.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(model.busy)
                }
                HStack {
                    Button(L10n.text("Сделать активным")) {
                        guard let profile = selected else { return }
                        confirm(.activate(profile.id), "Выбрать профиль VPN? При первой активации будет настроена и включена сеть Wi-Fi с VPN. При смене работающего профиля VPN переподключится.")
                    }.buttonStyle(StudioButtonStyle()).disabled(!ready || selected?.canActivate != true)
                    Button(L10n.text(status.enabled ? "Выключить Wi-Fi с VPN" : "Включить Wi-Fi с VPN")) {
                        confirm(.setEnabled(!status.enabled), status.enabled ? "Выключить Wi-Fi с VPN? Устройства этой сети потеряют подключение." : "Включить Wi-Fi с VPN с выбранным профилем?")
                    }.buttonStyle(StudioButtonStyle()).disabled(!ready || (!status.enabled && status.activeProfile.isEmpty))
                    Button(L10n.text("Удалить профиль"), role: .destructive) {
                        guard let profile = selected else { return }
                        confirm(.delete(profile.id), "Удалить выбранный профиль VPN? Для повторного импорта понадобится исходная ссылка.")
                    }.buttonStyle(StudioButtonStyle()).disabled(!ready || selected == nil || selected?.active == true)
                }
                if selected != nil {
                    HStack {
                        TextField(L10n.text("Название профиля"), text: $renameName).textFieldStyle(.roundedBorder)
                        Button(L10n.text("Переименовать")) {
                            if let selected { confirm(.rename(selected.id, renameName), "Сохранить новое название выбранного профиля VPN?") }
                        }.buttonStyle(StudioButtonStyle()).disabled(!ready || renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(L10n.text("Активный профиль можно удалить после выбора другого профиля."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
            } else { Text(L10n.text("Обновите состояние, чтобы прочитать профили с модема.")).foregroundStyle(StudioStyle.secondary) }
        }
    }

    private var importer: some View {
        StudioCard {
            Text(L10n.text("Добавить профиль VPN")).font(.system(size: 18, weight: .semibold))
            Picker(L10n.text("Формат профиля"), selection: $importKind) {
                Text(L10n.text("Ссылка VLESS / Hysteria2")).tag("uri")
                Text(L10n.text("Конфигурация WireGuard / AmneziaWG")).tag("config")
            }.pickerStyle(.segmented).disabled(model.busy)
            Text(L10n.text("Можно вставить ссылку VLESS / Hysteria2 или конфигурацию WireGuard / AmneziaWG .conf. Другие протоколы доступны через подписку."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            if importKind == "uri" { SecureField("vless://… / hy2://…", text: $uri).textFieldStyle(.roundedBorder).disabled(model.busy) }
            else { TextEditor(text: $configuration).font(.system(.caption, design: .monospaced)).frame(height: 120).disabled(model.busy) }
            TextField(L10n.text("Название профиля (необязательно)"), text: $importName).textFieldStyle(.roundedBorder).disabled(model.busy)
            HStack {
                Button(L10n.text("Вставить из буфера")) {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    if importKind == "uri" { uri = text } else { configuration = text }
                }.buttonStyle(StudioButtonStyle()).disabled(model.busy)
                Button(L10n.text("Открыть файл профиля"), action: chooseProfile).buttonStyle(StudioButtonStyle()).disabled(model.busy)
                Spacer()
                Button(L10n.text("Импортировать профиль")) {
                    let operation: VPNOperation = importKind == "uri" ? .importProfile(uri: uri, name: importName) : .importConfiguration(config: configuration, name: importName)
                    do { try operation.validate(); uri = ""; configuration = ""; inputError = ""; model.performVPNProfile(operation) }
                    catch { inputError = error.localizedDescription }
                }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(!ready || (importKind == "uri" ? uri.isEmpty : configuration.isEmpty))
            }
            Text(L10n.text("Импорт сохраняет профиль без активации. Ссылка не записывается в журнал программы."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        }
    }

    private var subscriptions: some View {
        StudioCard {
            Text(L10n.text("Подписки VPN")).font(.system(size: 18, weight: .semibold))
            Text(L10n.text("Подписка загружается через интернет компьютера. Импорт и обновление сохраняют профили без переключения текущего подключения."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            ForEach(status?.subscriptions ?? []) { subscription in
                HStack {
                    VStack(alignment: .leading) {
                        Text(subscription.name).fontWeight(.semibold)
                        Text(subscription.host + " · " + String(subscription.profileCount)).font(.caption).foregroundStyle(StudioStyle.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Обновить подписку")) { model.performVPNProfile(.updateSubscription(subscription.id)) }
                        .buttonStyle(StudioButtonStyle()).disabled(!ready)
                    Button(L10n.text("Удалить подписку"), role: .destructive) {
                        confirm(.deleteSubscription(subscription.id), "Удалить подписку? Уже импортированные профили останутся на модеме.")
                    }.buttonStyle(StudioButtonStyle()).disabled(!ready)
                }
            }
            SecureField(L10n.text("Ссылка подписки HTTPS"), text: $subscriptionURL).textFieldStyle(.roundedBorder).disabled(model.busy)
            TextField(L10n.text("Название подписки (необязательно)"), text: $subscriptionName).textFieldStyle(.roundedBorder).disabled(model.busy)
            Button(L10n.text("Добавить подписку")) {
                let operation = VPNOperation.importSubscription(url: subscriptionURL, name: subscriptionName)
                do { try operation.validate(); inputError = ""; subscriptionURL = ""; model.performVPNProfile(operation) }
                catch { inputError = error.localizedDescription }
            }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(!ready || subscriptionURL.isEmpty)
            if let summary = status?.lastImport {
                Text(L10n.text("Последний импорт / обновление подписки")).font(.caption).fontWeight(.semibold)
                Text(L10n.text("Добавлено:") + " \(summary.added) · " + L10n.text("Обновлено:") + " \(summary.updated) · " + L10n.text("Удалено:") + " \(summary.removed) · " + L10n.text("Дубликатов:") + " \(summary.duplicates)")
                    .font(.caption)
                if summary.retainedActive > 0 { Text(L10n.text("Активный профиль сохранён. Чтобы применить новые настройки, выберите его и нажмите «Сделать активным».")) .font(.caption).foregroundStyle(StudioStyle.warning) }
                if !summary.skipped.isEmpty {
                    DisclosureGroup(L10n.text("Пропущенные записи") + " (\(summary.skipped.count))") {
                        ForEach(Array(summary.skipped.enumerated()), id: \.offset) { _, skipped in
                            Text("#\(skipped.index): " + L10n.text(VPNSettingsManager.message(skipped.code))).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var wifiSettings: some View {
        StudioCard {
            Text(L10n.text("Настройки Wi-Fi с VPN")).font(.system(size: 18, weight: .semibold))
            TextField(L10n.text("Название сети"), text: Binding(get: { wifi.ssid }, set: { wifi.ssid = $0; wifi.isDirty = true })).textFieldStyle(.roundedBorder)
            Picker(L10n.text("Пароль Wi-Fi"), selection: Binding(get: { wifi.passwordMode }, set: { wifi.setPasswordMode($0) })) {
                ForEach(VPNWiFiPasswordMode.allCases.filter { $0 != .preserve || status?.configured == true }) { mode in Text(L10n.text(mode.title)).tag(mode) }
            }
            if wifi.passwordMode == .custom {
                SecureField(L10n.text("Пароль Wi-Fi"), text: Binding(get: { wifi.password }, set: { wifi.password = $0; wifi.isDirty = true })).textFieldStyle(.roundedBorder)
                SecureField(L10n.text("Повторите пароль"), text: Binding(get: { wifi.confirmation }, set: { wifi.confirmation = $0; wifi.isDirty = true })).textFieldStyle(.roundedBorder)
            }
            Button(L10n.text("Сохранить настройки Wi-Fi")) {
                do {
                    try wifi.validate(configured: status?.configured == true)
                    inputError = ""
                    model.saveVPNWiFi(wifi.configuration) { success in if success { wifi.saved(status) } }
                } catch { inputError = error.localizedDescription }
            }.buttonStyle(StudioButtonStyle()).disabled(!ready || status?.enabled == true)
            Text(L10n.text("Название и пароль можно менять, когда Wi-Fi с VPN выключен."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        }.disabled(model.busy)
    }

    private func confirm(_ operation: VPNOperation, _ text: String) {
        do { try operation.validate(); inputError = ""; pending = operation; confirmationText = L10n.text(text); confirmationPresented = true }
        catch { inputError = error.localizedDescription }
    }
    private func chooseProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "conf") ?? .data]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let data = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard let value = String(data: data, encoding: .utf8), data.count <= 8 * 1024 * 1024 else { throw IMEIError.message("Нужен текстовый файл профиля UTF-8, не больше 8 МиБ.") }
            let link = value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
            if VPNOperation.isProfileLink(link) {
                try VPNOperation.importProfile(uri: link, name: importName).validate()
                importKind = "uri"; uri = link.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                try VPNOperation.importConfiguration(config: link, name: importName).validate()
                importKind = "config"; configuration = link
            }
            inputError = ""
        } catch { inputError = "Не удалось открыть профиль UTF-8. Допустимы ссылка VLESS / Hysteria2 или файл .conf до 8 МиБ." }
    }
}
