import Foundation

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw IMEIError.message("TEST: " + message) }
}
private func rejects(_ work: () throws -> Void) throws {
    var rejected = false
    do { try work() } catch { if error.localizedDescription.hasPrefix("TEST:") { throw error }; rejected = true }
    try check(rejected, "Expected refusal")
}
private final class Remote: RemoteTransport {
    let cid = String(repeating: "a", count: 32)
    var boot = "11111111-2222-3333-4444-555555555555", firmware = ModemEngine.firmwareHash
    var active = "none", previous = "unset", running = false, free = 100000
    var selected: Set<String>?, previousSelected: Set<String>?
    var platformFailure = false, absentFiles = false, badUpload = false, failInstall = false, malformedReceipt = false, missingRollbackReceipt = false
    var badSupervisorUpload = false, inspectError: String?
    var commands: [String] = [], archiveUploads = 0, supervisorUploads = 0, installed = false
    let bundle: DiagnosticToolsBundle
    init(_ bundle: DiagnosticToolsBundle) { self.bundle = bundle }
    var currentSelection: Set<String> { selected ?? (active == "none" ? [] : DiagnosticTool.ids) }
    var oldSelection: Set<String> { previousSelected ?? (["none", "unset"].contains(previous) ? [] : DiagnosticTool.ids) }
    func status() -> String { "ZTE_DIAG_TOOLS_V2\nactive=\(active)\nprevious=\(previous)\nselected=\(DiagnosticTool.selectionText(currentSelection))\nprevious_selected=\(previous == "unset" ? "unset" : DiagnosticTool.selectionText(oldSelection))\nrunning=\(running ? 1 : 0)\nfree_kib=\(free)\n" }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        func result(_ text: String, _ status: Int32 = 0) -> CommandResult { .init(status: status, stdout: status == 0 ? Data(text.utf8) : Data(), stderr: status == 0 ? Data() : Data(text.utf8)) }
        if command == AccessIdentity.command {
            if platformFailure { return result("PLATFORM",71) }
            return result((absentFiles ? "absent" : firmware) + "  /firmware/image/modem.b16\n" + (absentFiles ? "absent" : ModemEngine.routerHash) + "  /usr/bin/diag-router\n" + cid + "\n" + boot + "\n")
        }
        if let input, command.contains("cat > '") {
            let path = command.components(separatedBy: "cat > '")[1].components(separatedBy: "'")[0]
            if path.hasSuffix("bundle.tar.gz") { archiveUploads += 1; try check(digest(input) == bundle.archiveSHA256, "Unverified archive uploaded") }
            if path.hasSuffix("zte-timeout") { supervisorUploads += 1; try check(digest(input) == ModemHostTools.timeoutHash, "Unverified supervisor uploaded") }
            let rejected = badUpload || (badSupervisorUpload && path.hasSuffix("zte-timeout"))
            return result((rejected ? String(repeating: "0", count: 64) : digest(input)) + "  " + path + "\n")
        }
        if command.contains("; sh '") {
            try check(command.contains(DiagnosticToolsManager.helperHash), "Helper not pinned before execution")
            if command.hasSuffix(" 'inspect'") {
                if let inspectError { return result("DIAG_ERROR " + inspectError, 1) }
                return result(status())
            }
            if command.contains(" 'install' ") {
                try check(archiveUploads == 1 && supervisorUploads > 0 && command.contains(bundle.id) && command.contains(bundle.archiveSHA256) && command.contains(cid) && command.contains(boot), "Install omitted proof")
                if failInstall { return result("DIAG_ERROR SELF_TEST", 1) }
                let tool = DiagnosticTool.catalog.first { command.contains(" '" + $0.id + "' ") }?.id
                let next = tool.map { currentSelection.union([$0]) } ?? DiagnosticTool.ids
                if active != bundle.id || currentSelection != next { previousSelected = currentSelection; previous = active }
                selected = next; active = bundle.id; installed = true
            } else if command.contains(" 'remove' ") {
                let tool = DiagnosticTool.catalog.first { command.contains(" '" + $0.id + "' ") }?.id
                previousSelected = currentSelection; selected = tool.map { currentSelection.subtracting([$0]) } ?? []
                previous = active; if currentSelection.isEmpty { active = "none" }
            }
            else if command.contains(" 'rollback' ") {
                let old = active, oldSelected = currentSelection
                active = previous; selected = oldSelection; previous = old; previousSelected = oldSelected
            }
            else { throw IMEIError.message("TEST: unknown helper command") }
            if missingRollbackReceipt { previous = "unset"; previousSelected = [] }
            return result(malformedReceipt ? "truncated\n" : status())
        }
        try check(!command.contains("opkg") && !command.contains("remount") && !command.contains("/etc/init.d"), "Mutation outside private scope")
        return result("")
    }
}
private final class Fixture {
    let root: URL, resources: URL, remote: Remote, engine: ModemEngine
    init(skipFirmwareCheck: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-diag-tools-test-" + UUID().uuidString)
        try secureDirectory(root)
        resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        remote = Remote(try DiagnosticToolsManager.bundle(resources: resources))
        engine = try ModemEngine(root: root, resources: resources, connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/hosts", skipFirmwareCheck: skipFirmwareCheck), transport: remote)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
@main struct DiagnosticToolsTests {
    static func main() throws {
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); count += 1; print("PASS " + name) }
        try test("Bundled archive metadata and pins match four selected tools") {
            let f = try Fixture(), b = try DiagnosticToolsManager.bundle(resources: f.resources, verifyArchive: true)
            try check(Set(DiagnosticTool.catalog.map(\.id)) == Set(["htop", "iperf3", "mtr", "tcpdump"]) && b.fileCount == 52, "Wrong catalog")
        }
        try test("Status parser distinguishes absent installed removed and rollback-to-absence") {
            let f = try Fixture()
            let absent = try DiagnosticToolsManager.parse(Data(f.remote.status().utf8))
            try check(!absent.installed && !absent.canRollback, "Absent status wrong")
            f.remote.active = f.remote.bundle.id; f.remote.previous = "none"
            let installed = try DiagnosticToolsManager.parse(Data(f.remote.status().utf8))
            try check(installed.installed && installed.canRollback && installed.previous == nil, "Initial rollback lost")
            f.remote.active = "none"; f.remote.previous = f.remote.bundle.id
            let removed = try DiagnosticToolsManager.parse(Data(f.remote.status().utf8))
            try check(!removed.installed && removed.canRollback && removed.previous == f.remote.bundle.id, "Removal backup lost")
        }
        try test("Legacy V1 receipts map existing and previous bundles to all four tools") {
            let f = try Fixture()
            let legacy = "ZTE_DIAG_TOOLS_V1\nactive=\(f.remote.bundle.id)\nprevious=none\nrunning=0\nfree_kib=100000\n"
            let status = try DiagnosticToolsManager.parse(Data(legacy.utf8))
            try check(status.selected == DiagnosticTool.ids && status.previousSelected.isEmpty && status.canRollback, "V1 migration lost the installed set")
            let removed = legacy.replacingOccurrences(of: "active=" + f.remote.bundle.id, with: "active=none").replacingOccurrences(of: "previous=none", with: "previous=" + f.remote.bundle.id)
            let old = try DiagnosticToolsManager.parse(Data(removed.utf8))
            try check(old.selected.isEmpty && old.previousSelected == DiagnosticTool.ids, "V1 removal lost recovery selection")
        }
        try test("Individual install and removal preserve unrelated tools and rollback restores exact selection") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare(toolID: "htop") }
            try check(plan.toolID == "htop" && plan.selected == ["htop"], "Tool plan incorrectly selected the full bundle")
            let installed = try f.engine.locked { try manager.install(plan) }
            try check(installed.selected == ["htop"] && installed.isInstalled("htop") && !installed.isInstalled("mtr"), "Individual install enabled unrelated tool")
            f.remote.selected = ["htop", "iperf3"]
            let removed = try f.engine.locked { try manager.change("remove", toolID: "htop") }
            try check(removed.selected == ["iperf3"] && removed.active == installed.active && removed.previousSelected == ["htop", "iperf3"], "Individual removal changed remaining tool")
            let restored = try f.engine.locked { try manager.change("rollback") }
            try check(restored.selected == ["htop", "iperf3"], "Rollback did not restore prior selection")
        }
        try test("Selection changes after prepare invalidate a plan even when bundle hashes match") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            f.remote.active = f.remote.bundle.id; f.remote.selected = ["htop"]
            let plan = try f.engine.locked { try manager.prepare(toolID: "mtr") }
            f.remote.selected = ["htop", "iperf3"]
            try rejects { _ = try f.engine.locked { try manager.install(plan) } }
            try check(f.remote.archiveUploads == 0, "A stale per-tool plan uploaded data")
        }
        try test("A successful active selection without a rollback receipt is not accepted") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare(toolID: "htop") }
            f.remote.missingRollbackReceipt = true
            try rejects { _ = try f.engine.locked { try manager.install(plan) } }
        }
        try test("Shared version upgrade cannot silently change unrelated installed applications") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            f.remote.active = String(repeating: "b", count: 64); f.remote.selected = ["htop", "iperf3"]
            try rejects { _ = try f.engine.locked { try manager.prepare(toolID: "htop") } }
            f.remote.selected = ["htop"]
            let plan = try f.engine.locked { try manager.prepare(toolID: "htop") }
            try check(plan.selected == ["htop"], "Sole-tool upgrade refused or expanded selection")
        }
        try test("Unknown tool identifiers and removing uninstalled tools are rejected") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            try rejects { _ = try f.engine.locked { try manager.prepare(toolID: "../htop") } }
            f.remote.active = f.remote.bundle.id; f.remote.selected = ["htop"]
            try rejects { _ = try f.engine.locked { try manager.change("remove", toolID: "mtr") } }
            try rejects { _ = try f.engine.locked { try manager.change("rollback", toolID: "htop") } }
            try check(!f.remote.commands.contains { $0.contains(" 'remove' ") }, "Uninstalled tool removal was executed")
        }
        try test("V2 rejects noncanonical duplicate unknown and inconsistent selections") {
            let f = try Fixture(); f.remote.active = f.remote.bundle.id; f.remote.selected = ["htop"]
            let valid = f.remote.status()
            for value in ["none", "", "htop,htop", "iperf3,htop", "htop,unknown", ",htop", "htop,"] {
                try rejects { _ = try DiagnosticToolsManager.parse(Data(valid.replacingOccurrences(of: "selected=htop\n", with: "selected=" + value + "\n").utf8)) }
            }
            try rejects { _ = try DiagnosticToolsManager.parse(Data(valid.replacingOccurrences(of: "previous_selected=unset", with: "previous_selected=none").utf8)) }
        }
        try test("Malformed status hash duplicates unknown fields truncated and oversized replies refuse") {
            let f = try Fixture(), valid = f.remote.status()
            for text in [valid.replacingOccurrences(of: "active=none", with: "active=../../etc"), valid + "extra=1\n", valid.replacingOccurrences(of: "previous=unset", with: "active=none"), valid.replacingOccurrences(of: "running=0", with: "running=2"), valid.replacingOccurrences(of: "free_kib=100000", with: "free_kib=-1"), String(valid.dropLast()), String(repeating: "X", count: 4097)] {
                try rejects { _ = try DiagnosticToolsManager.parse(Data(text.utf8)) }
            }
        }
        try test("Prepare validates without upload or installation and locks are required") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            try rejects { _ = try manager.prepare() }
            let plan = try f.engine.locked { try manager.prepare() }
            try check(plan.identity.cid == f.remote.cid && plan.bootID == f.remote.boot && f.remote.archiveUploads == 0 && !f.remote.installed, "Prepare installed data")
            try check(f.remote.supervisorUploads == 0, "Inspection unnecessarily required an executable supervisor")
        }
        try test("Supervisor is staged only for self-tests and its cleanup names the private file") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare(toolID: "htop") }
            _ = try f.engine.locked { try manager.install(plan) }
            try check(f.remote.supervisorUploads == 1, "Install did not stage its supervisor")
            _ = try f.engine.locked { try manager.change("remove", toolID: "htop") }
            try check(f.remote.supervisorUploads == 1, "Removal unexpectedly required a supervisor")
            _ = try f.engine.locked { try manager.change("rollback") }
            try check(f.remote.supervisorUploads == 2, "Rollback self-test omitted a fresh supervisor")
            try check(f.remote.commands.contains { $0.contains("rm -f") && $0.contains("/zte-timeout'") && !$0.contains("rm -rf") }, "Supervisor temporary file omitted from bounded cleanup")
        }
        try test("Bad supervisor transfer stops before archive upload or any installation") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare(toolID: "htop") }
            f.remote.badSupervisorUpload = true
            try rejects { _ = try f.engine.locked { try manager.install(plan) } }
            try check(f.remote.archiveUploads == 0 && !f.remote.installed && !f.remote.commands.contains { $0.contains(" 'install' ") }, "Unverified supervisor allowed installation")
        }
        try test("Capability failure names the actual missing command") {
            let f = try Fixture(); f.remote.inspectError = "CAPABILITY_od"
            do { _ = try f.engine.locked { try DiagnosticToolsManager(engine: f.engine).inspect() }; throw IMEIError.message("TEST: missing command accepted") }
            catch {
                try check(error.localizedDescription.contains("«od»") && !error.localizedDescription.contains("flock") && !error.localizedDescription.contains("timeout"), "Missing utility was misreported")
            }
        }
        try test("Install rechecks identity state upload and final receipt; only private paths used") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare() }
            let installed = try f.engine.locked { try manager.install(plan) }
            try check(installed.active == f.remote.bundle.id && installed.canRollback && f.remote.archiveUploads == 1, "Install receipt wrong")
        }
        try test("Reboot after preview refuses before archive upload") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare() }
            f.remote.boot = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            try rejects { _ = try f.engine.locked { try manager.install(plan) } }
            try check(f.remote.archiveUploads == 0 && !f.remote.installed, "Changed boot wrote archive")
        }
        try test("Changed state or running tools after preview cannot be overwritten") {
            for running in [false, true] {
                let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
                let plan = try f.engine.locked { try manager.prepare() }
                if running { f.remote.running = true } else { f.remote.active = String(repeating: "b", count: 64) }
                try rejects { _ = try f.engine.locked { try manager.install(plan) } }
                try check(f.remote.archiveUploads == 0 && !f.remote.installed, "Stale plan wrote data")
            }
        }
        try test("Bad uploaded helper prevents every helper invocation") {
            let f = try Fixture(); f.remote.badUpload = true
            try rejects { _ = try f.engine.locked { try DiagnosticToolsManager(engine: f.engine).prepare() } }
            try check(!f.remote.commands.contains(where: { $0.contains("; sh '") }), "Corrupted upload executed")
        }
        try test("Helper self-test failure preserves previous active state") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            f.remote.active = String(repeating: "b", count: 64)
            let plan = try f.engine.locked { try manager.prepare() }; f.remote.failInstall = true
            try rejects { _ = try f.engine.locked { try manager.install(plan) } }
            try check(f.remote.active == plan.before.active && !f.remote.installed, "Failed install replaced active state")
        }
        try test("Remove preserves a restorable previous state and rollback restores it") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            f.remote.active = f.remote.bundle.id
            let removed = try f.engine.locked { try manager.change("remove") }
            try check(!removed.installed && removed.previous == f.remote.bundle.id, "Remove lost backup")
            let restored = try f.engine.locked { try manager.change("rollback") }
            try check(restored.active == f.remote.bundle.id && restored.canRollback, "Rollback failed")
        }
        try test("Running tools and absent history block remove rollback and prepare") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine: f.engine)
            try rejects { _ = try f.engine.locked { try manager.change("rollback") } }
            f.remote.running = true; f.remote.active = f.remote.bundle.id
            try rejects { _ = try f.engine.locked { try manager.prepare() } }
            try rejects { _ = try f.engine.locked { try manager.change("remove") } }
            try check(f.remote.active == f.remote.bundle.id, "Running tools changed")
        }
        try test("Invalid platform and low space block preparation") {
            for firmware in [false, true] {
                let f = try Fixture()
                if firmware { f.remote.platformFailure = true } else { f.remote.free = 0 }
                try rejects { _ = try f.engine.locked { try DiagnosticToolsManager(engine: f.engine).prepare() } }
                try check(f.remote.archiveUploads == 0, "Blocked prepare uploaded archive")
            }
        }
        try test("Measured non-B31 identity reaches package checks and preserves their refusal") {
            let f = try Fixture()
            f.remote.firmware = String(repeating: "b", count: 64)
            let manager = DiagnosticToolsManager(engine: f.engine)
            let plan = try f.engine.locked { try manager.prepare(toolID: "htop") }
            let installed = try f.engine.locked { try manager.install(plan) }
            try check(installed.selected == ["htop"] && f.remote.archiveUploads == 1, "Override failed on compatible packages")
            let refused = try Fixture()
            refused.remote.firmware = String(repeating: "b", count: 64)
            refused.remote.inspectError = "UNSUPPORTED_PLATFORM"
            try rejects { _ = try refused.engine.locked { try DiagnosticToolsManager(engine: refused.engine).prepare(toolID: "htop") } }
            try check(refused.remote.archiveUploads == 0 && !refused.remote.installed, "Override bypassed package ABI refusal")
        }
        try test("Absent unrelated files and local IMEI pending permit inspect and install") {
            let f = try Fixture(), manager = DiagnosticToolsManager(engine:f.engine); f.remote.absentFiles = true
            for name in ["pending.json","setup-pending.json"] { try savePrivate(Data("synthetic".utf8),f.root.appendingPathComponent(name)) }
            let plan=try f.engine.locked { try manager.prepare(toolID:"htop") }
            _=try f.engine.locked { try manager.install(plan) }
            try check(f.remote.installed,"Absent dependency blocked tools")
        }
        try test("Actual system restore still blocks diagnostic staging") {
            let f=try Fixture(), manager=DiagnosticToolsManager(engine:f.engine)
            try savePrivate(Data("synthetic".utf8),f.root.appendingPathComponent("system-restore-pending.json"))
            try rejects { _=try f.engine.locked { try manager.inspect() } }
            try check(f.remote.commands.isEmpty,"System restore blocker bypassed")
        }
        print("DiagnosticToolsTests: \(count) passed")
    }
}
