import Foundation
import Darwin

/// Original text is audit context only. The encoded body is never logged.
struct ADBStreamInput {
    let data: Data
    let ready: String
    let begin: String
    let result: String
    let auditOriginal: String
}
struct ADBShellPlan {
    static let templateSHA256 = "0692a6b053b7cadae5d4a754684e94062ecaa94067f8f103913c1191e9dc6a1c"
    let command: String
    let marker: String
    let input: ADBStreamInput?
    static func make(_ text: String, templateURL: URL) throws -> Self {
        let bytes = Data(text.utf8)
        try require(!bytes.contains(0) && bytes.count <= 128 * 1024, "Команда ADB содержит недопустимые данные или превышает 128 КиБ")
        func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        let marker = "__ZTE_RESULT_" + nonce() + "__"
        let framed = "(" + text + "); zte_code=$?; printf '\\n" + marker + "%s\\n' \"$zte_code\""
        if framed.utf8.count <= 3000 { return .init(command: framed, marker: marker, input: nil) }
        let fd = open(templateURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        try require(fd >= 0, "Шаблон потоковой передачи ADB недоступен")
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= 4096, "Некорректный шаблон передачи ADB")
        let template = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097) ?? Data()
        try require(digest(template) == templateSHA256, "SHA256 шаблона передачи ADB не совпал")
        let ready = "__ZTE_READY_" + nonce() + "__", begin = "__ZTE_BEGIN_" + nonce() + "__", end = "__ZTE_END_" + nonce() + "__"
        let chunks = (bytes.count + 63) / 64
        var encoded = Data()
        for (index, byte) in bytes.enumerated() {
            encoded.append(Data(String(format: "\\0%03o", Int(byte)).utf8))
            if index % 64 == 63 || index == bytes.count - 1 { encoded.append(10) }
        }
        encoded.append(Data((end + "\n").utf8))
        var script = String(decoding: template, as: UTF8.self)
        for (key, value) in ["CHUNKS": String(chunks), "LAST_CHARS": String(((bytes.count - 1) % 64 + 1) * 5), "BYTES": String(bytes.count), "SHA256": digest(bytes), "READY": ready, "BEGIN": begin, "RESULT": marker, "END": end] {
            script = script.replacingOccurrences(of: "@" + key + "@", with: value)
        }
        let command = "sh -c " + shellQuote(script)
        try require(command.utf8.count < 4096, "Bootstrap ADB превышает предел старого adbd")
        return .init(command: command, marker: marker, input: .init(data: encoded, ready: ready, begin: begin, result: marker, auditOriginal: text))
    }
    static func line(_ raw: Data, equals marker: String) -> Bool {
        guard raw.last == 10 else { return false }
        var line = raw; line.removeLast()
        for _ in 0..<2 { if line.last == 13 { line.removeLast() } }
        return line == Data(marker.utf8)
    }
    static func payload(_ result: CommandResult, input: ADBStreamInput) throws -> CommandResult {
        // Discard only the transport prelude, then retain payload bytes verbatim.
        let needle = Data(input.begin.utf8), raw = result.stdout
        guard let match = raw.range(of: needle), raw.range(of: needle, in: match.upperBound..<raw.endIndex) == nil,
              match.lowerBound == raw.startIndex || raw[match.lowerBound - 1] == 10,
              let newline = raw[match.lowerBound...].firstIndex(of: 10),
              line(Data(raw[match.lowerBound...newline]), equals: input.begin) else {
            throw CommandFailure(message: "ADB не подтвердил начало выполненной команды; результат неизвестен", partial: .init(status: result.status, stdout: Data(), stderr: result.stderr))
        }
        return .init(status: result.status, stdout: Data(raw[(newline + 1)...]), stderr: result.stderr)
    }
    func decode(_ result: CommandResult, original: String) throws -> CommandResult {
        let value = try input.map { try Self.payload(result, input: $0) } ?? result
        return try ADBClient.decodeShellResult(value, marker: marker, command: original)
    }
}

