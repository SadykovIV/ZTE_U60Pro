import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw Failure(message: message) }
}
private func failedResult(_ error: String, cause: Any? = nil) throws -> (EsimRPCDecoder, EsimRPCResult) {
    var value: [String: Any] = ["type": "result", "ok": false, "error": error]
    if let cause { value["component_error"] = cause }
    var decoder = EsimRPCDecoder()
    _ = try decoder.consume(JSONSerialization.data(withJSONObject: value))
    guard let result = decoder.result else { throw Failure(message: "missing failed result") }
    return (decoder, result)
}

@main enum MacEsimCardDiagnosticTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "catalog path required") }
        let catalog = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS " + name)
        }
        try test("component allowlist exactly matches backend receipt") {
            try check(Set(catalog) == EsimLog.componentErrors && catalog.count == EsimLog.componentErrors.count, "catalog mismatch")
            for code in catalog {
                let (_, result) = try failedResult("card_cleanup_unknown", cause: code)
                try check(result.componentError == code, "known cause lost")
                try check(EsimLog.resultMetadata(result).contains("component_error=" + code), "cause not journaled")
            }
        }
        try test("six card failures stay typed for exit zero and one and cannot authorize writes") {
            for code in ["card_busy", "card_open_rejected", "card_cleanup_unknown", "card_not_ready", "card_reset_failed", "card_power_restore_failed"] {
                try check(EsimLog.backendError(code) == code, "new fixed code hidden")
                for exit: Int32 in [0, 1] {
                    let (decoder, _) = try failedResult(code, cause: "qmi_open_unknown")
                    do {
                        _ = try decoder.finish(exitCode: exit, operation: .list, before: nil)
                        throw Failure(message: "failed card result authorized access")
                    } catch let error as EsimFailure {
                        guard case .backend(let actual) = error else { throw Failure(message: "lost backend category") }
                        try check(actual == code, "lost fixed failure")
                    }
                }
            }
        }
        try test("unknown cleanup keeps first rejection cause in sanitized journal") {
            let (_, result) = try failedResult("card_cleanup_unknown", cause: "qmi_open_rejected")
            let text = EsimLog.resultMetadata(result)
            try check(text.contains("error=card_cleanup_unknown") && text.contains("component_error=qmi_open_rejected"), "first cause overwritten")
            try check(EsimLog.recoveryCode(.backend("card_cleanup_unknown")) == "restart_modem_before_retry", "unsafe retry advice")
        }
        try test("unknown and private causes are discarded before journal and UI") {
            for privateValue in ["LPA:1$private.invalid$synthetic-secret", String(repeating: "8", count: 32), "qmi_open_unknown\nprivate"] {
                let (_, result) = try failedResult("card_cleanup_unknown", cause: privateValue)
                try check(result.componentError == nil, "private cause retained")
                let text = EsimLog.resultMetadata(result) + EsimLog.componentMetadata(privateValue)
                try check(!text.contains(privateValue) && !text.contains("component_error="), "private cause escaped")
            }
        }
        try test("legacy omission and null remain compatible but wrong types fail") {
            let (_, legacy) = try failedResult("snapshot_cleanup_failed")
            let (_, null) = try failedResult("card_busy", cause: NSNull())
            try check(legacy.componentError == nil && null.componentError == nil, "optional cause changed legacy schema")
            for invalid: Any in [true, 12, ["code": "qmi_open_unknown"], ["qmi_open_unknown"]] {
                do { _ = try failedResult("card_busy", cause: invalid); throw Failure(message: "invalid cause type accepted") }
                catch is DecodingError { }
            }
        }
        try test("RU and EN card messages distinguish reset from readiness") {
            let ru = EsimFailure.backend("card_cleanup_unknown").localizedDescription
            let en = EsimLog.localizedCardMessage(ru, language: "en")
            try check(ru.contains("Перезагрузите модем") && en.contains("Restart the modem"), "reboot instruction missing")
            try check(EsimLog.localizedCardMessage(ru, language: "ru") == ru, "Russian message changed")
            for code in ["card_busy", "card_open_rejected", "card_not_ready"] {
                let russian = EsimFailure.backend(code).localizedDescription
                let english = EsimLog.localizedCardMessage(russian, language: "en")
                try check(russian != english && english.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil, "English message untranslated")
                try check(english.contains("Wait") && english.contains("refresh"), "readiness advice missing")
                try check(EsimLog.recoveryCode(.backend(code)) == "wait_then_refresh_profiles", "wrong recovery action")
            }
        }
        try test("SIM power errors preserve distinct recovery and do not extend helper catalog") {
            for code in ["card_reset_failed", "card_power_restore_failed"] {
                try check(EsimLog.componentError(code) == nil, "agent error entered helper catalog")
                let ru = EsimFailure.backend(code).localizedDescription
                let en = EsimLog.localizedCardMessage(ru, language: "en")
                try check(ru != en && en.contains("unconfirmed") && en.contains("profiles"), "SIM power error untranslated")
            }
            try check(EsimLog.cardMessage("card_reset_failed")!.contains("Перезапуск SIM не подтверждён"), "reset result overstated")
            try check(EsimLog.cardMessage("card_power_restore_failed")!.contains("Перезагрузите модем"), "power restore needs reboot")
            try check(EsimLog.recoveryCode(.backend("card_reset_failed")) == "refresh_profiles_before_retry", "reset recovery action")
            try check(EsimLog.recoveryCode(.backend("card_power_restore_failed")) == "restart_modem_before_retry", "power recovery action")
        }
        try test("new optional cause does not relax success postconditions") {
            var decoder = EsimRPCDecoder()
            _ = try decoder.consume(JSONSerialization.data(withJSONObject: ["type":"result", "ok":true,
                "snapshot":["ok":true,"eid":String(repeating:"1",count:32),"profiles":[]],
                "changed":false,"notifications_pending":false]))
            _ = try decoder.finish(exitCode:0,operation:.list,before:nil)
            do { _ = try decoder.finish(exitCode:1,operation:.list,before:nil); throw Failure(message:"nonzero success accepted") }
            catch let error as EsimFailure { guard case .transport = error else { throw Failure(message:"wrong exit category") } }
            var contradictory = EsimRPCDecoder()
            _ = try contradictory.consume(JSONSerialization.data(withJSONObject: ["type":"result", "ok":true,
                "snapshot":["ok":true,"eid":String(repeating:"1",count:32),"profiles":[]],
                "changed":false,"notifications_pending":false,"component_error":"qmi_open_rejected"]))
            do { _ = try contradictory.finish(exitCode:0,operation:.list,before:nil); throw Failure(message:"success with known failure cause accepted") }
            catch let error as EsimFailure { guard case .protocolError = error else { throw Failure(message:"wrong contradictory result category") } }
        }
        print("PASS \(passed) groups; \(catalog.count) fixed component codes; no network or device")
    }
}
