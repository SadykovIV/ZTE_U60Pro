import Foundation
import Darwin

private struct FixtureFailure: Error {}
private let cid = String(repeating: "a", count: 32)
private let boot = "11111111-1111-1111-1111-111111111111"
private let firmware = String(repeating: "b", count: 64)
private let router = String(repeating: "c", count: 64)

private final class NoWeb: WebTransport {
    func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply { throw FixtureFailure() }
}
private struct NoHost: HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult { throw FixtureFailure() }
}
private final class ReadySSH: RemoteTransport {
    let journal: String, scenario: String, source: Data
    var identityCalls = 0, proofCalls = 0, commits = 0, cleanups = 0, unexpected = 0
    init(journal: String, scenario: String, source: Data) { self.journal = journal; self.scenario = scenario; self.source = source }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        func answer(_ text: String, status: Int32 = 0) -> CommandResult { .init(status: status, stdout: Data(text.utf8), stderr: Data()) }
        if command == AccessIdentity.command {
            identityCalls += 1
            let observedBoot = scenario == "boot-changed" && identityCalls > 1 ? "22222222-2222-2222-2222-222222222222" : boot
            return answer("\(firmware)  /firmware/image/modem.b16\n\(router)  /usr/bin/diag-router\n\(cid)\n\(observedBoot)\n")
        }
        if command.hasPrefix("sh -s -- "), input == Data(OnboardingEngine.readyReinstallProofScript.utf8) {
            guard command.contains(shellQuote(digest(source))) else { throw FixtureFailure() }
            proofCalls += 1
            return answer(scenario == "proof-failed" ? "" : "INSTALL_READY_UNCHANGED", status: scenario == "proof-failed" ? 71 : 0)
        }
        if command.contains("'--commit'") {
            commits += 1
            return answer(scenario == "commit-lost" ? "" : "INSTALL_COMMITTED " + journal + "\n", status: scenario == "commit-lost" ? 255 : 0)
        }
        if command.hasPrefix("test -d "), command.contains("rm -f"), command.contains("; rmdir ") { cleanups += 1; return answer("") }
        unexpected += 1; throw FixtureFailure()
    }
}

@main enum ReadyCleanTests {
    static func main() throws {
        let fm = FileManager.default, resources = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")
        let source = try Data(contentsOf: resources.appendingPathComponent("Onboarding/setup-agent.sh"))
        let base = fm.temporaryDirectory.appendingPathComponent("zte-ready-clean-" + UUID().uuidString)
        try secureDirectory(base); defer { try? fm.removeItem(at: base) }
        var passed = 0
        for scenario in ["legacy-ready", "generic-complete", "proof-failed", "commit-lost", "boot-changed", "not-ready"] {
            let root = base.appendingPathComponent(scenario), id = UUID().uuidString.lowercased()
            let generic = scenario == "generic-complete"
            // Legacy backup UUID is intentionally distinct from its install UUID.
            let backup = root.appendingPathComponent("SetupBackups/" + (generic ? id : UUID().uuidString.lowercased()))
            try secureDirectory(backup); try secureDirectory(root.appendingPathComponent("SSH"))
            let key = root.appendingPathComponent("SSH/id_ed25519"), known = root.appendingPathComponent("SSH/known_hosts")
            try savePrivate(Data("synthetic-key\n".utf8), key); try savePrivate(Data("synthetic-host\n".utf8), known)
            let paths = try SetupRemotePaths(id: id, installRequested: false, stage: nil, journal: nil)
            let phase = scenario == "not-ready" ? "install-requested" : (generic ? "complete" : "ready")
            let raw: Data
            if generic {
                let saved = AccessSetupJournal(id: id, cid: cid, bootID: boot, firmwareHash: firmware, routerHash: router,
                    installerProfile: "linux-arm64-access", directory: backup.path, adbSerial: "synthetic", phase: phase,
                    installRequested: true, forceReinstall: false, cleanComponents: false, remoteJournal: paths.journal, remoteStage: paths.stage)
                raw = try JSONEncoder().encode(saved)
            } else {
                let identity = try WebIdentity(["imei":"353490068701222", "integrate_version":"CN_ZTE_MU5250V1.0.0B31", "wa_inner_version":"BD_CNMU5250V1.0.0B31"])
                let saved = SetupJournal(id: id, identity: identity, phase: phase, directory: backup.path,
                    installRequested: true, forceReinstall: false, cleanComponents: false, cid: cid,
                    remoteJournal: paths.journal, remoteStage: paths.stage, newAgent: false,
                    installerProfile: "b31", firmwareHash: firmware, routerHash: router)
                raw = try JSONEncoder().encode(saved)
            }
            let pending = root.appendingPathComponent("setup-pending.json")
            try savePrivate(raw, pending)
            let ssh = ReadySSH(journal: paths.journal, scenario: scenario, source: source)
            let connection = Connection(host: "192.0.2.1", port: "2222", keyPath: key.path, knownHostsPath: known.path, skipFirmwareCheck: false)
            let web = try ModemWebClient(host: connection.host, transport: NoWeb())
            let engine = try OnboardingEngine(root: root, resources: resources, connection: connection, web: web, runner: NoHost(), sshFactory: { _ in ssh })
            var succeeded = false
            do { try engine.finishReadyBeforeCleanReinstall(); succeeded = true } catch {}
            let expectedSuccess = scenario == "legacy-ready" || generic
            try require(succeeded == expectedSuccess && ssh.unexpected == 0, "Unexpected ready-clean outcome: " + scenario)
            if expectedSuccess {
                try require(ssh.commits == 1 && ssh.proofCalls == 1 && ssh.identityCalls == 2 && ssh.cleanups == 1,
                            "Original commit must occur exactly once, without authentication or installation")
                try require(!fm.fileExists(atPath: pending.path) && (try Data(contentsOf: backup.appendingPathComponent("before-clean-reinstall.json"))) == raw,
                            "Original pending must be archived before it is removed")
                // Re-entering the reconciler after success is a no-op, not replay.
                try engine.finishReadyBeforeCleanReinstall()
                try require(ssh.commits == 1 && ssh.proofCalls == 1, "Completed old intent was replayed")
            } else {
                try require(try Data(contentsOf: pending) == raw, "Uncertain outcome changed pending")
                try require(ssh.cleanups == 0 && !fm.fileExists(atPath: backup.appendingPathComponent("before-clean-reinstall.json").path), "Uncertain outcome discarded old evidence")
                if scenario == "not-ready" { try require(ssh.identityCalls == 0 && ssh.commits == 0, "Unknown phase reached SSH") }
                if scenario == "proof-failed" { try require(ssh.commits == 0, "Failed proof reached commit") }
            }
            passed += 1; print("PASS " + scenario)
        }
        print("RESULT \(passed) passed; 0 failed; no device")
    }
}
