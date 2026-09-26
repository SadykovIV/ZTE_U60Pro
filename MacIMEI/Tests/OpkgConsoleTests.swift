import Foundation
@main struct OpkgConsoleTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws { if !value { throw IMEIError.message(label) }; count += 1 }
        for text in ["opkg update", "opkg list", "opkg list 'tcp*'", "opkg search '*ping*'", "opkg info curl", "opkg files htop", "opkg install curl nano", "opkg remove nano", "opkg list-installed", "opkg status curl", "list 'iperf?' "] {
            let result = try OpkgConsoleCommand.parse(text)
            try check(try OpkgConsoleCommand.parse(result.display) == result, "Lost argv in normalized command: " + text)
        }
        for text in ["", "opkg", "sh", "opkg install", "opkg remove", "opkg update curl", "opkg upgrade", "opkg install --force-depends curl", "opkg -o / install curl", "opkg install /tmp/test.ipk", "opkg install https://example.test/a.ipk", "opkg install curl;reboot", "opkg install $(reboot)", "opkg install `reboot`", "opkg list | sh", "opkg list\nopkg update", "opkg list >file", "opkg list \"unfinished", "opkg install '*'"] {
            do { _ = try OpkgConsoleCommand.parse(text) }
            catch { count += 1; continue }
            throw IMEIError.message("Unsafe or malformed command accepted: " + text)
        }
        print("OpkgConsoleTests: \(count) PASS")
    }
}
