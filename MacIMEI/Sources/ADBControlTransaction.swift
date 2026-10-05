import Foundation

private struct ADBControlPending: Codable {
    let schema: Int
    let token: String
    let cid: String
    let boot: String
    let firmware: String
    let router: String
    let enabled: Bool
    var dispatched: Bool
    var stage: String { "/tmp/zte-adb-toggle-" + token }
}
struct ADBControlManager {
    let engine: ModemEngine
    var now: () -> Date = Date.init
    var wait: (TimeInterval) -> Void = Thread.sleep
    // Updated only from the reviewed bundled source, never learned from a modem.
    static let scriptHash = "4e24dd2e15fa567c8a22efaafdc0f01345fb226c2b1fef7f921ec77d67ebe2f7"
    static let capabilityCommand = "set -eu; for t in sh stat readlink sha256sum cut awk sed sort pidof nohup sleep cat mv rm rmdir mkdir ln id uname; do command -v \"$t\" >/dev/null 2>&1 || exit 71; done; test -d /tmp && test ! -L /tmp && test -w /tmp && test -r /tmp && test -x /tmp && test \"$(stat -c %u /tmp)\" = 0 || exit 71; test -f /sbin/adbd && test ! -L /sbin/adbd && test \"$(stat -c %u /sbin/adbd)\" = 0 && test \"$(sha256sum /sbin/adbd | cut -d ' ' -f 1)\" = 6d42bf97ae1f761ba3c5a0ee48deb84db0b19e4766b6b538b71741743d5b3f90 || exit 71; printf 'ADB_CAPABILITY_READY\\n'"
    var pendingURL: URL { engine.root.appendingPathComponent("adb-toggle-pending.json") }
    private var scriptURL: URL { engine.resources.appendingPathComponent("Onboarding/adb-toggle.sh") }
    private func script() throws -> Data {
        let data = try Data(contentsOf: scriptURL)
        try require(data.count <= 32768 && digest(data) == Self.scriptHash, "Компонент переключения ADB повреждён")
        return data
    }
    func status() throws -> ADBControlStatus {
        if engine.fm.fileExists(atPath: pendingURL.path) {
            let (bytes, truncated) = try DiagnosticArchive.readRegular(root: engine.root, relative: "adb-toggle-pending.json", limit: 4096)
            let pending = try JSONDecoder().decode(ADBControlPending.self, from: bytes)
            try require(!truncated && pending.schema == 1 && pending.token.range(of: #"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#, options: .regularExpression) != nil && pending.cid.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil && UUID(uuidString: pending.boot) != nil && pending.firmware == ModemEngine.firmwareHash && pending.router == ModemEngine.routerHash, "Некорректная сохранённая операция ADB")
            try same(pending)
            if !pending.dispatched {
                let absent = "set -eu; test -d /tmp && test ! -L /tmp && test -r /tmp && test -x /tmp && test \"$(stat -c %u /tmp)\" = 0 || exit 71; test ! -e " + shellQuote(pending.stage) + "; test ! -L " + shellQuote(pending.stage) + "; test ! -e /tmp/zte-imei-app.lock; test ! -L /tmp/zte-imei-app.lock; printf 'ADB_STAGE_ABSENT\\n'"
                if (try? run(absent)) == "ADB_STAGE_ABSENT\n" {
                    try same(pending)
                    try engine.fm.removeItem(at: pendingURL)
                    return try observedStatus()
                }
            }
            let recoveredPhase = try? phase(pending)
            if recoveredPhase == nil && !pending.dispatched {
                try require(try run(command("cancel", pending)) == "ADB_CANCELLED\n", "Отмена подготовки ADB не подтверждена")
                try require(try phase(pending) == "cancelled", "Отмена подготовки ADB не подтверждена")
                try cleanup(pending)
            } else if let observed = recoveredPhase {
                if ["committed", "rolled-back", "cancelled"].contains(observed) {
                    try cleanup(pending)
                } else if ["prepared", "preparing"].contains(observed) && !pending.dispatched {
                    try require(try run(command("cancel", pending)) == "ADB_CANCELLED\n", "Отмена неподтверждённой подготовки ADB не завершена")
                    try require(try phase(pending) == "cancelled", "Отмена неподтверждённой подготовки ADB не завершена")
                    try cleanup(pending)
                }
            }
        }
        var observed = try observedStatus()
        if engine.fm.fileExists(atPath: pendingURL.path) {
            observed.supportsChange = false
            observed.message = "Операция ADB ещё не подтверждена. Обновите состояние после автоматического отката; повторная запись заблокирована."
        }
        return observed
    }
    private func observedStatus() throws -> ADBControlStatus {
        let before = try engine.measuredIdentity()
        let result = try engine.transport.run(ADBControlProtocol.command, input: nil, timeout: 15)
        try require(result.status == 0, "Не удалось прочитать состояние ADB через SSH")
        var state = try ADBControlProtocol.parse(result.stdout)
        state.supportsChange = state.enabled != nil && state.descriptorsReady
            && before.identity.firmwareHash == ModemEngine.firmwareHash && before.routerHash == ModemEngine.routerHash
            && !engine.fm.fileExists(atPath: pendingURL.path) && (try? script()) != nil
        if state.supportsChange {
            state.supportsChange = (try? run(Self.capabilityCommand)) == "ADB_CAPABILITY_READY\n"
        }
        try require(try engine.measuredIdentity() == before, "Устройство или сеанс загрузки изменились при чтении ADB")
        return state
    }
    private func same(_ pending: ADBControlPending) throws {
        let proof = try engine.measuredIdentity()
        try require(proof.identity.cid == pending.cid && proof.bootID == pending.boot && proof.identity.firmwareHash == pending.firmware && proof.routerHash == pending.router, "Устройство или сеанс загрузки изменились во время переключения ADB")
    }
    private func scriptGuard(_ pending: ADBControlPending) -> String {
        let stage = shellQuote(pending.stage), path = shellQuote(pending.stage + "/adb-toggle.sh")
        return "set -eu; test -d " + stage + " && test ! -L " + stage + " && test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700 || exit 71; " +
            "test -f " + path + " && test ! -L " + path + " && test \"$(stat -c '%u:%a:%h' " + path + ")\" = 0:600:1 && test \"$(stat -c %s " + path + ")\" -le 32768 || exit 71; " +
            "test \"$(sha256sum " + path + " | cut -d ' ' -f 1)\" = " + shellQuote(Self.scriptHash) + " || exit 71; "
    }
    private func invocation(_ mode: String, _ pending: ADBControlPending) -> String {
        "/bin/sh " + shellQuote(pending.stage + "/adb-toggle.sh") + " " + mode + " " +
        [pending.stage, pending.token, pending.cid, pending.boot, pending.enabled ? "1" : "0"].map(shellQuote).joined(separator: " ")
    }
    private func command(_ mode: String, _ pending: ADBControlPending) -> String { scriptGuard(pending) + invocation(mode, pending) }
    private func run(_ command: String, input: Data? = nil, timeout: TimeInterval = 15) throws -> String {
        let result = try engine.transport.run(command, input: input, timeout: timeout)
        try require(result.status == 0 && result.stdout.count <= 512, "Команда переключения ADB не подтверждена. Повторная запись не выполнялась.")
        return CommandText.decode(result.stdout)
    }
    private func phase(_ pending: ADBControlPending) throws -> String {
        let reply = try run(command("result", pending))
        let phases = ["preparing", "prepared", "changing", "awaiting-ack", "committed", "rolled-back", "rollback-unknown", "cleanup-unknown", "cancelled"]
        guard let value = phases.first(where: { reply == "ADB_PHASE=" + $0 + "\n" }) else { throw IMEIError.message("Некорректный ответ переключения ADB") }
        return value
    }
    private func cleanup(_ pending: ADBControlPending) throws {
        try same(pending)
        let stage = shellQuote(pending.stage)
        // Never recurse and never remove a lock. The worker releases its own
        // lock before publishing a terminal receipt.
        let files = ["adb-toggle.sh", "phase", "before", "after", "udc", "daemon", "name", "target", "desired", "original", "ack", "worker.log"]
        let inventoryGuard = "for p in " + stage + "/* " + stage + "/.[!.]* " + stage + "/..?*; do test -e \"$p\" || test -L \"$p\" || continue; case \"${p##*/}\" in " + files.joined(separator: "|") + "|apply-once|decision) :;; *) exit 71;; esac; done; " +
            "for d in " + shellQuote(pending.stage + "/apply-once") + " " + shellQuote(pending.stage + "/decision") + "; do if test -e \"$d\" || test -L \"$d\"; then test -d \"$d\" && test ! -L \"$d\" && test \"$(stat -c '%u:%a' \"$d\")\" = 0:700 || exit 71; for p in \"$d\"/* \"$d\"/.[!.]* \"$d\"/..?*; do if test -e \"$p\" || test -L \"$p\"; then exit 71; fi; done; fi; done; "
        let command = "set -eu; test ! -e " + shellQuote(pending.stage + "/prepare-active") + "; test ! -L " + shellQuote(pending.stage + "/prepare-active") + "; test -d " + stage + " && test ! -L " + stage + " || exit 71; test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700; " + inventoryGuard +
            "for f in " + files.map { shellQuote(pending.stage + "/" + $0) }.joined(separator: " ") + "; do test ! -L \"$f\" || exit 71; if test -e \"$f\"; then test -f \"$f\" && test \"$(stat -c '%u:%a:%h' \"$f\")\" = 0:600:1 || exit 71; fi; done; " +
            "rm -f " + files.map { shellQuote(pending.stage + "/" + $0) }.joined(separator: " ") + "; if test -d " + shellQuote(pending.stage + "/apply-once") + "; then rmdir " + shellQuote(pending.stage + "/apply-once") + "; fi; if test -d " + shellQuote(pending.stage + "/decision") + "; then rmdir " + shellQuote(pending.stage + "/decision") + "; fi; rmdir " + stage + "; printf 'ADB_STAGE_REMOVED\\n'"
        try require(try run(command) == "ADB_STAGE_REMOVED\n", "Очистка временной операции ADB не подтверждена")
        try engine.fm.removeItem(at: pendingURL)
    }
    func setEnabled(_ enabled: Bool) throws -> ADBControlStatus {
        try require(engine.lockFD >= 0, "Переключение ADB требует блокировки приложения")
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json", "system-restore-pending.json", "adb-toggle-pending.json"] {
            try require(!engine.fm.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала проверьте незавершённую операцию модема")
        }
        let source = try script()
        let proof = try engine.measuredIdentity()
        let initial = try status()
        try require(try engine.measuredIdentity() == proof, "Устройство или сеанс загрузки изменились во время переключения ADB")
        try require(initial.supportsChange, "Безопасное переключение ADB для этой конфигурации не подтверждено")
        if initial.enabled == enabled { return initial }
        try require(proof.identity.firmwareHash == ModemEngine.firmwareHash && proof.routerHash == ModemEngine.routerHash, "Изменения ADB для этой прошивки не подтверждены")
        var pending = ADBControlPending(schema: 1, token: UUID().uuidString.lowercased(), cid: proof.identity.cid, boot: proof.bootID, firmware: proof.identity.firmwareHash, router: proof.routerHash, enabled: enabled, dispatched: false)
        try savePrivate(JSONEncoder().encode(pending), pendingURL)
        let stage = shellQuote(pending.stage)
        _ = try run("set -eu; umask 077; test ! -L /tmp; test \"$(stat -c %u /tmp)\" = 0; mkdir -m 700 " + stage + "; cat > " + shellQuote(pending.stage + "/adb-toggle.sh") + "; test \"$(sha256sum " + shellQuote(pending.stage + "/adb-toggle.sh") + " | cut -d ' ' -f 1)\" = " + shellQuote(Self.scriptHash), input: source)
        try same(pending)
        let prepare = try run(command("prepare", pending))
        if prepare == "ADB_UNCHANGED\n" {
            try cleanup(pending)
            return try status()
        }
        try require(prepare == "ADB_PREPARED\n", "Подготовка переключения ADB не подтверждена")
        // Mark before dispatch. A lost reply must never cause another apply.
        pending.dispatched = true
        try savePrivate(JSONEncoder().encode(pending), pendingURL)
        let launch = scriptGuard(pending) + "umask 077; nohup " + invocation("apply", pending) + " </dev/null >" + shellQuote(pending.stage + "/worker.log") + " 2>&1 & printf 'ADB_DISPATCHED\\n'"
        _ = try? run(launch, timeout: 10)
        let deadline = now().addingTimeInterval(95)
        var ackAttempted = false
        while now() < deadline {
            wait(1)
            guard let observed = try? phase(pending) else { continue }
            try same(pending)
            if observed == "awaiting-ack" && !ackAttempted {
                // ack validates exact other links, UDC and daemon again on-device.
                ackAttempted = true
                _ = try? run(command("ack", pending))
            } else if observed == "committed" {
                let final = try observedStatus()
                try require(final.enabled == enabled, "Переключение ADB завершено, но итоговое состояние не подтверждено")
                try cleanup(pending)
                return try status()
            } else if observed == "rolled-back" || observed == "cancelled" {
                try cleanup(pending)
                throw IMEIError.message("SSH не подтвердил переключение ADB. Исходная конфигурация USB восстановлена.")
            } else if observed == "rollback-unknown" || observed == "cleanup-unknown" {
                throw IMEIError.message("Восстановление USB не подтверждено. Операция и блокировка сохранены; повторное переключение не выполняйте.")
            }
        }
        throw IMEIError.message("Переключение ADB не подтверждено. Модем выполняет автоматический откат; запись повторно не отправлялась.")
    }
}