/// One deadline for READY, stdin transfer, both output pipes and child completion.
/// Before BEGIN only bounded protocol lines are inspected; PTY echo is discarded.
/// No remote file, second invocation, signal to a remote PID or automatic retry.
final class ADBStreamProcess {
    static func run(_ executable: URL, arguments: [String], input: ADBStreamInput, timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation) throws -> ResearchCommandResult {
        if cancellation.cancelled { return .init(status: -1, stdout: Data(), stderr: Data(), outcome: "cancelled", duration: 0) }
        let process = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = out; process.standardError = err
        let start = ProcessInfo.processInfo.systemUptime
        try process.run()
        try? stdin.fileHandleForReading.close(); try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        let outFD = out.fileHandleForReading.fileDescriptor, errFD = err.fileHandleForReading.fileDescriptor, inFD = stdin.fileHandleForWriting.fileDescriptor
        defer { try? stdin.fileHandleForWriting.close(); try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close() }
        var outcome = "success", stdout = Data(), stderr = Data(), prelude = Data(), errorPrelude = Data()
        var discardErrorLine = false
        var ready = false, begun = false, inputClosed = false, written = 0, preludeCount = 0
        var openOut = true, openErr = true, childEnded: Double?
        for fd in [outFD, errFD, inFD] { if fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0 { outcome = "failed" } }
        // Do not change process-wide SIGPIPE policy when the child closes stdin.
        if fcntl(inFD, F_SETNOSIGPIPE, 1) < 0 { outcome = "failed" }
        func retain(_ bytes: Data, error: Bool) {
            let remaining = max(0, maxBytes - stdout.count - stderr.count)
            if bytes.count > remaining { outcome = "truncated" }
            if error { stderr.append(bytes.prefix(remaining)) } else { stdout.append(bytes.prefix(remaining)) }
        }
        func receiveError(_ bytes: Data) {
            if begun { errorPrelude.removeAll(); retain(bytes, error: true); return }
            // A client/PTY may echo the reversible input on either pipe. Keep
            // no partial line or arbitrary pre-BEGIN stderr, including errors.
            for byte in bytes {
                if !discardErrorLine { errorPrelude.append(byte) }
                if byte == 10 {
                    if ADBShellPlan.line(errorPrelude, equals: "error: shell command too long") { retain(Data("error: shell command too long\n".utf8), error: true) }
                    errorPrelude.removeAll(); discardErrorLine = false
                } else if errorPrelude.count > 128 { errorPrelude.removeAll(); discardErrorLine = true }
            }
        }
        func receive(_ bytes: Data) {
            if begun { retain(bytes, error: false); return }
            preludeCount += bytes.count
            if preludeCount > input.data.count + 8192 { outcome = "failed"; return }
            prelude.append(bytes)
            while let lf = prelude.firstIndex(of: 10) {
                let line = Data(prelude[...lf]); prelude.removeSubrange(...lf)
                if ADBShellPlan.line(line, equals: input.ready) {
                    if ready { outcome = "failed"; return }; ready = true
                } else if ADBShellPlan.line(line, equals: input.begin) {
                    guard ready && written == input.data.count else { outcome = "failed"; return }
                    begun = true; retain(line, error: false); retain(prelude, error: false); prelude.removeAll(); return
                }
            }
            if prelude.count > 4096 { outcome = "failed" }
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while outcome == "success" {
            let now = ProcessInfo.processInfo.systemUptime
            if cancellation.cancelled { outcome = "cancelled"; break }
            if now - start >= timeout { outcome = "timeout"; break }
            for (fd, isError) in [(errFD, true), (outFD, false)] where isError ? openErr : openOut {
                // Bounded drain per turn leaves cancellation/stdin responsive.
                for _ in 0..<8 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count > 0 { let bytes = Data(buffer.prefix(count)); if isError { receiveError(bytes) } else { receive(bytes) } }
                    else if count == 0 { if isError { openErr = false } else { openOut = false }; break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else { outcome = "failed"; break }
                }
            }
            if outcome != "success" { break }
            if ready && !inputClosed {
                let count = input.data.withUnsafeBytes { bytes in Darwin.write(inFD, bytes.baseAddress!.advanced(by: written), min(4096, bytes.count - written)) }
                if count > 0 { written += count }
                else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { outcome = "failed"; break }
                if written == input.data.count { try? stdin.fileHandleForWriting.close(); inputClosed = true }
            }
            if !process.isRunning {
                if childEnded == nil { childEnded = now }
                if !openOut && !openErr { break }
                if now - (childEnded ?? now) >= 0.5 { outcome = "timeout"; break }
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if process.isRunning {
            process.terminate()
            let end = ProcessInfo.processInfo.systemUptime + 0.3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if outcome == "success" && (!ready || !begun || written != input.data.count || process.terminationStatus != 0) { outcome = "failed" }
        return .init(status: process.terminationStatus, stdout: stdout, stderr: stderr, outcome: outcome, duration: ProcessInfo.processInfo.systemUptime - start, localExitCode: process.terminationStatus)
    }
}
