import Foundation

@MainActor extension AppModel {
    var displayLayoutChanged: Bool { displaySavedLayout != displayLayout }
    var displayPagesChanged: Bool { displaySavedPages != displayPages }
    var displayPageRows: [ModemLauncherPage] {
        displayPages.pages + ModemLauncherPage.allCases.filter { !displayPages.pages.contains($0) }
    }

    func clearDisplayLayout() {
        displayLayout = .defaultLayout; displaySavedLayout = nil
        displayLayoutMessage = ""; displayDraftEdited = false
        displayPages = .defaultPages; displaySavedPages = nil
        displayPagesMessage = ""; displayPagesDraftEdited = false
    }
    func setDisplayPage(_ page: ModemLauncherPage, enabled: Bool) {
        guard !busy, displayPages.pages.contains(page) != enabled else { return }
        if enabled { displayPages.pages.append(page) }
        else { displayPages.pages.removeAll { $0 == page } }
        displayPagesDraftEdited = true; displayPagesMessage = ""
    }
    func moveDisplayPage(_ page: ModemLauncherPage, by offset: Int) {
        guard !busy, [-1, 1].contains(offset), let index = displayPages.pages.firstIndex(of: page),
              displayPages.pages.indices.contains(index + offset) else { return }
        displayPages.pages.swapAt(index, index + offset)
        displayPagesDraftEdited = true; displayPagesMessage = ""
    }
    func receiveDisplayInspection(_ value: ModemDisplayInspection, appliedLayout: Bool = false, appliedPages: Bool = false) {
        displayInspection = value; displaySavedLayout = value.layout; displaySavedPages = value.pages
        if appliedLayout || !displayDraftEdited {
            displayLayout = value.layout ?? .defaultLayout; displayDraftEdited = false
        }
        if appliedPages || !displayPagesDraftEdited {
            displayPages = value.pages ?? .defaultPages; displayPagesDraftEdited = false
        }
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
    func installEsimDisplay() { performDisplay(.installEsim) }
    func applyDisplayLayout() { performDisplay(.apply) }
    func applyDisplayPages() { performDisplay(.applyPages) }
    var canInstallEsimDisplay: Bool { canManage && !skipFirmwareCheck && !esimPreview }

    private enum DisplayOperation { case inspect, install, installEsim, apply, applyPages }
    private func performDisplay(_ operation: DisplayOperation) {
        guard canManage else { return }
        if operation == .installEsim && !canInstallEsimDisplay { return }
        let config = connection, root = storage, assets = resources, target = sshSelectionContext
        let layout = displayLayout, pages = displayPages, keepDraft = displayDraftEdited, keepPagesDraft = displayPagesDraftEdited
        if operation == .install || operation == .apply {
            do { try layout.validate() }
            catch { displayError = error.localizedDescription; return }
        }
        do { try pages.validate() } catch { displayError = error.localizedDescription; return }
        busy = true; progress = 0; displayError = ""; displayLayoutMessage = ""; displayPagesMessage = ""
        switch operation {
        case .inspect: append("Проверяю дисплей и читаю настройки плитки…")
        case .install: append("Устанавливаю выбранные страницы и показатели…")
        case .installEsim:
            esimAuthorization = nil
            append("Устанавливаю страницу eSIM с сохранением страниц и настроек Launcher…")
        case .apply: append("Сохраняю оформление, состав и порядок показателей на модеме…")
        case .applyPages: append("Сохраняю выбранные страницы и их порядок…")
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
                        case .install: return try manager.install(layout: layout, pages: pages)
                        case .installEsim: return try manager.installEsimPage()
                        case .apply: return try manager.applyLayout(layout)
                        case .applyPages: return try manager.applyPages(pages)
                        }
                    }
                }.value
                receiveDisplayInspection(value, appliedLayout: operation == .install || operation == .apply,
                                         appliedPages: operation == .install || operation == .applyPages)
                if operation == .inspect && keepDraft && displayLayoutChanged {
                    displayLayoutMessage = "Настройки модема прочитаны. Ваши изменения сохранены в редакторе; нажмите кнопку применения, чтобы записать их."
                }
                if (operation == .inspect || operation == .installEsim) && keepPagesDraft && displayPagesChanged {
                    displayPagesMessage = "Порядок страниц модема прочитан. Ваш несохранённый выбор оставлен в редакторе."
                }
                if operation == .installEsim {
                    displayLayoutMessage = "Страница eSIM установлена и добавлена в конец, если её не было. Прежний порядок страниц, раскладка и настройки VPN сохранены."
                    if keepDraft { displayLayoutMessage += " Несохранённые изменения в редакторе не применялись." }
                }
                append(value.detail, progress: 1)
            } catch {
                displayError = error.localizedDescription
                displayInspection = nil; displaySavedLayout = nil; displaySavedPages = nil
                append("Дисплей: " + error.localizedDescription)
            }
            busy = false; refreshActivity(); operationTask = nil
        }
    }
}
