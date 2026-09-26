import Foundation
import AppKit

@MainActor extension AppModel {
    var canUseOpkgConsole: Bool { canManage && experimentalOpkgStatus?.installed == true }
    func copyExperimentalOpkgCommand() {
        guard canUseOpkgConsole else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ExperimentalOpkgManager.remoteRoot + "/opkg", forType: .string)
        append("Путь адаптера opkg скопирован для SSH-сеанса модема.")
    }
    func installExperimentalOpkg() { manageExperimentalOpkg("install-adapter") }
    func removeExperimentalOpkg() { manageExperimentalOpkg("remove-adapter") }
    func rollbackExperimentalOpkg() { manageExperimentalOpkg("rollback") }
    func refreshExperimentalOpkg() { manageExperimentalOpkg("inspect") }
    func runOpkgCommand() {
        guard canUseOpkgConsole else { return }
        do {
            let command = try OpkgConsoleCommand.parse(opkgCommand)
            if opkgHistory.last != command.display { opkgHistory.append(command.display) }
            opkgHistory = Array(opkgHistory.suffix(50))
            manageExperimentalOpkg("command", arguments: command.arguments, display: command.display)
        } catch { appendOpkgOutput("Ошибка: " + error.localizedDescription) }
    }
    func removeExperimentalPackage(_ name: String) {
        guard canUseOpkgConsole, experimentalOpkgStatus?.packages.contains(where: { $0.name == name }) == true else { return }
        opkgCommand = "opkg remove " + name; runOpkgCommand()
    }
    func appendOpkgOutput(_ text: String) {
        // The console is session-only and bounded, including remote output.
        let clean = ActivityJournal.redact(text).unicodeScalars.filter { $0.value == 10 || $0.value == 9 || !CharacterSet.controlCharacters.contains($0) }
        opkgTranscript += (opkgTranscript.isEmpty ? "" : "\n") + String(String.UnicodeScalarView(clean))
        if opkgTranscript.utf8.count > 131072 { opkgTranscript = "[Предыдущий вывод сокращён]\n" + String(opkgTranscript.suffix(65536)) }
    }
    private func manageExperimentalOpkg(_ action: String, arguments: [String] = [], display: String? = nil) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources, target = sshSelectionContext
        experimentalOpkgError = ""; busy = true; progress = 0
        if let display { appendOpkgOutput("$ " + display) }
        append("opkg: " + (display ?? action))
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> (ExperimentalOpkgResult, ModemApplicationStorage?) in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        try target.verify(engine)
                        let manager = ExperimentalOpkgManager(engine: engine)
                        let outcome: ExperimentalOpkgResult = try {
                        switch action {
                        case "install-adapter": return try manager.installAdapter()
                        case "remove-adapter": return try manager.removeAdapter()
                        case "rollback": return try manager.rollback()
                        case "command": return try manager.execute(arguments)
                        default: return ExperimentalOpkgResult(output: "Состояние opkg обновлено.", status: try manager.inspect())
                        }
                        }()
                        let storage = try? ModemApplications(engine: engine).inventory().applicationStorage
                        try target.verify(engine)
                        return (outcome, storage)
                    }
                }.value
                experimentalOpkgStatus = result.0.status
                applicationInventory?.applicationStorage = result.1
                appendOpkgOutput(result.0.output.isEmpty ? "Команда завершена." : result.0.output)
                append("opkg: операция завершена.", progress: 1)
            } catch {
                experimentalOpkgStatus = nil
                experimentalOpkgError = OpkgConsoleCommand.failureMessage(ActivityJournal.redact(error.localizedDescription))
                appendOpkgOutput("Ошибка: " + experimentalOpkgError)
                append("opkg: " + experimentalOpkgError)
            }
            busy = false; refreshActivity(); operationTask = nil
        }
    }
}
