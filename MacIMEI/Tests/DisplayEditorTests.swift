import Foundation

@main struct DisplayEditorTests {
    @MainActor static func main() throws {
        let model = AppModel()
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw IMEIError.message(message) }; checks += 1
        }
        try check(model.displayLayout == .defaultLayout && model.displayLayout.enabledCount == 6, "Default layout changed")
        try check(model.displayLayout.style == .list, "Native default style is not list")
        model.setDisplayStyle(.tiles)
        try check(model.displayLayout.style == .tiles && model.displayDraftEdited, "Persistent grid selection was not marked dirty")
        let grid = try ModemDisplayLayout.decode(model.displayLayout.encoded())
        try check(grid.style == .tiles, "Grid style did not reach the modem wire format")
        for metric in ModemDisplayMetric.allCases { model.setDisplayMetric(metric, enabled: true) }
        try check(model.displayLayout.enabledCount == 12, "Cannot select all scrolling metrics")
        model.moveDisplayMetric(.uptime, before: .cpu)
        try check(model.displayLayout.items.first?.metric == .uptime, "Drag to top failed")
        model.moveDisplayMetric(.cpu, before: nil)
        try check(model.displayLayout.items.last?.metric == .cpu, "Drag to end failed")
        model.moveDisplayMetric(.uptime, before: .cpu)
        try check(model.displayLayout.items.suffix(2).map(\.metric) == [.uptime, .cpu], "Downward before-target insertion failed")
        model.moveDisplayMetric(.cpu, before: .cpu)
        try check(model.displayLayout.items.last?.metric == .cpu, "Self move changed order")
        for metric in ModemDisplayMetric.allCases where metric != .cpu { model.setDisplayMetric(metric, enabled: false) }
        model.setDisplayMetric(.cpu, enabled: false)
        try check(model.displayLayout.enabledCount == 1 && model.displayLayout.items.last?.enabled == true, "Last metric can be removed")
        try check(!model.displayLayoutMessage.isEmpty, "Last metric rejection not explained")
        try check(model.displayDraftEdited && model.displayLayoutChanged, "Dirty layout not tracked")
        let one = model.displayLayout
        model.busy = true
        model.setDisplayStyle(.list)
        model.setDisplayMetric(.memory, enabled: true)
        model.moveDisplayMetric(.cpu, before: .signal)
        model.resetDisplayLayout()
        try check(model.displayLayout == one, "Editor changes during operation")
        model.busy = false
        model.resetDisplayLayout()
        try check(model.displayLayout == .defaultLayout && model.displayDraftEdited, "Reset must be a local draft")
        try check(model.displayLayout.style == .list, "Reset left grid style selected")
        model.displaySavedLayout = .defaultLayout
        try check(!model.displayLayoutChanged, "Equal stored layout reported dirty")
        model.setDisplayStyle(.tiles)
        try check(model.displayLayoutChanged, "Style-only change is not dirty")
        model.moveDisplayMetric(.uptime, before: .cpu)
        try check(model.displayLayoutChanged && model.displayLayout.items.first?.enabled == false, "Disabled position not retained")
        let encoded = try model.displayLayout.encoded()
        let decoded = try ModemDisplayLayout.decode(encoded)
        try check(decoded == model.displayLayout, "Editor order does not round-trip")
        model.connectionMode = .adb
        model.connected = true
        model.installDisplay(); model.applyDisplayLayout(); model.refreshDisplay()
        try check(model.operationTask == nil && !model.busy, "Manual ADB invoked SSH display mutation")
        model.invalidateChannelConnection()
        try check(model.displayLayout == .defaultLayout && model.displaySavedLayout == nil && !model.displayDraftEdited, "Connection change retained another modem draft")
        print("PASS DisplayEditorTests \(checks) checks")
    }
}
