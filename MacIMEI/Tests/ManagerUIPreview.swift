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
        model.adbControlStatus = ADBControlStatus(enabled: true, supportsChange: true, descriptorsReady: true)
        let previousAgentHash = "076824a90eec46702744ae0f383872841d3c4704216ae32de4725f906f86a550"
        precondition(BundledAgent.supportedUpgradeHashes.contains(previousAgentHash) && previousAgentHash != BundledAgent.sha256)
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
        var vpn = VPNStatus()
        vpn.installed = true; vpn.coreAvailable = true; vpn.configured = true
        vpn.enabled = true; vpn.coreRunning = true; vpn.networkOk = true
        vpn.ssid = "ZTE-VPN"; vpn.desiredSsid = "ZTE-VPN"; vpn.settingsSupported = true
        let subscriptionID = "33333333-3333-3333-3333-333333333333"
        vpn.profiles = [
            .init(id: "11111111-1111-1111-1111-111111111111", name: "Amnezia · Helsinki", transport: "", warnings: [], active: true, protocolName: "amneziawg", subscriptionId: subscriptionID, updateAvailable: true),
            .init(id: "22222222-2222-2222-2222-222222222222", name: "Home · WireGuard", transport: "", warnings: [], active: false, protocolName: "wireguard"),
            .init(id: "44444444-4444-4444-4444-444444444444", name: "Europe · VLESS", transport: "tcp", warnings: [], active: false, protocolName: "vless", subscriptionId: subscriptionID),
            .init(id: "55555555-5555-5555-5555-555555555555", name: "Travel · Hysteria2", transport: "", warnings: ["VPN_INSECURE_TLS"], active: false, protocolName: "hysteria2", removedFromSubscription: true)
        ]
        vpn.activeProfile = vpn.profiles[0].id
        vpn.subscriptions = [.init(id: subscriptionID, name: "Demo subscription", host: "example.test", updatedAt: 1791900000, profileCount: 3)]
        vpn.lastImport = .init(added: 3, updated: 1, removed: 0, duplicates: 2, retainedActive: 1, skipped: [.init(index: 5, code: "VPN_SUBSCRIPTION_FILE_REFERENCE")])
        model.vpnInspection = .init(status: vpn, missingCapabilities: [], ssclashInstalled: false, helperReady: true)
        var paths: [String] = []

        for language in ["ru", "en"] {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language], forName: UserDefaults.argumentDomain)
            precondition(L10n.language == language)
            let screens: [(String, AnyView)] = [
                ("preparation", AnyView(ContentView(model: model, verifiedCatalog: catalog))),
                ("connection-methods", AnyView(ContentView(model: model, verifiedCatalog: catalog, connectionMethodsExpanded: true))),
                ("connection-methods-detail", AnyView(ZStack { StudioStyle.canvas; VStack(alignment: .leading, spacing: 18) { Text(L10n.text("Доступные способы подключения")).font(.title2); StudioCard { ContentView(model: model, verifiedCatalog: catalog).connectionMethodsContents }; Spacer() }.padding(36) })),
                ("diagnostics", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationSection: .diagnostics))),
                ("preparation-credentials", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationCredentialsExpanded: true))),
                ("journal", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .administration, administrationSection: .activity))),
                ("administration", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .administration))),
                ("modem", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .modem))),
                ("agent-esim", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationSection: .agent))),
                ("agent-update", AnyView(ContentView(model: model, verifiedCatalog: catalog, preparationSection: .agent))),
                ("esim", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .esim))),
                ("esim-ordinary", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .esim))),
                ("launcher-esim", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .display, launcherSection: .esim))),
                ("esim-progress", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .esim))),
                ("vpn", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .vpn))),
                ("vpn-detail", AnyView(ZStack { StudioStyle.canvas; ContentView(model: model, verifiedCatalog: catalog).vpnPage.padding(36).frame(maxHeight: .infinity, alignment: .top) })),
                ("catalog", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .applications, applicationSection: .available))),
                ("terminal", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .applications, applicationSection: .opkg))),
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
                model.agentInstallationStatus = AgentInstallationStatus(hash: screen == "agent-update" ? previousAgentHash : BundledAgent.sha256, running: true, startupReady: true)
                if screen.hasPrefix("agent-") {
                    model.agentInstallationStatus?.web = AgentWebStatus(url: "http://192.0.2.1:8080/",
                        loopback: .init(code: "200", isHTML: true), lan: .init(code: "200", isHTML: true),
                        computer: .init(code: screen == "agent-esim" ? "refused" : "200", isHTML: screen != "agent-esim"))
                }
                let size = screen == "vpn-detail" ? NSSize(width: 1280, height: 2000) : size
                let currentView = rootView
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
        let metadata: [String: Any] = ["source": "production SwiftUI views", "data": "synthetic fixture", "network": "none; disconnected model", "pixelSize": [1280, 900], "fullVPNPanelPixelSize": [1280, 2000], "screens": paths]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("macos-preview-manifest.json"))
        print("PASS: \(paths.count) production SwiftUI screens rendered without modem operations")
    }
}
