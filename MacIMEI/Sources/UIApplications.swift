import SwiftUI

extension ContentView {
    var applicationsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let storage = model.applicationInventory?.applicationStorage {
                        Text(L10n.text("Свободно \(AppModel.bytesLabel(kib: storage.availableKiB)) · приложения занимают \(AppModel.bytesLabel(kib: storage.managedUsedKiB))"))
                            .font(.system(size: 12, weight: .medium))
                        Text(L10n.text("Хранилище /data · в занятом месте учтены копии для отката"))
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    } else {
                        Text(L10n.text(model.connected ? "Обновите приложения, чтобы проверить свободное место на модеме." : "Подключитесь по SSH, чтобы получить список приложений модема."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                }
                Spacer()
                Button(action: model.refreshApplications) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage).help(L10n.text("Обновить только приложения и место для них"))
            }
            Picker(L10n.text("Раздел приложений"), selection: $applicationSection) {
                ForEach(ApplicationSection.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            switch applicationSection {
            case .installed: installedApplicationsPage
            case .available: applicationCatalogPage
            case .opkg: experimentalOpkgPage
            }
        }
        .sheet(isPresented: Binding(get: { expandedApplication == "ssclash" }, set: { if !$0 { expandedApplication = nil } })) {
            ssclashInstallSheet
        }
    }
    var installedApplicationsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            applicationInspectionErrors
            if model.applicationInventory == nil {
                StudioNote(symbol: "square.grid.2x2", text: "Список ещё не получен. Нажмите обновление после подключения к модему.")
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(DiagnosticTool.catalog.filter { model.diagnosticToolsStatus?.isInstalled($0.id) == true }) { tool in
                    diagnosticApplicationCard(tool)
                }
                if model.applicationInventory?.ssclashInstalled == true {
                    ssclashApplicationCard
                }
                if model.experimentalOpkgStatus?.installed == true { opkgApplicationCard }
                ForEach(model.experimentalOpkgStatus?.installed == true ? model.experimentalOpkgStatus?.packages ?? [] : [], id: \.name) { package in
                    experimentalPackageCard(package)
                }
            }
            if model.applicationsFullyChecked && model.installedApplicationCount == 0 {
                StudioCard {
                    Text(L10n.text("Дополнительных приложений пока нет")).font(.system(size: 15, weight: .medium))
                    Button(L10n.text("Открыть каталог")) { applicationSection = .available }.buttonStyle(StudioButtonStyle())
                }
            }
            if model.applicationInventory?.ssclashUnmanaged == true {
                applicationError("Найдены непроверенные файлы SSClash. Они не считаются установленным приложением; подробности доступны в каталоге.")
            }
            diagnosticToolsMaintenance
            if let inventory = model.applicationInventory {
                DisclosureGroup(L10n.text("Компоненты прошивки · \(inventory.installedPackages.count)")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("Системные компоненты показаны для справки. Удаление компонентов прошивки недоступно."))
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        StudioField(label: "ПОИСК КОМПОНЕНТА", placeholder: "Название пакета", text: $model.packageSearch)
                        ForEach(Array(model.filteredPackages.prefix(50))) { package in
                            HStack {
                                Text(L10n.text(package.name)).font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text(L10n.text(package.version)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                            }
                        }
                        if model.filteredPackages.count > 50 { Text(L10n.text("Уточните поиск, чтобы увидеть остальные компоненты.")).font(.system(size: 11)) }
                    }.padding(.top, 10)
                }.font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }
    var applicationCatalogPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            verifiedCatalogHeader
            applicationInspectionErrors
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(DiagnosticTool.catalog.filter { verifiedCatalog.allows($0.id) }) { diagnosticApplicationCard($0) }
                if verifiedCatalog.allows("ssclash") { ssclashApplicationCard }
                if verifiedCatalog.allows("opkg") { opkgApplicationCard }
            }
            if verifiedCatalog.entries.isEmpty {
                StudioNote(symbol: "checkmark.shield", text: L10n.text("В этом каталоге пока нет совместимых проверенных приложений.", "This catalog has no compatible verified applications yet."))
            }
            diagnosticToolsMaintenance
        }
    }
    var verifiedCatalogHeader: some View {
        StudioCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 22)).foregroundStyle(StudioStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Проверенные приложения", "Verified applications")).font(.system(size: 14, weight: .semibold))
                    Text(L10n.text("В каталоге только приложения, проверенные на модеме. Новые добавляются после проверки; список обновляется отдельно от программы.", "The catalog contains applications tested on the modem. New entries are added after verification; the list updates independently of the application."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    if !verifiedCatalog.status.isEmpty {
                        Text(verifiedCatalog.statusText(language: L10n.language)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await verifiedCatalog.refresh() }
                } label: {
                    Label(L10n.text(verifiedCatalog.isUpdating ? "Проверяем…" : "Обновить каталог", verifiedCatalog.isUpdating ? "Checking…" : "Update catalog"), systemImage: "arrow.clockwise")
                }.buttonStyle(StudioButtonStyle()).disabled(verifiedCatalog.isUpdating)
            }
            if !verifiedCatalog.error.isEmpty {
                Text(verifiedCatalog.errorText(language: L10n.language)).font(.system(size: 11)).foregroundStyle(StudioStyle.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder var applicationInspectionErrors: some View {
        if !model.applicationsError.isEmpty { applicationError(model.applicationsError) }
        if !model.diagnosticToolsError.isEmpty { applicationError("Диагностика: " + model.diagnosticToolsError) }
        if !model.experimentalOpkgError.isEmpty { applicationError("opkg: " + model.experimentalOpkgError) }
    }
    func applicationError(_ text: String) -> some View {
        Label(L10n.text(text), systemImage: "exclamationmark.triangle")
            .font(.system(size: 11)).foregroundStyle(StudioStyle.warning)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    var ssclashApplicationCard: some View {
        let inventory = model.applicationInventory
        let present = inventory?.ssclashInstalled == true || inventory?.ssclashUnmanaged == true
        let installed: Bool? = inventory.flatMap { $0.ssclashUnmanaged ? nil : $0.ssclashInstalled }
        let app = inventory?.installedApplications.first
        return ApplicationTile(name: "SSClash-Go", version: app?.version ?? ModemApplications.ssclashVersion,
                               summary: "Веб-панель управления прокси и профилями подключения.", installed: installed,
                               statusText: inventory?.ssclashUnmanaged == true ? "Непроверенная установка" : nil) {
            if present {
                HStack(spacing: 8) {
                    if inventory?.ssclashRunning == true {
                        Button(L10n.text("Открыть"), action: model.openSSClash).buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    } else {
                        Button(L10n.text("Запустить"), action: model.startSSClash).buttonStyle(StudioButtonStyle()).disabled(!model.canManage || inventory?.ssclashUnmanaged == true)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.text("Удалить"), action: model.removeSSClash).buttonStyle(StudioButtonStyle()).disabled(!model.canManage || app?.canRemove != true)
                }
                if let reason = app?.removalBlockReason { Text(L10n.text(reason)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary) }
            } else {
                Button(L10n.text("Установить")) { expandedApplication = "ssclash" }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || installed == nil)
            }
        }
    }
    var ssclashInstallSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Установка SSClash-Go")).font(.title2.bold())
            Text(L10n.text("Задайте пароль для веб-панели. Ядро прокси и профиль подключения настраиваются после установки."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            secureSetting(label: "ПАРОЛЬ SSCLASH", placeholder: "Не менее 8 символов", text: $model.ssclashPassword)
            secureSetting(label: "ПОВТОР ПАРОЛЯ", placeholder: "Повторите пароль", text: $model.ssclashPasswordConfirmation)
            Text(L10n.text("Нужно 64 МиБ на /data. Перед удалением программа сохраняет архив приложения и настроек."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            DisclosureGroup(L10n.text("Лицензия")) { Text(L10n.text(ModemApplications.catalog[0].licenseSummary)).font(.system(size: 11)) }
            HStack {
                Button(L10n.text("Отмена")) { expandedApplication = nil; model.ssclashPassword = ""; model.ssclashPasswordConfirmation = "" }
                    .buttonStyle(StudioButtonStyle())
                Spacer()
                Button(L10n.text("Установить")) { model.installSSClash(); expandedApplication = nil }
                    .buttonStyle(StudioButtonStyle(prominent: true))
                    .disabled(!model.canManage || !model.ssclashPasswordValid || (model.applicationInventory?.applicationStorage?.availableKiB ?? 0) < 64 * 1024)
            }
        }.padding(24).frame(width: 440).background(StudioStyle.canvas)
    }
}

struct ApplicationTile<Actions: View>: View {
    let name: String
    let version: String
    let summary: String
    let installed: Bool?
    var statusText: String? = nil
    var verification: String? = nil
    @ViewBuilder let actions: () -> Actions
    private var symbol: String {
        switch name.lowercased() {
        case "htop": return "chart.bar.xaxis"
        case "iperf3": return "speedometer"
        case "mtr": return "point.3.connected.trianglepath.dotted"
        case "tcpdump": return "waveform.path"
        case "opkg": return "shippingbox"
        case "ssclash-go": return "network"
        default: return "app.dashed"
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium)).foregroundStyle(StudioStyle.accent)
                .frame(width: 44, height: 44)
                .background(StudioStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(L10n.text(name)).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    Text(L10n.text(version)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                    if let verification {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(StudioStyle.accent).font(.system(size: 11))
                            .help(verification).accessibilityLabel(L10n.text("Проверено на B31", "Verified on B31"))
                    }
                }
                Text(L10n.text(summary)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(L10n.text(statusText ?? installed.map { $0 ? "Установлено" : "Не установлено" } ?? "Не проверено"),
                      systemImage: installed == true ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10)).foregroundStyle(installed == true ? StudioStyle.accent : statusText != nil ? StudioStyle.warning : StudioStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            actions().frame(width: 230, alignment: .trailing)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.line, lineWidth: 1))
    }
}
