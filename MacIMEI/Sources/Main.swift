import SwiftUI
import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.model?.busy == true { Self.model?.append("Дождитесь завершения операции перед закрытием приложения."); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { Self.model?.busy != true }
}
@main struct ZTEIMEIStudio: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).onAppear { ApplicationDelegate.model = model }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1100, height: 780)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
