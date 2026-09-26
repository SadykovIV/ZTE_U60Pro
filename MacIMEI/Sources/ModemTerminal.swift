import Foundation
import Combine
import Darwin

struct ModemTerminalLaunch {
    static func command(identity: Identity, bootID: String, marker: String) throws -> String {
        try require(identity.cid.count == 32 && identity.cid.allSatisfy { $0.isHexDigit } && UUID(uuidString: bootID) != nil,
                    "Не подтверждена идентичность терминала")
        try require(marker.hasPrefix("__ZTE_TERMINAL_") && marker.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || $0 == 95 || $0 == 45 }, "Неверный маркер терминала")
        return """
        test "$(cat /sys/block/mmcblk0/device/cid)" = \(shellQuote(identity.cid)) && test "$(cat /proc/sys/kernel/random/boot_id)" = \(shellQuote(bootID)) || { echo 'Модем или его загрузка изменились'; exit 1; }
        export TERM=xterm-256color HISTFILE=/dev/null
        exec 3<<'ZTE_TERMINAL_ENV'
        unset ENV
        opkg() { /data/zte-imei-apps/opkg-private/opkg "$@"; }
        PS1='modem# '
        exec 3<&-
        printf '%s\\n' \(shellQuote(marker))
        ZTE_TERMINAL_ENV
        export ENV=/proc/self/fd/3
        exec /bin/sh -i
        """
    }
    static func arguments(connection: Connection, remoteCommand: String) throws -> [String] {
        try connection.validate()
        return ["-F", "/dev/null", "-tt", "-p", connection.port, "-i", connection.keyPath,
                "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
                "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"" + connection.knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"",
                "-o", "GlobalKnownHostsFile=/dev/null", "root@" + connection.host, remoteCommand]
    }
}

