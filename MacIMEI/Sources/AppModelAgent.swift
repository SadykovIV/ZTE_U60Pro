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
            try engine.locked { try AgentInstallationManager(engine: engine).inspect() }
        }, finish: { [weak self] value in self?.agentInstallationStatus = value; self?.append("Состояние агента обновлено") })
    }
    func installAgent(custom: Bool) {
        guard canManage else { return }
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
            try engine.locked {
                let manager = AgentInstallationManager(engine: engine)
                return try custom ? manager.install(candidate) : manager.installBundled(candidate)
            }
        }, finish: { [weak self] value in
            self?.agentInstallationStatus = value; self?.vpnInspection = nil; self?.modemInformation = nil
            self?.append(custom ? "Выбранный агент установлен и запущен" : "Агент с eSIM и веб-панель установлены")
        })
    }
    func restoreAgent() {
        runManaged("Восстанавливаю предыдущий агент…", work: { engine in
            try engine.locked { try AgentInstallationManager(engine: engine).restore() }
        }, finish: { [weak self] value in
            self?.agentInstallationStatus = value; self?.vpnInspection = nil; self?.modemInformation = nil
            self?.append("Предыдущий агент восстановлен и запущен")
        })
    }
}
