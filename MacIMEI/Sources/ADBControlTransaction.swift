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
    static let scriptHash = "1ab9a52c4a5bf062e0863dba043e5f5da08d7397dde2d0fb1856e7955eb9e363"
    static let release1271ScriptHash = "8e8f39ca743a4e53971db885afc3117ab3023a0ff3d6144c0954b078f6562a79"
    static let previousScriptHash = "0ca5d10426c8398bab5e35af525782c490dce30f841a073e2cc64e3dc49c27dd"
    static let b04FirmwareHash = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81"
    static let b28FirmwareHash = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478"
    static let b27FirmwareHash = "4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e"
    static let b27RouterHash = "786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f"
    static func known(firmware: String, router: String) -> Bool {
        if firmware == b27FirmwareHash { return router == b27RouterHash }
        return [ModemEngine.firmwareHash, b28FirmwareHash, b04FirmwareHash, "absent"].contains(firmware) && router == ModemEngine.routerHash
    }
    static let capabilityCommand = "set -eu; for t in sh stat readlink sha256sum cut awk sed sort pidof nohup sleep cat mv rm rmdir mkdir ln id uname cmp chmod; do command -v \"$t\" >/dev/null 2>&1 || exit 71; done; test -d /tmp && test ! -L /tmp && test -w /tmp && test -r /tmp && test -x /tmp && test \"$(stat -c %u /tmp)\" = 0 || exit 71; test -f /sbin/adbd && test ! -L /sbin/adbd && test \"$(stat -c %u /sbin/adbd)\" = 0 || exit 71; printf 'ADB_CAPABILITY_READY\\n'"
    // The captured B04 image or its absence is only a candidate: native identity is measured
    // in the capability check and again by the transaction before every write.
    static let b04CapabilityCommand = #"""
if test -e /firmware/image/modem.b16 || test -L /firmware/image/modem.b16; then
  test -f /firmware/image/modem.b16 && test ! -L /firmware/image/modem.b16 && test "$(stat -c %u /firmware/image/modem.b16)" = 0 || exit 71
  test "$(sha256sum /firmware/image/modem.b16 | cut -d ' ' -f 1)" = c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81 || exit 71
fi
  test -f /usr/bin/zte_topsw_mdm && test ! -L /usr/bin/zte_topsw_mdm && test "$(stat -c %u /usr/bin/zte_topsw_mdm)" = 0 || exit 71
  test "$(sha256sum /usr/bin/zte_topsw_mdm | cut -d ' ' -f 1)" = 93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64 || exit 71
  info=$(ubus -t 5 call zwrt_web device_info '{}') || exit 71
  test "$(printf '%s' "$info" | jsonfilter -e '@.integrate_version')" = XCBZ_HK_MU5250V1.0.0B04 || exit 71
  test "$(printf '%s' "$info" | jsonfilter -e '@.wa_inner_version')" = BD_XCBZHKMU5250V1.0.0B04 || exit 71
"""#
    static let b27CapabilityCommand = #"""
test -f /usr/bin/zte_topsw_mdm && test ! -L /usr/bin/zte_topsw_mdm && test "$(stat -c %u /usr/bin/zte_topsw_mdm)" = 0 || exit 71
  test "$(sha256sum /usr/bin/zte_topsw_mdm | cut -d ' ' -f 1)" = 00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d || exit 71
