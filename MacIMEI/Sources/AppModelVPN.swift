import Foundation

extension AppModel {
    func refreshVPN() { performVPN() }
    func installVPN() { performVPN(install: true) }
    private func performVPN(install: Bool = false) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources
        busy = true; progress = 0; vpnError = ""
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        let manager = VPNSettingsManager(engine: engine)
                        if install { return try manager.install() }
                        return try manager.inspect()
                    }
                }.value
                vpnInspection = result
                append(install ? "Компоненты VPN установлены" : "Состояние VPN обновлено", progress: 1)
            } catch {
                vpnError = error.localizedDescription
                append("VPN: " + error.localizedDescription)
            }
            busy = false; operationTask = nil
        }
    }
}
