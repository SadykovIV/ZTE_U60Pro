import AppKit
import SwiftUI

typealias StudioState<Value> = SwiftUI.State<Value>

enum StudioStyle {
    static let canvas = Color(red: 0.065, green: 0.075, blue: 0.085)
    static let sidebar = Color(red: 0.085, green: 0.100, blue: 0.110)
    static let surface = Color(red: 0.105, green: 0.122, blue: 0.133)
    static let elevated = Color(red: 0.130, green: 0.149, blue: 0.157)
    static let line = Color.white.opacity(0.075)
    static let text = Color(red: 0.920, green: 0.945, blue: 0.942)
    static let secondary = Color(red: 0.575, green: 0.633, blue: 0.646)
    static let accent = Color(red: 0.345, green: 0.830, blue: 0.735)
    static let warning = Color(red: 0.930, green: 0.735, blue: 0.420)
}

enum StudioPage: String, CaseIterable, Identifiable {
    case preparation = "Подготовка модема"
    case display = "Launcher"
    case imei = "IMEI"
    case ttl = "TTL"
    case vpn = "VPN"
    case applications = "Приложения (beta)"
    case administration = "Администрирование"
    case modem = "О модеме"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .modem: return "wifi.router"
        case .preparation: return "wrench.and.screwdriver"
        case .display: return "display"
        case .imei: return "simcard"
        case .ttl: return "slider.horizontal.3"
        case .applications: return "square.grid.2x2"
        case .vpn: return "network"
        case .administration: return "person.badge.key.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .modem: return "Устройство, система, память и диагностика"
        case .preparation: return "Подключение, ADB, агент и русский интерфейс"
        case .display: return "Плитки, показатели модема и управление VPN на экране"
        case .imei: return "Чтение, смена и резервные копии IMEI"
        case .ttl: return "Фиксация исходящего TTL и прибавка к входящему"
        case .applications: return "Установленные приложения и каталог"
        case .vpn: return "Проверка и установка компонентов VPN"
        case .administration: return "Доступы, резервные копии и журнал действий"
        }
    }
}
enum ModemSection: String, CaseIterable, Identifiable {
    case overview = "Об устройстве"
    case memory = "Память"
    case diagnostics = "Диагностика"
    var id: String { rawValue }
}
enum PreparationSection: String, CaseIterable, Identifiable {
    case connection = "Подключение и настройка"
    case agent = "Агент"
    case localization = "Русификация"
    var id: String { rawValue }
}
enum IMEISection: String, CaseIterable, Identifiable {
    case imei = "Смена IMEI"
    case backups = "Бэкапы IMEI"
    var id: String { rawValue }
}
enum AdministrationSection: String, CaseIterable, Identifiable {
    case access = "Доступы"
    case backups = "Бэкапы"
    case activity = "Журнал действий"
    var id: String { rawValue }
}
enum ApplicationSection: String, CaseIterable, Identifiable {
    case installed = "Установлено"
    case available = "Каталог"
    case opkg = "Terminal"
    var id: String { rawValue }
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    @StudioState var page: StudioPage = .preparation
    @StudioState var modemSection: ModemSection = .overview
    @StudioState var preparationSection: PreparationSection = .connection
    @StudioState var launcherSection: LauncherSection = .information
    @StudioState var imeiSection: IMEISection = .imei
    @StudioState var administrationSection: AdministrationSection = .access
    @StudioState var applicationSection: ApplicationSection = .installed
    @StudioState var expandedApplication: String?
    @StudioState var settingsExpanded = false
    @StudioState var copiedLog = false

