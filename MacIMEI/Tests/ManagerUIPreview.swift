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

        for language in ["ru", "en"] {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language], forName: UserDefaults.argumentDomain)
            precondition(L10n.language == language)
            let screens: [(String, AnyView)] = [
                ("preparation", AnyView(ContentView(model: model, verifiedCatalog: catalog))),
                ("catalog", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .applications, applicationSection: .available))),
                ("terminal", AnyView(ContentView(model: model, verifiedCatalog: catalog, page: .applications, applicationSection: .opkg))),
                ("about", AnyView(ZStack {
                    StudioStyle.canvas
                    ContentView(model: model, verifiedCatalog: catalog).aboutSheet
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioStyle.line))
                }))
            ]
            for (screen, rootView) in screens {
                let host = NSHostingView(rootView: rootView.frame(width: size.width, height: size.height))
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
        print("PASS: 8 production SwiftUI screens rendered without modem operations")
    }
}
