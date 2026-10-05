import Foundation
import CryptoKit
import Darwin

/// Dedicated private pipes; deliberately does not use the file-backed/audited
/// SSHTransport for eUICC requests, responses, identifiers or HTTPS bodies.
final class EsimSSHProcess {
    static let maxLine = 9 * 1024 * 1024
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffered = Data()
    private var inputClosed = false
    private var finished = false
    private let stderrDone = DispatchGroup()

    static func arguments(_ connection: Connection, command: String) -> [String] {
        ["-F", "/dev/null", "-T", "-p", connection.port, "-i", connection.keyPath,
         "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
         "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
         "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null",
         "-o", "UserKnownHostsFile=\"" + connection.knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"",
         "root@" + connection.host, command]
    }
    convenience init(connection: Connection, command: String) throws {
        try connection.validate()
        try self.init(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: Self.arguments(connection, command: command))
    }
    // Internal injection for a real interactive-pipe fixture; production always
    // selects the checked SSH arguments through the initializer above.
    init(executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        // A remote early exit must become an uncertain transport result,
        // rather than terminating the desktop process with SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw EsimFailure.transport }
        do { try process.run() } catch { throw EsimFailure.transport }
        // These data are discarded, including any dependency debug output.
        stderrDone.enter()
        let handle = errors.fileHandleForReading, group = stderrDone
        DispatchQueue.global(qos: .utility).async {
            defer { try? handle.close(); group.leave() }
            while let data = try? handle.read(upToCount: 8192), !data.isEmpty {}
        }
    }
    func send(_ data: Data, newline: Bool = true) throws {
        guard !inputClosed else { throw EsimFailure.transport }
        do { try input.fileHandleForWriting.write(contentsOf: data); if newline { try input.fileHandleForWriting.write(contentsOf: Data([10])) } }
        catch { throw EsimFailure.transport }
    }
    func closeInput() { if !inputClosed { inputClosed = true; try? input.fileHandleForWriting.close() } }
    func line() throws -> Data? {
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                guard newline <= Self.maxLine else { throw EsimFailure.protocolError }
                let result = Data(buffered[..<newline]); buffered.removeSubrange(...newline); return result
            }
            guard buffered.count <= Self.maxLine else { throw EsimFailure.protocolError }
            // FileHandle.read(upToCount:) can wait for the full count or EOF
            // on macOS pipes. RPC requires each short line before the writer
            // closes, so use one blocking POSIX read of currently available data.
            var bytes = [UInt8](repeating: 0, count: 65536)
            var count: Int
            repeat {
                count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            } while count < 0 && errno == EINTR
            guard count >= 0 else { throw EsimFailure.transport }
            if count == 0 { guard buffered.isEmpty else { throw EsimFailure.protocolError }; return nil }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }
    func finish() -> Int32 {
        if finished { return process.terminationStatus }
        closeInput()
        // Drain without retaining after a parser/relay failure, allowing the
        // remote process to see EOF and close its own card channel.
        while let bytes = try? output.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty {}
        try? output.fileHandleForReading.close()
        process.waitUntilExit(); stderrDone.wait(); finished = true
        return process.terminationStatus
    }
    deinit { _ = finish() }
}

struct EsimResources {
    var agent: Data
    var agentSHA: String
    private let directory: URL
    private let hashes: [String: String]
    init(root: URL) throws {
        let directory = root.appendingPathComponent("Esim")
        do {
            let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("SHA256.json")))
            func checked(_ name: String) throws -> Data {
                let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
                let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard hashes[name] == actual else { throw EsimFailure.resources }
                return bytes
            }
            agent = try checked("zte-agent-esim")
            guard !agent.isEmpty, let pin = hashes["zte-agent-esim"] else { throw EsimFailure.resources }
            agentSHA = pin
            self.directory = directory; self.hashes = hashes
        } catch { throw EsimFailure.resources }
    }
    func certificatePEM() throws -> Data {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("gsma-rsp-roots.pem")),
              hashes["gsma-rsp-roots.pem"] == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() else { throw EsimFailure.resources }
        return bytes
    }
}