    var selectedBackup: BackupItem? {
        model.backups.first { $0.id == model.selectedBackupID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(StudioStyle.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(StudioStyle.line).frame(height: 1)
                if model.skipFirmwareCheck {
                    Label(FirmwareCheck.warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(StudioStyle.warning)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(StudioStyle.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.warning.opacity(0.35)))
                        .padding(.horizontal, 30).padding(.top, 16)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.pendingOperation {
                            recoveryBanner
                        }
                        connectionSectionNotice
                        switch page {
                        case .modem: modemPage
                        case .preparation: preparationPage
                        case .display: displayPage
                        case .imei: imeiPage
                        case .ttl: ttlPage
                        case .applications: applicationsPage
                        case .vpn: vpnPage
                        case .administration: administrationPage
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                statusBar
            }
            .background(StudioStyle.canvas)
        }
        .frame(minWidth: 960, minHeight: 700)
        .foregroundStyle(StudioStyle.text)
        .tint(StudioStyle.accent)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshBackups() }
        .onChange(of: page) { model.recordNavigation($0.rawValue) }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(StudioStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(StudioStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("ZTE").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("IMEI STUDIO")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(2.0)
                        .foregroundStyle(StudioStyle.secondary)
                }
            }
            .padding(.top, 29)
            .padding(.bottom, 34)
            .padding(.horizontal, 22)

            Text("УПРАВЛЕНИЕ")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(StudioStyle.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            VStack(spacing: 5) {
                ForEach(StudioPage.allCases) { item in
                    Button {
                        page = item
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 19)
                            Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                            if page == item {
                                Circle().fill(StudioStyle.accent).frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(page == item ? StudioStyle.accent : StudioStyle.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(page == item ? StudioStyle.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 30)

            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Circle().fill(model.connected ? (model.activeChannel == .adb ? StudioStyle.warning : StudioStyle.accent) : StudioStyle.secondary)
                        .frame(width: 6, height: 6)
                    Text(model.connectionLabel)
                        .font(.system(size: 11, weight: .medium))
                }
                if model.connected && model.activeChannel == .adb {
                    Text("Ограниченный доступ").font(.system(size: 10)).foregroundStyle(StudioStyle.warning)
                }
                Text(model.host.isEmpty ? "192.168.0.1" : model.host)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(StudioStyle.secondary)
                Rectangle().fill(StudioStyle.line).frame(height: 1).padding(.vertical, 4)
                Text("U60 Pro / MU5250")
                    .font(.system(size: 11, weight: .medium))
                HStack {
                    Text(model.skipFirmwareCheck ? "Проверка отключена" : "Профиль B31")
                    Spacer()
                    Text("v\(model.appVersion)")
                }
                .font(.system(size: 10))
                .foregroundStyle(StudioStyle.secondary)
            }
            .padding(17)
            .background(StudioStyle.canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(14)
        }
        .frame(width: 250)
        .background(StudioStyle.sidebar)
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.rawValue).font(.system(size: 25, weight: .semibold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            Spacer(minLength: 20)
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text("macOS · ARM64")
            }
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(StudioStyle.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(Capsule().stroke(StudioStyle.line, lineWidth: 1))
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
    }

    @ViewBuilder var connectionSectionNotice: some View {
        if page != .preparation || preparationSection != .connection {
            if !model.connected {
                StudioNote(symbol: "cable.connector", text: "Нет подключения. Откройте «Подготовку модема» и подключитесь по SSH или USB ADB. Управление станет доступно после подключения по SSH.")
            } else if model.activeChannel == .adb {
                StudioNote(symbol: "info.circle", text: model.connectionCapabilityText)
            }
        }
        if model.connected && !model.busy {
            ForEach(pageRefreshErrors, id: \.0) { title, detail in
                StudioNote(symbol: "exclamationmark.triangle", text: title + ": " + detail)
            }
            if !pageRefreshErrors.isEmpty {
                Button("Повторить обновление разделов", action: model.refreshConnectedSections).buttonStyle(StudioButtonStyle())
            }
        }
    }
    var pageRefreshErrors: [(String, String)] {
        let sections: [ConnectionOverviewSection]
        switch page {
        case .modem: sections = [.information]
        case .display: sections = [] // The launcher has its own detailed error.
        case .vpn: sections = []
        case .ttl: sections = model.ttlStatus == nil ? [.ttl] : []
        case .applications: sections = model.applicationInventory == nil ? [.applications] : []
        case .preparation:
            switch preparationSection {
            case .connection: sections = []
            case .agent: sections = model.agentInstallationStatus == nil ? [.agent] : []
            case .localization: sections = model.screenLocalizationStatus == nil ? [.screen] : []
            }
        case .administration: sections = administrationSection == .access && model.accessState == nil ? [.access] : []
        case .imei: sections = []
        }
        return sections.compactMap { section in model.sectionRefreshErrors[section].map { (section.title, $0) } }
    }

    var modemPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Раздел настроек модема", selection: $modemSection) {
                ForEach(ModemSection.allCases) { section in Text(section.rawValue).tag(section) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Раздел настроек модема")
            switch modemSection {
            case .overview: modemOverview
            case .memory: memoryPage
            case .diagnostics: diagnosticsPage
            }
        }
    }

    var modemOverview: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.connected {
                StudioCard {
                    Text("Сведения о подключённом устройстве").font(.system(size: 18, weight: .semibold))
                    Text("Подключитесь в «Подготовке модема» по SSH или USB ADB. После подключения сведения и состояние разделов обновятся автоматически.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    Button("Перейти к подготовке") { page = .preparation }.buttonStyle(StudioButtonStyle())
                }
            }
            modemInformationCards
        }
    }

    var preparationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Подготовка модема", selection: $preparationSection) {
                ForEach(PreparationSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch preparationSection {
            case .connection: connectionPage
            case .agent: agentPreparationPage
            case .localization: localizationPage
            }
        }
    }

    var connectionPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioCard {
                HStack {
                    Label("Параметры подключения", systemImage: "wifi.router")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("MU5250 / U60 Pro").font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    StudioField(label: "АДРЕС МОДЕМА", placeholder: "192.168.0.1", text: $model.host)
                        .onChange(of: model.host) { _ in model.invalidateChannelConnection() }
                    StudioField(label: "SSH-ПОРТ", placeholder: "2222", text: $model.port)
                        .frame(width: 100)
                        .onChange(of: model.port) { _ in model.invalidateChannelConnection() }
                }.disabled(model.busy)
                HStack(alignment: .top, spacing: 14) {
                    connectionPasswordField("ПАРОЛЬ WEB", placeholder: "Пароль штатной панели", text: $model.webPassword)
                    connectionPasswordField("ПАРОЛЬ АГЕНТА", placeholder: "Текущий или новый пароль", text: $model.agentPassword)
                }.disabled(model.busy)
                connectionPasswordField("КЛЮЧ БЭКАПА (BACKUP-KEY SUFFIX)", placeholder: "Ключ для вашей прошивки", text: $model.backupSuffix).disabled(model.busy)
                HStack(alignment: .center, spacing: 14) {
                    Toggle("Не проверять прошивку", isOn: Binding(get: { model.skipFirmwareCheck }, set: { model.setFirmwareCheckSkipped($0) }))
                        .toggleStyle(.checkbox).font(.system(size: 12, weight: .medium)).disabled(model.busy)
                        .help("Отключает общую сверку версии и хэшей с B31 и разрешает повторную предварительную подготовку при доступном SSH. Проверки устройства, бэкапов, NV/EFS и ограничения установщиков сохраняются. При перезапуске приложения проверка включается снова.")
                    Spacer(minLength: 0)
                    Text("Пароли не сохраняются на Mac")
                        .font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                }
                DisclosureGroup(isExpanded: $settingsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("При подготовке ключ и доверие SSH создаются автоматически. Здесь можно выбрать файлы для уже подготовленного модема.")
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        pathSetting(label: "ПРИВАТНЫЙ SSH-КЛЮЧ", placeholder: "Путь к id_ed25519", text: $model.keyPath, action: model.chooseKey)
                        pathSetting(label: "ИЗВЕСТНЫЕ SSH-ХОСТЫ", placeholder: "Путь к known_hosts", text: $model.knownHostsPath, action: model.chooseKnownHosts)
                    }.padding(.top, 10).disabled(model.busy)
                } label: {
                    Label("Параметры SSH", systemImage: "key.horizontal")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.secondary)
                }
            }
            connectionRoutingCard
        }.onAppear {
            if !model.connectionsChecked && !model.busy { model.discoverConnectionsPassively() }
        }
    }
    func connectionPasswordField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(StudioStyle.secondary)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(12).background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(label == "ПАРОЛЬ WEB" ? "Пароль веб-интерфейса" : "Пароль агента")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    var currentPair: some View {
        HStack(spacing: 14) {
            IMEICard(slot: "01", title: "ТЕКУЩИЙ IMEI 1", value: model.currentIMEI1)
            IMEICard(slot: "02", title: "ТЕКУЩИЙ IMEI 2", value: model.currentIMEI2)
        }
    }

    var changePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "simcard", text: "Приложение читает IMEI обоих слотов из NV550 и проверяет их формат. Перед сменой обязательно сохраняет NV550 и EFS config с контрольными суммами, записывает новую пару и после перезагрузки сверяет результат. Копии доступны во вкладке «Бэкапы IMEI».")
            HStack {
                Text("Текущая пара").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Прочитать IMEI") { model.readIMEI() }.buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
            }
            currentPair

            StudioCard {
                StudioSectionTitle(number: "01", title: "Новые IMEI", detail: "Каждый номер должен содержать 15 цифр и корректную контрольную цифру.")
                HStack(alignment: .top, spacing: 16) {
                    StudioField(label: "IMEI 1", placeholder: "15 цифр", text: $model.imei1, large: true)
                    VStack(alignment: .trailing, spacing: 10) {
                        StudioField(label: "IMEI 2", placeholder: "15 цифр", text: $model.imei2, large: true)
                        Button(action: model.generateSecond) {
                            Label("Получить из первого", systemImage: "wand.and.stars")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioStyle.accent)
                        .disabled(model.busy || model.imei1.isEmpty)
                        .help("Сохранить TAC первого IMEI, увеличить серийную часть и пересчитать контрольную цифру")
                    }
                }
                .disabled(model.busy)
                .padding(.top, 4)

                if !model.validationMessage.isEmpty {
                    Label(model.validationMessage, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioStyle.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 15) {
                    Button(action: model.checkIMEI) {
                        Label("Проверить IMEI", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(model.busy)
                    Text(model.imeiCheckResult.isEmpty ? "Проверка формата, контрольной цифры и различия номеров. Статус в сетях операторов не проверяется." : model.imeiCheckResult)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioStyle.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            StudioCard {
                StudioSectionTitle(number: "02", title: "Обязательный бэкап перед записью", detail: "Перед каждой сменой приложение создаёт свежую копию NV550 обоих слотов и EFS config, затем проверяет контрольные суммы. Если бэкап не создан, запись не начнётся.")
                Button { imeiSection = .backups } label: { Label("Открыть бэкапы IMEI", systemImage: "externaldrive") }
                    .buttonStyle(StudioButtonStyle())
                HStack(spacing: 0) {
                    reviewColumn(label: "IMEI 1", oldValue: model.currentIMEI1, newValue: model.imei1)
                    Rectangle().fill(StudioStyle.line).frame(width: 1, height: 58).padding(.horizontal, 24)
                    reviewColumn(label: "IMEI 2", oldValue: model.currentIMEI2, newValue: model.imei2)
                }
                .padding(.vertical, 6)
                Rectangle().fill(StudioStyle.line).frame(height: 1)
                HStack(alignment: .center, spacing: 20) {
                    Text("Во время операции модем будет перезагружен. Оставьте приложение открытым и не отключайте питание до завершения.")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: model.apply) {
                        Label(model.connected ? "Записать оба IMEI" : "Настроить и записать IMEI", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!model.canApply || model.busy)
                    OperationInfoButton(topic: .imei)
                }
            }

            if !model.connected {
                StudioNote(symbol: "network", text: "Выберите SSH или автоматическое подключение и заполните пароли Web и агента в разделе «Подготовка модема». Кнопка «Настроить и записать IMEI» выполнит первоначальную настройку, прочитает текущую пару и создаст бэкап перед записью.")
            }
        }
    }

    var imeiBackupsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Button(action: model.backup) { Label("Создать бэкап IMEI", systemImage: "plus") }
                    .buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!model.canManage)
                Button(action: model.importBackup) { Label("Импортировать", systemImage: "square.and.arrow.down") }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(model.busy)
                Spacer(minLength: 0)
                Button(action: model.refreshBackups) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(model.busy)
                    .help("Обновить список")
                Button(action: model.revealBackups) { Image(systemName: "folder") }
                    .buttonStyle(StudioButtonStyle())
                    .help("Открыть папку бэкапов в Finder")
            }

            if model.backups.isEmpty {
                StudioCard {
                    VStack(spacing: 15) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(StudioStyle.secondary)
                        Text("Бэкапов пока нет").font(.system(size: 17, weight: .medium))
                        Text("Сохраните данные подключённого модема\nили импортируйте ранее созданный бэкап.")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioStyle.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("СОХРАНЁННЫЕ КОПИИ").tracking(1.1)
                        Spacer()
                        Text("\(model.backups.count)")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioStyle.secondary)
                    ForEach(model.backups) { backup in
                        backupRow(backup)
                    }
                }
            }

            if let backup = selectedBackup {
                StudioCard {
                    StudioSectionTitle(number: "↩", title: "Восстановить выбранную пару", detail: backup.date)
                    HStack(spacing: 30) {
                        valueColumn(label: "IMEI 1 ИЗ БЭКАПА", value: backup.imei1)
                        valueColumn(label: "IMEI 2 ИЗ БЭКАПА", value: backup.imei2)
                        Spacer(minLength: 0)
                    }
                    Text(backup.url.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StudioStyle.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(StudioStyle.line).frame(height: 1)
                    HStack(spacing: 16) {
                        Text("Будут восстановлены оба IMEI из этой копии. Перед записью приложение сохранит текущее состояние.")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: model.restore) {
                            Label("Восстановить IMEI", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(StudioButtonStyle(prominent: true))
                        .disabled(!model.connected || model.busy || model.pendingOperation || model.setupPending)
                    }
                }
            }

            StudioNote(symbol: "internaldrive", text: "Бэкапы хранятся локально на этом Mac. Сохраните отдельную копию папки, если планируете переносить приложение или переустанавливать систему.")
        }
    }

    var sshPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioCard {
                HStack {
                    StudioSectionTitle(number: "01", title: "Доступ по SSH", detail: "Отдельные учётные записи с входом по логину и паролю.")
                    Spacer()
                    Button(action: model.refreshSSHAccounts) { Label("Обновить", systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
                if model.sshAccountsLoaded {
                    Label(model.sshListenerReady ? "Служба входа по паролю запущена на порту 2223" : "Служба входа по паролю ещё не запущена", systemImage: model.sshListenerReady ? "checkmark.shield" : "person.crop.circle")
                        .font(.system(size: 12)).foregroundStyle(model.sshListenerReady ? StudioStyle.accent : StudioStyle.secondary)
                    if model.sshAccounts.isEmpty {
                        Text("Пользователей, созданных приложением, пока нет.").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                    ForEach(model.sshAccounts) { account in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle").foregroundStyle(StudioStyle.accent)
                            Text(account.name).font(.system(size: 13, weight: .medium, design: .monospaced))
                            Spacer()
                            Text(account.administrator ? "Администратор · doas" : "Пользователь").font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            Button("Удалить") { model.deleteSSHAccount(account.name) }.buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.sshRecoveryPending)
                        }
                    }
                } else {
                    Text("Подключите модем и обновите список пользователей.").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
                if model.sshRecoveryPending {
                    StudioNote(symbol: "exclamationmark.triangle", text: "Обнаружено незавершённое изменение учётных записей. Журнал сохранён в /data/zte-imei-admin/transactions; новая операция остановлена до восстановления.")
                    if model.sshRecoveryKind == .delete {
                        Button(action: model.recoverSSHDeletion) { Label("Восстановить прерванное удаление", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    }
                }
            }
            StudioCard {
                StudioSectionTitle(number: "02", title: "Новый администратор", detail: "После входа команда doas -s откроет root-shell с проверкой пароля пользователя.")
                StudioField(label: "ЛОГИН", placeholder: "Например, admin", text: $model.sshUsername)
                HStack(alignment: .top, spacing: 16) {
                    secureSetting(label: "ПАРОЛЬ SSH", placeholder: "Не менее 8 символов", text: $model.sshPassword)
                    secureSetting(label: "ПОВТОР ПАРОЛЯ", placeholder: "Повторите пароль", text: $model.sshPasswordConfirmation)
                }
                if !model.sshUsername.isEmpty || !model.sshPassword.isEmpty {
                    Text(model.sshValidation.isEmpty ? "Данные готовы к созданию пользователя" : model.sshValidation)
                        .font(.system(size: 11)).foregroundStyle(model.sshValidation.isEmpty ? StudioStyle.accent : StudioStyle.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .center, spacing: 18) {
                    Text("Настройки пользователей и SSH будут сохранены перед изменением. Пароль не сохраняется в настройках приложения.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(action: model.createSSHAccount) { Label("Создать администратора", systemImage: "person.badge.plus") }
                        .buttonStyle(StudioButtonStyle(prominent: true))
                        .disabled(!model.canManage || !model.sshValidation.isEmpty || model.sshRecoveryPending)
                }
            }.disabled(model.busy)
            if model.sshListenerReady {
                StudioCard {
                    Text("ПОДКЛЮЧЕНИЕ В ТЕРМИНАЛЕ").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(StudioStyle.secondary)
                    Text(model.sshCommand + "\n# После входа:\ndoas -s")
                        .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                }
            }
            StudioNote(symbol: "network", text: "SSH доступен по адресу модема на порту 2223. У каждого пользователя свой пароль; команды администратора выполняются через doas.")
        }
    }

    var localizationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioCard {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 32)).foregroundStyle(StudioStyle.accent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Экран модема на русском").font(.system(size: 20, weight: .semibold))
                        Text("Проверенный перевод меню и сообщений с подобранным размером шрифта. В выборе языка появятся English и Русский вместо English и 中文.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Русификация сохраняется после перезагрузки модема. Язык можно менять в его настройках.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Rectangle().fill(StudioStyle.line).frame(height: 1)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let state = model.screenLocalizationStatus {
                            Label(state.title, systemImage: state.state == .enabled ? "checkmark.circle" : state.state == .error ? "exclamationmark.triangle" : "info.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(state.state == .enabled ? StudioStyle.accent : state.state == .error ? StudioStyle.warning : StudioStyle.text)
                            Text(state.state == .error ? state.summary : "Текущий язык: " + state.languageTitle)
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Состояние ещё не проверено").font(.system(size: 13, weight: .medium))
                            Text("Подключите модем и нажмите «Проверить».")
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: model.refreshScreenLocalization) { Label("Проверить", systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
            }
            StudioCard {
                StudioSectionTitle(number: "02", title: "Управление языком", detail: "При включении или восстановлении интерфейс на экране модема перезапустится.")
                HStack(spacing: 12) {
                    Button(action: model.enableScreenLocalization) { Label("Включить русский", systemImage: "checkmark.bubble") }
                        .buttonStyle(StudioButtonStyle(prominent: true))
                        .disabled(!model.canManage)
                    Button(action: model.disableScreenLocalization) { Label("Вернуть штатный интерфейс", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(StudioButtonStyle())
                        .disabled(!model.canManage || model.screenLocalizationStatus == nil || model.screenLocalizationStatus?.state == .absent)
                }
                Text("Штатный интерфейс вернёт исходные English и 中文 и обычный размер шрифта.")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var ttlPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioCard {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Настройка TTL").font(.system(size: 20, weight: .semibold))
                        Text("Исходящим пакетам IPv4 задаётся точное значение TTL. К входящему TTL прибавляется указанное число перед передачей пакетов подключённым устройствам.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(action: model.refreshTTLSettings) { Label("Проверить", systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
                Rectangle().fill(StudioStyle.line).frame(height: 1)
                if let status = model.ttlStatus {
                    Label(status.title, systemImage: status.state == .verified ? "checkmark.circle" : status.state == .error ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(status.state == .verified ? StudioStyle.accent : status.state == .error ? StudioStyle.warning : StudioStyle.text)
                    Text(status.detail.isEmpty ? status.capabilityDescription : status.detail)
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.state == .configured || status.state == .verified {
                        Text("Действующие настройки: исходящий TTL — " + (status.configuration.outbound.map(String.init) ?? "обычный") + "; входящий — " + (status.configuration.inboundIncrement.map { "+\($0)" } ?? "без прибавки") + ".")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(status.verificationDescription)
                            .font(.system(size: 12)).foregroundStyle(status.verification == .verified ? StudioStyle.accent : StudioStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if status.state != .error && status.state != .unsupported && !status.persistenceDescription.isEmpty {
                        Text(status.persistenceDescription).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                } else {
                    Text("Нажмите «Проверить», чтобы узнать возможности модема и текущие настройки TTL.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            StudioNote(symbol: "arrow.up.arrow.down", text: "TTL — число переходов, которое может пройти пакет IPv4. На выходе в мобильную сеть модем заменяет TTL заданным числом, например 64. Для трафика из мобильной сети в основную Wi-Fi-сеть прибавляет +N, например +1. Правила сохраняются на модеме и восстанавливаются после перезагрузки; IPv6 эта настройка не меняет.")
            StudioCard {
                ttlDirection(title: "Исходящий TTL", detail: "При отправке пакетов в интернет.",
                             enabled: $model.ttlOutboundEnabled, value: $model.ttlOutboundValue)
                Rectangle().fill(StudioStyle.line).frame(height: 1)
                ttlDirection(title: "Прибавить к входящему TTL", detail: "К значению, которое устройство получило бы без этой настройки. Итоговый TTL — не больше 255.",
                             enabled: $model.ttlInboundIncrementEnabled, value: $model.ttlInboundIncrementValue, increment: true)
                if !model.ttlValidationMessage.isEmpty {
                    Text(model.ttlValidationMessage).font(.system(size: 12)).foregroundStyle(StudioStyle.warning)
                }
                Text("Для применения TTL модем использует программную обработку трафика. Это может снизить скорость соединения.")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center, spacing: 16) {
                    Text("Настройки изменятся только после нажатия «Применить». Отключённое направление сохраняет обычное поведение TTL.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: model.applyTTLSettings) { Label("Применить", systemImage: "checkmark") }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canApplyTTL)
                }
            }.disabled(model.busy)
        }
    }

    func ttlDirection(title: String, detail: String, enabled: Binding<Bool>, value: Binding<String>, increment: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(title, isOn: enabled).toggleStyle(.switch).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                if increment { Text("+").font(.system(size: 20, weight: .medium)).padding(.bottom, 12) }
                StudioField(label: increment ? "ПРИБАВИТЬ" : "ЗНАЧЕНИЕ TTL", placeholder: "1–255", text: value)
                    .frame(width: 120)
            }.disabled(!enabled.wrappedValue)
        }
    }

    func secureSetting(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(StudioStyle.secondary)
            SecureField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 14))
                .padding(13).background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(label)
        }
    }

    var journalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Сообщения текущего сеанса")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log, forType: .string)
                    copiedLog = true
                } label: {
                    Label(copiedLog ? "Скопировано" : "Копировать", systemImage: copiedLog ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(StudioButtonStyle())
                .disabled(model.log.isEmpty)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(model.log.isEmpty ? "Здесь появятся результаты подключения, резервного копирования и проверки IMEI." : model.log)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(6)
                    .foregroundStyle(model.log.isEmpty ? StudioStyle.secondary : StudioStyle.text.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .frame(minHeight: 380, idealHeight: 480)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioStyle.line, lineWidth: 1))
            .onChange(of: model.log) { _ in copiedLog = false }
        }
    }

    var statusBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StudioStyle.line).frame(height: 1)
            HStack(spacing: 12) {
                if model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                } else {
                    Circle().fill(model.connected ? StudioStyle.accent : StudioStyle.secondary).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.status.isEmpty ? "Готово к подключению" : model.status)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if model.busy {
                        Text("Дождитесь завершения операции")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioStyle.secondary)
                    }
                }
                Spacer(minLength: 12)
                if model.busy {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(Int(min(max(model.progress, 0), 1) * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(StudioStyle.secondary)
                        ProgressView(value: min(max(model.progress, 0), 1))
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                    }
                }
                if page != .administration || administrationSection != .activity {
                    Button { page = .administration; administrationSection = .activity; model.refreshActivity() } label: {
                        Label("Журнал", systemImage: "text.alignleft")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioStyle.secondary)
                    .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .background(StudioStyle.sidebar.opacity(0.55))
        }
    }

    var recoveryBanner: some View {
        HStack(alignment: .center, spacing: 15) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 20))
                .foregroundStyle(StudioStyle.warning)
            VStack(alignment: .leading, spacing: 5) {
                Text("Есть незавершённая операция")
                    .font(.system(size: 12, weight: .semibold))
                Text("Приложение проверит сохранённый этап и текущее состояние модема, затем продолжит работу.")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: model.resume) {
                Label("Продолжить", systemImage: "play.fill")
            }
            .buttonStyle(StudioButtonStyle())
            .disabled(model.busy)
            .accessibilityLabel("Продолжить незавершённую операцию")
        }
        .padding(18)
        .background(StudioStyle.warning.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.warning.opacity(0.25), lineWidth: 1))
    }

    func pathSetting(label: String, placeholder: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            StudioField(label: label, placeholder: placeholder, text: text)
            Button(action: action) { Image(systemName: "folder") }
                .buttonStyle(StudioButtonStyle())
                .help("Выбрать файл")
        }
    }

    func reviewColumn(label: String, oldValue: String, newValue: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(StudioStyle.secondary)
            Text(oldValue.isEmpty ? "Не прочитан" : oldValue)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(StudioStyle.secondary)
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                Text(newValue.isEmpty ? "—" : newValue)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
            }
            .foregroundStyle(StudioStyle.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func valueColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(StudioStyle.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    func backupRow(_ backup: BackupItem) -> some View {
        let isSelected = backup.id == model.selectedBackupID
        return Button {
            model.selectedBackupID = backup.id
        } label: {
            HStack(spacing: 15) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? StudioStyle.accent : StudioStyle.secondary.opacity(0.6))
                VStack(alignment: .leading, spacing: 7) {
                    Text(backup.date).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 18) {
                        Text("1  \(backup.imei1.isEmpty ? "—" : backup.imei1)")
                        Text("2  \(backup.imei2.isEmpty ? "—" : backup.imei2)")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StudioStyle.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "externaldrive").foregroundStyle(StudioStyle.secondary)
            }
            .padding(17)
            .background(isSelected ? StudioStyle.accent.opacity(0.05) : StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? StudioStyle.accent.opacity(0.4) : StudioStyle.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }
}

struct StudioCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 19) { content }
            .padding(23)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(StudioStyle.line, lineWidth: 1))
    }
}

