import Foundation
import Darwin
@main enum EsimProcessTests {
    static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            fputs("FAIL: interactive short-line read waited for EOF or a full buffer\n", stderr)
            exit(23)
        }
        let script = """
        printf '%s\n' '{"type":"progress","stage":"downloading"}'
        IFS= read -r ack || exit 31
        [ "$ack" = ACK ] || exit 32
        printf '%s\n' '{"type":"http","id":1,"payload":{}}'
        IFS= read -r reply || exit 33
        [ "$reply" = RESPONSE ] || exit 34
        printf '%s\n' '{"type":"result","ok":false,"error":"synthetic"}'
        """
        let child = try EsimSSHProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        guard let first = try child.line(), String(decoding: first, as: UTF8.self).contains("progress") else { throw EsimFailure.protocolError }
        try child.send(Data("ACK".utf8))
        guard let http = try child.line(), String(decoding: http, as: UTF8.self).contains("http") else { throw EsimFailure.protocolError }
        try child.send(Data("RESPONSE".utf8))
        guard let result = try child.line(), String(decoding: result, as: UTF8.self).contains("result"), try child.line() == nil, child.finish() == 0 else { throw EsimFailure.protocolError }
        print("PASS: real EsimSSHProcess exchanges two short interactive messages without EOF; no SSH or device calls")
    }
}
