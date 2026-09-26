import AppKit
import SwiftUI

extension ContentView {
    var modemInformationCards: some View {
        StudioCard {
            HStack {
                Text("Система и устройство").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshModemInformation) { Label("Обновить сведения", systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canCollectDiagnostics)
            }
            if let info = model.modemInformation {
                informationRow("Модель", info.model)
                informationRow("Прошивка", info.firmware)
                informationRow("Версия модемной части", info.internalFirmware)
                informationRow("Операционная система", info.distribution + " " + info.systemVersion + " · " + info.revision)
                informationRow("Ядро Linux", info.kernel)
                informationRow("Процессор", info.processor + " · ядер: \(info.cpuCount)")
                informationRow("Архитектура / плата", info.architecture + " / " + info.board)
                informationRow("Имя устройства", info.hostname)
                informationRow("Время работы", durationLabel(info.uptimeSeconds))
                informationRow("Нагрузка · 1 / 5 / 15 мин", info.loadAverage)
                informationRow("Аккумулятор", info.batteryPercent.map { "\($0)% · " + batteryLabel(info.batteryState) } ?? "Нет данных")
                informationRow("Агент на модеме", info.agentVersion)
                DisclosureGroup("Идентификаторы и время проверки") {
                    VStack(spacing: 10) {
                        informationRow("CID накопителя", info.identity.cid)
                        informationRow("Сеанс загрузки", info.bootID)
                        informationRow("Обновлено", info.collectedAt.formatted(date: .numeric, time: .standard))
                    }.padding(.top, 10)
                }.font(.system(size: 12))
            } else if let summary = model.channelSummary {
                informationRow("Подключение", model.activeChannel?.title ?? "—")
                if let firmware = summary.firmware { informationRow("Прошивка", firmware) }
                if let imei = summary.primaryIMEI { informationRow("IMEI устройства", imei) }
                if let version = summary.agentVersion { informationRow("Версия агента", version) }
                if let identity = summary.identity { informationRow("CID накопителя", identity.cid) }
                ForEach(summary.fields.keys.filter { $0 != "firmware" && $0 != "routerSHA256" }.sorted(), id: \.self) { key in
                    informationRow(channelFieldTitle(key), summary.fields[key] ?? "—")
                }
                Text(model.connectionCapabilityText).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            } else {
                Text("Сведения считываются непосредственно с модема. Подключитесь и нажмите «Обновить сведения».")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }
    func channelFieldTitle(_ key: String) -> String {
        ["firmware": "Прошивка", "innerVersion": "Внутренняя версия", "hostname": "Имя устройства",
         "kernel": "Ядро Linux", "uptimeSeconds": "Время работы, секунд", "loadAverage": "Нагрузка",
         "memoryTotalKiB": "RAM всего, КиБ", "memoryAvailableKiB": "RAM доступно, КиБ",
         "batteryPercent": "Аккумулятор, %", "detailsUnavailable": "Дополнительные сведения", "batteryState": "Состояние аккумулятора", "architecture": "Архитектура", "model": "Модель"][key] ?? key
    }
    func informationRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(title).foregroundStyle(StudioStyle.secondary).frame(width: 185, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
    func durationLabel(_ seconds: Double) -> String {
        let minutes = seconds.isFinite ? Int(max(0, min(seconds / 60, 52_596_000))) : 0
        return "\(minutes / 1440) д. \((minutes % 1440) / 60) ч. \(minutes % 60) мин."
    }
    func batteryLabel(_ status: String) -> String {
        ["Full":"заряжен", "Charging":"заряжается", "Discharging":"разряжается", "Not charging":"не заряжается"][status] ?? status
    }
    var memoryPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Память и накопители").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshModemInformation) { Label("Обновить", systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canCollectDiagnostics)
            }
            if let info = model.modemInformation {
                StudioCard {
                    Text("Оперативная память · RAM").font(.system(size: 15, weight: .semibold))
                    informationRow("Всего", AppModel.bytesLabel(kib: info.memoryTotalKiB))
                    informationRow("Доступно приложениям", AppModel.bytesLabel(kib: info.memoryAvailableKiB))
                    ProgressView(value: Double(info.memoryTotalKiB - info.memoryAvailableKiB), total: Double(info.memoryTotalKiB))
                    informationRow("Свободно / файловый кэш", AppModel.bytesLabel(kib: info.memoryFreeKiB) + " / " + AppModel.bytesLabel(kib: info.memoryCachedKiB))
                    informationRow("Подкачка", info.swapTotalKiB == 0 ? "Не используется" : AppModel.bytesLabel(kib: info.swapFreeKiB) + " свободно из " + AppModel.bytesLabel(kib: info.swapTotalKiB))
                }
                StudioCard {
                    Text("Разделы и файловые системы").font(.system(size: 15, weight: .semibold))
                    Text("/tmp — временная файловая система в RAM. Размеры разделов не складываются в общий объём накопителя.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    ForEach(info.volumes) { volume in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(volume.mount).font(.system(size: 12, weight: .medium, design: .monospaced))
                                if info.readOnlyMounts.contains(volume.mount) { Image(systemName: "lock").help("Только чтение") }
                                Spacer()
                                Text("Свободно \(AppModel.bytesLabel(kib: volume.availableKiB)) из \(AppModel.bytesLabel(kib: volume.totalKiB))")
                                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            }
                            ProgressView(value: Double(volume.usedKiB), total: Double(volume.totalKiB))
                        }.padding(.vertical, 5)
                    }
                }
            } else if let summary = model.channelSummary, let total = summary.fields["memoryTotalKiB"] {
                StudioCard {
                    informationRow("RAM всего, КиБ", total)
                    informationRow("RAM доступно, КиБ", summary.fields["memoryAvailableKiB"] ?? "Нет данных")
                    Text("Сведения API агента. Для списка разделов и файловых систем выберите SSH или ADB.").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
            } else { StudioNote(symbol: "memorychip", text: "Выберите SSH, ADB или агент и обновите сведения. Web не предоставляет данные о памяти.") }
        }
    }
    var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            diagnosticExportCard
            StudioCard {
                HStack {
                    Text("Диагностика модема").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button(action: model.collectDiagnostics) { Label("Собрать диагностику", systemImage: "doc.text.magnifyingglass") }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canCollectDiagnostics)
                }
                Text("Системный журнал, ядро, сеть, маршруты, firewall, процессы, USB, питание, температуры и структура каталогов. Системные разделы читаются через SSH или работающий ADB по USB. Через агент и Web сохраняются доступные сведения API; остальные разделы отмечаются как пропущенные. Сбор соблюдает выбранный способ подключения и не требует соответствия B31. Для каждого раздела сохраняются результат чтения и контрольная сумма; известные поля с паролями и токенами скрываются.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                if let report = model.diagnosticReport {
                    ForEach(report.warnings ?? [], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(StudioStyle.warning) }
                    informationRow("Собрано", report.created)
                    informationRow("Подключение", report.transport.flatMap(ConnectionMode.init(rawValue:))?.title ?? (report.transport == nil ? "Не указано в старом отчёте" : "Не установлено"))
                    if let reason = report.selectionReason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    informationRow("Результаты сбора", report.outcomeSummary)
                    Button(action: model.revealDiagnostics) { Label("Открыть папку отчёта", systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                    Text("Отчёт может содержать адреса сети и идентификаторы устройства. Просмотрите его перед отправкой.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                }
            }
            if let report = model.diagnosticReport {
                Picker("Раздел отчёта", selection: $model.selectedDiagnostic) {
                    ForEach(report.files) { file in Text(file.title + (file.effectiveOutcome == .succeeded ? "" : " · " + file.statusLabel)).tag(file.name) }
                }.onChange(of: model.selectedDiagnostic) { _ in model.loadDiagnosticText() }
                ScrollView([.horizontal, .vertical]) {
                    Text(model.diagnosticText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
                }.frame(height: 380).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    var imeiPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("IMEI", selection: $imeiSection) {
                ForEach(IMEISection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch imeiSection { case .imei: changePage; case .backups: imeiBackupsPage }
        }
    }
    var administrationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Раздел администрирования", selection: $administrationSection) {
                ForEach(AdministrationSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch administrationSection {
            case .access: accessPage
            case .backups: allBackupsPage
            case .activity: activityPage
            }
        }
    }
    var accessPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Службы и способы входа").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshAccess) { Label("Проверить доступы", systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
            }
            if let state = model.accessState {
                ForEach(state.services) { service in accessCard(service) }
            } else { StudioNote(symbol: "network", text: "Проверьте доступы, чтобы увидеть состояние WEB, SSH, ADB и агента и доступные действия.") }
            sshPage
        }
    }
    func accessCard(_ service: AccessServiceState) -> some View {
        StudioCard {
            HStack {
                Text(service.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(serviceStateLabel(service.state)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(service.state == .running ? StudioStyle.accent : StudioStyle.secondary)
            }
            informationRow("Адрес", service.endpoint)
            Text(service.credentialModel).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            Text(service.detail).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            if !service.allowedActions.isEmpty {
                HStack {
                    ForEach(service.allowedActions, id: \.rawValue) { action in
                        Button(action.title) { model.changeService(service.id, action: action) }
                            .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    }
                    Spacer()
                    Text("До перезагрузки модема").font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                }
            }
        }
    }
    func serviceStateLabel(_ state: AccessServiceRuntime) -> String {
        switch state { case .running: return "Работает"; case .stopped: return "Остановлена"; case .unavailable: return "Не установлена"; case .unknown: return "Не подтверждено" }
    }
    var allBackupsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            systemBackupsCard
            StudioCard {
                Text("Отдельные данные и настройки").font(.system(size: 18, weight: .semibold))
                Text("Выберите состав копии. Каждый архив сохраняется на Mac с проверкой устройства, размера и SHA256.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                Picker("Состав резервной копии", selection: $model.deviceBackupKind) {
                    ForEach(DeviceBackupKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(model.busy)
                Text(model.deviceBackupKind.scope).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text(model.deviceBackupKind.limitations).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(action: model.createDeviceBackup) { Label("Создать копию", systemImage: "plus") }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage)
                    Button(action: model.refreshDeviceBackups) { Label("Обновить список", systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(model.busy)
                    Spacer()
                    Button(action: model.revealDeviceBackups) { Label("Папка копий", systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                }
            }
            if !model.deviceBackups.isEmpty {
                StudioCard {
                    Text("Модемные, пользовательские и конфигурационные копии").font(.system(size: 14, weight: .semibold))
                    ForEach(model.deviceBackups) { item in
                        Button { model.selectedDeviceBackupID = item.id } label: {
                            HStack {
                                Image(systemName: model.selectedDeviceBackupID == item.id ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.kind.title).font(.system(size: 12, weight: .medium))
                                    Text(item.date).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.system(size: 11))
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                    HStack {
                        Button(action: model.verifyDeviceBackup) { Label("Проверить целостность", systemImage: "checkmark.shield") }.buttonStyle(StudioButtonStyle())
                        Button(action: model.exportDeviceBackup) { Label("Экспортировать", systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
                    }.disabled(model.busy || model.selectedDeviceBackupID == nil)
                }
            }
            StudioNote(symbol: "simcard", text: "Резервные копии NV550 и EFS для смены IMEI находятся в разделе «IMEI» → «Бэкапы IMEI».")
            Button("Открыть бэкапы IMEI") { page = .imei; imeiSection = .backups }.buttonStyle(StudioButtonStyle())
        }.onAppear { model.refreshDeviceBackups(); model.refreshBackups(); model.refreshSystemBackups() }
    }
    var activityPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            diagnosticExportCard
            StudioCard {
                Text("Постоянный журнал действий").font(.system(size: 18, weight: .semibold))
                Text("Сохраняется между запусками: этапы, проверки прошивки, SSH, USB/ADB и HTTP, длительность, коды завершения, ошибки и очищенный вывод. Запросы связаны с операциями и сеансом приложения. Секретный ввод не сохраняется; известные конфиденциальные поля скрываются.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(action: model.refreshActivity) { Label("Обновить", systemImage: "arrow.clockwise") }.buttonStyle(StudioButtonStyle())
                    Button(action: model.revealActivity) { Label("Весь журнал", systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                    Button(action: model.revealOperationLogs) { Label("Трассировки запросов", systemImage: "doc.text") }.buttonStyle(StudioButtonStyle())
                }
                StudioField(label: "ПОИСК В ПОСЛЕДНИХ 400 СОБЫТИЯХ", placeholder: "Операция, ошибка или идентификатор", text: $model.activitySearch)
                if !model.journalWarning.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.journalWarning) }
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.filteredActivity) { event in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Операция: " + event.operationID).textSelection(.enabled)
                            ForEach(event.details.keys.sorted(), id: \.self) { key in
                                Text(key + ": " + (event.details[key] ?? "")).textSelection(.enabled)
                            }
                        }.font(.system(size: 10, design: .monospaced)).padding(.vertical, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.system(size: 12))
                            Text(activityDateLabel(event.timestamp) + " · " + activityResultLabel(event.result)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                        }
                    }.padding(12).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            DisclosureGroup("Сообщения текущего сеанса") { journalPage.padding(.top, 12) }
        }.onAppear { model.refreshActivity() }
    }
    func activityDateLabel(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "d MMM yyyy, HH:mm:ss"
        return formatter.string(from: date)
    }
    func activityResultLabel(_ value: String) -> String {
        ["started":"начато", "completed":"завершено", "failed":"ошибка", "progress":"этап операции", "message":"сообщение", "warning":"предупреждение"][value] ?? value
    }
}
