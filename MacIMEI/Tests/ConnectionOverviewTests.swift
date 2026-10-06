import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.check(message) }
}
private func rejects(_ fragment: String, _ body: () throws -> Void) throws {
    do { try body() } catch let error as Failure { throw error } catch {
        try check(error.localizedDescription.contains(fragment), "Unexpected rejection: " + error.localizedDescription)
        return
    }
    throw Failure.check("Expected rejection: " + fragment)
}
private let identity = Identity(cid: String(repeating: "a", count: 32), firmwareHash: ModemEngine.firmwareHash)
private let boot = "2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601"
private let infoText = """
__INFO_SCHEMA__
1
__INFO_BOARD__
{"kernel":"5.15.137","hostname":"modem","system":"SDX75","model":"ZTE MU5250","board_name":"qcom,sdx75","release":{"distribution":"OpenWrt","version":"23.05","revision":"r-custom"}}
__INFO_DEVICE__
{"integrate_version":"MU5250V1.0.0B31","wa_inner_version":"B31-internal"}
__INFO_ARCH__
aarch64
__INFO_CPU__
4
__INFO_UPTIME__
12345.67 20000.00
__INFO_LOAD__
0.01 0.02 0.03
__INFO_MEMORY__
MemTotal: 2048000 kB
MemFree: 512000 kB
MemAvailable: 1024000 kB
Cached: 400000 kB
SwapTotal: 0 kB
SwapFree: 0 kB
__INFO_DISKS__
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 65536 65536 0 100% /
/dev/mmcblk0p50 5242880 2097152 3145728 40% /data
__INFO_MOUNTS__
/dev/root / squashfs ro,relatime 0 0
/dev/mmcblk0p50 /data ext4 rw,relatime 0 0
__INFO_BATTERY__
78
Charging
__INFO_AGENT__
__INFO_END__
"""

private final class Fixture {
    var proof = DiagnosticDeviceProof(identity: identity, routerHash: ModemEngine.routerHash, bootID: boot, webIdentity: nil)
    var summary = ConnectionDeviceSummary(identity: identity, bootID: boot)
    var readNames = [String](), summaryCalls = 0
    var failSummaryAt = 0, failVerify = false
    func session(_ mode: ConnectionMode = .ssh) -> ReadOnlyChannelSession {
        let shell = DiagnosticSession(transport: mode.rawValue, reason: "test", proof: proof, readIdentity: {
            if self.failVerify { throw IMEIError.message("Connection lost") }
            return self.proof
        }) { command, _ in
            try check(command == ModemInformationManager.command, "Unexpected diagnostic command")
            return CommandResult(status: 0, stdout: Data(infoText.utf8), stderr: Data())
        }
        return ReadOnlyChannelSession(mode: mode, summary: summary, diagnosticSession: shell) {
            self.summaryCalls += 1
            if self.summaryCalls == self.failSummaryAt { self.summary.bootID = UUID().uuidString }
            return self.summary
        }
    }
    func readers() -> ConnectionOverviewReaders {
        ConnectionOverviewReaders(information: {
            self.readNames.append("information")
            return try ModemInformationManager.parse(infoText, identity: identity, boot: boot)
        }, display: {
            self.readNames.append("display")
            return ModemDisplayInspection(state: .absent, detail: "fixture", identity: identity, bootID: boot,
                                          expectedHash: VPNSettingsManager.launcherHash, canInstall: true)
        }, vpn: {
            self.readNames.append("vpn")
            return VPNInspection(status: VPNStatus(), missingCapabilities: [], ssclashInstalled: false)
        }, ttl: {
            self.readNames.append("ttl")
            return TTLStatus(state: .disabled, verification: .notApplicable)
        }, screen: {
            self.readNames.append("screen")
            return ScreenLocalizationStatus(state: .absent, language: "en")
        }, access: {
            self.readNames.append("access")
            return AccessManagementState(services: [], sshAccounts: SSHAccountState(accounts: [], listenerReady: false, recoveryPending: false))
        }, agent: {
            self.readNames.append("agent")
            return AgentInstallationStatus()
        }, applications: {
            self.readNames.append("applications")
            return ModemApplicationInventory(storage: [], memoryTotalKiB: 100, memoryAvailableKiB: 50,
                                             installedPackages: [], opkgWritable: false, ssclashInstalled: false,
                                             ssclashRunning: false, architecture: "aarch64", release: "fixture")
        })
    }
}

