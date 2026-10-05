import Foundation
import Darwin

@main enum AccessAgentReuseTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("access-agent-proof-" + UUID().uuidString)
        try secureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent"), process = root.appendingPathComponent("proc/123")
        try secureDirectory(process); try savePrivate(Data("synthetic agent".utf8), agent)
        try FileManager.default.createSymbolicLink(atPath: process.appendingPathComponent("exe").path, withDestinationPath: agent.path)
        let fields = ["S"] + Array(repeating: "0", count: 18) + ["5678", "0"]
        try savePrivate(Data(("123 (zte-agent) " + fields.joined(separator: " ") + "\n").utf8), process.appendingPathComponent("stat"))
        let hash = digest(try Data(contentsOf: agent))
        func run(_ environment: [String], discovery: Bool = true, pids: String = "123") throws -> CommandResult {
            try savePrivate(Data((environment.joined(separator: "\0") + "\0").utf8), process.appendingPathComponent("environ"))
            let script = "pidof() { printf '%s\\n' " + shellQuote(pids) + "; }; " + AccessAgentProcessProof.command(discovery: discovery, host: "192.0.2.1")
                .replacingOccurrences(of: "/data/zte-agent", with: agent.path)
                .replacingOccurrences(of: "/proc/$p/", with: root.appendingPathComponent("proc").path + "/$p/")
            return try HostProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: 3)
        }
        let valid = ["ZTE_AGENT_MODE=discovery", "ZTE_AGENT_BIND=192.0.2.1:9090"]
        let good = try run(valid)
        let exact = Data(("AGENT_ACCESS_READY 123 5678 " + hash + " " + hash + "\n").utf8)
        try require(good.stdout == exact, "Discovery proof did not emit exactly five fields and one LF")
        try require(good.status == 0 && AccessAgentProcessProof.parse(good.stdout, allowedHashes: [hash]).diskHash == hash, "Valid mapped process refused")
        print("PASS actual shell validates disk, mapped executable, PID/starttime and discovery environment")
        let normal = try run([], discovery: false)
        try require(normal.status == 0 && normal.stdout == exact && AccessAgentProcessProof.parse(normal.stdout, allowedHashes: [hash]).startTime == "5678", "Normal proof shell or parser rejected exact LF output")
        let literalNewline = Data(("AGENT_ACCESS_READY 123 5678 " + hash + " " + hash + "\\n").utf8)
        try require((try? AccessAgentProcessProof.parse(literalNewline, allowedHashes: [hash])) == nil, "Literal backslash-n accepted as a mapped hash")
        print("PASS normal-mode actual shell emits five fields and LF; literal backslash-n is rejected")
        for invalid in [valid + ["ZTE_AGENT_MODE=normal"], ["ZTE_AGENT_MODE=normal"] + valid, valid + ["ZTE_AGENT_MODE=discovery"], valid + ["ZTE_AGENT_BIND=192.0.2.2:9090"], valid + ["ZTE_AGENT_BIND=192.0.2.1:9090"], ["ZTE_AGENT_MODE=normal", valid[1]], [valid[0]]] {
            try require(run(invalid).status == 72, "Duplicate/invalid environment granted discovery")
        }
        print("PASS seven duplicate missing and wrong environment cases refused")
        try require(run(valid, pids: "123 123").status == 72, "Duplicate processes accepted")
        print("PASS more than one matching process refused")
        let other = root.appendingPathComponent("other"); try savePrivate(Data("different".utf8), other)
        try FileManager.default.removeItem(at: process.appendingPathComponent("exe"))
        try FileManager.default.createSymbolicLink(atPath: process.appendingPathComponent("exe").path, withDestinationPath: other.path)
        try require(run(valid).status == 72, "Wrong mapped path accepted")
        print("PASS unrelated mapped path refused")
        let proof = DiagnosticDeviceProof(identity: Identity(cid: String(repeating: "a", count: 32), firmwareHash: ModemEngine.firmwareHash), routerHash: ModemEngine.routerHash, bootID: "01234567-89ab-4cde-8f01-23456789abcd", webIdentity: nil)
        try require(AccessAgentReusePolicy.allowedHashes(latest: hash, proof: proof, profile: "b31", reuseExisting: true) == [hash, AccessAgentReusePolicy.previousSHA256, AccessAgentReusePolicy.publishedPreviousSHA256], "Historical access policy")
        try require(AccessAgentReusePolicy.allowedHashes(latest: hash, proof: proof, profile: "b31", reuseExisting: false) == [hash], "New install policy widened")
        try require(AccessAgentReusePolicy.allowedHashes(latest: hash, proof: proof, profile: "linux-arm64-access", reuseExisting: true) == [hash], "Generic policy widened")
        print("PASS access-only historical policy remains separate from generic and new installation")
        print("RESULT 6 groups passed; 0 failed")
    }
}