struct StudioField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(StudioStyle.secondary)
            TextField(placeholder, text: $text)
                .font(.system(size: large ? 18 : 12, weight: large ? .medium : .regular, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: large ? 49 : 38)
                .background(StudioStyle.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioStyle.line, lineWidth: 1))
                .accessibilityLabel(label)
        }
    }
}

struct IMEICard: View {
    let slot: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                Spacer()
                Text(slot)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioStyle.accent)
            }
            .foregroundStyle(StudioStyle.secondary)
            Text(value.isEmpty ? "Не прочитан" : value)
                .font(.system(size: value.isEmpty ? 17 : 21, weight: .medium, design: value.isEmpty ? .default : .monospaced))
                .foregroundStyle(value.isEmpty ? StudioStyle.secondary : StudioStyle.text)
                .textSelection(.enabled)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(StudioStyle.line, lineWidth: 1))
    }
}

struct StudioSectionTitle: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioStyle.accent)
                .frame(width: 27, height: 27)
                .background(StudioStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StudioNote: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(StudioStyle.accent.opacity(0.7))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 11))
                .lineSpacing(3)
                .foregroundStyle(StudioStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

struct StudioButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .foregroundStyle(prominent ? StudioStyle.canvas : StudioStyle.text)
            .background(prominent ? StudioStyle.accent : StudioStyle.elevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(prominent ? Color.clear : StudioStyle.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.32)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
