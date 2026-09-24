import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ flag: @autoclosure () throws -> Bool, _ text: String) throws { if try !flag() { throw Failure.assertion(text) } }
private func reject(_ body: () throws -> Void) throws { do { try body() } catch is IMEIError { return }; throw Failure.assertion("Expected refusal") }
private let cid = "0123456789abcdef0123456789abcdef"
private let boot = "2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601"
private let state0 = "SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING 0\nSSH_USERS_LISTENER 0\n"
private let state1 = "SSH_USERS_SCHEMA 1\nSSH_USERS_PENDING 0\nSSH_ACCOUNT modemadmin 50000 /data/zte-imei-admin/homes/modemadmin 1\nSSH_USERS_LISTENER 1\n"
private final class Mock: RemoteTransport {
    var commands = [String](), inputs = [Data?](), uploaded = [String:Data](), created = false
    var badFirmware = false, wrongUpload = false, commandFails = false, pending = false
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command); inputs.append(input)
        func output(_ s: String) -> CommandResult { CommandResult(status:0,stdout:Data(s.utf8),stderr:Data()) }
        if command.hasPrefix("sha256sum /firmware") { return output((badFirmware ? "invalid" : ModemEngine.firmwareHash) + " /firmware/image/modem.b16\n" + ModemEngine.routerHash + " /usr/bin/diag-router\n" + cid + "\n" + boot + "\n") }
        if command.contains("SSH_USERS_SCHEMA") { return output(pending ? state0.replacingOccurrences(of:"PENDING 0",with:"PENDING 1") : (created ? state1 : state0)) }
        if command.hasPrefix("umask 077; cat >") {
            let path = command.components(separatedBy:"'")[1]; uploaded[path] = input!
            return output((wrongUpload ? "wrong" : digest(input!)) + " " + path + "\n")
        }
        if command.hasPrefix("sh '/tmp/zte-ssh-users-") {
            try check(input == Data("safe 'password;123\n".utf8), "Password must be stdin")
            if commandFails { return CommandResult(status:1,stdout:Data(),stderr:Data("SSH_USERS_ERROR USER_EXISTS\n".utf8)) }
            created = true; return output("SSH_USERS_CREATED modemadmin 50000 synthetic-journal\n")
        }
        if command.hasPrefix("test -d '") && command.contains("tar -C") { return output("synthetic private backup") }
        if command.contains("zte-imei-app.lock") || command.hasPrefix("umask 077; mkdir '/tmp/zte-ssh-users-") || command.hasPrefix("rm -f '/tmp/zte-ssh-users-") { return output("") }
        throw Failure.assertion("Unexpected command " + command)
    }
}
@main enum SSHAccountTests {
    static func main() throws {
        var passed = 0
        func test(_ label: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS " + label) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zte-ssh-tests-" + UUID().uuidString)
        try secureDirectory(dir); defer { try? FileManager.default.removeItem(at:dir) }
        let assets = dir.appendingPathComponent("resources/SSHAccounts"); try secureDirectory(assets)
        let names = ["create-ssh-user.sh","start-ssh-users.sh","doas","dropbear"]
        var hashes = [String:String]()
        for name in names { let bytes=Data(("synthetic-"+name).utf8); try savePrivate(bytes,assets.appendingPathComponent(name)); hashes[name]=digest(bytes) }
        try saveJSON(hashes,assets.appendingPathComponent("SHA256.json"))
        let connection = Connection(host:"192.168.0.1",port:"2222",keyPath:"/dev/null",knownHostsPath:"/dev/null")
        func manager(_ mock: Mock) throws -> SSHAccountManager {
            try SSHAccountManager(root:dir.appendingPathComponent(UUID().uuidString),resources:assets.deletingLastPathComponent(),connection:connection,transport:mock)
        }
        try test("Login validation blocks system names and shell injection") {
            for name in ["root","daemon","zteimei","a b","-x","a;reboot","a\nroot","admin\n","Aadmin",String(repeating:"a",count:25)] { try reject { try SSHAccountManager.validate(username:name,password:"Valid123!") } }
            try SSHAccountManager.validate(username:"modemadmin",password:"safe 'password;123")
        }
        try test("Password validation excludes truncation and line injection") {
            for password in ["1234567",String(repeating:"x",count:129),"Valid123\nroot", "Valid123\0", "пароль123"] { try reject { try SSHAccountManager.validate(username:"test",password:password) } }
        }
        try test("Strict parser preserves named administrative account") {
            let state=try SSHAccountManager.parseState(state1)
            try check(state.accounts.count == 1 && state.accounts[0].uid == 50000 && state.accounts[0].administrator && state.listenerReady && state.port == 2223,"State parse")
        }
        try test("Strict parser rejects incomplete duplicated and UID0 records") {
            for text in ["",state1+"SSH_USERS_LISTENER 1\n",state1.replacingOccurrences(of:"50000",with:"0"),state1.replacingOccurrences(of:"homes/modemadmin",with:"homes/other"),state1+"junk\n"] { try reject { _ = try SSHAccountManager.parseState(text) } }
        }
        try test("Read-only inspect never installs anything") {
            let mock=Mock(); let state=try manager(mock).inspect(); try check(!state.listenerReady && mock.uploaded.isEmpty && !mock.created,"Inspect writes")
        }
        try test("Firmware mismatch stops before upload") {
            let mock=Mock();mock.badFirmware=true;try reject { _=try manager(mock).create(username:"modemadmin",password:"safe 'password;123") }; try check(mock.uploaded.isEmpty,"Bad firmware upload")
        }
        try test("Pending remote transaction stops before upload") {
            let mock=Mock();mock.pending=true;try reject { _=try manager(mock).create(username:"modemadmin",password:"safe 'password;123") }; try check(mock.uploaded.isEmpty,"Pending transaction upload")
        }
        try test("Corrupt upload blocks account creation") {
            let mock=Mock();mock.wrongUpload=true;try reject { _=try manager(mock).create(username:"modemadmin",password:"safe 'password;123") }; try check(!mock.created,"Corrupt upload executed")
        }
        try test("Successful creation keeps password out of argv and journals") {
            let mock=Mock(), service=try manager(mock); let state=try service.create(username:"modemadmin",password:"safe 'password;123")
            try check(state.listenerReady && mock.created && mock.uploaded.count == 4,"Creation incomplete")
            try check(mock.commands.allSatisfy{ !$0.contains("safe 'password;123") },"Password appears in argv")
            let files=FileManager.default.enumerator(at:service.root,includingPropertiesForKeys:nil)!.compactMap{$0 as? URL}
            for file in files { if let data=try? Data(contentsOf:file) { try check(!String(decoding:data,as:UTF8.self).contains("safe 'password;123"),"Password leaked in journal") } }
            try check(files.contains{$0.lastPathComponent == "settings-before.tar"},"No local settings snapshot")
        }
        try test("Failed installer keeps evidence and avoids success") {
            let mock=Mock();mock.commandFails=true;try reject { _=try manager(mock).create(username:"modemadmin",password:"safe 'password;123") };try check(!mock.created,"Failure reported success")
        }
        print("\(passed) SSH account tests passed")
    }
}
