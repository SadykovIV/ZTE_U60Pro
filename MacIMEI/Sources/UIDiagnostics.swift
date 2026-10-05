import SwiftUI
import AppKit

enum DiagnosticsSection: String, CaseIterable, Identifiable {
    case connection = "Подключение и ADB"
    case firmware = "Устройство и прошивка"
    case reports = "Сбор и экспорт"
    var id: String { rawValue }
}

extension ContentView {
    var preparationDiagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(L10n.text("Раздел диагностики"), selection: $diagnosticsSection) {
                ForEach(DiagnosticsSection.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if diagnosticsSection != .reports {
                DisclosureGroup(L10n.text("Параметры диагностического подключения"), isExpanded: $diagnosticSettingsExpanded) {
                    connectionParametersCard(forDiagnostics: true).padding(.top, 10)
                }
                .font(.system(size: 12, weight: .medium))
            }
            switch diagnosticsSection {
            case .connection:
                connectionDiagnosticsCard
                accessDiagnosticsCard
                diagnosticADBCard
            case .firmware:
                firmwareResearchCard
            case .reports:
                diagnosticsPage
            }
        }
    }

    var diagnosticExportCard: some View {
        StudioCard {
            Text(L10n.text("Диагностический ZIP")).font(.system(size: 18, weight: .semibold))
            Text(L10n.text("Для разбора проблем на других прошивках: журналы приложения, запросы и ошибки, сведения о системе и компонентах, отчёты модема. Экспорт сохранённых данных доступен без подключения."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Общий диагностический архив включает журнал действий программы и трассировки запросов. Просмотр журнала остаётся в «Администрирование» → «Журнал действий»."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Экспортировать журналы в ZIP")) { model.exportDiagnostics(collectFresh: false) }
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy)
                Button(L10n.text("Собрать с модема и сохранить ZIP")) { model.exportDiagnostics(collectFresh: true) }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canCollectDiagnostics)
            }
            Text(L10n.text("Свежий сбор использует выбранное подключение SSH или USB ADB без переключения на другой канал. Ключи, резервные копии и файлы VPN-профилей не включаются. Известные секреты скрываются; адреса сети и идентификаторы устройства остаются. Предел — 64 МиБ, все пропуски отмечаются в архиве."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.diagnosticExportSummary.isEmpty {
                Text(L10n.text(model.diagnosticExportSummary)).font(.system(size: 12)).textSelection(.enabled)
                if let url = model.diagnosticExportURL {
                    Button(L10n.text("Показать ZIP в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(StudioButtonStyle())
                }
            }
        }
    }
}