"""#
    private func capabilityCommand(_ firmware: String) -> String {
        if firmware == Self.b27FirmwareHash { return "set -eu; " + Self.b27CapabilityCommand + "; " + Self.capabilityCommand }
        return ["absent", Self.b04FirmwareHash].contains(firmware) ? "set -eu; " + Self.b04CapabilityCommand + "; " + Self.capabilityCommand : Self.capabilityCommand
    }
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
            try require(!truncated && pending.schema == 1 && pending.token.range(of: #"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#, options: .regularExpression) != nil && pending.cid.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil && UUID(uuidString: pending.boot) != nil && Self.known(firmware: pending.firmware, router: pending.router), "Некорректная сохранённая операция ADB")
            let current = try engine.measuredIdentity()
            try require(current.identity.cid == pending.cid && current.identity.firmwareHash == pending.firmware && current.routerHash == pending.router, "Устройство изменилось во время восстановления ADB")
            if current.bootID != pending.boot {
                try require(try stageAbsent(pending), "Старая операция ADB всё ещё присутствует")
                let observed = try observedStatus()
                try require(observed.enabled != nil && (try stageAbsent(pending)) && (try engine.measuredIdentity()) == current, "Восстановление ADB после перезагрузки не подтверждено")
                try archive(pending, bytes: bytes)
                return try observedStatus()
            }
            if try !pending.dispatched && stageAbsent(pending) {
                let observed = try observedStatus()
                try require(observed.enabled != nil && (try stageAbsent(pending)), "Состояние ADB не подтверждено")
                try same(pending)
                try archive(pending, bytes: bytes)
                return try observedStatus()
            }
            // Only the current bundled helper executes. Old staged bytes are
            // compared with a reviewed hash, never loaded as recovery code.
            let recoveryCommand = scriptGuard(pending, recovery: true) + "exec /bin/sh -s -- " +
                ["reconcile", pending.stage, pending.token, pending.cid, pending.boot, pending.enabled ? "1" : "0"].map(shellQuote).joined(separator: " ") + " \"$stage_hash\""
            let source = try script()
            if let reply = try? run(recoveryCommand, input: source, timeout: 30),
               ["ADB_RECOVERED=cancelled\n", "ADB_RECOVERED=settled-before\n", "ADB_RECOVERED=settled-after\n"].contains(reply) {
                let observed = try observedStatus()
                try require(observed.enabled != nil && (reply != "ADB_RECOVERED=settled-after\n" || observed.enabled == pending.enabled), "Восстановленное состояние ADB не подтверждено")
                try same(pending)
                try archive(pending, bytes: bytes)
                // Cleanup is optional after the exact intent has been archived.
                // A lost housekeeping reply cannot recreate a settled lock.
                try? cleanup(pending, removePending: false)
            }
        }
        var observed = try observedStatus()
        if engine.fm.fileExists(atPath: pendingURL.path) {
            observed.supportsChange = false
            observed.message = "Операция ADB ещё не подтверждена. Обновите состояние после автоматического отката; повторная запись заблокирована. Если повторная проверка не помогает, перезапустите модем и подключитесь снова."
        }
        return observed
    }
    private func observedStatus() throws -> ADBControlStatus {
        let before = try engine.measuredIdentity()
        let result = try engine.transport.run(ADBControlProtocol.command, input: nil, timeout: 15)
        try require(result.status == 0, "Не удалось прочитать состояние ADB через SSH")
        var state = try ADBControlProtocol.parse(result.stdout)
        state.supportsChange = state.enabled != nil && state.descriptorsReady
            && Self.known(firmware: before.identity.firmwareHash, router: before.routerHash)
            && !engine.fm.fileExists(atPath: pendingURL.path) && (try? script()) != nil
        if state.supportsChange {
            state.supportsChange = (try? run(capabilityCommand(before.identity.firmwareHash))) == "ADB_CAPABILITY_READY\n"
        }
        try require(try engine.measuredIdentity() == before, "Устройство или сеанс загрузки изменились при чтении ADB")
        return state
    }
    private func stageAbsent(_ pending: ADBControlPending) throws -> Bool {
        let command = "set -eu; test -d /tmp && test ! -L /tmp && test -r /tmp && test -x /tmp && test \"$(stat -c %u /tmp)\" = 0 || exit 71; test ! -e " + shellQuote(pending.stage) + "; test ! -L " + shellQuote(pending.stage) + "; test ! -e /tmp/zte-imei-app.lock; test ! -L /tmp/zte-imei-app.lock; printf 'ADB_STAGE_ABSENT\\n'"
        return (try? run(command)) == "ADB_STAGE_ABSENT\n"
    }
    private func archive(_ pending: ADBControlPending, bytes: Data) throws {
        let (current, truncated) = try DiagnosticArchive.readRegular(root: engine.root, relative: "adb-toggle-pending.json", limit: 4096)
        try require(!truncated && current == bytes, "Сохранённая операция ADB изменилась")
        let name = "adb-toggle-recovered-" + pending.token + ".json"
        let destination = engine.root.appendingPathComponent(name)
        if engine.fm.fileExists(atPath: destination.path) {
            let (saved, oversized) = try DiagnosticArchive.readRegular(root: engine.root, relative: name, limit: 4096)
            try require(!oversized && saved == bytes, "Архив операции ADB не подтверждён")
            try engine.fm.removeItem(at: pendingURL)
        } else { try engine.fm.moveItem(at: pendingURL, to: destination) }
    }
    private func same(_ pending: ADBControlPending) throws {
        let proof = try engine.measuredIdentity()
        try require(proof.identity.cid == pending.cid && proof.bootID == pending.boot && proof.identity.firmwareHash == pending.firmware && proof.routerHash == pending.router, "Устройство или сеанс загрузки изменились во время переключения ADB")
    }
    private func scriptGuard(_ pending: ADBControlPending, recovery: Bool = false) -> String {
        let stage = shellQuote(pending.stage), path = shellQuote(pending.stage + "/adb-toggle.sh")
        return "set -eu; test -d " + stage + " && test ! -L " + stage + " && test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700 || exit 71; " +
            "test -f " + path + " && test ! -L " + path + " && test \"$(stat -c '%u:%a:%h' " + path + ")\" = 0:600:1 && test \"$(stat -c %s " + path + ")\" -le 32768 || exit 71; " +
            "stage_hash=$(sha256sum " + path + " | cut -d ' ' -f 1); " +
            (recovery ? "case \"$stage_hash\" in " + Self.scriptHash + "|" + Self.release1271ScriptHash + "|" + Self.previousScriptHash + ") :;; *) exit 71;; esac; " : "test \"$stage_hash\" = " + shellQuote(Self.scriptHash) + " || exit 71; ")
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
    private func cleanup(_ pending: ADBControlPending, removePending: Bool = true) throws {
        try same(pending)
        let stage = shellQuote(pending.stage)
        // Never recurse and never remove a lock. The worker releases its own
        // lock before publishing a terminal receipt.
        let files = ["adb-toggle.sh", "phase", "before", "after", "udc", "daemon", "name", "target", "desired", "original", "ack", "worker.log", "rc.before", "rc.after", "rc.mode", "phase.new", "before.new", "after.new", "udc.new", "daemon.new", "name.new", "target.new", "desired.new", "original.new", "ack.new", "rc.mode.new"]
        let inventoryGuard = "for p in " + stage + "/* " + stage + "/.[!.]* " + stage + "/..?*; do test -e \"$p\" || test -L \"$p\" || continue; case \"${p##*/}\" in " + files.joined(separator: "|") + "|apply-once|decision|released-lock) :;; *) exit 71;; esac; done; " +
            "for d in " + shellQuote(pending.stage + "/apply-once") + " " + shellQuote(pending.stage + "/decision") + "; do if test -e \"$d\" || test -L \"$d\"; then test -d \"$d\" && test ! -L \"$d\" && test \"$(stat -c '%u:%a' \"$d\")\" = 0:700 || exit 71; for p in \"$d\"/* \"$d\"/.[!.]* \"$d\"/..?*; do if test -e \"$p\" || test -L \"$p\"; then exit 71; fi; done; fi; done; "
        let released = shellQuote(pending.stage + "/released-lock")
        let releasedGuard = "if test -e " + released + " || test -L " + released + "; then test -d " + released + " && test ! -L " + released + " && test \"$(stat -c '%u:%a' " + released + ")\" = 0:700 || exit 71; for p in " + released + "/* " + released + "/.[!.]* " + released + "/..?*; do test ! -e \"$p\" && test ! -L \"$p\" && continue; test \"${p##*/}\" = owner && test -f \"$p\" && test ! -L \"$p\" && test \"$(stat -c '%u:%a:%h' \"$p\")\" = 0:600:1 && test \"$(cat \"$p\")\" = " + shellQuote(pending.token) + " || exit 71; done; fi; "
        let releasedRemove = "if test -d " + released + "; then rm -f " + shellQuote(pending.stage + "/released-lock/owner") + "; rmdir " + released + "; fi; "
        let command = "set -eu; test ! -e " + shellQuote(pending.stage + "/prepare-active") + "; test ! -L " + shellQuote(pending.stage + "/prepare-active") + "; test -d " + stage + " && test ! -L " + stage + " || exit 71; test \"$(stat -c '%u:%a' " + stage + ")\" = 0:700; " + inventoryGuard + releasedGuard +
            "for f in " + files.map { shellQuote(pending.stage + "/" + $0) }.joined(separator: " ") + "; do test ! -L \"$f\" || exit 71; if test -e \"$f\"; then test -f \"$f\" && test \"$(stat -c '%u:%a:%h' \"$f\")\" = 0:600:1 || exit 71; fi; done; " +
            releasedRemove + "rm -f " + files.map { shellQuote(pending.stage + "/" + $0) }.joined(separator: " ") + "; if test -d " + shellQuote(pending.stage + "/apply-once") + "; then rmdir " + shellQuote(pending.stage + "/apply-once") + "; fi; if test -d " + shellQuote(pending.stage + "/decision") + "; then rmdir " + shellQuote(pending.stage + "/decision") + "; fi; rmdir " + stage + "; printf 'ADB_STAGE_REMOVED\\n'"
        if removePending {
            let (bytes, truncated) = try DiagnosticArchive.readRegular(root: engine.root, relative: "adb-toggle-pending.json", limit: 4096)
            try require(!truncated, "Сохранённая операция ADB повреждена")
            try archive(pending, bytes: bytes)
            _ = try? run(command)
        } else {
            try require(try run(command) == "ADB_STAGE_REMOVED\n", "Очистка временной операции ADB не подтверждена")
        }
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
        let persistenceOnly = !enabled && initial.enabled == false
            && Self.known(firmware: proof.identity.firmwareHash, router: proof.routerHash)
            && (try? run(capabilityCommand(proof.identity.firmwareHash))) == "ADB_CAPABILITY_READY\n"
        try require(initial.supportsChange || persistenceOnly, "Безопасное переключение ADB для этой конфигурации не подтверждено. Для включения нужны готовые USB-дескрипторы ADB; выключение уже отсутствующего ADB доступно через SSH.")
        try require(Self.known(firmware: proof.identity.firmwareHash, router: proof.routerHash), "Изменения ADB для этой прошивки не подтверждены")
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
