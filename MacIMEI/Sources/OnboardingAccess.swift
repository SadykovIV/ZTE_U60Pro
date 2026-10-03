import Foundation

/// Uses the existing pending-file namespace so all operation guards continue to
/// block while an access transaction needs reconciliation. No fabricated WEB ID.
struct AccessSetupJournal: Codable {
    var intent = "linux-arm64-access"
    var id: String
    var cid: String
    var bootID: String
    var firmwareHash: String
    var routerHash: String
    var installerProfile: String
    var directory: String
    var adbSerial: String
    var phase = "prepared"
    var installRequested = false
    var remoteJournal: String?

    func validate(root: URL) throws {
        let validPhase = ["prepared", "install-requested", "ready", "complete"].contains(phase)
        let expectedRemote = "/data/local/tmp/zte-imei-installations/" + id
        try require(intent == "linux-arm64-access" && UUID(uuidString: id) != nil && validPhase &&
                    (installRequested == (phase != "prepared")) &&
                    (remoteJournal == nil || remoteJournal == expectedRemote) &&
                    (!["ready", "complete"].contains(phase) || remoteJournal == expectedRemote),
                    "Некорректный журнал доступа; повторная установка не запускалась")
        let expectedDirectory = root.appendingPathComponent("SetupBackups/" + id).standardizedFileURL
        try require(URL(fileURLWithPath: directory).standardizedFileURL == expectedDirectory, "Неверный каталог журнала доступа")
    }
}

