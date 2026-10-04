import Foundation

@MainActor extension AppModel {
    var sshSelectionContext: SSHSelectionContext {
        SSHSelectionContext(identity: connectedIdentity ?? modemInformation?.identity,
                            imei: connectedIMEI ?? channelSummary?.primaryIMEI, session: channelSession)
    }
    var permitsSSHOperations: Bool {
        (connectionMode == .automatic || connectionMode == .ssh) && (activeChannel == nil || activeChannel == .ssh)
    }
    var connectionLabel: String {
        guard connected else { return "Нет подключения" }
        if activeChannel == .ssh { return "Подключено · SSH" }
        if activeChannel == .adb { return "Подключено · ADB" }
        return "Нет подключения"
    }
    var connectionCapabilityText: String {
        guard connected else { return "Сначала нажмите «Проверить устройство». Рабочий root USB ADB позволяет подготовить SSH; неизвестная прошивка требует проверки конкретных условий установки." }
        return activeChannel == .ssh
            ? "SSH: сведения, диагностика и управление. Совместимость каждой операции проверяется отдельно."
            : "ADB по USB: ограниченный доступ — сведения и диагностика. Для установки плиток и управления выполните подготовку SSH."
    }
    var isStockWebAvailable: Bool {
        channelStatuses.contains { $0.mode == .web && ($0.state == .available || $0.state == .authenticationRequired) }
    }
    var hasSSHForPreparation: Bool {
        (connected && activeChannel == .ssh && accessReady) || channelStatuses.contains { $0.mode == .ssh && $0.state == .available }
    }
    var canPrepareModem: Bool {
        !busy && !terminalActive && !pendingOperation && !systemRestorePending && !diagnosticADBPending && (isStockWebAvailable || setupPending || channelStatuses.contains { $0.mode == .adb && $0.state == .available } || firmwareResearchReport?.transport == "adb")
            && (setupPending || !hasSSHForPreparation)
    }
    var canEnableDiagnosticADB: Bool {
        !busy && !terminalActive && !pendingOperation && !systemRestorePending && !setupPending && (isStockWebAvailable || diagnosticADBPending || (!host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !webPassword.isEmpty))
    }
    var preparationUnavailableReason: String? {
        if hasSSHForPreparation && !setupPending {
            return "SSH уже доступен: предварительная подготовка не требуется. ADB можно включить отдельно для диагностики."
        }
        guard connectionsChecked, !isStockWebAvailable, !setupPending, firmwareResearchReport?.transport != "adb", !channelStatuses.contains(where: { $0.mode == .adb && $0.state == .available }) else { return nil }
        switch channelStatuses.first(where: { $0.mode == .web })?.state {
        case .invalidPassword:
            return "Неверный пароль штатного Web. Исправьте пароль и нажмите «Проверить подключения»."
        case .rateLimited:
            return "Штатный Web временно заблокировал вход. Дождитесь окончания блокировки и повторите проверку подключений."
        case .notChecked:
            return "Пароль штатного Web ещё не проверен. Нажмите «Проверить подключения»."
        default:
            return "Сначала нажмите «Проверить устройство». Для подготовки нужен работающий root USB ADB или поддерживаемый способ его включения через штатный Web."
        }
    }

    func connectionPasswordChanged(_ mode: ConnectionMode) {
        // Password fields are disabled during operations. Clearing secrets after
        // setup must not invalidate its verified result or an active shell.
        guard !busy, mode == .web || mode == .agent,
              let index = channelStatuses.firstIndex(where: { $0.mode == mode }) else { return }
        channelStatuses[index] = ConnectionChannelStatus(mode: mode, state: .notChecked,
            message: "Пароль изменён. Нажмите «Проверить подключения», чтобы проверить доступ.")
    }

