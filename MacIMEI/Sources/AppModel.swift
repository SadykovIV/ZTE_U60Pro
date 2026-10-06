import SwiftUI
import AppKit

@MainActor final class AppModel: ObservableObject {
    @Published var host = "192.168.0.1"
    @Published var port = "2222"
    @Published var webPassword = "" {
        didSet { if oldValue != webPassword { connectionPasswordChanged(.web) } }
    }
    @Published var agentPassword = "" {
        didSet { if oldValue != agentPassword { connectionPasswordChanged(.agent) } }
    }
    @Published var connectionMode: ConnectionMode = .automatic
    @Published var channelStatuses: [ConnectionChannelStatus] = []
    @Published var activeChannel: ConnectionMode?
    @Published var channelSummary: ConnectionDeviceSummary?
    @Published var connectionReason = ""
    @Published var connectionsChecked = false
    @Published var preparationError = ""
    @Published var diagnosticADBMessage = ""
    @Published var diagnosticADBPending = false
    @Published var adbControlStatus: ADBControlStatus?
    @Published var adbTogglePending = false
    @Published var sectionRefreshErrors: [ConnectionOverviewSection: String] = [:]
    @Published var sectionsUpdatedAt: Date?
    var channelSession: ReadOnlyChannelSession?
    @Published var skipFirmwareCheck = false
    @Published var backupSuffix = ""
    @Published var forcePreparation = false { didSet { if !forcePreparation { cleanPreparationComponents = false } } }
    @Published var cleanPreparationComponents = false { didSet { if cleanPreparationComponents { forcePreparation = true } } }
    @Published var setupPending = false
    @Published var componentCleanupPending = false
    @Published var componentCleanupCanCancel = false
    @Published var keyPath = ""
    @Published var knownHostsPath = ""
    @Published var imei1 = ""
    @Published var imei2 = ""
    @Published var currentIMEI1 = ""
    @Published var currentIMEI2 = ""
    @Published var firmware = ""
    @Published var status = "Подключите модем, чтобы управлять устройством"
    @Published var progress: Double = 0
    @Published var busy = false {
        didSet { if busy != oldValue { connectionActivityGeneration &+= 1 } }
    }
    var connectionActivityGeneration: UInt64 = 0
    @Published var connected = false
    @Published var accessReady = false
    var connectedIdentity: Identity?
    var connectedReadCID: String?
    var connectedWebIdentity: WebIdentity?
    var connectedIMEI: String?
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
    @Published var applicationsError = ""
    @Published var experimentalOpkgStatus: ExperimentalOpkgStatus?
    @Published var experimentalOpkgError = ""
    let terminalSession = ModemTerminalSession()
    @Published var terminalActive = false
    @Published var terminalError = ""
    @Published var opkgFeeds: ExperimentalOpkgFeeds?
    @Published var opkgFeedsDraft = ""
    @Published var opkgFeedsMessage = ""
    @Published var opkgCommand = ""
    @Published var opkgTranscript = ""
    @Published var opkgHistory: [String] = []
    @Published var modemInformation: ModemInformation?
    @Published var diagnosticExportURL: URL?
    @Published var diagnosticExportSummary = ""
    @Published var firmwareSupportExportURL: URL?
    @Published var firmwareSupportExportSummary = ""
    @Published var diagnosticReport: DiagnosticReport?
    @Published var selectedDiagnostic = "system.log"
    @Published var diagnosticText = ""
    @Published var firmwareResearchReport: FirmwareResearchReport?
    @Published var firmwareResearchRunning = false
    @Published var firmwareResearchProgress: Double = 0
    @Published var firmwareResearchMessage = ""
    @Published var firmwareResearchExportURL: URL?
    var firmwareResearchCancellation: ResearchCancellation?
    var firmwareResearchLoaded = false
    @Published var activityEvents: [ActivityEvent] = []
    @Published var activitySearch = ""
    @Published var journalWarning = ""
    @Published var accessState: AccessManagementState?
    @Published var deviceBackups: [DeviceBackupItem] = []
    @Published var selectedDeviceBackupID: String?
    @Published var deviceBackupKind: DeviceBackupKind = .configuration
    @Published var systemBackups: [SystemBackupItem] = []
    @Published var selectedSystemBackupID: String?
    @Published var systemRestorePlan: SystemRestorePlan?
    @Published var systemRestoreConfirmation = ""
    @Published var systemAllowLiveCapture = false
    @Published var systemRestorePending = false
    @Published var systemBackupCanCancel = false
    var systemBackupCancellation: SystemBackupCancellation?
    @Published var screenLocalizationStatus: ScreenLocalizationStatus?
    @Published var customAgent: AgentCandidate?
    @Published var agentInstallationStatus: AgentInstallationStatus?
    @Published var displayInspection: ModemDisplayInspection?
    @Published var displayError = ""
    @Published var esimSnapshot: EsimSnapshot?
    @Published var esimCard: EsimCardCheck?
    @Published var esimSelectedICCID: String?
    @Published var esimMessage = ""
    @Published var esimError = ""
    @Published var esimPreview = false
    @Published var esimOperationActive = false
    var esimAuthorization: String?
    var esimLogID: UUID?
    @Published var displayLayout: ModemDisplayLayout = .defaultLayout
    @Published var displaySavedLayout: ModemDisplayLayout?
    @Published var displayLayoutMessage = ""
    var displayDraftEdited = false
    @Published var displayPages: ModemLauncherPages = .defaultPages
    @Published var displaySavedPages: ModemLauncherPages?
    @Published var displayPagesMessage = ""
    var displayPagesDraftEdited = false
    @Published var vpnInspection: VPNInspection?
    @Published var vpnError = ""
    @Published var ttlStatus: TTLStatus?
    @Published var ttlOutboundEnabled = false
    @Published var ttlOutboundValue = "64"
    @Published var ttlInboundIncrementEnabled = false
    @Published var ttlInboundIncrementValue = "1"
    @Published var packageName = ""
    @Published var diagnosticToolsStatus: DiagnosticToolsStatus?
    @Published var diagnosticToolsPlan: DiagnosticToolsPlan?
    @Published var diagnosticToolsError = ""
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
    var connectionMonitorTask: Task<Void, Never>?
    var validationMessage: String {
        if imei1.isEmpty && imei2.isEmpty { return "Введите два IMEI или сгенерируйте второй на основе первого" }
        if !IMEI.valid(imei1) { return "IMEI 1: нужны 15 цифр и корректная контрольная сумма Luhn" }
        if !IMEI.valid(imei2) { return "IMEI 2: нужны 15 цифр и корректная контрольная сумма Luhn" }
        if imei1 == imei2 { return "Для двух слотов нужны разные IMEI" }
        if imei1 == currentIMEI1 && imei2 == currentIMEI2 { return "Эта пара уже записана на модеме" }
        return "Оба IMEI корректны по формату и контрольной сумме"
    }
    var canApply: Bool { permitsSSHOperations && (connected || (!webPassword.isEmpty && !agentPassword.isEmpty)) && !busy && !terminalActive && !pendingOperation && !setupPending && !diagnosticADBPending && !adbTogglePending && !systemRestorePending && IMEI.valid(imei1) && IMEI.valid(imei2) && imei1 != imei2 && (imei1 != currentIMEI1 || imei2 != currentIMEI2) }
    var canManage: Bool { connected && activeChannel == .ssh && accessReady && permitsSSHOperations && !busy && !terminalActive && !adbTogglePending && !systemRestorePending }
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
        let esimFixture = CommandLine.arguments.contains("--esim-ui-fixture")
        storage = esimFixture ? FileManager.default.temporaryDirectory.appendingPathComponent("zte-esim-ui-preview-" + UUID().uuidString) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ZTE IMEI Studio")
        resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("MacIMEI/Resources")
        keyPath = storage.appendingPathComponent("SSH/id_ed25519").path
        knownHostsPath = storage.appendingPathComponent("SSH/known_hosts").path
        if let c = try? readJSON(Connection.self, storage.appendingPathComponent("connection.json")) { host = c.host; port = c.port; keyPath = c.keyPath; knownHostsPath = Connection.restoredKnownHostsPath(c.knownHostsPath, fallback: storage.appendingPathComponent("SSH/known_hosts").path) }
        if let saved = try? readJSON(ConnectionMode.self, storage.appendingPathComponent("connection-mode.json")) { connectionMode = saved == .ssh ? .ssh : .automatic }
        refreshBackups()
        refreshSystemBackups()
        do {
            try ActivityJournal(root: storage).record(operationID: sessionID, category: "session", title: "Запуск приложения", result: "started", details: ["macOS": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": "arm64", "endpoint": host + ":" + port])
        } catch { journalWarning = "Журнал недоступен: " + error.localizedDescription }
        refreshActivity()
        loadEsimPreview()
        if pendingOperation { status = "Есть незавершённая операция. Подключите тот же модем и нажмите «Продолжить»." }
    }
    var connection: Connection { Connection(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, keyPath: keyPath, knownHostsPath: knownHostsPath, skipFirmwareCheck: skipFirmwareCheck) }
    func setFirmwareCheckSkipped(_ enabled: Bool) {
        guard !busy, !terminalActive, enabled != skipFirmwareCheck else { return }
        let statuses = channelStatuses, checked = connectionsChecked
        skipFirmwareCheck = enabled
        // A policy change invalidates the session, not reachability or entered
        // credentials. Retain discovery so the explicit override is immediate.
        invalidateChannelConnection(clearIdentity: false)
        channelStatuses = statuses; connectionsChecked = checked
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
        connectionMonitorTask?.cancel(); connectionMonitorTask = nil
        accessReady = true; connectedIdentity = state.identity; connectedReadCID = state.identity.cid; activeChannel = .ssh
        channelSession = nil; channelSummary = nil; connectedWebIdentity = nil
        mergeChannelStatuses([ConnectionChannelStatus(mode: .ssh, state: .available, message: "SSH и устройство проверены")])
        connectedIMEI = state.imeis[0]
        currentIMEI1 = state.imeis[0]; currentIMEI2 = state.imeis[1]
        firmware = state.identity.firmwareHash == ModemEngine.firmwareHash ? "CN_ZTE_MU5250V1.0.0B31" : "Непроверенная прошивка"; connected = true
    }
    func acceptIMEIRead(_ state: DeviceState) throws {
        try require(state.imeis.count == 2, "Модем не вернул оба IMEI")
        guard connected, let session = channelSession else { accept(state); return }
        guard activeChannel == .ssh, session.mode == .ssh, let proof = session.diagnosticSession?.readProof else {
            throw IMEIError.message("Устройство, прошивка или сеанс загрузки изменились во время чтения IMEI")
        }
        try require((connectedIdentity == nil || state.identity == connectedIdentity) &&
                    (connectedReadCID == nil || state.identity.cid == connectedReadCID) &&
                    (proof.cid == nil || state.identity.cid == proof.cid) &&
                    (proof.firmwareHash == nil || state.identity.firmwareHash == proof.firmwareHash) &&
                    (proof.bootID == nil || state.boot == proof.bootID),
                    "Устройство, прошивка или сеанс загрузки изменились во время чтения IMEI")
        if let connectedIMEI {
            try require(state.imeis[0] == connectedIMEI, "IMEI выбранного модема изменился. Проверьте подключение заново.")
        }
        // A read does not replace the verified session, its monitor, or any
        // other section. Mutations use accept(_:) and rehydrate after reboot.
        currentIMEI1 = state.imeis[0]; currentIMEI2 = state.imeis[1]
        connectedIdentity = state.identity; connectedReadCID = state.identity.cid; connectedIMEI = state.imeis[0]
    }
    func perform(continuingIMEIOperation: Bool = false, _ work: @escaping @Sendable (ModemEngine) throws -> DeviceState?) {
        guard !busy && !terminalActive && !systemRestorePending && permitsSSHOperations else { return }
        let config = connection
        // A pending IMEI transaction may have changed IMEI and rebooted already.
        // Its journal checks the intended device and the acknowledged progress.
        let target = continuingIMEIOperation ? SSHSelectionContext(identity: connectedIdentity, imei: nil, session: nil) : sshSelectionContext
        do { try config.validate(); try secureDirectory(storage); try saveJSON(config, storage.appendingPathComponent("connection.json")) }
        catch { append(error.localizedDescription); return }
        busy = true; progress = 0; imeiCheckResult = ""
        let root = storage, assets = resources
        operationTask = Task { [weak self] in
            guard let self else { return }
            var receivedState = false
            do {
                let state = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> DeviceState? in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try target.verify(engine); return try work(engine) }
                }.value
                if let state { accept(state); receivedState = true }
            } catch {
                append("Остановлено: " + error.localizedDescription)
                markConnectionUnavailable(error.localizedDescription)
            }
            busy = false; refreshBackups(); operationTask = nil
            if receivedState { refreshConnectedSections() }
        }
    }
    func connect() {
        guard !busy else { return }
        // The main connection always uses SSH. Switching
        // a stored legacy preference must not discard a local launcher draft.
        if connectionMode != .ssh {
            connectionMode = .ssh
            do { try secureDirectory(storage); try saveJSON(connectionMode, storage.appendingPathComponent("connection-mode.json")) }
            catch { append("Не удалось сохранить способ подключения: " + error.localizedDescription); return }
        }
        connectPreferredChannel()
    }
    func readIMEI() { connect(readIMEIOnly: true) }
    private func connect(readIMEIOnly: Bool) {
        guard !busy && !terminalActive && permitsSSHOperations else { append("Для чтения NV/IMEI выберите SSH или подготовьте SSH-доступ."); return }
        let config = connection, root = storage, assets = resources
        let target = sshSelectionContext
        do { try config.validate(); try secureDirectory(storage); try saveJSON(config, storage.appendingPathComponent("connection.json")) }
        catch { append(error.localizedDescription); return }
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] text, progress in
                        Task { @MainActor [weak self] in self?.append(text, progress: progress) }
                    }
                    return try engine.locked {
                        try target.verify(engine)
                        let state = try engine.inspect()
                        try target.verify(engine)
                        return state
                    }
                }.value
                try acceptIMEIRead(state)
            } catch { markConnectionUnavailable(error.localizedDescription); append("Остановлено: " + error.localizedDescription) }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func setup(targets: [String]? = nil) {
        guard !busy && !terminalActive && !systemRestorePending && permitsSSHOperations else { return }
        let password = webPassword, agentSecret = agentPassword, suffix = backupSuffix
        let config = connection, root = storage, assets = resources
        let expectedIdentity = connectedIdentity, expectedIMEI = connectedIMEI ?? channelSummary?.primaryIMEI
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let installer = try OnboardingEngine(root: root, resources: assets, connection: config, backupSuffix: suffix, update: { [weak self] message,value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    })
                    return try installer.run(webPassword: password, agentPassword: agentSecret, expectedIdentity: expectedIdentity, expectedIMEI: expectedIMEI)
                }.value
                keyPath = result.connection.keyPath; knownHostsPath = result.connection.knownHostsPath; port = result.connection.port
                try saveJSON(result.connection, root.appendingPathComponent("connection.json"))
                accessReady = true; connectedIdentity = result.identity
                if let state = result.state { accept(state) }
                else {
                    connected = false; currentIMEI1 = ""; currentIMEI2 = ""; firmware = result.firmware
                    modemInformation = nil; applicationInventory = nil; accessState = nil
                    agentInstallationStatus = nil; screenLocalizationStatus = nil; ttlStatus = nil
                    vpnInspection = nil; vpnError = ""; sshAccountsLoaded = false; sshAccounts = []
                    diagnosticReport = nil; diagnosticText = ""; selectedDiagnostic = "system.log"
                    append("SSH-доступ готов. Готовность агента и совместимость изменения IMEI проверяются отдельно; доступна диагностика.")
                    if targets != nil { append("Автоматическая смена IMEI после подготовки этой прошивки не выполняется.") }
                }
                if let targets, let preparedState = result.state, targets != preparedState.imeis {
                    let connection = result.connection
                    let target = SSHSelectionContext(identity: result.identity, imei: preparedState.imeis[0], session: nil)
                    let state = try await Task.detached(priority: .userInitiated) { [weak self] in
                        let engine = try ModemEngine(root: root, resources: assets, connection: connection) { [weak self] message,value in
                            Task { @MainActor [weak self] in self?.append(message, progress: value) }
                        }
                        return try engine.locked { try target.verify(engine); return try engine.begin(targets: targets) }
                    }.value
                    accept(state)
                }
            } catch { markConnectionUnavailable(error.localizedDescription); append("Остановлено: " + error.localizedDescription) }
            busy = false; refreshBackups(); operationTask = nil
            if connected { refreshConnectedSections() }
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
    func resume() { guard pendingOperation else { return }; perform(continuingIMEIOperation: true) { try $0.resume() } }
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
        let target = sshSelectionContext
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let verifier = try ModemEngine(root: root, resources: assets, connection: config)
                    try target.verify(verifier)
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
        guard VerifiedCatalogStore.shared.allows("ssclash") else { append("Приложение пока не входит в проверенный каталог"); return }
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
        let target = sshSelectionContext
        busy = true; progress = 0
        if action == "preview" { packagePreview = ""; packagePreviewName = "" }
        if action == "inventory" { applicationsError = "" }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> (ModemApplicationInventory, String) in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        try target.verify(engine)
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
                        return (try action == "inventory" ? manager.inventoryWithManagedApps() : manager.inventory(), message)
                    }
                }.value
                acceptApplicationInventory(result.0)
                if action == "preview" { packagePreview = result.1; packagePreviewName = package; append("Результат проверки пакета получен", progress: 1) }
                else { append(result.1, progress: 1) }
            } catch {
                if action == "inventory" {
                    applicationInventory = nil; diagnosticToolsStatus = nil; diagnosticToolsPlan = nil
                    experimentalOpkgStatus = nil; applicationsError = ActivityJournal.redact(error.localizedDescription)
                }
                append("Приложения: " + error.localizedDescription)
            }
            busy = false; refreshBackups(); operationTask = nil
        }
    }
    func refreshScreenLocalization() { manageScreenLocalization(.status) }
    func enableScreenLocalization() { manageScreenLocalization(.enable) }
    func disableScreenLocalization() { manageScreenLocalization(.disable) }
    private func manageScreenLocalization(_ action: ScreenLocalizationAction) {
        guard action == .status ? canReadModem : canManage else { return }
        let config = connection, root = storage, assets = resources
        let target = sshSelectionContext
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try target.verify(engine); return try ScreenLocalization(engine: engine).perform(action) }
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
        let target = sshSelectionContext
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked { try target.verify(engine); return try TTLSettingsManager(engine: engine).perform(configuration: configuration) }
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
        adbTogglePending = FileManager.default.fileExists(atPath: storage.appendingPathComponent("adb-toggle-pending.json").path)
        diagnosticADBPending = FileManager.default.fileExists(atPath: storage.appendingPathComponent("adb-access-pending.json").path)
        componentCleanupPending = ComponentCleanup.hasPending(root: storage)
        componentCleanupCanCancel = ComponentCleanup.canCancel(root: storage)
        setupPending = FileManager.default.fileExists(atPath: storage.appendingPathComponent("setup-pending.json").path) || componentCleanupPending
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
    func chooseKey() { let p = NSOpenPanel(); p.title = L10n.text("Закрытый SSH-ключ установленного агента"); p.canChooseDirectories = false; p.showsHiddenFiles = true; if p.runModal() == .OK, let url = p.url { editConnectionKeyPath(url.path) } }
    func chooseKnownHosts() { let p = NSOpenPanel(); p.title = L10n.text("Файл с проверенным ключом SSH-сервера модема"); p.canChooseDirectories = false; p.showsHiddenFiles = true; if p.runModal() == .OK, let url = p.url { editConnectionKnownHostsPath(url.path) } }
    func importBackup() {
        guard !busy && !pendingOperation else { return }
        let p = NSOpenPanel(); p.title = L10n.text("Папка бэкапа приложения или исходного IMEI-бэкапа проекта"); p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let url = p.url { perform { engine in _ = try engine.importBackup(url); engine.update("Бэкап импортирован и проверен.", 1); return nil } }
    }
}