extension OnboardingEngine {
    /// Caller holds the host operation lock. A responding root USB device is
    /// evaluated before any web login, backup activation or installer mutation.
    func runExistingUSBAccess(hashes: [String: String], webPassword: String, agentPassword: String,
                              expected: DiagnosticDeviceExpectation, expectedIdentity: Identity?) throws -> SetupResult? {
        var saved: AccessSetupJournal?
        if fm.fileExists(atPath: pending.path) {
            let raw = try Data(contentsOf: pending)
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw IMEIError.message("Некорректный журнал доступа")
            }
            if object["intent"] as? String != "linux-arm64-access" {
                // A damaged access discriminator must not enter the legacy Web
                // backup flow. Only a decodable legacy journal may use it.
                try require(object["bootID"] == nil && (try? JSONDecoder().decode(SetupJournal.self, from: raw)) != nil,
                            "Некорректный журнал доступа; транспорт не запускался")
                return nil
            }
            saved = try JSONDecoder().decode(AccessSetupJournal.self, from: raw)
            try saved!.validate(root: root)
        }
        let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
        let serials: [String]
        do { serials = try adb.discovery().readyUSBSerials }
        catch { throw IMEIError.message("Не удалось проверить USB ADB. " + ActivityJournal.sanitize(error.localizedDescription) + " Включение ADB и восстановление не запускались.") }
        if serials.isEmpty {
            try require(saved == nil, "Для продолжения установки нужен тот же USB ADB; новая установка не запускалась")
            return nil
        }
        try require(serials.count <= 16 && (serials.count == 1 || !expected.cids.isEmpty), "Выберите один USB модем; автоматический выбор неоднозначен")
        var binding = expected
        var webProof: WebIdentity?
        if !webPassword.isEmpty {
            try web.login(password: webPassword)
            webProof = try web.identity(skipFirmwareCheck: true)
            binding.imeis.insert(webProof!.imei)
            try require(binding.imeis.count == 1, "Web не совпадает с ожидаемым модемом")
        }
        var matches: [(String, DiagnosticDeviceProof)] = []
        for serial in serials {
            let response = try adb.shellResult(serial, AccessIdentity.command + (binding.requiresWeb ? "; ubus call zwrt_web device_info '{}'" : ""), timeout: 20)
            guard response.status == 0 else { continue }
            let proof = try AccessIdentity.parse(response.stdout, requireWeb: binding.requiresWeb)
            if binding.matches(proof) && (webProof == nil || webProof == proof.webIdentity) { matches.append((serial, proof)) }
        }
        try require(matches.count == 1, "USB ADB уже обнаружен, но root/Linux ARM64, CID и загрузка ожидаемого устройства не подтверждены. Включение ADB и восстановление не запускались.")
        let (serial, proof) = matches[0]
        if let expectedIdentity { try require(proof.identity == expectedIdentity, "Устройство или прошивка изменились") }
        let profile = AccessIdentity.profile(proof, experimental: currentConnection.skipFirmwareCheck)
        if profile == "linux-arm64-access" { try require(serials.count == 1, "Для generic подготовки нужен единственный USB-модем") }
        let startupData = try Self.agentStartup(password: agentPassword, discovery: profile == "linux-arm64-access", discoveryHost: host)
        func verify() throws {
            let currentUSB = try adb.discovery().readyUSBSerials
            if profile == "linux-arm64-access" {
                let physical = try adb.command(["-d", "get-serialno"], timeout: 5)
                try require(CommandText.decode(physical).trimmingCharacters(in: .whitespacesAndNewlines) == serial, "Не подтверждён единственный физический USB-модем")
            }
            try require(currentUSB.contains(serial) && (profile != "linux-arm64-access" || currentUSB.count == 1), "Выбранный USB-модем отключён или выбор стал неоднозначным")
            let response = try adb.shellResult(serial, AccessIdentity.command, timeout: 20)
            try require(response.status == 0, "Повторная идентификация USB недоступна")
            let fresh = try AccessIdentity.parse(response.stdout)
            try require(fresh.identity == proof.identity && fresh.routerHash == proof.routerHash && fresh.bootID == proof.bootID, "Устройство, загрузка или компоненты изменились; подготовка остановлена")
        }
        if let saved {
            try require(saved.cid == proof.identity.cid && saved.bootID == proof.bootID && saved.firmwareHash == proof.identity.firmwareHash && saved.routerHash == proof.routerHash && saved.installerProfile == profile, "Незавершённая подготовка относится к другому устройству, загрузке или компонентам")
        }
        if saved == nil {
            let own = Connection(host: host, port: "2222", keyPath: root.appendingPathComponent("SSH/id_ed25519").path,
                knownHostsPath: root.appendingPathComponent("SSH/known_hosts").path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
            for connection in [own, currentConnection] where fm.isReadableFile(atPath: connection.keyPath) && fm.isReadableFile(atPath: connection.knownHostsPath) {
                let ssh: RemoteTransport = sshFactory?(connection) ?? SSHTransport(connection)
                let response: CommandResult
                do { response = try ssh.run(AccessIdentity.command, input: nil, timeout: 20) }
                catch {
                    let detail = (error as? CommandFailure).map { CommandText.decode($0.partial.stderr) } ?? ""
                    try require(!DiagnosticTransportSelector.hostTrustFailure(error.localizedDescription + detail), "Проверка ключа SSH не пройдена; установка остановлена")
                    continue
                }
                try require(!DiagnosticTransportSelector.hostTrustFailure(CommandText.decode(response.stderr)), "Проверка ключа SSH не пройдена; установка остановлена")
                if response.status == 255 || response.status == -1 { continue }
                try require(response.status == 0, "Существующий SSH ответил без полной идентификации")
                let fresh = try AccessIdentity.parse(response.stdout)
                try require(fresh.identity == proof.identity && fresh.routerHash == proof.routerHash && fresh.bootID == proof.bootID, "SSH и USB относятся к разным устройствам")
                try verifyAccessAgent(ssh, proof: proof, profile: profile, expectedHash: hashes["zte-agent"]!, password: agentPassword)
                try verify()
                return SetupResult(connection: connection, state: nil, identity: proof.identity, firmware: proof.webIdentity?.firmware ?? "unknown", suffix: "")
            }
        }
        // A fresh bounded inventory is evidence only. The installer still repeats
        // its exact structural preflight; saved or imported reports grant nothing.
        if saved == nil {
            update("Собираю сведения об устройстве перед подготовкой доступа…", 0.15)
            let spec = try ResearchSpecification.load(resources)
            let report = FirmwareResearchCollector(specification: spec, connection: currentConnection, mode: .adb, resources: resources,
                cancellation: ResearchCancellation(), expectedCID: proof.identity.cid, secrets: [agentPassword], runner: researchRunner)
                .collect(context: ["operation": "access-preparation", "writeAuthorization": "none"]) { _, _ in }
            _ = try FirmwareResearchArchive.save(report, root: root)
            try require(report.transport == "adb" && report.bindingStrength == "full" && report.outcome != "cancelled", "Исследование не подтвердило привязку устройства; установка не запускалась")
            try verify()
        }
        let id = saved?.id ?? UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent("SetupBackups/" + id)
        let stage = "/data/local/tmp/zte-imei-setup-" + id
        let remoteJournal = "/data/local/tmp/zte-imei-installations/" + id
        let policy = AccessIdentity.policyArguments(proof, profile: profile)
        let owner = ([id] + policy).joined(separator: " ")
        var journal = saved ?? AccessSetupJournal(id: id, cid: proof.identity.cid, bootID: proof.bootID, firmwareHash: proof.identity.firmwareHash,
            routerHash: proof.routerHash, installerProfile: profile, directory: directory.path, adbSerial: serial)
        let key: URL
        if journal.installRequested {
            let phase = try adb.shell(serial, "cat " + shellQuote(remoteJournal + "/state"))
            try require(phase == "ready" || phase == "complete", "Результат прежней установки не подтверждён. Журнал сохранён; установка автоматически не повторяется.")
            key = root.appendingPathComponent("SSH/id_ed25519")
            try require(fm.fileExists(atPath: key.path), "Ключ незавершённой установки недоступен")
        } else {
            let installer = try String(contentsOf: assets.appendingPathComponent("setup-agent.sh"), encoding: .utf8)
            update("Проверяю условия установки доступа…", 0.5)
            try verify()
            let answer = try adb.shell(serial, "sh -c " + shellQuote(installer) + " -- " + (["--preflight"] + policy).map(shellQuote).joined(separator: " "), timeout: 60)
            try require(answer == "INSTALL_PREFLIGHT " + profile + " imei_config=unknown", "Условия установки не подтверждены")
            try verify()
            try secureDirectory(directory); try saveJSON(journal, pending)
            key = try createKey()
            try require(try adb.shell(serial, Self.stagePreparationCommand(stage: stage, owner: owner)) == "INSTALL_STAGE_READY", "Не подтверждён приватный каталог установки")
            let temporary = fm.temporaryDirectory.appendingPathComponent("zte-access-" + UUID().uuidString)
            try secureDirectory(temporary); defer { try? fm.removeItem(at: temporary) }
            let startup = temporary.appendingPathComponent("start-agent.sh")
            try savePrivate(startupData, startup)
            for name in ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] { try pushStaged(adb, serial: serial, source: assets.appendingPathComponent(name), stage: stage, name: name, owner: owner) }
            try pushStaged(adb, serial: serial, source: key.appendingPathExtension("pub"), stage: stage, name: "id_ed25519.pub", owner: owner)
            try pushStaged(adb, serial: serial, source: startup, stage: stage, name: "start-agent.sh", owner: owner)
            try verify()
            journal.installRequested = true; journal.phase = "install-requested"; try saveJSON(journal, pending)
            _ = try adb.shell(serial, "set -eu; umask 077; set -C; printf '%s\\n' " + shellQuote(owner) + " > " + shellQuote(stage + "/.install-requested"))
            let publicData = try Data(contentsOf: key.appendingPathExtension("pub"))
            let arguments = [stage + "/setup-agent.sh", stage, proof.identity.cid, hashes["zte-agent"]!, hashes["dropbear"]!, digest(publicData)] + Array(policy.dropFirst())
            update("Устанавливаю доступ по собственному SSH-ключу…", 0.65)
            let installAnswer = try adb.shell(serial, "sh " + arguments.map(shellQuote).joined(separator: " "), timeout: 100)
            try require(installAnswer.split(separator: "\n").contains(Substring("INSTALL_READY " + remoteJournal)), "Установщик не подтвердил готовность; автоматического повтора нет")
            journal.phase = "ready"; journal.remoteJournal = remoteJournal; try saveJSON(journal, pending)
        }
        try verify()
        let hostPublic = try adb.shell(serial, "/data/bin/dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key")
        let keys = hostPublic.split(separator: "\n").filter { $0.hasPrefix("ssh-ed25519 ") }
        try require(keys.count == 1, "Не получен однозначный SSH host key")
        let fields = keys[0].split(separator: " ")
        try require(fields.count >= 2 && Data(base64Encoded: String(fields[1]))?.count == 51, "Некорректный SSH host key")
        try verify()
        let hosts = root.appendingPathComponent("SSH/known_hosts")
        try savePrivate(Data("[\(host)]:2222 ssh-ed25519 \(fields[1])\n".utf8), hosts)
        let connection = Connection(host: host, port: "2222", keyPath: key.path, knownHostsPath: hosts.path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
        let ssh: RemoteTransport = sshFactory?(connection) ?? SSHTransport(connection)
        func sshVerify() throws {
            let answer = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(answer.status == 0, "SSH не подтвердил доступ")
            let fresh = try AccessIdentity.parse(answer.stdout)
            try require(fresh.identity == proof.identity && fresh.routerHash == proof.routerHash && fresh.bootID == proof.bootID, "SSH не совпадает с USB-модемом и его загрузкой")
        }
        try sshVerify()
        try verifyAccessAgent(ssh, proof: proof, profile: profile, expectedHash: hashes["zte-agent"]!, password: agentPassword)
        try sshVerify()
        let commit = [stage + "/setup-agent.sh", "--commit", remoteJournal] + policy
        let answer = try ssh.run("sh " + commit.map(shellQuote).joined(separator: " "), input: nil, timeout: 40)
        try require(answer.status == 0 && CommandText.decode(answer.stdout).split(separator: "\n").contains(Substring("INSTALL_COMMITTED " + remoteJournal)), "Журнал установки не завершён; он сохранён для проверки")
        try sshVerify()
        journal.phase = "complete"; journal.remoteJournal = remoteJournal
        try saveJSON(journal, directory.appendingPathComponent("setup-result.json")); try fm.removeItem(at: pending)
        _ = try? adb.shell(serial, "rm -f " + ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh", "id_ed25519.pub", "start-agent.sh", ".owner", ".install-requested"].map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage))
        update("SSH и агент проверены. Операции с NV, картой и прошивкой проверяются отдельно.", 1)
        return SetupResult(connection: connection, state: nil, identity: proof.identity, firmware: proof.webIdentity?.firmware ?? "unknown", suffix: "")
    }
    func verifyAccessAgent(_ ssh: RemoteTransport, proof: DiagnosticDeviceProof, profile: String, expectedHash: String, password: String) throws {
        let discoveryCheck = profile == "linux-arm64-access" ? "tr '\\000' '\\n' < /proc/$p/environ | grep -qx \"ZTE_AGENT_MODE=discovery\" || exit 72; " : ""
        let bindCheck = profile == "linux-arm64-access" ? "tr '\\000' '\\n' < /proc/$p/environ | grep -Fqx " + shellQuote("ZTE_AGENT_BIND=" + host + ":9090") + " || exit 72; " : ""
        let process = try ssh.run("set -e; test \"$(sha256sum /data/zte-agent | cut -d ' ' -f 1)\" = " + shellQuote(expectedHash) + "; found=0; for p in $(pidof zte-agent); do if test \"$(readlink /proc/$p/exe)\" = /data/zte-agent; then " + discoveryCheck + bindCheck + "found=1; fi; done; test \"$found\" = 1; printf AGENT_READY", input: nil, timeout: 15)
        try require(process.status == 0 && process.stdout == Data("AGENT_READY".utf8), "Не подтверждён процесс установленного агента или режим discovery")
        try authenticateAgent(transport: ssh, password: password)
        let response = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
        try require(response.status == 0, "Проверка SSH после входа не завершена")
        let after = try AccessIdentity.parse(response.stdout)
        try require(after.identity == proof.identity && after.routerHash == proof.routerHash && after.bootID == proof.bootID, "Во время проверки доступа изменился модем, загрузка или компоненты")
    }

}
