import Foundation

@MainActor extension AppModel {
    var applicationsFullyChecked: Bool {
        applicationInventory != nil && applicationInventory?.ssclashUnmanaged != true && diagnosticToolsStatus != nil && experimentalOpkgStatus != nil
    }
    var installedApplicationCount: Int {
        (diagnosticToolsStatus?.installed == true ? diagnosticToolsStatus?.selected.count ?? 0 : 0)
            + (applicationInventory?.ssclashInstalled == true ? 1 : 0)
            + (experimentalOpkgStatus?.installed == true ? 1 : 0)
            + (experimentalOpkgStatus?.installed == true ? experimentalOpkgStatus?.packages.count ?? 0 : 0)
    }
    func acceptApplicationInventory(_ inventory: ModemApplicationInventory) {
        applicationInventory = inventory; applicationsError = ""
        if inventory.managedAppsChecked {
            diagnosticToolsStatus = inventory.diagnosticTools; diagnosticToolsPlan = nil
            experimentalOpkgStatus = inventory.experimentalOpkg
            diagnosticToolsError = inventory.managedAppErrors["diagnostics"] ?? ""
            experimentalOpkgError = inventory.managedAppErrors["opkg"] ?? ""
        }
    }
}
