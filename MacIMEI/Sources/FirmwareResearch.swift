import Foundation
import Darwin

struct ResearchText: Codable, Sendable { let ru: String; let en: String; func text(_ language: String) -> String { language == "en" ? en : ru } }
struct ResearchProfile: Codable, Sendable { let id: String; let firmwareSHA256: String; let routerSHA256: String; let architecture: String }
struct ResearchProbe: Codable, Sendable { let id: String; let title: ResearchText; let category: String; let command: String; let timeoutSeconds: Int; let maxBytes: Int }
struct ResearchRequirement: Codable, Sendable { let probe: String; let fact: String; let equals: String; let label: ResearchText; var platforms: [String]? = nil }
struct ResearchFeature: Codable, Sendable { let id: String; let title: ResearchText; let profiles: [String]; let platforms: [String]?; let requirements: [ResearchRequirement]; let limitations: ResearchText }
struct ResearchObservation: Codable, Sendable { let id: String; let title: ResearchText; let probe: String; let fact: String }
struct ResearchObservationResult: Codable, Sendable, Identifiable { let id: String; let title: ResearchText; let probe: String; let fact: String; let state: String; let value: String?; var sourceStatus: String? = nil; var sourceExitCode: Int32? = nil; var reason: String? = nil }
struct ResearchSpecification: Codable, Sendable {
    // Updated only when the reviewed, bundled command allowlist changes.
    static let expectedSHA256 = "88a58d72e3dda052d6468ac933099a2cf2c6d48f7a872727f73155bb9d7c9845"
    let schemaVersion: Int; let revision: Int; let profiles: [ResearchProfile]; let probes: [ResearchProbe]; let features: [ResearchFeature]
    var observations: [ResearchObservation]? = nil
    static func load(_ resources: URL) throws -> Self {
        let path = resources.appendingPathComponent("FirmwareResearch/probes.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        try require(fd >= 0, "Research specification is unavailable")
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= 1_048_576, "Invalid research specification file")
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1_048_577) ?? Data()
        try require(data.count <= 1_048_576 && digest(data) == expectedSHA256, "Research command allowlist integrity check failed")
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func validate() throws {
        try require(schemaVersion == 1 && (1...64).contains(probes.count), "Unsupported research specification")
        let ids = probes.map(\.id)
        try require(Set(ids).count == ids.count, "Duplicate research probe")
        for item in probes {
            try require(item.id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil && (1...120).contains(item.timeoutSeconds) && (128...262144).contains(item.maxBytes) && item.command.utf8.count <= 32768, "Invalid research probe")
        }
        try require(Set((observations ?? []).map(\.id)).count == (observations ?? []).count && (observations ?? []).count <= 256, "Invalid research observations")
        for item in observations ?? [] { try require(ids.contains(item.probe) && item.fact.range(of: #"^[a-z0-9_]{1,80}$"#, options: .regularExpression) != nil, "Unknown observation source") }
        for feature in features { for requirement in feature.requirements { try require(ids.contains(requirement.probe), "Unknown research prerequisite") } }
    }
}

final class ResearchCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var requested = false
    private let external: @Sendable () -> Bool
    init(external: @escaping @Sendable () -> Bool = { false }) { self.external = external }
    func cancel() { lock.lock(); requested = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); let local = requested; lock.unlock(); return local || external() }
}
struct ResearchCommandResult: Sendable {
    var status: Int32; var stdout: Data; var stderr: Data; var outcome: String; var duration: Double
    var localExitCode: Int32? = nil; var remoteExitCode: Int32? = nil
}
protocol ResearchProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation) throws -> ResearchCommandResult
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation, input: ADBStreamInput?) throws -> ResearchCommandResult
}
extension ResearchProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation, input: ADBStreamInput?) throws -> ResearchCommandResult {
        try require(input == nil, "Research transport cannot stream ADB input")
        return try run(executable, arguments: arguments, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation)
    }
}
/// Drains both pipes continuously while retaining a shared bounded prefix. No unbounded temp files.
final class ResearchBoundedRunner: ResearchProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation, input: ADBStreamInput?) throws -> ResearchCommandResult {
        guard let input else { return try run(executable, arguments: arguments, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation) }
        return try ADBStreamProcess.run(executable, arguments: arguments, input: input, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation)
    }
    private final class Capture: @unchecked Sendable {
        let lock = NSLock(); var stdout = Data(); var stderr = Data(); var clipped = false; let limit: Int
        init(_ limit: Int) { self.limit = limit }
        func append(_ data: Data, error: Bool) { lock.lock(); defer { lock.unlock() }; let left = max(0, limit - stdout.count - stderr.count); if data.count > left { clipped = true }; if error { stderr.append(data.prefix(left)) } else { stdout.append(data.prefix(left)) } }
        func snapshot() -> (Data, Data, Bool) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr, clipped) }
    }
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation) throws -> ResearchCommandResult {
        if cancellation.cancelled { return ResearchCommandResult(status: -1, stdout: Data(), stderr: Data(), outcome: "cancelled", duration: 0) }
        let process = Process(), out = Pipe(), err = Pipe(), capture = Capture(maxBytes)
        process.executableURL = executable; process.arguments = arguments; process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = err
        let started = ProcessInfo.processInfo.systemUptime
        try process.run()
        // Close parent write ends so a terminated child cannot keep readers alive.
        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        let group = DispatchGroup()
        for (handle, isError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
            group.enter(); DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); group.leave() }
                while let data = try? handle.read(upToCount: 8192), !data.isEmpty { capture.append(data, error: isError) }
            }
        }
        var outcome = "success"
        while process.isRunning {
            if cancellation.cancelled { outcome = "cancelled"; break }
            if capture.snapshot().2 { outcome = "truncated"; break }
            if ProcessInfo.processInfo.systemUptime - started >= timeout { outcome = "timeout"; break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { process.terminate(); let deadline = Date().addingTimeInterval(0.3); while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }; if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        // Descendants inheriting stdout must not stall report cancellation forever.
        if group.wait(timeout: .now() + 1) == .timedOut {
            if outcome == "success" { outcome = "timeout" }
            capture.append(Data("\nOutput stream did not close; captured data is incomplete.\n".utf8), error: true)
            try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
        }
        let (stdout, stderr, clipped) = capture.snapshot()
        if outcome == "success" { outcome = clipped ? "truncated" : process.terminationStatus == 0 ? "success" : "failed" }
        return ResearchCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, outcome: outcome, duration: ProcessInfo.processInfo.systemUptime - started, localExitCode: process.terminationStatus)
    }
}

