import Foundation

private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private let cid = "0123456789abcdef0123456789abcdef"
private let cidHash = digest(Data((cid + "\n").utf8))
private let bootHash = digest(Data("boot\n".utf8))
private let title = ResearchText(ru: "Проверка", en: "Probe")
private func specification() -> ResearchSpecification {
    ResearchSpecification(schemaVersion: 1, revision: 1,
        profiles: [.init(id: "b31", firmwareSHA256: "known", routerSHA256: "known-router", architecture: "aarch64")],
        probes: [.init(id: "identity", title: title, category: "identity", command: "id -u", timeoutSeconds: 1, maxBytes: 1024),
                 .init(id: "firmware-hashes", title: title, category: "identity", command: "sha256sum /firmware/image/modem.b16", timeoutSeconds: 1, maxBytes: 1024)],
        features: [.init(id: "imei", title: title, profiles: ["b31"], platforms: nil, requirements: [.init(probe: "identity", fact: "root", equals: "1", label: title)], limitations: title)])
}
private final class FakeRunner: ResearchProcessRunning {
    var streamed = 0
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation, input: ADBStreamInput?) throws -> ResearchCommandResult {
        guard let input else { return try run(executable, arguments: arguments, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation) }
        streamed += 1
        var args = arguments; args[3] = "(" + input.auditOriginal + "); zte_code=$?; printf '\n" + input.result + "%s\n' \"$zte_code\""
        var value = try run(executable, arguments: args, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation)
        value.stdout = Data((input.begin + "\n").utf8) + value.stdout
        return value
    }
    var calls: [[String]] = []; var sshFailure = "Connection refused"; var sshOutcome = "failed"; var devices = ["USB-SECRET"]
    var nonroot = false; var mismatch = false; var missingIdentity = false; var changeAfter = false; var probeCalls = 0
    var physicalMismatch = false; var losePhysicalAfterProbe = false
    var physicalDelay: TimeInterval = 0; var probeTimeouts = [TimeInterval]()
    var probeOutcome = "success"; var token: ResearchCancellation?; var cancelAfterFirst = false
    var remoteCode = 0; var omitFooter = false; var lineEnding = "\n"
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation) throws -> ResearchCommandResult {
        calls.append(arguments)
        if executable.lastPathComponent == "ssh" { return .init(status: 255, stdout: Data(), stderr: Data(sshFailure.utf8), outcome: sshOutcome, duration: 0.01) }
        if arguments == ["version"] { return .init(status: 0, stdout: Data("Android Debug Bridge test".utf8), stderr: Data(), outcome: "success", duration: 0) }
        if arguments == ["-d", "get-serialno"] {
            if physicalDelay > 0 { Thread.sleep(forTimeInterval: physicalDelay) }
            let ok = devices.count == 1 && !(losePhysicalAfterProbe && probeCalls > 0)
            return .init(status: ok ? 0 : 1, stdout: Data((physicalMismatch ? "OTHER-USB" : devices.first ?? "").utf8), stderr: Data(), outcome: ok ? "success" : "failed", duration: 0)
        }
        if arguments == ["devices", "-l"] { return .init(status: 0, stdout: Data(("List of devices attached\n" + devices.map { $0 + " device usb:1 transport_id:1\n" }.joined()).utf8), stderr: Data(), outcome: "success", duration: 0) }
        try check(arguments.count == 4 && arguments[0] == "-s" && arguments[2] == "shell", "Unexpected mutation/tool command")
        let command = arguments[3]; guard let marker = ADBClient.shellMarker(in: command) else { throw Failure.assertion("No footer") }
        let output: String
        if command.contains(FirmwareResearchCollector.bootstrap) {
            output = "uid=\(nonroot ? "2000" : "0")\narchitecture=aarch64\n" + (missingIdentity ? "" : "cid=\(mismatch ? String(repeating: "a", count: 64) : cidHash)\nboot=\(changeAfter && probeCalls > 0 ? String(repeating: "b", count: 64) : bootHash)\n")
        } else {
            probeCalls += 1; probeTimeouts.append(timeout)
            if cancelAfterFirst { cancellation.cancel() }
            if command.contains("sha256sum") { output = "FR_FACT firmware_sha256=unknown\nFR_FACT router_sha256=known-router\n" }
            else { output = "FR_FACT uid=\(nonroot ? "2000" : "0")\nFR_FACT architecture=aarch64\nFR_FACT root=\(nonroot ? "0" : "1")\nSUPER-SECRET-WEB\npassword=unlabelled-value\nIMEI=867123456789017\n" }
        }
        let outcome = command.contains(FirmwareResearchCollector.bootstrap) ? "success" : probeOutcome
        let footer = !command.contains(FirmwareResearchCollector.bootstrap) && omitFooter ? "" : "\n" + marker + String(command.contains(FirmwareResearchCollector.bootstrap) ? 0 : remoteCode) + "\n"
        return .init(status: 0, stdout: Data((output + footer).replacingOccurrences(of: "\n", with: lineEnding).utf8), stderr: Data(), outcome: outcome, duration: 0.02)
    }
}

