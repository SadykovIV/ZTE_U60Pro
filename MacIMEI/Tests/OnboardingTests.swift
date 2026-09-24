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

private let testIMEI = "490154203237518"
private let testCID = "0123456789abcdef0123456789abcdef"
private let testSuffix = "synthetic-backup-suffix"
private let testPassword = "test-password"
// SHA-256 of the synthetic test password/challenge, never a device credential.
private let expectedPasswordHash = "C2682E16F0B2C76CE55C4998EA7914050AF4CFAF82510D405CEB2AF9B74B4FB5" // gitleaks:allow
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
private func backup(suffix: String = testSuffix) throws -> Data {
    let inner = try BackupGzip.compress(tar([("etc/rc.local",Data("#!/bin/sh\ncat /sys/class/android_usb/android0/usb_op\nexit 0\n".utf8))]))
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
    var restoreCount = 0, backupCount = 0, outerError: Int?, challenge = "salt-0123"
    init(_ data: Data) { backupData = data }
    func request(path: String, data: Data?, contentType: String?, cookie: String?) throws -> WebReply {
        requests.append(Request(path:path,data:data,cookie:cookie))
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
        let params = payload[0]["params"] as! [Any], method = params[2] as! String
        methods.append(method)
        var result = [String:Any](), headers = [String:String]()
        switch method {
        case "web_login_info":
            try check(params[0] as? String == String(repeating:"0",count:32) && cookie == nil, "Challenge starts without credentials")
            result = ["zte_web_sault":challenge]
        case "web_login":
            loginArguments = params[3] as! [String:Any]
            result = ["result":accepted ? 0 : 1,"ubus_rpc_session":session]
            headers["set-cookie"] = cookieHeader
        case "device_info":
            try check(params[0] as? String == sessionID && cookie == "test-cookie", "Authenticated identity")
            identityCalls += 1; result = info
            if let n = identityChangeAfter, identityCalls >= n { result["imei"] = "490154203237526" }
        case "device_backup_proc": backupCount += 1
        case "device_restore_proc": restoreCount += 1
        default: throw TestFailure.check("Unexpected RPC: \(method)")
        }
        return WebReply(data:try JSONSerialization.data(withJSONObject:[["jsonrpc":"2.0","id":1,"result":[outerError ?? 0,result]]]),headers:headers)
    }
}

