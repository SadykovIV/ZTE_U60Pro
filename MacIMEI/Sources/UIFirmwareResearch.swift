import SwiftUI

enum ResearchUI {
    static func detail(_ value: String) -> String {
        guard L10n.language != "en" else { return value }
        let messages = [
            "SSH key or known_hosts file is unavailable.": "SSH-ключ или файл known_hosts недоступен.",
            "USB ADB root shell is available.": "Через USB ADB доступна оболочка с правами root.",
            "USB ADB is available without confirmed root; privilege-dependent results may be unknown.": "USB ADB доступен, права root не подтверждены; часть проверок может остаться без результата.",
            "Strict SSH host key verification passed; firmware research does not require a known firmware hash or root.": "Ключ сервера SSH проверен; для исследования не требуется известный хэш прошивки или root.",
            "CID or boot ID is unavailable. Device continuity has limited evidence; missing facts are not treated as compatible.": "CID или идентификатор загрузки недоступен. Возможности проверки устройства ограничены; отсутствующие сведения не означают совместимость.",
            "The sole USB ADB device was selected. Its relationship to the configured WEB IP address is not established.": "Выбрано единственное устройство USB ADB. Его связь с указанным адресом WEB не установлена.",
            "CID and boot fingerprints are both unavailable. Only bootstrap evidence was retained; the modem cannot be bound for further probes.": "Отпечатки CID и загрузки недоступны. Сохранены только начальные сведения: невозможно привязать дальнейшие проверки к конкретному модему.",
            "SSH host trust failed; automatic fallback is stopped.": "Ключ сервера SSH не прошёл проверку доверия; автоматический переход на другой канал остановлен.",
            "SSH failed; a responding or untrusted endpoint is not bypassed with ADB.": "Ошибка SSH: при ответе устройства или проблеме доверия переход на ADB не выполняется.",
            "Manual SSH mode requires SSH key and known_hosts files.": "При ручном выборе SSH необходимы ключ и файл known_hosts.",
            "No authorized USB ADB device. Research does not enable ADB or prepare the modem.": "Нет разрешённого устройства USB ADB. Исследование не включает ADB и не выполняет подготовку модема.",
            "Multiple USB ADB devices and no expected modem identity; no device was selected.": "Подключено несколько устройств USB ADB, ожидаемый модем неизвестен; автоматический выбор не выполнен.",
            "USB ADB did not identify exactly one matching modem.": "Через USB ADB не удалось однозначно определить подходящий модем.",
            "USB ADB device did not match the expected modem.": "Устройство USB ADB не совпало с ожидаемым модемом.",
            "Connected modem identity differs from the expected modem.": "Идентификация подключённого модема отличается от ожидаемой.",
            "Device identity or boot changed, or continuity could no longer be checked; collection stopped.": "Устройство или сеанс загрузки изменились либо их проверка стала недоступна; сбор остановлен.",
            "Device identity or boot changed after a probe; that probe's output was discarded and collection stopped.": "После проверки изменилось устройство или загрузка; её результат отброшен, дальнейший сбор остановлен.",
            "The eight-minute research time limit was reached.": "Достигнут предел времени исследования: восемь минут.",
            "The 16 MiB collection limit was reached.": "Достигнут предел объёма сбора: 16 МиБ.",
            "Firmware research requires SSH or USB ADB. Select automatic, SSH or ADB; manual WEB/agent mode does not switch channels.": "Для исследования нужен SSH или USB ADB. Выберите автоматический режим, SSH или ADB; при ручном выборе WEB или агента другие каналы не используются."
        ]
        return messages[value] ?? value
    }
    static func outcome(_ value: String) -> String {
        switch value {
        case "complete": return L10n.text("Сбор завершён", "Collection complete")
        case "partial": return L10n.text("Собран частичный отчёт", "Partial report collected")
        case "collecting": return L10n.text("Идёт сбор", "Collecting")
        case "cancelled": return L10n.text("Остановлено пользователем", "Cancelled")
        case "success": return L10n.text("Получено", "Collected")
        case "failed": return L10n.text("Ошибка команды", "Command failed")
        case "timeout": return L10n.text("Время ожидания истекло", "Timed out")
        case "truncated": return L10n.text("Вывод сокращён", "Output truncated")
        case "skipped": return L10n.text("Не запрашивалось", "Not requested")
        case "prerequisites_met": return L10n.text("Предпосылки выполнены", "Prerequisites met")
        case "blocked": return L10n.text("Есть препятствия", "Prerequisites blocked")
        case "unknown": return L10n.text("Недостаточно данных", "Insufficient evidence")
        case "available": return L10n.text("Доступен", "Available")
        case "unavailable": return L10n.text("Недоступен", "Unavailable")
        case "unconfigured": return L10n.text("Не настроен", "Not configured")
        case "host_trust_failed": return L10n.text("Ошибка доверия ключу", "Host trust failed")
        case "identity_mismatch": return L10n.text("Другое устройство", "Identity mismatch")
        case "authentication_or_shell_failed": return L10n.text("Ошибка входа или оболочки", "Authentication or shell failed")
        case "host_tool_version": return L10n.text("Версия инструмента", "Host tool version")
        case "enumerated": return L10n.text("Список устройств", "Devices enumerated")
        default: return value
        }
    }
}

