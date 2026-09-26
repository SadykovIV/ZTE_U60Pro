import Foundation

@MainActor extension AppModel {
    var displayLayoutChanged: Bool { displaySavedLayout != displayLayout }

    func clearDisplayLayout() {
        displayLayout = .defaultLayout; displaySavedLayout = nil
        displayLayoutMessage = ""; displayDraftEdited = false
    }
    func resetDisplayLayout() {
        guard !busy else { return }
        displayLayout = .defaultLayout; displayDraftEdited = true; displayLayoutMessage = ""
    }
    func setDisplayStyle(_ style: ModemDisplayPageStyle) {
        guard !busy, displayLayout.style != style else { return }
        displayLayout.style = style
        displayDraftEdited = true; displayLayoutMessage = ""
    }
    func setDisplayMetric(_ metric: ModemDisplayMetric, enabled: Bool) {
        guard !busy, let index = displayLayout.items.firstIndex(where: { $0.metric == metric }),
              displayLayout.items[index].enabled != enabled else { return }
        if !enabled && displayLayout.enabledCount <= 1 {
            displayLayoutMessage = "Оставьте хотя бы один показатель."
            return
        }
        displayLayout.items[index].enabled = enabled
        displayDraftEdited = true; displayLayoutMessage = ""
    }
    func moveDisplayMetric(_ metric: ModemDisplayMetric, before target: ModemDisplayMetric?) {
        guard !busy, metric != target,
              let source = displayLayout.items.firstIndex(where: { $0.metric == metric }),
              target == nil || displayLayout.items.contains(where: { $0.metric == target }) else { return }
        let item = displayLayout.items.remove(at: source)
        let destination = target.flatMap { target in displayLayout.items.firstIndex(where: { $0.metric == target }) } ?? displayLayout.items.endIndex
        displayLayout.items.insert(item, at: destination)
        displayDraftEdited = true; displayLayoutMessage = ""
    }

    func refreshDisplay() { performDisplay(.inspect) }
    func installDisplay() { performDisplay(.install) }
    func applyDisplayLayout() { performDisplay(.apply) }

    private enum DisplayOperation { case inspect, install, apply }
    private func performDisplay(_ operation: DisplayOperation) {
        guard canManage else { return }
        let config = connection, root = storage, assets = resources, target = sshSelectionContext
        let layout = displayLayout, keepDraft = displayDraftEdited
        if operation != .inspect {
            do { try layout.validate() }
            catch { displayError = error.localizedDescription; return }
        }
        busy = true; progress = 0; displayError = ""; displayLayoutMessage = ""
        switch operation {
        case .inspect: append("Проверяю дисплей и читаю настройки плитки…")
        case .install: append("Устанавливаю плитки с выбранными показателями…")
        case .apply: append("Сохраняю оформление, состав и порядок показателей на модеме…")
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let engine = try ModemEngine(root: root, resources: assets, connection: config) { [weak self] message, value in
                        Task { @MainActor [weak self] in self?.append(message, progress: value) }
                    }
                    return try engine.locked {
                        try target.verify(engine)
                        let manager = ModemDisplayManager(engine: engine)
                        switch operation {
                        case .inspect: return try manager.inspect()
                        case .install: return try manager.install(layout: layout)
                        case .apply: return try manager.applyLayout(layout)
                        }
                    }
                }.value
                displayInspection = value; displaySavedLayout = value.layout
                if operation != .inspect || !keepDraft {
                    displayLayout = value.layout ?? .defaultLayout
                    displayDraftEdited = false
                }
                if operation == .inspect && keepDraft && displayLayoutChanged {
                    displayLayoutMessage = "Настройки модема прочитаны. Ваши изменения сохранены в редакторе; нажмите кнопку применения, чтобы записать их."
                }
                append(value.detail, progress: 1)
            } catch {
                displayError = error.localizedDescription
                displayInspection = nil; displaySavedLayout = nil
                append("Дисплей: " + error.localizedDescription)
            }
            busy = false; refreshActivity(); operationTask = nil
        }
    }
}