struct ResearchProbeResult: Codable, Sendable, Identifiable {
    let id: String; let title: ResearchText; let category: String; let command: String
    let outcome: String; let exitCode: Int32?; let stdout: String; let stderr: String; let durationSeconds: Double; let facts: [String: String]
    var localExitCode: Int32? = nil; var remoteExitCode: Int32? = nil
}
struct ResearchFeatureResult: Codable, Sendable, Identifiable {
    let id: String; let title: ResearchText; let state: String; let evidence: [ResearchText]; let limitations: ResearchText
}
struct ResearchConnectionAttempt: Codable, Sendable { let transport: String; let outcome: String; let detail: String }
struct FirmwareResearchReport: Codable, Sendable {
    var schemaVersion = 1; var id = UUID().uuidString.lowercased(); var startedAt: String; var finishedAt = ""
    var specificationRevision: Int; var transport = "none"; var outcome = "collecting"; var profile: String?
    var bindingStrength: String? = nil
    var authorization: String? = nil
    var continuityVerified: Bool? = nil
    var observations: [ResearchObservationResult]? = nil
    var bootstrapCommand = FirmwareResearchCollector.bootstrap
    var binding: [String: String] = [:]; var attempts: [ResearchConnectionAttempt] = []; var warnings: [String] = []
    var probes: [ResearchProbeResult] = []; var features: [ResearchFeatureResult] = []; var application: [String: String]
}

struct ResearchRedactor {
    var secrets: [String]
    func clean(_ text: String) -> String {
        var result = text
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
        result = ActivityJournal.sanitize(result)
        for pattern in [#"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#, #"(?i)\b[0-9a-f]{32}\b"#, #"(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"#, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#] {
            result = result.replacingOccurrences(of: pattern, with: "[identifier-redacted]", options: .regularExpression)
        }
        return result
    }
    func output(_ data: Data) -> String {
        guard !data.contains(0) else { return "[binary output omitted]" }
        return clean(CommandText.decode(data))
    }
}

