import Foundation

@MainActor extension AppModel {
    /// Catalog approval is checked at the action boundary as well as in the UI.
    /// Existing installations can still be inspected, removed or rolled back.
    func catalogAllowsInstallation(_ id: String) -> Bool {
        guard VerifiedCatalogStore.shared.allows(id) else {
            append("Приложение пока не входит в проверенный каталог: " + id)
            return false
        }
        return true
    }
}
