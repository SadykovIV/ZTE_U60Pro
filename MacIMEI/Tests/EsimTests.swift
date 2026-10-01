import Foundation

private enum TestError: Error { case failed(String) }
private func check(_ ok: @autoclosure () throws -> Bool, _ reason: String) throws { if try !ok() { throw TestError.failed(reason) } }
private func rejects(_ body: () throws -> Void) throws { do { try body() } catch is TestError { throw TestError.failed("bad assertion") } catch { return }; throw TestError.failed("unexpected accept") }
private func profile(_ id: String = "890000000000000001", state: String = "disabled", aid: String? = "A0000000000000000000000000000001") -> EsimProfile {
    EsimProfile(iccid: id, isdpAid: aid, state: state, enabled: state == "enabled", nickname: nil, serviceProvider: "Fixture", name: nil)
}
private func snapshot(_ profiles: [EsimProfile] = []) -> EsimSnapshot { EsimSnapshot(ok: true, eid: String(repeating: "1", count: 32), profiles: profiles) }
private func resultLine(_ s: EsimSnapshot, changed: Bool = false, modemVerified: Bool? = nil, radioRestored: Bool? = nil) throws -> Data {
    var result: [String:Any] = ["type":"result", "ok":true, "snapshot":try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)), "changed":changed, "notifications_pending":false]
    if let modemVerified { result["modem_verified"] = modemVerified }
    if let radioRestored { result["radio_restored"] = radioRestored }
    return try JSONSerialization.data(withJSONObject:result)
}

