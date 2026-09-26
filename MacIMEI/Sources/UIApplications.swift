import SwiftUI

extension ContentView {
    var applicationsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let storage = model.applicationInventory?.applicationStorage {
                        Text("Свободно \(AppModel.bytesLabel(kib: storage.availableKiB)) · приложения занимают \(AppModel.bytesLabel(kib: storage.managedUsedKiB))")
                            .font(.system(size: 12, weight: .medium))
                        Text("Хранилище /data · в занятом месте учтены копии для отката")
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    } else {
                        Text(model.connected ? "Обновите приложения, чтобы проверить свободное место на модеме." : "Подключитесь по SSH, чтобы получить список приложений модема.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                }
                Spacer()
                Button(action: model.refreshApplications) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage).help("Обновить только приложения и место для них")
            }
            Picker("Раздел приложений", selection: $applicationSection) {
                ForEach(ApplicationSection.allCases) { Text($0.rawValue).tag($0) }
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
    var applicationColumns: [GridItem] { [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)] }
    var installedApplicationsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            applicationInspectionErrors
            if model.applicationInventory == nil {
                StudioNote(symbol: "square.grid.2x2", text: "Список ещё не получен. Нажмите обновление после подключения к модему.")
            }
            LazyVGrid(columns: applicationColumns, alignment: .leading, spacing: 12) {
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
                    Text("Дополнительных приложений пока нет").font(.system(size: 15, weight: .medium))
                    Button("Открыть каталог") { applicationSection = .available }.buttonStyle(StudioButtonStyle())
                }
            }
            if model.applicationInventory?.ssclashUnmanaged == true {
                applicationError("Найдены непроверенные файлы SSClash. Они не считаются установленным приложением; подробности доступны в каталоге.")
            }
            diagnosticToolsMaintenance
            if let inventory = model.applicationInventory {
                DisclosureGroup("Компоненты прошивки · \(inventory.installedPackages.count)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Системные компоненты показаны для справки. Удаление компонентов прошивки недоступно.")
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        StudioField(label: "ПОИСК КОМПОНЕНТА", placeholder: "Название пакета", text: $model.packageSearch)
                        ForEach(Array(model.filteredPackages.prefix(50))) { package in
                            HStack {
                                Text(package.name).font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text(package.version).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                            }
                        }
                        if model.filteredPackages.count > 50 { Text("Уточните поиск, чтобы увидеть остальные компоненты.").font(.system(size: 11)) }
                    }.padding(.top, 10)
                }.font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }
    var applicationCatalogPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            applicationInspectionErrors
            LazyVGrid(columns: applicationColumns, alignment: .leading, spacing: 12) {
                ForEach(DiagnosticTool.catalog) { diagnosticApplicationCard($0) }
                ssclashApplicationCard
                opkgApplicationCard
            }
            diagnosticToolsMaintenance
        }
    }
    @ViewBuilder var applicationInspectionErrors: some View {
        if !model.applicationsError.isEmpty { applicationError(model.applicationsError) }
        if !model.diagnosticToolsError.isEmpty { applicationError("Диагностика: " + model.diagnosticToolsError) }
        if !model.experimentalOpkgError.isEmpty { applicationError("opkg: " + model.experimentalOpkgError) }
    }
    func applicationError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
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
                        Button("Открыть", action: model.openSSClash).buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    } else {
                        Button("Запустить", action: model.startSSClash).buttonStyle(StudioButtonStyle()).disabled(!model.canManage || inventory?.ssclashUnmanaged == true)
                    }
                    Spacer(minLength: 0)
                    Button("Удалить", action: model.removeSSClash).buttonStyle(StudioButtonStyle()).disabled(!model.canManage || app?.canRemove != true)
                }
                if let reason = app?.removalBlockReason { Text(reason).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary) }
            } else {
                Button("Установить") { expandedApplication = "ssclash" }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || installed == nil)
            }
        }
    }
    var ssclashInstallSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Установка SSClash-Go").font(.title2.bold())
            Text("Задайте пароль для веб-панели. Ядро прокси и профиль подключения настраиваются после установки.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            secureSetting(label: "ПАРОЛЬ SSCLASH", placeholder: "Не менее 8 символов", text: $model.ssclashPassword)
            secureSetting(label: "ПОВТОР ПАРОЛЯ", placeholder: "Повторите пароль", text: $model.ssclashPasswordConfirmation)
            Text("Нужно 64 МиБ на /data. Перед удалением программа сохраняет архив приложения и настроек.")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            DisclosureGroup("Лицензия") { Text(ModemApplications.catalog[0].licenseSummary).font(.system(size: 11)) }
            HStack {
                Button("Отмена") { expandedApplication = nil; model.ssclashPassword = ""; model.ssclashPasswordConfirmation = "" }
                    .buttonStyle(StudioButtonStyle())
                Spacer()
                Button("Установить") { model.installSSClash(); expandedApplication = nil }
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
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(name).layoutPriority(1)
                Spacer(minLength: 0)
                Text(version).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 110, alignment: .trailing).help(version)
            }
            Text(summary).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).lineLimit(3).help(summary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            Label(statusText ?? installed.map { $0 ? "Установлено" : "Не установлено" } ?? "Не проверено",
                  systemImage: installed == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10)).foregroundStyle(installed == true ? StudioStyle.accent : statusText != nil ? StudioStyle.warning : StudioStyle.secondary)
            actions()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioStyle.line, lineWidth: 1))
    }
}