final class FirmwareResearchCollector {
    static let totalLimit = 16 * 1024 * 1024
    static let bootstrap = """
    printf 'uid='; id -u; printf 'architecture='; uname -m
    zte_hash=none
    if command -v sha256sum >/dev/null 2>&1; then zte_hash=sha256sum
    elif command -v busybox >/dev/null 2>&1 && busybox sha256sum /dev/null >/dev/null 2>&1; then zte_hash=busybox; fi
    for zte_key in cid boot; do
      if test "$zte_key" = cid; then zte_file=/sys/block/mmcblk0/device/cid; else zte_file=/proc/sys/kernel/random/boot_id; fi
      printf '%s=' "$zte_key"
      if test "$zte_hash" = sha256sum; then sha256sum "$zte_file" 2>/dev/null | cut -d ' ' -f 1
      elif test "$zte_hash" = busybox; then busybox sha256sum "$zte_file" 2>/dev/null | cut -d ' ' -f 1
      fi
      printf '\n'
    done
    """
    let specification: ResearchSpecification; let connection: Connection; let mode: ConnectionMode; let resources: URL
    let cancellation: ResearchCancellation; let runner: ResearchProcessRunning; let expectedCID: String?
    let timeLimit: TimeInterval?
    var redactor: ResearchRedactor
    init(specification: ResearchSpecification, connection: Connection, mode: ConnectionMode, resources: URL, cancellation: ResearchCancellation, expectedCID: String?, secrets: [String], runner: ResearchProcessRunning = ResearchBoundedRunner(), timeLimit: TimeInterval? = 8 * 60) {
        self.specification = specification; self.connection = connection; self.mode = mode; self.resources = resources; self.cancellation = cancellation; self.expectedCID = expectedCID; self.redactor = ResearchRedactor(secrets: secrets + [expectedCID ?? ""]); self.runner = runner
        self.timeLimit = timeLimit
    }
    private var sshArguments: [String] {
        ["-F", "/dev/null", "-T", "-p", connection.port, "-i", connection.keyPath,
         "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
         "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=\"" + connection.knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"", "root@" + connection.host]
    }
    private func execute(_ command: String, transport: String, serial: String, timeout: Int, limit: Int, deadline: Date) throws -> ResearchCommandResult {
        let commandDeadline = min(deadline, Date().addingTimeInterval(TimeInterval(timeout)))
        func remaining() throws -> TimeInterval {
            let value = commandDeadline.timeIntervalSinceNow
            try require(value > 0 && !cancellation.cancelled, "Research time limit reached or cancelled before the next command.")
            return value
        }
        if transport == "ssh" {
            var result = try runner.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: sshArguments + [command], timeout: try remaining(), maxBytes: limit, cancellation: cancellation)
            result.localExitCode = result.localExitCode ?? (result.status >= 0 ? result.status : nil)
            if (result.outcome == "success" || result.outcome == "failed") && result.status != 255 { result.remoteExitCode = result.status }
            return result
        }
        let physical = try runner.run(resources.appendingPathComponent("Onboarding/adb"), arguments: ["-d", "get-serialno"], timeout: min(try remaining(), 5), maxBytes: 4096, cancellation: cancellation)
        let physicalSerial = CommandText.decode(physical.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(physical.outcome == "success" && physical.status == 0 && physicalSerial == serial,
                    "Physical USB identity is unavailable or changed; collection stopped without selecting another transport.")
        let plan = try ADBShellPlan.make(command, templateURL: resources.appendingPathComponent("Onboarding/adb-stream.sh"))
        var result = try runner.run(resources.appendingPathComponent("Onboarding/adb"), arguments: ["-s", serial, "shell", plan.command], timeout: try remaining(), maxBytes: limit, cancellation: cancellation, input: plan.input)
        result.localExitCode = result.localExitCode ?? (result.status >= 0 ? result.status : nil)
        if result.outcome == "success" {
            do { let decoded = try plan.decode(CommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr), original: command); result.status = decoded.status; result.remoteExitCode = decoded.status; result.stdout = decoded.stdout; result.outcome = decoded.status == 0 ? "success" : "failed" }
            catch { result.outcome = "failed"; result.stderr.append(Data(("\n" + error.localizedDescription).utf8)) }
        }
        return result
    }
    static func binding(_ data: Data) -> [String: String] {
        var values = [String: String](), seen = Set<String>(), duplicates = Set<String>()
        for line in CommandText.decode(data).split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, ["uid", "architecture", "cid", "boot"].contains(String(pair[0])) else { continue }
            let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = String(pair[0])
            if !seen.insert(key).inserted { duplicates.insert(key) }
            if key == "cid" || key == "boot" {
                if value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { values[key] = value }
            } else if !value.isEmpty && value.utf8.count <= 128 { values[key] = value }
        }
        for key in duplicates { values.removeValue(forKey: key) }
        return values
    }
    static func bindingStrength(_ value: [String: String]) -> String {
        let count = ["cid", "boot"].filter { value[$0] != nil }.count
        return count == 2 ? "full" : count == 1 ? "partial" : "transport-only"
    }
    static func sameDevice(_ initial: [String: String], _ later: [String: String]) -> Bool {
        initial.allSatisfy { later[$0.key] == $0.value }
    }
    static func facts(_ output: String) -> [String: String] {
        var result = [String: String](), duplicates = Set<String>()
        for line in CommandText.normalize(output).split(whereSeparator: \.isNewline) where line.hasPrefix("FR_FACT ") {
            let pair = line.dropFirst(8).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].range(of: #"^[a-z0-9_]{1,80}$"#, options: .regularExpression) != nil, pair[1].utf8.count <= 512, pair[1].utf8.allSatisfy({ (32...126).contains($0) }) else { continue }
            let key = String(pair[0]); if result[key] != nil { duplicates.insert(key) }; result[key] = String(pair[1])
        }
        for duplicate in duplicates { result[duplicate] = "conflicting" }
        return result
    }
    private static func unavailable(_ value: ResearchCommandResult) -> Bool {
        let text = String(decoding: value.stderr, as: UTF8.self).lowercased()
        return (value.status == 255 || value.outcome == "timeout") && ["connection refused", "connection timed out", "operation timed out", "no route to host", "network is unreachable", "host is down"].contains(where: text.contains)
    }
    func collect(context: [String: String], progress: (FirmwareResearchReport, Double) -> Void) -> FirmwareResearchReport {
        var report = FirmwareResearchReport(startedAt: ISO8601DateFormatter().string(from: Date()), specificationRevision: specification.revision, application: context.mapValues(redactor.clean))
        var transport = "", serial = "", original = [String: String](), total = 0
        var continuityLost = false
        let deadline = timeLimit.map { Date().addingTimeInterval($0) } ?? Date.distantFuture
        // sysfs/proc identity files include a newline; retain only their digest.
        let expectedCIDHash = expectedCID.map { digest(Data(($0 + "\n").utf8)) }
        func attempt(_ channel: String, _ outcome: String, _ message: String) { report.attempts.append(.init(transport: channel, outcome: outcome, detail: redactor.clean(message))) }
        do {
            try specification.validate()
            try require(mode == .automatic || mode == .ssh || mode == .adb, "Firmware research requires SSH or USB ADB. Select automatic, SSH or ADB; manual WEB/agent mode does not switch channels.")
            if mode != .adb {
                if FileManager.default.isReadableFile(atPath: connection.keyPath) && FileManager.default.isReadableFile(atPath: connection.knownHostsPath) {
                    try connection.validate()
                    let value = try execute(Self.bootstrap, transport: "ssh", serial: "", timeout: 12, limit: 16384, deadline: deadline)
                    let detail = String(decoding: value.stderr, as: UTF8.self)
                    if DiagnosticTransportSelector.hostTrustFailure(detail) { attempt("ssh", "host_trust_failed", detail); throw IMEIError.message("SSH host trust failed; automatic fallback is stopped.") }
                    if value.outcome == "success" { original = Self.binding(value.stdout); transport = "ssh"; attempt("ssh", "available", "Strict SSH host key verification passed; firmware research does not require a known firmware hash or root.") }
                    else { attempt("ssh", value.outcome == "cancelled" ? "cancelled" : Self.unavailable(value) ? "unavailable" : "authentication_or_shell_failed", detail); try require(mode == .automatic && Self.unavailable(value), "SSH failed; a responding or untrusted endpoint is not bypassed with ADB.") }
                } else { attempt("ssh", "unconfigured", "SSH key or known_hosts file is unavailable."); try require(mode == .automatic, "Manual SSH mode requires SSH key and known_hosts files.") }
            }
            if transport.isEmpty {
                let hashes = try readJSON([String: String].self, resources.appendingPathComponent("Onboarding/SHA256.json"))
                let adb = resources.appendingPathComponent("Onboarding/adb")
                try require(hashes["adb"] == digest(Data(contentsOf: adb)), "Bundled ADB integrity check failed")
                let version = try runner.run(adb, arguments: ["version"], timeout: 5, maxBytes: 4096, cancellation: cancellation)
                attempt("adb", "host_tool_version", redactor.output(version.stdout + version.stderr))
                let devices = try runner.run(adb, arguments: ["devices", "-l"], timeout: 12, maxBytes: 65536, cancellation: cancellation)
                try require(devices.outcome == "success", "ADB device enumeration failed: " + redactor.output(devices.stderr))
                for line in CommandText.decode(devices.stdout).split(whereSeparator: \.isNewline) {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    if fields.count > 1 && ["device", "offline", "unauthorized", "no"].contains(String(fields[1])) { redactor.secrets.append(String(fields[0])) }
                }
                let serials = try DiagnosticTransportSelector.usbSerials(devices.stdout)
                redactor.secrets += serials
                attempt("adb", "enumerated", "Authorized USB ADB devices: \(serials.count). " + redactor.output(devices.stdout))
                try require(!serials.isEmpty, "No authorized USB ADB device. Research does not enable ADB or prepare the modem.")
                try require(serials.count <= 16, "Too many USB ADB devices for a bounded research selection.")
                try require(serials.count == 1 || expectedCID != nil, "Multiple USB ADB devices and no expected modem identity; no device was selected.")
                var matches = [(String, [String: String])]()
                for candidate in serials {
                    try require(!cancellation.cancelled && Date() < deadline, "Research device selection stopped or exceeded its time limit.")
                    let value = try execute(Self.bootstrap, transport: "adb", serial: candidate, timeout: 12, limit: 16384, deadline: deadline)
                    let identity = Self.binding(value.stdout)
                    if value.outcome != "success" { attempt("adb", value.outcome, redactor.output(value.stderr)); continue }
                    if let expectedCIDHash, let found = identity["cid"], expectedCIDHash != found { attempt("adb", "identity_mismatch", "USB ADB device did not match the expected modem."); continue }
                    if serials.count > 1 && identity["cid"] != expectedCIDHash { continue }
                    matches.append((candidate, identity))
                }
                try require(matches.count == 1, "USB ADB did not identify exactly one matching modem.")
                (serial, original) = matches[0]; transport = "adb"; redactor.secrets.append(serial)
                attempt("adb", "available", original["uid"] == "0" ? "USB ADB root shell is available." : "USB ADB is available without confirmed root; privilege-dependent results may be unknown.")
            }
            report.transport = transport; report.binding = original.mapValues(redactor.clean)
            report.bindingStrength = Self.bindingStrength(original); report.authorization = "none"
            if report.bindingStrength == "transport-only" { report.warnings.append("CID and boot fingerprints are unavailable. Read-only observations use the same transport endpoint; device continuity is not proven and no writes are authorized.") }
            if let expectedCIDHash, let found = original["cid"] { try require(expectedCIDHash == found, "Connected modem identity differs from the expected modem.") }
            if original["cid"] == nil || original["boot"] == nil { report.warnings.append("CID or boot ID is unavailable. Device continuity has limited evidence; missing facts are not treated as compatible.") }
            if transport == "adb" && expectedCID == nil { report.warnings.append("The sole USB ADB device was selected. Its relationship to the configured WEB IP address is not established.") }
            for (index, probe) in specification.probes.enumerated() {
                if cancellation.cancelled { report.outcome = "cancelled"; break }
                if Date() >= deadline { report.outcome = "partial"; report.warnings.append("The eight-minute research time limit was reached."); break }
                if total >= Self.totalLimit { report.outcome = "partial"; report.warnings.append("The 16 MiB collection limit was reached."); break }
                let before = try execute(Self.bootstrap, transport: transport, serial: serial, timeout: min(12, max(1, Int(deadline.timeIntervalSinceNow))), limit: 16384, deadline: deadline)
                if before.outcome != "success" || !Self.sameDevice(original, Self.binding(before.stdout)) { continuityLost = true; throw IMEIError.message("Device identity or boot changed, or continuity could no longer be checked; collection stopped.") }
                let value = try execute(probe.command, transport: transport, serial: serial, timeout: min(probe.timeoutSeconds, max(1, Int(deadline.timeIntervalSinceNow))), limit: min(probe.maxBytes, Self.totalLimit - total), deadline: deadline)
                total += value.stdout.count + value.stderr.count
                if value.outcome != "cancelled" {
                    let after = try execute(Self.bootstrap, transport: transport, serial: serial, timeout: min(12, max(1, Int(deadline.timeIntervalSinceNow))), limit: 16384, deadline: deadline)
                    if after.outcome != "success" || !Self.sameDevice(original, Self.binding(after.stdout)) { continuityLost = true; throw IMEIError.message("Device identity or boot changed after a probe; that probe's output was discarded and collection stopped.") }
                }
                let stdout = redactor.output(value.stdout), stderr = redactor.output(value.stderr)
                report.probes.append(.init(id: probe.id, title: probe.title, category: probe.category, command: probe.command, outcome: value.outcome, exitCode: value.remoteExitCode, stdout: stdout, stderr: stderr, durationSeconds: value.duration, facts: value.outcome == "success" && value.remoteExitCode == 0 ? Self.facts(stdout) : [:], localExitCode: value.localExitCode, remoteExitCode: value.remoteExitCode))
                progress(report, Double(index + 1) / Double(specification.probes.count))
                if value.outcome == "cancelled" { report.outcome = "cancelled"; break }
            }
            if report.outcome == "collecting" { report.outcome = report.probes.allSatisfy { $0.outcome == "success" } ? "complete" : "partial" }
            report.continuityVerified = !continuityLost && !cancellation.cancelled
        } catch { report.outcome = cancellation.cancelled ? "cancelled" : "partial"; report.warnings.append(redactor.clean(error.localizedDescription)); if report.transport == "none" { attempt("selection", report.outcome, error.localizedDescription) } }
        let collected = Set(report.probes.map(\.id))
        for probe in specification.probes where !collected.contains(probe.id) {
            report.probes.append(.init(id: probe.id, title: probe.title, category: probe.category, command: probe.command, outcome: "skipped", exitCode: nil, stdout: "", stderr: "Not collected; see connection attempts and report warnings.", durationSeconds: 0, facts: [:]))
        }
        report.authorization = "none"
        report.continuityVerified = report.continuityVerified ?? false
        report.bindingStrength = report.bindingStrength ?? "transport-only"
        report.observations = Self.observe(specification, results: report.probes, continuityLost: continuityLost)
        report.profile = Self.profile(specification, results: report.probes)
        report.features = Self.assess(specification, results: report.probes, profile: report.profile, continuityLost: continuityLost, bindingComplete: report.bindingStrength == "full")
        report.finishedAt = ISO8601DateFormatter().string(from: Date()); progress(report, 1)
        return report
    }
    static func observe(_ specification: ResearchSpecification, results: [ResearchProbeResult], continuityLost: Bool = false) -> [ResearchObservationResult] {
        var definitions = specification.observations ?? []
        let mapped = Set(definitions.map { $0.probe + "." + $0.fact })
        for result in results {
            for fact in result.facts.keys.sorted() where !mapped.contains(result.id + "." + fact) {
                definitions.append(.init(id: "fact:" + result.id + ":" + fact, title: .init(ru: fact, en: fact), probe: result.id, fact: fact))
            }
        }
        return definitions.map { item in
            let probe = results.first { $0.id == item.probe }
            let raw = probe?.facts[item.fact]
            let trusted = !continuityLost && probe?.outcome == "success" && probe?.exitCode == 0
            let state: String
            if !trusted || raw == nil || ["", "unknown", "not-assessed", "not-performed", "conflicting"].contains(raw!.lowercased()) { state = "not-assessed" }
            else if ["missing", "absent"].contains(raw!.lowercased()) { state = "absent" }
            else { state = "known" }
            let reason = state != "not-assessed" ? nil : continuityLost ? "continuity-lost" : !trusted ? "source-not-success" : raw == nil ? "fact-unavailable" : "fact-not-assessed"
            return .init(id: item.id, title: item.title, probe: item.probe, fact: item.fact, state: state, value: state == "known" ? raw : nil,
                sourceStatus: probe?.outcome ?? "missing", sourceExitCode: probe?.exitCode, reason: reason)
        }
    }
    static func profile(_ specification: ResearchSpecification, results: [ResearchProbeResult]) -> String? {
        guard let identity = results.first(where: { $0.id == "identity" && $0.outcome == "success" }), let hashes = results.first(where: { $0.id == "firmware-hashes" && $0.outcome == "success" }) else { return nil }
        return specification.profiles.first { hashes.facts["firmware_sha256"] == $0.firmwareSHA256 && hashes.facts["router_sha256"] == $0.routerSHA256 && identity.facts["architecture"] == $0.architecture }?.id
    }
    static func assess(_ specification: ResearchSpecification, results: [ResearchProbeResult], profile: String?, continuityLost: Bool = false, bindingComplete: Bool = true) -> [ResearchFeatureResult] {
        specification.features.filter { $0.platforms == nil || $0.platforms!.contains("macos") }.map { feature in
            var blocked = false, unknown = continuityLost, evidence = [ResearchText]()
            if continuityLost { evidence.append(.init(ru: "Непрерывность идентификации устройства нарушена", en: "Device continuity was lost")) }
            if !feature.profiles.isEmpty && !feature.profiles.contains(profile ?? "") {
                if let profile { blocked = true; evidence.append(.init(ru: "Профиль " + profile + " не поддерживается этой операцией программы", en: "Profile " + profile + " is not supported by this application operation")) }
                else { unknown = true; evidence.append(.init(ru: "Нет совпадения с проверенным профилем прошивки", en: "No matching verified firmware profile")) }
            }
            for requirement in feature.requirements where requirement.platforms == nil || requirement.platforms!.contains("macos") {
                guard let result = results.first(where: { $0.id == requirement.probe }), result.outcome == "success", let value = result.facts[requirement.fact] else { unknown = true; evidence.append(.init(ru: requirement.label.ru + ": неизвестно", en: requirement.label.en + ": unknown")); continue }
                if ["unknown", "not-assessed", "not-performed", "conflicting", ""].contains(value.lowercased()) { unknown = true; evidence.append(.init(ru: requirement.label.ru + ": не проверялось", en: requirement.label.en + ": not assessed")) }
                else if value != requirement.equals { blocked = true; evidence.append(.init(ru: requirement.label.ru + ": не выполнено", en: requirement.label.en + ": not met")) }
                else { evidence.append(.init(ru: requirement.label.ru + ": выполнено", en: requirement.label.en + ": met")) }
            }
            if !bindingComplete { unknown = true; evidence.append(.init(ru: "Нет полной привязки CID и загрузки; наблюдения не разрешают запись", en: "Full CID and boot binding is unavailable; observations do not authorize writes")) }
            return ResearchFeatureResult(id: feature.id, title: feature.title, state: continuityLost ? "unknown" : blocked ? "blocked" : unknown ? "unknown" : "prerequisites_met", evidence: evidence, limitations: feature.limitations)
        }
    }
}

