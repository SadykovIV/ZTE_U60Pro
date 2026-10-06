import Foundation
import Darwin

private enum TestFailure: Error { case check(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure.check(message) }
}
private func rejects(_ contains: String? = nil, _ body: () throws -> Void) throws {
    do { try body() }
    catch let failure as TestFailure { throw failure }
    catch {
        if let contains { try check(error.localizedDescription.contains(contains), "Unexpected failure: \(error.localizedDescription)") }
        return
    }
    throw TestFailure.check("Operation unexpectedly succeeded")
}
private func rejectsWeb(_ expected: ModemWebError, _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as ModemWebError { try check(error == expected, "Unexpected Web error: \(error)"); return }
    throw TestFailure.check("Expected typed Web error: \(expected)")
}

private let testIMEI = "353490068701222"
private let testCID = "0123456789abcdef0123456789abcdef"
private let testPassword = "test-password"
private let expectedPasswordHash = "C2682E16F0B2C76CE55C4998EA7914050AF4CFAF82510D405CEB2AF9B74B4FB5"
private let sessionID = "1234567890abcdef1234567890abcdef"

private func deviceObject(_ imei: String = testIMEI) -> [String:Any] {
    ["imei": imei, "integrate_version":"CN_ZTE_MU5250V1.0.0B31", "wa_inner_version":"BD_CNMU5250V1.0.0B31"]
}
private func tar(_ files: [(String, Data)]) -> Data {
    var output = Data()
    for (name, bytes) in files {
        var header = Data(repeating: 0, count: 512)
        func put(_ offset: Int, _ text: String) { header.replaceSubrange(offset..<offset+text.utf8.count, with: text.utf8) }
        put(0,name); put(100,"0000775\0"); put(108,"0000000\0"); put(116,"0000000\0")
        put(124,String(format:"%011o",bytes.count)+"\0"); put(136,"15100000000\0"); put(148,"        ")
        header[156]=48; put(257,"ustar\0"); put(263,"00")
        put(148,String(format:"%06o",header.reduce(0) {$0+Int($1)})+"\0 ")
        output += header; output += bytes; output += Data(repeating:0,count:(512-bytes.count%512)%512)
    }
    return output + Data(repeating:0,count:1024)
}
private let testBackupSuffix = "synthetic-public-fixture-key"
private func backup(suffix: String = testBackupSuffix, rc: Data? = nil) throws -> Data {
    let inner = try BackupGzip.compress(tar([("etc/rc.local",try rc ?? Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/stock-usb-mode.synthetic.rc.local")))]))
    let outer = try BackupGzip.compress(tar([(BackupPatch.innerPath,inner),(BackupPatch.md5Path,Data((BackupCipher.md5(inner)+"\n").utf8))]))
    return try BackupCipher.encrypt(outer,password:testIMEI+suffix)
}

/// Entire web API is in memory. Unknown calls fail; no URLSession is created.
private final class MockWeb: WebTransport {
    struct Request { let path: String; let data: Data?; let cookie: String? }
    var requests = [Request](), methods = [String](), loginArguments = [String:Any]()
    var accepted = true, cookieHeader = "webtoken=\"test-cookie\"; Path=/", session = sessionID
    var info = deviceObject(), identityChangeAfter: Int?, identityCalls = 0
    var backupData: Data
    var uploadedData: Data?, badUploadHash = false
    var restoreCount = 0, backupCount = 0, rebootCount = 0, outerError: Int?, challenge = "salt-0123"
    var loginResult: Any?, rawReply: Data?, transportFailure: Error?
    var directAdvertised = false, directCount = 0, directCode = 0
    var listUnavailable = false
    var directFailure: Error?, onDirect: (() -> Void)?
    var rebootFailure: Error?, onReboot: (() -> Void)?
    init(_ data: Data) { backupData = data }
    func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply {
        requests.append(Request(path:path,data:data,cookie:cookie))
        if let transportFailure { throw transportFailure }
        if let rawReply { return WebReply(data: rawReply, headers: [:]) }
        if path == "/backup/back_parameter" { return WebReply(data:backupData,headers:[:]) }
        if path == "/cgi-bin/cgi-upload" {
            guard let data, let type = contentType, let boundary = type.components(separatedBy:"boundary=").last,
                  let start = data.range(of:Data("Content-Type: application/octet-stream\r\n\r\n".utf8)),
                  let end = data.range(of:Data(("\r\n--"+boundary+"--\r\n").utf8),options:.backwards), start.upperBound <= end.lowerBound else {
                throw TestFailure.check("Unexpected multipart upload")
            }
            let bytes = Data(data[start.upperBound..<end.lowerBound]); uploadedData = bytes
            return WebReply(data:try JSONSerialization.data(withJSONObject:["sha256sum":badUploadHash ? String(repeating:"0",count:64) : digest(bytes)]),headers:[:])
        }
        try check(path == "/ubus/" && contentType == "application/json", "Unknown web request")
        let payload = try JSONSerialization.jsonObject(with:data!) as! [[String:Any]]
        try check(payload.count == 1, "Batch size")
        if payload[0]["method"] as? String == "list" {
            try check(payload[0]["params"] as? [String] == ["zwrt_bsp.usb"] && cookie == "test-cookie", "USB capability query must be authenticated and use object-only params")
            methods.append("list:zwrt_bsp.usb")
            if listUnavailable { throw ModemWebError.rpcRejected(method: "list", code: 6) }
            let result: [String: Any] = directAdvertised ? ["zwrt_bsp.usb": ["set": ["mode": "String"]]] : [:]
            return WebReply(data: try JSONSerialization.data(withJSONObject: [["jsonrpc": "2.0", "id": 1, "result": result]]), headers: [:])
        }
        let params = payload[0]["params"] as! [Any], method = params[2] as! String
        methods.append(method)
        var result = [String:Any](), headers = [String:String]()
        switch method {
        case "web_login_info":
            try check(params[0] as? String == String(repeating:"0",count:32) && cookie == nil, "Challenge starts without credentials")
            result = ["zte_web_sault":challenge]
        case "web_login":
            loginArguments = params[3] as! [String:Any]
            result = ["result":loginResult ?? (accepted ? 0 : 1),"ubus_rpc_session":session]
            headers["set-cookie"] = cookieHeader
        case "device_info":
            try check(params[0] as? String == sessionID && cookie == "test-cookie", "Authenticated identity")
            identityCalls += 1; result = info
            if let n = identityChangeAfter, identityCalls >= n { result["imei"] = "353490068701230" }
        case "device_backup_proc": backupCount += 1
        case "device_restore_proc": restoreCount += 1
        case "device_reboot":
            try check(params[1] as? String == "zwrt_mc.device.manager" && params[3] as? [String: String] == ["moduleName": "web"], "Only stock Web reboot is allowed")
            rebootCount += 1; onReboot?()
            if let rebootFailure { throw rebootFailure }

        case "set":
            try check(params[1] as? String == "zwrt_bsp.usb" && params[3] as? [String: String] == ["mode": "debug"], "Only documented direct USB operation is allowed")
            directCount += 1; onDirect?()
            if let directFailure { throw directFailure }
            result = ["status": directCode]
        default: throw TestFailure.check("Unexpected RPC: \(method)")
        }
        return WebReply(data:try JSONSerialization.data(withJSONObject:[["jsonrpc":"2.0","id":1,"result":[outerError ?? 0,result]]]),headers:headers)
    }
}

/// Never invokes Process. The marker is taken from the actual generated wrapper.
private final class MockResearch: ResearchProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation, input: ADBStreamInput?) throws -> ResearchCommandResult {
        guard let input else { return try run(executable, arguments: arguments, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation) }
        var args = arguments; args[3] = "(" + input.auditOriginal + "); zte_code=$?; printf '\n" + input.result + "%s\n' \"$zte_code\""
        var value = try run(executable, arguments: args, timeout: timeout, maxBytes: maxBytes, cancellation: cancellation)
        value.stdout = Data((input.begin + "\n").utf8) + value.stdout
        return value
    }
    var calls = 0
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, cancellation: ResearchCancellation) throws -> ResearchCommandResult {
        calls += 1
        if arguments == ["-d", "get-serialno"] { return .init(status: 0, stdout: Data("ABC\n".utf8), stderr: Data(), outcome: "success", duration: 0) }
        if arguments == ["version"] { return .init(status: 0, stdout: Data("fixture".utf8), stderr: Data(), outcome: "success", duration: 0) }
        if arguments == ["devices", "-l"] { return .init(status: 0, stdout: Data("List of devices attached\nABC device usb:1\n".utf8), stderr: Data(), outcome: "success", duration: 0) }
        try check(executable.lastPathComponent == "adb" && arguments.count == 4, "Research fixture attempted network")
        let command = arguments[3], marker = ADBClient.shellMarker(in: command)!
        let output = command.contains(FirmwareResearchCollector.bootstrap) ? "uid=0\narchitecture=aarch64\ncid=" + digest(Data((testCID + "\n").utf8)) + "\nboot=" + digest(Data("fixture-boot\n".utf8)) : "FR_FACT observed=not-assessed"
        return .init(status: 0, stdout: Data((output + "\n" + marker + "0\n").utf8), stderr: Data(), outcome: "success", duration: 0)
    }
}
private final class MockHost: HostCommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: ADBStreamInput?) throws -> CommandResult {
        guard let input else { return try run(executable, arguments, timeout: timeout) }
        var args = arguments; args[3] = "(" + input.auditOriginal + "); zte_code=$?; printf '\n" + input.result + "%s\n' \"$zte_code\""
        let value = try run(executable, args, timeout: timeout)
        return .init(status: value.status, stdout: Data((input.begin + "\n").utf8) + value.stdout, stderr: value.stderr)
    }
    var calls = [[String]]()
    var status: Int32 = 0, shellCode = "0", includeMarker = true, shellText = "synthetic output"
    var shellLineEnding: String?
    var deviceList = "List of devices attached\n", identityCID = testCID, identityIMEI = testIMEI
    var deviceListSequence = [String](), identityCIDSequence = [String]()
    var identityHashesValid = true, identityMode = false
    var identityFirmware = ModemEngine.firmwareHash, identityRouter = ModemEngine.routerHash, identityInfo = deviceObject()
    var fullInstaller = false, installed = false, loseInstallAcknowledgement = false
    var failPushAt: Int?, pushCount = 0, preflightError = false
    var installerCalls = 0, stage = "", remoteJournal = "", uploads = [String:Data]()
    var onInstall: (() -> Void)?
    var rollbackVerified = false, rollbackReply: String?, remoteState: String?
    var lastDeviceList = "", usbSerialOverride: String?
    private func quoted(_ text: String) throws -> [String] {
        let text = text.components(separatedBy: "); zte_code=").first ?? text
        let expression=try NSRegularExpression(pattern:"'([^']*)'")
        return expression.matches(in:text,range:NSRange(text.startIndex...,in:text)).map {String(text[Range($0.range(at:1),in:text)!])}
    }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments)
        if executable.lastPathComponent == "ssh-keygen" {
            if arguments.first == "-q", let index=arguments.firstIndex(of:"-f") {
                try savePrivate(Data("synthetic-private-key".utf8),URL(fileURLWithPath:arguments[index+1]))
                return CommandResult(status:0,stdout:Data(),stderr:Data())
            }
            if arguments.first == "-y" { return CommandResult(status:0,stdout:Data("ssh-ed25519 SYNTHETIC test\n".utf8),stderr:Data()) }
            throw TestFailure.check("Unexpected ssh-keygen command")
        }
        try check(executable.lastPathComponent == "adb", "Unexpected host executable: \(executable.lastPathComponent)")
        var value: String
        if arguments == ["devices","-l"] { value = deviceListSequence.isEmpty ? deviceList : deviceListSequence.removeFirst(); lastDeviceList = value }
        else if arguments == ["-d", "get-serialno"] {
            let records = try ADBDiscovery.parse(Data(lastDeviceList.utf8)).records.filter { $0.state == "device" }
            if let usbSerialOverride { value = usbSerialOverride }
            else if records.count == 1 { value = records[0].serial }
            else { return CommandResult(status: 1, stdout: Data(), stderr: Data("error: more than one device/emulator".utf8)) }
        }
        else if fullInstaller && arguments.count == 5 && arguments[2] == "push" {
            pushCount += 1
            if pushCount == failPushAt { throw IMEIError.message("synthetic interrupted upload") }
            let path=arguments[4];try check(path.hasPrefix(stage+"/"),"Upload only owned stage")
            uploads[path]=try Data(contentsOf:URL(fileURLWithPath:arguments[3]));value="1 file pushed"
        }
        else if arguments.count == 4 && arguments[2] == "shell" {
            let command = arguments[3]
            let regex = try NSRegularExpression(pattern:"__ZTE_RESULT_[A-F0-9]+__")
            guard let match = regex.firstMatch(in:command,range:NSRange(command.startIndex...,in:command)), let range = Range(match.range,in:command) else { throw TestFailure.check("Missing shell exit wrapper") }
            value = shellText
            if identityMode && (command.contains("sha256sum /firmware/image/modem.b16") || command.contains(AccessIdentity.command)) {
                var object = identityInfo; object["imei"] = identityIMEI
                let info = String(data:try JSONSerialization.data(withJSONObject:object,options:.sortedKeys),encoding:.utf8)!
                let cid = identityCIDSequence.isEmpty ? identityCID : identityCIDSequence.removeFirst()
                value = (identityHashesValid ? identityFirmware : String(repeating:"0",count:64)) + "  /firmware/image/modem.b16\n" + identityRouter + "  /usr/bin/diag-router\n" + cid + "\n" + (command.contains(AccessIdentity.command) ? "01234567-89ab-4cde-8f01-23456789abcd\n" : "") + (command.contains("ubus call") ? info : "")
            } else if command.hasPrefix("(sh -c ") && command.contains("'--verify-rollback'") {
                value = rollbackReply ?? (rollbackVerified ? "INSTALL_ROLLBACK_VERIFIED " + remoteJournal : "INSTALL_ERROR ROLLBACK_UNVERIFIED")
                shellCode = rollbackVerified ? "0" : "1"
            } else if command.hasPrefix("(sh -c ") && command.contains("'--preflight'") {
                value = preflightError ? "INSTALL_ERROR PREFLIGHT_TOOL" : "INSTALL_PREFLIGHT " + (command.contains("'linux-arm64-access'") ? "linux-arm64-access" : command.contains("'b02-experimental'") ? "b02-experimental" : "b31") + " imei_config=unknown"
                if preflightError { shellCode = "1" }
            } else if fullInstaller {
                if command.contains("printf 'INSTALL_STAGE_READY") {
                    stage=try quoted(command)[0];try check(stage.hasPrefix("/data/zte-imei-studio/stage-"),"Owned staging path");value="INSTALL_STAGE_READY"
                } else if command.hasPrefix("(set -eu; test -d ") {
                    let paths = try quoted(command), source = paths[paths.count - 2], destination = paths.last!
                    try check(source.hasPrefix(stage + "/incoming-") && destination.hasPrefix(stage + "/"), "Atomic stage promotion")
                    guard let data = uploads.removeValue(forKey: source) else { throw TestFailure.check("Promotion without staged incoming file") }
                    uploads[destination] = data; value = ""
                } else if command.hasPrefix("(set -eu; umask 077; set -C; printf ") { value = ""
                } else if command.hasPrefix("(set -e; chmod 600 ") {
                    let path=try quoted(command)[0];guard let data=uploads[path] else {throw TestFailure.check("Hash check without upload")}
                    value=digest(data)+"  "+path
                } else if command.hasPrefix("(sh '") && command.contains("/setup-agent.sh'") {
                    var args=try quoted(command)
                    if args.count > 1 && args[1] == "--reinstall" { args.remove(at: 1) }
                    try check(args.count >= 6 && args[0] == stage+"/setup-agent.sh" && args[1] == stage && args[2] == testCID,"Exact installer invocation and CID")
                    for name in ["zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh","id_ed25519.pub","start-agent.sh"] {try check(uploads[stage+"/"+name] != nil,"Missing staged asset")}
                    try check(args[3] == digest(uploads[stage+"/zte-agent"]!) && args[4] == digest(uploads[stage+"/dropbear"]!) && args[5] == digest(uploads[stage+"/id_ed25519.pub"]!),"Installer hashes")
                    try check([9, 10].contains(args.count) && args[7] == identityFirmware && args[8] == identityRouter, "Bound installer policy hashes")
                    try check(!command.contains(testPassword),"Password absent from installer argv")
                    installerCalls += 1;installed=true;remoteJournal="/data/zte-imei-studio/installations/"+String(stage.split(separator:"/").last!.dropFirst("stage-".count));onInstall?()
                    value="INSTALL_AGENT new\nINSTALL_READY "+remoteJournal
                    if loseInstallAcknowledgement {value="INSTALL_INCOMPLETE "+remoteJournal;shellCode="1";loseInstallAcknowledgement=false}
                } else if (command.hasPrefix("('/data/zte-imei-studio/bin/dropbearkey' -y ") || command.hasPrefix("('/data/bin/dropbearkey' -y ")) {
                    let key=Data([0,0,0,11])+Data("ssh-ed25519".utf8)+Data([0,0,0,32])+Data(repeating:0x33,count:32)
                    value="Public key portion is:\nssh-ed25519 "+key.base64EncodedString()+" synthetic"
                } else if command.hasPrefix("(cat '") && command.contains("/state'") {value=remoteState ?? (installed ? "ready" : "pending")}
                else if command.hasPrefix("(rm -f ") {value=""}
                else {throw TestFailure.check("Unexpected full installer shell: "+command)}
            }
            if includeMarker { value += "\r\n" + command[range] + shellCode + "\r\n" }
            if let shellLineEnding { value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: shellLineEnding) }
        } else { throw TestFailure.check("Unexpected host command: \(arguments)") }
        return CommandResult(status:status,stdout:Data(value.utf8),stderr:Data())
    }
}

