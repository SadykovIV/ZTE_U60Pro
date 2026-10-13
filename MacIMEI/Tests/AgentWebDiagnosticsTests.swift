import Foundation

@main enum AgentWebDiagnosticsTests {
    static func main() throws {
        var count = 0
        func check(_ ok: @autoclosure () -> Bool, _ name: String) throws {
            guard ok() else { throw NSError(domain: name, code: 1) }
            count += 1; print("PASS " + name)
        }
        for bad in ["192.168.00.1", "192.168.0.1:8080", "host", "192.168.0.1;reboot", "999.1.1.1"] {
            try check((try? AgentWebDiagnostics.address(bad)) == nil, "Reject noncanonical host " + bad)
        }
        let command = try AgentWebDiagnostics.command(host: "192.168.0.1")
        try check(command.contains("--noproxy '*'") && command.contains("--output /dev/null") && !command.contains("--location"), "Remote checks never proxy, follow redirects or export bodies")
        try check(command.contains("probe loopback http://127.0.0.1:8080/ &") && command.contains("probe lan http://192.168.0.1:8080/ &"), "Both modem paths run in parallel on HTML port")
        let parse = AgentWebDiagnostics.parse("AGENT_WEB lan 200 yes\nAGENT_WEB loopback 200 yes\n")
        try check(parse.0.available && parse.1.available, "Out of order concurrent results accepted")
        for text in ["AGENT_WEB lan 200 yes\nAGENT_WEB lan 200 yes\n", "AGENT_WEB loopback 200 yes SECRET", "AGENT_WEB lan 999 yes"] {
            let pair = AgentWebDiagnostics.parse(text)
            try check(!pair.0.available && !pair.1.available, "Malformed facts do not certify HTML")
        }
        for code in ["401", "404", "302", "timeout", "refused"] {
            let status = AgentWebDiagnostics.collect(host: "192.168.0.1", remote: { _ in "AGENT_WEB loopback 200 yes\nAGENT_WEB lan 200 yes\n" }, http: { url in
                precondition(url.absoluteString == "http://192.168.0.1:8080/")
                return .init(code: code, isHTML: true)
            })
            try check(status.loopback.available && !status.computer.available && status.warning != nil, "PC failure stays separate from working modem: " + code)
            try check(status.log.contains("computer=" + code), "Log retains machine-readable failure " + code)
        }
        let wrongType = AgentWebObservation(code: "200", isHTML: false)
        try check(!wrongType.available, "HTTP200 JSON cannot certify HTML panel")
        try check(wrongType.display({ $0 == "ответ не HTML" ? "response is not HTML" : $0 }) == "HTTP 200 · response is not HTML", "Dynamic HTTP suffix localizes independently")
        let sshError = AgentWebDiagnostics.collect(host: "192.168.0.1", remote: { _ in throw NSError(domain: "SSH failed", code: 1) }, http: { _ in .init(code:"200", isHTML:true) })
        try check(sshError.loopback.code == "ssh-unavailable" && sshError.computer.available && sshError.warning == nil, "SSH failure preserves independent PC success")
        let forbidden = AgentWebDiagnostics.collect(host: "bad", remote: { _ in fatalError("Unexpected SSH") }, http: { _ in fatalError("Unexpected HTTP") })
        try check(forbidden.computer.code == "invalid-address", "Invalid address performs no I/O")
        // Execute the actual generated shell against a shell-function HTTP fixture.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "curl() { case \"$*\" in *127.0.0.1*) printf '200 text/html; charset=utf-8';; *) return 28;; esac; };\n" + command]
        let pipe=Pipe();process.standardOutput=pipe;try process.run()
        let raw=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        let shell = AgentWebDiagnostics.parse(String(decoding:raw,as:UTF8.self))
        try check(process.terminationStatus == 0 && shell.0.available && shell.1.code == "timeout", "Actual shell separates loopback HTML and LAN timeout")
        print("\(count) passed, 0 failed; no modem contacted")
    }
}
