import SwiftUI
import AppKit

extension ContentView {
    var diagnosticExportCard: some View {
        StudioCard {
            Text("Диагностический ZIP").font(.system(size: 18, weight: .semibold))
            Text("Для разбора проблем на других прошивках: журналы приложения, запросы и ошибки, сведения о системе и компонентах, отчёты модема. Экспорт сохранённых данных доступен без подключения.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Экспортировать журналы в ZIP") { model.exportDiagnostics(collectFresh: false) }
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy)
                Button("Собрать с модема и сохранить ZIP") { model.exportDiagnostics(collectFresh: true) }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canCollectDiagnostics)
            }
            Text("Свежий сбор использует выбранное подключение SSH или USB ADB без переключения на другой канал. Ключи, резервные копии и файлы VPN-профилей не включаются. Известные секреты скрываются; адреса сети и идентификаторы устройства остаются. Предел — 64 МиБ, все пропуски отмечаются в архиве.")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.diagnosticExportSummary.isEmpty {
                Text(model.diagnosticExportSummary).font(.system(size: 12)).textSelection(.enabled)
                if let url = model.diagnosticExportURL {
                    Button("Показать ZIP в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(StudioButtonStyle())
                }
            }
        }
    }
}
