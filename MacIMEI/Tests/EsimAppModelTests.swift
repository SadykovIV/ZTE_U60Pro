import Foundation

@main struct EsimAppModelTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw IMEIError.message(message) }; count += 1
        }
        let model = AppModel()
        try check(model.storage.path.contains("/MacIMEI/.build/connection-model-") && model.storage.lastPathComponent == "state", "Private test storage required")
        let identity = Identity(cid: String(repeating: "a", count: 32), firmwareHash: ModemEngine.firmwareHash)
        let boot = "2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601"
        let summary = ConnectionDeviceSummary(identity: identity, bootID: boot, imei: "490154203237518", fields: [:])
        let proof = DiagnosticDeviceProof(identity: identity, routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: nil)
        let diagnostics = DiagnosticSession(transport: "ssh", reason: "synthetic", proof: proof,
            readIdentity: { throw IMEIError.message("No device access in model test") },
            execute: { _, _ in throw IMEIError.message("No device access in model test") })
        let session = ReadOnlyChannelSession(mode: .ssh, summary: summary, diagnosticSession: diagnostics,
            readSummary: { throw IMEIError.message("No device access in model test") })
        model.acceptChannelSelection(ChannelSelection(requestedMode: .ssh, actualMode: .ssh, statuses: [], session: session, reason: "synthetic"))
        defer { model.connectionMonitorTask?.cancel() }
        model.esimSelectedTarget = .removable
        model.esimSnapshot = EsimSnapshot(ok: true, target: .removable, eid: String(repeating: "1", count: 32), profiles: [])
        model.esimAllowedOperations = ["list", "download", "delete", "rename"]
        model.esimAuthorization = model.esimTargetKey
        try check(model.canPerformEsim("download") && model.canPerformEsim("delete"), "Confirmed target permits card-local actions")
        try check(!model.canPerformEsim("enable"), "Unavailable radio operation must stay disabled")
        model.esimAllowedOperations.append("enable")
        try check(model.canPerformEsim("enable"), "Explicit radio grant enables selected card")
        let removableBinding = model.esimTargetKey
        model.esimSelectedTarget = .internalCard
        try check(model.esimTargetKey != removableBinding && !model.canWriteEsim, "Changing route invalidates same EID and inventory")
        model.esimSnapshot?.target = .internalCard
        try check(!model.canWriteEsim, "Changing snapshot route cannot inherit old authorization")
        model.esimAuthorization = model.esimTargetKey
        try check(model.canWriteEsim, "New target can be authorized after its own fresh read")
        model.esimSnapshot?.eid = String(repeating: "2", count: 32)
        try check(!model.canWriteEsim, "Card replacement invalidates authorization")
        model.esimAuthorization = model.esimTargetKey
        model.host = "192.0.2.89"
        try check(!model.canWriteEsim, "Connection change invalidates authorization")
        model.clearEsim()
        try check(model.esimSelectedTarget == nil && model.esimSnapshot == nil && model.esimAuthorization == nil && model.esimAllowedOperations.isEmpty && model.esimTargets.isEmpty, "Clearing connection also clears discovery and grants")
        try check(model.operationTask == nil && !model.busy, "State checks never start a card operation")
        print("EsimAppModelTests \(count) passed; no device calls")
    }
}