struct EsimService {
    let connection: Connection
    let resources: URL
    static let stages: [String: String] = [
        "checking_card": "Проверяю карту…", "reading_profiles": "Читаю все профили…",
        "downloading": "Загружаю профиль…", "enabling": "Активирую профиль…",
        "deleting": "Удаляю профиль…", "notifications": "Передаю уведомления оператору…", "verifying": "Проверяю результат на карте…", "cleanup": "Закрываю канал карты…",
        "radio_offline": "Включаю авиарежим для перечитывания SIM…", "radio_online": "Радио включено, перечитываю SIM…", "reading_modem": "Проверяю выбранный профиль в модеме…"
    ]
    private func command(_ text: String, input: Data? = nil) throws {
        let child = try EsimSSHProcess(connection: connection, command: text)
        do {
            if let input { try child.send(input, newline: false) }
            child.closeInput()
            // Staging/cleanup commands have no stdout protocol.
            var unexpected = false
            while let line = try child.line() { if !line.isEmpty { unexpected = true } }
            guard child.finish() == 0, !unexpected else { throw EsimFailure.transport }
        } catch { _ = child.finish(); throw EsimFailure.transport }
    }
    func perform(_ operation: EsimOperation, expected: EsimSnapshot?, journal: @escaping @Sendable (String) -> Void = { _ in }, progress: @escaping @Sendable (String) -> Void) throws -> EsimRPCResult {
        let started = ProcessInfo.processInfo.systemUptime
        func log(_ metadata: String) {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
            journal("eSIM · " + operation.name + " · +" + String(format: "%.1f", elapsed) + " s · " + metadata)
        }
        log("local_preflight")
        let request = try operation.request(snapshot: expected)
        let assets = try EsimResources(root: resources)
        let path = "/tmp/zte-desktop-esim-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let cleanup = "rm -f \(path)/agent && rmdir \(path)"
        let staging = """
        set -eu
        test "$(id -u)" = 0
        test "$(uname -m)" = aarch64
        umask 077
        mkdir \(path)
        trap '\(cleanup)' EXIT
        cat > \(path)/agent
        test "$(sha256sum \(path)/agent | cut -d ' ' -f 1)" = \(assets.agentSHA)
        chmod 500 \(path)/agent
        trap - EXIT
        """
        log("staging_start")
        try command(staging, input: assets.agent)
        log("staging_verified")
        var removed = false
        defer {
            if !removed {
                do { try command(cleanup); log("temporary_files_removed") }
                catch { log("temporary_files_cleanup_unknown") }
            }
        }
        let child = try EsimSSHProcess(connection: connection, command: "\(path)/agent --esim-rpc")
        var decoder = EsimRPCDecoder()
        var httpFailure: EsimNetworkFailure?
        var httpRelay: EsimHTTPSRelay?
        decoder.allowsHTTP = operation.mutates
        do {
            try child.send(request)
            log("rpc_request_sent")
            while let line = try child.line() {
                switch try decoder.consume(line) {
                case .progress(let stage, let detail):
                    let title = Self.stages[stage] ?? "Проверяю карту…"
                    progress(title)
                    log(title + " stage=" + stage + (detail.map { " " + $0.summary } ?? ""))
                case .http(let id, let payload):
                    let httpRequest = try EsimHTTPSRelay.request(payload)
                    let httpStart = ProcessInfo.processInfo.systemUptime
                    log("host_http_start id=\(id) request_bytes=\(httpRequest.httpBody?.count ?? 0)")
                    progress("Ожидаю HTTPS-ответ оператора…")
                    if httpRelay == nil { httpRelay = try EsimHTTPSRelay(certificatePEM: assets.certificatePEM()) }
                    let relay = httpRelay!
                    // While this thread relays HTTPS, agent heartbeats remain in
                    // its pipe. A local metadata-only timer reports that wait.
                    let waiting = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    waiting.schedule(deadline: .now() + 5, repeating: 5)
                    waiting.setEventHandler {
                        let duration = Int(max(0, ProcessInfo.processInfo.systemUptime - httpStart) * 1000)
                        log("host_http_waiting id=\(id) duration_ms=\(duration)")
                    }
                    waiting.resume()
                    let reply = relay.perform(payload)
                    if let failure = relay.failure { httpFailure = failure }
                    waiting.cancel()
                    let duration = Int(max(0, ProcessInfo.processInfo.systemUptime - httpStart) * 1000)
                    log("host_http_end id=\(id) http_status=\(reply.0) response_bytes=\(reply.1.count) duration_ms=\(duration)" + (reply.0 == 0 ? " error=" + (relay.failure ?? .transport).rawValue : ""))
                    let response: [String: Any] = ["type": "http_response", "id": id, "rcode": reply.0, "rx": reply.1.map { String(format: "%02X", $0) }.joined()]
                    try child.send(JSONSerialization.data(withJSONObject: response))
                case .result:
                    if let result = decoder.result {
                        log(EsimLog.resultMetadata(result))
                    }
                    child.closeInput()
                }
            }
            let exit = child.finish()
            log("ssh_exit code=\(exit)")
            let completed = try decoder.finish(exitCode: exit, operation: operation, before: expected)
            log("postconditions_verified")
            try command(cleanup); removed = true
            log("temporary_files_removed")
            return completed
        } catch {
            let exit = child.finish()
            var failure = error as? EsimFailure ?? .protocolError
            // Preserve cleanup/card errors if they occurred after a network error.
            if case .backend("lpac_failed") = failure, let httpFailure { failure = .network(httpFailure) }
            log("operation_unconfirmed error=" + EsimLog.failureCode(failure) + EsimLog.componentMetadata(decoder.result?.componentError) + " ssh_exit=\(exit); " + EsimLog.recoveryCode(failure))
            throw failure
        }
    }
}
