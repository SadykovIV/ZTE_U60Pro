import SwiftUI

extension ContentView {
    func diagnosticApplicationCard(_ tool: DiagnosticTool) -> some View {
        let installed = model.diagnosticToolsStatus.map { $0.isInstalled(tool.id) }
        let version = installed == true && model.diagnosticToolsStatus?.active != model.diagnosticToolsBundle?.id
            ? "Сохранённая версия" : model.diagnosticToolsBundle?.version(tool.id) ?? ""
        return ApplicationTile(name: tool.name, version: version,
                               summary: tool.purpose, installed: installed) {
            HStack(spacing: 8) {
                if installed == true {
                    Button("Команда SSH") { model.copyDiagnosticToolCommand(tool.id) }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
                    Spacer(minLength: 0)
                    Button("Удалить") { model.removeDiagnosticTool(tool.id) }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.diagnosticToolsStatus?.running == true)
                } else {
                    Button("Установить") { model.installDiagnosticTool(tool.id) }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canManage || installed == nil || model.diagnosticToolsStatus?.running == true)
                }
            }
        }
    }
    var diagnosticToolsMaintenance: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.diagnosticToolsStatus?.canRollback == true {
                HStack {
                    Text("Последнее изменение диагностических приложений можно отменить.")
                        .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    Spacer()
                    Button("Откатить", action: model.rollbackDiagnosticTools)
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.diagnosticToolsStatus?.running == true)
                }
            }
            DisclosureGroup("Как устанавливаются приложения") {
                Text("Каждая карточка управляет одним приложением. Перед установкой автоматически проверяются устройство, совместимость, место и контрольные суммы; перед применением проверки повторяются. Измерения и захват трафика запускаются вручную.\n\nДиагностические утилиты используют общий неизменяемый комплект библиотек в /data. При удалении утилита исключается из установленных; приватный комплект остаётся для остальных приложений и отката и продолжает занимать место. «Откатить» возвращает состояние до последнего изменения. Файлы по приватному пути остаются доступны root. При работающей утилите изменение комплекта заблокировано.\n\nСистемные библиотеки и ZTEDATA не изменяются. Для расширенной установки предусмотрена отдельная вкладка opkg.")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        }
    }
}
