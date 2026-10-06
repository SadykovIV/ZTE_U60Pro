import SwiftUI
import AppKit

extension ContentView {
    var preparationDiagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            firmwareResearchCard
            firmwareSupportCard
            diagnosticsPage
        }
    }

    var firmwareSupportCard: some View {
        StudioCard {
            HStack {
                Text(L10n.text("Данные для адаптации прошивки")).font(.system(size: 18, weight: .semibold))
                OperationInfoButton(topic: .firmwareSupport)
                Spacer()
            }
            Text(L10n.text("Экранный интерфейс и языковые файлы, безопасные сведения о системе и агенте, журнал программы. Сбор через SSH без изменения модема."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("Собрать данные для адаптации прошивки")) { model.collectFirmwareSupport() }
                .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canCollectFirmwareSupport)
            if !model.firmwareSupportExportSummary.isEmpty {
                Text(L10n.text(model.firmwareSupportExportSummary)).font(.system(size: 12)).textSelection(.enabled)
                if let url = model.firmwareSupportExportURL {
                    Button(L10n.text("Показать ZIP в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(StudioButtonStyle())
                }
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
            Text(L10n.text("Свежий сбор выполняется через SSH. Ключи, резервные копии и файлы VPN-профилей не включаются. Известные секреты скрываются; адреса сети и идентификаторы устройства остаются. Предел — 64 МиБ, все пропуски отмечаются в архиве."))
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
