import SwiftUI

extension ContentView {
    func diagnosticApplicationCard(_ tool: DiagnosticTool) -> some View {
        let installed = model.diagnosticToolsStatus.map { $0.isInstalled(tool.id) }
        let version = installed == true && model.diagnosticToolsStatus?.active != model.diagnosticToolsBundle?.id
            ? "Сохранённая версия" : verifiedCatalog.entry(tool.id)?.version ?? model.diagnosticToolsBundle?.version(tool.id) ?? ""
        return ApplicationTile(name: tool.name, version: version,
                               summary: verifiedCatalog.entry(tool.id)?.description(language: L10n.language) ?? L10n.text(tool.purpose), installed: installed,
                               verification: verifiedCatalog.entry(tool.id)?.verification.summary.text(language: L10n.language)) {
            HStack(spacing: 8) {
                if installed == true {
                    Button(L10n.text("Команда SSH")) { model.copyDiagnosticToolCommand(tool.id) }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    Spacer(minLength: 0)
                    Button(L10n.text("Удалить")) { model.removeDiagnosticTool(tool.id) }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.diagnosticToolsStatus?.running == true)
                } else {
                    Button(L10n.text("Установить")) { model.installDiagnosticTool(tool.id) }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || installed == nil || model.diagnosticToolsStatus?.running == true)
                }
            }
        }
    }
    var diagnosticToolsMaintenance: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.diagnosticToolsStatus?.canRollback == true {
                HStack {
                    Text(L10n.text("Последнее изменение диагностических приложений можно отменить."))
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    Spacer()
                    Button(L10n.text("Откатить"), action: model.rollbackDiagnosticTools)
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.diagnosticToolsStatus?.running == true)
                }
            }
            DisclosureGroup(L10n.text("Как устанавливаются приложения")) {
                Text(L10n.text("Каждая карточка управляет одним приложением. Перед установкой автоматически проверяются устройство, совместимость, место и контрольные суммы; перед применением проверки повторяются. Измерения и захват трафика запускаются вручную.\n\nДиагностические утилиты используют общий неизменяемый комплект библиотек в /data. При удалении утилита исключается из установленных; приватный комплект остаётся для остальных приложений и отката и продолжает занимать место. «Откатить» возвращает состояние до последнего изменения. Файлы по приватному пути остаются доступны root. При работающей утилите изменение комплекта заблокировано.\n\nСистемные библиотеки и ZTEDATA не изменяются. Для расширенной установки предусмотрена вкладка Terminal."))
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        }
    }
}
