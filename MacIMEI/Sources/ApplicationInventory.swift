import Foundation

extension ModemApplications {
    /// The caller holds the local operation lock; every reader checks the same
    /// device. Optional adapters fail independently and never imply absence.
    func inventoryWithManagedApps() throws -> ModemApplicationInventory {
        let identity = try engine.measuredIdentity()
        var result = try inventory()
        result.managedAppsChecked = true
        do { result.diagnosticTools = try DiagnosticToolsManager(engine: engine).inspect() }
        catch { result.managedAppErrors["diagnostics"] = ActivityJournal.redact(error.localizedDescription) }
        try require(try engine.measuredIdentity() == identity, "Устройство изменилось во время проверки приложений")
        do { result.experimentalOpkg = try ExperimentalOpkgManager(engine: engine).inspect() }
        catch { result.managedAppErrors["opkg"] = ActivityJournal.redact(error.localizedDescription) }
        try require(try engine.measuredIdentity() == identity, "Устройство изменилось во время проверки приложений")
        return result
    }
}