private final class StatusTransport: RemoteTransport {
    var commands = [String](), payloadHashes = [String](), fail = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        if let input { payloadHashes.append(digest(input)) }
        let output: String
        if command == SSHReadProof.quickCommand {
            output = "ZTE_SSH_READ_V1\n0\nLinux\naarch64\n" + identity.cid + "\n" + boot + "\n?\n?\n"
        } else if command == "unset ZTE_AGENT_TEST_ROOT; sh -s -- status" {
            output = "AGENT_SHA absent\n"
        } else if command == "sh -s -- status " + shellQuote(identity.cid) {
            output = "TTL_STATUS state=disabled outbound=off inbound_inc=off capability=supported verification=not-applicable persistence=none\n"
        } else if command == "sh -s -- status " + shellQuote(identity.cid) + " '192.168.0.1'" {
            output = "ACCESS_SCHEMA 1\n" + AccessServiceID.allCases.map {
                "ACCESS_SERVICE \($0.rawValue) running \($0 == .managementSSH ? "protected" : "readonly")\n"
            }.joined()
        } else if command.contains("printf 'SSH_USERS_SCHEMA 1") {
            output = "SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING 0\nSSH_USERS_RECOVERY none\nSSH_USERS_LISTENER 0\n"
        } else { throw Failure.check("Unexpected command, possibly a mutation: " + command) }
        return CommandResult(status: fail ? 1 : 0, stdout: Data(output.utf8), stderr: fail ? Data("fixture refusal".utf8) : Data())
    }
}