@main struct FirmwareResearchTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("firmware-tests-" + UUID().uuidString)
        try secureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Resources"); try secureDirectory(assets.appendingPathComponent("Onboarding"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Resources/Onboarding/adb-stream.sh"), to: assets.appendingPathComponent("Onboarding/adb-stream.sh"))
        let adb = assets.appendingPathComponent("Onboarding/adb"); try savePrivate(Data("FAKE-ADB".utf8), adb)
        try saveJSON(["adb": digest(Data("FAKE-ADB".utf8))], assets.appendingPathComponent("Onboarding/SHA256.json"))
        let key = root.appendingPathComponent("key"), hosts = root.appendingPathComponent("known_hosts")
        try savePrivate(Data("fake".utf8), key); try savePrivate(Data("fake".utf8), hosts)
        let config = Connection(host: "192.168.0.1", port: "2222", keyPath: key.path, knownHostsPath: hosts.path)
        func collect(_ fake: FakeRunner, mode: ConnectionMode = .automatic, expected: String? = nil) -> FirmwareResearchReport {
            FirmwareResearchCollector(specification: specification(), connection: config, mode: mode, resources: assets, cancellation: ResearchCancellation(), expectedCID: expected, secrets: ["SUPER-SECRET-WEB"], runner: fake).collect(context: ["appVersion": "test"]) { _, _ in }
        }
        for eol in ["\n", "\r\n", "\r\r\n"] {
            let fake = FakeRunner(); fake.lineEnding = eol
            let value = collect(fake, mode: .adb, expected: cid)
            try check(value.outcome == "complete" && value.binding["architecture"] == "aarch64" && value.probes.allSatisfy { $0.outcome == "success" && $0.remoteExitCode == 0 && !$0.stdout.contains("\r") }, "Research line endings lost remote result or binding")
            try check(value.probes.first { $0.id == "identity" }?.facts["root"] == "1", "Research root fact lost")
            let failed = FakeRunner(); failed.lineEnding = eol; failed.remoteCode = 1
            try check(collect(failed, mode: .adb).probes.allSatisfy { $0.outcome == "failed" && $0.localExitCode == 0 && $0.remoteExitCode == 1 }, "Research line ending failure became success")
        }
        print("PASS research LF/CRLF/CRCRLF bootstrap, facts, remote failures and report text")
        let longSpec = ResearchSpecification(schemaVersion: 1, revision: 1, profiles: [],
            probes: [.init(id: "long", title: title, category: "identity", command: "#" + String(repeating: "x", count: 4096) + "\nid -u", timeoutSeconds: 1, maxBytes: 1024)], features: [])
        let longRunner = FakeRunner()
        let longReport = FirmwareResearchCollector(specification: longSpec, connection: config, mode: .adb, resources: assets, cancellation: ResearchCancellation(), expectedCID: nil, secrets: [], runner: longRunner).collect(context: [:]) { _, _ in }
        try check(longRunner.streamed == 1 && longReport.outcome == "complete" && longReport.probes.first?.remoteExitCode == 0, "Long research command bypassed stream/remote proof")
        let normal = FakeRunner(), report = collect(normal)
        try check(report.transport == "adb" && report.outcome == "complete", "Unprepared unknown firmware should collect")
        try check(report.features[0].state == "unknown", "Unknown firmware must never certify writes")
        try check(report.probes.count == 2 && report.probes.allSatisfy { $0.outcome == "success" }, "Successful probe accounting")
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try check(!encoded.contains("SUPER-SECRET-WEB") && !encoded.contains("867123456789017") && !encoded.contains("USB-SECRET") && !encoded.contains(cid), "Secrets escaped report")
        let manual = FakeRunner(); let manualReport = collect(manual, mode: .ssh)
        try check(manualReport.transport == "none" && manual.calls.count == 1 && manualReport.probes.allSatisfy { $0.outcome == "skipped" }, "Manual SSH must never fallback or invent probe faults")
        let trust = FakeRunner(); trust.sshFailure = "Host key verification failed."; let trustReport = collect(trust)
        try check(trust.calls.count == 1 && trustReport.attempts.contains { $0.outcome == "host_trust_failed" }, "Host trust failure fallback")
        let auth = FakeRunner(); auth.sshFailure = "Permission denied (publickey)."; _ = collect(auth)
        try check(auth.calls.count == 1, "Authentication failure must not fallback")
        let stalled = FakeRunner(); stalled.sshFailure = ""; stalled.sshOutcome = "timeout"; _ = collect(stalled)
        try check(stalled.calls.count == 1, "Unclassified SSH shell timeout must not switch devices")
        let several = FakeRunner(); several.devices = ["ONE", "TWO"]; let ambiguous = collect(several, mode: .adb)
        try check(ambiguous.transport == "none" && several.probeCalls == 0, "Ambiguous USB selection")
        let mismatch = FakeRunner(); mismatch.mismatch = true; let mismatchReport = collect(mismatch, mode: .adb, expected: cid)
        try check(mismatchReport.transport == "none" && mismatch.probeCalls == 0, "Mismatched device")
        let physical = FakeRunner(); physical.physicalMismatch = true
        try check(collect(physical, mode: .adb).probes.allSatisfy { $0.outcome == "skipped" } && physical.probeCalls == 0, "ADB serial alone must not prove physical USB")
        let slowUSB = FakeRunner(); slowUSB.physicalDelay = 0.04
        try check(collect(slowUSB, mode: .adb).outcome == "complete" && slowUSB.probeTimeouts.count == 2 && slowUSB.probeTimeouts.allSatisfy { $0 > 0 && $0 < 0.98 }, "Physical USB proof must share the command deadline")
        let lostPhysical = FakeRunner(); lostPhysical.losePhysicalAfterProbe = true; lostPhysical.missingIdentity = true
        try check(collect(lostPhysical, mode: .adb).probes.allSatisfy { $0.outcome == "skipped" } && lostPhysical.probeCalls == 1, "Unbound USB loss must discard active probe and stop")
        let changed = FakeRunner(); changed.changeAfter = true; let changedReport = collect(changed)
        try check(changedReport.probes.allSatisfy { $0.outcome == "skipped" } && changed.probeCalls == 1, "Device change must discard current probe and stop")
        let nonroot = FakeRunner(); nonroot.nonroot = true; let nonrootReport = collect(nonroot)
        try check(nonrootReport.transport == "adb" && nonrootReport.features[0].state == "blocked", "Nonroot diagnosis must collect and report specific blocker")
        let missing = FakeRunner(); missing.missingIdentity = true; let missingReport = collect(missing)
        try check(missingReport.transport == "adb" && !missingReport.warnings.isEmpty && missing.probeCalls == 2 && missingReport.binding["uid"] == "0", "Missing fingerprints must still collect bounded read-only evidence without granting authorization")
        try check(missingReport.bindingStrength == "transport-only" && missingReport.authorization == "none", "Unbound evidence cannot authorize writes")
        try check(report.bindingStrength == "full" && report.authorization == "none", "Bound evidence cannot authorize writes either")
        try check(FirmwareResearchCollector.bindingStrength(["boot": bootHash]) == "partial", "Partial binding")
        let observationSpec = ResearchSpecification(schemaVersion: 1, revision: 1, profiles: [], probes: specification().probes, features: [], observations: [.init(id: "root", title: title, probe: "identity", fact: "root")])
        for (raw, expectedState) in [("0", "known"), ("1", "known"), ("absent", "absent"), ("missing", "absent"), ("not-assessed", "not-assessed"), ("conflicting", "not-assessed")] {
            let probe = ResearchProbeResult(id: "identity", title: title, category: "identity", command: "", outcome: "success", exitCode: 0, stdout: "", stderr: "", durationSeconds: 0, facts: ["root": raw])
            let result = FirmwareResearchCollector.observe(observationSpec, results: [probe])[0]
            try check(result.sourceStatus == "success" && result.sourceExitCode == 0, "Observation provenance missing")
            try check(result.state == expectedState && (expectedState == "known" ? result.value == raw : result.value == nil), "Observation state misrepresented unavailable or zero value")
            try check(FirmwareResearchCollector.observe(observationSpec, results: [probe], continuityLost: true)[0].state == "not-assessed", "Lost continuity cannot certify observations")
        }
        let timed = FakeRunner(); timed.probeOutcome = "timeout"; let timedReport = collect(timed)
        try check(timedReport.probes.allSatisfy { $0.outcome == "timeout" } && timedReport.features[0].state == "unknown", "Timeout evidence cannot satisfy prerequisites")
        let remoteFailure = FakeRunner(); remoteFailure.remoteCode = 1; let remoteFailureReport = collect(remoteFailure)
        try check(remoteFailureReport.probes.allSatisfy { $0.outcome == "failed" && $0.localExitCode == 0 && $0.remoteExitCode == 1 }, "Local ADB zero must not hide remote failure")
        let noFooter = FakeRunner(); noFooter.omitFooter = true; let noFooterReport = collect(noFooter)
        try check(noFooterReport.probes.allSatisfy { $0.outcome == "failed" && $0.localExitCode == 0 && $0.remoteExitCode == nil }, "Missing footer cannot invent remote success")
        let cancelled = FakeRunner(); cancelled.cancelAfterFirst = true; let cancelledReport = collect(cancelled)
        try check(cancelledReport.outcome == "cancelled" && cancelledReport.probes.count == 2, "Cancellation should retain partial report")
        _ = try FirmwareResearchArchive.save(cancelledReport, root: root)
        try check(try FirmwareResearchArchive.latest(root: root).id == cancelledReport.id, "Offline persisted report")
        let zip = root.appendingPathComponent("report.zip")
        try check(try FirmwareResearchArchive.export(report, to: zip).count == 64, "ZIP checksum")
        let redactor = ResearchRedactor(secrets: ["literal-secret", "USB-SECRET", cid])
        let unsafe = "literal-secret\nUSB-SECRET\n\(cid)\n867123456789017\npassword='abc'\nkey_2g=abc\npsk=abc\nCookie: abc\nAuthorization: Bearer abc\n-----BEGIN PRIVATE KEY-----\nHIDDEN-KEY\n-----END PRIVATE KEY-----\nAA:BB:CC:DD:EE:FF\n192.168.0.1"
        let sanitized = redactor.clean(unsafe)
        for value in ["literal-secret", "USB-SECRET", cid, "867123456789017", "abc", "HIDDEN-KEY", "AA:BB", "192.168"] { try check(!sanitized.contains(value), "Redaction missed " + value) }
        let processRunner = ResearchBoundedRunner()
        let clipped = try processRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while :; do printf 'abcdefghijabcdefghijabcdefghij'; done"], timeout: 3, maxBytes: 1024, cancellation: ResearchCancellation())
        try check(clipped.outcome == "truncated" && clipped.stdout.count + clipped.stderr.count <= 1024, "Host output bound")
        let timeout = try processRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"], timeout: 0.1, maxBytes: 1024, cancellation: ResearchCancellation())
        try check(timeout.outcome == "timeout" && timeout.duration < 2, "Host timeout bound")
        let token = ResearchCancellation(); token.cancel()
        let stopped = try processRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"], timeout: 3, maxBytes: 1024, cancellation: token)
        try check(stopped.outcome == "cancelled", "Host cancellation")
        let unclosed = try processRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 2 & printf inherited"], timeout: 4, maxBytes: 1024, cancellation: ResearchCancellation())
        try check(unclosed.outcome == "timeout", "Inherited incomplete output must not count as success")
        try check(FirmwareResearchCollector.facts("FR_FACT root=1\nFR_FACT root=0")["root"] == "conflicting", "Ambiguous duplicate facts")
        let fullLength = String(repeating: "x", count: 512)
        try check(FirmwareResearchCollector.facts("FR_FACT test=" + fullLength)["test"] == fullLength, "512-byte facts omitted")
        try check(FirmwareResearchCollector.facts("FR_FACT test=" + fullLength + "x").isEmpty && FirmwareResearchCollector.facts("FR_FACT test=tab\tvalue").isEmpty && FirmwareResearchCollector.facts("FR_FACT test=bad\0value").isEmpty, "Oversize or control facts accepted")
        let dynamicProbe = ResearchProbeResult(id: "identity", title: title, category: "identity", command: "", outcome: "success", exitCode: 0, stdout: "", stderr: "", durationSeconds: 0, facts: ["new_component": "0"])
        let dynamic = FirmwareResearchCollector.observe(specification(), results: [dynamicProbe])
        try check(dynamic.count == 1 && dynamic[0].probe == "identity" && dynamic[0].fact == "new_component" && dynamic[0].value == "0", "Unmapped observed facts disappear from inventory")
        let identityProbe = ResearchProbeResult(id: "identity", title: title, category: "identity", command: "id", outcome: "success", exitCode: 0, stdout: "", stderr: "", durationSeconds: 0, facts: ["architecture": "aarch64", "root": "1", "firmware_sha256": "known", "router_sha256": "known-router"])
        try check(FirmwareResearchCollector.profile(specification(), results: [identityProbe]) == nil, "Unrelated probe may not supply firmware hashes")
        let afterChange = FirmwareResearchCollector.assess(specification(), results: [identityProbe], profile: "b31", continuityLost: true)
        try check(afterChange.allSatisfy { $0.state == "unknown" }, "Lost device continuity cannot leave green prerequisites")
        try check(FirmwareResearchCollector.assess(specification(), results: [identityProbe], profile: "b31", bindingComplete: false).allSatisfy { $0.state == "unknown" }, "Partial binding produced green operation prerequisites")
        let unsupported = FirmwareResearchCollector.assess(specification(), results: [identityProbe], profile: "b02-experimental")
        try check(unsupported.allSatisfy { $0.state == "blocked" }, "A known firmware profile excluded by current operation is a confirmed blocker")
        let bundledResources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        let bundled = try ResearchSpecification.load(bundledResources)
        try check(bundled.probes.count == 57 && bundled.features.count == 19 && bundled.revision == 11 && bundled.observations?.count == 76, "Bundled reviewed specification")
        var values = [String: [String: String]]()
        for feature in bundled.features { for requirement in feature.requirements { values[requirement.probe, default: [:]][requirement.fact] = requirement.equals } }
        values["boot-protection"]?["restore_readiness"] = "not-assessed"
        values["esim-components"]?["physical_euicc_management"] = "not-assessed"
        values["esim-components"]?["native_isdr_access"] = "not-assessed"
        let prerequisites = bundled.probes.map { probe in ResearchProbeResult(id: probe.id, title: probe.title, category: probe.category, command: probe.command, outcome: "success", exitCode: 0, stdout: "", stderr: "", durationSeconds: 0, facts: values[probe.id] ?? [:]) }
        let realB31 = bundled.profiles.first { $0.id == "b31" }!
        let hashProbe = ResearchProbeResult(id:"firmware-hashes", title:title, category:"identity", command:"", outcome:"success", exitCode:0, stdout:"", stderr:"", durationSeconds:0, facts:["firmware_sha256":realB31.firmwareSHA256,"router_sha256":realB31.routerSHA256])
        try check(FirmwareResearchCollector.profile(bundled, results:[identityProbe,hashProbe]) == "b31", "Successful B31 identity and pinned hashes select the exact profile")
        let failedIdentity = ResearchProbeResult(id:"identity", title:title, category:"identity", command:"", outcome:"failed", exitCode:1, stdout:"", stderr:"", durationSeconds:0, facts:identityProbe.facts)
        try check(FirmwareResearchCollector.profile(bundled, results:[failedIdentity,hashProbe]) == nil, "Failed probes do not silently become trusted after the no-LF fix")
        try check(bundled.features.filter { ["config-backup","user-data-backup","modem-backup","full-backup","full-restore"].contains($0.id) }.allSatisfy { feature in feature.requirements.contains { $0.fact == "tmp_private_stage_parent" } && !feature.requirements.contains { $0.fact == "tmp_safe" } }, "Backup assessment accepts a sticky private-stage parent independently of installer parents")
        try check(bundled.features.filter { ["preparation","ssh"].contains($0.id) }.allSatisfy { feature in feature.requirements.contains {  $0.fact == "setup_anchor_safe" } }, "Installer uses the protected private anchor")
        try check(bundled.features.first { $0.id == "agent" }!.requirements.contains { $0.fact == "dashboard_runtime_safe" } && !bundled.features.first { $0.id == "agent" }!.requirements.contains {  $0.fact == "setup_anchor_safe" }, "Private dashboard update must not inherit old startup parent blocker")
        let assessment = FirmwareResearchCollector.assess(bundled, results: prerequisites, profile: "b31")
        try check(assessment.first(where: { $0.id == "full-restore" })?.state == "unknown", "Deliberately unassessed restoration readiness must stay unknown")
        try check(assessment.first(where: { $0.id == "physical-euicc" })?.state == "unknown" && assessment.first(where: { $0.id == "native-esim" })?.state == "unknown", "Metadata cannot prove physical or native card management")
        let esimProbe = bundled.probes.first(where: { $0.id == "esim-components" })!
        try check(esimProbe.command.contains("ubus -t 5 -v list zwrt_zte_mdm.api") && !esimProbe.command.contains("ubus call") && !esimProbe.command.contains("uci ") && !esimProbe.command.contains("lpac "), "Research must not invoke card or slot operations")
        try check(bundled.features.flatMap(\.requirements).contains { $0.platforms == ["macos"] }, "Platform-specific prerequisites decoded")
        let tampered = assets.appendingPathComponent("FirmwareResearch"); try secureDirectory(tampered)
        var bytes = try Data(contentsOf: bundledResources.appendingPathComponent("FirmwareResearch/probes.json")); bytes.append(32)
        try savePrivate(bytes, tampered.appendingPathComponent("probes.json"))
        try check((try? ResearchSpecification.load(assets)) == nil, "Modified command allowlist must fail its compiled SHA pin")
        print("FirmwareResearchTests PASS: unknown/nonroot firmware, transport policy, trust, device binding, cancellation, offline report, redaction, ZIP, bounded process capture")
    }
}
