import Foundation

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw IMEIError.message(message) } }
private func rejects(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw IMEIError.message("Expected refusal") }
private let cid = "0123456789abcdef0123456789abcdef", boot = "00112233-4455-6677-8899-aabbccddeeff"
private let hash = String(repeating: "a", count: 64)
private func identity(_ firmware: String, _ router: String, _ identifier: String = cid, _ bootID: String = boot) -> Data {
    Data((firmware + "  /firmware/image/modem.b16\n" + router + "  /usr/bin/diag-router\n" + identifier + "\n" + bootID + "\n").utf8)
}
private final class Remote: RemoteTransport {
    var calls = [String](); var raw = identity(hash, hash)
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command); try check(input == nil, "Access probe wrote data")
        return .init(status: 0, stdout: raw, stderr: Data())
    }
}
@main enum AccessIdentityTests {
    static func main() throws {
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); count += 1; print("PASS " + name) }
        try test("Unknown and provably absent component hashes describe access without granting NV") {
            for value in [hash, "absent"] {
                let proof = try AccessIdentity.parse(identity(value, value))
                try check(proof.identity.firmwareHash == value && proof.routerHash == value && AccessIdentity.profile(proof, experimental: false) == "linux-arm64-access", "Unknown identity became known firmware")
                try check(AccessIdentity.policyArguments(proof, profile: "linux-arm64-access") == [cid, "linux-arm64-access", value, value, boot], "Generic policy lost exact hashes or boot")
            }
        }
        try test("Invalid missing and conflicting access proofs refuse") {
            for raw in [identity("unknown", hash), identity("absent", "unreadable"), identity(hash, hash, "missing"), identity(hash, hash, cid, "missing"), identity(hash, hash) + Data("extra\n".utf8), Data()] { try rejects { _ = try AccessIdentity.parse(raw) } }
        }
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("zte-access-identity-" + UUID().uuidString)
        try secureDirectory(directory); defer { try? FileManager.default.removeItem(at: directory) }
        try test("Strict NV identity remains independently enforced") {
            let remote = Remote()
            let engine = try ModemEngine(root: directory.appendingPathComponent("state"), resources: directory, connection: .init(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/hosts"), transport: remote)
            try check(try engine.accessIdentity().0.firmwareHash == hash, "Measured access refused unknown hash")
            try rejects { _ = try engine.identity() }
            remote.raw = identity("absent", "absent")
            try check(try engine.accessIdentity().0.firmwareHash == "absent", "Measured absence unavailable")
            try rejects { _ = try engine.identity() }
            try check(remote.calls.count == 4 && !remote.calls.contains { $0.contains("--snapshot") || $0.contains("zte_nv") }, "Identity test invoked NV")
        }
        try test("Actual shell distinguishes absent regular and symlink files and enforces root Linux ARM64") {
            let fw = directory.appendingPathComponent("firmware"), router = directory.appendingPathComponent("router"), cidFile = directory.appendingPathComponent("cid"), bootFile = directory.appendingPathComponent("boot")
            try savePrivate(Data((cid + "\n").utf8), cidFile); try savePrivate(Data((boot + "\n").utf8), bootFile)
            let script = AccessIdentity.command.replacingOccurrences(of: "/firmware/image/modem.b16", with: fw.path).replacingOccurrences(of: "/usr/bin/diag-router", with: router.path).replacingOccurrences(of: "/sys/block/mmcblk0/device/cid", with: cidFile.path).replacingOccurrences(of: "/proc/sys/kernel/random/boot_id", with: bootFile.path)
            func run(uid: String = "0", os: String = "Linux", arch: String = "aarch64") throws -> CommandResult {
                let prefix = "id() { printf '%s\\n' " + shellQuote(uid) + "; }; uname() { if test \"$1\" = -s; then printf '%s\\n' " + shellQuote(os) + "; else printf '%s\\n' " + shellQuote(arch) + "; fi; }; sha256sum() { /usr/bin/shasum -a 256 \"$@\"; };\n"
                return try HostProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", prefix + script], timeout: 5)
            }
            let absent = try run(); try check(absent.status == 0 && CommandText.decode(absent.stdout).hasPrefix("absent  " + fw.path), "Missing file misreported status=\(absent.status) output=\(CommandText.decode(absent.stdout)) error=\(CommandText.decode(absent.stderr)) path=\(directory.path)")
            try savePrivate(Data("fixture".utf8), fw); try savePrivate(Data("router".utf8), router)
            try check(try run().status == 0, "Regular files not hashed")
            try FileManager.default.removeItem(at: router); try FileManager.default.createSymbolicLink(at: router, withDestinationURL: fw)
            try check(try run().status != 0, "Symlink treated as trusted component")
            try FileManager.default.removeItem(at: router)
            let missingParent = directory.appendingPathComponent("not-present/component")
            let missingScript = script.replacingOccurrences(of: fw.path, with: missingParent.path)
            let prefix = "id() { printf '0\\n'; }; uname() { if test \"$1\" = -s; then printf 'Linux\\n'; else printf 'aarch64\\n'; fi; }; sha256sum() { /usr/bin/shasum -a 256 \"$@\"; };\n"
            let missing = try HostProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", prefix + missingScript], timeout: 5)
            try check(missing.status == 0 && CommandText.decode(missing.stdout).contains("absent  " + missingParent.path), "Securely missing parent cannot be observed")
            let linkedParent = directory.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: directory)
            let linkedScript = script.replacingOccurrences(of: fw.path, with: linkedParent.appendingPathComponent("missing").path)
            try check(try HostProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", prefix + linkedScript], timeout: 5).status != 0, "Symlink ancestor produced false absence")
            for (uid, os, arch) in [("2000", "Linux", "aarch64"), ("0", "Darwin", "aarch64"), ("0", "Linux", "armv7l")] { try check(try run(uid: uid, os: os, arch: arch).status != 0, "Access platform gate bypassed") }
        }
        print("RESULT \(count) passed; 0 failed")
    }
}
