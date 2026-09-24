import Foundation
private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func reject(_ body: () throws -> Void) throws { do { try body() } catch is IMEIError { return }; throw Failure.assertion("Expected refusal") }
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601"
private let emptyAccounts = "SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING 0\nSSH_USERS_LISTENER 0\n"
private func report(_ running: Bool = true) -> String {
    "ACCESS_SCHEMA 1\nACCESS_SERVICE stockWeb running readonly\nACCESS_SERVICE dashboard running control\nACCESS_SERVICE agent \(running ? "running" : "stopped") control\nACCESS_SERVICE managementSSH running protected\nACCESS_SERVICE userSSH unavailable readonly\nACCESS_SERVICE adb running readonly\n"
}
private final class Mock: RemoteTransport {
    var commands = [String](), uploaded = [String:Data](), running = true, corrupt = false, failAction = false, deleted = false
    var accountExists = false, pending = false, actionCount = 0
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        func output(_ text: String) -> CommandResult { CommandResult(status:0,stdout:Data(text.utf8),stderr:Data()) }
        if command.hasPrefix("sha256sum /firmware") { return output(ModemEngine.firmwareHash+" /firmware/image/modem.b16\n"+ModemEngine.routerHash+" /usr/bin/diag-router\n"+cid+"\n"+boot+"\n") }
        if command.hasPrefix("sh -s -- status") { try check(input != nil,"Missing read-only script");return output(report(running)) }
        if command.contains("SSH_USERS_SCHEMA") {
            if accountExists && !deleted { return output("SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING \(pending ? "1":"0")\nSSH_ACCOUNT modemadmin 50000 /data/zte-imei-admin/homes/modemadmin 1\nSSH_USERS_LISTENER 1\n") }
            return output(emptyAccounts)
        }
        if command.hasPrefix("umask 077; cat >") {
            let path=command.components(separatedBy:"'")[1];uploaded[path]=input!
            return output((corrupt ? "bad" : digest(input!))+" "+path+"\n")
        }
        if command.hasPrefix("sh '/tmp/zte-access-") {
            actionCount += 1
            if failAction { return CommandResult(status:1,stdout:Data(),stderr:Data("ACCESS_ERROR START\n".utf8)) }
            running = !command.contains(" agent stop ");return output(report(running))
        }
        if command.hasPrefix("sh '/tmp/zte-ssh-users-") {
            try check(input == nil,"Delete must have no password payload");deleted=true;return output("SSH_USERS_DELETED modemadmin archive journal\n")
        }
        if command.hasPrefix("test -d '") && command.contains("tar -C") { return output("private snapshot") }
        if command.contains("zte-imei-app.lock") || command.hasPrefix("umask 077; mkdir '") || command.hasPrefix("rm -f '") {return output("")}
        throw Failure.assertion("Unexpected command "+command)
    }
}
@main enum AccessManagementTests {
    static func main() throws {
        var passed=0
        func test(_ name: String,_ body: () throws -> Void) throws { try body();passed += 1;print("PASS "+name) }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("zte-access-tests-"+UUID().uuidString)
        try secureDirectory(root);defer{try? FileManager.default.removeItem(at:root)}
        let resources=root.appendingPathComponent("Resources"),assets=resources.appendingPathComponent("SSHAccounts");try secureDirectory(assets)
        var hashes=[String:String]()
        for name in ["access-services.sh","delete-ssh-user.sh"] { let data=Data(("fixture "+name).utf8);try savePrivate(data,assets.appendingPathComponent(name));hashes[name]=digest(data) }
        try saveJSON(hashes,assets.appendingPathComponent("SHA256.json"))
        let connection=Connection(host:"192.168.0.1",port:"2222",keyPath:"/dev/null",knownHostsPath:"/dev/null")
        func manager(_ mock: Mock) throws -> AccessManager { try AccessManager(root:root.appendingPathComponent(UUID().uuidString),resources:resources,connection:connection,transport:mock) }
        try test("Parse all service capabilities with protected management channel") {
            let states=try AccessManager.parseServices(report(),host:connection.host)
            try check(states.count == 6,"Six services");try check(states.first{$0.id == .managementSSH}!.allowedActions.isEmpty,"Reserved endpoint")
            try check(states.first{$0.id == .agent}!.allowedActions == [.stop,.restart],"Actions")
            try check(states.first{$0.id == .dashboard}!.credentialModel.contains("Одна"),"No fake per-user web accounts")
        }
        try test("Parser refuses missing duplicate and unknown service records") {
            for value in ["",report()+"ACCESS_SERVICE agent running control\n",report().replacingOccurrences(of:"agent running",with:"foreign running"),report().replacingOccurrences(of:"ACCESS_SERVICE adb running readonly\n",with:"")] {
                try reject { _=try AccessManager.parseServices(value,host:connection.host) }
            }
        }
        try test("Parser rejects mutating protected and stock capabilities") {
            for value in [report().replacingOccurrences(of:"managementSSH running protected",with:"managementSSH running control"),report().replacingOccurrences(of:"stockWeb running readonly",with:"stockWeb running control"),report().replacingOccurrences(of:"agent running control",with:"agent unknown control")] {
                try reject { _=try AccessManager.parseServices(value,host:connection.host) }
            }
        }
        try test("Inspect is read-only and reports account state") {
            let mock=Mock();let state=try manager(mock).inspect();try check(state.services.count == 6 && mock.uploaded.isEmpty && mock.actionCount == 0,"Inspect mutation")
        }
        try test("Protected service rejected before any transport command") {
            let mock=Mock();try reject {_=try manager(mock).perform(service:.managementSSH,action:.stop)};try check(mock.commands.isEmpty,"Protected remote call")
        }
        try test("Action verifies upload and resulting service status") {
            let mock=Mock();let state=try manager(mock).perform(service:.agent,action:.stop)
            try check(state.services.first{$0.id == .agent}!.state == .stopped && mock.actionCount == 1,"Stop incomplete")
        }
        try test("Corrupt upload never reaches service action") {
            let mock=Mock();mock.corrupt=true;try reject {_=try manager(mock).perform(service:.agent,action:.stop)};try check(mock.actionCount == 0,"Corrupt payload executed")
        }
        try test("Failed service action does not report success") {
            let mock=Mock();mock.failAction=true;try reject {_=try manager(mock).perform(service:.agent,action:.stop)}
        }
        try test("Recovery kind distinguishes deletion from older creation and unknown journals") {
            let pending="SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING 1\nSSH_USERS_LISTENER 0\n"
            try check(try SSHAccountManager.parseState(pending).recoveryKind == .unknown,"Legacy pending must not enable delete recovery")
            try check(try SSHAccountManager.parseState(emptyAccounts).recoveryKind == .none,"Legacy idle")
            for kind in [SSHAccountRecoveryKind.create, .delete, .unknown] {
                try check(try SSHAccountManager.parseState(pending+"SSH_USERS_RECOVERY \(kind.rawValue)\n").recoveryKind == kind,"Recovery kind")
            }
            for text in [pending+"SSH_USERS_RECOVERY none\n",emptyAccounts+"SSH_USERS_RECOVERY delete\n",pending+"SSH_USERS_RECOVERY delete\nSSH_USERS_RECOVERY delete\n"] { try reject {_=try SSHAccountManager.parseState(text)} }
        }
        try test("Deletion keeps backup and sends no password") {
            let mock=Mock();mock.accountExists=true
            let service=try SSHAccountManager(root:root.appendingPathComponent(UUID().uuidString),resources:resources,connection:connection,transport:mock)
            let result=try service.delete(username:"modemadmin");try check(result.accounts.isEmpty && mock.deleted,"Delete incomplete")
            let files=FileManager.default.enumerator(at:service.root,includingPropertiesForKeys:nil)!.compactMap{$0 as? URL}
            try check(files.contains{$0.lastPathComponent == "settings-before.tar"},"Delete backup missing")
        }
        try test("Deletion rejects system and missing users before upload") {
            let mock=Mock();let service=try SSHAccountManager(root:root.appendingPathComponent(UUID().uuidString),resources:resources,connection:connection,transport:mock)
            try reject {_=try service.delete(username:"root")};try reject {_=try service.delete(username:"modemadmin")};try check(mock.uploaded.isEmpty,"Unexpected delete upload")
        }
        try test("Pending account transaction blocks new deletion") {
            let mock=Mock();mock.accountExists=true;mock.pending=true
            let service=try SSHAccountManager(root:root.appendingPathComponent(UUID().uuidString),resources:resources,connection:connection,transport:mock)
            try reject {_=try service.delete(username:"modemadmin")};try check(mock.uploaded.isEmpty,"Pending delete uploaded")
        }
        print("\(passed) access-management tests passed")
    }
}