private final class UnavailableSSH: RemoteTransport {
    var calls = [String]()
    var ready=false, probesAvailable=true, authenticationAccepted=true, authenticationCalls=0, commitCalls=0
    var cleanupComplete=false, cleanupActions=[String](), cleanupReply: String?
    var installedJournal="",uploads=[String:Data](),malformedSnapshot=false
    var firmware = ModemEngine.firmwareHash, info = deviceObject()
    var identityReads = 0, changeBootAfterAuthentication = false
    var accessProofReads = 0, changeAccessBoot = false, accessCID = testCID, accessRouter = ModemEngine.routerHash
    var accessFailure: CommandResult?
    var expectedAgentPassword = testPassword
    var agentDiskHash = digest(Data("SYNTHETIC-zte-agent".utf8)), agentMappedHash: String?
    var processProofCalls = 0, changeProcessAfterAuth = false, agentProcessValid = true
    private func output(_ value: String, status: Int32 = 0) -> CommandResult {CommandResult(status:status,stdout:Data(value.utf8),stderr:Data())}
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        if let accessFailure, command.hasPrefix(AccessIdentity.command) || command == SSHReadProof.command { return accessFailure }
        if !ready {throw IMEIError.message("Synthetic SSH unavailable")}
        if input == Data("SYNTHETIC-clean-components.sh".utf8) || command.contains("SYNTHETIC-clean-components.sh") {
            let action = ["status", "prepare", "clean"].first { command.contains(" -- '" + $0 + "' ") } ?? "unexpected"
            cleanupActions.append(action)
            if let cleanupReply { return output(cleanupReply + "\n") }
            if cleanupComplete { return output("CLEAN_COMPLETE\n") }
            return CommandResult(status:1,stdout:Data(),stderr:Data("CLEAN_ERROR BUSY\n".utf8))
        }
        if command == SSHReadProof.command {
            accessProofReads += 1
            let boot = changeAccessBoot && accessProofReads > 1 ? "11234567-89ab-4cde-8f01-23456789abcd" : "01234567-89ab-4cde-8f01-23456789abcd"
            return output("ZTE_SSH_READ_V1\n0\nLinux\naarch64\n" + accessCID + "\n" + boot + "\n" + firmware + "\n" + accessRouter + "\n")
        }
        if command.hasPrefix(AccessIdentity.command) {
            accessProofReads += 1
            identityReads += 1
            let boot = ((changeAccessBoot && accessProofReads > 1) || (changeBootAfterAuthentication && authenticationCalls > 0)) ? "11234567-89ab-4cde-8f01-23456789abcd" : "01234567-89ab-4cde-8f01-23456789abcd"
            let web = String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self)
            return output(firmware + "  /firmware/image/modem.b16\n" + accessRouter + "  /usr/bin/diag-router\n" + accessCID + "\n" + boot + "\n" + (command.contains("ubus call") ? web + "\n" : ""))
        }
        if command.contains("printf ZTE_AGENT_PRESENT") {return probesAvailable ? output("ZTE_AGENT_PRESENT") : output("",status:1)}
        if command.hasPrefix("sha256sum /firmware/image/modem.b16 ") {
            identityReads += 1
            let boot = changeBootAfterAuthentication && authenticationCalls > 0 ? "11234567-89ab-4cde-8f01-23456789abcd" : "01234567-89ab-4cde-8f01-23456789abcd"
            return output(firmware+"  /firmware/image/modem.b16\n"+ModemEngine.routerHash+"  /usr/bin/diag-router\n"+testCID+"\n"+boot+"\n")
        }
        if command.contains("ubus call zwrt_web device_info") { return CommandResult(status: 0, stdout: try JSONSerialization.data(withJSONObject: info), stderr: Data()) }
        if command.contains("/tmp/zte-imei-app.lock") || command.hasPrefix("umask 077; mkdir '/tmp/zte-imei-") || command.hasPrefix("rm -f '/tmp/zte-imei-") {return output("")}
        if command.hasPrefix("umask 077; cat > '") {
            let path=String(command.dropFirst("umask 077; cat > '".count).prefix {$0 != "'"})
            guard let input else {throw TestFailure.check("Missing helper upload")};uploads[path]=input;return output(digest(input)+"  "+path+"\n")
        }
        if command.hasSuffix(" '--snapshot'") {
            let path=String(command.dropFirst().prefix {$0 != "'"})
            try check(uploads[path] == Data("SYNTHETIC-zte_nv".utf8),"Snapshot helper matches fixture")
            if malformedSnapshot {return output("APP_NV broken")}
            var first=Data(repeating:0xa5,count:128),second=Data(repeating:0x5a,count:128)
            first.replaceSubrange(0..<9,with:[0x08,0x3a,0x35,0x94,0x00,0x86,0x07,0x21,0x22])
            second.replaceSubrange(0..<9,with:[0x08,0x3a,0x35,0x94,0x00,0x86,0x07,0x21,0x03])
            return output("APP_NV index=0 data="+first.hex+"\nAPP_NV index=1 data="+second.hex+"\n")
        }
        if command.hasPrefix("ubus call zwrt_zte_mdm.api get_imei") {return output("{\"imei\":\""+(command.hasSuffix("get_imei2") ? "353490068701230" : testIMEI)+"\"}")}
        if command.contains("AGENT_ACCESS_READY") {
            processProofCalls += 1
            if !agentProcessValid { return output("", status: 72) }
            let pid = changeProcessAfterAuth && authenticationCalls > 0 ? "124" : "123"
            return output("AGENT_ACCESS_READY " + pid + " 5678 " + agentDiskHash + " " + (agentMappedHash ?? agentDiskHash) + "\n")
        }
        if command.contains("printf AGENT_READY") {return output("AGENT_READY")}
        if command.contains("/present/data_zte-agent") {return output("NEW")}
        if command.hasPrefix("/usr/bin/curl ") {
            let body=try JSONSerialization.jsonObject(with:input!) as! [String:Any]
            try check(body["password"] as? String == expectedAgentPassword && !command.contains(expectedAgentPassword),"Agent credentials passed only through stdin")
            authenticationCalls += 1
            return output(authenticationAccepted ? "{\"ok\":true,\"data\":{\"token\":\"synthetic-token\"}}" : "{\"ok\":false}")
        }
        if command.contains("'--commit'") {
            try check(!installedJournal.isEmpty && command.contains("'"+installedJournal+"'") && command.contains("'"+testCID+"'"),"Commit journal and CID")
            commitCalls += 1;return output("INSTALL_COMMITTED "+installedJournal+"\n")
        }
        throw TestFailure.check("Unexpected SSH mock command: "+command)
    }
}

private struct Fixture {
    let base: URL, root: URL, resources: URL, web: MockWeb, host: MockHost, ssh: UnavailableSSH, engine: OnboardingEngine
    init(data: Data? = nil) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("zte-onboarding-tests-"+UUID().uuidString)
        root = base.appendingPathComponent("state"); resources = base.appendingPathComponent("resources")
        let assets = resources.appendingPathComponent("Onboarding"); try secureDirectory(assets)
        var hashes = [String:String]()
        for name in ["adb","zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh","clean-components.sh"] {
            let content = Data(("SYNTHETIC-"+name).utf8); try savePrivate(content,assets.appendingPathComponent(name)); hashes[name]=digest(content)
        }
        let stream = try Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Onboarding/adb-stream.sh"))
        try savePrivate(stream, assets.appendingPathComponent("adb-stream.sh")); hashes["adb-stream.sh"] = digest(stream)
        try saveJSON(hashes,assets.appendingPathComponent("SHA256.json"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/FirmwareResearch"), to: resources.appendingPathComponent("FirmwareResearch"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/HostTools"), to: resources.appendingPathComponent("HostTools"))
        let helper=Data("SYNTHETIC-zte_nv".utf8);try savePrivate(helper,resources.appendingPathComponent("zte_nv"));try saveJSON(["zte_nv":digest(helper)],resources.appendingPathComponent("helpers.json"))
        web = MockWeb(try data ?? backup()); host = MockHost(); ssh = UnavailableSSH()
        let connection = Connection(host:"192.0.2.1",port:"2222",keyPath:root.appendingPathComponent("absent-key").path,knownHostsPath:root.appendingPathComponent("absent-hosts").path)
        let client = try ModemWebClient(host:connection.host,transport:web)
        let injectedSSH = ssh
        engine = try OnboardingEngine(root:root,resources:resources,connection:connection,backupSuffix:testBackupSuffix,web:client,runner:host,sshFactory:{_ in injectedSSH}, adbWaitAttempts: 2, directADBWaitAttempts: 1, adbPollDelay: 0, researchRunner: MockResearch())
    }
    func remove() { try? FileManager.default.removeItem(at:base) }
}