    func setConnectionMode(_ mode: ConnectionMode) {
        guard !busy, mode != connectionMode, mode == .automatic || ConnectionMode.connectionPriority.contains(mode) else { return }
        connectionMode = mode
        // Discovery describes reachability, independently of the requested mode.
        let statuses = channelStatuses, checked = connectionsChecked
        invalidateChannelConnection(clearIdentity: false)
        channelStatuses = statuses; connectionsChecked = checked
        do { try secureDirectory(storage); try saveJSON(mode, storage.appendingPathComponent("connection-mode.json")) }
        catch { append("Не удалось сохранить способ подключения: " + error.localizedDescription) }
    }
    func clearConnectedData(preserveDisplayDraft: Bool = false) {
        closeTerminal(); terminalSession.clear(); terminalError = ""
        opkgFeeds = nil; opkgFeedsDraft = ""; opkgFeedsMessage = ""
        modemInformation = nil; applicationInventory = nil; accessState = nil
        applicationsError = ""; experimentalOpkgStatus = nil; experimentalOpkgError = ""
        opkgTranscript = ""; opkgHistory = []; opkgCommand = ""
        diagnosticToolsStatus = nil; diagnosticToolsPlan = nil; diagnosticToolsError = ""
        agentInstallationStatus = nil; screenLocalizationStatus = nil; ttlStatus = nil
        ttlOutboundEnabled = false; ttlOutboundValue = "64"; ttlInboundIncrementEnabled = false; ttlInboundIncrementValue = "1"
        vpnInspection = nil; vpnError = ""; displayInspection = nil; displaySavedLayout = nil; displaySavedPages = nil; displayError = ""
        if !preserveDisplayDraft { clearDisplayLayout() }
        sshAccounts = []; sshListenerReady = false; sshRecoveryPending = false; sshRecoveryKind = .none; sshAccountsLoaded = false
        currentIMEI1 = ""; currentIMEI2 = ""; firmware = ""
        clearEsim()
        packagePreview = ""; packagePreviewName = ""
        sectionRefreshErrors = [:]; sectionsUpdatedAt = nil
        systemRestorePlan = nil; systemRestoreConfirmation = ""
    }
    func markConnectionUnavailable(_ reason: String) {
        connectionMonitorTask?.cancel(); connectionMonitorTask = nil
        if let previous = activeChannel, !reason.isEmpty,
           channelStatuses.first(where: { $0.mode == previous })?.state.preventsDowngrade != true {
            mergeChannelStatuses([ConnectionChannelStatus(mode: previous, state: .unavailable, message: reason)])
        }
        channelSession = nil; channelSummary = nil; activeChannel = nil
        connected = false; accessReady = false; connectionReason = reason
        clearConnectedData(preserveDisplayDraft: true)
    }
    func invalidateChannelConnection(clearIdentity: Bool = true) {
        guard !busy else { return }
        markConnectionUnavailable("")
        channelStatuses = []; connectionsChecked = false; preparationError = ""; diagnosticADBMessage = ""
        clearDisplayLayout()
        diagnosticReport = nil; diagnosticText = ""; selectedDiagnostic = "system.log"
        if clearIdentity { connectedIdentity = nil; connectedWebIdentity = nil; connectedIMEI = nil }
    }
    func mergeChannelStatuses(_ statuses: [ConnectionChannelStatus]) {
        var byMode = Dictionary(uniqueKeysWithValues: channelStatuses.map { ($0.mode, $0) })
        for status in statuses where status.state != .notChecked || byMode[status.mode] == nil { byMode[status.mode] = status }
        channelStatuses = ConnectionMode.discoveryOrder.compactMap { byMode[$0] }
    }
    func acceptDiscoveredStatuses(_ statuses: [ConnectionChannelStatus], authenticate: Bool) {
        let previous = Dictionary(uniqueKeysWithValues: channelStatuses.map { ($0.mode, $0) })
        channelStatuses = statuses.map { status in
            guard !authenticate, status.mode == .web || status.mode == .agent,
                  status.state == .authenticationRequired, let known = previous[status.mode] else { return status }
            let message: String
            switch known.state {
            case .available:
                message = "Сервис отвечает. Пароль был принят при последней ручной проверке; повторный вход не выполнялся."
            case .invalidPassword:
                message = "Сервис отвечает. При последней ручной проверке пароль был отклонён. Исправьте пароль и повторите проверку."
            case .rateLimited:
                message = "Сервис отвечает. При последней ручной проверке вход был временно заблокирован. Дождитесь окончания блокировки и повторите проверку."
            default: return status
            }
            // This proves reachability and retains the explicitly checked
            // credential result, without reusing an old device summary.
            return ConnectionChannelStatus(mode: status.mode, state: known.state, message: message)
        }
        connectionsChecked = true
    }
    func acceptChannelSelection(_ result: ChannelSelection) {
        mergeChannelStatuses(result.statuses)
        connectionReason = result.reason
        guard let session = result.session, let mode = result.actualMode,
              mode == .ssh, session.mode == mode, session.diagnosticSession != nil else {
            markConnectionUnavailable(result.reason)
            return
        }
        channelSession = session; activeChannel = mode; connected = true; accessReady = mode == .ssh
        acceptChannelSummary(session.summary)
    }
    func acceptChannelSummary(_ summary: ConnectionDeviceSummary) {
        channelSummary = summary
        if let identity = summary.identity { connectedIdentity = identity }
        if let web = summary.webIdentity { connectedWebIdentity = web }
        if let imei = summary.primaryIMEI {
            if currentIMEI1 != imei { currentIMEI2 = "" }
            connectedIMEI = imei; currentIMEI1 = imei
        }
        if let version = summary.firmware { firmware = version }
        if connected, let activeChannel {
            mergeChannelStatuses([ConnectionChannelStatus(mode: activeChannel, state: .available,
                message: "Соединение и устройство проверены", summary: summary)])
        }
    }
    func acceptConnectionOverview(_ value: ConnectionOverviewSnapshot) {
        acceptChannelSummary(value.summary)
        if value.sections.contains(.information) {
            modemInformation = value.information
            if let info = value.information { firmware = info.firmware }
        }
        if value.sections.contains(.display) {
            if let display = value.display { receiveDisplayInspection(display) }
            else {
                displayInspection = nil; displaySavedLayout = nil; displaySavedPages = nil
                if !displayDraftEdited { displayLayout = .defaultLayout }
                if !displayPagesDraftEdited { displayPages = .defaultPages }
            }
            displayError = value.errors[.display] ?? ""
        }
        if value.sections.contains(.vpn) { vpnInspection = value.vpn; vpnError = value.errors[.vpn] ?? "" }
        if value.sections.contains(.ttl) {
            ttlStatus = value.ttl
            if let ttl = value.ttl, ttl.state != .error && ttl.state != .unsupported {
                ttlOutboundEnabled = ttl.configuration.outbound != nil
                ttlOutboundValue = String(ttl.configuration.outbound ?? 64)
                ttlInboundIncrementEnabled = ttl.configuration.inboundIncrement != nil
                ttlInboundIncrementValue = String(ttl.configuration.inboundIncrement ?? 1)
            }
        }
        if value.sections.contains(.screen) { screenLocalizationStatus = value.screen }
        if value.sections.contains(.agent) { agentInstallationStatus = value.agent }
        if value.sections.contains(.applications) {
            if let inventory = value.applications { acceptApplicationInventory(inventory) }
            else {
                applicationInventory = nil; diagnosticToolsStatus = nil; diagnosticToolsPlan = nil; experimentalOpkgStatus = nil
                applicationsError = value.errors[.applications] ?? ""
                diagnosticToolsError = ""; experimentalOpkgError = ""
            }
        }
        if value.sections.contains(.access) {
            if let access = value.access { acceptAccess(access) }
            else {
                accessState = nil; sshAccounts = []; sshAccountsLoaded = false
                sshListenerReady = false; sshRecoveryPending = false; sshRecoveryKind = .none
            }
        }
        sectionsUpdatedAt = Date()
        for section in ConnectionOverviewSection.allCases where value.sections.contains(section) {
            sectionRefreshErrors[section] = value.errors[section]
            if let error = value.errors[section] { append(section.title + ": " + error) }
        }
    }

