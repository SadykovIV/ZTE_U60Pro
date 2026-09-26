import Foundation
import AppKit

final class SystemBackupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    func cancel() { lock.lock(); requested = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

@MainActor extension AppModel {
    var selectedSystemBackup: SystemBackupItem? {
        systemBackups.first { $0.id == selectedSystemBackupID }
    }
    var canUseSystemBackupConnection: Bool {
        // RAM recovery cannot pass the normal running-firmware connection probe.
        // The restore service verifies recovery environment and CID itself.
        !busy && !terminalActive && permitsSSHOperations && !host.isEmpty && !keyPath.isEmpty && !knownHostsPath.isEmpty && !pendingOperation && !setupPending
    }
    var canExecuteSystemRestore: Bool {
        guard !busy, !terminalActive, permitsSSHOperations, let plan = systemRestorePlan, plan.canRestore,
              plan.backup.id == selectedSystemBackupID else { return false }
        return systemRestoreConfirmation == "ВОССТАНОВИТЬ " + String(plan.inventory.cid.suffix(8)) &&
            (!plan.requiresLiveCaptureAcknowledgement || systemAllowLiveCapture)
    }
    func refreshSystemBackups() {
        systemRestorePending = SystemBackups.hasPendingRestore(root: storage)
        do {
            systemBackups = try SystemBackups.list(root: storage) { [weak self] id, reason in
                self?.append("Полный образ \(id) исключён из списка: " + reason)
            }
        }
        catch { systemBackups = []; append("Полные образы: " + error.localizedDescription) }
        if !systemBackups.contains(where: { $0.id == selectedSystemBackupID }) {
            selectSystemBackup(systemBackups.first?.id)
        }
    }
    func selectSystemBackup(_ id: String?) {
        selectedSystemBackupID = id
        systemRestorePlan = nil; systemRestoreConfirmation = ""; systemAllowLiveCapture = false
    }
    // Recovery has its own identity/idle-device checks. Normal inspect() depends
    // on files and services which must not be mounted/running during raw restore.
    func runSystemBackupOperation<T: Sendable>(_ title: String,
        work: @escaping @Sendable (ModemEngine) throws -> T,
        finish: @escaping @MainActor (T) -> Void) {
        guard canUseSystemBackupConnection else { return }
        let config = connection, root = storage, assets = resources
        do { try config.validate() } catch {
            systemBackupCanCancel = false; systemBackupCancellation = nil
            append(error.localizedDescription); return
        }
        busy = true; progress = 0; append(title)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try work(engine) }
                }.value
                finish(result); progress = 1
            } catch { append("Полный образ: " + error.localizedDescription) }
            systemBackupCanCancel = false; systemBackupCancellation = nil
            busy = false; refreshSystemBackups(); refreshActivity(); operationTask = nil
        }
    }
    func createSystemBackup() {
        guard canUseSystemBackupConnection && !systemRestorePending else { return }
        let cancellation = SystemBackupCancellation()
        systemBackupCancellation = cancellation; systemBackupCanCancel = true
        runSystemBackupOperation("Сохраняю полный образ накопителя…", work: {
            try SystemBackups(engine: $0).create(cancelled: { cancellation.isCancelled() })
        }, finish: { [weak self] item in
            self?.selectSystemBackup(item.id)
            self?.append("Полный образ сохранён на Mac; размер и SHA256 проверены")
        })
    }
    func cancelSystemBackup() {
        guard systemBackupCanCancel else { return }
        systemBackupCancellation?.cancel(); systemBackupCanCancel = false
        append("Останавливаю чтение полного образа; незавершённая копия будет удалена")
    }
    func prepareSystemRestore() {
        guard let item = selectedSystemBackup else { return }
        systemRestorePlan = nil; systemRestoreConfirmation = ""; systemAllowLiveCapture = false
        runSystemBackupOperation("Проверяю образ и условия восстановления…", work: {
            try SystemBackups(engine: $0).prepareRestore(item)
        }, finish: { [weak self] plan in
            self?.systemRestorePlan = plan
            self?.append(plan.canRestore ? "План восстановления готов к проверке" : "Для записи нужна среда восстановления: " + plan.inventory.offlineExplanation)
        })
    }
    func executeSystemRestore() {
        guard canExecuteSystemRestore, let plan = systemRestorePlan else { return }
        let allowLive = systemAllowLiveCapture
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text(plan.isResume ? "Продолжить восстановление модема?" : "Восстановить полный образ модема?")
        alert.informativeText = L10n.text("Модем CID …\(plan.inventory.cid.suffix(8)). Образ от \(plan.backup.created), \(ByteCountFormatter.string(fromByteCount: plan.backup.bytes, countStyle: .file)). Содержимое основной и загрузочных областей eMMC будет заменено. Перед первой записью сохраняется текущий полный образ. После начала записи не отключайте питание.")
        alert.addButton(withTitle: L10n.text(plan.isResume ? "Продолжить восстановление" : "Восстановить"))
        alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        systemRestoreConfirmation = ""
        runSystemBackupOperation(plan.isResume ? "Продолжаю восстановление образа…" : "Сохраняю текущее состояние перед восстановлением…", work: {
            try SystemBackups(engine: $0).restore(plan, allowLiveCapture: allowLive)
        }, finish: { [weak self] result in
            self?.systemRestorePlan = nil
            self?.connected = false
            self?.accessReady = false; self?.connectedIdentity = nil; self?.connectedWebIdentity = nil; self?.connectedIMEI = nil; self?.modemInformation = nil
            self?.channelSession = nil; self?.channelSummary = nil; self?.activeChannel = nil; self?.channelStatuses = []
            self?.append("Восстановление завершено и проверено. Предыдущий образ: \(result.beforeBackupID). Перезагрузка автоматически не выполнялась.")
        })
    }
    func verifySystemBackup() {
        guard let item = selectedSystemBackup else { return }
        runLocalSystemBackupOperation("Проверяю полный образ…", work: {
            _ = try SystemBackups.verify(item)
        }, finish: { [weak self] _ in self?.append("Все файлы полного образа прошли проверку SHA256", progress: 1) })
    }
    func importSystemBackup() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Папка полного образа с manifest.json"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = storage
        runLocalSystemBackupOperation("Проверяю и импортирую полный образ…", work: {
            try SystemBackups.importBackup(from: url, root: root)
        }, finish: { [weak self] item in self?.selectSystemBackup(item.id); self?.append("Полный образ импортирован и проверен") })
    }
    func exportSystemBackup() {
        guard !busy, let item = selectedSystemBackup else { return }
        let panel = NSOpenPanel(); panel.title = "Куда экспортировать полный образ"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        runLocalSystemBackupOperation("Экспортирую полный образ…", work: {
            try SystemBackups.export(item, to: directory)
        }, finish: { [weak self] url in
            self?.append("Экспортированная копия проверена")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
    }
    private func runLocalSystemBackupOperation<T: Sendable>(_ title: String,
        work: @escaping @Sendable () throws -> T, finish: @escaping @MainActor (T) -> Void) {
        guard !busy else { return }
        busy = true; progress = 0; append(title)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do { let result = try await Task.detached(priority: .userInitiated, operation: work).value; finish(result); progress = 1 }
            catch { append("Полный образ: " + error.localizedDescription) }
            busy = false; refreshSystemBackups(); refreshActivity(); operationTask = nil
        }
    }
    func revealSystemBackups() {
        let url = storage.appendingPathComponent("SystemBackups")
        try? secureDirectory(url); NSWorkspace.shared.open(url)
    }
}
