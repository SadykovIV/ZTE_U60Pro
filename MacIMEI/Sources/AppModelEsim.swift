import Foundation

@MainActor extension AppModel {
    var esimTargetKey: String {
        [host, port, keyPath, knownHostsPath, sshSelectionContext.identity?.cid ?? "", sshSelectionContext.identity?.firmwareHash ?? "", activeChannel?.rawValue ?? ""].joined(separator: "\n")
    }
    var canReadEsim: Bool { canReadModem && !esimPreview && !pendingOperation && !setupPending && !systemRestorePending && !skipFirmwareCheck }
    var canWriteEsim: Bool { canManage && !esimPreview && !skipFirmwareCheck && esimAuthorization == esimTargetKey && esimSnapshot?.writeReady == true }
    func clearEsim() { esimSnapshot = nil; esimAuthorization = nil; esimSelectedICCID = nil; esimMessage = ""; esimError = "" }
    func performEsim(_ operation: EsimOperation) {
        guard operation.mutates ? canWriteEsim : canReadEsim else { return }
        let before = esimSnapshot, config = connection, target = sshSelectionContext, key = esimTargetKey
        let root = storage, assets = resources, logID = UUID()
        // An explicit selected SSH identity is required for this bounded B31 workflow.
        guard target.identity != nil || target.session?.summary.identity != nil else { esimError = "Проверьте SSH-подключение к модему перед чтением eSIM."; return }
        do { _ = try operation.request(snapshot: before); try config.validate() }
        catch { esimError = EsimFailure.invalidInput.localizedDescription; return }
        esimAuthorization = nil; esimError = ""; esimMessage = "Проверяю карту…"; busy = true; progress = 0; esimOperationActive = true; esimLogID = logID
        append("eSIM · " + operation.name + " · Начинаю операцию; подробный ход появится в журнале.")
        let report: @Sendable (String) -> Void = { [weak self] stage in
            guard let target = self else { return }
            Task { @MainActor in
                guard target.esimLogID == logID else { return }
                target.esimMessage = stage
            }
        }
        let journal: @Sendable (String) -> Void = { [weak self] metadata in
            guard let target = self else { return }
            Task { @MainActor in
                guard target.esimLogID == logID else { return }
                target.append(metadata)
            }
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let engine = try ModemEngine(root: root, resources: assets, connection: config)
                    return try engine.locked {
                        try target.verify(engine)
                        return try EsimService(connection: config, resources: assets).perform(operation, expected: before, journal: journal, progress: report)
                    }
                }.value
                guard self.esimTargetKey == key else { throw EsimFailure.targetChanged }
                self.esimSnapshot = result.snapshot; self.esimAuthorization = key
                if !((result.snapshot?.profiles.contains { $0.iccid == self.esimSelectedICCID }) ?? false) { self.esimSelectedICCID = nil }
                self.esimMessage = operation.name == "enable" ? "Профиль активен, SIM перечитана, радио включено. Регистрация в мобильной сети проверяется отдельно." : operation.name == "download" ? "Профиль установлен и выключен. Выберите его для активации." : operation.name == "delete" ? "Профиль удалён. Список перечитан с карты." : "Все профили прочитаны с карты."
                if result.notificationsPending == true { self.esimMessage += " Уведомления оператору ещё не доставлены." }
                self.progress = 1
                // Only allowlisted metadata and fixed error codes are journaled.
                self.append("Операция eSIM завершена", progress: 1)
            } catch {
                self.esimAuthorization = nil; self.esimSnapshot = nil; self.esimSelectedICCID = nil
                let failure = error as? EsimFailure ?? .transport
                self.esimError = failure.localizedDescription
                self.esimMessage = ""
                self.append("eSIM · " + operation.name + " · error=" + EsimLog.failureCode(failure) + "; recovery=" + EsimLog.recoveryCode(failure))
            }
            self.busy = false; self.esimOperationActive = false; self.esimLogID = nil; self.operationTask = nil
        }
    }
    func loadEsimPreview(force: Bool = false) {
        guard force || CommandLine.arguments.contains("--esim-ui-fixture") else { return }
        esimPreview = true
        connectionsChecked = true
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: "ru"], forName: UserDefaults.argumentDomain)
        esimSnapshot = EsimSnapshot(ok: true, eid: "89000000000000000000000000000001", profiles: [
            EsimProfile(iccid: "8900000000000000001", isdpAid: "A0000000000000000000000000000001", state: "enabled", enabled: true, nickname: "Основной", serviceProvider: "Demo Mobile", name: "Рабочий тариф"),
            EsimProfile(iccid: "8900000000000000002", isdpAid: "A0000000000000000000000000000002", state: "disabled", enabled: false, nickname: "Для поездок", serviceProvider: "Demo Travel", name: "Европа")
        ])
        esimMessage = "Демонстрационные данные. Подключение и операции с картой отключены."
        esimAuthorization = nil
    }
}
