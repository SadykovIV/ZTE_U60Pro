import Foundation
@main struct ModemTerminalTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ text: String) throws { if !value { throw IMEIError.message("TEST: " + text) }; count += 1; print("PASS " + text) }
        let proof = Identity(cid: String(repeating: "a", count: 32), firmwareHash: ModemEngine.firmwareHash)
        let boot = "11111111-2222-3333-4444-555555555555"
        let command = try ModemTerminalLaunch.command(identity: proof, bootID: boot, marker: "__ZTE_TERMINAL_TEST__")
        try check(command.contains(proof.cid) && command.contains(boot), "Remote shell binds selected modem and boot")
        try check(command.contains("exec /bin/sh -i") && command.contains("HISTFILE=/dev/null") && command.contains("opkg()"), "Interactive shell and private opkg convenience without command validation")
        let session = ModemTerminalSession()
        try session.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "test -t 0 && test -t 1 && printf 'PTY_OK\\n'; read line; eval \"$line\"; read last; printf 'LAST:%s\\n' \"$last\""])
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(session.connected && String(decoding: session.output(from: 0).data, as: UTF8.self).contains("PTY_OK"), "Process receives real PTY on stdin/stdout")
        session.resize(columns: 117, rows: 44)
        session.send("printf 'PIPE_'; printf 'OK\\n'; stty size\n")
        try await Task.sleep(nanoseconds: 200_000_000)
        let first = String(decoding: session.output(from: 0).data, as: UTF8.self)
        try check(first.contains("PIPE_OK") && first.contains("44 117"), "Unrestricted compound shell command and PTY resize")
        session.send("value with пробелами\n")
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(String(decoding: session.output(from: 0).data, as: UTF8.self).contains("LAST:value with пробелами"), "UTF-8 input survives PTY")
        try check(!session.active, "Natural exit releases terminal ownership")
        session.clear();try check(session.output(from: 0).data.isEmpty, "Clear removes in-memory output")
        try session.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '__ZTE_TERMINAL_TEST__'; sleep 5"], handshakeMarker: "__ZTE_TERMINAL_TEST__")
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(session.connected && !String(decoding: session.output(from: 0).data, as: UTF8.self).contains("__ZTE_TERMINAL"), "Connection marker enables input and is hidden")
        try check(!session.send(Data(repeating: 65, count: 1024 * 1024 + 1)) && session.status.contains("Ввод не отправлен"), "Oversized input rejected visibly instead of dropped silently")
        session.disconnect();try check(!session.active && !session.connected, "Explicit disconnect blocks further input")
        let before = session.output(from: 0).end
        session.send("must not run\n")
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(session.output(from: 0).end == before, "Closed session rejects late input/output callbacks")
        print("ModemTerminalTests: \(count) PASS")
    }
}
