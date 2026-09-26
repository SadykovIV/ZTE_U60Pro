import Foundation
import AppKit

@MainActor extension AppModel {
    var diagnosticToolsBundle: DiagnosticToolsBundle? { try? DiagnosticToolsManager.bundle(resources: resources) }
    var canInstallDiagnosticTools: Bool { canManage && diagnosticToolsPlan != nil && diagnosticToolsPlan?.before.active != diagnosticToolsPlan?.bundleID && diagnosticToolsStatus?.running != true }
    func installDiagnosticTool(_ toolID: String) {
        guard catalogAllowsInstallation(toolID) else { return }
        guard DiagnosticTool.catalog.contains(where: { $0.id == toolID }), diagnosticToolsStatus?.isInstalled(toolID) == false else { return }
        manageDiagnosticTools("install-one", toolID: toolID)
    }
    func removeDiagnosticTool(_ toolID: String) {
        guard DiagnosticTool.catalog.contains(where: { $0.id == toolID }), diagnosticToolsStatus?.isInstalled(toolID) == true else { return }
        manageDiagnosticTools("remove-one", toolID: toolID)
    }
    func prepareDiagnosticTools() { manageDiagnosticTools("prepare") }
    func installDiagnosticTools() {
        guard canInstallDiagnosticTools, DiagnosticTool.ids.allSatisfy({ catalogAllowsInstallation($0) }) else { return }
        manageDiagnosticTools("install")
    }
    func removeDiagnosticTools() { guard diagnosticToolsStatus?.installed == true else { return }; manageDiagnosticTools("remove") }
    func rollbackDiagnosticTools() { guard diagnosticToolsStatus?.canRollback == true else { return }; manageDiagnosticTools("rollback") }
    func refreshDiagnosticTools() { manageDiagnosticTools("inspect") }
    func copyDiagnosticToolCommand(_ name: String) {
        guard let active = diagnosticToolsStatus?.active, diagnosticToolsStatus?.isInstalled(name) == true, DiagnosticTool.catalog.contains(where: { $0.id == name }) else { return }
        let command = DiagnosticToolsManager.remoteRoot + "/releases/" + active + "/bin/" + name
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        append("Команда \(name) скопирована. Выполните её в SSH-сеансе модема.")
    }
    private func manageDiagnosticTools(_ action: String, toolID: String? = nil) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources, target = sshSelectionContext, plan = diagnosticToolsPlan
        if action == "install" && plan == nil { return }
        diagnosticToolsPlan = nil; diagnosticToolsError = ""
        busy = true; progress = 0
        append(action == "prepare" ? "Перепроверяю диагностический набор, модем и место для отката…" : "Диагностический набор: \(action)…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> (DiagnosticToolsStatus, DiagnosticToolsPlan?, ModemApplicationStorage?) in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        try target.verify(engine)
                        let manager = DiagnosticToolsManager(engine: engine)
                        let outcome: (DiagnosticToolsStatus, DiagnosticToolsPlan?) = try {
                        switch action {
                        case "install-one":
                            guard let toolID else { throw IMEIError.message("Не выбрано приложение") }
                            let prepared = try manager.prepare(toolID: toolID)
                            return (try manager.install(prepared), nil)
                        case "remove-one":
                            guard let toolID else { throw IMEIError.message("Не выбрано приложение") }
                            return (try manager.change("remove", toolID: toolID), nil)
                        case "prepare": let value = try manager.prepare(); return (value.before, value)
                        case "install": return (try manager.install(plan!), nil)
                        case "remove", "rollback": return (try manager.change(action), nil)
                        default: return (try manager.inspect(), nil)
                        }
                        }()
                        let storage = try? ModemApplications(engine: engine).inventory().applicationStorage
                        try target.verify(engine)
                        return (outcome.0, outcome.1, storage)
                    }
                }.value
                diagnosticToolsStatus = result.0; diagnosticToolsPlan = result.1
                applicationInventory?.applicationStorage = result.2
                switch action {
                case "install-one": append("\(toolID ?? "Приложение") установлено. Файлы и запуск проверены.", progress: 1)
                case "remove-one": append("\(toolID ?? "Приложение") удалено из установленных; общий комплект сохранён для отката.", progress: 1)
                case "prepare": append("Проверка пройдена. Можно установить набор; перед применением модем и файлы будут проверены ещё раз.", progress: 1)
                case "remove": append("Набор удалён из активного состояния. Копия сохранена для восстановления кнопкой «Откатить».", progress: 1)
                case "rollback": append("Предыдущее состояние диагностического набора восстановлено.", progress: 1)
                case "install": append("Диагностический набор установлен, версии и целостность проверены. Утилиты запускаются вручную по SSH.", progress: 1)
                default: append("Состояние диагностического набора обновлено.", progress: 1)
                }
            } catch {
                diagnosticToolsStatus = nil; diagnosticToolsError = ActivityJournal.redact(error.localizedDescription)
                append("Диагностический набор: " + diagnosticToolsError)
            }
            busy = false; refreshActivity(); operationTask = nil
        }
    }
}
