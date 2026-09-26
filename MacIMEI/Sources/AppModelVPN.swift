import Foundation

extension AppModel {
    func refreshVPN() { performVPN() }
    func installVPN() { performVPN(install: true) }
    func saveVPNWiFi(_ configuration: VPNWiFiConfiguration, completion: @escaping @MainActor (Bool) -> Void) {
        guard canManage else { completion(false); return }
        performVPN(configuration: configuration, completion: completion)
    }
    private func performVPN(install: Bool = false, configuration: VPNWiFiConfiguration? = nil, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources
        let target = sshSelectionContext
        busy = true; progress = 0; vpnError = ""
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        try target.verify(engine)
                        let manager = VPNSettingsManager(engine: engine)
                        let result: VPNInspection
                        if let configuration { result = try manager.configureWiFi(configuration) }
                        else if install { result = try manager.install() }
                        else { result = try manager.inspect() }
                        try target.verify(engine)
                        return result
                    }
                }.value
                vpnInspection = result
                append(configuration != nil ? "Настройки Wi-Fi с VPN сохранены; сеть остаётся выключенной" : install ? "Компоненты VPN установлены" : "Состояние VPN обновлено", progress: 1)
                completion?(true)
            } catch {
                vpnError = error.localizedDescription
                append("VPN: " + error.localizedDescription)
                completion?(false)
            }
            busy = false; operationTask = nil
        }
    }
}
