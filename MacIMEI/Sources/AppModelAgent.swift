import Foundation
import AppKit

@MainActor extension AppModel {
    func chooseCustomAgent() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите агент для Linux ARM64"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            customAgent = try AgentCandidate.inspect(url)
            append("Выбран свой файл агента: " + url.lastPathComponent)
        } catch { customAgent = nil; append("Файл агента отклонён: " + error.localizedDescription) }
    }
    func refreshAgent() {
        runManaged("Проверяю агент и возможность восстановления…", readOnly: true, work: { engine in
            var value = try engine.locked { try AgentInstallationManager(engine: engine).inspect() }
            value.web = AgentWebDiagnostics.collect(engine: engine)
            return value
        }, finish: { [weak self] value in
            self?.agentInstallationStatus = value; self?.append("Состояние агента обновлено")
            if let web = value.web { self?.append(web.log) }
        })
    }
    func installAgent(custom: Bool) {
        guard custom ? canManage : canReplaceCore else { return }
        if !custom {
            let config = connection, root = storage, assets = resources, expected = connectedIdentity
            busy = true; progress = 0; agentInstallationStatus = nil; vpnInspection = nil; modemInformation = nil
            clearEsim()
            append("Заменяю агент и веб-панель с сохранением настроек…")
            operationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                        let installer = try OnboardingEngine(root: root, resources: assets, connection: config, update: { [weak self] message, value in
                            Task { @MainActor [weak self] in self?.append(message, progress: value) }
                        })
                        return try installer.replaceCore(webPassword: "", agentPassword: "", preserveSettings: true, expectedIdentity: expected)
                    }.value
                    keyPath = result.connection.keyPath; knownHostsPath = result.connection.knownHostsPath; port = result.connection.port
                    append("Агент и веб-панель обновлены; пользовательские настройки сохранены", progress: 1)
                } catch { append("Установка агента: " + error.localizedDescription) }
                busy = false; refreshBackups(); refreshActivity(); operationTask = nil
                refreshAgent()
            }
            return
        }
        let candidate: AgentCandidate
        do {
            if custom {
                guard let selected = customAgent else { return }
                candidate = selected
            } else {
                candidate = try AgentCandidate.inspect(resources.appendingPathComponent("Onboarding/zte-agent"))
                try require(candidate.sha256 == VPNSettingsManager.agentHash, "Повреждён встроенный агент")
            }
        } catch { append("Установка агента: " + error.localizedDescription); return }
        agentInstallationStatus = nil; vpnInspection = nil; modemInformation = nil
        clearEsim()
        runManaged(custom ? "Устанавливаю выбранный агент…" : "Устанавливаю агент из комплекта приложения…", work: { engine in
            var value = try engine.locked {
                let manager = AgentInstallationManager(engine: engine)
                return try custom ? manager.install(candidate) : manager.installBundled(candidate)
            }
            value.web = AgentWebDiagnostics.collect(engine: engine)
            return value
        }, finish: { [weak self] value in
            self?.agentInstallationStatus = value; self?.vpnInspection = nil; self?.modemInformation = nil
            self?.append(custom ? "Выбранный агент установлен и запущен" : "Агент с eSIM и веб-панель установлены")
            if let web = value.web { self?.append(web.log) }
        })
    }
    func restoreAgent() {
        runManaged("Восстанавливаю предыдущий агент…", work: { engine in
            var value = try engine.locked { try AgentInstallationManager(engine: engine).restore() }
            value.web = AgentWebDiagnostics.collect(engine: engine)
            return value
        }, finish: { [weak self] value in
            self?.agentInstallationStatus = value; self?.vpnInspection = nil; self?.modemInformation = nil
            self?.append("Предыдущий агент восстановлен и запущен")
            if let web = value.web { self?.append(web.log) }
        })
    }
}
