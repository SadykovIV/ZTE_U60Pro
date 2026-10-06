import Foundation

struct SSHAccount: Identifiable, Codable, Sendable {
    var name: String
    var uid: Int
    var home: String
    var administrator: Bool
    var id: String { name }
}
enum SSHAccountRecoveryKind: String, Sendable { case none, create, delete, unknown }
struct SSHAccountState: Sendable {
    var accounts: [SSHAccount]
    var listenerReady: Bool
    var port: Int = 2223
    var recoveryPending: Bool
    var recoveryKind: SSHAccountRecoveryKind = .none
}

/// Creates named administrators without changing the existing root password or
/// the key-only management endpoint. Passwords travel only through SSH stdin.
final class SSHAccountManager: @unchecked Sendable {
    let engine: ModemEngine
    var root: URL { engine.root }
    var resources: URL { engine.resources }
    var connection: Connection { engine.connection }
    var assets: URL { resources.appendingPathComponent("SSHAccounts") }
    init(root: URL, resources: URL, connection: Connection, transport: RemoteTransport? = nil,
         update: @escaping @Sendable (String, Double) -> Void = { _, _ in }) throws {
        engine = try ModemEngine(root: root, resources: resources, connection: connection, transport: transport, update: update)
    }
    static func validate(username: String, password: String) throws {
        let bytes = Array(username.utf8)
        try require((1...24).contains(bytes.count) && bytes.first.map { (97...122).contains($0) } == true &&
                    bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 } &&
                    !["root", "zteimei", "daemon", "nobody"].contains(username),
                    "Логин: 1–24 латинских символа; начните с a–z, далее допустимы цифры и _. Системные имена запрещены.")
        try require((8...128).contains(password.utf8.count) && password.utf8.allSatisfy { (32...126).contains($0) },
                    "Пароль SSH: 8–128 печатных латинских символов, цифр или знаков без перевода строки.")
    }
    private func checkPending() throws {
        for name in ["adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                        "Сначала завершите текущую настройку или смену IMEI")
        }
    }
    func readStateUnlocked() throws -> SSHAccountState {
        let command = """
        set -eu
        base=/data/zte-imei-admin
        printf 'SSH_USERS_SCHEMA 1\\n'
        pending=0; recovery=none
        owned_file() { test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0; }
        owned_dir() { test -d "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0; }
        if test -e "$base/active" || test -L "$base/active"; then
            pending=1; recovery=unknown
            if owned_dir "$base" && owned_dir "$base/transactions" && owned_file "$base/active"; then
                token=$(cat "$base/active")
                if test "${#token}" = 36 && printf '%s' "$token" | grep -Eq '^[a-f0-9-]{36}$'; then
                    journal=$base/transactions/$token
                    if owned_dir "$journal" && owned_file "$journal/cid" && owned_file "$journal/state" &&
                       test "$(cat "$journal/cid")" = "$(cat /sys/block/mmcblk0/device/cid)"; then
                        if owned_file "$journal/operation" && test "$(cat "$journal/operation")" = delete; then recovery=delete
                        elif test ! -e "$journal/operation" && test ! -L "$journal/operation" && owned_file "$journal/user" && owned_file "$journal/targets"; then recovery=create; fi
                    fi
                fi
            fi
        fi
        printf 'SSH_USERS_PENDING %s\\nSSH_USERS_RECOVERY %s\\n' "$pending" "$recovery"

        awk -F: '$3 >= 50000 && $3 <= 59999 && $5 == \"ZTE IMEI Studio\" && $6 ~ /^\\/data\\/zte-imei-admin\\/homes\\/[a-z][a-z0-9_]*$/ {print $1 " " $3 " " $6}' /etc/passwd | while read -r name uid home; do
            admin=0
            if test -f /etc/zte-imei-admin/doas.conf && grep -qFx "permit $name as root" /etc/zte-imei-admin/doas.conf; then admin=1; fi
            printf 'SSH_ACCOUNT %s %s %s %s\\n' "$name" "$uid" "$home" "$admin"
        done
        ready=0
        if test -f /var/run/zte-imei-users.pid && test ! -L /var/run/zte-imei-users.pid; then
            pid=$(cat /var/run/zte-imei-users.pid)
            case "$pid" in ''|*[!0-9]*) ;; *)
                if test "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" = "$base/bin/dropbear" &&
                    tr '\\000' '\\n' < "/proc/$pid/cmdline" | grep -qFx \(shellQuote(connection.host + ":2223")) &&
                    tr '\\000' '\\n' < "/proc/$pid/cmdline" | grep -qFx -- -w &&
                    tr '\\000' '\\n' < "/proc/$pid/cmdline" | awk 'previous=="-G" && $0=="zteimei" {found=1} {previous=$0} END {exit !found}' &&
                    awk '$2 ~ /:08AF$/ && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6; then ready=1; fi;;
            esac
        fi
        printf 'SSH_USERS_LISTENER %s\\n' "$ready"
        """
        return try Self.parseState(engine.text(command))
    }
    static func parseState(_ text: String) throws -> SSHAccountState {
        var accounts = [SSHAccount](), ready: Bool?, pending: Bool?, schema = false
        var recoveryKind: SSHAccountRecoveryKind?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard let kind = fields.first else { continue }
            switch kind {
            case "SSH_USERS_SCHEMA":
                try require(!schema && fields == ["SSH_USERS_SCHEMA", "1"], "Неизвестный формат SSH-пользователей"); schema = true
            case "SSH_USERS_PENDING":
                try require(pending == nil && fields.count == 2 && ["0", "1"].contains(fields[1]), "Повреждён статус SSH"); pending = fields[1] == "1"
            case "SSH_USERS_RECOVERY":
                try require(recoveryKind == nil && fields.count == 2, "Повреждён вид восстановления SSH")
                guard let kind = SSHAccountRecoveryKind(rawValue: fields[1]) else { throw IMEIError.message("Неизвестный вид восстановления SSH") }
                recoveryKind = kind
            case "SSH_USERS_LISTENER":
                try require(ready == nil && fields.count == 2 && ["0", "1"].contains(fields[1]), "Повреждён статус SSH"); ready = fields[1] == "1"
            case "SSH_ACCOUNT":
                try require(fields.count == 5, "Повреждена запись SSH-пользователя")
                try validate(username: fields[1], password: "validation-only")
                guard let uid = Int(fields[2]), (50000...59999).contains(uid),
                      fields[3] == "/data/zte-imei-admin/homes/" + fields[1], ["0", "1"].contains(fields[4]) else { throw IMEIError.message("Неизвестная учётная запись SSH") }
                try require(!accounts.contains { $0.name == fields[1] || $0.uid == uid }, "Повтор SSH-пользователя")
                accounts.append(SSHAccount(name: fields[1], uid: uid, home: fields[3], administrator: fields[4] == "1"))
            default: throw IMEIError.message("Неожиданный ответ проверки SSH")
            }
        }
        guard schema, let ready, let pending else { throw IMEIError.message("Неполный статус SSH") }
        let kind = recoveryKind ?? (pending ? .unknown : .none)
        try require(pending ? kind != .none : kind == .none, "Несогласованный статус восстановления SSH")
        return SSHAccountState(accounts: accounts.sorted { $0.name < $1.name }, listenerReady: ready, recoveryPending: pending, recoveryKind: kind)
    }
    func inspect() throws -> SSHAccountState {
        try engine.locked {
            let proof = try engine.measuredIdentity()
            let state = try readStateUnlocked()
            try require(try engine.measuredIdentity() == proof, "Подключён другой модем")
            return state
        }
    }
    /// Delete only a managed account. Home contents are archived on the modem;
    /// the exact databases before the operation are also retained privately here.
    func delete(username: String) throws -> SSHAccountState {
        try Self.validate(username: username, password: "validation-only")
        return try mutateDeletion(username: username)
    }
    func recoverDeletion() throws -> SSHAccountState { try mutateDeletion(username: nil) }
    private func mutateDeletion(username: String?) throws -> SSHAccountState {
        try require(connection.port == "2222", "Удаление пользователей доступно только через служебный SSH на порту 2222")
        return try engine.locked {
            try checkPending()
            let proof = try engine.measuredIdentity(), identity = proof.identity; try engine.acquireRemoteLock()
            let before = try readStateUnlocked()
            if let username {
                try require(!before.recoveryPending, "Сначала восстановите незавершённую операцию SSH")
                try require(before.accounts.contains { $0.name == username }, "Можно удалить только SSH-пользователя, созданного приложением")
            } else { try require(before.recoveryPending && before.recoveryKind == .delete, "Нет подтверждённого незавершённого удаления SSH-пользователя") }
            let name = "delete-ssh-user.sh", hashes = try readJSON([String:String].self, assets.appendingPathComponent("SHA256.json"))
            let data = try Data(contentsOf: assets.appendingPathComponent(name))
            try require(hashes[name] == digest(data), "Повреждён компонент удаления SSH-пользователей")
            let token = UUID().uuidString.lowercased(), stage = "/tmp/zte-ssh-users-" + token
            let local = root.appendingPathComponent("SSHAccountBackups/" + token); try secureDirectory(local)
            try saveJSON(["username":username ?? "", "cid":identity.cid, "action":username == nil ? "recover-delete" : "delete", "phase":"prepared"], local.appendingPathComponent("operation.json"))
            _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
            defer { _ = try? engine.remote("rm -f " + shellQuote(stage + "/" + name) + "; rmdir " + shellQuote(stage), timeout:15) }
            try require(try engine.textUpload(path:stage + "/" + name,data:data) == hashes[name], "Не совпала контрольная сумма компонента удаления")
            var arguments = ["sh",shellQuote(stage + "/" + name),username == nil ? "recover" : "delete",shellQuote(stage),shellQuote(identity.cid)]
            if let username { arguments.append(shellQuote(username)) }
            arguments.append(shellQuote(engine.remoteLockToken!))
            engine.update(username == nil ? "Восстанавливаю операцию SSH…" : "Сохраняю настройки и архивирую домашнюю папку…", 0.3)
            try require(try engine.measuredIdentity() == proof, "Подключён другой модем")
            let result = try engine.transport.run(arguments.joined(separator:" "),input:nil,timeout:150)
            try savePrivate(result.stdout + result.stderr,local.appendingPathComponent("result.log"))
            let remoteJournal = "/data/zte-imei-admin/transactions/" + token
            if username != nil, let archive = try? engine.remote("test -d " + shellQuote(remoteJournal + "/before") + " && tar -C " + shellQuote(remoteJournal) + " -cf - before cid user operation state", timeout:30) {
                try savePrivate(archive,local.appendingPathComponent("settings-before.tar"))
            }
            try require(result.status == 0, "Удаление или восстановление пользователя остановлено. Журнал и резервная копия сохранены; открытые сеансы пользователя нужно завершить перед удалением.")
            let after = try readStateUnlocked()
            try require(try engine.measuredIdentity() == proof, "Подключён другой модем")
            try require(!after.recoveryPending && (username == nil || !after.accounts.contains { $0.name == username! }), "Проверка удаления SSH-пользователя не завершилась")
            try saveJSON(["username":username ?? "", "cid":identity.cid, "action":username == nil ? "recover-delete" : "delete", "phase":"complete"],local.appendingPathComponent("operation.json"))
            engine.update(username == nil ? "Исходное состояние SSH восстановлено." : "Пользователь удалён. Домашняя папка сохранена в закрытом архиве на модеме.", 1)
            return after
        }
    }

    func create(username: String, password: String) throws -> SSHAccountState {
        try Self.validate(username: username, password: password)
        return try engine.locked {
            try checkPending()
            let proof = try engine.measuredIdentity(), identity = proof.identity; try engine.acquireRemoteLock()
            let before = try readStateUnlocked()
            try require(!before.recoveryPending, "На модеме сохранена незавершённая операция SSH. Проверьте её журнал перед созданием пользователя.")
            try require(!before.accounts.contains { $0.name == username }, "Пользователь с таким именем уже создан")
            let names = ["create-ssh-user.sh", "start-ssh-users.sh", "doas", "dropbear"]
            let hashes = try readJSON([String:String].self, assets.appendingPathComponent("SHA256.json"))
            var files = [String:Data]()
            for name in names {
                let data = try Data(contentsOf: assets.appendingPathComponent(name))
                try require(hashes[name] == digest(data), "Повреждён компонент SSH: \(name)"); files[name] = data
            }
            let token = UUID().uuidString.lowercased(), stage = "/tmp/zte-ssh-users-" + token
            let local = root.appendingPathComponent("SSHAccountBackups/" + token)
            try secureDirectory(local)
            try saveJSON(["username": username, "cid": identity.cid, "remoteJournal": "/data/zte-imei-admin/transactions/" + token,
                          "phase": "prepared"], local.appendingPathComponent("operation.json"))
            engine.update("Сохраняю настройки SSH и создаю администратора…", 0.2)
            _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
            defer {
                let list = names.map { shellQuote(stage + "/" + $0) }.joined(separator: " ")
                _ = try? engine.remote("rm -f " + list + "; rmdir " + shellQuote(stage), timeout: 15)
            }
            for name in names {
                let path = stage + "/" + name, data = files[name]!
                let result = try engine.textUpload(path: path, data: data)
                try require(result == hashes[name], "Не совпала контрольная сумма SSH-компонента")
            }
            let command = ["sh", shellQuote(stage + "/create-ssh-user.sh"), shellQuote(stage), shellQuote(identity.cid),
                           shellQuote(connection.host), shellQuote(username), shellQuote(hashes["doas"]!), shellQuote(hashes["dropbear"]!)].joined(separator: " ")
            // Transport stores stdin in an isolated 0600 temporary file and removes it
            // on exit. Neither command, transcript, nor operation.json contains it.
            try require(try engine.measuredIdentity() == proof, "Подключён другой модем")
            let result = try engine.transport.run(command, input: Data((password + "\n").utf8), timeout: 150)
            let transcript = result.stdout + result.stderr
            try savePrivate(transcript, local.appendingPathComponent("result.log"))
            let remoteJournal = "/data/zte-imei-admin/transactions/" + token
            if let archive = try? engine.remote("test -d " + shellQuote(remoteJournal + "/before") + " && tar -C " + shellQuote(remoteJournal) + " -cf - before targets cid user state", timeout: 30) {
                try savePrivate(archive, local.appendingPathComponent("settings-before.tar"))
            }
            try require(result.status == 0, "Создание SSH-пользователя остановлено. Журнал и доступный бэкап сохранены; пароль в них не записывается.")
            let after = try readStateUnlocked()
            try require(try engine.measuredIdentity() == proof, "Подключён другой модем")
            try require(after.listenerReady && !after.recoveryPending && after.accounts.contains { $0.name == username && $0.administrator },
                        "Пользователь создан, но проверка службы SSH не завершилась. См. журнал операции.")
            try saveJSON(["username": username, "cid": identity.cid, "remoteJournal": remoteJournal, "phase": "complete"], local.appendingPathComponent("operation.json"))
            engine.update("Администратор создан. SSH по паролю: порт 2223; команды root — через doas.", 1)
            return after
        }
    }
}
private extension ModemEngine {
    func textUpload(path: String, data: Data) throws -> String {
        let output = try remote("umask 077; cat > " + shellQuote(path) + " && chmod 700 " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: data)
        return String(decoding: output, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    }
}
