import Foundation
private func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw IMEIError.message(text) } }
private func reject(_ block: () throws -> Void) throws { do { try block() } catch { return }; throw IMEIError.message("Expected refusal") }
@main enum AgentInstallationTests {
    static func main() throws {
        let fm = FileManager.default, root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let bundled = root.appendingPathComponent("Resources/Onboarding/zte-agent")
        let candidate = try AgentCandidate.inspect(bundled)
        try check(candidate.sha256 == VPNSettingsManager.agentHash && candidate.sha256 == BundledAgent.sha256, "Bundled ELF not accepted")
        let esim = try Data(contentsOf: root.appendingPathComponent("Resources/Esim/zte-agent-esim"))
        try check(digest(esim) == candidate.sha256, "Install and temporary eSIM agent must be identical")
        try check(BundledAgent.description(for: candidate.sha256).hasPrefix(BundledAgent.version), "Current agent version not recognized")
        try check(BundledAgent.description(for: "3da0915669ca101fe8b2faef3d683405957a2fbd49000a58257d28868321b3df").hasPrefix("2.7.0-vpn.1"), "Legacy agent recognition lost")
        try check(BundledAgent.description(for: String(repeating: "0", count: 64)) == "Другая сборка / свой агент", "Unknown agent must remain unknown")
        try check(BundledAgent.supportedUpgradeHashes.contains("c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346"), "Previous public agent upgrade lost")
        try check(BundledAgent.description(for: "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346").hasPrefix("2.8.0"), "Previous public agent unknown")
        let original = try Data(contentsOf: bundled)
        let temp = fm.temporaryDirectory.appendingPathComponent("zte-agent-candidate-" + UUID().uuidString)
        try secureDirectory(temp); defer { try? fm.removeItem(at: temp) }
        var cases = 0
        func invalid(_ mutate: (inout Data) -> Void) throws {
            var data = original; mutate(&data); try reject { _ = try AgentCandidate.validateELF(data) }; cases += 1
        }
        try invalid { $0[18] = 62; $0[19] = 0 } // x86-64
        try invalid { $0[4] = 1 } // ELF32
        try invalid { $0[5] = 2 } // big endian
        try invalid { $0[16] = 1 } // relocatable object
        try invalid { $0[56] = 0; $0[57] = 0 } // no program table
        try invalid { $0[32] = 0xff; $0[39] = 0xff } // offset overflow
        try invalid { $0 = Data($0.prefix(100)) } // truncated segments
        try invalid { $0.replaceSubrange(0..<4, with: Data([0xcf,0xfa,0xed,0xfe])) } // Mach-O
        let symlink = temp.appendingPathComponent("agent"); try fm.createSymbolicLink(at: symlink, withDestinationURL: bundled)
        try reject { _ = try AgentCandidate.inspect(symlink) }
        let archive = temp.appendingPathComponent("agent.zip"); try savePrivate(Data(repeating: 0x50, count: 1024), archive)
        try reject { _ = try AgentCandidate.inspect(archive) }
        let valid = try AgentInstallationStatus.parse("AGENT_SHA " + candidate.sha256 + "\nAGENT_RUNNING yes\nAGENT_STARTUP yes\nAGENT_BACKUP " + candidate.sha256)
        try check(valid.running && valid.startupReady && valid.backupHash != nil, "Status incorrect")
        for text in ["", "AGENT_SHA ../../bad", "AGENT_SHA absent\nAGENT_SHA absent", "AGENT_SHA absent\nAGENT_BACKUP not-a-hash"] { try reject { _ = try AgentInstallationStatus.parse(text) } }
        let script = try Data(contentsOf: root.appendingPathComponent("Resources/AgentInstallation/manager.sh"))
        try check(digest(script) == AgentInstallationManager.scriptHash, "Installer integrity pin stale")
        print("PASS bundled ARM64 ELF, \(cases) incompatible/corrupt ELF variants, symlink/archive rejection, status parsing and installer integrity")
    }
}