@main struct OnboardingTests {
    static func main() throws {
        var passed = 0, failed = 0
        var results=[[String:String]]()
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)");results.append(["name":name,"result":"PASS"]) }
            catch { failed += 1; print("FAIL \(name): \(error)");results.append(["name":name,"result":"FAIL","error":String(describing:error)]) }
        }
        run("Diagnostic ADB activates despite existing SSH and never installs components") {
            let f = try Fixture(); defer { f.remove() }
            f.ssh.ready = true; f.host.identityMode = true; f.web.directAdvertised = true
            f.web.onDirect = { f.host.deviceList = "List of devices attached\nABC device usb:1\n" }
            let result = try f.engine.enableDiagnosticADB(webPassword: testPassword)
            try check(result.identity.cid == testCID && f.web.directCount == 1 && f.web.restoreCount == 0, "Diagnostic enable was skipped or restored unnecessarily")
            try check(f.ssh.calls.isEmpty && f.host.pushCount == 0 && f.host.installerCalls == 0 && !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("SSH").path), "Diagnostic enable touched SSH or installer")
            try check(!FileManager.default.fileExists(atPath: f.engine.pending.path) && !FileManager.default.fileExists(atPath: f.engine.diagnosticPending.path), "Diagnostic completion left or used setup journal")
        }
        run("Already working diagnostic ADB accepts unknown hashes and needs only adb asset") {
            let f = try Fixture(data: Data("invalid archive".utf8)); defer { f.remove() }
            f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            f.host.identityFirmware = String(repeating: "b", count: 64); f.host.identityRouter = String(repeating: "c", count: 64)
            for name in ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] { try FileManager.default.removeItem(at: f.engine.assets.appendingPathComponent(name)) }
            let result = try f.engine.enableDiagnosticADB(webPassword: testPassword)
            try check(result.identity.firmwareHash == f.host.identityFirmware && result.routerHash == f.host.identityRouter, "Diagnostic proof was incorrectly gated on installer profile")
            try check(f.web.backupCount == 0 && f.web.directCount == 0 && f.web.restoreCount == 0 && f.ssh.calls.isEmpty, "Working ADB triggered mutation or SSH shortcut")
        }
        run("Diagnostic restore pending resumes without Web and never repeats restore") {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true
            try rejects("не подтверждён") { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword, expectedIdentity: Identity(cid: testCID, firmwareHash: ModemEngine.firmwareHash), expectedIMEI: testIMEI) }
            let saved = try readJSON(SetupJournal.self, f.engine.diagnosticPending)
            try check(saved.cid == testCID && saved.restoreRequested && !saved.installRequested && saved.intent == "diagnostic-adb" && f.web.restoreCount == 1, "Diagnostic restore intent was not durable")
            let calls = f.web.requests.count; f.web.transportFailure = IMEIError.message("Web unavailable during reboot")
            try rejects("не подтверждён") { _ = try f.engine.enableDiagnosticADB(webPassword: "") }
            try check(f.web.requests.count == calls && f.web.restoreCount == 1, "Pending restore was repeated or required Web")
            f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            _ = try f.engine.enableDiagnosticADB(webPassword: "")
            try check(f.web.requests.count == calls && f.web.restoreCount == 1 && f.ssh.calls.isEmpty && !FileManager.default.fileExists(atPath: f.engine.diagnosticPending.path), "Read-only resume did not complete")
        }
        run("Diagnostic direct request is not replayed after uncertain outcome") {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true; f.web.directAdvertised = true
            f.web.directFailure = IMEIError.message("reply lost")
            f.web.onDirect = { f.web.transportFailure = IMEIError.message("Web dropped") }
            try rejects { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword) }
            let saved = try readJSON(SetupJournal.self, f.engine.diagnosticPending)
            try check(saved.directADBRequested == true && saved.directADBOutcome == "uncertain" && f.web.directCount == 1 && f.web.restoreCount == 0, "Uncertain direct result was lost")
            let webRequests = f.web.requests.count
            f.host.deviceListSequence = ["List of devices attached\n", "List of devices attached\nABC device usb:1\n"]
            _ = try f.engine.enableDiagnosticADB(webPassword: "")
            try check(f.web.requests.count == webRequests && f.web.directCount == 1 && f.web.restoreCount == 0 && f.ssh.calls.isEmpty, "Direct resume required Web or repeated the command")
        }
        run("Diagnostic ADB rejects setup recovery before any transport") {
            let f = try Fixture(); defer { f.remove() }
            try savePrivate(Data("{}".utf8), f.engine.pending)
            try rejects("предварительную подготовку") { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword) }
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.calls.isEmpty, "Competing setup touched a transport")
        }
        run("Setup rejects diagnostic recovery before any transport") {
            let f = try Fixture(); defer { f.remove() }
            try savePrivate(Data("{}".utf8), f.engine.diagnosticPending)
            try rejects("включение ADB") { _ = try f.engine.run(password: testPassword) }
            try rejects("включение ADB") { _ = try f.engine.prepareSSH() }
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.calls.isEmpty, "Setup bypassed diagnostic pending guard")
        }
        run("Diagnostic journal intent and identity are bound on resume") {
            let f = try Fixture(); defer { f.remove() }
            let directory = f.root.appendingPathComponent("ADBAccessBackups/" + UUID().uuidString); try secureDirectory(directory)
            let web = try WebIdentity(deviceObject())
            var journal = SetupJournal(id: UUID().uuidString, identity: web, phase: "restore-requested", directory: directory.path, restoreRequested: true, intent: "setup")
            try saveJSON(journal, f.engine.diagnosticPending)
            try rejects("Некорректный журнал") { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword) }
            journal.intent = "diagnostic-adb"; try saveJSON(journal, f.engine.diagnosticPending)
            try rejects { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword, expectedIMEI: "353490068701230") }
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.calls.isEmpty, "Invalid or mismatched recovery touched a transport")
        }
        run("Diagnostic already-enabled B31 reboots once and resumes a lost acknowledgement without Web") {
            let prepared = try BackupPatch.prepare(encrypted: backup(), imei: testIMEI, suffix: testBackupSuffix)
            let f = try Fixture(data: prepared.patchedEncrypted); defer { f.remove() }
            f.host.identityMode = true; f.web.rebootFailure = IMEIError.message("reboot reply lost")
            try rejects("не подтверждён") { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword) }
            let saved = try readJSON(SetupJournal.self, f.engine.diagnosticPending)
            try check(saved.diagnosticRebootRequested == true && !saved.restoreRequested && !saved.installRequested && f.web.rebootCount == 1 && f.web.uploadedData == nil, "Existing config was restored or reboot intent not saved")
            let calls = f.web.requests.count; f.web.transportFailure = IMEIError.message("Web down")
            try rejects("не подтверждён") { _ = try f.engine.enableDiagnosticADB(webPassword: "") }
            try check(f.web.requests.count == calls && f.web.rebootCount == 1, "Reboot was repeated during resume")
            f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            _ = try f.engine.enableDiagnosticADB(webPassword: "")
            try check(f.web.requests.count == calls && f.web.restoreCount == 0 && f.web.rebootCount == 1 && f.ssh.calls.isEmpty && f.host.installerCalls == 0, "Diagnostic reboot crossed installation boundary")
        }
        run("Already working ADB never reboots even when B31 boot line is present") {
            let prepared = try BackupPatch.prepare(encrypted: backup(), imei: testIMEI, suffix: testBackupSuffix)
            let f = try Fixture(data: prepared.patchedEncrypted); defer { f.remove() }
            f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            _ = try f.engine.enableDiagnosticADB(webPassword: testPassword)
            try check(f.web.rebootCount == 0 && f.web.backupCount == 0 && f.web.restoreCount == 0 && f.web.directCount == 0, "Working root ADB rebooted")
        }
        run("Normal preparation never uses diagnostic already-enabled reboot") {
            let prepared = try BackupPatch.prepare(encrypted: backup(), imei: testIMEI, suffix: testBackupSuffix)
            let f = try Fixture(data: prepared.patchedEncrypted); defer { f.remove() }
            f.host.identityMode = true
            try rejects("не подтверждён") { _ = try f.engine.run(password: testPassword) }
            try check(f.web.rebootCount == 0 && f.web.restoreCount == 0, "Normal setup inherited diagnostic reboot")
        }
        run("Changed Web identity blocks diagnostic reboot before sending") {
            let prepared = try BackupPatch.prepare(encrypted: backup(), imei: testIMEI, suffix: testBackupSuffix)
            let f = try Fixture(data: prepared.patchedEncrypted); defer { f.remove() }
            f.host.identityMode = true; f.web.identityChangeAfter = 4
            try rejects("Устройство изменилось") { _ = try f.engine.enableDiagnosticADB(webPassword: testPassword) }
            try check(f.web.rebootCount == 0 && f.web.restoreCount == 0 && f.web.directCount == 0, "Changed device received reboot")
        }
        run("Public diagnostic ADB needs no backup key when USB already works or direct activation succeeds") {
            for alreadyReady in [true, false] {
                let f = try Fixture(); defer { f.remove() }
                f.host.identityMode = true; f.web.directAdvertised = true
                if alreadyReady { f.host.deviceList = "List of devices attached\nABC device usb:1\n" }
                f.web.onDirect = { f.host.deviceList = "List of devices attached\nABC device usb:1\n" }
                let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: f.engine.currentConnection, web: f.engine.web, runner: f.host, adbWaitAttempts: 1, directADBWaitAttempts: 1, adbPollDelay: 0, researchRunner: MockResearch())
                _ = try manager.enableDiagnosticADB(webPassword: testPassword)
                try check(f.web.directCount == (alreadyReady ? 0 : 1) && f.web.restoreCount == 0, "Absent key blocked a path that never decrypts backups")
            }
        }
        run("Known B31 automatic key validates an independent synthetic backup") {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/b31-auto-backup.synthetic.bin"))
            let f = try Fixture(data: bytes); defer { f.remove() }
            let manager = try OnboardingEngine(root:f.root, resources:f.resources, connection:f.engine.currentConnection, web:f.engine.web, runner:f.host)
            let (_, patch, _) = try manager.prepare(password:testPassword)
            try check(patch.originalHash == digest(bytes) && !patch.alreadyEnabled && patch.patchedHash != patch.originalHash, "Automatic key failed independent archive validation")
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0, "Offline preparation changed device")
        }
        run("Known B31 automatic key reaches exactly one diagnostic restore") {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/b31-auto-backup.synthetic.bin"))
            let f = try Fixture(data:bytes); defer { f.remove() }
            f.host.identityMode=true; f.host.deviceList="List of devices attached\nABC device usb:1\n"
            f.host.deviceListSequence=["List of devices attached\n",f.host.deviceList]
            let manager = try OnboardingEngine(root:f.root, resources:f.resources, connection:f.engine.currentConnection, web:f.engine.web, runner:f.host, adbWaitAttempts:1, directADBWaitAttempts:1, adbPollDelay:0, researchRunner:MockResearch())
            _ = try manager.enableDiagnosticADB(webPassword:testPassword)
            try check(f.web.uploadedData != nil && f.web.restoreCount==1 && f.web.rebootCount==0, "Automatic path did not preserve exactly-once restore")
        }
        run("Explicit wrong or malformed override never falls back to the known key") {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/b31-auto-backup.synthetic.bin"))
            for override in ["synthetic-wrong", "\0", String(repeating:"a",count:129)] {
                let f = try Fixture(data:bytes); defer { f.remove() }
                let manager=try OnboardingEngine(root:f.root,resources:f.resources,connection:f.engine.currentConnection,backupSuffix:override,web:f.engine.web,runner:f.host,adbWaitAttempts:1,directADBWaitAttempts:1,adbPollDelay:0,researchRunner:MockResearch())
                try rejects { _ = try manager.enableDiagnosticADB(webPassword:testPassword) }
                try check(f.web.uploadedData==nil && f.web.restoreCount==0 && f.web.rebootCount==0,"Invalid explicit key fell back or mutated")
            }
        }
        run("Automatic key validates format independently of firmware labels and refuses malformed backup") {
            for otherFirmware in [false,true] {
                let bytes = otherFirmware ? try Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/b31-auto-backup.synthetic.bin")) : Data("invalid encrypted fixture".utf8)
                let f=try Fixture(data:bytes);defer{f.remove()}
                var connection=f.engine.currentConnection;connection.skipFirmwareCheck=true
                if otherFirmware { f.web.info["integrate_version"]="CN_ZTE_MU5250V1.0.0B32";f.web.info["wa_inner_version"]="BD_CNMU5250V1.0.0B32" }
                let manager=try OnboardingEngine(root:f.root,resources:f.resources,connection:connection,web:f.engine.web,runner:f.host)
                if otherFirmware { _ = try manager.prepare(password:testPassword) } else { try rejects { _ = try manager.prepare(password:testPassword) } }
                try check(f.web.uploadedData==nil && f.web.restoreCount==0,"Invalid archive or profile mutated device")
            }
        }
        run("Read-only key check accepts matching archives on B31 FLY B28 and unknown firmware without resources") {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/b31-auto-backup.synthetic.bin"))
            for pair in [("CN_ZTE_MU5250V1.0.0B31","BD_CNMU5250V1.0.0B31"), ("FLY_CN_MU5250V1.0.0B13","BD_FLYMODEMMU5250V1.0.0B28"), ("fixture-unknown-outer","fixture-unknown-inner")] {
                let f = try Fixture(data:bytes); defer { f.remove() }
                f.web.info["integrate_version"] = pair.0; f.web.info["wa_inner_version"] = pair.1
                try FileManager.default.removeItem(at: f.resources)
                let engine = try OnboardingEngine(root:f.root, resources:f.resources, connection:f.engine.currentConnection, web:f.engine.web, runner:f.host)
                let result = try engine.verifyBackupKey(password:testPassword)
                try check(result.firmware == pair.0 && result.inner == pair.1 && result.entryCount == 1 && result.encryptedSHA256 == digest(bytes), "Read-only metadata mismatch")
                try check(try Data(contentsOf:result.directory.appendingPathComponent("back_parameter.original")) == bytes, "Original encrypted backup was not preserved")
                let names = try FileManager.default.contentsOfDirectory(atPath:result.directory.path).sorted()
                try check(names == ["back_parameter.original","identity.json","manifest.json","verification.json"], "Unexpected plaintext or patched artifact")
                let report = try String(contentsOf:result.directory.appendingPathComponent("verification.json"))
                let manifest = try readJSON([String:String].self,result.directory.appendingPathComponent("manifest.json"))
                try check(manifest["suffixVerified"] == "true" && manifest["formatVerified"] == "true" && manifest["operation"] == "read-only-key-check", "Verified read-only manifest is inconsistent")
                try check(!report.contains(testIMEI) && !report.contains(testPassword) && !report.contains("#!/bin/sh"), "Verification metadata contains private material")
                try check(f.host.calls.isEmpty && f.ssh.calls.isEmpty && f.web.identityCalls == 2 && f.web.backupCount == 1, "Read-only check invoked host helpers or skipped identity binding")
                try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.web.rebootCount == 0 && f.web.directCount == 0, "Read-only check authorized mutation")
                try check(!FileManager.default.fileExists(atPath:engine.pending.path) && !FileManager.default.fileExists(atPath:engine.diagnosticPending.path), "Read-only check created mutation intent")
                let allowed: Set<String> = ["web_login_info","web_login","device_info","device_backup_proc"]
                try check(Set(f.web.methods).isSubset(of:allowed), "Read-only check invoked an unapproved Web method")
            }
        }
        run("Read-only key check preserves manual precedence and rejects corrupt or unknown format with zero writes") {
            let known = try Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/b31-auto-backup.synthetic.bin"))
            var corrupt = known; corrupt[corrupt.count-1] ^= 1
            let wrongFormat = try BackupCipher.encrypt(Data("not a valid gzip archive".utf8),password:testIMEI+testBackupSuffix)
            for (bytes, suffix) in [(known,"wrong-synthetic"),(known,"\0"),(known,String(repeating:"x",count:129)),(corrupt,""),(wrongFormat,testBackupSuffix)] {
                let f = try Fixture(data:bytes);defer { f.remove() }
                let engine = try OnboardingEngine(root:f.root,resources:f.resources,connection:f.engine.currentConnection,backupSuffix:suffix,web:f.engine.web,runner:f.host)
                try rejects(suffix.contains("\0") || suffix.utf8.count > 128 ? "Некорректный Backup-key" : "Не удалось подтвердить ключ и формат") { _ = try engine.verifyBackupKey(password:testPassword) }
                try check(f.host.calls.isEmpty && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.web.rebootCount == 0 && f.web.directCount == 0, "Failed key check changed device")
            }
            let f = try Fixture();defer {f.remove()}
            f.web.info["integrate_version"] = "arbitrary-firmware";f.web.info["wa_inner_version"] = "arbitrary-inner"
            let result = try f.engine.verifyBackupKey(password:testPassword)
            try check(result.entryCount == 1 && f.web.uploadedData == nil && f.host.calls.isEmpty,"Valid manual override lost authority")
        }
        run("Read-only key check rejects changed identity without enabling access") {
            let f = try Fixture();defer {f.remove()};f.web.identityChangeAfter=2
            try rejects("Устройство изменилось") { _ = try f.engine.verifyBackupKey(password:testPassword) }
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.web.rebootCount == 0 && f.host.calls.isEmpty,"Changed identity changed access")
        }
        run("Read-only key validation never skips executable-template validation for restore") {
            let bytes = try backup(rc:Data("#!/bin/sh\n# /sys/class/android_usb/android0/usb_op\nexit 0\n".utf8))
            let f = try Fixture(data:bytes);defer {f.remove()}
            f.web.info["integrate_version"]="FLY_CN_MU5250V1.0.0B13";f.web.info["wa_inner_version"]="BD_FLYMODEMMU5250V1.0.0B28"
            _ = try f.engine.verifyBackupKey(password:testPassword)
            try rejects("штатный USB-блок") { _ = try f.engine.prepare(password:testPassword) }
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.web.rebootCount == 0,"Read verification granted write permission")
        }
        run("Existing SSH preparation needs no HTTP credentials backup agent or NV mutation") {
            let f = try Fixture(data: Data("invalid archive must not be read".utf8)); defer { f.remove() }
            f.web.accepted = false; f.ssh.ready = true; f.ssh.malformedSnapshot = true; f.ssh.authenticationAccepted = false
            let result = try f.engine.prepareSSH(expectedIdentity: Identity(cid: testCID, firmwareHash: ModemEngine.firmwareHash))
            try check(result?.identity?.cid == testCID && result?.state == nil && result?.suffix == "", "Access-only proof overstated NV or backup readiness")
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.accessProofReads == 2, "SSH preparation touched HTTP or host installer")
            try check(f.ssh.calls.allSatisfy { $0 == SSHReadProof.command }, "SSH probe performed an extra operation")
            try check(!FileManager.default.fileExists(atPath: f.engine.pending.path), "Read-only preparation created installation intent")
        }
        run("Unavailable SSH preparation returns nil without web login or ADB activation") {
            let f = try Fixture(); defer { f.remove() }
            try check(try f.engine.prepareSSH() == nil, "Unavailable SSH accepted")
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.calls.count == 2, "Probe bypassed SSH boundary")
        }
        run("SSH preparation host trust failures cannot fall through to another key or transport") {
            let f = try Fixture(); defer { f.remove() }
            f.ssh.accessFailure = CommandResult(status: 255, stdout: Data(), stderr: Data("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!".utf8))
            try rejects("Проверка ключа SSH") { _ = try f.engine.prepareSSH() }
            try check(f.ssh.calls.count == 1 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.web.requests.isEmpty, "Trust failure fell back")
        }
        run("SSH preparation refuses wrong CID and changed boot before writes") {
            for failure in 0..<2 {
                let f = try Fixture(); defer { f.remove() }; f.ssh.ready = true
                if failure == 0 { f.ssh.accessCID = String(repeating: "b", count: 32) }
                if failure == 1 { f.ssh.changeAccessBoot = true }
                if failure == 2 { f.ssh.accessRouter = String(repeating: "0", count: 64) }
                try rejects { _ = try f.engine.prepareSSH(expectedIdentity: Identity(cid: testCID, firmwareHash: ModemEngine.firmwareHash)) }
                try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.uploads.isEmpty && f.ssh.authenticationCalls == 0, "Invalid identity reached mutation/authentication")
            }
        }
        run("SSH preparation observes B02 and unknown firmware without NV or an override") {
            let f = try Fixture(); defer { f.remove() }; f.ssh.ready = true
            f.ssh.info["integrate_version"] = "STD_PL_MU5250V1.0.0B02"; f.ssh.info["wa_inner_version"] = "BD_STDPLMU5250V1.0.0B02"
            f.ssh.firmware = OnboardingEngine.b02FirmwareHash
            try check(try f.engine.prepareSSH()?.identity?.firmwareHash == OnboardingEngine.b02FirmwareHash, "Access-only B02 identity incorrectly needs override")
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: connection, backupSuffix: testBackupSuffix, web: f.engine.web, runner: f.host, sshFactory: { _ in f.ssh }, researchRunner: MockResearch())
            try check(try manager.prepareSSH()?.identity?.firmwareHash == OnboardingEngine.b02FirmwareHash, "Known B02 SSH not recognized")
            f.ssh.firmware = String(repeating: "0", count: 64)
            try check(try manager.prepareSSH()?.identity?.firmwareHash == f.ssh.firmware, "Unknown firmware should allow measured access")
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.authenticationCalls == 0 && f.ssh.uploads.isEmpty, "B02 access probe inferred agent/NV readiness")
        }
        run("SSH preparation preserves pending setup and requires explicit continuation") {
            let f = try Fixture(); defer { f.remove() }; f.ssh.ready = true
            let saved = Data("saved installation intent".utf8); try savePrivate(saved, f.engine.pending)
            try rejects("незавершённую настройку") { _ = try f.engine.prepareSSH() }
            try check(try Data(contentsOf: f.engine.pending) == saved, "Pending install was changed by access probe")
            try check(f.ssh.calls.isEmpty && f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] }, "Pending guard did not stop early")
        }
        run("Explicit installation keeps web and agent passwords separate") {
            let f = try Fixture(); defer { f.remove() }
            let agentPassword = "separate-agent-password'123"
            f.host.fullInstaller = true; f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device\n"
            f.ssh.expectedAgentPassword = agentPassword
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            _ = try f.engine.run(webPassword: testPassword, agentPassword: agentPassword)
            try check(f.web.loginArguments["password"] as? String == expectedPasswordHash && f.ssh.authenticationCalls == 1, "Credentials were mixed between services")
            let startup = String(decoding: f.host.uploads[f.host.stage + "/start-agent.sh"]!, as: UTF8.self)
            try check(startup.contains(shellQuote(agentPassword)) && !startup.contains(testPassword), "Startup contains web credentials")
            try check(!f.host.calls.flatMap { $0 }.contains { $0.contains(agentPassword) } && !f.ssh.calls.contains { $0.contains(agentPassword) }, "Agent password leaked into command arguments")
            try check(f.web.backupCount == 0 && f.host.installerCalls == 1 && f.ssh.commitCalls == 1, "Separate credentials skipped installation safeguards")
        }
        run("Missing separate agent password stops before web login or installation") {
            let f = try Fixture(); defer { f.remove() }
            try rejects("пароль агента") { _ = try f.engine.run(webPassword: testPassword, agentPassword: "") }
            try check(f.web.requests.isEmpty && f.ssh.calls.allSatisfy { $0 == SSHReadProof.command } && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] }, "Empty agent credential triggered setup")
        }
        run("SSH preparation preserves a known API IMEI without requiring a CID") {
            let f = try Fixture(); defer { f.remove() }; f.ssh.ready = true
            try check(try f.engine.prepareSSH(expectedIMEI: testIMEI)?.identity?.cid == testCID, "Matching API IMEI rejected")
            _ = try f.engine.prepareSSH(expectedIMEI: "353490068701230")
            try check(!f.ssh.calls.contains { $0.contains("ubus") }, "Ordinary SSH reuse called vendor identity RPC")
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.uploads.isEmpty, "IMEI continuity probe mutated device")
        }
        run("Preparation refuses another web IMEI before fresh backup or device writes") {
            let f = try Fixture(); defer { f.remove() }
            try rejects("другому модему") { _ = try f.engine.run(webPassword: testPassword, agentPassword: testPassword, expectedIMEI: "353490068701230") }
            try check(f.web.backupCount == 0 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.calls.allSatisfy { $0 == SSHReadProof.command }, "Different web target reached preparation")
        }
        run("Known CID mismatch blocks existing ADB and SSH before helper or stage writes") {
            for viaSSH in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                if viaSSH { f.ssh.ready = true; f.ssh.accessCID = String(repeating: "b", count: 32) }
                else { f.host.identityMode = true; f.host.identityCID = String(repeating: "b", count: 32); f.host.deviceList = "List of devices attached\nABC device\n" }
                try rejects { _ = try f.engine.run(webPassword: testPassword, agentPassword: testPassword, expectedIdentity: Identity(cid: testCID, firmwareHash: ModemEngine.firmwareHash), expectedIMEI: testIMEI) }
                try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.ssh.uploads.isEmpty && !f.host.calls.contains { $0.contains("push") || $0.joined().contains("mkdir") }, "CID mismatch reached mutation")
            }
        }
        run("Known CID without an IMEI mapping cannot enable ADB through another web endpoint") {
            let f = try Fixture(); defer { f.remove() }
            try rejects("не сообщает CID") { _ = try f.engine.run(webPassword: testPassword, agentPassword: testPassword, expectedIdentity: Identity(cid: testCID, firmwareHash: ModemEngine.firmwareHash)) }
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.installerCalls == 0, "CID-only expectation permitted web restore")
        }
        run("Web challenge matches independent SHA256 vector without plaintext password") {
            let mock = MockWeb(Data()), client = try ModemWebClient(host:"192.0.2.1",transport:mock)
            try client.login(password:testPassword)
            try check(mock.loginArguments["password"] as? String == expectedPasswordHash, "Double uppercase SHA256")
            try check(client.session == sessionID && client.cookie == "test-cookie", "Authenticated session/cookie")
            try check(!mock.requests.contains { String(decoding:$0.data ?? Data(),as:UTF8.self).contains(testPassword) }, "No verbatim password in requests")
        }
        run("Rejected password stops before identity backup or host commands") {
            let f = try Fixture(); defer { f.remove() }; f.web.accepted=false
            try rejects("Вход отклонён") { _ = try f.engine.run(password:testPassword) }
            try check(f.web.methods == ["web_login_info","web_login"] && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] } && f.ssh.calls.allSatisfy { $0 == SSHReadProof.command }, "No further action")
            try check(!FileManager.default.fileExists(atPath:f.engine.pending.path), "No write journal")
        }
        run("Missing cookie zero session and invalid challenge fail login") {
            for choice in 0..<3 {
                let mock=MockWeb(Data()),client=try ModemWebClient(host:"192.0.2.1",transport:mock)
                if choice == 0 { mock.cookieHeader="unrelated=x" }
                if choice == 1 { mock.session=String(repeating:"0",count:32) }
                if choice == 2 { mock.challenge="" }
                try rejects { try client.login(password:testPassword) }
            }
        }
        run("Empty Web password is distinct and clears a previously authenticated session") {
            let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
            try client.login(password: testPassword)
            let previousRequests = mock.requests.count
            try rejectsWeb(.passwordRequired) { try client.login(password: "") }
            try check(mock.requests.count == previousRequests, "Empty password sent an authentication attempt")
            try check(client.cookie == nil && client.session == String(repeating: "0", count: 32), "Old credentials survived failed login")
        }
        run("Only explicit Web password rejection has invalidPassword type") {
            for result: Any in [1, "1"] {
                let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
                mock.loginResult = result
                try rejectsWeb(.invalidPassword) { try client.login(password: testPassword) }
                try check(mock.methods == ["web_login_info", "web_login"], "Password rejection retried or continued")
                try check(client.cookie == nil && client.session == String(repeating: "0", count: 32), "Rejected login retained credentials")
            }
        }
        run("Unknown Web login codes remain explicit rejection without claiming a wrong password") {
            for result: Any in [2, "9", -1] {
                let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
                mock.loginResult = result
                let expected = Int(String(describing: result))!
                try rejectsWeb(.authenticationRejected(code: expected)) { try client.login(password: testPassword) }
            }
        }
        run("Successful numeric and string Web login status require real session credentials") {
            for result: Any in [0, "0"] {
                let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
                mock.loginResult = result
                try client.login(password: testPassword)
                try check(try client.identity().imei == testIMEI, "Successful authentication did not permit identity")
            }
        }
        run("Malformed Web login results and sessions are protocol errors instead of password errors") {
            for choice in 0..<7 {
                let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
                switch choice {
                case 0: mock.cookieHeader = "unrelated=x"
                case 1: mock.session = String(repeating: "0", count: 32)
                case 2: mock.challenge = ""
                case 3: mock.loginResult = NSNull()
                case 4: mock.loginResult = false
                case 5: mock.loginResult = "unexpected"
                default: mock.rawReply = Data("not JSON".utf8)
                }
                do { try client.login(password: testPassword); throw TestFailure.check("Malformed login succeeded") }
                catch let error as ModemWebError {
                    guard case .malformedResponse = error else { throw TestFailure.check("Malformed response mislabeled: \(error)") }
                }
                try check(client.cookie == nil && client.session == String(repeating: "0", count: 32), "Malformed login retained credentials")
            }
        }
        run("Web RPC refusal does not falsely identify the password as invalid") {
            let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
            mock.outerError = 6
            try rejectsWeb(.rpcRejected(method: "web_login_info", code: 6)) { try client.login(password: testPassword) }
            try check(mock.methods == ["web_login_info"], "RPC refusal still sent a password")
        }
        run("Web connection failure remains a transport error and is never retried") {
            let mock = MockWeb(Data()), client = try ModemWebClient(host: "192.0.2.1", transport: mock)
            mock.transportFailure = URLError(.cannotConnectToHost)
            do { try client.login(password: testPassword); throw TestFailure.check("Connection unexpectedly succeeded") }
            catch let error as URLError { try check(error.code == .cannotConnectToHost, "Transport error changed") }
            try check(mock.requests.count == 1 && mock.methods.isEmpty, "Transport failure retried or sent password")
        }
        run("Invalid Web IMEI stops before fresh backup regardless of firmware name") {
            let f=try Fixture(); defer {f.remove()}
            f.web.info["integrate_version"]="unknown-firmware";f.web.info["imei"]="353490068701223"
            try rejects {_ = try f.engine.run(password:testPassword)}
            try check(f.web.backupCount == 0 && f.web.uploadedData == nil && f.web.restoreCount == 0,"Invalid identity cannot progress")
        }
        run("Fresh backup preparation verifies suffix and saves originals privately") {
            let f=try Fixture(); defer {f.remove()}
            let (identity,result,directory)=try f.engine.prepare(password:testPassword)
            try check(identity.imei == testIMEI && !result.alreadyEnabled && f.web.backupCount == 1, "Prepared fresh backup")
            try check(try Data(contentsOf:directory.appendingPathComponent("back_parameter.original")) == f.web.backupData, "Exact encrypted original")
            let permissions = try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("back_parameter.original").path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o600 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] }, "Prepare cannot mutate device")
        }
        run("Malformed encrypted backup never uploads or restores") {
            let f=try Fixture(data:Data("not an encrypted backup".utf8)); defer {f.remove()}
            try rejects {_ = try f.engine.run(password:testPassword)}
            try check(f.web.backupCount == 1 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] }, "Malformed archive blocks mutation")
        }
        run("Incorrect suffix cannot pass archive verification or upload") {
            let f=try Fixture(data:backup(suffix:"synthetic-wrong-suffix")); defer {f.remove()}
            try rejects {_ = try f.engine.run(password:testPassword)}
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] }, "Unverified suffix blocks restore after read-only ADB discovery")
        }
        run("Identity change while obtaining backup blocks patch upload") {
            let f=try Fixture(); defer {f.remove()}; f.web.identityChangeAfter=2
            try rejects("Устройство изменилось") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0, "Identity rechecked after backup")
        }
        run("Upload SHA mismatch blocks restore and preserves pending intent") {
            let f=try Fixture(); defer {f.remove()}; f.web.badUploadHash=true
            try rejects("SHA256") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.uploadedData != nil && f.web.restoreCount == 0, "No restore after bad upload digest")
            let journal = try readJSON(SetupJournal.self,f.engine.pending)
            try check(!journal.restoreRequested && !journal.installRequested, "No false restore/install claim")
            _ = try BackupPatch.inspect(BackupCipher.decrypt(f.web.uploadedData!,password:testIMEI+testBackupSuffix))
            try check(f.host.calls.allSatisfy { $0 == ["devices", "-l"] }, "No installation commands")
        }
        run("Identity change after upload blocks restore") {
            let f=try Fixture(); defer {f.remove()}; f.web.identityChangeAfter=4
            try rejects("Устройство изменилось") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.uploadedData != nil && f.web.restoreCount == 0, "Restore requires final identity check")
        }
        run("Retry before restore pairs new candidate with its own fresh original") {
            let f=try Fixture(); defer {f.remove()}; f.web.badUploadHash=true
            let oldOriginal=f.web.backupData
            try rejects("SHA256") {_ = try f.engine.run(password:testPassword)}
            let first=try readJSON(SetupJournal.self,f.engine.pending)
            f.web.backupData=try backup()
            try rejects("SHA256") {_ = try f.engine.run(password:testPassword)}
            let second=try readJSON(SetupJournal.self,f.engine.pending)
            try check(second.directory != first.directory && second.id == first.id,"Fresh backup gets its own directory on pre-restore retry")
            try check(try Data(contentsOf:URL(fileURLWithPath:second.directory).appendingPathComponent("back_parameter.original")) == f.web.backupData,"New candidate has matching original")
            try check(try Data(contentsOf:URL(fileURLWithPath:first.directory).appendingPathComponent("back_parameter.original")) == oldOriginal,"Previous original remains unchanged")
        }
        run("Pending installation never replays web restore when initial ADB scan is empty") {
            let f=try Fixture(); defer {f.remove()}
            let directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased());try secureDirectory(directory)
            var pending=SetupJournal(id:UUID().uuidString.lowercased(),identity:try WebIdentity(deviceObject()),phase:"install-requested",directory:directory.path)
            pending.installRequested=true;pending.cid=testCID
            try saveJSON(pending,f.engine.pending)
            f.host.deviceListSequence=["List of devices attached\n","List of devices attached\nABC device\n"]
            f.host.identityMode=true;f.host.shellText="pending"
            try rejects("прервалась до готовности") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0,"No web restore after install intent")
            let saved=try readJSON(SetupJournal.self,f.engine.pending)
            try check(saved.directory == directory.path,"Recovery keeps original journal directory")
        }
        run("Pending CID mismatch stops before key generation staging and installation") {
            let f=try Fixture();defer {f.remove()}
            let directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased());try secureDirectory(directory)
            var pending=SetupJournal(id:UUID().uuidString.lowercased(),identity:try WebIdentity(deviceObject()),phase:"prepared",directory:directory.path)
            pending.cid=String(repeating:"a",count:32);try saveJSON(pending,f.engine.pending)
            f.host.deviceList="List of devices attached\nABC device\n";f.host.identityMode=true
            try rejects("CID отличается") {_ = try f.engine.run(password:testPassword)}
            try check(!f.host.calls.contains {$0.contains("push") || $0.contains("-q") || $0.joined().contains("mkdir")},"No writes to mismatched CID")
        }
        run("CID change immediately before staging blocks every device write") {
            let f=try Fixture();defer {f.remove()}
            f.host.deviceList="List of devices attached\nABC device\n";f.host.identityMode=true
            f.host.identityCIDSequence=[testCID,String(repeating:"a",count:32)]
            try rejects("изменились") {_ = try f.engine.run(password:testPassword)}
            try check(!f.host.calls.contains {$0.contains("push") || $0.joined().contains("mkdir")},"No stage creation/push after identity changed")
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0,"Existing ADB skips web restore")
        }
        run("Full virgin setup verifies backup restore ADB install pin SSH authentication and commit") {
            let f=try Fixture();defer {f.remove()}
            f.host.fullInstaller=true;f.host.identityMode=true;f.host.deviceList="List of devices attached\nABC device\n"
            f.host.deviceListSequence=["List of devices attached\n", "List of devices attached\n", f.host.deviceList]
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            let result=try f.engine.run(password:testPassword)
            try check(result.state == nil && result.identity?.cid == testCID,"Final verified modem state")
            try check(f.web.backupCount == 1 && f.web.restoreCount == 1 && f.host.installerCalls == 1,"Backup and restore/install exactly once")
            try check(f.ssh.authenticationCalls == 2 && f.ssh.commitCalls == 1,"Access and commit both authenticate the new agent")
            try check(!FileManager.default.fileExists(atPath:f.engine.pending.path),"Completed setup clears pending journal")
            let known=try String(contentsOfFile:result.connection.knownHostsPath,encoding:.utf8)
            try check(known.hasPrefix("[192.0.2.1]:2222 ssh-ed25519 "),"Host key pinned from verified USB identity")
            let directory=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("SetupBackups"),includingPropertiesForKeys:nil).first!
            let journal=try readJSON(SetupJournal.self,directory.appendingPathComponent("setup-result.json"))
            try check(journal.phase == "complete" && journal.restoreRequested && journal.installRequested,"Durable complete record")
        }
        run("Working physical ADB skips suffix decryption and USB activation") {
            let f = try Fixture(data: backup(suffix: "unknown-but-not-needed")); defer { f.remove() }
            f.host.fullInstaller = true; f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device transport_id:1\n"
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            let result = try f.engine.run(password: testPassword)
            try check(result.identity?.cid == testCID && f.host.calls.contains(["-d", "get-serialno"]), "USB selector fallback not used")
            try check(f.web.directCount == 0 && f.web.restoreCount == 0 && !f.web.methods.contains("list:zwrt_bsp.usb"), "Working ADB triggered activation")
        }
        run("Working root ADB with unknown hashes reaches structural preflight without activation or restore") {
            for unknownRouter in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"; f.web.directAdvertised = true
                if unknownRouter { f.host.identityRouter = String(repeating: "0", count: 64) }
                else { f.host.identityFirmware = String(repeating: "0", count: 64) }
                f.host.preflightError = true
                try rejects("PREFLIGHT_TOOL") { _ = try f.engine.run(password: testPassword) }
                try check(f.web.directCount == 0 && f.web.restoreCount == 0 && f.web.uploadedData == nil && f.host.installerCalls == 0, "Unsupported but working ADB caused mutating fallback")
            }
        }
        run("Initial ADB inventory failure and duplicate serials block activation before any USB or restore request") {
            for duplicate in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                f.web.directAdvertised = true
                if duplicate { f.host.deviceList = "List of devices attached\nABC device usb:1\nABC device usb:2\n" }
                else { f.host.status = 1 }
                try rejects("Не удалось проверить USB ADB") { _ = try f.engine.run(password: testPassword) }
                try check(f.web.directCount == 0 && f.web.restoreCount == 0 && f.web.uploadedData == nil && f.host.installerCalls == 0 && !f.web.methods.contains("list:zwrt_bsp.usb"), "Broken host inventory was mistaken for absent ADB and changed the modem")
            }
        }
        run("Advertised direct USB debug verifies real ADB and skips backup restore") {
            let f = try Fixture(); defer { f.remove() }
            f.host.fullInstaller = true; f.host.identityMode = true; f.web.directAdvertised = true
            f.web.onDirect = { [weak host = f.host] in host?.deviceList = "List of devices attached\nABC device usb:1\n" }
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            _ = try f.engine.run(password: testPassword)
            try check(f.web.directCount == 1 && f.web.restoreCount == 0 && f.web.uploadedData == nil && f.host.installerCalls == 1, "Direct success failed to stop activation chain")
        }
        run("Direct acknowledgement alone cannot start installation and falls back once on B31") {
            let f = try Fixture(); defer { f.remove() }
            f.web.directAdvertised = true
            try rejects("Работающий ADB") { _ = try f.engine.run(password: testPassword) }
            let pending = try readJSON(SetupJournal.self, f.engine.pending)
            try check(f.web.directCount == 1 && f.web.restoreCount == 1 && f.host.installerCalls == 0 && pending.restoreRequested && pending.directADBOutcome == "accepted", "Web success was mistaken for usable ADB")
            try rejects("Работающий ADB") { _ = try f.engine.run(password: testPassword) }
            try check(f.web.directCount == 1 && f.web.restoreCount == 1 && f.host.installerCalls == 0, "Retry replayed a mutating request")
        }
        run("Lost direct response with usable ADB proceeds without repeating the operation") {
            let f = try Fixture(); defer { f.remove() }
            f.web.directAdvertised = true; f.web.directFailure = URLError(.networkConnectionLost)
            f.host.fullInstaller = true; f.host.identityMode = true
            f.web.onDirect = { [weak host = f.host] in host?.deviceList = "List of devices attached\nABC device usb:1\n" }
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            _ = try f.engine.run(password: testPassword)
            try check(f.web.directCount == 1 && f.web.restoreCount == 0 && f.host.installerCalls == 1, "Uncertain direct response was replayed or hid working ADB")
        }
        run("Changed web target after direct USB blocks fallback restore") {
            let f = try Fixture(); defer { f.remove() }
            f.web.directAdvertised = true
            f.web.onDirect = { [weak web = f.web] in web?.identityChangeAfter = 3 }
            try rejects("после USB debug") { _ = try f.engine.run(password: testPassword) }
            try check(f.web.directCount == 1 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.installerCalls == 0, "Uncertain target reached restore")
        }
        run("Direct fallback restores only a fresh backup taken after USB switch") {
            let f = try Fixture(); defer { f.remove() }
            let fresh = try backup(); f.web.directAdvertised = true; f.web.directCode = 1
            f.web.onDirect = { [weak web = f.web] in web?.backupData = fresh }
            try rejects("Работающий ADB") { _ = try f.engine.run(password: testPassword) }
            let pending = try readJSON(SetupJournal.self, f.engine.pending)
            try check(f.web.backupCount == 1 && f.web.directCount == 1 && f.web.restoreCount == 1 && pending.directADBOutcome == "rejected", "Rejected direct method skipped controlled fallback")
            try check(try Data(contentsOf: URL(fileURLWithPath: pending.directory).appendingPathComponent("back_parameter.original")) == fresh, "Fallback paired patch with a stale original")
            let manifest = try readJSON([String: String].self, URL(fileURLWithPath: pending.directory).appendingPathComponent("manifest.json"))
            try check(manifest["encryptedSHA256"] == digest(fresh), "Fallback patched an earlier backup")
        }
        run("Unknown introspection tries the one known USB method and explicit absence skips it on any firmware") {
            for advertised in [false,true] {
                let f=try Fixture();defer {f.remove()}
                f.web.info["integrate_version"]="FLY_CN_MU5250V1.0.0B13";f.web.info["wa_inner_version"]="BD_FLYMODEMMU5250V1.0.0B28"
                f.web.listUnavailable=advertised
                try rejects("Работающий ADB") { _ = try f.engine.run(password:testPassword) }
                try check(f.web.directCount == (advertised ? 1 : 0) && f.web.backupCount == 1 && f.web.restoreCount == 1,"Known method chain did not follow introspection")
                try rejects("Работающий ADB") { _ = try f.engine.run(password:testPassword) }
                try check(f.web.directCount == (advertised ? 1 : 0) && f.web.restoreCount == 1,"Uncertain restore was replayed")
            }
        }
        run("FLY B28 direct success needs no backup support key or firmware override") {
            let f=try Fixture(data:Data("backup endpoint unsupported".utf8));defer {f.remove()}
            f.web.info["integrate_version"]="FLY_CN_MU5250V1.0.0B13";f.web.info["wa_inner_version"]="BD_FLYMODEMMU5250V1.0.0B28"
            f.host.identityMode=true;f.host.identityInfo=f.web.info;f.web.listUnavailable=true
            f.web.onDirect={ [weak host=f.host] in host?.deviceList="List of devices attached\nABC device usb:1\n" }
            let result=try f.engine.enableDiagnosticADB(webPassword:testPassword)
            try check(result.webIdentity.firmware.hasPrefix("FLY_") && f.web.directCount == 1 && f.web.backupCount == 0 && f.web.restoreCount == 0,"Direct success required backup or version gate")
        }
        run("FLY B28 verified fallback continues through measured generic installer") {
            let f=try Fixture();defer {f.remove()}
            f.web.info["integrate_version"]="FLY_CN_MU5250V1.0.0B13";f.web.info["wa_inner_version"]="BD_FLYMODEMMU5250V1.0.0B28"
            f.host.identityInfo=f.web.info;f.host.identityMode=true;f.host.fullInstaller=true
            f.host.identityFirmware=String(repeating:"a",count:64);f.host.identityRouter=String(repeating:"b",count:64)
            f.ssh.firmware=f.host.identityFirmware;f.ssh.accessRouter=f.host.identityRouter
            f.host.deviceList="List of devices attached\nABC device usb:1\n"
            f.host.deviceListSequence=["List of devices attached\n","List of devices attached\n",f.host.deviceList]
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            let result=try f.engine.run(password:testPassword)
            try check(result.identity?.firmwareHash==f.host.identityFirmware && result.state==nil && f.web.restoreCount==1 && f.host.installerCalls==1,"Verified fallback did not reach generic installation")
            let startup=String(decoding:f.host.uploads[f.host.stage+"/start-agent.sh"]!,as:UTF8.self)
            try check(startup.contains("ZTE_AGENT_MODE='discovery'") && !FileManager.default.fileExists(atPath:f.engine.pending.path),"Generic state or transaction completion lost")
        }
        run("Generic handoff preserves restore intent through preflight failure and missing ADB") {
            let f=try Fixture();defer {f.remove()}
            f.web.info["integrate_version"]="FLY_CN_MU5250V1.0.0B13";f.web.info["wa_inner_version"]="BD_FLYMODEMMU5250V1.0.0B28"
            f.host.identityInfo=f.web.info;f.host.identityMode=true;f.host.fullInstaller=true;f.host.preflightError=true
            f.host.identityFirmware=String(repeating:"a",count:64);f.host.identityRouter=String(repeating:"b",count:64)
            f.ssh.firmware=f.host.identityFirmware;f.ssh.accessRouter=f.host.identityRouter
            f.host.deviceList="List of devices attached\nABC device usb:1\n"
            f.host.deviceListSequence=["List of devices attached\n","List of devices attached\n",f.host.deviceList]
            try rejects { _ = try f.engine.run(password:testPassword) }
            try check(f.web.restoreCount==1 && f.host.installerCalls==0,"First failure occurred outside post-restore preflight")
            let pending=try readJSON(SetupJournal.self,f.engine.pending)
            try check(pending.phase=="adb-ready" && pending.restoreRequested && !pending.installRequested,"Bootstrap intent was lost before generic preflight completed")
            let previousUploads=f.web.requests.filter{$0.path=="/cgi-bin/cgi-upload"}.count
            f.host.deviceList="List of devices attached\n";f.host.shellCode="0";f.host.preflightError=false
            try rejects { _ = try f.engine.run(password:testPassword) }
            let retained=try readJSON(SetupJournal.self,f.engine.pending)
            try check(retained.restoreRequested && f.web.restoreCount==1 && f.web.directCount==0 && f.web.requests.filter{$0.path=="/cgi-bin/cgi-upload"}.count==previousUploads && f.host.installerCalls==0,"Retry repeated activation or restore after handoff failure")
        }
        run("Offline and unauthorized ADB are explained without claiming access") {
            let f = try Fixture(); defer { f.remove() }
            f.host.deviceList = "List of devices attached\nABC unauthorized usb:1\nDEF offline usb:2\n"
            try rejects("unauthorized") { _ = try f.engine.waitADB(ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: f.host), expected: WebIdentity(deviceObject())) }
            try check(f.host.calls.allSatisfy { $0 == ["devices", "-l"] }, "Non-ready transport received a shell command")
        }
        run("USB selector must name a listed ready endpoint and cannot accept network endpoints") {
            let host = MockHost(), adb = ADBClient(binary: URL(fileURLWithPath: "/fixture/adb"), runner: host)
            host.deviceList = "List of devices attached\nABC device transport_id:1\n"; host.usbSerialOverride = "DIFFERENT"
            try check(try adb.devices(usbOnly: true).isEmpty, "USB selector accepted an unlisted endpoint")
            host.deviceList = "List of devices attached\n192.0.2.5:5555 device transport_id:1\n"; host.calls = []
            try check(try adb.devices(usbOnly: true).isEmpty && host.calls == [["devices", "-l"]], "Network endpoint entered USB fallback")
        }
        run("Forced preparation bypasses working SSH and installs once with explicit flag") {
            let f=try Fixture();defer {f.remove()}
            f.host.identityMode=true;f.host.fullInstaller=true;f.host.deviceList="List of devices attached\nABC device usb:1\n";f.ssh.ready=true
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.installedJournal=host?.remoteJournal ?? "" }
            let newPassword="synthetic-forced-new-password"
            f.ssh.expectedAgentPassword = newPassword
            _ = try f.engine.run(webPassword:"",agentPassword:newPassword,forceReinstall:true)
            let commands=f.host.calls.map{$0.joined(separator:" ")}
            try check(f.host.installerCalls==1 && f.ssh.authenticationCalls==1 && f.ssh.commitCalls==1,"Forced preparation reused SSH instead of verified reinstall")
            try check(commands.contains{$0.contains("'--reinstall' '--preflight'")} && commands.contains{$0.contains("/setup-agent.sh' '--reinstall'")},"Force flag absent from preflight/apply")
            let startup=String(decoding:f.host.uploads[f.host.stage+"/start-agent.sh"]!,as:UTF8.self)
            try check(startup.contains(newPassword) && !commands.contains{$0.contains(newPassword)},"Forced password missing from private startup or exposed in argv")
            try check(!f.ssh.calls.contains{$0.contains("--reinstall")} && f.web.requests.isEmpty && f.web.restoreCount==0,"Force widened commit or called Web on ready USB")
        }
        run("Saved preparation mode wins over a changed checkbox before dispatch") {
            for initial in [false,true] {
                let f=try Fixture();defer {f.remove()}
                f.host.identityMode=true;f.host.fullInstaller=true;f.host.deviceList="List of devices attached\nABC device usb:1\n";f.host.failPushAt=2
                f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
                try rejects("interrupted upload") { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:initial) }
                let first=try readJSON(AccessSetupJournal.self,f.engine.pending)
                try check(first.forceReinstall==initial && !first.installRequested,"Mode was not persisted before staging")
                f.host.failPushAt=nil;f.host.calls=[]
                _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:!initial)
                let apply=f.host.calls.map{$0.joined(separator:" ")}.first{$0.contains("(sh '") && $0.contains("/setup-agent.sh'")} ?? ""
                try check(apply.contains("'--reinstall'")==initial && f.host.installerCalls==1,"Changed checkbox changed pending mode")
            }
        }
        run("Clean intent implies force and a changed retry cannot silently replace an unready intent") {
            for initial in [false,true] {
                let f=try Fixture();defer { f.remove() }
                f.host.identityMode=true;f.host.fullInstaller=true;f.host.deviceList="List of devices attached\nABC device usb:1\n";f.host.failPushAt=2
                try rejects("interrupted upload") { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,cleanComponents:initial) }
                let saved=try readJSON(AccessSetupJournal.self,f.engine.pending)
                try check(saved.cleanComponents==initial && saved.forceReinstall==initial && !saved.installRequested,
                          "Cleanup mode was not persisted before staging or failed to imply force")
                f.host.pushCount=0;f.host.calls=[]
                try rejects(initial ? "interrupted upload" : "не подтвердила готовность") { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:!initial,cleanComponents:!initial) }
                let retained=try readJSON(AccessSetupJournal.self,f.engine.pending)
                try check(retained.cleanComponents==initial && retained.forceReinstall==initial && f.host.installerCalls==0,
                          "Retry changed saved cleanup mode or dispatched installation")
            }
        }
        run("Malformed cleanup journal blocks bootstrap before any Web or ADB request") {
            let f=try Fixture();defer { f.remove() }
            try savePrivate(Data("{}".utf8),ComponentCleanup.pendingURL(root:f.root))
            try rejects { _ = try f.engine.run(webPassword:testPassword,agentPassword:testPassword,forceReinstall:true,cleanComponents:true) }
            try check(f.web.requests.isEmpty && f.host.calls.isEmpty && f.ssh.calls.isEmpty && f.host.installerCalls==0,
                      "Unknown cleanup state replayed preparation or accessed a device")
        }
        run("Dangling cleanup intent blocks bootstrap before any transport") {
            let f=try Fixture();defer { f.remove() }
            try FileManager.default.createSymbolicLink(at:ComponentCleanup.pendingURL(root:f.root),withDestinationURL:f.root.appendingPathComponent("absent-plan"))
            try check(ComponentCleanup.hasPending(root:f.root), "Dangling intent was treated as absent")
            try rejects { _ = try f.engine.run(webPassword:testPassword,agentPassword:testPassword) }
            try check(f.web.requests.isEmpty && f.host.calls.isEmpty && f.ssh.calls.isEmpty, "Unsafe cleanup intent reached transport")
        }
        run("Committed cleanup resumes alone and acknowledges a completed crash without setup replay") {
            let f=try Fixture();defer { f.remove() }
            f.host.identityMode=true;f.host.fullInstaller=true;f.host.deviceList="List of devices attached\nABC device usb:1\n"
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            try rejects("операция модема") { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,cleanComponents:true) }
            let url=ComponentCleanup.pendingURL(root:f.root)
            var plan=try readJSON(ComponentCleanupPlan.self,url)
            try check(plan.phase=="prepared" && f.host.installerCalls==1 && f.ssh.commitCalls==1 &&
                      !FileManager.default.fileExists(atPath:f.engine.pending.path), "Cleanup was not durably separated after commit")
            let backup=URL(fileURLWithPath:plan.setupReceipt)
            let completeSetup=try Data(contentsOf:backup)
            let saved=try JSONDecoder().decode(AccessSetupJournal.self,from:completeSetup)
            try check(saved.phase=="complete" && saved.cleanComponents==true && saved.forceReinstall==true, "Missing completed setup receipt")
            let webCount=f.web.requests.count, adbCount=f.host.calls.count, authCount=f.ssh.authenticationCalls
            try rejects("операция модема") { _ = try f.engine.run(webPassword:"",agentPassword:"",forceReinstall:false,cleanComponents:false) }
            try check(f.web.requests.count==webCount && f.host.calls.count==adbCount && f.ssh.authenticationCalls==authCount && f.host.installerCalls==1,
                      "Cleanup retry requested credentials or replayed bootstrap/install")
            let archive=Data("synthetic owned component backup".utf8)
            try secureDirectory(URL(fileURLWithPath:plan.backupDirectory))
            try savePrivate(archive,URL(fileURLWithPath:plan.backupDirectory).appendingPathComponent("components.tar"))
            plan.phase="clean-requested";plan.archiveSha=digest(archive);plan.archiveBytes=Int64(archive.count)
            try saveJSON(plan,url)
            // Simulate a crash after scheduling while the already-complete setup journal remains.
            try savePrivate(completeSetup,f.engine.pending)
            f.ssh.cleanupComplete=true
            let result=try f.engine.run(webPassword:"",agentPassword:"")
            try check(result.componentsCleaned && result.identity==plan.identity &&
                      !ComponentCleanup.hasPending(root:f.root) && !FileManager.default.fileExists(atPath:f.engine.pending.path),
                      "Completed cleanup was not acknowledged")
            try check(f.host.installerCalls==1 && f.ssh.commitCalls==1 && f.web.requests.count==webCount && f.host.calls.count==adbCount &&
                      f.ssh.cleanupActions==["status","status","status"], "Completed cleanup replayed an action")
            try check(try Data(contentsOf:backup)==completeSetup, "Setup receipt was lost or changed")
            let receipt=try readJSON(ComponentCleanupPlan.self,URL(fileURLWithPath:plan.backupDirectory).appendingPathComponent("cleanup-result.json"))
            try check(receipt.phase=="complete" && receipt.archiveSha==digest(archive), "Cleanup completion receipt missing")
        }
        run("Completed clean preparation retries scheduling over SSH without USB credentials or commit") {
            let f=try Fixture();defer { f.remove() }
            let id=UUID().uuidString.lowercased(), directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
            // Legacy backups may have a directory UUID different from the setup UUID.
            try secureDirectory(directory)
            var journal=SetupJournal(id:id,identity:try WebIdentity(deviceObject()),phase:"complete",directory:directory.path)
            journal.installRequested=true;journal.forceReinstall=true;journal.cleanComponents=true
            journal.cid=testCID;journal.firmwareHash=ModemEngine.firmwareHash;journal.routerHash=ModemEngine.routerHash
            journal.installerProfile="b31";journal.remoteStage=SetupRemotePaths.anchor+"/stage-"+id
            journal.remoteJournal=SetupRemotePaths.anchor+"/installations/"+id
            try saveJSON(journal,f.engine.pending)
            try secureDirectory(f.root.appendingPathComponent("SSH"))
            try savePrivate(Data("synthetic key".utf8),f.root.appendingPathComponent("SSH/id_ed25519"))
            try savePrivate(Data("synthetic known hosts".utf8),f.root.appendingPathComponent("SSH/known_hosts"))
            f.ssh.ready=true
            try rejects("операция модема") { _ = try f.engine.run(webPassword:"",agentPassword:"") }
            try check(ComponentCleanup.hasPending(root:f.root) && f.ssh.cleanupActions==["status"] &&
                      f.web.requests.isEmpty && f.host.calls.isEmpty && f.ssh.authenticationCalls==0 && f.ssh.commitCalls==0,
                      "Completed preparation required USB, authentication or replayed commit")
            try check(!FileManager.default.fileExists(atPath:f.engine.pending.path),"Complete setup journal was not handed off")
        }
        run("Cleanup cancellation preserves receipts and never dispatches setup or removal") {
            let f=try Fixture();defer { f.remove() }
            let id=UUID().uuidString.lowercased(), directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
            try secureDirectory(directory);f.ssh.ready=true
                try savePrivate(Data("synthetic key".utf8),URL(fileURLWithPath:f.engine.currentConnection.keyPath))
                try savePrivate(Data("synthetic known hosts".utf8),URL(fileURLWithPath:f.engine.currentConnection.knownHostsPath))
            var journal=SetupJournal(id:id,identity:try WebIdentity(deviceObject()),phase:"complete",directory:directory.path)
            journal.installRequested=true;journal.forceReinstall=true;journal.cleanComponents=true
            journal.cid=testCID;journal.firmwareHash=ModemEngine.firmwareHash;journal.routerHash=ModemEngine.routerHash
            try saveJSON(journal,f.engine.pending);try saveJSON(journal,directory.appendingPathComponent("setup-result.json"))
            try ComponentCleanup.schedule(root:f.root,connection:f.engine.currentConnection,setupID:id,setupDirectory:directory,
                expectedIdentity:Identity(cid:testCID,firmwareHash:ModemEngine.firmwareHash),transport:f.ssh)
            let url=ComponentCleanup.pendingURL(root:f.root),original=try Data(contentsOf:ComponentCleanup.pendingURL(root:f.root))
            try check(ComponentCleanup.canCancel(root:f.root), "Prepared cleanup cancellation is unavailable")
            f.ssh.cleanupReply="CLEAN_ABSENT"
            let result=try f.engine.cancelComponentCleanup()
            try check(!result.componentsCleaned && !ComponentCleanup.hasPending(root:f.root) && !FileManager.default.fileExists(atPath:f.engine.pending.path),
                      "Cancellation did not release only the completed matching intents")
            let backup=f.root.appendingPathComponent("ComponentBackups/"+id)
            try check(try Data(contentsOf:backup.appendingPathComponent("cleanup-before-cancel.json"))==original,"Original cancellation intent was lost")
            let cancelled=try readJSON(ComponentCleanupPlan.self,backup.appendingPathComponent("cleanup-cancelled.json"))
            try check(cancelled.phase=="cancelled" && f.ssh.cleanupActions==["status"] && f.host.calls.isEmpty && f.web.requests.isEmpty &&
                      f.ssh.authenticationCalls==0 && f.ssh.commitCalls==0,"Cancel changed components or replayed preparation")
            // Crash after terminal cancellation, before acknowledgment: run only finishes local handoff.
            try saveJSON(cancelled,url);try saveJSON(journal,f.engine.pending)
            let before=f.ssh.calls.count
            _ = try f.engine.run(webPassword:"",agentPassword:"")
            try check(f.ssh.calls.count==before && !ComponentCleanup.hasPending(root:f.root),"Terminal cancellation resumed remote work")
        }
        run("Cleanup cancellation refuses dispatched or unknown state and retains intent") {
            for local in ["prepared", "clean-requested"] {
                let f=try Fixture();defer { f.remove() }
                let id=UUID().uuidString.lowercased(),directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
                try secureDirectory(directory);f.ssh.ready=true
                try savePrivate(Data("synthetic key".utf8),URL(fileURLWithPath:f.engine.currentConnection.keyPath))
                try savePrivate(Data("synthetic known hosts".utf8),URL(fileURLWithPath:f.engine.currentConnection.knownHostsPath))
                try ComponentCleanup.schedule(root:f.root,connection:f.engine.currentConnection,setupID:id,setupDirectory:directory,
                    expectedIdentity:Identity(cid:testCID,firmwareHash:ModemEngine.firmwareHash),transport:f.ssh)
                let url=ComponentCleanup.pendingURL(root:f.root)
                var plan=try readJSON(ComponentCleanupPlan.self,url)
                if local=="clean-requested" {plan.phase=local;plan.archiveSha=String(repeating:"a",count:64);plan.archiveBytes=1;try saveJSON(plan,url)}
                let original=try Data(contentsOf:url)
                f.ssh.calls=[];f.ssh.cleanupReply="CLEAN_PENDING " + String(repeating:"a",count:64) + " 1"
                try rejects { _ = try f.engine.cancelComponentCleanup() }
                try check(try Data(contentsOf:url)==original,"Unknown/dispatched cancellation modified intent")
                try check(!f.ssh.cleanupActions.contains("clean") && f.web.requests.isEmpty && f.host.calls.isEmpty,
                          "Cancellation dispatched cleanup or bootstrap")
                if local=="clean-requested" {try check(f.ssh.calls.isEmpty && !ComponentCleanup.canCancel(root:f.root),"Dispatched cleanup reached remote cancel")}
            }
        }
        run("Forced lost acknowledgement retains intent and resumes without replay") {
            let f=try Fixture();defer {f.remove()}
            f.host.identityMode=true;f.host.fullInstaller=true;f.host.deviceList="List of devices attached\nABC device usb:1\n";f.host.loseInstallAcknowledgement=true
            var recordedBeforeDispatch=false
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in
                recordedBeforeDispatch=(try? readJSON(AccessSetupJournal.self,f.engine.pending)).map{$0.installRequested && $0.forceReinstall==true} ?? false
                ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? ""
            }
            try rejects { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:true) }
            try check(recordedBeforeDispatch && FileManager.default.fileExists(atPath:f.engine.pending.path),"Lost acknowledgement discarded forced intent")
            f.host.shellCode="0"
            _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:false)
            try check(f.host.installerCalls==1 && f.web.restoreCount==0 && f.ssh.commitCalls==1,"Forced resume replayed apply or restore")
        }
        run("Only exact verified forced rollback archives pending and permits explicit retry") {
            for valid in [false,true] {
                let f=try Fixture();defer {f.remove()}
                f.host.identityMode=true;f.host.fullInstaller=true;f.host.deviceList="List of devices attached\nABC device usb:1\n";f.host.loseInstallAcknowledgement=true
                f.host.rollbackVerified=true
                if !valid { f.host.rollbackReply="INSTALL_ROLLBACK_VERIFIED /foreign" }
                try rejects { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:true) }
                try check(FileManager.default.fileExists(atPath:f.engine.pending.path) == !valid,"Unverified rollback released pending intent")
                try check(f.host.installerCalls==1 && f.web.restoreCount==0,"Rollback handler replayed mutation")
                if valid {
                    let dirs=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("SetupBackups"),includingPropertiesForKeys:nil)
                    let archived=try readJSON(AccessSetupJournal.self,dirs[0].appendingPathComponent("setup-rolled-back.json"))
                    try check(archived.installRequested && archived.forceReinstall==true,"Rollback original journal lost")
                    try check(FileManager.default.fileExists(atPath:dirs[0].appendingPathComponent("rollback-verification.txt").path),"Rollback proof not retained")
                } else {
                    f.host.remoteState="rolled-back";f.host.shellCode="0"
                    try rejects { _ = try f.engine.run(webPassword:"",agentPassword:testPassword,forceReinstall:false) }
                    try check(f.host.installerCalls==1 && FileManager.default.fileExists(atPath:f.engine.pending.path),"Bare rolled-back state released intent or replayed")
                }
            }
        }
        run("Existing SSH agent fast path does not upload restore or install") {
            let f=try Fixture();defer {f.remove()};f.ssh.ready=true
            let result=try f.engine.run(password:testPassword)
            try check(result.state == nil && result.identity?.cid == testCID,"Existing pair verified via NV and API")
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] },"No ADB/bootstrap mutations on existing access")
            try check(f.ssh.authenticationCalls == 0 && f.ssh.commitCalls == 0,"Access-only reuse attempted agent authentication")
        }
        run("Actual run reuses released previous agent only with current B31 identity and login") {
            for previous in [AccessAgentReusePolicy.previousSHA256, AccessAgentReusePolicy.publishedPreviousSHA256] {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"; f.ssh.ready = true
            f.ssh.agentDiskHash = previous
            try savePrivate(Data("synthetic-key".utf8), URL(fileURLWithPath: f.engine.currentConnection.keyPath))
            try savePrivate(Data("synthetic-hosts".utf8), URL(fileURLWithPath: f.engine.currentConnection.knownHostsPath))
            let result = try f.engine.run(webPassword: "", agentPassword: testPassword)
            try check(result.state == nil && result.connection.keyPath == f.engine.currentConnection.keyPath, "Reuse returned wrong connection or NV state")
            try check(f.ssh.authenticationCalls == 0 && f.ssh.processProofCalls == 0 && f.host.installerCalls == 0 && f.host.pushCount == 0 && f.host.stage.isEmpty && f.web.requests.isEmpty, "Reuse installed, skipped login, or used web")
            try check(!FileManager.default.fileExists(atPath: f.engine.pending.path) && !f.ssh.calls.contains { $0.contains("--snapshot") || $0.contains("zte_nv") || $0.contains("--commit") }, "Reuse created installation or NV work")
            }
        }
        run("SSH reuse does not inspect unknown or mismatched agent") {
            for mappedMismatch in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"; f.ssh.ready = true
                f.ssh.agentDiskHash = mappedMismatch ? AccessAgentReusePolicy.previousSHA256 : String(repeating: "a", count: 64)
                if mappedMismatch { f.ssh.agentMappedHash = String(repeating: "b", count: 64) }
                try savePrivate(Data("key".utf8), URL(fileURLWithPath: f.engine.currentConnection.keyPath))
                try savePrivate(Data("hosts".utf8), URL(fileURLWithPath: f.engine.currentConnection.knownHostsPath))
                _ = try f.engine.run(webPassword: "", agentPassword: "")
                try check(f.ssh.authenticationCalls == 0 && f.host.installerCalls == 0 && f.host.pushCount == 0 && f.host.stage.isEmpty, "Unknown binary permitted auth/install")
            }
        }
        run("SSH reuse permits generic and B02 read-only access without agent checks") {
            for generic in [true, false] {
                let f = try Fixture(); defer { f.remove() }
                f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"; f.ssh.ready = true
                let firmware = generic ? String(repeating: "c", count: 64) : OnboardingEngine.b02FirmwareHash
                f.host.identityFirmware = firmware; f.ssh.firmware = firmware; f.ssh.agentDiskHash = AccessAgentReusePolicy.previousSHA256
                try savePrivate(Data("key".utf8), URL(fileURLWithPath: f.engine.currentConnection.keyPath))
                try savePrivate(Data("hosts".utf8), URL(fileURLWithPath: f.engine.currentConnection.knownHostsPath))
                var connection = f.engine.currentConnection; connection.skipFirmwareCheck = !generic
                let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: connection, runner: f.host, sshFactory: { _ in f.ssh }, researchRunner: MockResearch())
                _ = try manager.run(webPassword: "", agentPassword: "")
                try check(f.ssh.authenticationCalls == 0 && f.host.installerCalls == 0 && f.host.pushCount == 0, "Scoped historical policy widened")
            }
        }
        run("SSH reuse ignores unavailable agent credentials but rejects changed SSH boot") {
            for changed in [false, true] {
                let f = try Fixture(); defer { f.remove() }; f.ssh.ready = true
                f.ssh.authenticationAccepted = false; f.ssh.agentProcessValid = false; f.ssh.changeAccessBoot = changed
                if changed { try rejects { _ = try f.engine.run(webPassword: "", agentPassword: "") } }
                else { _ = try f.engine.run(webPassword: "", agentPassword: "") }
                try check(f.ssh.authenticationCalls == 0 && f.ssh.processProofCalls == 0 && f.host.installerCalls == 0 && f.host.pushCount == 0, "Reuse inspected agent or installed")
            }
        }
        run("Actual run new-install verification never accepts previous binary") {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            f.ssh.agentDiskHash = AccessAgentReusePolicy.previousSHA256
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            try rejects("сборка") { _ = try f.engine.run(webPassword: "", agentPassword: testPassword) }
            try check(f.host.installerCalls == 1 && f.ssh.authenticationCalls == 0 && f.ssh.commitCalls == 0, "Old binary was accepted after new installation")
            try check(try readJSON(AccessSetupJournal.self, f.engine.pending).installRequested, "Unknown installation journal lost")
        }
        run("Successful initial preparation installs SSH and agent without VPN or launcher components") {
            let f = try Fixture(); defer { f.remove() }
            f.host.fullInstaller = true; f.host.identityMode = true
            f.host.deviceList = "List of devices attached\nABC device\n"
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in
                ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? ""
            }
            try check(!FileManager.default.fileExists(atPath: f.resources.appendingPathComponent("VPN").path), "Fixture unexpectedly provides optional VPN resources")
            let result = try f.engine.run(password: testPassword)
            try check(result.identity?.cid == testCID && f.host.installerCalls == 1 && f.ssh.authenticationCalls == 1 && f.ssh.commitCalls == 1, "Preparation did not complete verified SSH and agent installation")
            let staged = Set(f.host.uploads.keys.map { URL(fileURLWithPath: $0).lastPathComponent })
            try check(staged == Set(["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh", "id_ed25519.pub", "start-agent.sh"]), "Preparation staged optional application components")
            let commands = f.host.calls.map { $0.joined(separator: " ") } + f.ssh.calls
            let optionalComponents = ["vpnctl", "/data/zte-vpn", "/data/zte-launcher", "install-launcher", "launcher.so", "mihomo"]
            try check(commands.allSatisfy { command in optionalComponents.allSatisfy { !command.contains($0) } }, "Preparation invoked VPN or launcher setup")
            let productionInstaller = try String(contentsOfFile: "Resources/Onboarding/setup-agent.sh", encoding: .utf8)
            try check(optionalComponents.allSatisfy { !productionInstaller.contains($0) }, "Bundled SSH installer also configures optional VPN or launcher components")
        }
        run("Existing SSH access never invokes NV even when an NV fixture would fail") {
            let f=try Fixture();defer {f.remove()};f.ssh.ready=true;f.ssh.malformedSnapshot=true
            let result = try f.engine.run(password:testPassword)
            try check(result.state == nil && !f.ssh.calls.contains { $0.contains("--snapshot") }, "Access must not invoke NV")
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] },"Read validation error stays an error")
        }
        run("Installer path resolver preserves requested legacy layout and rejects mismatched paths") {
            let id=UUID().uuidString.lowercased()
            let oldStage="/data/local/tmp/zte-imei-setup-"+id, oldJournal="/data/local/tmp/zte-imei-installations/"+id
            let newStage="/data/zte-imei-studio/stage-"+id, newJournal="/data/zte-imei-studio/installations/"+id
            let old=try SetupRemotePaths(id:id,installRequested:true,stage:nil,journal:nil)
            try check(old.stage==oldStage && old.journal==oldJournal && old.dropbearKey=="/data/bin/dropbearkey","Legacy dispatched operation moved to new layout")
            let next=try SetupRemotePaths(id:id,installRequested:false,stage:oldStage,journal:oldJournal)
            try check(next.stage==newStage && next.journal==newJournal,"Undispatched operation kept unsafe stock parents")
            let root=URL(fileURLWithPath:"/fixture")
            var prepared=AccessSetupJournal(id:id,cid:testCID,bootID:"01234567-89ab-4cde-8f01-23456789abcd",firmwareHash:ModemEngine.firmwareHash,routerHash:ModemEngine.routerHash,installerProfile:"b31",directory:"/fixture/SetupBackups/"+id,adbSerial:"ABC")
            prepared.remoteStage=oldStage; prepared.remoteJournal=oldJournal
            try prepared.validate(root:root)
            let resumed=try SetupRemotePaths(id:id,installRequested:true,stage:newStage,journal:newJournal)
            try check(resumed.stage==newStage && resumed.journal==newJournal && resumed.dropbearKey=="/data/zte-imei-studio/bin/dropbearkey","New operation lost saved paths")
            try rejects { _ = try SetupRemotePaths(id:id,installRequested:true,stage:oldStage,journal:newJournal) }
            try rejects { _ = try SetupRemotePaths(id:id,installRequested:false,stage:"/data/other",journal:nil) }
            try rejects { _ = try SetupRemotePaths(id:id,installRequested:true,stage:newStage,journal:newJournal+"/../other") }
            try rejects { _ = try SetupRemotePaths(id:"../other",installRequested:true,stage:nil,journal:nil) }
        }
        run("Legacy requested installation commits its saved installer without upload or replay") {
            let f=try Fixture(); defer {f.remove()}
            let id=UUID().uuidString.lowercased(), directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
            try secureDirectory(directory)
            var journal=SetupJournal(id:id,identity:try WebIdentity(deviceObject()),phase:"install-requested",directory:directory.path)
            journal.installRequested=true; journal.restoreRequested=true; journal.cid=testCID
            journal.installerProfile="b31"; journal.firmwareHash=ModemEngine.firmwareHash; journal.routerHash=ModemEngine.routerHash
            try saveJSON(journal,f.engine.pending)
            f.ssh.ready=true; f.ssh.installedJournal="/data/local/tmp/zte-imei-installations/"+id
            _ = try f.engine.run(webPassword:testPassword,agentPassword:testPassword,forceReinstall:true)
            try check(f.ssh.commitCalls==1 && f.ssh.calls.contains { $0.contains("stage='/data/local/tmp/zte-imei-setup-"+id+"'") && $0.contains("sh /proc/self/fd/9 '--commit'") },"Resume did not use original staged installer through verified descriptor")
            try check(f.host.pushCount==0 && f.host.installerCalls==0 && f.web.restoreCount==0,"Legacy resume replayed installation or restore")
            try check(!f.ssh.calls.contains{$0.contains("--reinstall")},"Checkbox changed old pending commit mode")
        }
        run("Ready USB resumes saved restore without any Web password or request") {
            let f=try Fixture(); defer {f.remove()}
            let id=UUID().uuidString.lowercased(), directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
            try secureDirectory(directory)
            var journal=SetupJournal(id:id,identity:try WebIdentity(deviceObject()),phase:"restore-requested",directory:directory.path)
            journal.restoreRequested=true; journal.cid=testCID
            try saveJSON(journal,f.engine.pending)
            f.host.fullInstaller=true; f.host.identityMode=true; f.host.deviceList="List of devices attached\nABC device usb:1\n"
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            _ = try f.engine.run(webPassword:"",agentPassword:testPassword)
            try check(f.web.requests.isEmpty && f.web.restoreCount==0 && f.web.uploadedData==nil,"Ready USB resume used Web or replayed restore")
            try check(f.host.installerCalls==1 && f.ssh.commitCalls==1 && f.host.stage.hasPrefix("/data/zte-imei-studio/stage-"),"Ready USB did not complete guarded private access install")
            let history=try readJSON(SetupJournal.self,directory.appendingPathComponent("bootstrap-result.json"))
            try check(history.restoreRequested && !history.installRequested,"Bootstrap history lost restore intent")
        }
        run("Saved restore without matching ready USB keeps intent and never falls through to Web") {
            for mismatch in [false,true] {
                let f=try Fixture(); defer {f.remove()}
                let id=UUID().uuidString.lowercased(),directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
                try secureDirectory(directory)
                var journal=SetupJournal(id:id,identity:try WebIdentity(deviceObject()),phase:"restore-requested",directory:directory.path)
                journal.restoreRequested=true; journal.cid=testCID; try saveJSON(journal,f.engine.pending)
                let before=try Data(contentsOf:f.engine.pending)
                f.host.identityMode=true
                if mismatch { f.host.deviceList="List of devices attached\nABC device usb:1\n";f.host.identityCID=String(repeating:"a",count:32) }
                try rejects { _ = try f.engine.run(webPassword:"",agentPassword:testPassword) }
                try check(f.web.requests.isEmpty && f.host.installerCalls==0 && f.host.pushCount==0,"Unconfirmed USB resume used Web or staged writes")
                try check(try Data(contentsOf:f.engine.pending)==before,"Unconfirmed USB resume changed restore intent")
            }
        }
        run("Requested restore with no installer continues in private anchor without restoring again") {
            let f=try Fixture(); defer {f.remove()}
            let id=UUID().uuidString.lowercased(), directory=f.root.appendingPathComponent("SetupBackups/"+UUID().uuidString.lowercased())
            try secureDirectory(directory)
            var journal=SetupJournal(id:id,identity:try WebIdentity(deviceObject()),phase:"restore-requested",directory:directory.path)
            journal.restoreRequested=true
            try saveJSON(journal,f.engine.pending)
            f.host.fullInstaller=true; f.host.identityMode=true; f.host.deviceList="List of devices attached\nABC device\n"
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            _ = try f.engine.run(password:testPassword)
            try check(f.web.restoreCount==0 && f.web.uploadedData==nil && f.host.installerCalls==1,"Resumed restore replayed Web mutation")
            try check(f.host.stage.hasPrefix("/data/zte-imei-studio/stage-") && f.host.remoteJournal.hasPrefix("/data/zte-imei-studio/installations/"),"Resumed restore used legacy stock parents")
        }
        run("Lost installer acknowledgement resumes ready journal without restore or installer replay") {
            let f=try Fixture();defer {f.remove()}
            f.host.fullInstaller=true;f.host.identityMode=true;f.host.deviceList="List of devices attached\nABC device\n"
            f.host.deviceListSequence=["List of devices attached\n", "List of devices attached\n", f.host.deviceList]
            f.host.loseInstallAcknowledgement=true
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            try rejects("Модем отклонил") {_ = try f.engine.run(password:testPassword)}
            let pending=try readJSON(SetupJournal.self,f.engine.pending)
            try check(pending.installRequested && pending.restoreRequested && pending.phase == "install-requested","Intent persisted before lost ack")
            f.host.shellCode="0";f.ssh.probesAvailable=false
            let result=try f.engine.run(password:testPassword)
            try check(result.identity?.cid == testCID && f.web.restoreCount == 1 && f.host.installerCalls == 1,"Resume does not replay writes")
            try check(f.ssh.authenticationCalls == 2 && f.ssh.commitCalls == 1 && !FileManager.default.fileExists(atPath:f.engine.pending.path),"Resumed install checked and committed")
        }
        run("Agent authentication failure leaves installation pending and uncommitted") {
            let f=try Fixture();defer {f.remove()}
            f.host.fullInstaller=true;f.host.identityMode=true;f.host.deviceList="List of devices attached\nABC device\n"
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            f.ssh.authenticationAccepted=false
            try rejects("не подтвердил вход") {_ = try f.engine.run(password:testPassword)}
            try check(f.ssh.authenticationCalls == 1 && f.ssh.commitCalls == 0 && FileManager.default.fileExists(atPath:f.engine.pending.path),"Failed auth does not commit installation")
        }
        run("Assets hash mismatch stops before web login") {
            let f=try Fixture(); defer {f.remove()}
            try savePrivate(Data("corrupt".utf8),f.resources.appendingPathComponent("Onboarding/zte-agent"))
            try rejects("Повреждён") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.requests.isEmpty && f.host.calls.allSatisfy { $0 == ["devices", "-l"] || $0 == ["-d", "get-serialno"] }, "No actions with corrupt resources")
        }
        run("Existing IMEI transaction and operation lock block onboarding") {
            let f=try Fixture(); defer {f.remove()}
            try savePrivate(Data("pending".utf8),f.root.appendingPathComponent("pending.json"))
            try rejects("незавершённую смену") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.requests.isEmpty, "Pending IMEI guard")
            try FileManager.default.removeItem(at:f.root.appendingPathComponent("pending.json"))
            let fd=open(f.root.appendingPathComponent("operation.lock").path,O_RDWR|O_CREAT,0o600); defer {flock(fd,LOCK_UN);close(fd)}
            try check(fd >= 0 && flock(fd,LOCK_EX|LOCK_NB)==0,"Test lock held")
            try rejects("Другая операция") {_ = try f.engine.run(password:testPassword)}
            try check(f.web.requests.isEmpty,"Concurrent onboarding guard")
        }
        run("Pending onboarding blocks IMEI change and recovery before remote access") {
            let f=try Fixture();defer {f.remove()}
            try savePrivate(Data("pending setup".utf8),f.engine.pending)
            let connection=Connection(host:"192.0.2.1",port:"2222",keyPath:"/synthetic/key",knownHostsPath:"/synthetic/hosts")
            let engine=try ModemEngine(root:f.root,resources:f.resources,connection:connection,transport:f.ssh)
            try rejects("первоначальную настройку") {_ = try engine.begin(targets:[testIMEI,"353490068701230"])}
            try rejects("первоначальную настройку") {_ = try engine.begin(targets:nil,restore:f.root.appendingPathComponent("synthetic-backup"))}
            try check(f.ssh.calls.isEmpty,"No SSH before setup pending guard")
        }
        run("ADB device list ignores offline and unauthorized endpoints") {
            let host=MockHost(); host.deviceList="List of devices attached\nABC device product:x\nDEF unauthorized\nGHI offline\n\n"
            let adb=ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            try check(try adb.devices()==["ABC"],"ADB device selection")
            host.deviceList = "List of devices attached\nUSB device usb:336592896X\nTCP device transport_id:1\nEMPTY device usb:\nDUP device usb:1 usb:2\n"
            try check(try adb.devices(usbOnly: true) == ["USB"], "Unconfirmed physical USB descriptor accepted")
        }
        run("Existing root ADB with CRCRLF completes diagnostic access without enabling or installing again") {
            let f = try Fixture(); defer { f.remove() }
            f.host.shellLineEnding = "\r\r\n"; f.host.identityMode = true
            f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            _ = try f.engine.enableDiagnosticADB(webPassword: testPassword)
            try check(f.web.backupCount == 0 && f.web.directCount == 0 && f.web.restoreCount == 0 && f.web.rebootCount == 0 && f.host.installerCalls == 0 && f.host.pushCount == 0, "Working CRCRLF ADB triggered a mutation")
        }
        run("Legacy ADB zero process exit cannot hide failed remote command") {
            let host=MockHost(),adb=ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            try check(try adb.shell("ABC","printf synthetic") == "synthetic output","Wrapped success")
            host.shellText = "first\r\nsecond\r\n"
            try check(try adb.shell("ABC", "printf lines") == "first\nsecond", "Legacy CRLF normalization")
            host.shellCode="1"
            try rejects("Модем отклонил") {_ = try adb.shell("ABC","false")}
            host.shellCode="0";host.includeMarker=false
            try rejects {_ = try adb.shell("ABC","false")}
            host.includeMarker=true;host.status=1
            try rejects("ADB не выполнил") {_ = try adb.shell("ABC","true")}
        }
        run("ADB result preserves remote exit and payload and rejects ambiguous footer") {
            let marker = "__ZTE_RESULT_00112233445566778899AABBCCDDEEFF__"
            let raw = Data(("  payload\n\n" + marker + "7\n").utf8)
            let result = try ADBClient.decodeShellResult(CommandResult(status: 0, stdout: raw, stderr: Data("warning".utf8)), marker: marker)
            try check(result.status == 7 && result.stdout == Data("  payload\n".utf8) && result.stderr == Data("warning".utf8), "Remote result was lost or trimmed")
            for bad in ["payload", "\n" + marker + "0\n" + marker + "0\n", "\n" + marker + "999\n", "\n" + marker + "0\ntrailing", "\n" + marker + "0"] {
                try rejects { _ = try ADBClient.decodeShellResult(CommandResult(status: 0, stdout: Data(bad.utf8), stderr: Data()), marker: marker) }
            }
        }
        run("ADB ordinary shell errors expose bounded sanitized cause and distinguish local status") {
            let host = MockHost(), adb = ADBClient(binary: URL(fileURLWithPath: "/synthetic/adb"), runner: host)
            host.shellCode = "1"; host.shellText = "mkdir: No such file or directory\npassword=private-value\n" + String(repeating: "x", count: 4000)
            do { _ = try adb.shell("ABC", "mkdir /data/local/tmp/test"); throw TestFailure.check("Unexpected success") }
            catch let failure as TestFailure { throw failure }
            catch { let text = error.localizedDescription; try check(text.contains("удалённый код 1") && text.contains("No such file") && !text.contains("private-value") && text.count < 750, "Error omitted or leaked detail") }
            host.status = 3; host.shellText = "unlabelled-sensitive-value"
            do { _ = try adb.shellResult("ABC", "cat /etc/shadow"); throw TestFailure.check("Unexpected success") }
            catch let failure as TestFailure { throw failure }
            catch { try check(error.localizedDescription.contains("локальный код 3") && !error.localizedDescription.contains("unlabelled-sensitive-value"), "Local result leaked sensitive output") }
        }
        run("Installer profile allows exact B02 only with explicit experimental flag") {
            var object = deviceObject(); object["integrate_version"] = "STD_PL_MU5250V1.0.0B02"; object["wa_inner_version"] = "BD_STDPLMU5250V1.0.0B02"
            let web = try WebIdentity(object, skipFirmwareCheck: true), device = Identity(cid: testCID, firmwareHash: OnboardingEngine.b02FirmwareHash)
            try check(try OnboardingEngine.installerProfile(web: web, device: device, experimental: true) == "b02-experimental", "B02 tuple not recognized")
            try rejects { _ = try OnboardingEngine.installerProfile(web: web, device: device, experimental: false) }
            try rejects { _ = try OnboardingEngine.installerProfile(web: web, device: Identity(cid: testCID, firmwareHash: String(repeating: "0", count: 64)), experimental: true) }
        }
        run("B02 incompatible backup template refuses restore without a firmware-name gate") {
            let f = try Fixture(data:backup(rc:Data("#!/bin/sh\n# no recognized USB code\nexit 0\n".utf8))); defer { f.remove() }
            f.web.info["integrate_version"] = "STD_PL_MU5250V1.0.0B02"; f.web.info["wa_inner_version"] = "BD_STDPLMU5250V1.0.0B02"
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: connection, backupSuffix: testBackupSuffix, web: f.engine.web, runner: f.host, sshFactory: { _ in f.ssh }, researchRunner: MockResearch())
            try rejects("штатный USB-блок") { _ = try manager.run(password: testPassword) }
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.installerCalls == 0, "B02 bootstrap mutated device")
        }
        run("TCP-only B02 ADB cannot substitute for required physical USB") {
            let f = try Fixture(data:backup(rc:Data("#!/bin/sh\n# no recognized USB code\nexit 0\n".utf8))); defer { f.remove() }
            f.web.info["integrate_version"] = "STD_PL_MU5250V1.0.0B02"; f.web.info["wa_inner_version"] = "BD_STDPLMU5250V1.0.0B02"
            f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\n192.0.2.10:5555 device product:MU5250 transport_id:1\n"
            f.host.identityInfo = f.web.info; f.host.identityFirmware = OnboardingEngine.b02FirmwareHash
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: connection, backupSuffix: testBackupSuffix, web: f.engine.web, runner: f.host, sshFactory: { _ in f.ssh }, researchRunner: MockResearch())
            try rejects("штатный USB-блок") { _ = try manager.run(password: testPassword) }
            try check(f.host.calls.allSatisfy { $0 == ["devices", "-l"] } && f.host.pushCount == 0 && f.host.installerCalls == 0 && f.web.restoreCount == 0 && f.web.uploadedData == nil, "TCP-only B02 triggered setup actions")
        }
        run("B02 access setup binds exact hashes and never invokes NV helpers") {
            let f = try Fixture(); defer { f.remove() }
            f.web.info["integrate_version"] = "STD_PL_MU5250V1.0.0B02"; f.web.info["wa_inner_version"] = "BD_STDPLMU5250V1.0.0B02"
            f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\nABC device usb:1-2 transport_id:1\n"
            f.host.identityInfo = f.web.info; f.host.identityFirmware = OnboardingEngine.b02FirmwareHash
            f.ssh.info = f.web.info; f.ssh.firmware = OnboardingEngine.b02FirmwareHash
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: connection, backupSuffix: testBackupSuffix, web: f.engine.web, runner: f.host, sshFactory: { _ in f.ssh }, researchRunner: MockResearch())
            let result = try manager.run(password: testPassword)
            try check(result.state == nil && result.identity?.firmwareHash == OnboardingEngine.b02FirmwareHash && result.firmware.hasSuffix("B02"), "B02 falsely reported NV readiness")
            try check(f.web.restoreCount == 0 && f.web.uploadedData == nil && f.host.installerCalls == 1 && f.ssh.authenticationCalls >= 1 && f.ssh.commitCalls == 1, "Unverified bootstrap or missing access checks")
            try check(!f.ssh.calls.contains { $0.contains("--snapshot") || $0.contains("zte_nv") || $0.contains("zte_config") }, "B02 used NV/EFS helper")
            let repeated = try manager.run(password: testPassword)
            try check(repeated.state == nil && f.host.installerCalls == 1, "Existing B02 access reinstalled or implied NV compatibility")
        }
        run("B02 access reuse rejects a reboot before accepting readiness") {
            let f = try Fixture(); defer { f.remove() }
            f.web.info["integrate_version"] = "STD_PL_MU5250V1.0.0B02"; f.web.info["wa_inner_version"] = "BD_STDPLMU5250V1.0.0B02"
            f.ssh.info = f.web.info; f.ssh.firmware = OnboardingEngine.b02FirmwareHash; f.ssh.ready = true; f.ssh.changeAccessBoot = true
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root: f.root, resources: f.resources, connection: connection, backupSuffix: testBackupSuffix, web: f.engine.web, runner: f.host, sshFactory: { _ in f.ssh }, researchRunner: MockResearch())
            try rejects("сеанс SSH изменились") { _ = try manager.run(password: testPassword) }
            try check(f.ssh.accessProofReads == 2 && f.ssh.commitCalls == 0 && f.host.installerCalls == 0, "Changed boot accepted or mutated")
        }
        run("Read-only installer preflight failure precedes stage and uploads") {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\nABC device\n"; f.host.preflightError = true
            try rejects("PREFLIGHT_TOOL") { _ = try f.engine.run(password: testPassword) }
            try check(f.host.stage.isEmpty && f.host.pushCount == 0 && f.host.installerCalls == 0 && f.web.restoreCount == 0, "Mutation before installer preflight")
        }
        run("Interrupted upload repeats owned preparation and installs once") {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\nABC device\n"; f.host.failPushAt = 2
            f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
            try rejects("interrupted upload") { _ = try f.engine.run(password: testPassword) }
            let priorStage = f.host.stage
            try check(!(try readJSON(AccessSetupJournal.self, f.engine.pending)).installRequested, "Upload interruption falsely marked installer launched")
            f.host.failPushAt = nil
            _ = try f.engine.run(password: testPassword)
            try check(f.host.stage == priorStage && f.host.installerCalls == 1 && f.web.restoreCount == 0, "Retry replayed deployment or chose foreign stage")
        }
        run("ADB identity requires exact firmware web IMEI and valid CID") {
            let host=MockHost(),adb=ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            host.identityMode=true;let expected=try WebIdentity(deviceObject())
            try check(try adb.identity("ABC",expected:expected).cid==testCID,"Verified ADB identity")
            host.identityHashesValid=false;try rejects {_ = try adb.identity("ABC",expected:expected)}
            host.identityHashesValid=true;host.identityIMEI="353490068701230";try rejects {_ = try adb.identity("ABC",expected:expected)}
            host.identityIMEI=testIMEI;host.identityCID="../../other";try rejects {_ = try adb.identity("ABC",expected:expected)}
        }
        run("Firmware override web identity still validates IMEI and preserves version") {
            var object = deviceObject(); object["integrate_version"] = "CN_ZTE_MU5250V1.0.0B32"
            object["wa_inner_version"] = "BD_CNMU5250V1.0.0B32"
            try rejects { _ = try WebIdentity(object) }
            let value = try WebIdentity(object, skipFirmwareCheck: true)
            try check(value.firmware.hasSuffix("B32") && value.inner.hasSuffix("B32"), "Version replaced with B31")
            object["imei"] = "353490068701223"
            try rejects { _ = try WebIdentity(object, skipFirmwareCheck: true) }
        }
        run("Firmware override reaches authenticated onboarding preparation") {
            let f = try Fixture(); defer { f.remove() }
            f.web.info["integrate_version"] = "CN_ZTE_MU5250V1.0.0B32"
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root:f.root, resources:f.resources, connection:connection, backupSuffix:testBackupSuffix, web:f.engine.web, runner:f.host)
            let (identity, _, _) = try manager.prepare(password:testPassword)
            try check(identity.firmware.hasSuffix("B32") && f.web.backupCount == 1 && f.web.restoreCount == 0, "Policy missing from onboarding")
        }
        run("Firmware override ADB permits unknown hash but still matches web device") {
            let host = MockHost(), adb = ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            host.identityMode = true; host.identityHashesValid = false
            let expected = try WebIdentity(deviceObject())
            let result = try adb.identity("ABC", expected: expected, skipFirmwareCheck: true)
            try check(result.firmwareHash == String(repeating:"0",count:64), "Actual ADB hash lost")
            host.identityIMEI = "353490068701230"
            try rejects { _ = try adb.identity("ABC", expected: expected, skipFirmwareCheck: true) }
            host.identityIMEI = testIMEI; host.identityCID = "invalid"
            try rejects { _ = try adb.identity("ABC", expected: expected, skipFirmwareCheck: true) }
        }
        run("Damaged access discriminator refuses before Web backup or USB selection") {
            for missing in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                let id = UUID().uuidString.lowercased()
                let saved = AccessSetupJournal(id: id, cid: testCID, bootID: "01234567-89ab-4cde-8f01-23456789abcd", firmwareHash: ModemEngine.firmwareHash,
                    routerHash: ModemEngine.routerHash, installerProfile: "b31", directory: f.root.appendingPathComponent("SetupBackups/" + id).path, adbSerial: "ABC")
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
                object["intent"] = missing ? nil : "damaged-access"
                try savePrivate(JSONSerialization.data(withJSONObject: object), f.engine.pending)
                try rejects { _ = try f.engine.run(webPassword: testPassword, agentPassword: testPassword) }
                try check(f.web.requests.isEmpty && f.host.calls.isEmpty && f.ssh.calls.isEmpty, "Damaged access discriminator caused a transport call")
            }
        }
        run("Consistent access journal phases retain exact recovery target") {
            let f = try Fixture(); defer { f.remove() }
            let id = UUID().uuidString.lowercased()
            for phase in ["prepared", "install-requested", "ready", "complete"] {
                var saved = AccessSetupJournal(id: id, cid: testCID, bootID: "01234567-89ab-4cde-8f01-23456789abcd", firmwareHash: ModemEngine.firmwareHash,
                    routerHash: ModemEngine.routerHash, installerProfile: "b31", directory: f.root.appendingPathComponent("SetupBackups/" + id).path, adbSerial: "ABC")
                saved.phase = phase; saved.installRequested = phase != "prepared"
                if ["ready", "complete"].contains(phase) { saved.remoteJournal = "/data/local/tmp/zte-imei-installations/" + id }
                try saved.validate(root: f.root)
            }
        }
        run("Inconsistent access recovery journal refuses before any transport") {
            for (phase, requested, remote) in [("ready", false, "exact"), ("prepared", true, "none"), ("install-requested", false, "none"), ("ready", true, "none"), ("complete", true, "foreign"), ("unknown", true, "exact")] {
                let f = try Fixture(); defer { f.remove() }
                let id = UUID().uuidString.lowercased(), directory = f.root.appendingPathComponent("SetupBackups/" + id)
                var saved = AccessSetupJournal(id: id, cid: testCID, bootID: "01234567-89ab-4cde-8f01-23456789abcd", firmwareHash: ModemEngine.firmwareHash,
                    routerHash: ModemEngine.routerHash, installerProfile: "b31", directory: directory.path, adbSerial: "ABC")
                saved.phase = phase; saved.installRequested = requested
                saved.remoteJournal = remote == "none" ? nil : "/data/local/tmp/zte-imei-installations/" + (remote == "exact" ? id : UUID().uuidString.lowercased())
                try saveJSON(saved, f.engine.pending)
                try rejects { _ = try f.engine.run(webPassword: "", agentPassword: testPassword) }
                try check(f.host.calls.isEmpty && f.web.requests.isEmpty && f.ssh.calls.isEmpty, "Inconsistent recovery journal reached a transport")
            }
        }
        run("Unknown root USB firmware installs passive access without web backup NV or override") {
            for missing in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"
                f.host.identityFirmware = missing ? "absent" : String(repeating: "a", count: 64)
                f.host.identityRouter = missing ? "absent" : String(repeating: "b", count: 64)
                f.ssh.firmware = f.host.identityFirmware; f.ssh.accessRouter = f.host.identityRouter
                f.host.onInstall = { [weak host = f.host, weak ssh = f.ssh] in ssh?.ready = true; ssh?.installedJournal = host?.remoteJournal ?? "" }
                let result = try f.engine.run(webPassword: "", agentPassword: testPassword)
                try check(result.state == nil && result.identity?.firmwareHash == f.host.identityFirmware && f.host.installerCalls == 1 && f.ssh.commitCalls == 1, "Unknown access installation incomplete")
                let startup = String(decoding: f.host.uploads[f.host.stage + "/start-agent.sh"]!, as: UTF8.self)
                try check(startup.contains("export ZTE_AGENT_MODE='discovery'") && startup.contains("export ZTE_AGENT_BIND='192.0.2.1:9090'"), "Generic agent not constrained to discovery and selected address")
                try check(f.web.requests.isEmpty && f.web.backupCount == 0 && f.web.restoreCount == 0 && !f.ssh.calls.contains { $0.contains("zte_nv") || $0.contains("--snapshot") || $0.contains("get_imei") }, "Unknown access called Web activation or NV")
                let deploy = f.host.calls.map { $0.joined(separator: " ") }.first { $0.contains("(sh '") && $0.contains("/setup-agent.sh'") }!
                try check(deploy.contains("'linux-arm64-access'") && deploy.contains("'01234567-89ab-4cde-8f01-23456789abcd'"), "Generic installer lost boot binding")
                try check(f.host.uploads[f.host.stage + "/zte-timeout"].map(digest) == ModemHostTools.timeoutHash, "Generic installer did not receive verified timeout helper")
            }
        }
        run("Generic timeout resource corruption refuses before preflight or staging") {
            let f = try Fixture(); defer { f.remove() }
            f.host.identityMode = true; f.host.fullInstaller = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n"
            f.host.identityFirmware = String(repeating: "a", count: 64); f.host.identityRouter = String(repeating: "b", count: 64)
            try savePrivate(Data("UNTRUSTED-TIMEOUT".utf8), f.resources.appendingPathComponent("HostTools/zte-timeout"))
            try rejects { _ = try f.engine.run(webPassword: "", agentPassword: testPassword) }
            try check(f.host.pushCount == 0 && f.host.installerCalls == 0 && !f.host.calls.contains { $0.joined().contains("--preflight") }, "Corrupt timeout reached installation preflight")
            try check(f.web.requests.isEmpty && !FileManager.default.fileExists(atPath: f.engine.pending.path), "Corrupt resource activated Web or saved install intent")
        }
        run("Non-root USB and ambiguous USB never fall through to activation") {
            for ambiguous in [false, true] {
                let f = try Fixture(); defer { f.remove() }
                f.host.identityMode = true; f.host.deviceList = "List of devices attached\nABC device usb:1\n" + (ambiguous ? "DEF device usb:2\n" : "")
                if !ambiguous { f.host.shellCode = "1" }
                try rejects { _ = try f.engine.run(webPassword: "", agentPassword: testPassword) }
                try check(f.web.requests.isEmpty && f.host.pushCount == 0 && f.host.installerCalls == 0, "Unproven root USB led to activation or installation")
            }
        }
        run("Discovery startup rejects missing noncanonical or injected IPv4") {
            for host in [nil, "0.0.0.0", "255.255.255.255", "192.168.00.1", "192.0.2.1;id", "example.com", "::1"] as [String?] {
                try rejects { _ = try OnboardingEngine.agentStartup(password: testPassword, discovery: true, discoveryHost: host) }
            }
            let normal = String(decoding: try OnboardingEngine.agentStartup(password: testPassword), as: UTF8.self)
            try check(!normal.contains("ZTE_AGENT_MODE") && !normal.contains("ZTE_AGENT_BIND"), "Legacy startup was changed")
        }
        run("Agent password is shell-quoted without command-line interpolation") {
            let password="a'$(touch /tmp/not-executed)\nsecret"
            let script=String(decoding:try OnboardingEngine.agentStartup(password:password),as:UTF8.self)
            try check(script.contains("export ZTE_AGENT_PASSWORD="+shellQuote(password)+"\n"),"Literal shell quoting")
            try check(!script.contains("--password"),"Password is not passed to agent argv")
        }
        print("Onboarding tests: \(passed) passed, \(failed) failed")
        let cwd=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let project=FileManager.default.fileExists(atPath:cwd.appendingPathComponent("Sources/Onboarding.swift").path) ? cwd : cwd.appendingPathComponent("MacIMEI")
        var hashes=[String:String]()
        for path in ["Sources/Domain.swift","Sources/Engine.swift","Sources/BackupPatch.swift","Sources/ModemWeb.swift","Sources/Onboarding.swift","Tests/OnboardingTests.swift"] {
            if let data=try? Data(contentsOf:project.appendingPathComponent(path)) {hashes[path]=digest(data)}
        }
        let report:[String:Any]=["passed":passed,"failed":failed,"tests":results,"sourceSHA256":hashes,"network":"mock only","processes":"mock only","deviceWrites":false]
        try secureDirectory(project.appendingPathComponent(".build"))
        try savePrivate(JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),project.appendingPathComponent(".build/onboarding-test-results.json"))
        if failed > 0 {exit(1)}
    }
}
