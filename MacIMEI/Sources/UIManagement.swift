import AppKit
import SwiftUI

extension ContentView {
    var modemInformationCards: some View {
        StudioCard {
            HStack {
                Text(L10n.text("Система и устройство")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshModemInformation) { Label(L10n.text("Обновить сведения"), systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canRefreshModem)
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
                DisclosureGroup(L10n.text("Идентификаторы и время проверки")) {
                    VStack(spacing: 10) {
                        informationRow("CID накопителя", info.identity?.cid ?? "—")
                        informationRow("Сеанс загрузки", info.bootID)
                        informationRow("Обновлено", info.collectedAt.formatted(date: .numeric, time: .standard))
                    }.padding(.top, 10)
                }.font(.system(size: 12))
            } else if let summary = model.channelSummary {
                informationRow("Подключение", model.activeChannel?.title ?? "—")
                if let firmware = summary.firmware { informationRow("Прошивка", firmware) }
                if let imei = summary.primaryIMEI { informationRow("IMEI устройства", imei) }
                if let version = summary.agentVersion { informationRow("Версия агента", version) }
                if let cid = summary.observedCID { informationRow("CID накопителя", cid) }
                ForEach(summary.fields.keys.filter { !["firmware", "routerSHA256", "cid", "sshReadOnly", "accessProfile"].contains($0) }.sorted(), id: \.self) { key in
                    informationRow(channelFieldTitle(key), summary.fields[key] ?? "—")
                }
                Text(L10n.text(model.connectionCapabilityText)).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            } else {
                Text(L10n.text("Сведения считываются непосредственно с модема. Подключитесь и нажмите «Обновить сведения»."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }
    func channelFieldTitle(_ key: String) -> String {
        ["uid": "UID", "system": "Система", "firmware": "Прошивка", "innerVersion": "Внутренняя версия", "hostname": "Имя устройства",
         "kernel": "Ядро Linux", "uptimeSeconds": "Время работы, секунд", "loadAverage": "Нагрузка",
         "memoryTotalKiB": "RAM всего, КиБ", "memoryAvailableKiB": "RAM доступно, КиБ",
         "batteryPercent": "Аккумулятор, %", "detailsUnavailable": "Дополнительные сведения", "batteryState": "Состояние аккумулятора", "architecture": "Архитектура", "model": "Модель"][key] ?? key
    }
    func informationRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(L10n.text(title)).foregroundStyle(StudioStyle.secondary).frame(width: 185, alignment: .leading)
            Text(L10n.text(value)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
                Text(L10n.text("Память и накопители")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshModemInformation) { Label(L10n.text("Обновить"), systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canRefreshModem)
            }
            if let info = model.modemInformation {
                StudioCard {
                    Text(L10n.text("Оперативная память · RAM")).font(.system(size: 15, weight: .semibold))
                    informationRow("Всего", AppModel.bytesLabel(kib: info.memoryTotalKiB))
                    informationRow("Доступно приложениям", AppModel.bytesLabel(kib: info.memoryAvailableKiB))
                    ProgressView(value: Double(info.memoryTotalKiB - info.memoryAvailableKiB), total: Double(info.memoryTotalKiB))
                    informationRow("Свободно / файловый кэш", AppModel.bytesLabel(kib: info.memoryFreeKiB) + " / " + AppModel.bytesLabel(kib: info.memoryCachedKiB))
                    informationRow("Подкачка", info.swapTotalKiB == 0 ? "Не используется" : AppModel.bytesLabel(kib: info.swapFreeKiB) + " свободно из " + AppModel.bytesLabel(kib: info.swapTotalKiB))
                }
                StudioCard {
                    Text(L10n.text("Разделы и файловые системы")).font(.system(size: 15, weight: .semibold))
                    Text(L10n.text("/tmp — временная файловая система в RAM. Размеры разделов не складываются в общий объём накопителя."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    ForEach(info.volumes) { volume in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(L10n.text(volume.mount)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                if info.readOnlyMounts.contains(volume.mount) { Image(systemName: "lock").help(L10n.text("Только чтение")) }
                                Spacer()
                                Text(L10n.text("Свободно \(AppModel.bytesLabel(kib: volume.availableKiB)) из \(AppModel.bytesLabel(kib: volume.totalKiB))"))
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
                    Text(L10n.text("Для списка разделов и файловых систем обновите сведения через SSH.")).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
            } else { StudioNote(symbol: "memorychip", text: "Подключитесь по SSH и обновите сведения.") }
        }
    }
    var imeiPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker(L10n.text("IMEI"), selection: $imeiSection) {
                ForEach(IMEISection.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            switch imeiSection { case .imei: changePage; case .backups: imeiBackupsPage }
        }
    }
    var administrationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker(L10n.text("Раздел администрирования"), selection: $administrationSection) {
                ForEach(AdministrationSection.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
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
                Text(L10n.text("Службы и способы входа")).font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            if let state = model.accessState {
                ForEach(state.services) { service in accessCard(service) }
            } else { StudioNote(symbol: "network", text: "Проверка доступов находится в «Подготовка модема» → «Подключение» → «Доступные способы подключения».") }
            sshPage
        }
    }
    func accessCard(_ service: AccessServiceState) -> some View {
        StudioCard {
            HStack {
                Text(L10n.text(service.title)).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(L10n.text(serviceStateLabel(service.state))).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(service.state == .running ? StudioStyle.accent : StudioStyle.secondary)
            }
            informationRow("Адрес", service.endpoint)
            Text(L10n.text(service.credentialModel)).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            Text(L10n.text(service.detail)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            if !service.allowedActions.isEmpty {
                HStack {
                    ForEach(service.allowedActions, id: \.rawValue) { action in
                        Button(L10n.text(action.title)) { model.changeService(service.id, action: action) }
                            .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    }
                    Spacer()
                    Text(L10n.text("До перезагрузки модема")).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
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
                Text(L10n.text("Отдельные данные и настройки")).font(.system(size: 18, weight: .semibold))
                Text(L10n.text("Выберите состав копии. Каждый архив сохраняется на Mac с проверкой устройства, размера и SHA256."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                Picker(L10n.text("Состав резервной копии"), selection: $model.deviceBackupKind) {
                    ForEach(DeviceBackupKind.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.pickerStyle(.segmented).disabled(model.busy)
                Text(L10n.text(model.deviceBackupKind.scope)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text(model.deviceBackupKind.limitations)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(action: model.createDeviceBackup) { Label(L10n.text("Создать копию"), systemImage: "plus") }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage)
                    Button(action: model.refreshDeviceBackups) { Label(L10n.text("Обновить список"), systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(model.busy)
                    Spacer()
                    Button(action: model.revealDeviceBackups) { Label(L10n.text("Папка копий"), systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                }
            }
            if !model.deviceBackups.isEmpty {
                StudioCard {
                    Text(L10n.text("Модемные, пользовательские и конфигурационные копии")).font(.system(size: 14, weight: .semibold))
                    ForEach(model.deviceBackups) { item in
                        Button { model.selectedDeviceBackupID = item.id } label: {
                            HStack {
                                Image(systemName: model.selectedDeviceBackupID == item.id ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.text(item.kind.title)).font(.system(size: 12, weight: .medium))
                                    Text(L10n.text(item.date)).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                                }
                                Spacer()
                                Text(L10n.text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))).font(.system(size: 11))
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                    HStack {
                        Button(action: model.verifyDeviceBackup) { Label(L10n.text("Проверить целостность"), systemImage: "checkmark.shield") }.buttonStyle(StudioButtonStyle())
                        Button(action: model.exportDeviceBackup) { Label(L10n.text("Экспортировать"), systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
                    }.disabled(model.busy || model.selectedDeviceBackupID == nil)
                }
            }
            StudioNote(symbol: "simcard", text: "Резервные копии NV550 и EFS для смены IMEI находятся в разделе «IMEI» → «Бэкапы IMEI».")
            Button(L10n.text("Открыть бэкапы IMEI")) { page = .imei; imeiSection = .backups }.buttonStyle(StudioButtonStyle())
        }.onAppear { model.refreshDeviceBackups(); model.refreshBackups(); model.refreshSystemBackups() }
    }
    var activityPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioCard {
                Text(L10n.text("Постоянный журнал действий")).font(.system(size: 18, weight: .semibold))
                Text(L10n.text("Сохраняется между запусками: этапы, проверки прошивки, SSH, USB/ADB и HTTP, длительность, коды завершения, ошибки и очищенный вывод. Запросы связаны с операциями и сеансом приложения. Секретный ввод не сохраняется; известные конфиденциальные поля скрываются."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(action: model.refreshActivity) { Label(L10n.text("Обновить"), systemImage: "arrow.clockwise") }.buttonStyle(StudioButtonStyle())
                    Button(action: model.revealActivity) { Label(L10n.text("Весь журнал"), systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                    Button(action: model.revealOperationLogs) { Label(L10n.text("Трассировки запросов"), systemImage: "doc.text") }.buttonStyle(StudioButtonStyle())
                }
                StudioField(label: "ПОИСК В ПОСЛЕДНИХ 400 СОБЫТИЯХ", placeholder: "Операция, ошибка или идентификатор", text: $model.activitySearch)
                if !model.journalWarning.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: model.journalWarning) }
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.filteredActivity) { event in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("Операция: " + event.operationID)).textSelection(.enabled)
                            ForEach(event.details.keys.sorted(), id: \.self) { key in
                                Text(L10n.text(key + ": " + (event.details[key] ?? ""))).textSelection(.enabled)
                            }
                        }.font(.system(size: 10, design: .monospaced)).padding(.vertical, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text(event.title)).font(.system(size: 12))
                            Text(activityDateLabel(event.timestamp) + " · " + L10n.text(activityResultLabel(event.result))).font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
                        }
                    }.padding(12).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            DisclosureGroup(L10n.text("Сообщения текущего сеанса")) { journalPage.padding(.top, 12) }
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
