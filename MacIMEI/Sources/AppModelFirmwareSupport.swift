import AppKit
import UniformTypeIdentifiers

@MainActor extension AppModel {
    var canCollectFirmwareSupport: Bool {
        canReadModem && channelSession?.mode == .ssh && channelSession?.diagnosticSession != nil &&
            channelSession?.sshEndpoint == ConnectionRouter.sshEndpoint(connection)
    }

    func firmwareSupportSelectionMatches(_ expected: Connection, session: ReadOnlyChannelSession) -> Bool {
        connected && activeChannel == .ssh && channelSession === session && host == expected.host && port == expected.port &&
            keyPath == expected.keyPath && knownHostsPath == expected.knownHostsPath
    }

    func collectFirmwareSupport() {
        guard canCollectFirmwareSupport, let session = channelSession else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("Сохранить данные для адаптации прошивки")
        panel.allowedContentTypes = [.zip]
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "ZTE-Firmware-Support-" + date + ".zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let config = connection, root = storage, assets = resources
        let secrets = [webPassword, agentPassword, backupSuffix, sshPassword, currentIMEI1, currentIMEI2, imei1, imei2, connectedIMEI ?? ""]
        let cancellation = ResearchCancellation()
        busy = true; progress = 0; firmwareSupportExportURL = nil; firmwareSupportExportSummary = ""
        append("Собираю данные для адаптации прошивки…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) { [weak self] in
                        let collector = try FirmwareSupportCollector(root: root, resources: assets, connection: config, session: session, secrets: secrets, selectionIsCurrent: { [weak self] in
                            DispatchQueue.main.sync { self?.firmwareSupportSelectionMatches(config, session: session) ?? false }
                        }) { [weak self] message, fraction in
                            Task { @MainActor [weak self] in self?.append(message, progress: fraction) }
                        }
                        return try collector.collect(to: destination, cancelled: { cancellation.cancelled })
                    }.value
                } onCancel: { cancellation.cancel() }
                firmwareSupportExportURL = result.url
                firmwareSupportExportSummary = result.complete ? "Данные для адаптации сохранены. Файлы и свежий технический отчёт проверены." : "Сохранён неполный архив. Причины и недостающие данные указаны в metadata.json и research/REPORT.md."
                append(firmwareSupportExportSummary, progress: 1)
                try? ActivityJournal(root: root).record(operationID: sessionID, category: "firmware-support", title: "Сбор данных для адаптации прошивки", result: result.complete ? "completed" : "incomplete", details: ["archiveSHA256": result.sha256, "files": String(result.fileCount), "missingRequired": String(result.omissions)])
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            } catch {
                firmwareSupportExportSummary = "Сбор данных для адаптации не завершён: " + error.localizedDescription
                append(firmwareSupportExportSummary)
                try? ActivityJournal(root: root).record(operationID: sessionID, category: "firmware-support", title: "Сбор данных для адаптации прошивки", result: "failed")
            }
            busy = false; operationTask = nil; refreshActivity()
        }
    }
}
