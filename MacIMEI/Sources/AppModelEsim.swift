import Foundation

@MainActor extension AppModel {
    var esimTargetKey: String {
        [host, port, keyPath, knownHostsPath, channelSession?.summary.bootID ?? "", activeChannel?.rawValue ?? "", esimSelectedTarget?.rawValue ?? "", esimSnapshot?.eid ?? ""].joined(separator: "\n")
    }
    var canReadEsim: Bool { canReadModem && !esimPreview }
    var canWriteEsim: Bool { canManage && canReadEsim && esimAuthorization == esimTargetKey && esimSelectedTarget != nil && esimSnapshot?.target == esimSelectedTarget && esimSnapshot?.writeReady == true }
    func canPerformEsim(_ operation: String) -> Bool { canWriteEsim && esimAllowedOperations.contains(operation) }
    var confirmedEsimTargets: [EsimDiscoveredTarget] { esimTargets.filter(\.confirmed) }
    var hasOrdinarySIM: Bool { esimCard?.kind == "ordinary_sim" && esimAuthorization == esimTargetKey }
    var esimCardStatus: String {
        if esimOperationActive { return "Тип SIM-карты: проверка…" }
        if hasOrdinarySIM { return "Карта не предоставляет eUICC. Управление профилями недоступно." }
        if esimSnapshot != nil && esimAuthorization == esimTargetKey { return "eUICC подтверждена: EID и профили прочитаны." }
        if confirmedEsimTargets.count > 1 && esimSelectedTarget == nil { return "Найдено несколько eUICC. Выберите карту для управления профилями." }
        if !esimTargets.isEmpty && esimSelectedTarget == nil { return esimDiscoveryComplete ? "Карты проверены. Управление профилями eSIM недоступно." : "Не все карты удалось проверить. Повторите проверку или выберите подтверждённую eUICC." }
        if !esimError.isEmpty { return "Тип SIM-карты определить не удалось. Ошибка чтения не означает, что карта обычная." }
        return "Тип SIM-карты ещё не проверен. Нажмите «Проверить карту и профили»."
    }
    func clearEsim() { esimTargets = []; esimSelectedTarget = nil; esimAllowedOperations = []; esimNetworkSelected = nil; esimDiscoveryComplete = false; esimSnapshot = nil; esimCard = nil; esimAuthorization = nil; esimSelectedICCID = nil; esimMessage = ""; esimError = "" }
    func selectEsimTarget(_ target: EsimTarget?) {
        guard !busy, let target, confirmedEsimTargets.contains(where: { $0.target == target }) else { return }
        esimSelectedTarget = target; esimSnapshot = nil; esimCard = nil; esimAuthorization = nil; esimSelectedICCID = nil; esimAllowedOperations = []; esimNetworkSelected = nil
        performEsim(.list)
    }
    func performEsim(_ operation: EsimOperation) {
        guard operation.mutates ? canPerformEsim(operation.name) : canReadEsim else { return }
        let discovering = operation.name == "discover"
        let target = discovering ? nil : esimSelectedTarget
        let before = operation.mutates ? esimSnapshot : nil, config = connection, session = channelSession, key = esimTargetKey
        let assets = resources, logID = UUID()
        do { _ = try operation.request(snapshot: before, target: target); try config.validate() }
        catch { esimError = EsimFailure.invalidInput.localizedDescription; return }
        esimAuthorization = nil; esimCard = nil; esimError = ""; esimMessage = "Проверяю карту…"; busy = true; progress = 0; esimOperationActive = true; esimLogID = logID
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
                    if let session { _ = try session.requireSSH() }
                    let result = try EsimService(connection: config, resources: assets).perform(operation, expected: before, target: target, journal: journal, progress: report)
                    if let session { _ = try session.requireSSH() }
                    return result
                }.value
                guard self.esimTargetKey == key else { throw EsimFailure.targetChanged }
                if discovering {
                    self.esimTargets = result.targets ?? []; self.esimDiscoveryComplete = result.complete == true
                    let automatic = EsimValidation.automaticTarget(self.esimTargets, complete: self.esimDiscoveryComplete)
                    self.esimSelectedTarget = automatic?.target; self.esimSnapshot = automatic?.snapshot; self.esimCard = automatic?.card
                    self.esimAllowedOperations = automatic?.operations ?? []; self.esimNetworkSelected = automatic?.networkSelected
                } else {
                    self.esimSnapshot = result.snapshot; self.esimCard = result.card
                    self.esimAllowedOperations = result.operations ?? []; self.esimNetworkSelected = result.networkSelected
                }
                self.esimAuthorization = self.esimCard == nil ? nil : self.esimTargetKey
                if !((result.snapshot?.profiles.contains { $0.iccid == self.esimSelectedICCID }) ?? false) { self.esimSelectedICCID = nil }
                self.esimMessage = self.hasOrdinarySIM ? "Карта не предоставляет eUICC. Управление профилями недоступно." : operation.name == "enable" ? "Профиль активен, SIM перечитана, радио включено. Регистрация в мобильной сети проверяется отдельно." : operation.name == "download" ? "Профиль установлен и выключен. Выберите его для активации." : operation.name == "delete" ? "Профиль удалён. Список перечитан с карты." : "Все профили прочитаны с карты."
                if discovering && self.esimSelectedTarget == nil { self.esimMessage = self.esimCardStatus }
                if result.notificationsPending == true { self.esimMessage += " Уведомления оператору ещё не доставлены." }
                self.progress = 1
                // Only allowlisted metadata and fixed error codes are journaled.
                self.append("Операция eSIM завершена", progress: 1)
            } catch {
                self.esimAuthorization = nil; self.esimTargets = []; self.esimSelectedTarget = nil; self.esimDiscoveryComplete = false; self.esimAllowedOperations = []; self.esimNetworkSelected = nil; self.esimSnapshot = nil; self.esimCard = nil; self.esimSelectedICCID = nil
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
        esimSnapshot = EsimSnapshot(ok: true, target: .removable, eid: "89000000000000000000000000000001", profiles: [
            EsimProfile(iccid: "8900000000000000001", isdpAid: "A0000000000000000000000000000001", state: "enabled", enabled: true, nickname: "Основной", serviceProvider: "Demo Mobile", name: "Рабочий тариф"),
            EsimProfile(iccid: "8900000000000000002", isdpAid: "A0000000000000000000000000000002", state: "disabled", enabled: false, nickname: "Для поездок", serviceProvider: "Demo Travel", name: "Европа")
        ])
        esimMessage = "Демонстрационные данные. Подключение и операции с картой отключены."
        esimAuthorization = nil
    }
}
