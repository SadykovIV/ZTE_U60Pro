import Foundation

private let identity = Identity(cid: String(repeating: "a", count: 32), firmwareHash: ModemEngine.firmwareHash)
private let boot = "2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601"
private let imei = "490154203237518"
private let summary = ConnectionDeviceSummary(identity: identity, bootID: boot, imei: imei, fields: ["firmware": "CN_ZTE_MU5250V1.0.0B31"])
private func selection(_ mode: ConnectionMode, shell: Bool = true, requested: ConnectionMode = .automatic) -> ChannelSelection {
    let proof = DiagnosticDeviceProof(identity: identity, routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: nil)
    let diagnostics = DiagnosticSession(transport: mode.rawValue, reason: "state fixture", proof: proof,
        readIdentity: { throw IMEIError.message("State test must not verify or contact a modem") },
        execute: { _, _ in throw IMEIError.message("State test must not execute a modem command") })
    let session = ReadOnlyChannelSession(mode: mode, summary: summary, diagnosticSession: shell ? diagnostics : nil,
                                        readSummary: { throw IMEIError.message("State test must not refresh a modem") })
    return ChannelSelection(requestedMode: requested, actualMode: mode,
                            statuses: [ConnectionChannelStatus(mode: mode, state: .available, message: "fixture", summary: summary)],
                            session: session, reason: "fixture selected " + mode.rawValue)
}
private func snapshot() -> ConnectionOverviewSnapshot {
    let account = SSHAccount(name: "modemadmin", uid: 50000, home: "/data/zte-imei-admin/homes/modemadmin", administrator: true)
    return ConnectionOverviewSnapshot(summary: summary, limitedToADB: false,
        information: ModemInformation(collectedAt: Date(), model: "ZTE MU5250", firmware: "B31", internalFirmware: "B31-internal",
            distribution: "OpenWrt", systemVersion: "23.05.4", revision: "fixture", kernel: "5.15", architecture: "aarch64", board: "sdx75",
            processor: "SDX75", cpuCount: 4, hostname: "modem", uptimeSeconds: 3600, loadAverage: "0 0 0", memoryTotalKiB: 1024,
            memoryAvailableKiB: 512, memoryFreeKiB: 256, memoryCachedKiB: 128, swapTotalKiB: 0, swapFreeKiB: 0, volumes: [],
            readOnlyMounts: ["/"], batteryPercent: 78, batteryState: "Charging", agentVersion: "fixture", identity: identity, bootID: boot),
        display: ModemDisplayInspection(state: .absent, detail: "fixture", identity: identity, bootID: boot,
                                        expectedHash: VPNSettingsManager.launcherHash, canInstall: true),
        vpn: VPNInspection(status: VPNStatus(), missingCapabilities: [], ssclashInstalled: false),
        ttl: TTLStatus(state: .configured, configuration: TTLConfiguration(outbound: 65, inboundIncrement: 2), capability: .supported),
        screen: ScreenLocalizationStatus(state: .enabled, language: "cn", mounted: 3, bootEnabled: true, pid: 42),
        access: AccessManagementState(services: [], sshAccounts: SSHAccountState(accounts: [account], listenerReady: true, recoveryPending: false)),
        agent: AgentInstallationStatus(hash: VPNSettingsManager.agentHash, running: true, startupReady: true),
        applications: ModemApplicationInventory(storage: [], memoryTotalKiB: 1024, memoryAvailableKiB: 512, installedPackages: [],
            opkgWritable: false, ssclashInstalled: true, ssclashRunning: true, architecture: "aarch64", release: "23.05.4"))
}