@main enum ConnectionOverviewTests {
    static func main() throws {
        var passed = 0
        func test(_ title: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + title) }
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zte-overview-tests-" + UUID().uuidString)
        try secureDirectory(temp); defer { try? FileManager.default.removeItem(at: temp) }
        func engine(_ stub: StatusTransport, resources assets: URL? = nil) throws -> ModemEngine {
            try ModemEngine(root: temp.appendingPathComponent(UUID().uuidString), resources: assets ?? resources,
                            connection: Connection(host: "192.168.0.1", port: "2222", keyPath: "/dev/null", knownHostsPath: "/dev/null"), transport: stub)
        }
        try test("SSH hydrates all independently read statuses and install eligibility") {
            let f = Fixture(), value = try ConnectionOverview.collect(session: f.session(), readers: f.readers())
            try check(value.errors.isEmpty && value.information?.model == "ZTE MU5250" && value.display?.canInstall == true, "Missing information or launcher install eligibility")
            try check(value.access != nil && value.vpn != nil && value.ttl != nil && value.screen != nil && value.agent != nil && value.applications != nil, "Missing optional statuses")
            try check(!value.limitedToADB && Set(f.readNames).count == 8, "Readers missing/repeated")
        }
        try test("A scoped refresh executes exactly the selected section, never all readers") {
            for section in ConnectionOverviewSection.allCases {
                let f = Fixture(); var progress = [ConnectionOverviewSection]()
                let value = try ConnectionOverview.collect(session: f.session(), readers: f.readers(), sections: [section], update: { progress.append($0) })
                try check(value.sections == [section] && f.readNames == [section.rawValue] && progress == [section], "Refresh escaped selected section: " + section.rawValue)
                try check(value.errors.isEmpty && f.summaryCalls == 2, "Scoped refresh skipped before/after session identity check")
            }
        }
        try test("An unrelated broken component is never called during information refresh") {
            let f = Fixture(); var readers = f.readers()
            readers.display = { throw Failure.check("Unrelated display reader invoked") }
            readers.applications = { throw Failure.check("Unrelated applications reader invoked") }
            let value = try ConnectionOverview.collect(session: f.session(), readers: readers, sections: [.information])
            try check(value.information != nil && value.errors.isEmpty && f.readNames == ["information"], "Unrelated component influenced information refresh")
        }
        try test("Scoped refresh still rejects device replacement and final identity drift") {
            let f = Fixture(); let session = f.session(); var readers = f.readers()
            readers.information = { f.proof.bootID = UUID().uuidString; throw IMEIError.message("module failure") }
            try rejects("изменились") { _ = try ConnectionOverview.collect(session: session, readers: readers, sections: [.information]) }
            let last = Fixture(); last.failSummaryAt = 2
            try rejects("перезагрузился") { _ = try ConnectionOverview.collect(session: last.session(), readers: last.readers(), sections: [.information]) }
        }
        try test("Unsupported launcher and VPN errors preserve subsequent sections") {
            let f = Fixture(); var readers = f.readers()
            readers.display = { throw IMEIError.message("unsupported display") }
            readers.vpn = { throw IMEIError.message("password='secret-value' component error") }
            let value = try ConnectionOverview.collect(session: f.session(), readers: readers)
            try check(value.display == nil && value.vpn == nil && value.ttl != nil && value.agent != nil && value.applications != nil, "Optional error prevented later section")
            try check(value.errors.count == 2 && value.summary.identity == identity, "Lost valid connection")
            try check(!value.errors[.vpn]!.contains("secret-value"), "Error leaked secret")
        }
        try test("Malformed basic information remains section error with usable launcher") {
            let f = Fixture(); var readers = f.readers()
            readers.information = { try ModemInformationManager.parse("bad", identity: identity, boot: boot) }
            let value = try ConnectionOverview.collect(session: f.session(), readers: readers)
            try check(value.information == nil && value.errors[.information] != nil && value.display?.canInstall == true, "Basic section error disconnected device")
        }
        try test("ADB rejected by both overview overloads before any reader") {
            let f = Fixture(), stub = StatusTransport(), e = try engine(stub)
            try rejects("SSH") { _ = try ConnectionOverview.collect(session: f.session(.adb), readers: f.readers()) }
            try e.locked { try rejects("SSH") { _ = try ConnectionOverview.collect(engine: e, session: f.session(.adb)) } }
            try check(f.readNames.isEmpty && f.summaryCalls == 0 && stub.commands.isEmpty, "ADB caused collection before refusal")
        }
        try test("Device replacement during a successful reader aborts all later readers") {
            let f = Fixture(); let session = f.session(); var readers = f.readers()
            readers.display = { f.proof.identity.cid = String(repeating: "b", count: 32); return ModemDisplayInspection(state: .absent, detail: "", identity: identity, bootID: boot, expectedHash: "") }
            try rejects("изменились") { _ = try ConnectionOverview.collect(session: session, readers: readers) }
            try check(!f.readNames.contains("vpn"), "Continued after target change")
        }
        try test("Device replacement during failed reader is fatal, not isolated error") {
            let f = Fixture(); let session = f.session(); var readers = f.readers()
            readers.display = { f.proof.identity.firmwareHash = String(repeating: "b", count: 64); throw IMEIError.message("module failure") }
            try rejects("изменились") { _ = try ConnectionOverview.collect(session: session, readers: readers) }
            try check(!f.readNames.contains("vpn"), "Continued after failed reader identity drift")
        }
        try test("Reboot during section read discards snapshot") {
            let f = Fixture(); let session = f.session(); var readers = f.readers()
            readers.agent = { f.proof.bootID = UUID().uuidString; return AgentInstallationStatus() }
            try rejects("изменились") { _ = try ConnectionOverview.collect(session: session, readers: readers) }
            try check(!f.readNames.contains("applications"), "Continued after reboot")
        }
        try test("Final public identity refresh detects drift after last section") {
            let f = Fixture(); f.failSummaryAt = 2
            try rejects("перезагрузился") { _ = try ConnectionOverview.collect(session: f.session(), readers: f.readers()) }
        }
        try test("Session and manager engine binding failure happens before readers") {
            let f = Fixture()
            try rejects("engine target mismatch") {
                _ = try ConnectionOverview.collect(session: f.session(), readers: f.readers(), verifyEngine: { throw IMEIError.message("engine target mismatch") })
            }
            try check(f.readNames.isEmpty, "Reader ran against foreign engine")
        }
        try test("Connection loss escapes optional-module isolation") {
            let f = Fixture(); var readers = f.readers()
            readers.ttl = { f.failVerify = true; throw IMEIError.message("timeout") }
            try rejects("Connection lost") { _ = try ConnectionOverview.collect(session: f.session(), readers: readers) }
            try check(!f.readNames.contains("agent"), "Connection loss not fatal")
        }
        try test("Web and agent cannot masquerade as full application connections") {
            for mode in [ConnectionMode.web, .agent] {
                let f = Fixture()
                try rejects("SSH") { _ = try ConnectionOverview.collect(session: f.session(mode), readers: f.readers()) }
                try check(f.readNames.isEmpty, "Weak channel reached readers")
            }
        }
        try test("Inconsistent channel proof rejected before any collection") {
            let f = Fixture(); f.summary.bootID = UUID().uuidString
            try rejects("не совпадают") { _ = try ConnectionOverview.collect(session: f.session(), readers: f.readers()) }
            try check(f.readNames.isEmpty, "Inconsistent proof accepted")
        }
        try test("Agent and TTL use reviewed status payloads without installer staging or common remote lock") {
            let stub = StatusTransport(), e = try engine(stub)
            try e.locked {
                try check(try ConnectionOverview.readAgent(engine: e).hash == "absent", "Agent status")
                try check(try ConnectionOverview.readTTL(engine: e, cid: identity.cid).state == .disabled, "TTL status")
                try check(e.remoteLockToken == nil, "Read status took common remote lock")
            }
            try check(stub.commands.count == 2 && stub.payloadHashes == [AgentInstallationManager.scriptHash, TTLSettingsManager.resourceHashes["manager.sh"]!], "Payloads or actions changed")
        }
        try test("Access and accounts hydrate while caller holds operation lock") {
            let stub = StatusTransport(), e = try engine(stub)
            let value = try e.locked { try ConnectionOverview.readAccess(engine: e, cid: identity.cid) }
            try check(value.services.count == 6 && value.sshAccounts.accounts.isEmpty && !value.sshAccounts.recoveryPending, "Access failed or attempted nested lock")
            try check(stub.commands.count == 2, "Access performed writes")
        }
        try test("Changed bundled status scripts rejected before remote execution") {
            let bad = temp.appendingPathComponent("bad-resources")
            for path in ["AgentInstallation", "TTL", "SSHAccounts"] { try secureDirectory(bad.appendingPathComponent(path)) }
            for path in ["AgentInstallation/manager.sh", "TTL/manager.sh", "SSHAccounts/access-services.sh"] { try savePrivate(Data("malicious".utf8), bad.appendingPathComponent(path)) }
            try saveJSON(["access-services.sh":String(repeating:"a",count:64)], bad.appendingPathComponent("SSHAccounts/SHA256.json"))
            let stub = StatusTransport(), e = try engine(stub, resources: bad)
            try rejects("Повреждён") { _ = try ConnectionOverview.readAgent(engine: e) }
            try rejects("Повреждён") { _ = try ConnectionOverview.readTTL(engine: e, cid: identity.cid) }
            try rejects("Повреждён") { _ = try ConnectionOverview.readAccess(engine: e, cid: identity.cid) }
            try check(stub.commands.isEmpty, "Corrupt payload sent")
        }
        try test("Failed status command never accepts its otherwise valid output") {
            let stub = StatusTransport(); stub.fail = true; let e = try engine(stub)
            try rejects("кодом 1") { _ = try ConnectionOverview.readAgent(engine: e) }
            try rejects("кодом 1") { _ = try ConnectionOverview.readTTL(engine: e, cid: identity.cid) }
        }
        try test("Mislabeled SSH overview refuses an ADB shell before identity or probes") {
            let f = Fixture(), stub = StatusTransport(), e = try engine(stub)
            let adb = f.session(.adb)
            let session = ReadOnlyChannelSession(mode: .ssh, summary: f.summary, diagnosticSession: adb.diagnosticSession) {
                throw Failure.check("Foreign session summary queried")
            }
            try rejects("SSH") { _ = try ConnectionOverview.collect(session: session, readers: f.readers()) }
            try e.locked { try rejects("SSH") { _ = try ConnectionOverview.collect(engine: e, session: session) } }
            try check(stub.commands.isEmpty && f.readNames.isEmpty, "Foreign shell reached readers")
        }
        try test("Quick session permits an explicit agent status without reading other components") {
            let stub = StatusTransport(), e = try engine(stub)
            let proof=SSHReadProof(uid:"0",system:"Linux",architecture:"aarch64",cid:identity.cid,bootID:boot)
            let light=ConnectionDeviceSummary(bootID:boot,fields:["cid":identity.cid,"sshReadOnly":"1","accessProfile":"read-only-ssh"])
            let shell=DiagnosticSession(reason:"quick",proof:proof,readIdentity:{proof},execute:{_,_ in throw Failure.check("Unexpected information reader")})
            let selected=ReadOnlyChannelSession(mode:.ssh,summary:light,diagnosticSession:shell,readSummary:{light})
            let value=try e.locked { try ConnectionOverview.collect(engine:e,session:selected,sections:[.agent]) }
            try check(value.sections == [.agent] && value.agent?.hash == "absent" && value.errors.isEmpty, "Generic profile hid explicit status")
            try check(stub.commands.filter { $0 != SSHReadProof.quickCommand } == ["unset ZTE_AGENT_TEST_ROOT; sh -s -- status"], "Agent status scanned another component")
        }
        try test("Production collector refuses execution without the caller operation lock") {
            let f = Fixture(), stub = StatusTransport(), e = try engine(stub)
            try rejects("блокировки") { _ = try ConnectionOverview.collect(engine: e, session: f.session()) }
            try check(stub.commands.isEmpty, "Unlocked collector reached modem")
        }
        print("\(passed) connection overview tests passed")
    }
}
