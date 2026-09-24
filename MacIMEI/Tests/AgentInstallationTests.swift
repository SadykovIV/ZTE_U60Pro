import Foundation
private func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw IMEIError.message(text) } }
private func reject(_ block: () throws -> Void) throws { do { try block() } catch { return }; throw IMEIError.message("Expected refusal") }
@main enum AgentInstallationTests {
    static func main() throws {
        let fm = FileManager.default, root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let bundled = root.appendingPathComponent("Resources/Onboarding/zte-agent")
        let candidate = try AgentCandidate.inspect(bundled)
        try check(candidate.sha256 == VPNSettingsManager.agentHash, "Bundled ELF not accepted")
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
