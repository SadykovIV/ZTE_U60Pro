import Foundation

@MainActor extension AppModel {
    var esimTargetKey: String {
        [host, port, keyPath, knownHostsPath, channelSession?.summary.bootID ?? "", activeChannel?.rawValue ?? ""].joined(separator: "\n")
    }
    var canReadEsim: Bool { canReadModem && !esimPreview }
    var canWriteEsim: Bool { canReadEsim && esimAuthorization == esimTargetKey && esimSnapshot?.writeReady == true }
    var hasOrdinarySIM: Bool { esimCard?.kind == "ordinary_sim" && esimAuthorization == esimTargetKey }
    var esimCardStatus: String {
        if esimOperationActive { return "Тип SIM-карты: проверка…" }
        if hasOrdinarySIM { return "Вставлена обычная SIM-карта оператора. Установка профилей eSIM недоступна." }
        if esimSnapshot != nil && esimAuthorization == esimTargetKey { return "Тип SIM-карты: физическая eUICC подтверждена." }
        if !esimError.isEmpty { return "Тип SIM-карты определить не удалось. Ошибка чтения не означает, что карта обычная." }
        return "Тип SIM-карты ещё не проверен. Нажмите «Проверить карту и профили»."
    }
    func clearEsim() { esimSnapshot = nil; esimCard = nil; esimAuthorization = nil; esimSelectedICCID = nil; esimMessage = ""; esimError = "" }
    func performEsim(_ operation: EsimOperation) {
        guard operation.mutates ? canWriteEsim : canReadEsim else { return }
        let before = esimSnapshot, config = connection, session = channelSession, key = esimTargetKey
        let assets = resources, logID = UUID()
        do { _ = try operation.request(snapshot: before); try config.validate() }
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
                    let result = try EsimService(connection: config, resources: assets).perform(operation, expected: before, journal: journal, progress: report)
                    if let session { _ = try session.requireSSH() }
                    return result
                }.value
                guard self.esimTargetKey == key else { throw EsimFailure.targetChanged }
                self.esimSnapshot = result.snapshot; self.esimCard = result.card; self.esimAuthorization = key
                if !((result.snapshot?.profiles.contains { $0.iccid == self.esimSelectedICCID }) ?? false) { self.esimSelectedICCID = nil }
                self.esimMessage = self.hasOrdinarySIM ? "Вставлена обычная SIM-карта оператора. Установка профилей eSIM недоступна." : operation.name == "enable" ? "Профиль активен, SIM перечитана, радио включено. Регистрация в мобильной сети проверяется отдельно." : operation.name == "download" ? "Профиль установлен и выключен. Выберите его для активации." : operation.name == "delete" ? "Профиль удалён. Список перечитан с карты." : "Все профили прочитаны с карты."
                if result.notificationsPending == true { self.esimMessage += " Уведомления оператору ещё не доставлены." }
                self.progress = 1
                // Only allowlisted metadata and fixed error codes are journaled.
                self.append("Операция eSIM завершена", progress: 1)
            } catch {
                self.esimAuthorization = nil; self.esimSnapshot = nil; self.esimCard = nil; self.esimSelectedICCID = nil
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