@main enum EsimTests {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--tls-smoke" {
            let ca = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let response = try EsimHTTPSRelay(certificatePEM: ca).perform(["url":"https://rsp.invigo.com/", "tx":"", "headers":["Content-Type: application/json"]])
            print("{\"rcode\":\(response.0),\"bodyBytes\":\(response.1.count)}")
            return
        }
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + name) }
        try test("empty and complete profile inventory") { try snapshot().validate(); try snapshot([profile()]).validate() }
        try test("duplicate ICCID and case folded AID rejected") {
            try rejects { try snapshot([profile(), profile()]).validate() }
            try rejects { try snapshot([profile(), profile("890000000000000002", aid:"a0000000000000000000000000000001")]).validate() }
        }
        try test("malformed identifiers and mismatched state rejected") {
            try rejects { try snapshot([profile("123")]).validate() }
            try rejects { try snapshot([profile(aid:"ABC")]).validate() }
            var p = profile(); p.enabled = true; try rejects { try snapshot([p]).validate() }
        }
        try test("LPA boundaries and confirmation validation") {
            try check(EsimValidation.activationCode("LPA:1$example.com$fixture") != nil,"valid code")
            for code in ["LPA:1$127.0.0.1$x","LPA:1$example.com$", "LPA:1$example.com$hello world", "LPA:1$example.com$" + String(repeating:"x", count:512)] { try check(EsimValidation.activationCode(code) == nil,"invalid accepted") }
            for c in ["-x","has space","new\nline",String(repeating:"a",count:513)] { try rejects { _ = try EsimOperation.download("LPA:1$example.com$fixture",c).request(snapshot:snapshot()) } }
        }
        try test("writes require fresh snapshot and exact target") {
            try rejects { _ = try EsimOperation.enable("890000000000000001").request(snapshot:nil) }
            try rejects { _ = try EsimOperation.enable("890000000000000002").request(snapshot:snapshot([profile()])) }
            try rejects { _ = try EsimOperation.delete("890000000000000001").request(snapshot:snapshot([profile(state:"unknown")])) }
            try rejects { _ = try EsimOperation.delete("890000000000000001").request(snapshot:snapshot([profile(state:"enabled")])) }
        }
        try test("manual SM-DP plus Matching ID forms exact request") {
            for address in ["example.com", " HTTPS://example.com/ ".lowercased(), "https://example.com:443/"] {
                let code=EsimValidation.manualCode(address:address,matchingID:" fixture-ID ")
                try check(code == "LPA:1$example.com$fixture-ID","manual normalization")
                let data=try EsimOperation.download(code!,"").request(snapshot:snapshot())
                let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                try check(object["activation_code"] as? String == code,"manual code unused")
            }
        }
        try test("manual missing injection control and delimiter refused") {
            for address in ["", "https://user@example.com", "http://example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com:444/", "example.com\nother.com", "https://%65xample.com/", "example.com$injected"] {
                try check(EsimValidation.manualCode(address:address,matchingID:"fixture") == nil,"invalid manual address")
            }
            for matching in ["", "one two", "one$two", "one\ntwo", "one\u{0}two", String(repeating:"x",count:512)] {
                try check(EsimValidation.manualCode(address:"example.com",matchingID:matching) == nil,"invalid manual matching id")
            }
        }
        try test("delete carries explicit confirmation") {
            let data = try EsimOperation.delete("890000000000000001").request(snapshot:snapshot([profile()]))
            let o = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            try check(o["confirm_delete"] as? Bool == true,"confirmation omitted")
        }
        try test("RPC success requires final and zero exit") {
            var d = EsimRPCDecoder(); try rejects { _ = try d.finish(exitCode:0,operation:.list,before:nil) }
            _ = try d.consume(resultLine(snapshot())); _ = try d.finish(exitCode:0,operation:.list,before:nil)
            try rejects { _ = try d.finish(exitCode:1,operation:.list,before:nil) }
        }
        try test("duplicate final and progress after final rejected") {
            var d = EsimRPCDecoder(); _ = try d.consume(resultLine(snapshot()))
            try rejects { _ = try d.consume(resultLine(snapshot())) }
            try rejects { _ = try d.consume(Data(#"{"type":"progress","stage":"verifying"}"#.utf8)) }
        }
        try test("malformed and arbitrary diagnostic strings rejected") {
            for text in ["invalid", #"{"type":"progress","stage":"private-fixture"}"#, #"{"type":"http","id":true,"payload":{}}"#] { var d=EsimRPCDecoder(); try rejects { _ = try d.consume(Data(text.utf8)) } }
        }
        try test("failed final never authorizes writes") {
            var d=EsimRPCDecoder(); _ = try d.consume(Data(#"{"type":"result","ok":false,"error":"private-fixture"}"#.utf8))
            try rejects { _ = try d.finish(exitCode:0,operation:.list,before:nil) }
        }
        try test("legacy progress and cleanup telemetry sequence") {
            var d = EsimRPCDecoder()
            _ = try d.consume(Data(#"{"type":"progress","stage":"checking_card"}"#.utf8))
            for i in 1...2 {
                let fields: [String: Any] = ["type":"progress", "stage":"cleanup", "detail":["event":"waiting", "log_seq":i, "elapsed_ms":5000*i, "apdu_count":25, "http_count":2, "waiting_for":"cleanup"]]
                guard case .progress(let stage, let detail) = try d.consume(JSONSerialization.data(withJSONObject: fields)) else { throw TestError.failed("event") }
                try check(stage == "cleanup" && detail?.sequence == i && detail?.summary.contains("waiting_for=cleanup") == true,"metadata")
            }
        }
        try test("progress rejects duplicate gaps booleans and unbounded metadata") {
            let good: [String: Any] = ["event":"waiting", "log_seq":1, "elapsed_ms":5, "apdu_count":1, "http_count":1]
            for (key, bad): (String, Any) in [("log_seq", 2), ("log_seq", true), ("elapsed_ms", -1), ("apdu_count", 1.5), ("http_status", 600), ("event", "private-fixture")] {
                var fields = good; fields[key] = bad
                var d = EsimRPCDecoder()
                try rejects { _ = try d.consume(JSONSerialization.data(withJSONObject: ["type":"progress", "stage":"downloading", "detail":fields])) }
            }
            var d = EsimRPCDecoder()
            let line = try JSONSerialization.data(withJSONObject: ["type":"progress", "stage":"downloading", "detail":good])
            _ = try d.consume(line); try rejects { _ = try d.consume(line) }
        }
        try test("journal allowlist never copies private arbitrary fields") {
            let secret = "LPA:1$example.com$synthetic-secret"
            let fields: [String: Any] = ["event":"http_end", "log_seq":1, "elapsed_ms":100, "apdu_count":2, "http_count":1, "http_status":404, "duration_ms":15, "response_bytes":14, "component":secret, "waiting_for":secret, "outcome":secret, "error":secret, "url":secret, "eid":String(repeating:"8",count:32), "body":secret]
            let value = try EsimProgressDetail(fields).summary
            try check(value.contains("http_status=404") && value.contains("duration_ms=15") && value.contains("error=unrecognized_backend_error"),"missing safe metadata")
            for privateValue in [secret, String(repeating:"8",count:32), "example.com", "synthetic-secret", "url=", "body="] { try check(!value.contains(privateValue),"private journal leak") }
        }
        try test("known final error visible and unknown error cannot escape") {
            for (raw, expected) in [("lpac_failed", "lpac_failed"), ("LPA:1$example.com$synthetic-secret", "unrecognized_backend_error")] {
                var d = EsimRPCDecoder()
                _ = try d.consume(JSONSerialization.data(withJSONObject:["type":"result","ok":false,"error":raw]))
                do { _ = try d.finish(exitCode:0,operation:.list,before:nil); throw TestError.failed("failed result accepted") }
                catch let failure as EsimFailure {
                    try check(EsimLog.failureCode(failure) == expected,"unsafe final error")
                    try check(!failure.localizedDescription.contains("synthetic-secret"),"private UI error")
                }
                try rejects { _ = try d.finish(exitCode:1,operation:.list,before:nil) }
            }
        }
        try test("HTTP ids unique positive and forbidden during list") {
            let request=Data(#"{"type":"http","id":1,"payload":{}}"#.utf8)
            var d=EsimRPCDecoder();_ = try d.consume(request);try rejects {_ = try d.consume(request)}
            var list=EsimRPCDecoder();list.allowsHTTP=false;try rejects {_ = try list.consume(request)}
            var zero=EsimRPCDecoder();try rejects {_ = try zero.consume(Data(#"{"type":"http","id":0,"payload":{}}"#.utf8))}
        }
        try test("download must add exactly one disabled profile") {
            var d=EsimRPCDecoder(); _ = try d.consume(resultLine(snapshot([profile()]),changed:true)); _ = try d.finish(exitCode:0,operation:.download("LPA:1$example.com$x",""),before:snapshot())
            var bad=EsimRPCDecoder(); _ = try bad.consume(resultLine(snapshot([profile(state:"enabled")]),changed:true)); try rejects { _ = try bad.finish(exitCode:0,operation:.download("LPA:1$example.com$x",""),before:snapshot()) }
        }
        try test("enable verifies target and preserves inventory") {
            let before=snapshot([profile(),profile("890000000000000002",state:"enabled",aid:nil)])
            var d=EsimRPCDecoder(); _ = try d.consume(resultLine(snapshot([profile(state:"enabled"),profile("890000000000000002",aid:nil)]),changed:true,modemVerified:true,radioRestored:true)); _ = try d.finish(exitCode:0,operation:.enable("890000000000000001"),before:before)
            var bad=EsimRPCDecoder(); _ = try bad.consume(resultLine(snapshot([profile(state:"enabled")]),changed:true)); try rejects { _ = try bad.finish(exitCode:0,operation:.enable("890000000000000001"),before:before) }
        }
        try test("enable requires modem readback and restored radio after card activation") {
            let before=snapshot([profile()]), after=snapshot([profile(state:"enabled")])
            for (modem,radio): (Bool?,Bool?) in [(nil,nil),(true,nil),(nil,true),(false,true),(true,false)] {
                var d=EsimRPCDecoder();_ = try d.consume(resultLine(after,changed:true,modemVerified:modem,radioRestored:radio))
                try rejects { _ = try d.finish(exitCode:0,operation:.enable("890000000000000001"),before:before) }
            }
            let reread = try JSONSerialization.jsonObject(with: EsimOperation.enable("890000000000000001").request(snapshot: after)) as! [String:Any]
            try check(reread["operation"] as? String == "enable" && reread["iccid"] as? String == "890000000000000001" && reread["expected_snapshot"] != nil, "active reread changed operation or lost snapshot")
            var already=EsimRPCDecoder();_ = try already.consume(resultLine(after,changed:false,modemVerified:true,radioRestored:true))
            _ = try already.finish(exitCode:0,operation:.enable("890000000000000001"),before:after)
        }
        try test("radio progress and fixed recovery failure preserve safe diagnostics") {
            for stage in ["radio_offline","radio_online","reading_modem"] {
                var d=EsimRPCDecoder();_ = try d.consume(JSONSerialization.data(withJSONObject:["type":"progress","stage":stage]))
                try check(EsimService.stages[stage] != nil,"radio stage has no UI label")
            }
            for code in ["radio_restore_failed","modem_iccid_mismatch","modem_slot_mismatch","launcher_operation_refused"] {
                try check(EsimLog.backendError(code) == code,"new fixed backend error hidden")
            }
            try check(EsimFailure.backend("radio_restore_failed").localizedDescription.contains("Включение радио"),"radio recovery warning missing")
        }
        try test("EID change invalidates mutation result") {
            var after=snapshot([profile()]);after.eid=String(repeating:"2",count:32)
            var d=EsimRPCDecoder();_ = try d.consume(resultLine(after,changed:true));try rejects {_ = try d.finish(exitCode:0,operation:.download("LPA:1$example.com$x",""),before:snapshot())}
        }
        try test("HTTPS request restrictions and POST empty body") {
            let good:[String:Any] = ["url":"https://rsp.invigo.com/", "tx":"", "headers":["Content-Type: application/json"]]
            try check(EsimHTTPSRelay.request(good).httpMethod == "POST","method")
            for url in ["http://example.com/","https://127.0.0.1/","https://user@example.com/","https://example.com:444/","https://example.com/#x","https://[::1]/"] { var bad=good;bad["url"]=url;if (try? EsimHTTPSRelay.request(bad)) != nil { throw TestError.failed("HTTPS accepted: " + String(describing: bad)) } }
            for headers in [["Authorization: private"],["Content-Type: x\r\ny"]] { var bad=good;bad["headers"]=headers;if (try? EsimHTTPSRelay.request(bad)) != nil { throw TestError.failed("HTTPS accepted: " + String(describing: bad)) } }
            var bad=good;bad["tx"]="0Z";try rejects {_ = try EsimHTTPSRelay.request(bad)}
        }
        try test("masking and card label sanitation") {
            let text="890000000000000001";try check(!EsimPrivacy.mask(text).contains(text),"unmasked")
            try check(!EsimPrivacy.label("plan " + text + " LPA:1$example.com$secret").contains("secret"),"code leaked")
        }
        if CommandLine.arguments.count == 2 {
            let fixtures=URL(fileURLWithPath:CommandLine.arguments[1])
            try test("Vision one QR") { try check(EsimQR.read(fixtures.appendingPathComponent("single-qr.png")) == "LPA:1$example.com$synthetic-test","QR") }
            try test("Vision multiple and non LPA QR refused") { for file in ["multiple-qr.png","non-esim-qr.png"] {try rejects {_ = try EsimQR.read(fixtures.appendingPathComponent(file))}} }
        }
        print("\(passed) tests passed; no device calls")
    }
}
