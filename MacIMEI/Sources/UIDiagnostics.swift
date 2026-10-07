import SwiftUI
import AppKit

extension ContentView {
    var preparationDiagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            diagnosticExportCard
            firmwareSupportCard
        }
    }

    var firmwareSupportCard: some View {
        StudioCard {
            HStack {
                Text(L10n.text("Данные для адаптации прошивки")).font(.system(size: 18, weight: .semibold))
                OperationInfoButton(topic: .firmwareSupport)
                Spacer()
            }
            Text(L10n.text("Сведения об устройстве, проверки функций программы, структура прошивки и исходные файлы её компонентов — в одном ZIP. Подробные результаты сохраняются в архиве."))
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
            Text(L10n.text("Логи и журналы")).font(.system(size: 18, weight: .semibold))
            Text(L10n.text("Журналы подготовки и подключений, действия программы и ошибки операций. При подключении по SSH добавляются доступные журналы модема и компонентов программы."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("Сохранить логи и журналы")) { model.exportDiagnostics() }
                .buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.busy)
            Text(L10n.text("Если модем недоступен, ZIP сохранит локальные журналы и причину пропуска. Просмотр журнала действий остаётся в «Администрирование». Пароли, ключи и профили не включаются."))
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