@main struct ConnectionAppModelTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw IMEIError.message(message) }
        }
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); count += 1; print("PASS " + name) }
        let initial = AppModel(), isolatedStorage = initial.storage
        try check(isolatedStorage.path.contains("/MacIMEI/.build/connection-model-") && isolatedStorage.lastPathComponent == "state", "Test storage isolation not established")
        func model() throws -> AppModel {
            if FileManager.default.fileExists(atPath: isolatedStorage.path) { try FileManager.default.removeItem(at: isolatedStorage) }
            return AppModel()
        }
        try test("Fresh application explicitly disconnected with management disabled") {
            let m = try model()
            try check(!m.connected && m.connectionLabel == "Нет подключения" && !m.canManage && !m.canCollectDiagnostics, "Fresh connection state is misleading")
        }
        try test("SSH acceptance enables connected sidebar and management after busy ends") {
            let m = try model(); m.busy = true; m.acceptChannelSelection(selection(.ssh))
            try check(m.connected && m.accessReady && m.activeChannel == .ssh && m.connectionLabel.contains("Подключено") && m.connectionLabel.contains("SSH"), "SSH not reflected as connected")
            try check(!m.canManage && !m.canCollectDiagnostics, "Buttons enabled during hydration")
            m.busy = false
            try check(m.canManage && m.canReadModem && m.canCollectDiagnostics, "SSH controls remain disabled")
            try check(m.connectedIdentity == identity && m.connectedIMEI == imei && m.currentIMEI1 == imei, "Connected identity not retained")
        }
        try test("ADB availability is reserved for SSH preparation") {
            let m = try model(); m.connectionMode = .adb; m.acceptChannelSelection(selection(.adb, requested: .adb))
            try check(!m.connected && !m.accessReady && m.activeChannel == nil && !m.canCollectDiagnostics && !m.canResearchFirmware, "ADB connection not visible")
            try check(!m.canManage && !m.canReadModem && !m.canUseSystemBackupConnection && !m.canApplyTTL, "ADB gained SSH capabilities")
            m.installDisplay(); m.applyDisplayLayout(); m.installVPN(); m.installAgent(custom: false); m.restoreAgent()
            m.enableScreenLocalization(); m.applyTTLSettings(); m.createDeviceBackup(); m.createSystemBackup()
            try check(m.operationTask == nil && !m.busy, "ADB mutation scheduled background work")
            try check(m.connectionCapabilityText.contains("подготовки") && m.connectionCapabilityText.contains("SSH"), "ADB restriction not explained")
        }
        try test("Web and agent discovery do not masquerade as active modem connection") {
            for mode in [ConnectionMode.web, .agent] {
                let m = try model(); m.acceptChannelSelection(selection(mode))
                try check(!m.connected && m.channelSession == nil && m.activeChannel == nil && !m.canManage && !m.canCollectDiagnostics, "Weak API became active connection")
                try check(m.channelStatuses.first(where: { $0.mode == mode })?.state == .available, "Discovery information lost")
            }
        }
        try test("Missing or mismatched diagnostic session cannot enable SSH") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh, shell: false))
            try check(!m.connected && !m.canManage, "SSH without diagnostic proof accepted")
            var mismatch = selection(.adb); mismatch.actualMode = .ssh
            m.acceptChannelSelection(mismatch)
            try check(!m.connected && !m.canManage, "Mismatched selected channel accepted")
        }
        try test("Stock Web login challenge permits preparation without claiming connection") {
            let m = try model()
            m.channelStatuses = [ConnectionChannelStatus(mode: .web, state: .authenticationRequired, message: "Штатный Web ответил; нужен пароль")]
            m.connectionsChecked = true
            try check(m.isStockWebAvailable && m.canPrepareModem && !m.connected && !m.canManage, "Web discovery readiness wrong")
            m.preparePreferredSSH()
            try check(m.operationTask == nil && !m.busy && m.preparationError.contains("пароль"), "Empty preparation credentials triggered transport")
            for state in [ConnectionChannelState.unavailable, .invalidPassword, .rateLimited, .identityMismatch, .trustRejected, .unsupported, .notChecked] {
                m.channelStatuses[0].state = state
                try check(!m.isStockWebAvailable && !m.canPrepareModem, "Unverified/unavailable Web enabled preparation")
            }
        }
        try test("Rejected Web password and rate limit block new setup with a distinct explanation") {
            for state in [ConnectionChannelState.invalidPassword, .rateLimited] {
                let m = try model(); m.webPassword = "fixture-web-secret"; m.agentPassword = "fixture-agent-secret"
                m.connectionsChecked = true
                m.channelStatuses = [ConnectionChannelStatus(mode: .web, state: state, message: "fixture")]
                try check(!m.canPrepareModem && !m.isStockWebAvailable, "Rejected Web login enabled new setup")
                let reason = m.preparationUnavailableReason ?? ""
                try check(state == .invalidPassword ? reason.contains("Неверный пароль") : reason.contains("блокиров"), "Rejected Web login explanation is ambiguous")
                m.preparePreferredSSH()
                try check(m.operationTask == nil && !m.busy, "Rejected Web login started transport")
                m.setupPending = true
                try check(m.canPrepareModem && m.preparationUnavailableReason == nil, "Known HTTP failure hides interrupted setup recovery")
            }
        }
        try test("Existing SSH disables new preparation even with firmware override") {
            let m = try model()
            m.connectionsChecked = true
            m.channelStatuses = [ConnectionChannelStatus(mode: .ssh, state: .available, message: "verified SSH"),
                                 ConnectionChannelStatus(mode: .web, state: .available, message: "verified Web")]
            try check(!m.canPrepareModem && m.preparationUnavailableReason?.contains("SSH уже доступен") == true, "Existing SSH did not disable redundant preparation")
            m.preparePreferredSSH()
            try check(m.operationTask == nil && !m.busy, "Disabled preparation still started")
            m.setFirmwareCheckSkipped(true)
            try check(!m.canPrepareModem && !m.canEnableDiagnosticADB && m.connectionsChecked && m.channelStatuses.count == 2, "Override bypassed prepared SSH or disabled diagnostic ADB")
            m.busy = true; try check(!m.canPrepareModem, "Override bypassed busy guard"); m.busy = false
            m.pendingOperation = true; try check(!m.canPrepareModem, "Override bypassed IMEI recovery"); m.pendingOperation = false
            m.systemRestorePending = true; try check(!m.canPrepareModem, "Override bypassed restore recovery"); m.systemRestorePending = false
            m.channelStatuses[1].state = .invalidPassword
            try check(!m.canPrepareModem, "Override bypassed rejected Web credentials")
            m.channelStatuses[0].state = .unavailable; m.channelStatuses[1].state = .available
            m.skipFirmwareCheck = false
            try check(m.canPrepareModem, "Absent SSH blocked normal preparation")
            m.connected = true; m.activeChannel = .ssh; m.accessReady = true
            try check(!m.canPrepareModem, "Active SSH was ignored when discovery was stale")
            m.setupPending = true
            try check(m.canPrepareModem, "Verified SSH prevented completing interrupted preparation")
        }
        try test("Diagnostic ADB is independent of agent password and SSH readiness but respects operation guards") {
            let m = try model(); m.webPassword = "fixture-web"; m.agentPassword = ""
            m.acceptChannelSelection(selection(.ssh)); m.channelStatuses.append(ConnectionChannelStatus(mode: .web, state: .notChecked, message: "password changed"))
            try check(!m.canEnableDiagnosticADB && !m.canChangeADB && !m.canPrepareModem, "Live SSH used legacy Web ADB path or unknown control state")
            m.terminalActive = true; try check(!m.canEnableDiagnosticADB, "Open terminal did not block automatic USB change"); m.terminalActive = false
            m.busy = true; try check(!m.canEnableDiagnosticADB, "Busy guard bypassed"); m.busy = false
            m.setupPending = true; try check(!m.canEnableDiagnosticADB, "Setup pending bypassed"); m.setupPending = false
            m.pendingOperation = true; try check(!m.canEnableDiagnosticADB, "IMEI pending bypassed"); m.pendingOperation = false
            m.systemRestorePending = true; try check(!m.canEnableDiagnosticADB, "System restore pending bypassed"); m.systemRestorePending = false
            m.markConnectionUnavailable(""); m.webPassword = ""; m.channelStatuses = []; m.diagnosticADBPending = true
            try check(m.canEnableDiagnosticADB && !m.canPrepareModem, "Diagnostic resume requires Web password or permits competing setup")
        }
        try test("ADB checkbox never sends a write for unknown state or another pending operation") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh))
            m.setADBEnabled(false)
            try check(m.adbControlStatus == nil && !m.canChangeADB && m.operationTask == nil && !m.busy, "Unknown state toggled ADB")
            m.adbControlStatus = .init(enabled: true, supportsChange: true, descriptorsReady: true)
            try check(m.canChangeADB, "Confirmed adapter remained disabled")
            m.adbTogglePending = true; m.setADBEnabled(false)
            try check(!m.canChangeADB && !m.canManage && !m.canPrepareModem && m.operationTask == nil, "Pending transaction allowed competing work")
            m.adbTogglePending = false; m.terminalActive = true; m.setADBEnabled(false)
            try check(!m.canChangeADB && m.operationTask == nil, "Terminal did not block USB change")
        }
        try test("Editing one password invalidates only its HTTP check and preserves connected sections") {
            let m = try model(); let chosen = selection(.ssh)
            m.acceptChannelSelection(chosen); m.acceptConnectionOverview(snapshot())
            m.moveDisplayMetric(.uptime, before: .cpu); let draft = m.displayLayout
            m.channelStatuses += [ConnectionChannelStatus(mode: .web, state: .invalidPassword, message: "fixture wrong Web password"),
                                  ConnectionChannelStatus(mode: .agent, state: .available, message: "fixture authenticated agent")]
            m.connectionsChecked = true
            m.webPassword = "corrected-web-secret"
            try check(m.channelStatuses.first(where: { $0.mode == .web })?.state == .notChecked, "Web password edit retained obsolete rejection")
            try check(m.channelStatuses.first(where: { $0.mode == .web })?.message.contains("Пароль изменён") == true, "Web password edit missing recheck hint")
            try check(m.channelStatuses.first(where: { $0.mode == .agent })?.state == .available, "Web password edit invalidated agent")
            try check(!m.canPrepareModem && m.preparationUnavailableReason?.contains("SSH уже доступен") == true, "New unchecked password enabled preparation")
            m.agentPassword = "corrected-agent-secret"
            try check(m.channelStatuses.first(where: { $0.mode == .agent })?.state == .notChecked, "Agent password edit retained obsolete success")
            try check(m.connected && m.canManage && m.channelSession === chosen.session && m.activeChannel == .ssh, "Password edit disconnected verified SSH")
            try check(m.modemInformation != nil && m.displayLayout == draft && m.displayDraftEdited && m.sectionsUpdatedAt != nil, "Password edit cleared device data or launcher draft")
            try check(m.connectionsChecked && m.channelStatuses.first(where: { $0.mode == .ssh })?.state == .available, "Password edit triggered passive probing or invalidated SSH")
            try check(!m.log.contains("corrected-web-secret") && !m.log.contains("corrected-agent-secret") && m.operationTask == nil, "Password edit logged secrets or started transport")
        }
        try test("Unchanged secrets and setup cleanup do not invalidate verified checks") {
            let m = try model(); m.webPassword = "fixture-secret"; m.agentPassword = "fixture-agent-secret"
            m.channelStatuses = [ConnectionChannelStatus(mode: .web, state: .available, message: "fixture Web"),
                                 ConnectionChannelStatus(mode: .agent, state: .available, message: "fixture agent")]
            m.webPassword = "fixture-secret"
            try check(m.channelStatuses.allSatisfy { $0.state == .available }, "Assigning unchanged password invalidated check")
            m.busy = true; m.webPassword = ""; m.agentPassword = ""
            try check(m.channelStatuses.allSatisfy { $0.state == .available }, "Clearing secrets during setup invalidated completed checks")
        }
        try test("Passive checks preserve explicit HTTP password results without repeated login or stale summary") {
            for state in [ConnectionChannelState.available, .invalidPassword, .rateLimited] {
                let m = try model()
                m.channelStatuses = [ConnectionChannelStatus(mode: .web, state: state, message: "manual result", summary: summary),
                                     ConnectionChannelStatus(mode: .agent, state: state, message: "manual agent result", summary: summary)]
                let passive = [ConnectionChannelStatus(mode: .web, state: .authenticationRequired, message: "Web reachable"),
                               ConnectionChannelStatus(mode: .agent, state: .authenticationRequired, message: "Agent reachable")]
                m.acceptDiscoveredStatuses(passive, authenticate: false)
                try check(m.channelStatuses.allSatisfy { $0.state == state && $0.message.contains("последней ручной проверке") && $0.summary == nil }, "Passive check erased password result or presented stale identity as current")
                let messages = m.channelStatuses.map(\.message)
                m.acceptDiscoveredStatuses(passive, authenticate: false)
                try check(m.channelStatuses.map(\.message) == messages, "Repeated passive checks duplicated status text")
                try check(m.canPrepareModem == (state == .available), "Passive probe erased preparation guard")
                m.acceptDiscoveredStatuses([ConnectionChannelStatus(mode: .web, state: .available, message: "fresh authenticated result")], authenticate: true)
                try check(m.channelStatuses.first?.state == .available && m.channelStatuses.first?.message == "fresh authenticated result" && m.canPrepareModem, "Explicit successful retry did not replace old result")
                m.acceptDiscoveredStatuses([ConnectionChannelStatus(mode: .web, state: .invalidPassword, message: "fresh invalid result")], authenticate: true)
                try check(!m.canPrepareModem && m.channelStatuses.first?.state == .invalidPassword, "Explicit rejected retry retained previous success")
            }
        }
        try test("Passive failures and password edits supersede earlier HTTP authentication") {
            for state in [ConnectionChannelState.unavailable, .identityMismatch, .trustRejected] {
                let m = try model()
                m.channelStatuses = [ConnectionChannelStatus(mode: .web, state: .available, message: "old Web success")]
                m.acceptDiscoveredStatuses([ConnectionChannelStatus(mode: .web, state: state, message: "fresh failure")], authenticate: false)
                try check(m.channelStatuses.first?.state == state && m.channelStatuses.first?.message == "fresh failure" && !m.canPrepareModem, "Passive failure concealed by old authentication")
            }
            let m = try model()
            m.channelStatuses = [ConnectionChannelStatus(mode: .web, state: .available, message: "old Web success")]
            m.webPassword = "replacement-secret"
            m.acceptDiscoveredStatuses([ConnectionChannelStatus(mode: .web, state: .authenticationRequired, message: "Web reachable; enter password")], authenticate: false)
            try check(m.channelStatuses.first?.state == .authenticationRequired && !m.channelStatuses[0].message.contains("последней"), "Password edit allowed old authenticated result to return")
        }
        try test("Interrupted setup remains resumable without Web discovery") {
            let m = try model(); m.setupPending = true
            try check(m.canPrepareModem && !m.isStockWebAvailable, "Recovery preparation hidden")
            m.busy = true; try check(!m.canPrepareModem, "Busy preparation enabled"); m.busy = false
            m.pendingOperation = true; try check(!m.canPrepareModem, "IMEI transaction ignored"); m.pendingOperation = false
            m.systemRestorePending = true; try check(!m.canPrepareModem, "System restore ignored")
        }
        try test("RAM recovery SSH remains available without normal firmware connection; ADB blocked") {
            let m = try model(); m.keyPath = "/dev/null"; m.knownHostsPath = "/dev/null"
            for mode in [ConnectionMode.automatic, .ssh] {
                m.connectionMode = mode
                try check(!m.connected && m.canUseSystemBackupConnection, "Disconnected RAM recovery requires unavailable normal-firmware probe")
            }
            m.connectionMode = .adb
            try check(!m.canUseSystemBackupConnection, "Manual ADB enabled SSH recovery")
            m.connectionMode = .automatic; m.activeChannel = .adb
            try check(!m.canUseSystemBackupConnection, "Selected ADB silently allowed SSH recovery")
            m.activeChannel = nil; m.busy = true
            try check(!m.canUseSystemBackupConnection, "Busy recovery enabled")
            m.busy = false; m.keyPath = ""
            try check(!m.canUseSystemBackupConnection, "Recovery enabled without SSH key")
        }
        try test("Successful overview populates all sections and launcher install eligibility") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            try check(m.connected && m.canManage && m.modemInformation?.model == "ZTE MU5250", "Overview lost connection")
            try check(m.displayInspection?.canInstall == true && m.displaySavedLayout == .defaultLayout, "Installable launcher not hydrated")
            try check(m.vpnInspection != nil && m.ttlStatus != nil && m.screenLocalizationStatus != nil && m.agentInstallationStatus != nil && m.applicationInventory != nil, "Missing hydrated section")
            try check(m.sshAccountsLoaded && m.sshAccounts.count == 1 && m.sshListenerReady && m.accessState != nil, "SSH account section not hydrated")
            try check(m.ttlOutboundEnabled && m.ttlOutboundValue == "65" && m.ttlInboundIncrementEnabled && m.ttlInboundIncrementValue == "2", "TTL UI fields not hydrated")
            try check(m.sectionsUpdatedAt != nil && m.sectionRefreshErrors.isEmpty, "Completion not reflected")
        }
        try test("Information refresh preserves every unrelated section, its error and editor drafts") {
            let m = try model(); let chosen = selection(.ssh)
            m.acceptChannelSelection(chosen); m.acceptConnectionOverview(snapshot())
            m.moveDisplayMetric(.uptime, before: .cpu); let draft = m.displayLayout
            m.ttlOutboundValue = "117"; m.ttlInboundIncrementValue = "3"
            m.packagePreview = "preserved preview"; m.packagePreviewName = "fixture"
            m.sectionRefreshErrors = [.vpn: "earlier VPN error", .information: "earlier information error"]
            m.vpnError = "earlier VPN error"
            let value = ConnectionOverviewSnapshot(summary: summary, limitedToADB: false, sections: [.information], information: snapshot().information)
            m.acceptConnectionOverview(value)
            try check(m.modemInformation != nil && m.sectionRefreshErrors[.information] == nil, "Requested section not replaced")
            try check(m.displayInspection != nil && m.displaySavedLayout != nil && m.vpnInspection != nil && m.ttlStatus != nil && m.screenLocalizationStatus != nil && m.agentInstallationStatus != nil && m.applicationInventory != nil && m.accessState != nil, "Information refresh cleared a different section")
            try check(m.sshAccountsLoaded && m.sshAccounts.count == 1 && m.sshListenerReady, "Information refresh cleared SSH users")
            try check(m.displayLayout == draft && m.displayDraftEdited && m.ttlOutboundValue == "117" && m.ttlInboundIncrementValue == "3", "Information refresh replaced an unrelated editor draft")
            try check(m.packagePreview == "preserved preview" && m.packagePreviewName == "fixture" && m.vpnError == "earlier VPN error" && m.sectionRefreshErrors == [.vpn: "earlier VPN error"], "Information refresh cleared an unrelated result/error")
            try check(m.connected && m.channelSession === chosen.session && m.canManage, "Information refresh replaced verified connection")
        }
        try test("A failed scoped information refresh clears only its own stale result") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            m.sectionRefreshErrors[.agent] = "earlier agent error"
            m.acceptConnectionOverview(ConnectionOverviewSnapshot(summary: summary, limitedToADB: false, sections: [.information], errors: [.information: "fixture information failure"]))
            try check(m.modemInformation == nil && m.sectionRefreshErrors[.information] == "fixture information failure", "Scoped failure left stale information")
            try check(m.connected && m.canManage && m.agentInstallationStatus != nil && m.displayInspection != nil && m.accessState != nil && m.applicationInventory != nil && m.sectionRefreshErrors[.agent] == "earlier agent error", "Scoped failure erased unrelated data or disconnected")
        }
        try test("Reading IMEI preserves verified session, sections and drafts; identity drift is refused") {
            let m = try model(); let chosen = selection(.ssh)
            m.acceptChannelSelection(chosen); m.acceptConnectionOverview(snapshot())
            m.ttlOutboundValue = "117"
            let state = DeviceState(identity: identity, boot: boot, records: [], imeis: [imei, "490154203237526"])
            try m.acceptIMEIRead(state)
            try check(m.currentIMEI1 == imei && m.currentIMEI2 == state.imeis[1] && m.connected && m.channelSession === chosen.session, "IMEI read discarded the selected session")
            try check(m.modemInformation != nil && m.displayInspection != nil && m.applicationInventory != nil && m.ttlOutboundValue == "117", "IMEI read refreshed unrelated sections")
            for changed in [DeviceState(identity: identity, boot: UUID().uuidString, records: [], imeis: state.imeis),
                            DeviceState(identity: identity, boot: boot, records: [], imeis: [state.imeis[1], imei])] {
                var rejected = false
                do { try m.acceptIMEIRead(changed) } catch { rejected = true }
                try check(rejected && m.channelSession === chosen.session && m.currentIMEI1 == imei, "IMEI refresh accepted changed device identity/boot")
            }
        }
        try test("Information refresh refuses stale ADB state before any transport call") {
            let m = try model(); m.host = "invalid host for isolated test"
            m.channelSession = selection(.adb).session; m.activeChannel = .adb; m.connected = true
            m.acceptConnectionOverview(snapshot()); m.ttlOutboundValue = "117"
            m.refreshModemInformation(); m.startFirmwareResearch(); m.collectDiagnostics()
            try check(m.operationTask == nil && !m.busy && !m.canReadModem && !m.canResearchFirmware && !m.canCollectDiagnostics, "Stale ADB enabled ordinary modem work")
            try check(m.modemInformation != nil && m.ttlOutboundValue == "117", "Refused request erased unrelated state")
        }
        try test("Partial overview errors retain connection, good sections and user's launcher draft") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.moveDisplayMetric(.uptime, before: .cpu)
            let draft = m.displayLayout
            var value = snapshot(); value.display = nil; value.vpn = nil; value.errors = [.display: "unsupported screen", .vpn: "unknown controller"]
            m.acceptConnectionOverview(value)
            try check(m.connected && m.canManage && m.agentInstallationStatus?.running == true && m.modemInformation != nil, "Optional error disconnected modem")
            try check(m.displayLayout == draft && m.displayDraftEdited && m.displaySavedLayout == nil, "Read refresh replaced local draft")
            try check(m.displayError == "unsupported screen" && m.vpnError == "unknown controller" && m.sectionRefreshErrors.count == 2, "Optional error not exposed")
        }
        try test("Failed access refresh removes stale account and service status") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            var value = snapshot(); value.access = nil; value.errors[.access] = "access temporarily unavailable"
            m.acceptConnectionOverview(value)
            try check(m.connected && m.canManage, "Access error disconnected modem")
            try check(m.accessState == nil && m.sshAccounts.isEmpty && !m.sshAccountsLoaded && !m.sshListenerReady, "Failed refresh left stale access/account status")
        }
        try test("Connection invalidation clears all modem-specific sections, controls and identity") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            m.moveDisplayMetric(.uptime, before: .cpu); m.packagePreview = "stale preview"; m.packagePreviewName = "package"
            m.currentIMEI2 = "123456789012347"; m.sshRecoveryPending = true; m.sshRecoveryKind = .delete
            m.systemRestoreConfirmation = "stale confirmation"; m.preparationError = "old error"; m.diagnosticADBMessage = "old modem ADB ready"; m.connectionsChecked = true
            m.invalidateChannelConnection()
            try check(!m.connected && !m.accessReady && m.channelSession == nil && m.channelSummary == nil && m.activeChannel == nil, "Transport retained after invalidation")
            try check(m.connectedIdentity == nil && m.connectedIMEI == nil && m.connectedWebIdentity == nil && m.currentIMEI1.isEmpty && m.currentIMEI2.isEmpty && m.firmware.isEmpty, "Old identity retained")
            try check(m.modemInformation == nil && m.applicationInventory == nil && m.accessState == nil && m.agentInstallationStatus == nil && m.screenLocalizationStatus == nil && m.ttlStatus == nil && m.vpnInspection == nil && m.displayInspection == nil, "Old section retained")
            try check(m.displaySavedLayout == nil && m.displayLayout == .defaultLayout && !m.displayDraftEdited && m.displayError.isEmpty && m.vpnError.isEmpty, "Old launcher editor retained")
            try check(m.sshAccounts.isEmpty && !m.sshAccountsLoaded && !m.sshListenerReady && !m.sshRecoveryPending && m.sshRecoveryKind == .none, "Old SSH controls retained")
            try check(!m.ttlOutboundEnabled && m.ttlOutboundValue == "64" && !m.ttlInboundIncrementEnabled && m.ttlInboundIncrementValue == "1", "Old TTL form retained")
            try check(m.packagePreview.isEmpty && m.packagePreviewName.isEmpty && m.systemRestoreConfirmation.isEmpty && m.preparationError.isEmpty && m.diagnosticADBMessage.isEmpty && !m.connectionsChecked && m.channelStatuses.isEmpty && m.sectionsUpdatedAt == nil && m.sectionRefreshErrors.isEmpty, "Stale metadata retained")
        }
        try test("Connection loss clears device data while preserving local launcher draft") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            m.moveDisplayMetric(.uptime, before: .cpu); let draft = m.displayLayout
            m.markConnectionUnavailable("connection lost")
            try check(!m.connected && !m.canManage && m.connectionLabel == "Нет подключения" && m.modemInformation == nil, "Lost connection still available")
            try check(m.displayLayout == draft && m.displayDraftEdited && m.displaySavedLayout == nil, "User draft lost on transient connection failure")
            try check(m.connectedIdentity == identity && m.connectedIMEI == imei, "Retry target binding lost")
        }
        try test("Unsupported legacy modes cannot replace a working SSH session") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            m.channelStatuses.append(ConnectionChannelStatus(mode: .web, state: .authenticationRequired, message: "fixture")); m.connectionsChecked = true
            m.setConnectionMode(.adb)
            try check(m.connectionMode == .automatic && m.connected && m.modemInformation != nil && m.connectedIdentity == identity && m.connectedIMEI == imei, "Mode change lost target or active state not cleared")
            try check(m.connectionsChecked && m.isStockWebAvailable, "Mode change discarded discovery")
            m.setConnectionMode(.web); try check(m.connectionMode == .automatic, "Web selectable as full connection")
            m.setConnectionMode(.agent); try check(m.connectionMode == .automatic, "Agent selectable as full connection")
        }
        try test("Persisted legacy Web agent and ADB modes migrate to SSH policy") {
            for mode in [ConnectionMode.web, .agent, .ssh, .adb] {
                let m = try model(); try secureDirectory(m.storage)
                try saveJSON(mode, m.storage.appendingPathComponent("connection-mode.json"))
                let reopened = AppModel()
                try check(reopened.connectionMode == (mode == .ssh ? .ssh : .automatic), "Legacy mode migration incorrect")
                try check(!reopened.connected && reopened.activeChannel == nil, "Relaunch fabricated connection")
            }
        }
        try test("Connection monitor rejects a result spanning an entire foreground operation") {
            let m = try model(); let chosen = selection(.ssh)
            m.acceptChannelSelection(chosen)
            let session = chosen.session!, generation = m.connectionActivityGeneration
            try check(m.canAcceptConnectionCheck(session, generation: generation), "Current idle check incorrectly rejected")
            m.busy = true
            try check(!m.canAcceptConnectionCheck(session, generation: generation), "Check accepted during foreground operation")
            m.busy = false
            try check(m.connected && m.channelSession === session && m.connectionActivityGeneration != generation, "Operation activity not tracked independently of session")
            try check(!m.canAcceptConnectionCheck(session, generation: generation), "Old result accepted after busy returned to false")
            try check(m.canAcceptConnectionCheck(session, generation: m.connectionActivityGeneration), "Fresh result rejected after operation")
        }
        try test("Connection monitor rejects replaced session and explicit disconnect") {
            let m = try model(); let first = selection(.ssh), replacement = selection(.ssh)
            m.acceptChannelSelection(first); let generation = m.connectionActivityGeneration
            m.acceptChannelSelection(replacement)
            try check(!m.canAcceptConnectionCheck(first.session!, generation: generation), "Same-device replacement accepted result from old session")
            try check(m.canAcceptConnectionCheck(replacement.session!, generation: m.connectionActivityGeneration), "Replacement session rejected")
            m.markConnectionUnavailable("unplugged")
            try check(!m.canAcceptConnectionCheck(replacement.session!, generation: m.connectionActivityGeneration), "Late check can resurrect lost connection")
        }
        try test("Verified active session repairs transient discovery status without switching channels") {
            let m = try model(); let chosen = selection(.ssh)
            m.acceptChannelSelection(chosen)
            m.mergeChannelStatuses([
                ConnectionChannelStatus(mode: .ssh, state: .unavailable, message: "transient discovery timeout"),
                ConnectionChannelStatus(mode: .web, state: .authenticationRequired, message: "Web password required")
            ])
            try check(m.channelStatuses.first(where: { $0.mode == .ssh })?.state == .unavailable, "Fixture not applied")
            var fresh = summary; fresh.fields["model"] = "ZTE MU5250"
            m.acceptChannelSummary(fresh)
            let status = m.channelStatuses.first(where: { $0.mode == .ssh })
            try check(status?.state == .available && status?.summary == fresh, "Verified connection did not replace stale discovery failure")
            try check(m.connected && m.channelSession === chosen.session && m.activeChannel == .ssh && m.canManage, "Status reconciliation switched or lost channel")
            try check(m.channelStatuses.first(where: { $0.mode == .web })?.state == .authenticationRequired, "Unrelated discovery overwritten")
            m.markConnectionUnavailable("unplugged"); m.acceptChannelSummary(fresh)
            try check(!m.connected && m.activeChannel == nil && !m.canManage, "Summary alone created connection after loss")
        }
        try test("Application tabs use individual modem state and do not invent absence on errors") {
            let m = try model()
            try check(ApplicationSection.allCases.map(\.rawValue) == ["Установлено", "Каталог", "Terminal"], "Applications tabs are not distinct")
            try check(!m.applicationsFullyChecked && m.installedApplicationCount == 0, "Unknown applications treated as fully checked")
            var inventory = snapshot().applications!
            inventory.ssclashInstalled = false; inventory.ssclashRunning = false
            inventory.managedAppsChecked = true
            let bundleID = String(repeating: "b", count: 64)
            inventory.diagnosticTools = .init(active: bundleID, previous: nil, canRollback: true, running: false, freeKiB: 100000, selected: ["htop"])
            inventory.experimentalOpkg = .init(installed: false, packages: [], freeKiB: 100000, canRollback: false, generation: nil, previous: nil, running: false)
            m.acceptApplicationInventory(inventory)
            try check(m.applicationsFullyChecked && m.installedApplicationCount == 1, "Individual htop installation appeared as whole set")
            try check(m.diagnosticToolsStatus?.isInstalled("htop") == true && m.diagnosticToolsStatus?.isInstalled("mtr") == false, "Wrong per-card installed state")
            inventory.ssclashUnmanaged = true; m.acceptApplicationInventory(inventory)
            try check(!m.applicationsFullyChecked && m.installedApplicationCount == 1, "Partial SSClash folder was counted as installed")
            inventory.ssclashUnmanaged = false
            inventory.diagnosticTools = nil; inventory.managedAppErrors["diagnostics"] = "fixture inspection failed"
            m.acceptApplicationInventory(inventory)
            try check(!m.applicationsFullyChecked && m.diagnosticToolsStatus == nil && m.diagnosticToolsError.contains("inspection failed"), "Failed inventory kept stale installation or claimed absence")
            m.acceptChannelSelection(selection(.adb, requested: .adb))
            m.installDiagnosticTool("htop"); m.installExperimentalOpkg(); m.refreshExperimentalOpkg()
            try check(m.operationTask == nil && !m.busy && !m.canUseOpkgConsole, "ADB enabled application mutation or opkg console")
        }
        try test("opkg console refuses shell input and forgets device state on disconnect") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh))
            m.experimentalOpkgStatus = .init(installed: true, packages: [.init(name: "nano", version: "7.2")], freeKiB: 100000, canRollback: true,
                                            generation: "g-11111111-2222-3333-4444-555555555555", previous: nil, running: false)
            try check(m.canUseOpkgConsole, "Verified SSH did not enable console")
            m.opkgCommand = "opkg install nano; reboot"; m.runOpkgCommand()
            try check(m.operationTask == nil && !m.busy && m.opkgTranscript.contains("Ошибка"), "Shell metacharacters reached transport")
            m.opkgHistory = ["opkg list-installed"]
            m.markConnectionUnavailable("fixture disconnected")
            try check(m.experimentalOpkgStatus == nil && m.opkgTranscript.isEmpty && m.opkgHistory.isEmpty && !m.canUseOpkgConsole, "Disconnected console retained wrong-device state")
        }
        try test("Diagnostic tools require prepared SSH state and clear after disconnect") {
            let m = try model(), bundleID = String(repeating: "c", count: 64)
            let state = DiagnosticToolsStatus(active: nil, previous: nil, canRollback: false, running: false, freeKiB: 100000)
            m.diagnosticToolsStatus = state
            m.diagnosticToolsPlan = DiagnosticToolsPlan(identity: identity, bootID: boot, before: state, bundleID: bundleID)
            try check(!m.canInstallDiagnosticTools, "Disconnected diagnostic install allowed")
            m.acceptChannelSelection(selection(.ssh))
            try check(m.canInstallDiagnosticTools, "Verified plan/SSH cannot install")
            m.busy = true; try check(!m.canInstallDiagnosticTools, "Busy install allowed"); m.busy = false
            m.markConnectionUnavailable("fixture unplugged")
            try check(m.diagnosticToolsStatus == nil && m.diagnosticToolsPlan == nil && !m.canInstallDiagnosticTools, "Stale diagnostic plan survived disconnect")
            m.connectionMode = .adb; m.acceptChannelSelection(selection(.adb))
            m.diagnosticToolsStatus = DiagnosticToolsStatus(active: bundleID, previous: nil, canRollback: true, running: false, freeKiB: 100000)
            m.prepareDiagnosticTools(); m.refreshDiagnosticTools(); m.removeDiagnosticTools(); m.rollbackDiagnosticTools()
            try check(m.operationTask == nil && !m.busy, "ADB diagnostic app management contacted a transport")
        }
        try test("Open manual terminal blocks managed writes and clears sensitive drafts on target change") {
            let m = try model(); m.acceptChannelSelection(selection(.ssh)); m.acceptConnectionOverview(snapshot())
            m.terminalActive = true
            m.opkgCommand = "private command draft"
            m.opkgFeedsDraft = "src/gz local https://example.invalid/packages"
            m.terminalError = "fixture"
            try check(!m.canManage && !m.canPrepareModem && !m.canApply && !m.canReadModem && !m.canUseSystemBackupConnection && !m.canExecuteSystemRestore, "Terminal allowed conflicting managed mutations")
            m.installVPN(); m.installDisplay(); m.installExperimentalOpkg(); m.saveOpkgFeeds(); m.readIMEI()
            try check(m.operationTask == nil && !m.busy, "Managed operation escaped terminal guard")
            m.closeTerminal()
            try check(!m.terminalActive && m.canManage, "Closing terminal did not restore controls")
            m.markConnectionUnavailable("fixture disconnect")
            try check(!m.terminalSession.active && m.opkgCommand.isEmpty && m.opkgFeeds == nil && m.opkgFeedsDraft.isEmpty && m.terminalError.isEmpty, "Disconnect retained terminal/device drafts")
        }
        print("PASS ConnectionAppModelTests \(count) groups")
    }
}
