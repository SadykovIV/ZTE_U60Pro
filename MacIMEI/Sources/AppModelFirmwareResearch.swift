import AppKit
import UniformTypeIdentifiers

@MainActor extension AppModel {
    var canResearchFirmware: Bool { canReadModem }
    func loadFirmwareResearch() {
        guard !firmwareResearchLoaded else { return }; firmwareResearchLoaded = true
        firmwareResearchReport = try? FirmwareResearchArchive.latest(root: storage)
    }
    func cancelFirmwareResearch() {
        firmwareResearchCancellation?.cancel()
        firmwareResearchMessage = L10n.text("Останавливаю сбор; уже полученные сведения будут сохранены.", "Stopping collection; evidence already collected will be retained.")
    }
    func startFirmwareResearch() {
        guard canResearchFirmware else { return }
        let root = storage, assets = resources, config = connection, mode = ConnectionMode.ssh
        let expectedCID = channelSession?.summary.observedCID ?? connectedReadCID ?? modemInformation?.identity?.cid ?? connectedIdentity?.cid
        let secrets = [webPassword, agentPassword, backupSuffix, sshPassword, currentIMEI1, currentIMEI2, imei1, imei2, connectedIMEI ?? ""]
        let context = ["appVersion": appVersion, "appBuild": DiagnosticsContext.build, "platform": "macos", "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
                       "requestedConnectionMode": mode.rawValue, "previouslyConnected": String(connected),
                       "SSHKeyConfigured": String(FileManager.default.isReadableFile(atPath: keyPath)),
                       "knownHostsConfigured": String(FileManager.default.isReadableFile(atPath: knownHostsPath)),
                       "writePermissionGrantedByResearch": "false", "firmwareCheckSkipped": String(skipFirmwareCheck), "probeSpecificationSHA256": ResearchSpecification.expectedSHA256]
        let token = ResearchCancellation(); firmwareResearchCancellation = token
        firmwareResearchRunning = true; firmwareResearchProgress = 0; firmwareResearchExportURL = nil; busy = true
        firmwareResearchMessage = L10n.text("Проверяю подключение SSH для чтения…", "Checking the SSH connection for read-only collection…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await Task.detached(priority: .userInitiated) { [weak self] () -> FirmwareResearchReport in
                    let spec = try ResearchSpecification.load(assets)
                    let collector = FirmwareResearchCollector(specification: spec, connection: config, mode: mode, resources: assets, cancellation: token, expectedCID: expectedCID, secrets: secrets)
                    // Only a host lock: no modem directory/lock or setup operation is created.
                    let lockURL = root.appendingPathComponent("operation.lock")
                    let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
                    try require(fd >= 0, "Cannot open operation lock")
                    defer { close(fd) }
                    try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "Another application instance is operating on the modem")
                    defer { flock(fd, LOCK_UN) }
                    let report = collector.collect(context: context) { partial, fraction in
                        Task { @MainActor [weak self] in
                            self?.firmwareResearchReport = partial; self?.firmwareResearchProgress = fraction
                            if let probe = partial.probes.last { self?.firmwareResearchMessage = probe.title.text(L10n.language) + " · " + ResearchUI.outcome(probe.outcome) }
                        }
                    }
                    _ = try FirmwareResearchArchive.save(report, root: root)
                    return report
                }.value
                firmwareResearchReport = report; firmwareResearchProgress = 1
                firmwareResearchMessage = ResearchUI.outcome(report.outcome)
            } catch { firmwareResearchMessage = L10n.text("Сбор не начался: ", "Collection could not start: ") + ActivityJournal.sanitize(error.localizedDescription) }
            firmwareResearchRunning = false; firmwareResearchCancellation = nil; busy = false; operationTask = nil
        }
    }
    func exportFirmwareResearch() {
        guard !busy, let report = firmwareResearchReport else { return }
        let panel = NSSavePanel(); panel.title = L10n.text("Экспорт исследования прошивки", "Export firmware research")
        panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "ZTE-Firmware-Research-" + String(report.startedAt.prefix(10)) + ".zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) { try FirmwareResearchArchive.export(report, to: destination) }.value
                firmwareResearchExportURL = destination
                firmwareResearchMessage = L10n.text("ZIP сохранён и проверен. Пароли, ключи и содержимое NV/EFS не включены.", "ZIP saved and verified. Passwords, keys and NV/EFS contents are excluded.")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { firmwareResearchMessage = L10n.text("Экспорт не завершён: ", "Export failed: ") + ActivityJournal.sanitize(error.localizedDescription) }
            busy = false; operationTask = nil
        }
    }
}
