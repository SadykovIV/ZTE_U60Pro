import Foundation

@MainActor extension AppModel {
    func openTerminal() {
        guard canManage, !terminalSession.active else { return }
        let config = connection, root = storage, assets = resources, target = sshSelectionContext
        busy = true; terminalError = ""
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await Task.detached(priority: .userInitiated) {
                    let engine = try ModemEngine(root: root, resources: assets, connection: config)
                    return try engine.locked { try target.verify(engine); return try engine.diagnosticIdentity() }
                }.value
                try require(config.host == self.connection.host && config.port == self.connection.port && self.connected && self.activeChannel == .ssh,
                            "Подключение изменилось перед открытием терминала")
                self.terminalSession.onActiveChange = { [weak self] active in self?.terminalActive = active }
                try self.terminalSession.start(connection: config, identity: identity.0, bootID: identity.1)
                self.append("Открыт SSH-терминал. Ввод и вывод терминала не записываются в журнал приложения.")
            } catch { self.terminalError = error.localizedDescription }
            self.busy = false; self.operationTask = nil
        }
    }
    func closeTerminal() { terminalSession.disconnect(); terminalActive = false }
    func sendTerminalCommand() {
        guard terminalSession.connected, !opkgCommand.isEmpty else { return }
        if terminalSession.send(opkgCommand + "\r") { opkgCommand = "" }
    }
    func loadOpkgFeeds() { manageOpkgFeeds(save: false) }
    func saveOpkgFeeds() { manageOpkgFeeds(save: true) }
    private func manageOpkgFeeds(save: Bool) {
        guard canUseOpkgConsole else { return }
        let config = connection, root = storage, assets = resources, target = sshSelectionContext
        let text = opkgFeedsDraft, previous = opkgFeeds?.generation
        guard !save || previous != nil else { return }
        busy = true; opkgFeedsMessage = ""
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let engine = try ModemEngine(root: root, resources: assets, connection: config)
                    return try engine.locked {
                        try target.verify(engine)
                        let manager = ExperimentalOpkgManager(engine: engine)
                        if save, let previous { _ = try manager.saveFeeds(text, expectedGeneration: previous) }
                        let feeds = try manager.loadFeeds()
                        let status = try manager.inspect()
                        try target.verify(engine)
                        return (feeds, status)
                    }
                }.value
                self.opkgFeeds = result.0; self.opkgFeedsDraft = result.0.text
                self.experimentalOpkgStatus = result.1
                self.opkgFeedsMessage = save ? "Источники сохранены. Выполните opkg update в Terminal. Предыдущая конфигурация доступна через откат." : "Источники прочитаны с модема."
            } catch { self.opkgFeedsMessage = error.localizedDescription }
            self.busy = false; self.operationTask = nil
        }
    }
}