enum FirmwareResearchArchive {
    static func save(_ report: FirmwareResearchReport, root: URL) throws -> URL {
        try require(UUID(uuidString: report.id) != nil, "Invalid research report ID")
        let directory = root.appendingPathComponent("FirmwareResearch/" + report.id)
        try secureDirectory(directory); try saveJSON(report, directory.appendingPathComponent("report.json"))
        try saveJSON(["id": report.id], root.appendingPathComponent("FirmwareResearch/latest.json")); return directory
    }
    static func latest(root: URL) throws -> FirmwareResearchReport {
        let (pointer, clipped) = try DiagnosticArchive.readRegular(root: root, relative: "FirmwareResearch/latest.json", limit: 4097)
        let id = try JSONDecoder().decode([String: String].self, from: pointer)["id"] ?? ""
        try require(!clipped && pointer.count <= 4096 && UUID(uuidString: id) != nil, "Invalid saved research report")
        let (data, truncated) = try DiagnosticArchive.readRegular(root: root, relative: "FirmwareResearch/" + id + "/report.json", limit: 32 * 1024 * 1024 + 1)
        try require(!truncated && data.count <= 32 * 1024 * 1024, "Saved research report is too large")
        let report = try JSONDecoder().decode(FirmwareResearchReport.self, from: data)
        try require(report.id == id, "Saved research report identity mismatch")
        return report
    }
    /// Shared offline payloads for both the standalone report and the common support ZIP.
    /// Never enumerates the cache or copies arbitrary saved files.
    static func textPayloads(_ original: FirmwareResearchReport, secrets: [String] = []) throws -> [(path: String, data: Data)] {
        try require(original.schemaVersion == 1 && UUID(uuidString: original.id) != nil && original.probes.count <= 64 && original.features.count <= 100 && (original.observations?.count ?? 0) <= 4096, "Invalid research export dataset")
        try require(original.probes.allSatisfy { $0.id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil }, "Unsafe research probe filename")
        try require(Set(original.probes.map(\.id)).count == original.probes.count, "Duplicate research export probe")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let originalData = try encoder.encode(original)
        try require(originalData.count <= 32 * 1024 * 1024, "Research export dataset exceeds the size limit")
        let redactor = ResearchRedactor(secrets: secrets)
        // Export-only policy: activation and SM-DP data can be short or look like
        // an ordinary SHA256. Redact by field name before considering its value.
        let credentialName = #"(?i)(activation|confirmation|matching[_ -]?id|sm[-_ ]?dp)"#
        func credential(_ key: String) -> Bool {
            ActivityJournal.isSecretField(key) || key.range(of: credentialName, options: .regularExpression) != nil
        }
        func cleanText(_ text: String) -> String {
            guard !text.contains("\0") else { return "[binary output omitted]" }
            let clean = redactor.clean(text).replacingOccurrences(of: #"(?im)^.*(?:\bLPA[ \t]*:|(?:activation[_ -]?code|confirmation[_ -]?code|matching[_ -]?id|sm[-_ ]?dp\+?(?:[_ -]*(?:address|server|host))?)[A-Za-z0-9_-]*["']?[ \t]*(?:[:=]|[ \t]+\S)).*$"#, with: "[activation data redacted]", options: .regularExpression)
            return clean.replacingOccurrences(of: #"(?i)\b(?:https?|ftp|ssh|socks[45]?)://[^\s\"<>]+"#, with: "[url-redacted]", options: .regularExpression)
        }
        func clean(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.reduce(into: [String: Any]()) { result, pair in
                    let privateObservation = pair.key == "value" && (object["fact"] as? String).map(credential) == true
                    result[cleanText(pair.key)] = credential(pair.key) || privateObservation ? "[redacted]" : clean(pair.value)
                }
            }
            if let array = value as? [Any] { return array.map(clean) }
            if let text = value as? String { return cleanText(text) }
            return value
        }
        var object = clean(try JSONSerialization.jsonObject(with: originalData)) as! [String: Any]
        // The random local report ID names the archive namespace; it is not a device ID.
        object["id"] = original.id
        object["profile"] = original.profile.map { clean($0) }
        object["authorization"] = "none"
        let report = try JSONDecoder().decode(FirmwareResearchReport.self, from: JSONSerialization.data(withJSONObject: object))
        let encodedReport = try encoder.encode(report)
        var payloads = [(path: String, data: Data)](), manifest = [[String: String]](), total = 0
        func write(_ data: Data, _ path: String) throws {
            try require(data.count <= 32 * 1024 * 1024 && total + data.count <= DiagnosticArchive.totalLimit, "Research export payload exceeds the size limit")
            payloads.append((path, data)); total += data.count
            manifest.append(["path": path, "sha256": digest(data), "bytes": String(data.count)])
        }
        try write(encodedReport, "report.json"); try write(encoder.encode(report.application), "application.json")
        var markdown = "# Исследование прошивки / Firmware research\n\nCreated: \(report.startedAt)\nFinished: \(report.finishedAt)\nTransport: \(report.transport)\nOutcome: \(report.outcome)\nProfile: \(report.profile ?? "unknown")\n\nRead-only evidence, not write compatibility certification. / Сведения только для чтения; успешная проверка предпосылок не гарантирует безопасность операций записи.\n\n"
        markdown += "Binding: \(report.bindingStrength ?? "not-assessed")\nWrite authorization: none\n\n"
        for item in report.observations ?? [] { markdown += "- " + item.title.en + ": " + item.state + (item.value.map { " — " + $0 } ?? "") + " (" + item.probe + "." + item.fact + ")\n" }
        markdown += "\n"
        for warning in report.warnings { markdown += "- " + warning + "\n" }
        markdown += "\n## Connection attempts / Подключения\n\n"
        for attempt in report.attempts { markdown += "- \(attempt.transport): \(attempt.outcome). \(attempt.detail)\n" }
        markdown += "\n## Compatibility prerequisites / Предпосылки совместимости\n\n"
        for feature in report.features { markdown += "### \(feature.title.ru) / \(feature.title.en): \(feature.state)\n\n" + feature.evidence.map { "- \($0.ru) / \($0.en)" }.joined(separator: "\n") + "\n\n\(feature.limitations.ru)\n\(feature.limitations.en)\n\n" }
        markdown += "## Probes / Проверки\n\n| Probe | Outcome | Local exit | Remote exit | Seconds |\n|---|---|---|---|---|\n"
        for probe in report.probes { markdown += "| \(probe.id) | \(probe.outcome) | \(probe.localExitCode.map(String.init) ?? "—") | \(probe.remoteExitCode.map(String.init) ?? "—") | \(String(format: "%.2f", probe.durationSeconds)) |\n"; try write(encoder.encode(probe), "probes/" + probe.id + ".json") }
        try write(Data(markdown.utf8), "REPORT.md"); try write(encoder.encode(manifest), "manifest-sha256.json")
        return payloads
    }
    static func export(_ report: FirmwareResearchReport, to destination: URL) throws -> String {
        let payloads = try textPayloads(report)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("zte-research-" + UUID().uuidString)
        try secureDirectory(work); defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = work.appendingPathComponent("ZTE-Firmware-Research"); try secureDirectory(snapshot)
        for payload in payloads {
            let target = snapshot.appendingPathComponent(payload.path)
            try secureDirectory(target.deletingLastPathComponent()); try savePrivate(payload.data, target)
        }
        let zip = work.appendingPathComponent("report.zip"), runner = ResearchBoundedRunner(), token = ResearchCancellation()
        let packed = try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", snapshot.path, zip.path], timeout: 60, maxBytes: 65536, cancellation: token)
        try require(packed.outcome == "success", "Could not create firmware research ZIP")
        let verified = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-tq", zip.path], timeout: 30, maxBytes: 65536, cancellation: token)
        try require(verified.outcome == "success", "Firmware research ZIP verification failed")
        let bytes = try Data(contentsOf: zip); try savePrivate(bytes, destination); return digest(bytes)
    }
}