/// Never invokes Process. The marker is taken from the actual generated wrapper.
private final class MockHost: HostCommandRunner {
    var calls = [[String]]()
    var status: Int32 = 0, shellCode = "0", includeMarker = true, shellText = "synthetic output"
    var deviceList = "List of devices attached\n", identityCID = testCID, identityIMEI = testIMEI
    var deviceListSequence = [String](), identityCIDSequence = [String]()
    var identityHashesValid = true, identityMode = false
    var fullInstaller = false, installed = false, loseInstallAcknowledgement = false
    var installerCalls = 0, stage = "", remoteJournal = "", uploads = [String:Data]()
    var onInstall: (() -> Void)?
    private func quoted(_ text: String) throws -> [String] {
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
        if arguments == ["devices","-l"] { value = deviceListSequence.isEmpty ? deviceList : deviceListSequence.removeFirst() }
        else if fullInstaller && arguments.count == 5 && arguments[2] == "push" {
            let path=arguments[4];try check(path.hasPrefix(stage+"/"),"Upload only owned stage")
            uploads[path]=try Data(contentsOf:URL(fileURLWithPath:arguments[3]));value="1 file pushed"
        }
        else if arguments.count == 4 && arguments[2] == "shell" {
            let command = arguments[3]
            let regex = try NSRegularExpression(pattern:"__ZTE_RESULT_[A-F0-9]+__")
            guard let match = regex.firstMatch(in:command,range:NSRange(command.startIndex...,in:command)), let range = Range(match.range,in:command) else { throw TestFailure.check("Missing shell exit wrapper") }
            value = shellText
            if identityMode && command.contains("sha256sum /firmware/image/modem.b16") {
                let info = String(data:try JSONSerialization.data(withJSONObject:deviceObject(identityIMEI),options:.sortedKeys),encoding:.utf8)!
                let cid = identityCIDSequence.isEmpty ? identityCID : identityCIDSequence.removeFirst()
                value = (identityHashesValid ? ModemEngine.firmwareHash : String(repeating:"0",count:64)) + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + cid + "\n" + info
            } else if fullInstaller {
                if command.hasPrefix("(umask 077; mkdir ") {
                    stage=try quoted(command)[0];try check(stage.hasPrefix("/data/local/tmp/zte-imei-setup-"),"Owned staging path");value=""
                } else if command.hasPrefix("(set -e; chmod 600 ") {
                    let path=try quoted(command)[0];guard let data=uploads[path] else {throw TestFailure.check("Hash check without upload")}
                    value=digest(data)+"  "+path
                } else if command.hasPrefix("(sh '") && command.contains("/setup-agent.sh'") {
                    let args=try quoted(command)
                    try check(args.count >= 6 && args[0] == stage+"/setup-agent.sh" && args[1] == stage && args[2] == testCID,"Exact installer invocation and CID")
                    for name in ["zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh","id_ed25519.pub","start-agent.sh"] {try check(uploads[stage+"/"+name] != nil,"Missing staged asset")}
                    try check(args[3] == digest(uploads[stage+"/zte-agent"]!) && args[4] == digest(uploads[stage+"/dropbear"]!) && args[5] == digest(uploads[stage+"/id_ed25519.pub"]!),"Installer hashes")
                    try check(!command.contains(testPassword),"Password absent from installer argv")
                    installerCalls += 1;installed=true;remoteJournal="/data/local/tmp/zte-imei-installations/"+String(stage.split(separator:"/").last!.dropFirst("zte-imei-setup-".count));onInstall?()
                    value="INSTALL_AGENT new\nINSTALL_READY "+remoteJournal
                    if loseInstallAcknowledgement {value="INSTALL_INCOMPLETE "+remoteJournal;shellCode="1";loseInstallAcknowledgement=false}
                } else if command.hasPrefix("(/data/bin/dropbearkey -y ") {
                    let key=Data([0,0,0,11])+Data("ssh-ed25519".utf8)+Data([0,0,0,32])+Data(repeating:0x33,count:32)
                    value="Public key portion is:\nssh-ed25519 "+key.base64EncodedString()+" synthetic"
                } else if command.hasPrefix("(cat '") && command.contains("/state'") {value=installed ? "ready" : "pending"}
                else if command.hasPrefix("(rm -f ") {value=""}
                else {throw TestFailure.check("Unexpected full installer shell: "+command)}
            }
            if includeMarker { value += "\r\n" + command[range] + shellCode + "\r\n" }
        } else { throw TestFailure.check("Unexpected host command: \(arguments)") }
        return CommandResult(status:status,stdout:Data(value.utf8),stderr:Data())
    }
}

