import Foundation
import Darwin

private enum Failure: Error { case check(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.check(message) }
}
private func rejects(_ contains: String, _ body: () throws -> Void) throws {
    do { try body() } catch let e as Failure { throw e } catch {
        try check(error.localizedDescription.contains(contains), "Unexpected rejection: \(error.localizedDescription)"); return
    }
    throw Failure.check("Expected rejection containing \(contains)")
}

@main struct TTLSettingsTests {
    static func main() throws {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        test("prefilled values never enable either direction") {
            let value = try TTLConfiguration(outboundEnabled: false, outboundText: "64", inboundIncrementEnabled: false, inboundIncrementText: "1")
            try check(value == .disabled && value.isDisabled, "Defaults enable TTL")
        }
        test("outbound SET and inbound INC are independently configured") {
            let outbound = try TTLConfiguration(outboundEnabled: true, outboundText: "65", inboundIncrementEnabled: false, inboundIncrementText: "64")
            let inbound = try TTLConfiguration(outboundEnabled: false, outboundText: "64", inboundIncrementEnabled: true, inboundIncrementText: "1")
            try check(outbound == TTLConfiguration(outbound: 65, inboundIncrement: nil), "Outbound affects inbound")
            try check(inbound == TTLConfiguration(outbound: nil, inboundIncrement: 1), "Inbound affects outbound")
        }
        test("IPv4 TTL endpoints one and 255 are accepted") {
            let value = try TTLConfiguration(outboundEnabled: true, outboundText: "1", inboundIncrementEnabled: true, inboundIncrementText: "255")
            try value.validate()
            try check(value.outbound == 1 && value.inboundIncrement == 255, "Valid boundary rejected")
        }
        test("invalid disabled fields cannot prevent removal of own rules") {
            let value = try TTLConfiguration(outboundEnabled: false, outboundText: "", inboundIncrementEnabled: false, inboundIncrementText: "invalid")
            try check(value == .disabled, "Disabled direction parses stale input")
        }
        test("invalid numbers signed input and shell syntax are rejected") {
            for text in ["", "0", "256", "9999999999999999999", "-1", "+1", "64.5", "64;reboot", "$(id)", "64\n65", "٦٤"] {
                try rejects("от 1 до 255") { _ = try TTLConfiguration(outboundEnabled: true, outboundText: text, inboundIncrementEnabled: false, inboundIncrementText: "64") }
            }
            try rejects("от 1 до 255") { try TTLConfiguration(outbound: 256, inboundIncrement: nil).validate() }
            try rejects("от 1 до 255") { try TTLConfiguration(outbound: nil, inboundIncrement: 0).validate() }
        }
        test("display whitespace is normalized into a numeric value") {
            let value = try TTLConfiguration(outboundEnabled: true, outboundText: " 64 ", inboundIncrementEnabled: true, inboundIncrementText: "1")
            try check(value.outbound == 64 && value.inboundIncrement == 1, "Whitespace not normalized")
        }
        test("configured rules do not imply verification on traffic or boot persistence") {
            let value = try TTLSettings.parseStatus("TTL_STATUS state=configured outbound=64 inbound_inc=off capability=supported verification=unverified persistence=session\n")
            try check(value.state == .configured && value.verification == .unverified && value.persistence == .session && value.canApply, "Capability/status overstated")
            try check(value.verificationDescription.contains("Автоматическая проверка трафика не выполняется") && value.persistenceDescription.contains("до перезагрузки"), "Misleading status text")
        }
        test("disabled state preserves off values without injecting 64") {
            let value = try TTLSettings.parseStatus("TTL_STATUS state=disabled outbound=off inbound_inc=off capability=supported verification=not-applicable persistence=none")
            try check(value.configuration == .disabled && value.persistenceDescription.isEmpty, "Disabled status invents rules or persistence")
        }
        test("unsupported capability never enables Apply") {
            let value = try TTLSettings.parseStatus("TTL_STATUS state=unsupported outbound=off inbound_inc=off capability=unsupported verification=unverified persistence=none")
            try check(!value.canApply && value.state == .unsupported, "Unsupported target can be applied")
        }
        test("verified result is explicitly a past traffic measurement") {
            let value = try TTLSettings.parseStatus("TTL_STATUS state=verified outbound=65 inbound_inc=128 capability=supported verification=verified persistence=boot")
            try check(value.verificationDescription.contains("последней проверке") && value.persistenceDescription.contains("после перезагрузки"), "Verification or persistence overclaim")
        }
        test("inconsistent success and unsupported claims fail closed") {
            for output in [
                "TTL_STATUS state=disabled outbound=64 inbound_inc=off capability=supported verification=not-applicable persistence=none",
                "TTL_STATUS state=configured outbound=off inbound_inc=off capability=supported verification=unverified persistence=session",
                "TTL_STATUS state=configured outbound=64 inbound_inc=off capability=unknown verification=unverified persistence=session",
                "TTL_STATUS state=unsupported outbound=off inbound_inc=off capability=supported verification=unverified persistence=none"
            ] {
                try rejects("Несогласован") { _ = try TTLSettings.parseStatus(output) }
            }
            try rejects("не подтверждает") { _ = try TTLSettings.parseStatus("TTL_STATUS state=verified outbound=64 inbound_inc=off capability=supported verification=unverified persistence=boot") }
        }
        test("status rejects duplicate unknown missing and invalid fields") {
            let good = "TTL_STATUS state=configured outbound=64 inbound_inc=off capability=supported verification=unverified persistence=session"
            try rejects("Повтор") { _ = try TTLSettings.parseStatus(good + " outbound=65") }
            try rejects("Неполный") { _ = try TTLSettings.parseStatus(good + " extra=1") }
            try rejects("Неполный") { _ = try TTLSettings.parseStatus(good.replacingOccurrences(of: " persistence=session", with: "")) }
            try rejects("Неверное значение") { _ = try TTLSettings.parseStatus(good.replacingOccurrences(of: "outbound=64", with: "outbound=+1")) }
            try rejects("Неверное значение") { _ = try TTLSettings.parseStatus(good.replacingOccurrences(of: "outbound=64", with: "outbound=256")) }
            try rejects("неоднозначный") { _ = try TTLSettings.parseStatus(good + "\n" + good) }
        }
        test("error status retains observations without reporting success") {
            let value = try TTLSettings.parseStatus("TTL_STATUS state=error outbound=64 inbound_inc=off capability=unknown verification=unverified persistence=none")
            try check(value.state == .error && value.configuration.outbound == 64 && !value.canApply, "Error silently erased or promoted")
        }
        print("\(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
