import Foundation

extension AppModel {
    func refreshVPN() { performVPN() }
    func installVPN() { performVPN(install: true) }
    func performVPNProfile(_ operation: VPNOperation) { performVPN(operation: operation) }
    func saveVPNWiFi(_ configuration: VPNWiFiConfiguration, completion: @escaping @MainActor (Bool) -> Void) {
        guard canManage else { completion(false); return }
        performVPN(configuration: configuration, completion: completion)
    }
    private func performVPN(install: Bool = false, operation: VPNOperation? = nil, configuration: VPNWiFiConfiguration? = nil, completion: (@MainActor (Bool) -> Void)? = nil) {
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
                    var preparedOperation = operation
                    if let operation {
                        switch operation {
                        case .importSubscription(let url, let name, nil):
                            try operation.validate()
                            let documents = try await VPNSubscriptionDownload.documents(url.trimmingCharacters(in: .whitespacesAndNewlines))
                            preparedOperation = .importSubscription(url: url, name: name, documents: documents)
                        case .updateSubscription(let id, nil):
                            let url = try engine.locked { try target.verify(engine); return try VPNSettingsManager(engine: engine).subscriptionURL(id) }
                            let documents = try await VPNSubscriptionDownload.documents(url)
                            preparedOperation = .updateSubscription(id, documents: documents)
                        default: break
                        }
                    }
                    return try engine.locked {
                        try target.verify(engine)
                        let manager = VPNSettingsManager(engine: engine)
                        let result: VPNInspection
                        if let preparedOperation { result = try manager.perform(preparedOperation) }
                        else if let configuration { result = try manager.configureWiFi(configuration) }
                        else if install { result = try manager.install() }
                        else { result = try manager.inspect() }
                        try target.verify(engine)
                        return result
                    }
                }.value
                vpnInspection = result.preservingImportSummary(from: vpnInspection)
                append(operation?.message ?? (configuration != nil ? "Настройки Wi-Fi с VPN сохранены; сеть остаётся выключенной" : install ? "Компоненты VPN установлены" : "Состояние VPN обновлено"), progress: 1)
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
