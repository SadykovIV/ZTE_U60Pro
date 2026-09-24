import SwiftUI

extension ContentView {
    var applicationsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "flask", text: "Экспериментальный раздел для исследования приложений на модеме. Доступность пакетов зависит от прошивки и её репозиториев.")
            StudioCard {
                HStack {
                    Text("Место для приложений").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button(action: model.refreshApplications) { Label("Обновить", systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                }
                if let storage = model.applicationInventory?.applicationStorage {
                    informationRow("Доступно для установки", AppModel.bytesLabel(kib: storage.availableKiB))
                    informationRow("Папка установки", storage.installRoot)
                    informationRow("Занято в папке приложений", AppModel.bytesLabel(kib: storage.managedUsedKiB))
                    Text("Приложения используют свободное место в \(storage.mount). В занятом объёме учтены их сохранённые копии; отдельной квоты нет.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                } else {
                    Text("Подключите модем и обновите список, чтобы проверить место для установки.")
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
            }
            Picker("Раздел приложений", selection: $applicationSection) {
                ForEach(ApplicationSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if applicationSection == .installed { installedApplicationsPage } else { applicationCatalogPage }
        }
    }
    var installedApplicationsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let inventory = model.applicationInventory {
                if inventory.installedApplications.isEmpty {
                    StudioCard {
                        Text("Дополнительные приложения не установлены").font(.system(size: 15, weight: .medium))
                        Button("Открыть каталог") { applicationSection = .available }.buttonStyle(StudioButtonStyle())
                    }
                }
                ForEach(inventory.installedApplications) { app in
                    StudioCard {
                        HStack {
                            Text(app.name).font(.system(size: 18, weight: .semibold))
                            Text(app.version).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            Spacer()
                            Text(app.isRunning ? "Работает" : "Остановлено").font(.system(size: 11)).foregroundStyle(StudioStyle.accent)
                        }
                        if let reason = app.removalBlockReason { Text(reason).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary) }
                        HStack {
                            if !app.isRunning {
                                Button("Запустить") { model.startSSClash() }.buttonStyle(StudioButtonStyle()).disabled(!model.canManage || inventory.ssclashUnmanaged)
                            }
                            Button(action: model.openSSClash) { Label("Открыть", systemImage: "arrow.up.right.square") }
                                .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || !app.isRunning)
                            Spacer()
                            Button(action: model.removeSSClash) { Label("Удалить", systemImage: "trash") }
                                .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || !app.canRemove)
                        }
                        Text("Перед удалением сохраняется архив приложения и его настроек. Активный прокси сначала нужно остановить в SSClash.")
                            .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    }
                }
                StudioCard {
                    DisclosureGroup("Компоненты прошивки · \(inventory.installedPackages.count)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Штатные пакеты входят в прошивку B31 и защищены от удаления. Дополнительные приложения управляются отдельно.")
                                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            StudioField(label: "ПОИСК КОМПОНЕНТА", placeholder: "Название пакета", text: $model.packageSearch)
                            ForEach(Array(model.filteredPackages.prefix(50))) { package in
                                HStack {
                                    Text(package.name).font(.system(size: 11, design: .monospaced))
                                    Spacer()
                                    Text(package.version).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                                }
                            }
                            if model.filteredPackages.count > 50 { Text("Уточните поиск, чтобы увидеть остальные компоненты.").font(.system(size: 11)).foregroundStyle(StudioStyle.secondary) }
                        }.padding(.top, 12)
                    }
                }
            } else { StudioNote(symbol: "square.grid.2x2", text: "Список установленных приложений появится после проверки модема.") }
        }
    }
    var applicationCatalogPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(ModemApplications.catalog) { app in
                StudioCard {
                    HStack {
                        Text(app.name).font(.system(size: 20, weight: .semibold))
                        Text(app.version).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        Spacer()
                        Label("Загрузка из GitHub", systemImage: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(StudioStyle.accent)
                    }
                    Text(app.summary).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    informationRow("Нужно свободного места", AppModel.bytesLabel(kib: app.requiredFreeKiB))
                    Text("Установщик работает без скачивания дополнительных файлов. Ядро прокси и профиль подключения настраиваются в SSClash после установки.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    if model.applicationInventory?.ssclashInstalled == true || model.applicationInventory?.ssclashUnmanaged == true {
                        Label("Уже есть на модеме", systemImage: "checkmark.circle").font(.system(size: 12))
                        Button("К установленным приложениям") { applicationSection = .installed }.buttonStyle(StudioButtonStyle())
                    } else {
                        HStack(spacing: 16) {
                            secureSetting(label: "ПАРОЛЬ SSCLASH", placeholder: "Не менее 8 символов", text: $model.ssclashPassword)
                            secureSetting(label: "ПОВТОР ПАРОЛЯ", placeholder: "Повторите пароль", text: $model.ssclashPasswordConfirmation)
                        }.disabled(model.busy)
                        Text("8–128 латинских букв, цифр или знаков без пробелов.").font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        Button(action: model.installSSClash) { Label("Установить", systemImage: "square.and.arrow.down") }
                            .buttonStyle(StudioButtonStyle(prominent: true))
                            .disabled(!model.canManage || model.applicationInventory == nil || !model.ssclashPasswordValid || (model.applicationInventory?.applicationStorage?.availableKiB ?? 0) < app.requiredFreeKiB)
                    }
                    DisclosureGroup("Лицензия") { Text(app.licenseSummary).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).padding(.top, 8) }
                }
            }
        }
    }
}