/// A real SSH PTY. Input/output are never written to the activity journal or disk.
@MainActor final class ModemTerminalSession: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var connected = false
    @Published private(set) var status = "Терминал отключён"
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var screenGeneration: UInt64 = 0
    var onActiveChange: ((Bool) -> Void)?
    private var process: Process?
    private var source: DispatchSourceRead?
    private var master: Int32 = -1
    private var token = UUID()
    private var buffer = Data()
    private var bufferStart = 0
    private var nextByte = 0
    private var handshake = Data()
    private var marker = Data()
    private var pendingInput = Data()
    private var inputTask: Task<Void, Never>?
    private var columns = 100, rows = 26
    private let maximumBuffer = 2 * 1024 * 1024

    func start(connection: Connection, identity: Identity, bootID: String) throws {
        let text = "__ZTE_TERMINAL_" + UUID().uuidString.uppercased() + "__"
        let remote = try ModemTerminalLaunch.command(identity: identity, bootID: bootID, marker: text)
        try launch(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ModemTerminalLaunch.arguments(connection: connection, remoteCommand: remote), handshakeMarker: text)
    }
    // Local test injection exercises the production PTY without any modem.
    func launch(executable: URL, arguments: [String], handshakeMarker: String? = nil) throws {
        try require(!active, "Терминал уже открыт")
        clear()
        var parent: Int32 = -1, child: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        try require(openpty(&parent, &child, nil, nil, &size) == 0, "Не удалось открыть PTY")
        // OpenSSH reads these initial terminal modes for the remote PTY, then
        // sets the local terminal raw itself. Preserve canonical input and ISIG.
        _ = fcntl(parent, F_SETFL, O_NONBLOCK)
        _ = fcntl(parent, F_SETFD, FD_CLOEXEC)
        let slave = FileHandle(fileDescriptor: child, closeOnDealloc: true)
        let task = Process(); task.executableURL = executable; task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"; task.environment = environment
        task.standardInput = slave; task.standardOutput = slave; task.standardError = slave
        let sessionToken = UUID(); token = sessionToken
        marker = handshakeMarker.map { Data($0.utf8) } ?? Data(); handshake = Data()
        task.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.finished(sessionToken, code: code)
            }
        }
        do { try task.run() }
        catch { try? slave.close(); close(parent); throw error }
        try? slave.close()
        master = parent; process = task; active = true; connected = marker.isEmpty
        status = connected ? "SSH · root" : "Открываю SSH-терминал…"; onActiveChange?(true)
        let reader = DispatchSource.makeReadSource(fileDescriptor: parent, queue: DispatchQueue(label: "zte.terminal.read"))
        reader.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(parent, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(count))
                Task { @MainActor [weak self] in self?.received(data, token: sessionToken) }
            }
        }
        reader.setCancelHandler { close(parent) }; source = reader; reader.resume()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.token == sessionToken, self.active, !self.connected else { return }
            self.disconnect(message: "SSH не подтвердил открытие терминала")
        }
    }
    private func received(_ data: Data, token: UUID) {
        guard self.token == token, active else { return }
        if !connected {
            handshake.append(data)
            if let range = handshake.range(of: marker) {
                var visible = handshake.subdata(in: 0..<range.lowerBound)
                visible.append(handshake.subdata(in: range.upperBound..<handshake.count))
                handshake.removeAll(); connected = true; status = "SSH · root"; append(visible)
            } else if handshake.count > 32768 {
                append(handshake.prefix(handshake.count - 1024)); handshake = handshake.suffix(1024)
            }
        } else { append(data) }
    }
    private func append(_ data: Data) {
        buffer.append(data); nextByte += data.count
        if buffer.count > maximumBuffer { let count = buffer.count - maximumBuffer; buffer.removeFirst(count); bufferStart += count }
        revision &+= 1
    }
    func output(from position: Int) -> (data: Data, end: Int, truncated: Bool) {
        let start = min(nextByte, max(bufferStart, position))
        return (buffer.subdata(in: (start - bufferStart)..<buffer.count), nextByte, position < bufferStart)
    }
    @discardableResult func send(_ text: String) -> Bool { send(Data(text.utf8)) }
    @discardableResult func send(_ data: Data) -> Bool {
        guard connected, master >= 0 else { return false }
        guard pendingInput.count + data.count <= 1024 * 1024 else {
            status = "Ввод не отправлен: очередь заполнена. Повторите вставку меньшими частями."
            return false
        }
        pendingInput.append(data)
        guard inputTask == nil else { return true }
        let fd = master, current = token
        inputTask = Task { @MainActor [weak self] in
            while let self, self.token == current, self.connected, self.master == fd, !self.pendingInput.isEmpty {
                let count = self.pendingInput.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!, min(4096, self.pendingInput.count)) }
                if count > 0 { self.pendingInput.removeFirst(count) }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    self.disconnect(message: "Ошибка отправки в терминал: " + String(cString: strerror(errno)))
                    break
                }
                if !self.pendingInput.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            }
            if self?.token == current { self?.inputTask = nil }
        }
        return true
    }
    func resize(columns: Int, rows: Int) {
        self.columns = max(20, min(500, columns)); self.rows = max(5, min(200, rows))
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(self.rows), ws_col: UInt16(self.columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        if let process, process.isRunning { kill(process.processIdentifier, SIGWINCH) }
    }
    func clear() { buffer.removeAll(); bufferStart = 0; nextByte = 0; screenGeneration &+= 1; revision &+= 1 }
    func disconnect(message: String = "Терминал отключён") {
        let old = process
        inputTask?.cancel(); inputTask = nil; pendingInput.removeAll()
        token = UUID(); connected = false; active = false; status = message
        if !handshake.isEmpty { append(handshake); handshake.removeAll() }
        source?.cancel(); source = nil; master = -1; process = nil; onActiveChange?(false)
        if let old, old.isRunning {
            old.terminate()
            Task { @MainActor in try? await Task.sleep(nanoseconds: 2_000_000_000); if old.isRunning { kill(old.processIdentifier, SIGKILL) } }
        }
    }
    private func finished(_ current: UUID, code: Int32) {
        guard token == current else { return }
        let wasConnected = connected
        disconnect(message: wasConnected ? "Сеанс завершён · код \(code)" : "SSH не открыл терминал · код \(code)")
    }
}