extension ContentView {
    var firmwareResearchCard: some View {
        StudioCard {
            Label(L10n.text("Исследование прошивки", "Firmware research"), systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
            Text(L10n.text("Проверка условий для функций программы, включая eSIM. Это не общий вердикт совместимости прошивки: отсутствие данных отличается от конкретного препятствия, например прав каталога. Доступна через работающий USB ADB или SSH без ключа бэкапа и отключения проверки прошивки.", "Checks prerequisites for application features, including eSIM. This is not an overall firmware compatibility verdict: missing evidence differs from a specific blocker such as directory permissions. Available through working USB ADB or SSH without a backup key or firmware-check override."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Только чтение: без включения ADB, установки, перезагрузки и записи в модем. Результат не разрешает операции записи и не гарантирует их совместимость.", "Read-only: no ADB activation, installation, reboot or modem writes. Findings do not authorize writes or certify their compatibility."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L10n.text("Исследовать прошивку", "Research firmware"), action: model.startFirmwareResearch)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canResearchFirmware)
                if model.firmwareResearchRunning {
                    Button(L10n.text("Остановить", "Stop"), action: model.cancelFirmwareResearch).buttonStyle(StudioButtonStyle())
                }
                Button(L10n.text("Экспорт ZIP", "Export ZIP"), action: model.exportFirmwareResearch)
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy || model.firmwareResearchReport == nil)
                Spacer()
            }
            if model.firmwareResearchRunning { ProgressView(value: model.firmwareResearchProgress).tint(StudioStyle.accent) }
            if !model.firmwareResearchMessage.isEmpty { Text(model.firmwareResearchMessage).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).textSelection(.enabled) }
            if let report = model.firmwareResearchReport {
                HStack {
                    Text(report.startedAt).font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Text(report.transport.uppercased() + " · " + (report.profile ?? L10n.text("профиль неизвестен", "unknown profile")))
                        .font(.system(size: 11, weight: .medium))
                }.foregroundStyle(StudioStyle.secondary)
                if !report.features.isEmpty {
                    ForEach(report.features) { feature in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(feature.evidence.enumerated()), id: \.offset) { _, evidence in Text(evidence.text(L10n.language)).font(.system(size: 11)) }
                                Text(feature.limitations.text(L10n.language)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            }.padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
                        } label: {
                            HStack {
                                Text(feature.title.text(L10n.language)).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Label(ResearchUI.outcome(feature.state), systemImage: feature.state == "prerequisites_met" ? "checkmark.circle" : feature.state == "blocked" ? "exclamationmark.triangle" : "questionmark.circle")
                                    .font(.system(size: 10)).foregroundStyle(feature.state == "prerequisites_met" ? StudioStyle.accent : StudioStyle.secondary)
                            }
                        }
                    }
                }
                DisclosureGroup(L10n.text("Подключение, ограничения и отдельные проверки", "Connection, limitations and individual probes")) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(report.attempts.enumerated()), id: \.offset) { _, attempt in
                            Text(attempt.transport.uppercased() + ": " + ResearchUI.outcome(attempt.outcome) + ". " + ResearchUI.detail(attempt.detail)).font(.system(size: 11))
                        }
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in Text(ResearchUI.detail(warning)).font(.system(size: 11)).foregroundStyle(.orange) }
                        ForEach(report.probes) { probe in
                            HStack { Text(probe.title.text(L10n.language)); Spacer(); Text(ResearchUI.outcome(probe.outcome)) }.font(.system(size: 10))
                        }
                    }.padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            }
        }.onAppear(perform: model.loadFirmwareResearch)
    }
}