    func discoverConnections() {
        discoverConnections(authenticate: true)
    }
    func discoverConnectionsPassively() {
        discoverConnections(authenticate: false)
    }
    private func discoverConnections(authenticate: Bool) {
        guard !esimPreview else { return }
        guard !busy, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let config = connection, root = storage, assets = resources
        let expected = connectedIdentity, expectedWeb = connectedWebIdentity, expectedIMEI = connectedIMEI
        let webSecret = authenticate ? webPassword : "", agentSecret = authenticate ? agentPassword : ""
        let selected = channelSession
        busy = true; progress = 0; preparationError = ""
        append(authenticate ? "Проверяю SSH, USB ADB, агент и штатный Web с введёнными паролями…" : "Проверяю доступность SSH, USB ADB, агента и штатного Web без входа…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let statuses = try await Task.detached(priority: .userInitiated) {
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { _, _ in }
                    return try engine.locked {
                        let statuses = try ConnectionRouter(engine: engine, expectedIdentity: expected, expectedWebIdentity: expectedWeb,
                            expectedIMEI: expectedIMEI, webPassword: webSecret, agentPassword: agentSecret).discover(authenticate: authenticate)
                        return statuses
                    }
                }.value
                acceptDiscoveredStatuses(statuses, authenticate: authenticate)
                if let selected {
                    do { acceptChannelSummary(try await Task.detached { try selected.readSummary() }.value) }
                    catch { markConnectionUnavailable(error.localizedDescription); append("Подключение потеряно: " + error.localizedDescription) }
                } else if connected, let activeChannel,
                          let status = statuses.first(where: { $0.mode == activeChannel }), status.state != .available {
                    markConnectionUnavailable(status.message)
                }
                append(isStockWebAvailable ? "Проверка завершена. Штатный Web доступен; можно выполнить подготовку." : "Проверка подключений завершена.", progress: 1)
            } catch { preparationError = error.localizedDescription; append("Проверка подключений: " + error.localizedDescription) }
            busy = false; refreshActivity(); operationTask = nil
        }
    }

    func connectPreferredChannel() {
        guard !busy else { return }
        let config = connection, root = storage, assets = resources, mode = ConnectionMode.ssh
        let expected = connectedIdentity ?? modemInformation?.identity
        let expectedWeb = connectedWebIdentity ?? channelSummary?.webIdentity
        let expectedIMEI = connectedIMEI ?? channelSummary?.primaryIMEI
        do { try secureDirectory(storage); try saveJSON(config, storage.appendingPathComponent("connection.json")) }
        catch { append("Не удалось сохранить подключение: " + error.localizedDescription); return }
        markConnectionUnavailable(""); preparationError = ""
        busy = true; progress = 0
        append("Подключаюсь к модему по SSH…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { _, _ in }
                    return try engine.locked {
                        try ConnectionRouter(engine: engine, expectedIdentity: expected, expectedWebIdentity: expectedWeb, expectedIMEI: expectedIMEI).connect(mode: mode)
                    }
                }.value
                acceptChannelSelection(result)
                append(result.reason, progress: result.actualMode == nil ? 0 : 0.2)
                if let session = channelSession { try await loadConnectedSections(session, config: config) }
                // An informational probe failure must not cancel a verified shell.
                do {
                    let statuses = try await Task.detached(priority: .userInitiated) {
                        let engine = try ModemEngine(root: root, resources: assets, connection: config) { _, _ in }
                        return try engine.locked {
                            try ConnectionRouter(engine: engine, expectedIdentity: result.session?.summary.identity ?? expected,
                                                 expectedWebIdentity: expectedWeb, expectedIMEI: result.session?.summary.primaryIMEI ?? expectedIMEI).discover()
                        }
                    }.value
                    acceptDiscoveredStatuses(statuses, authenticate: false)
                } catch {
                    preparationError = "Не удалось обновить список подключений: " + error.localizedDescription
                    append(preparationError)
                }
                if let session = channelSession { acceptChannelSummary(try await Task.detached { try session.readSummary() }.value) }
                if connected { append(connectionLabel + (sectionRefreshErrors.isEmpty ? ". Разделы обновлены." : ". Часть разделов требует внимания; причины показаны в них."), progress: 1) }
                else { append(result.reason) }
            } catch {
                markConnectionUnavailable(error.localizedDescription)
                append("Подключение: " + error.localizedDescription)
            }
            busy = false; refreshBackups(); refreshDeviceBackups(); refreshSystemBackups(); refreshActivity(); operationTask = nil
            startConnectionMonitor()
        }
    }

    private func loadConnectedSections(_ session: ReadOnlyChannelSession, config: Connection,
                                       sections: Set<ConnectionOverviewSection> = Set(ConnectionOverviewSection.allCases)) async throws {
        let root = storage, assets = resources
        let sections = session.summary.fields["accessProfile"] == "linux-arm64-access" ? sections.intersection([.information]) : sections
        append(sections == [.information] ? "Обновляю сведения о модеме…" : connectionLabel + ". Обновляю сведения разделов…", progress: 0.25)
        let snapshot = try await Task.detached(priority: .userInitiated) { [weak self] in
            let engine = try ModemEngine(root: root, resources: assets, connection: config) { _, _ in }
            return try engine.locked {
                try ConnectionOverview.collect(engine: engine, session: session, sections: sections) { [weak self] section in
                    Task { @MainActor [weak self] in self?.append("Обновляю раздел: " + section.title + "…") }
                }
            }
        }.value
        acceptConnectionOverview(snapshot)
    }
    func refreshConnectedSections() {
        refreshConnectedSections(Set(ConnectionOverviewSection.allCases))
    }
    private func refreshConnectedSections(_ sections: Set<ConnectionOverviewSection>) {
        guard !busy, connected else { return }
        let selected = channelSession, mode = activeChannel ?? .ssh
        let config = connection, root = storage, assets = resources
        let expected = connectedIdentity, expectedIMEI = connectedIMEI
        busy = true; progress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                var session = selected
                if session == nil {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let engine = try ModemEngine(root: root, resources: assets, connection: config) { _, _ in }
                        return try engine.locked { try ConnectionRouter(engine: engine, expectedIdentity: expected, expectedIMEI: expectedIMEI).connect(mode: mode) }
                    }.value
                    acceptChannelSelection(result); session = channelSession
                }
                guard let session else { throw IMEIError.message(connectionReason) }
                try await loadConnectedSections(session, config: config, sections: sections)
                if sections == [.information] {
                    append(sectionRefreshErrors[.information] == nil ? "Сведения о модеме обновлены." : "Не удалось обновить сведения о модеме; причина показана в разделе.", progress: 1)
                } else {
                    append(sectionRefreshErrors.isEmpty ? "Разделы обновлены." : "Разделы обновлены. Для недоступных сведений показаны причины.", progress: 1)
                }
            } catch { markConnectionUnavailable(error.localizedDescription); append("Подключение потеряно: " + error.localizedDescription) }
            busy = false; refreshActivity(); operationTask = nil
            startConnectionMonitor()
        }
    }
    func refreshChannelInformation() {
        // A page's refresh reads only that page, on the verified transport.
        refreshConnectedSections([.information])
    }
    func canAcceptConnectionCheck(_ session: ReadOnlyChannelSession, generation: UInt64) -> Bool {
        !busy && connected && channelSession === session && connectionActivityGeneration == generation
    }
    /// Keep the sidebar honest after unplugging or rebooting. A check never
    /// changes transport, and a result arriving during an operation is ignored.
    func startConnectionMonitor() {
        connectionMonitorTask?.cancel(); connectionMonitorTask = nil
        guard connected, channelSession != nil else { return }
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
                guard let self else { return }
                guard !self.busy, self.connected, let selected = self.channelSession else { continue }
                let generation = self.connectionActivityGeneration
                do {
                    let summary = try await Task.detached(priority: .utility) { try selected.readSummary() }.value
                    guard !Task.isCancelled, self.canAcceptConnectionCheck(selected, generation: generation) else { continue }
                    self.acceptChannelSummary(summary)
                } catch {
                    guard !Task.isCancelled, self.canAcceptConnectionCheck(selected, generation: generation) else { continue }
                    self.markConnectionUnavailable(error.localizedDescription)
                    self.append("Подключение потеряно: " + error.localizedDescription)
                    return
                }
            }
        }
    }
    func enableDiagnosticADB() {
        guard canEnableDiagnosticADB else { return }
        let config = connection, root = storage, assets = resources
        let expected = connectedIdentity ?? modemInformation?.identity
        let expectedWeb = connectedWebIdentity ?? channelSummary?.webIdentity
        let expectedIMEI = connectedIMEI ?? channelSummary?.primaryIMEI
        let suffix = backupSuffix
        let webSecret = webPassword, reconnectSSH = connected && activeChannel == .ssh
        diagnosticADBMessage = ""
        markConnectionUnavailable("")
        busy = true; progress = 0
        append("Включаю USB ADB для диагностики. Подготовка агента и SSH не запускается…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try OnboardingEngine(root: root, resources: assets, connection: config, backupSuffix: suffix, update: { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    })
                    return try engine.enableDiagnosticADB(webPassword: webSecret, expectedIdentity: expected, expectedIMEI: expectedIMEI)
                }.value
                connectedIdentity = result.identity; connectedWebIdentity = result.webIdentity; connectedIMEI = result.webIdentity.imei
                diagnosticADBMessage = "ADB готов для диагностики. Агент и параметры SSH не изменялись."
                mergeChannelStatuses([ConnectionChannelStatus(mode: .adb, state: .available, message: diagnosticADBMessage)])
                append(diagnosticADBMessage, progress: 1)
            } catch {
                diagnosticADBMessage = error.localizedDescription
                mergeChannelStatuses([ConnectionChannelStatus(mode: .adb, state: .unavailable, message: diagnosticADBMessage)])
                append("Диагностика ADB: " + diagnosticADBMessage)
            }
            // A restore may reboot the modem. Never reuse the pre-operation
            // green connection state; establish a new pinned SSH proof instead.
            if reconnectSSH {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let engine = try ModemEngine(root: root, resources: assets, connection: config)
                        return try engine.locked {
                            try ConnectionRouter(engine: engine, expectedIdentity: expected, expectedWebIdentity: expectedWeb, expectedIMEI: expectedIMEI).connect(mode: .ssh)
                        }
                    }.value
                    acceptChannelSelection(result)
                    if let session = channelSession { try await loadConnectedSections(session, config: config) }
                } catch { markConnectionUnavailable(error.localizedDescription); append("Проверка SSH после ADB: " + error.localizedDescription) }
            }
            busy = false; refreshBackups(); refreshActivity(); operationTask = nil
            startConnectionMonitor()
        }
    }
    func preparePreferredSSH() {
        guard canPrepareModem else { return }
        preparationError = ""
        guard !agentPassword.isEmpty else {
            preparationError = "Введите пароль агента. Пароль Web нужен только если работающий root USB ADB отсутствует."
            append(preparationError); return
        }
        let config = connection, root = storage, assets = resources
        let webSecret = webPassword, agentSecret = agentPassword, suffix = backupSuffix, expected = connectedIdentity
        backupSuffix = ""
        let expectedIMEI = connectedIMEI ?? channelSummary?.primaryIMEI
        markConnectionUnavailable("")
        busy = true; progress = 0
        append("Проверяю устройство и работающий root USB ADB перед подготовкой доступа…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            var prepared = false
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let installer = try OnboardingEngine(root: root, resources: assets, connection: config, backupSuffix: suffix, update: { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    })
                    return try installer.run(webPassword: webSecret, agentPassword: agentSecret, expectedIdentity: expected, expectedIMEI: expectedIMEI)
                }.value
                keyPath = result.connection.keyPath; knownHostsPath = result.connection.knownHostsPath; port = result.connection.port
                try saveJSON(result.connection, storage.appendingPathComponent("connection.json"))
                connectionMode = .ssh; try saveJSON(connectionMode, storage.appendingPathComponent("connection-mode.json"))
                connectedIdentity = result.identity; connectedWebIdentity = nil
                if let state = result.state { connectedIMEI = state.imeis[0] }
                backupSuffix = result.suffix; webPassword = ""; agentPassword = ""
                prepared = true
                append("Подготовка завершена. Подключаюсь по SSH и обновляю все разделы…", progress: 1)
            } catch { preparationError = error.localizedDescription; append("Подготовка: " + error.localizedDescription) }
            firmwareResearchReport = try? FirmwareResearchArchive.latest(root: storage)
            busy = false; refreshBackups(); refreshActivity(); operationTask = nil
            if prepared { connectPreferredChannel() }
        }
    }
}
