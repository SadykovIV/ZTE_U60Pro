import SwiftUI
import AppKit

@MainActor final class AppModel: ObservableObject {
    @Published var host = "192.168.0.1"
    @Published var port = "2222"
    @Published var webPassword = ""
    @Published var skipFirmwareCheck = false
    @Published var backupSuffix = ""
    @Published var setupPending = false
    @Published var keyPath = ""
    @Published var knownHostsPath = ""
    @Published var imei1 = ""
    @Published var imei2 = ""
    @Published var currentIMEI1 = ""
    @Published var currentIMEI2 = ""
    @Published var firmware = ""
    @Published var status = "Подключите модем, чтобы управлять устройством"
    @Published var progress: Double = 0
    @Published var busy = false
    @Published var connected = false
    @Published var log = ""
    @Published var backups: [BackupItem] = []
    @Published var selectedBackupID: String?
    @Published var pendingOperation = false
    @Published var imeiCheckResult = ""
    @Published var sshUsername = ""
    @Published var sshPassword = ""
    @Published var sshPasswordConfirmation = ""
    @Published var sshAccounts: [SSHAccount] = []
    @Published var sshListenerReady = false
    @Published var sshRecoveryPending = false
    @Published var sshRecoveryKind: SSHAccountRecoveryKind = .none
    @Published var sshAccountsLoaded = false
    @Published var applicationInventory: ModemApplicationInventory?
    @Published var modemInformation: ModemInformation?
    @Published var diagnosticExportURL: URL?
    @Published var diagnosticExportSummary = ""
    @Published var diagnosticReport: DiagnosticReport?
    @Published var selectedDiagnostic = "system.log"
    @Published var diagnosticText = ""
    @Published var activityEvents: [ActivityEvent] = []
    @Published var activitySearch = ""
    @Published var journalWarning = ""
    @Published var accessState: AccessManagementState?
    @Published var deviceBackups: [DeviceBackupItem] = []
    @Published var selectedDeviceBackupID: String?
    @Published var deviceBackupKind: DeviceBackupKind = .configuration
    @Published var screenLocalizationStatus: ScreenLocalizationStatus?
    @Published var customAgent: AgentCandidate?
    @Published var agentInstallationStatus: AgentInstallationStatus?
    @Published var vpnInspection: VPNInspection?
    @Published var vpnError = ""
    @Published var ttlStatus: TTLStatus?
    @Published var ttlOutboundEnabled = false
    @Published var ttlOutboundValue = "64"
    @Published var ttlInboundIncrementEnabled = false
    @Published var ttlInboundIncrementValue = "1"
    @Published var packageName = ""
    @Published var packageSearch = ""
    @Published var packagePreview = ""
    @Published var packagePreviewName = ""
    @Published var ssclashPassword = ""
    @Published var ssclashPasswordConfirmation = ""
    let appVersion = DiagnosticsContext.version
    let sessionID = DiagnosticsContext.sessionID
    let storage: URL
    let resources: URL
    var operationTask: Task<Void, Never>?
    var validationMessage: String {
        if imei1.isEmpty && imei2.isEmpty { return "Введите два IMEI или сгенерируйте второй на основе первого" }
        if !IMEI.valid(imei1) { return "IMEI 1: нужны 15 цифр и корректная контрольная сумма Luhn" }
        if !IMEI.valid(imei2) { return "IMEI 2: нужны 15 цифр и корректная контрольная сумма Luhn" }
        if imei1 == imei2 { return "Для двух слотов нужны разные IMEI" }
        if imei1 == currentIMEI1 && imei2 == currentIMEI2 { return "Эта пара уже записана на модеме" }
        return "Оба IMEI корректны по формату и контрольной сумме"
    }
    var canApply: Bool { (connected || !webPassword.isEmpty) && !busy && !pendingOperation && !setupPending && IMEI.valid(imei1) && IMEI.valid(imei2) && imei1 != imei2 && (imei1 != currentIMEI1 || imei2 != currentIMEI2) }
    var canManage: Bool { connected && !busy && !pendingOperation && !setupPending }
    var ttlValidationMessage: String {
        do {
            _ = try TTLConfiguration(outboundEnabled: ttlOutboundEnabled, outboundText: ttlOutboundValue,
                                     inboundIncrementEnabled: ttlInboundIncrementEnabled, inboundIncrementText: ttlInboundIncrementValue)
            return ""
        } catch { return error.localizedDescription }
    }
    var canApplyTTL: Bool {
        guard canManage, let status = ttlStatus,
              let configuration = try? TTLConfiguration(outboundEnabled: ttlOutboundEnabled, outboundText: ttlOutboundValue,
                                                       inboundIncrementEnabled: ttlInboundIncrementEnabled, inboundIncrementText: ttlInboundIncrementValue) else { return false }
        return configuration.isDisabled || status.canApply
    }
    var sshValidation: String {
        do { try SSHAccountManager.validate(username: sshUsername, password: sshPassword) }
        catch { return error.localizedDescription }
        return sshPassword == sshPasswordConfirmation ? "" : "Пароли не совпадают"
    }
    var sshCommand: String {
        let name = sshAccounts.first?.name ?? (sshUsername.isEmpty ? "username" : sshUsername)
        return "ssh -p 2223 \(name)@\(connection.host)"
    }
    var filteredPackages: [ModemPackage] {
        (applicationInventory?.installedPackages ?? []).filter {
            packageSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(packageSearch)
        }
    }
    var ssclashPasswordValid: Bool {
        (8...128).contains(ssclashPassword.utf8.count) &&
        ssclashPassword.utf8.allSatisfy { (33...126).contains($0) } &&
        ssclashPassword == ssclashPasswordConfirmation
    }
    static func bytesLabel(kib: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, min(kib, Int64.max / 1024)) * 1024, countStyle: .decimal)
    }
    init() {
        storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ZTE IMEI Studio")
        resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("MacIMEI/Resources")
        keyPath = storage.appendingPathComponent("SSH/id_ed25519").path
        knownHostsPath = storage.appendingPathComponent("SSH/known_hosts").path
        if let c = try? readJSON(Connection.self, storage.appendingPathComponent("connection.json")) { host = c.host; port = c.port; keyPath = c.keyPath; knownHostsPath = c.knownHostsPath.hasSuffix("/Contents/Resources/trusted_known_hosts") ? storage.appendingPathComponent("SSH/known_hosts").path : c.knownHostsPath }
        refreshBackups()
        do {
            try ActivityJournal(root: storage).record(operationID: sessionID, category: "session", title: "Запуск приложения", result: "started", details: ["macOS": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": "arm64", "endpoint": host + ":" + port])
        } catch { journalWarning = "Журнал недоступен: " + error.localizedDescription }
        refreshActivity()
        if pendingOperation { status = "Есть незавершённая операция. Подключите тот же модем и нажмите «Продолжить»." }
    }
    var connection: Connection { Connection(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, keyPath: keyPath, knownHostsPath: knownHostsPath, skipFirmwareCheck: skipFirmwareCheck) }
    func setFirmwareCheckSkipped(_ enabled: Bool) {
        guard !busy, enabled != skipFirmwareCheck else { return }
        skipFirmwareCheck = enabled
        connected = false; agentInstallationStatus = nil; modemInformation = nil; applicationInventory = nil; accessState = nil
        currentIMEI1 = ""; currentIMEI2 = ""; firmware = ""; screenLocalizationStatus = nil; ttlStatus = nil; vpnInspection = nil; vpnError = ""
        sshAccountsLoaded = false; sshAccounts = []
        append(enabled ? FirmwareCheck.warning : "Проверка прошивки включена. Подключитесь заново.")
    }
    func append(_ message: String, progress value: Double? = nil) {
        let date = DateFormatter(); date.dateFormat = "HH:mm:ss"
        let safe = ActivityJournal.redact(message)
        log += "[\(date.string(from: Date()))] \(safe)\n"
        if log.count > 200_000 { log = "[Ранние сообщения доступны в постоянном журнале]\n" + String(log.suffix(180_000)) }
        status = safe
        do { try ActivityJournal(root: storage).record(operationID: sessionID, category: "application", title: safe,
                                                       result: safe.hasPrefix("Остановлено") ? "failed" : value.map { $0 >= 1 ? "completed" : "progress" } ?? "message",
                                                       details: value.map { ["progress":String($0)] } ?? [:]) }
        catch { journalWarning = "Не удалось сохранить часть журнала: " + error.localizedDescription }
        if let value { progress = value }
    }
    func accept(_ state: DeviceState) {
        currentIMEI1 = state.imeis[0]; currentIMEI2 = state.imeis[1]
        firmware = state.identity.firmwareHash == ModemEngine.firmwareHash ? "CN_ZTE_MU5250V1.0.0B31" : "Непроверенная прошивка"; connected = true
    }
    func perform(_ work: @escaping @Sendable (ModemEngine) throws -> DeviceState?) {
        guard !busy else { return }
        let config = connection
        do { try config.validate(); try secureDirectory(storage); try saveJSON(config, storage.appendingPathComponent("connection.json")) }
        catch { append(error.localizedDescription); return }
        busy = true; progress = 0; imeiCheckResult = ""
        let root = storage, assets = resources
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> DeviceState? in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try work(engine) }
                }.value
                if let state { accept(state) }
            } catch {
                append("Остановлено: " + error.localizedDescription)
                connected = false
            }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func connect() { connect(readIMEIOnly: false) }
    func readIMEI() { connect(readIMEIOnly: true) }
    private func connect(readIMEIOnly: Bool) {
        if !readIMEIOnly && !webPassword.isEmpty { setup(); return }
        guard !busy else { return }
        let config = connection, root = storage, assets = resources
        do { try config.validate(); try secureDirectory(storage); try saveJSON(config, storage.appendingPathComponent("connection.json")) }
        catch { append(error.localizedDescription); return }
        busy = true; progress = 0; modemInformation = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] text, progress in
                        Task { @MainActor [weak self] in self?.append(text, progress: progress) }
                    }
                    return try engine.locked { try engine.inspect() }
                }.value
                accept(state)
            } catch { connected = false; append("Остановлено: " + error.localizedDescription) }
            busy = false; refreshBackups(); operationTask = nil
            if connected { refreshModemInformation() }
        }
    }
    func setup(targets: [String]? = nil) {
        guard !busy else { return }
        guard !webPassword.isEmpty else { append("Введите пароль веб-интерфейса для первоначальной настройки"); return }
        guard !backupSuffix.isEmpty else { append("Введите ключ расшифровки бэкапа (backup-key suffix)"); return }
        let password = webPassword, suffix = backupSuffix; webPassword = ""; backupSuffix = ""
        let config = connection, root = storage, assets = resources
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let installer = try OnboardingEngine(root: root, resources: assets, connection: config, update: { [weak self] message,value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    })
                    return try installer.run(password: password, backupSuffix: suffix)
                }.value
                keyPath = result.connection.keyPath; knownHostsPath = result.connection.knownHostsPath; port = result.connection.port
                try saveJSON(result.connection, root.appendingPathComponent("connection.json"))
                accept(result.state)
                if let targets, targets != result.state.imeis {
                    let connection = result.connection
                    let state = try await Task.detached(priority: .userInitiated) { [weak self] in
                        let engine = try ModemEngine(root: root, resources: assets, connection: connection) { [weak self] message,value in
                            Task { @MainActor [weak self] in self?.append(message, progress: value) }
                        }
                        return try engine.locked { try engine.begin(targets: targets) }
                    }.value
                    accept(state)
                }
            } catch { connected = false; append("Остановлено: " + error.localizedDescription) }
            busy = false; refreshBackups(); operationTask = nil
            if connected { refreshModemInformation() }
        }
    }
    func backup() { perform { engine in let state = try engine.inspect(); _ = try engine.makeBackup(state); engine.update("Бэкап сохранён; контрольные суммы совпали.", 1); return state } }
    func apply() {
        guard canApply else { return }
        let targets = [imei1, imei2]
        if !connected { setup(targets: targets); return }
        perform { try $0.begin(targets: targets) }
    }
    func restore() {
        guard !pendingOperation && !setupPending, let item = backups.first(where: { $0.id == selectedBackupID }) else { return }
        perform { try $0.begin(targets: nil, restore: item.url) }
    }
    func resume() { guard pendingOperation else { return }; perform { try $0.resume() } }
    func refreshSSHAccounts() { manageSSH(username: nil, password: nil) }
    func createSSHAccount() {
        guard canManage && !sshRecoveryPending else { return }
        guard sshValidation.isEmpty else { append(sshValidation); return }
        let password = sshPassword
        sshPassword = ""; sshPasswordConfirmation = ""
        manageSSH(username: sshUsername, password: password)
    }
    private func manageSSH(username: String?, password: String?) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let manager = try SSHAccountManager(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    if let username, let password { return try manager.create(username: username, password: password) }
                    return try manager.inspect()
                }.value
                sshAccounts = result.accounts; sshListenerReady = result.listenerReady
                sshRecoveryPending = result.recoveryPending; sshRecoveryKind = result.recoveryKind; sshAccountsLoaded = true
                if username == nil { append("Список SSH-пользователей обновлён", progress: 1) }
            } catch { append("SSH: " + error.localizedDescription) }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func refreshApplications() { manageApplications(action: "inventory") }
    func previewPackage() { manageApplications(action: "preview", package: packageName.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func installPackage() {
        let name = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard packagePreviewName == name && applicationInventory?.opkgWritable == true else { return }
        manageApplications(action: "package", package: name)
    }
    func installSSClash() {
        guard canManage && ssclashPasswordValid else { return }
        let password = ssclashPassword
        ssclashPassword = ""; ssclashPasswordConfirmation = ""
        manageApplications(action: "ssclash", password: password)
    }
    func startSSClash() { manageApplications(action: "start-ssclash") }
    func openSSClash() {
        guard applicationInventory?.ssclashRunning == true,
              (try? connection.validate()) != nil,
              let url = URL(string: "http://\(connection.host):9091") else { return }
        NSWorkspace.shared.open(url)
    }
    private func manageApplications(action: String, package: String = "", password: String = "") {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources
        busy = true; progress = 0
        if action == "preview" { packagePreview = ""; packagePreviewName = "" }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> (ModemApplicationInventory, String) in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        for file in ["pending.json", "setup-pending.json"] {
                            try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), "Сначала завершите настройку или смену IMEI")
                        }
                        _ = try engine.identity()
                        if ["package", "ssclash", "start-ssclash"].contains(action) { try engine.acquireRemoteLock() }
                        let manager = ModemApplications(engine: engine)
                        let message: String
                        switch action {
                        case "preview": message = try manager.previewPackage(package)
                        case "package": message = try manager.installPackage(package)
                        case "ssclash": message = try manager.installSSClash(password: password)
                        case "start-ssclash": message = try manager.startSSClash()
                        default: message = "Список приложений и место для установки обновлены"
                        }
                        return (try manager.inventory(), message)
                    }
                }.value
                applicationInventory = result.0
                if action == "preview" { packagePreview = result.1; packagePreviewName = package; append("Результат проверки пакета получен", progress: 1) }
                else { append(result.1, progress: 1) }
            } catch { append("Приложения: " + error.localizedDescription) }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func refreshScreenLocalization() { manageScreenLocalization(.status) }
    func enableScreenLocalization() { manageScreenLocalization(.enable) }
    func disableScreenLocalization() { manageScreenLocalization(.disable) }
    private func manageScreenLocalization(_ action: ScreenLocalizationAction) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try ScreenLocalization(engine: engine).perform(action) }
                }.value
                screenLocalizationStatus = result
                append(result.summary, progress: 1)
            } catch {
                screenLocalizationStatus = ScreenLocalizationStatus(state: .error, language: "other", detail: error.localizedDescription)
                append("Русификация: " + error.localizedDescription)
            }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func refreshTTLSettings() { manageTTLSettings(configuration: nil) }
    func applyTTLSettings() {
        guard canApplyTTL else { return }
        do {
            let configuration = try TTLConfiguration(outboundEnabled: ttlOutboundEnabled, outboundText: ttlOutboundValue,
                                                     inboundIncrementEnabled: ttlInboundIncrementEnabled, inboundIncrementText: ttlInboundIncrementValue)
            manageTTLSettings(configuration: configuration)
        } catch { append("TTL: " + error.localizedDescription) }
    }
    private func manageTTLSettings(configuration: TTLConfiguration?) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try TTLSettingsManager(engine: engine).perform(configuration: configuration) }
                }.value
                ttlStatus = result
                if result.state != .error && result.state != .unsupported {
                    ttlOutboundEnabled = result.configuration.outbound != nil
                    ttlInboundIncrementEnabled = result.configuration.inboundIncrement != nil
                    if let value = result.configuration.outbound { ttlOutboundValue = String(value) }
                    if let value = result.configuration.inboundIncrement { ttlInboundIncrementValue = String(value) }
                }
                append(result.summary, progress: 1)
            } catch {
                // Preserve the user's draft when an operation or its acknowledgement fails.
                ttlStatus = TTLStatus(state: .error, configuration: ttlStatus?.configuration ?? .disabled,
                                      capability: .unknown, detail: error.localizedDescription)
                append("TTL: " + error.localizedDescription)
            }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func generateSecond() {
        do { imei2 = try IMEI.second(imei1); checkIMEI() } catch { imeiCheckResult = error.localizedDescription }
    }
    func checkIMEI() {
        var lines: [String] = []
        for (i, number) in [imei1, imei2].enumerated() {
            if IMEI.valid(number) {
                lines.append("IMEI \(i+1): корректен · TAC \(number.prefix(8)) · serial \(number.dropFirst(8).prefix(6)) · контрольная цифра \(number.suffix(1))")
            } else { lines.append("IMEI \(i+1): неверный формат или контрольная сумма Luhn") }
        }
        if !imei1.isEmpty && imei1 == imei2 { lines.append("Ошибка: номера двух слотов совпадают") }
        lines.append("Проверка локальная. Выделение номера, модель по TAC и чёрные списки операторов не проверяются.")
        imeiCheckResult = lines.joined(separator: "\n")
    }
    func refreshBackups() {
        setupPending = FileManager.default.fileExists(atPath: storage.appendingPathComponent("setup-pending.json").path)
        pendingOperation = FileManager.default.fileExists(atPath: storage.appendingPathComponent("pending.json").path)
        let dir = storage.appendingPathComponent("Backups")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        backups = urls.compactMap { url in
            guard let m = try? readJSON(BackupManifest.self, url.appendingPathComponent("manifest.json")), m.imeis.count == 2 else { return nil }
            return BackupItem(id: m.id, date: m.created, imei1: m.imeis[0], imei2: m.imeis[1], url: url)
        }.sorted { $0.date > $1.date }
        if selectedBackupID == nil || !backups.contains(where: { $0.id == selectedBackupID }) { selectedBackupID = backups.first?.id }
    }
    func revealBackups() { try? secureDirectory(storage.appendingPathComponent("Backups")); NSWorkspace.shared.open(storage.appendingPathComponent("Backups")) }
    func chooseKey() { let p = NSOpenPanel(); p.title = "Закрытый SSH-ключ установленного агента"; p.canChooseDirectories = false; p.showsHiddenFiles = true; if p.runModal() == .OK, let url = p.url { keyPath = url.path } }
    func chooseKnownHosts() { let p = NSOpenPanel(); p.title = "Файл с проверенным ключом SSH-сервера модема"; p.canChooseDirectories = false; p.showsHiddenFiles = true; if p.runModal() == .OK, let url = p.url { knownHostsPath = url.path } }
    func importBackup() {
        guard !busy && !pendingOperation else { return }
        let p = NSOpenPanel(); p.title = "Папка бэкапа приложения или исходного IMEI-бэкапа проекта"; p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let url = p.url { perform { engine in _ = try engine.importBackup(url); engine.update("Бэкап импортирован и проверен.", 1); return nil } }
    }
}
