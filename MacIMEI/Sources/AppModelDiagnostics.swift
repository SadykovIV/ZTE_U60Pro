import AppKit
import UniformTypeIdentifiers

@MainActor extension AppModel {
    var canReadModem: Bool { !busy && !terminalActive && connected && activeChannel == .ssh && permitsSSHOperations && !host.isEmpty && !keyPath.isEmpty && !knownHostsPath.isEmpty }
    var canCollectDiagnostics: Bool { !busy && connected && (activeChannel == .ssh || activeChannel == .adb) && !host.isEmpty }
    func recordNavigation(_ title: String) {
        do { try ActivityJournal(root: storage).record(operationID: sessionID, category: "navigation", title: title, result: "message") }
        catch { journalWarning = "Не удалось сохранить переход в журнал: " + error.localizedDescription }
    }
    func exportDiagnostics(collectFresh: Bool) {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Сохранить диагностический ZIP"
        panel.allowedContentTypes = [.zip]
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "ZTE-Diagnostics-" + date + ".zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let config = connection, root = storage, assets = resources
        let expectedIdentity = modemInformation?.identity ?? connectedIdentity
        let mode = activeChannel ?? connectionMode, session = channelSession, expectedWeb = connectedWebIdentity ?? channelSummary?.webIdentity
        let expectedIMEI = connectedIMEI ?? channelSummary?.primaryIMEI
        let webSecret = webPassword, agentSecret = agentPassword
        let context = ["appVersion": appVersion, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                       "architecture": "arm64", "endpoint": config.host + ":" + config.port,
                       "connected": String(connected), "firmwareCheckSkipped": String(skipFirmwareCheck),
                       "pendingIMEIOperation": String(pendingOperation), "pendingSetup": String(setupPending),
                       "sessionID": sessionID, "freshCollectionRequested": String(collectFresh), "connectionMode": mode.rawValue,
                       "latestDisplayedReportID": diagnosticReport?.id ?? "none",
                       "sshKeyPresent": String(FileManager.default.fileExists(atPath: keyPath)),
                       "knownHostsPresent": String(FileManager.default.fileExists(atPath: knownHostsPath))]
        busy = true; progress = 0
        append(collectFresh ? "Собираю свежую диагностику для ZIP…" : "Готовлю ZIP из сохранённых журналов…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await Task.detached(priority: .userInitiated) { [weak self] () -> (DiagnosticArchiveResult, DiagnosticReport?) in
                    var context = context, report: DiagnosticReport?
                    if collectFresh {
                        do {
                            let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                                Task { @MainActor [weak self] in self?.append(message, progress: value * 0.85) }
                            }
                            report = try engine.locked { try ConnectionDiagnostics.collect(engine: engine, mode: mode, session: session,
                                expectedIdentity: expectedIdentity, expectedWebIdentity: expectedWeb, expectedIMEI: expectedIMEI, webPassword: webSecret, agentPassword: agentSecret) }
                            context["freshReportID"] = report?.id
                            context["freshReportSummary"] = report?.outcomeSummary
                            context["freshReportTransport"] = report?.transport
                            context["freshReportSelectionReason"] = report?.selectionReason
                            context["freshReportIdentityVerified"] = report.map { String($0.identityVerified == true) }
                        } catch {
                            context["freshCollectionError"] = ActivityJournal.redact(error.localizedDescription)
                            try? ActivityJournal(root: root).record(operationID: DiagnosticsContext.sessionID, category: "diagnostics", title: "Свежая диагностика недоступна; экспорт сохранённых данных", result: "warning", details: ["error": error.localizedDescription])
                        }
                    }
                    return (try DiagnosticArchive(root: root).export(to: destination, context: context), report)
                }.value
                if let report = value.1 {
                    diagnosticReport = report; selectedDiagnostic = report.files.first?.name ?? ""; loadDiagnosticText()
                }
                diagnosticExportURL = value.0.url
                let collectionIssues = collectFresh && (value.1 == nil || value.1?.files.contains(where: { $0.effectiveOutcome != .succeeded }) == true || value.1?.warnings?.isEmpty == false)
                diagnosticExportSummary = "ZIP проверен: \(value.0.fileCount) файлов." +
                    (value.0.warnings > 0 ? " Пропуски и сокращения: \(value.0.warnings), подробности в manifest.json." : "") +
                    (collectionIssues ? " Диагностика модема неполная; причины включены в архив." : "")
                append(diagnosticExportSummary, progress: 1)
                try? ActivityJournal(root: storage).record(operationID: sessionID, category: "export", title: "Диагностический ZIP сохранён", result: "completed", details: ["archiveSHA256": value.0.sha256, "files": String(value.0.fileCount), "warnings": String(value.0.warnings)])
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { append("Экспорт не завершён: " + error.localizedDescription) }
            busy = false; operationTask = nil; refreshActivity()
        }
    }
}
