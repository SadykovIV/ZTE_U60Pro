import Foundation
import AppKit

@MainActor extension AppModel {
    func runManaged<T: Sendable>(_ title: String, readOnly: Bool = false, usesSelectedChannel: Bool = false, work: @escaping @Sendable (ModemEngine) throws -> T,
                                 finish: @escaping @MainActor (T) -> Void) {
        let diagnosticTransport = readOnly && usesSelectedChannel
        guard diagnosticTransport ? canCollectDiagnostics : (readOnly ? canReadModem : canManage) else { return }
        if !readOnly && SystemBackups.hasPendingRestore(root: storage) {
            systemRestorePending = true
            append("Сначала завершите восстановление полного образа модема")
            return
        }
        let config = connection, root = storage, assets = resources
        let target = sshSelectionContext
        do { if !diagnosticTransport { try config.validate() } } catch { append("Остановлено: " + error.localizedDescription); return }
        busy = true; progress = 0
        append(title)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    let journal = try ActivityJournal(root: root)
                    try journal.record(operationID: engine.logDirectory.lastPathComponent, category: "operation", title: title, result: "started")
                    do {
                        if !diagnosticTransport { try target.verify(engine) }
                        let result = try work(engine)
                        try? journal.record(operationID: engine.logDirectory.lastPathComponent, category: "operation", title: title, result: "completed")
                        return result
                    } catch {
                        try? journal.record(operationID: engine.logDirectory.lastPathComponent, category: "operation", title: title, result: "failed", details: ["error":error.localizedDescription])
                        throw error
                    }
                }.value
                finish(value)
                progress = 1
            } catch { append("Остановлено: " + error.localizedDescription) }
            busy = false; refreshBackups(); refreshDeviceBackups(); refreshActivity(); operationTask = nil
        }
    }
    func refreshModemInformation() {
        refreshChannelInformation()
    }
    func collectDiagnostics() {
        let expected = modemInformation?.identity ?? connectedIdentity
        let mode = activeChannel ?? connectionMode, session = channelSession, expectedWeb = connectedWebIdentity ?? channelSummary?.webIdentity
        let expectedIMEI = connectedIMEI ?? channelSummary?.primaryIMEI
        let webSecret = webPassword, agentSecret = agentPassword
        runManaged("Собираю диагностическую информацию…", readOnly: true, usesSelectedChannel: true, work: { engine in
            try engine.locked { try ConnectionDiagnostics.collect(engine: engine, mode: mode, session: session,
                expectedIdentity: expected, expectedWebIdentity: expectedWeb, expectedIMEI: expectedIMEI, webPassword: webSecret, agentPassword: agentSecret) }
        }, finish: { [weak self] report in
            self?.diagnosticReport = report; self?.selectedDiagnostic = report.files.first?.name ?? ""
            self?.loadDiagnosticText(); self?.append("Диагностика сохранена. " + report.outcomeSummary)
        })
    }
    func loadDiagnosticText() {
        guard let report = diagnosticReport, report.files.contains(where: { $0.name == selectedDiagnostic }) else { diagnosticText = ""; return }
        diagnosticText = (try? String(contentsOf: report.url.appendingPathComponent(selectedDiagnostic), encoding: .utf8)) ?? "Не удалось прочитать файл диагностики"
    }
    func revealDiagnostics() { if let report = diagnosticReport { NSWorkspace.shared.open(report.url) } }
    func refreshActivity() {
        activityEvents = (try? ActivityJournal(root: storage).recent()) ?? []
        if FileManager.default.fileExists(atPath: storage.appendingPathComponent("Activity/incomplete.txt").path) {
            journalWarning = "Для одной из операций не удалось дописать результат в журнал. Подробности в папке журналов."
        }
    }
    var filteredActivity: [ActivityEvent] {
        activityEvents.filter { activitySearch.isEmpty || ($0.title + " " + $0.category + " " + $0.operationID + " " + $0.details.description).localizedCaseInsensitiveContains(activitySearch) }
    }
    func revealActivity() { if let journal = try? ActivityJournal(root: storage) { NSWorkspace.shared.open(journal.directory) } }
    func revealOperationLogs() {
        let directory = storage.appendingPathComponent("Activity/Traces")
        try? secureDirectory(directory); NSWorkspace.shared.open(directory)
    }
    func refreshDeviceBackups() {
        do { deviceBackups = try DeviceBackups.list(root: storage) }
        catch { append("Не удалось прочитать список бэкапов: " + error.localizedDescription) }
        if selectedDeviceBackupID == nil || !deviceBackups.contains(where: { $0.id == selectedDeviceBackupID }) { selectedDeviceBackupID = deviceBackups.first?.id }
    }
    func createDeviceBackup() {
        let kind = deviceBackupKind
        runManaged("Создаю бэкап: " + kind.title, work: { engine in
            try engine.locked { try DeviceBackups(engine: engine).create(kind) }
        }, finish: { [weak self] item in
            self?.selectedDeviceBackupID = item.id; self?.append("Бэкап создан, размер и SHA256 проверены")
        })
    }
    func verifyDeviceBackup() {
        guard !busy, let item = deviceBackups.first(where: { $0.id == selectedDeviceBackupID }) else { return }
        busy = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await Task.detached { try DeviceBackups.verify(item) }.value; append("Файлы бэкапа целы: контрольные суммы совпадают", progress: 1) }
            catch { append("Бэкап: " + error.localizedDescription) }
            busy = false; refreshActivity(); operationTask = nil
        }
    }
    func exportDeviceBackup() {
        guard !busy, let item = deviceBackups.first(where: { $0.id == selectedDeviceBackupID }) else { return }
        let panel = NSOpenPanel(); panel.title = "Куда сохранить копию бэкапа"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached { try DeviceBackups.export(item, to: destination) }.value
                append("Бэкап экспортирован и проверен", progress: 1); NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch { append("Экспорт: " + error.localizedDescription) }
            busy = false; refreshActivity(); operationTask = nil
        }
    }
    func revealDeviceBackups() {
        let directory = storage.appendingPathComponent("DeviceBackups")
        try? secureDirectory(directory); NSWorkspace.shared.open(directory)
    }
    func refreshAccess() {
        runManaged("Проверяю службы и доступы…", work: { engine in
            try AccessManager(root: engine.root, resources: engine.resources, connection: engine.connection).inspect()
        }, finish: { [weak self] value in
            self?.acceptAccess(value); self?.append("Статус доступов обновлён")
        })
    }
    func acceptAccess(_ value: AccessManagementState) {
        accessState = value; sshAccounts = value.sshAccounts.accounts
        sshListenerReady = value.sshAccounts.listenerReady; sshRecoveryPending = value.sshAccounts.recoveryPending; sshRecoveryKind = value.sshAccounts.recoveryKind; sshAccountsLoaded = true
    }
    func changeService(_ service: AccessServiceID, action: AccessServiceAction) {
        let title = action.title + ": " + (accessState?.services.first { $0.id == service }?.title ?? service.rawValue)
        runManaged(title, work: { engine in
            try AccessManager(root: engine.root, resources: engine.resources, connection: engine.connection).perform(service: service, action: action)
        }, finish: { [weak self] value in self?.acceptAccess(value); self?.append("Состояние службы проверено") })
    }
    func recoverSSHDeletion() {
        guard sshRecoveryPending && sshRecoveryKind == .delete else { return }
        runManaged("Восстанавливаю прерванное удаление SSH-пользователя…", work: { engine in
            try SSHAccountManager(root: engine.root, resources: engine.resources, connection: engine.connection).recoverDeletion()
        }, finish: { [weak self] value in
            self?.sshAccounts = value.accounts; self?.sshListenerReady = value.listenerReady
            self?.sshRecoveryPending = value.recoveryPending; self?.sshRecoveryKind = value.recoveryKind
            self?.append("Восстановление прерванного удаления завершено")
        })
    }
    func deleteSSHAccount(_ username: String) {
        guard canManage else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("Удалить SSH-пользователя \(username)?")
        alert.informativeText = L10n.text("Вход этого пользователя будет отключён. Перед удалением приложение сохранит настройки и домашний каталог для восстановления. Служебный доступ приложения останется включённым.")
        alert.addButton(withTitle: L10n.text("Удалить пользователя")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runManaged("Удаляю SSH-пользователя \(username)…", work: { engine in
            try SSHAccountManager(root: engine.root, resources: engine.resources, connection: engine.connection).delete(username: username)
        }, finish: { [weak self] value in self?.sshAccounts = value.accounts; self?.sshListenerReady = value.listenerReady; self?.sshRecoveryPending = value.recoveryPending; self?.sshRecoveryKind = value.recoveryKind; self?.append("SSH-пользователь удалён; резервная копия сохранена") })
    }
    func removeSSClash() {
        guard canManage else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("Удалить SSClash-Go с модема?")
        alert.informativeText = L10n.text("Приложение остановит принадлежащую ему службу и сохранит архив с настройками перед удалением. Активная маршрутизация прокси должна быть выключена в SSClash.")
        alert.addButton(withTitle: L10n.text("Удалить приложение")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runManaged("Удаляю SSClash-Go с сохранением копии…", work: { engine in
            try engine.locked {
                _ = try engine.identity(); try engine.acquireRemoteLock()
                let manager = ModemApplications(engine: engine)
                let message = try manager.removeSSClash()
                return (try manager.inventory(), message)
            }
        }, finish: { [weak self] value in self?.applicationInventory = value.0; self?.append(value.1) })
    }
}
