import AppKit
import SwiftUI

/// Renders the production desktop views with synthetic data and a disconnected
/// model. The wrapper script redirects all model storage into a temporary tree.
@main struct ManagerUIPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()
        let size = NSSize(width: 1280, height: 900)
        let model = AppModel()
        // Deliberately disconnected: entering Terminal must never start SSH.
        model.host = "192.0.2.1"
        model.keyPath = "/preview/SSH/id_ed25519"
        model.knownHostsPath = "/preview/SSH/known_hosts"
        model.connectionsChecked = true // Suppress the preparation screen's passive discovery.
        model.firmwareResearchLoaded = true // Never load real diagnostics in a synthetic preview.
        model.channelStatuses = ConnectionMode.discoveryOrder.map {
            ConnectionChannelStatus(mode: $0, state: .notChecked, message: "")
        }
        precondition(!model.connected && !model.canManage)
        precondition(PreparationSection.allCases.map(\.rawValue) == ["Настройка подключения", "Диагностика", "Установка агента", "Русификация"])
        precondition(ModemSection.allCases.map(\.rawValue) == ["Об устройстве", "Память"])
        precondition(AdministrationSection.allCases.last == .activity)
        model.loadEsimPreview(force: true)
        let previewSnapshot = model.esimSnapshot
        model.agentInstallationStatus = AgentInstallationStatus(hash: BundledAgent.sha256, running: true, startupReady: true)
        model.applicationInventory = .init(storage: [], memoryTotalKiB: 1048576,
            memoryAvailableKiB: 512000, installedPackages: [], opkgWritable: false,
            ssclashInstalled: false, ssclashRunning: false, architecture: "aarch64", release: "23.05.4",
            applicationStorage: .init(totalKiB: 2097152, availableKiB: 1700000, managedUsedKiB: 68400), managedAppsChecked: true)
        model.diagnosticToolsStatus = .init(active: nil, previous: nil, canRollback: false,
            running: false, freeKiB: 1700000, selected: [])
        model.experimentalOpkgStatus = .init(installed: false, packages: [], freeKiB: 1700000,
            canRollback: false, generation: nil, previous: nil, running: false)
        let catalog = VerifiedCatalogStore(cacheURL: model.storage.appendingPathComponent("catalog-preview.json"))
        precondition(catalog.entries.map(\.id) == ["htop", "opkg"])
        var paths: [String] = []
        var syntheticResearch = FirmwareResearchReport(startedAt: "2026-09-27T12:00:00Z", finishedAt: "2026-09-27T12:02:08Z", specificationRevision: 7, transport: "ssh", outcome: "partial", profile: nil,
            attempts: [.init(transport: "ssh", outcome: "available", detail: "Synthetic SSH fixture; no modem access")],
            warnings: ["Synthetic report; no modem access"],
            features: [
                .init(id: "agent", title: .init(ru: "Установка агента и SSH", en: "Agent and SSH installation"), state: "prerequisites_met", evidence: [.init(ru: "Права root: выполнено", en: "Root privilege: met")], limitations: .init(ru: "Установка не выполнялась. Результат не даёт разрешения на запись.", en: "No installation was performed. This finding grants no write permission.")),
                .init(id: "imei", title: .init(ru: "Изменение IMEI", en: "IMEI changes"), state: "unknown", evidence: [.init(ru: "Нет совпадения с проверенным профилем прошивки", en: "No matching verified firmware profile")], limitations: .init(ru: "NV/EFS не читаются и не меняются исследованием.", en: "Research does not read or change NV/EFS contents.")),
                .init(id: "vpn", title: .init(ru: "Компоненты VPN", en: "VPN components"), state: "blocked", evidence: [.init(ru: "Требуемая функция ядра: не выполнено", en: "Required kernel feature: not met")], limitations: .init(ru: "Сетевая конфигурация не менялась.", en: "Network configuration was not changed."))], application: ["fixture": "synthetic; no modem access"])
        syntheticResearch.bindingStrength = "transport-only"
        syntheticResearch.authorization = "none"
        syntheticResearch.observations = [
                .init(id: "architecture", title: .init(ru: "Архитектура", en: "Architecture"), probe: "identity", fact: "architecture", state: "known", value: "aarch64", sourceStatus: "success", sourceExitCode: 0),
                .init(id: "init", title: .init(ru: "Система запуска", en: "Init system"), probe: "init-runtime", fact: "init_comm", state: "known", value: "procd", sourceStatus: "success", sourceExitCode: 0),
                .init(id: "hasher", title: .init(ru: "SHA-256", en: "SHA-256"), probe: "fingerprint", fact: "hasher", state: "known", value: "busybox-sha256sum", sourceStatus: "success", sourceExitCode: 0),
                .init(id: "esim", title: .init(ru: "Интерфейс eSIM", en: "eSIM interface"), probe: "esim-components", fact: "esim_controller", state: "not-assessed", value: nil, sourceStatus: "skipped", reason: "No verified service schema")]

        for language in ["ru", "en"] {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language], forName: UserDefaults.argumentDomain)
            precondition(L10n.language == language)
            let screens: [(String, AnyView)] = [
                ("preparation", AnyView(ContentView(model: model, verifiedCatalog: catalog))),
                ("connection-methods", AnyView(ContentView(model: model, verifiedCatalog: catalog, connectionMethodsExpanded: true))),
                ("diagnostics", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationSection: .diagnostics))),
                ("preparation-credentials", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationCredentialsExpanded: true))),
                ("journal", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .administration, administrationSection: .activity))),
                ("administration", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .administration))),
                ("modem", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .modem))),
                ("agent-esim", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationSection: .agent))),
                ("esim", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .esim))),
                ("esim-ordinary", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .esim))),
                ("launcher-esim", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .display, launcherSection: .esim))),
                ("esim-progress", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .esim))),
                ("catalog", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .applications, applicationSection: .available))),
                ("terminal", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .applications, applicationSection: .opkg))),
                ("firmware-research-empty", AnyView(ZStack { StudioStyle.canvas; VStack(alignment: .leading, spacing: 18) { Text(L10n.text("Подготовка модема · Диагностика", "Modem preparation · Diagnostics")).font(.title2); ContentView(model: model, verifiedCatalog: catalog).firmwareResearchCard; Spacer() }.padding(36) })),
                ("firmware-research-result", AnyView(ZStack { StudioStyle.canvas; VStack(alignment: .leading, spacing: 18) { Text(L10n.text("Исследование прошивки · Пример отчёта", "Firmware research · Sample report")).font(.title2); ContentView(model: model, verifiedCatalog: catalog).firmwareResearchCard; Spacer() }.padding(36) })),
                ("about", AnyView(ZStack {
                    StudioStyle.canvas
                    ContentView(model: model, verifiedCatalog: catalog).aboutSheet
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioStyle.line))
                }))
            ]
            let filter = ProcessInfo.processInfo.environment["ZTE_UI_PREVIEW_FILTER"]
            for (screen, rootView) in screens where filter == nil || screen.hasPrefix(filter!) {
                model.esimSnapshot = screen == "esim-ordinary" ? nil : previewSnapshot
                model.esimCard = screen == "esim-ordinary" ? try JSONDecoder().decode(EsimCardCheck.self, from: Data(#"{"kind":"ordinary_sim","management":"unavailable","reason":"isdr_not_found","cleanup_confirmed":true}"#.utf8)) : nil
                model.esimAuthorization = screen == "esim-ordinary" ? model.esimTargetKey : nil
                model.displayPages = ModemLauncherPages(pages: [.esim, .info])
                model.displaySavedPages = .defaultPages
                model.displayPagesDraftEdited = true
                model.busy = screen == "esim-progress"
                model.esimOperationActive = model.busy
                model.progress = 0
                model.status = model.busy ? "eSIM · download · +15.0 s · host_http_waiting id=1 duration_ms=5000" : ""
                model.esimMessage = model.busy ? "Ожидаю HTTPS-ответ оператора…" : "Демонстрационные данные. Подключение и операции с картой отключены."
                model.firmwareResearchReport = screen == "firmware-research-result" ? syntheticResearch : nil
                model.firmwareResearchMessage = screen == "firmware-research-result" ? ResearchUI.outcome("partial") : ""
                let currentView: AnyView
                if screen.hasPrefix("firmware-research-") {
                    // Construct after the fixture change: a computed card is a value snapshot.
                    currentView = AnyView(ZStack { StudioStyle.canvas; VStack(alignment: .leading, spacing: 18) {
                        Text(screen.hasSuffix("result") ? L10n.text("Исследование прошивки · Пример отчёта", "Firmware research · Sample report") : L10n.text("Подготовка модема · Диагностика", "Modem preparation · Diagnostics")).font(.title2)
                        ContentView(model: model, verifiedCatalog: catalog).firmwareResearchCard
                        Spacer()
                    }.padding(36) })
                } else { currentView = rootView }
                let host = NSHostingView(rootView: currentView.frame(width: size.width, height: size.height))
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: 40, y: 40))
                window.orderFront(nil)
                let until = Date().addingTimeInterval(screen == "terminal" ? 2.0 : 0.6)
                while Date() < until {
                    RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.04)))
                }
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot allocate preview bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
                let name = "macos-\(screen)-\(language).png"
                try png.write(to: output.appendingPathComponent(name))
                paths.append(name)
                window.orderOut(nil)
                window.close()
                precondition(!model.connected && model.operationTask == nil && !model.terminalActive)
                print("Rendered \(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
        }
        let metadata: [String: Any] = ["source": "production SwiftUI views", "data": "synthetic fixture", "network": "none; disconnected model", "pixelSize": [1280, 900], "screens": paths]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("macos-preview-manifest.json"))
        print("PASS: \(paths.count) production SwiftUI screens rendered without modem operations")
    }
}