private final class UnavailableSSH: RemoteTransport {
    var calls = [String]()
    var ready=false, probesAvailable=true, authenticationAccepted=true, authenticationCalls=0, commitCalls=0
    var installedJournal="",uploads=[String:Data](),malformedSnapshot=false
    private func output(_ value: String, status: Int32 = 0) -> CommandResult {CommandResult(status:status,stdout:Data(value.utf8),stderr:Data())}
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        calls.append(command)
        if !ready {throw IMEIError.message("Synthetic SSH unavailable")}
        if command.contains("printf ZTE_AGENT_PRESENT") {return probesAvailable ? output("ZTE_AGENT_PRESENT") : output("",status:1)}
        if command.hasPrefix("sha256sum /firmware/image/modem.b16 ") {return output(ModemEngine.firmwareHash+"  /firmware/image/modem.b16\n"+ModemEngine.routerHash+"  /usr/bin/diag-router\n"+testCID+"\n01234567-89ab-4cde-8f01-23456789abcd\n")}
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
            first.replaceSubrange(0..<9,with:[0x08, 0x4a, 0x09, 0x51, 0x24, 0x30, 0x32, 0x57, 0x81])
            second.replaceSubrange(0..<9,with:[0x08, 0x4a, 0x09, 0x51, 0x24, 0x30, 0x32, 0x57, 0x62])
            return output("APP_NV index=0 data="+first.hex+"\nAPP_NV index=1 data="+second.hex+"\n")
        }
        if command.hasPrefix("ubus call zwrt_zte_mdm.api get_imei") {return output("{\"imei\":\""+(command.hasSuffix("get_imei2") ? "490154203237526" : testIMEI)+"\"}")}
        if command.contains("printf AGENT_READY") {return output("AGENT_READY")}
        if command.contains("/present/data_zte-agent") {return output("NEW")}
        if command.hasPrefix("/usr/bin/curl ") {
            let body=try JSONSerialization.jsonObject(with:input!) as! [String:Any]
            try check(body["password"] as? String == testPassword && !command.contains(testPassword),"Agent credentials passed only through stdin")
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
        for name in ["adb","zte-agent","dropbear","setup-agent.sh","start_zte_imei_studio.sh"] {
            let content = Data(("SYNTHETIC-"+name).utf8); try savePrivate(content,assets.appendingPathComponent(name)); hashes[name]=digest(content)
        }
        try saveJSON(hashes,assets.appendingPathComponent("SHA256.json"))
        let helper=Data("SYNTHETIC-zte_nv".utf8);try savePrivate(helper,resources.appendingPathComponent("zte_nv"));try saveJSON(["zte_nv":digest(helper)],resources.appendingPathComponent("helpers.json"))
        web = MockWeb(try data ?? backup()); host = MockHost(); ssh = UnavailableSSH()
        let connection = Connection(host:"192.0.2.1",port:"2222",keyPath:root.appendingPathComponent("absent-key").path,knownHostsPath:root.appendingPathComponent("absent-hosts").path)
        let client = try ModemWebClient(host:connection.host,transport:web)
        let injectedSSH = ssh
        engine = try OnboardingEngine(root:root,resources:resources,connection:connection,web:client,runner:host,sshFactory:{_ in injectedSSH})
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
        run("Public build requires a supplied backup suffix before any web request") {
            let f = try Fixture(); defer { f.remove() }
            try rejects("Введите ключ") { _ = try f.engine.prepare(password:testPassword, backupSuffix:"") }
            try check(f.web.requests.isEmpty, "Blank suffix caused network activity")
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
            try rejects("Вход отклонён") { _ = try f.engine.run(password:testPassword, backupSuffix:testSuffix) }
            try check(f.web.methods == ["web_login_info","web_login"] && f.host.calls.isEmpty && f.ssh.calls.isEmpty, "No further action")
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
        run("Wrong firmware and invalid web IMEI stop before fresh backup") {
            for choice in 0..<2 {
                let f=try Fixture(); defer {f.remove()}
                if choice == 0 {f.web.info["integrate_version"]="CN_ZTE_MU5250V1.0.0B32"}
                else {f.web.info["imei"]="490154203237519"}
                try rejects {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
                try check(f.web.backupCount == 0 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.isEmpty, "Unknown identity cannot progress")
            }
        }
        run("Fresh backup preparation verifies suffix and saves originals privately") {
            let f=try Fixture(); defer {f.remove()}
            let (identity,result,directory)=try f.engine.prepare(password:testPassword, backupSuffix:testSuffix)
            try check(identity.imei == testIMEI && !result.alreadyEnabled && f.web.backupCount == 1, "Prepared fresh backup")
            try check(try Data(contentsOf:directory.appendingPathComponent("back_parameter.original")) == f.web.backupData, "Exact encrypted original")
            let permissions = try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("back_parameter.original").path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o600 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.isEmpty, "Prepare cannot mutate device")
        }
        run("Malformed encrypted backup never uploads or restores") {
            let f=try Fixture(data:Data("not an encrypted backup".utf8)); defer {f.remove()}
            try rejects {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.backupCount == 1 && f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.isEmpty, "Malformed archive blocks mutation")
        }
        run("Incorrect suffix cannot pass archive verification or upload") {
            let f=try Fixture(data:backup(suffix:"synthetic-wrong-suffix")); defer {f.remove()}
            try rejects {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.isEmpty, "Unverified suffix blocks mutation")
        }
        run("Identity change while obtaining backup blocks patch upload") {
            let f=try Fixture(); defer {f.remove()}; f.web.identityChangeAfter=2
            try rejects("Устройство изменилось") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0, "Identity rechecked after backup")
        }
        run("Upload SHA mismatch blocks restore and preserves pending intent") {
            let f=try Fixture(); defer {f.remove()}; f.web.badUploadHash=true
            try rejects("SHA256") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.uploadedData != nil && f.web.restoreCount == 0, "No restore after bad upload digest")
            let journal = try readJSON(SetupJournal.self,f.engine.pending)
            try check(!journal.restoreRequested && !journal.installRequested, "No false restore/install claim")
            _ = try BackupPatch.inspect(BackupCipher.decrypt(f.web.uploadedData!,password:testIMEI+testSuffix))
            try check(f.host.calls == [["devices","-l"]], "No installation commands")
        }
        run("Identity change after upload blocks restore") {
            let f=try Fixture(); defer {f.remove()}; f.web.identityChangeAfter=4
            try rejects("Устройство изменилось") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.uploadedData != nil && f.web.restoreCount == 0, "Restore requires final identity check")
        }
        run("Retry before restore pairs new candidate with its own fresh original") {
            let f=try Fixture(); defer {f.remove()}; f.web.badUploadHash=true
            let oldOriginal=f.web.backupData
            try rejects("SHA256") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            let first=try readJSON(SetupJournal.self,f.engine.pending)
            f.web.backupData=try backup()
            try rejects("SHA256") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
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
            try rejects("прервалась до готовности") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
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
            try rejects("CID отличается") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(!f.host.calls.contains {$0.contains("push") || $0.contains("-q") || $0.joined().contains("mkdir")},"No writes to mismatched CID")
        }
        run("CID change immediately before staging blocks every device write") {
            let f=try Fixture();defer {f.remove()}
            f.host.deviceList="List of devices attached\nABC device\n";f.host.identityMode=true
            f.host.identityCIDSequence=[testCID,String(repeating:"a",count:32)]
            try rejects("CID изменился перед передачей") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(!f.host.calls.contains {$0.contains("push") || $0.joined().contains("mkdir")},"No stage creation/push after identity changed")
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0,"Existing ADB skips web restore")
        }
        run("Full virgin setup verifies backup restore ADB install pin SSH authentication and commit") {
            let f=try Fixture();defer {f.remove()}
            f.host.fullInstaller=true;f.host.identityMode=true;f.host.deviceList="List of devices attached\nABC device\n"
            f.host.deviceListSequence=["List of devices attached\n",f.host.deviceList]
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            let result=try f.engine.run(password:testPassword, backupSuffix:testSuffix)
            try check(result.state.imeis == [testIMEI,"490154203237526"] && result.state.identity.cid == testCID,"Final verified modem state")
            try check(f.web.backupCount == 1 && f.web.restoreCount == 1 && f.host.installerCalls == 1,"Backup and restore/install exactly once")
            try check(f.ssh.authenticationCalls == 1 && f.ssh.commitCalls == 1,"New agent authenticated before commit")
            try check(!FileManager.default.fileExists(atPath:f.engine.pending.path),"Completed setup clears pending journal")
            let known=try String(contentsOfFile:result.connection.knownHostsPath,encoding:.utf8)
            try check(known.hasPrefix("[192.0.2.1]:2222 ssh-ed25519 "),"Host key pinned from verified USB identity")
            let directory=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("SetupBackups"),includingPropertiesForKeys:nil).first!
            let journal=try readJSON(SetupJournal.self,directory.appendingPathComponent("setup-result.json"))
            try check(journal.phase == "complete" && journal.restoreRequested && journal.installRequested,"Durable complete record")
        }
        run("Existing SSH agent fast path does not upload restore or install") {
            let f=try Fixture();defer {f.remove()};f.ssh.ready=true
            let result=try f.engine.run(password:testPassword, backupSuffix:testSuffix)
            try check(result.state.identity.cid == testCID && result.state.imeis == [testIMEI,"490154203237526"],"Existing pair verified via NV and API")
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.isEmpty,"No ADB/bootstrap mutations on existing access")
            try check(f.ssh.authenticationCalls == 0 && f.ssh.commitCalls == 0,"Existing credentials are preserved")
        }
        run("Existing SSH NV verification error cannot fall through to reinstall") {
            let f=try Fixture();defer {f.remove()};f.ssh.ready=true;f.ssh.malformedSnapshot=true
            try rejects {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.uploadedData == nil && f.web.restoreCount == 0 && f.host.calls.isEmpty,"Read validation error stays an error")
        }
        run("Lost installer acknowledgement resumes ready journal without restore or installer replay") {
            let f=try Fixture();defer {f.remove()}
            f.host.fullInstaller=true;f.host.identityMode=true;f.host.deviceList="List of devices attached\nABC device\n"
            f.host.deviceListSequence=["List of devices attached\n",f.host.deviceList]
            f.host.loseInstallAcknowledgement=true
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            try rejects("Модем отклонил") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            let pending=try readJSON(SetupJournal.self,f.engine.pending)
            try check(pending.installRequested && pending.restoreRequested && pending.phase == "install-requested","Intent persisted before lost ack")
            f.host.shellCode="0";f.ssh.probesAvailable=false
            let result=try f.engine.run(password:testPassword, backupSuffix:testSuffix)
            try check(result.state.identity.cid == testCID && f.web.restoreCount == 1 && f.host.installerCalls == 1,"Resume does not replay writes")
            try check(f.ssh.authenticationCalls == 1 && f.ssh.commitCalls == 1 && !FileManager.default.fileExists(atPath:f.engine.pending.path),"Resumed install checked and committed")
        }
        run("Agent authentication failure leaves installation pending and uncommitted") {
            let f=try Fixture();defer {f.remove()}
            f.host.fullInstaller=true;f.host.identityMode=true;f.host.deviceList="List of devices attached\nABC device\n"
            f.host.onInstall={ [weak host=f.host,weak ssh=f.ssh] in ssh?.ready=true;ssh?.installedJournal=host?.remoteJournal ?? "" }
            f.ssh.authenticationAccepted=false
            try rejects("не подтвердил вход") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.ssh.authenticationCalls == 1 && f.ssh.commitCalls == 0 && FileManager.default.fileExists(atPath:f.engine.pending.path),"Failed auth does not commit installation")
        }
        run("Assets hash mismatch stops before web login") {
            let f=try Fixture(); defer {f.remove()}
            try savePrivate(Data("corrupt".utf8),f.resources.appendingPathComponent("Onboarding/zte-agent"))
            try rejects("Повреждён") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.requests.isEmpty && f.host.calls.isEmpty, "No actions with corrupt resources")
        }
        run("Existing IMEI transaction and operation lock block onboarding") {
            let f=try Fixture(); defer {f.remove()}
            try savePrivate(Data("pending".utf8),f.root.appendingPathComponent("pending.json"))
            try rejects("незавершённую смену") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.requests.isEmpty, "Pending IMEI guard")
            try FileManager.default.removeItem(at:f.root.appendingPathComponent("pending.json"))
            let fd=open(f.root.appendingPathComponent("operation.lock").path,O_RDWR|O_CREAT,0o600); defer {flock(fd,LOCK_UN);close(fd)}
            try check(fd >= 0 && flock(fd,LOCK_EX|LOCK_NB)==0,"Test lock held")
            try rejects("Другая операция") {_ = try f.engine.run(password:testPassword, backupSuffix:testSuffix)}
            try check(f.web.requests.isEmpty,"Concurrent onboarding guard")
        }
        run("Pending onboarding blocks IMEI change and recovery before remote access") {
            let f=try Fixture();defer {f.remove()}
            try savePrivate(Data("pending setup".utf8),f.engine.pending)
            let connection=Connection(host:"192.0.2.1",port:"2222",keyPath:"/synthetic/key",knownHostsPath:"/synthetic/hosts")
            let engine=try ModemEngine(root:f.root,resources:f.resources,connection:connection,transport:f.ssh)
            try rejects("первоначальную настройку") {_ = try engine.begin(targets:[testIMEI,"490154203237526"])}
            try rejects("первоначальную настройку") {_ = try engine.begin(targets:nil,restore:f.root.appendingPathComponent("synthetic-backup"))}
            try check(f.ssh.calls.isEmpty,"No SSH before setup pending guard")
        }
        run("ADB device list ignores offline and unauthorized endpoints") {
            let host=MockHost(); host.deviceList="List of devices attached\nABC device product:x\nDEF unauthorized\nGHI offline\n\n"
            let adb=ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            try check(try adb.devices()==["ABC"],"ADB device selection")
        }
        run("Legacy ADB zero process exit cannot hide failed remote command") {
            let host=MockHost(),adb=ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            try check(try adb.shell("ABC","printf synthetic") == "synthetic output","Wrapped success")
            host.shellCode="1"
            try rejects("Модем отклонил") {_ = try adb.shell("ABC","false")}
            host.shellCode="0";host.includeMarker=false
            try rejects {_ = try adb.shell("ABC","false")}
            host.includeMarker=true;host.status=1
            try rejects("ADB не выполнил") {_ = try adb.shell("ABC","true")}
        }
        run("ADB identity requires exact firmware web IMEI and valid CID") {
            let host=MockHost(),adb=ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            host.identityMode=true;let expected=try WebIdentity(deviceObject())
            try check(try adb.identity("ABC",expected:expected).cid==testCID,"Verified ADB identity")
            host.identityHashesValid=false;try rejects {_ = try adb.identity("ABC",expected:expected)}
            host.identityHashesValid=true;host.identityIMEI="490154203237526";try rejects {_ = try adb.identity("ABC",expected:expected)}
            host.identityIMEI=testIMEI;host.identityCID="../../other";try rejects {_ = try adb.identity("ABC",expected:expected)}
        }
        run("Firmware override web identity still validates IMEI and preserves version") {
            var object = deviceObject(); object["integrate_version"] = "CN_ZTE_MU5250V1.0.0B32"
            object["wa_inner_version"] = "BD_CNMU5250V1.0.0B32"
            try rejects { _ = try WebIdentity(object) }
            let value = try WebIdentity(object, skipFirmwareCheck: true)
            try check(value.firmware.hasSuffix("B32") && value.inner.hasSuffix("B32"), "Version replaced with B31")
            object["imei"] = "490154203237519"
            try rejects { _ = try WebIdentity(object, skipFirmwareCheck: true) }
        }
        run("Firmware override reaches authenticated onboarding preparation") {
            let f = try Fixture(); defer { f.remove() }
            f.web.info["integrate_version"] = "CN_ZTE_MU5250V1.0.0B32"
            var connection = f.engine.currentConnection; connection.skipFirmwareCheck = true
            let manager = try OnboardingEngine(root:f.root, resources:f.resources, connection:connection, web:f.engine.web, runner:f.host)
            let (identity, _, _) = try manager.prepare(password:testPassword, backupSuffix:testSuffix)
            try check(identity.firmware.hasSuffix("B32") && f.web.backupCount == 1 && f.web.restoreCount == 0, "Policy missing from onboarding")
        }
        run("Firmware override ADB permits unknown hash but still matches web device") {
            let host = MockHost(), adb = ADBClient(binary:URL(fileURLWithPath:"/synthetic/adb"),runner:host)
            host.identityMode = true; host.identityHashesValid = false
            let expected = try WebIdentity(deviceObject())
            let result = try adb.identity("ABC", expected: expected, skipFirmwareCheck: true)
            try check(result.firmwareHash == String(repeating:"0",count:64), "Actual ADB hash lost")
            host.identityIMEI = "490154203237526"
            try rejects { _ = try adb.identity("ABC", expected: expected, skipFirmwareCheck: true) }
            host.identityIMEI = testIMEI; host.identityCID = "invalid"
            try rejects { _ = try adb.identity("ABC", expected: expected, skipFirmwareCheck: true) }
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
