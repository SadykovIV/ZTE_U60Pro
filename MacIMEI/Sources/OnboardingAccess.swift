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
    var forceReinstall: Bool?
    var cleanComponents: Bool?
    var remoteJournal: String?
    var remoteStage: String?

    func validate(root: URL) throws {
        let validPhase = ["prepared", "install-requested", "ready", "complete"].contains(phase)
        let paths = try SetupRemotePaths(id: id, installRequested: installRequested, stage: remoteStage, journal: remoteJournal)
        let expectedRemote = paths.journal
        try require((cleanComponents != true || forceReinstall == true) && intent == "linux-arm64-access" && UUID(uuidString: id) != nil && validPhase &&
                    (installRequested == (phase != "prepared")) &&
                    (remoteJournal == nil || !installRequested || remoteJournal == expectedRemote) &&
                    (!["ready", "complete"].contains(phase) || remoteJournal == expectedRemote),
                    "Некорректный журнал доступа; повторная установка не запускалась")
        let expectedDirectory = root.appendingPathComponent("SetupBackups/" + id).standardizedFileURL
        try require(URL(fileURLWithPath: directory).standardizedFileURL == expectedDirectory, "Неверный каталог журнала доступа")
    }
}

extension OnboardingEngine {
    /// Commit already succeeded, but saving the cleanup plan may have lost SSH.
    /// Recheck the saved target through prepared SSH without replaying setup.
    func resumeCommittedCleanup() throws -> SetupResult? {
        guard fm.fileExists(atPath: pending.path) else { return nil }
        let raw = try DeviceBackups.smallFile(pending, maximum: 65536)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              object["phase"] as? String == "complete", object["cleanComponents"] as? Bool == true else { return nil }
        try require(object["forceReinstall"] as? Bool == true, "Некорректный режим незавершённой подготовки")
        func resume<J: Encodable>(_ journal: J, id: String, directory: URL, cid: String,
                                  firmware: String, router: String, boot: String?) throws -> SetupResult {
            try require(cid.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil &&
                        DeviceBackups.validHash(firmware) && DeviceBackups.validHash(router), "Некорректный журнал завершённой подготовки")
            let connection = Connection(host: host, port: "2222", keyPath: root.appendingPathComponent("SSH/id_ed25519").path,
                knownHostsPath: root.appendingPathComponent("SSH/known_hosts").path, skipFirmwareCheck: currentConnection.skipFirmwareCheck)
            try connection.validate()
            let ssh = sshFactory?(connection) ?? SSHTransport(connection)
            let answer = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(answer.status == 0, "Не удалось подтвердить модем перед очисткой")
            let proof = try AccessIdentity.parse(answer.stdout)
            try require(proof.identity == Identity(cid: cid, firmwareHash: firmware) && proof.routerHash == router &&
                        (boot == nil || proof.bootID == boot), "Модем или его загрузка изменились; журнал чистой установки сохранён")
            return try finishSetup(journal, id: id, directory: directory, cleanComponents: true,
                result: SetupResult(connection: connection, state: nil, identity: proof.identity, firmware: "unknown", suffix: ""))
        }
        if object["intent"] as? String == "linux-arm64-access" {
            let journal = try JSONDecoder().decode(AccessSetupJournal.self, from: raw)
            try journal.validate(root: root)
            return try resume(journal, id: journal.id, directory: URL(fileURLWithPath: journal.directory), cid: journal.cid,
                              firmware: journal.firmwareHash, router: journal.routerHash, boot: journal.bootID)
        }
        let journal = try JSONDecoder().decode(SetupJournal.self, from: raw)
        let directory = URL(fileURLWithPath: journal.directory).standardizedFileURL
        try require(object["bootID"] == nil && journal.intent == nil && journal.installRequested && UUID(uuidString: journal.id) != nil &&
                    directory.deletingLastPathComponent().path == root.appendingPathComponent("SetupBackups").standardizedFileURL.path &&
                    UUID(uuidString: directory.lastPathComponent) != nil, "Некорректный журнал завершённой подготовки")
        _ = try SetupRemotePaths(id: journal.id, installRequested: true, stage: journal.remoteStage, journal: journal.remoteJournal)
        return try resume(journal, id: journal.id, directory: directory, cid: journal.cid ?? "",
                          firmware: journal.firmwareHash ?? "", router: journal.routerHash ?? "", boot: nil)
    }
    /// The SSH transaction is complete before cleanup can be scheduled. Save the
    /// separate intent first so a crash never replays preparation to retry cleanup.
    func finishSetup<J: Encodable>(_ journal: J, id: String, directory: URL,
                                    cleanComponents: Bool, result: SetupResult) throws -> SetupResult {
        try saveJSON(journal, directory.appendingPathComponent("setup-result.json"))
        if cleanComponents {
            guard let identity = result.identity else { throw IMEIError.message("Не подтверждено устройство для очистки компонентов") }
            try saveJSON(journal, pending)
            let ssh = sshFactory?(result.connection) ?? SSHTransport(result.connection)
            try ComponentCleanup.schedule(root: root, connection: result.connection, setupID: id,
                setupDirectory: directory, expectedIdentity: identity, transport: ssh)
        }
        try fm.removeItem(at: pending)
        return cleanComponents ? try resumeComponentCleanup() : result
    }

    func resumeComponentCleanup() throws -> SetupResult {
        let cleaner = ComponentCleanup(root: root, resources: resources, connection: currentConnection, sshFactory: sshFactory, update: update)
        return try finishComponentCleanup(cleaner.run())
    }

    func cancelComponentCleanup() throws -> SetupResult {
        try locked {
            let cleaner = ComponentCleanup(root: root, resources: resources, connection: currentConnection, sshFactory: sshFactory, update: update)
            return try finishComponentCleanup(cleaner.cancelBeforeDispatch())
        }
    }

    private func finishComponentCleanup(_ result: ComponentCleanupResult) throws -> SetupResult {
        // A crash may leave the already-complete preparation journal beside its
        // cleanup intent. Never remove an unrelated or unfinished transaction.
        if fm.fileExists(atPath: pending.path) {
            let raw = try Data(contentsOf: pending)
            let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
            try require(object?["id"] as? String == result.setupID && object?["phase"] as? String == "complete" &&
                        object?["cleanComponents"] as? Bool == true && object?["forceReinstall"] as? Bool == true,
                        "Журнал подготовки изменился; его данные сохранены")
            try fm.removeItem(at: pending)
        }
        try ComponentCleanup.acknowledge(root: root, setupID: result.setupID)
        update(result.cancelled ? "Очистка отменена до удаления компонентов. Агент и SSH сохранены." : "Подготовка и очистка компонентов завершены. Агент и SSH сохранены.", 1)
        return SetupResult(connection: result.connection, state: nil, identity: result.identity,
                           firmware: "unknown", suffix: "", componentsCleaned: !result.cancelled)
    }
    /// Caller holds the host operation lock. A responding root USB device is
    /// evaluated before any web login, backup activation or installer mutation.
    func runExistingUSBAccess(hashes: [String: String], webPassword: String, agentPassword: String,
                              expected: DiagnosticDeviceExpectation, expectedIdentity: Identity?, completedBootstrapID: String? = nil, forceReinstall: Bool = false, cleanComponents: Bool = false) throws -> SetupResult? {
        var bootstrap: SetupJournal?
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
                guard let completedBootstrapID else { return nil }
                let prior = try JSONDecoder().decode(SetupJournal.self, from: raw)
                let directory = URL(fileURLWithPath: prior.directory).standardizedFileURL
                try require(prior.id == completedBootstrapID && UUID(uuidString: prior.id) != nil &&
                            prior.phase == "adb-ready" && !prior.installRequested && prior.intent == nil &&
                            directory.deletingLastPathComponent() == root.appendingPathComponent("SetupBackups").standardizedFileURL &&
                            UUID(uuidString: directory.lastPathComponent) != nil,
                            "Некорректный журнал подтверждённого ADB; установка не запускалась")
                bootstrap = prior
            } else {
                try require(completedBootstrapID == nil, "Журнал подготовки изменился; установка не запускалась")
                saved = try JSONDecoder().decode(AccessSetupJournal.self, from: raw)
                try saved!.validate(root: root)
            }
        }
        try require(completedBootstrapID == nil || bootstrap != nil, "Журнал подтверждённого ADB отсутствует; установка не запускалась")
        // A checkbox never changes the mode of a saved operation.
        let reinstall = saved != nil ? saved!.forceReinstall == true : bootstrap != nil ? bootstrap!.forceReinstall == true : forceReinstall
        let cleanup = saved != nil ? saved!.cleanComponents == true : bootstrap != nil ? bootstrap!.cleanComponents == true : cleanComponents
        try require(!cleanup || reinstall, "Некорректный режим незавершённой подготовки")
        let installFlags = reinstall ? ["--reinstall"] : []
        let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
        let serials: [String]
        do { serials = try adb.discovery().readyUSBSerials }
        catch { throw IMEIError.message("Не удалось проверить USB ADB. " + ActivityJournal.sanitize(error.localizedDescription) + " Включение ADB и восстановление не запускались.") }
        if serials.isEmpty {
            try require(saved == nil && bootstrap == nil, "Для продолжения установки нужен тот же USB ADB; новая установка не запускалась")
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
        if let bootstrap {
            try require(bootstrap.cid == proof.identity.cid && bootstrap.firmwareHash == proof.identity.firmwareHash &&
                        bootstrap.routerHash == proof.routerHash && bootstrap.adbSerial == serial && bootstrap.identity == proof.webIdentity,
                        "Подтверждённый ADB относится к другому устройству; установка не запускалась")
        }
        if let expectedIdentity { try require(proof.identity == expectedIdentity, "Устройство или прошивка изменились") }
        let profile = AccessIdentity.profile(proof, experimental: currentConnection.skipFirmwareCheck)
        if profile == "linux-arm64-access" { try require(serials.count == 1, "Для generic подготовки нужен единственный USB-модем") }
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
        if saved == nil && !reinstall {
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
                try verify()
                if var bootstrap {
                    bootstrap.phase = "complete"
                    try saveJSON(bootstrap, URL(fileURLWithPath: bootstrap.directory).appendingPathComponent("bootstrap-result.json"))
                    try fm.removeItem(at: pending)
                }
                update("SSH проверен. Готовность агента и IMEI проверяются отдельно.", 1)
                return SetupResult(connection: connection, state: nil, identity: proof.identity, firmware: proof.webIdentity?.firmware ?? "unknown", suffix: "")
            }
        }
        let startupData = try Self.agentStartup(password: agentPassword, discovery: profile == "linux-arm64-access", discoveryHost: host)
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
        let paths = try SetupRemotePaths(id: id, installRequested: saved?.installRequested ?? false, stage: saved?.remoteStage, journal: saved?.remoteJournal)
        let stage = paths.stage
        let remoteJournal = paths.journal
        let policy = AccessIdentity.policyArguments(proof, profile: profile)
        let owner = ([id] + policy).joined(separator: " ")
        var journal = saved ?? AccessSetupJournal(id: id, cid: proof.identity.cid, bootID: proof.bootID, firmwareHash: proof.identity.firmwareHash,
            routerHash: proof.routerHash, installerProfile: profile, directory: directory.path, adbSerial: serial)
        if saved == nil { journal.forceReinstall = reinstall; journal.cleanComponents = cleanup }
        let key: URL
        if journal.installRequested {
            let phase = try adb.shell(serial, "cat " + shellQuote(remoteJournal + "/state"))
            if phase == "rolled-back" && reinstall {
                try reconcileForcedRollback(adb, serial: serial, paths: paths, id: id, policy: policy, directory: directory)
                throw IMEIError.message(Self.rollbackRestoredMessage)
            }
            try require(phase == "ready" || phase == "complete", "Результат прежней установки не подтверждён. Журнал сохранён; установка автоматически не повторяется.")
            key = root.appendingPathComponent("SSH/id_ed25519")
            try require(fm.fileExists(atPath: key.path), "Ключ незавершённой установки недоступен")
        } else {
            let timeoutResource: URL?
            if profile == "linux-arm64-access" {
                let source = resources.appendingPathComponent("HostTools/zte-timeout")
                let bytes = try DeviceBackups.smallFile(source, maximum: 256 * 1024, publicResource: true)
                try require(digest(bytes) == ModemHostTools.timeoutHash, "Повреждён встроенный инструмент ограничения времени")
                timeoutResource = source
            } else { timeoutResource = nil }
            let installer = try String(contentsOf: assets.appendingPathComponent("setup-agent.sh"), encoding: .utf8)
            update("Проверяю условия установки доступа…", 0.5)
            try verify()
            let answer = try adb.shell(serial, "sh -c " + shellQuote(installer) + " -- " + (installFlags + ["--preflight"] + policy).map(shellQuote).joined(separator: " "), timeout: 60)
            try require(answer == "INSTALL_PREFLIGHT " + profile + " imei_config=unknown", "Условия установки не подтверждены")
            try verify()
            try secureDirectory(directory)
            if let bootstrap { try saveJSON(bootstrap, URL(fileURLWithPath: bootstrap.directory).appendingPathComponent("bootstrap-result.json")) }
            // Replace the old activation journal only after preflight succeeds.
            // Until this atomic save, restore/direct intents still prevent replay.
            try saveJSON(journal, pending)
            key = try createKey()
            try require(try adb.shell(serial, Self.stagePreparationCommand(stage: stage, owner: owner)) == "INSTALL_STAGE_READY", "Не подтверждён приватный каталог установки")
            let temporary = fm.temporaryDirectory.appendingPathComponent("zte-access-" + UUID().uuidString)
            try secureDirectory(temporary); defer { try? fm.removeItem(at: temporary) }
            let startup = temporary.appendingPathComponent("start-agent.sh")
            try savePrivate(startupData, startup)
            for name in ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] { try pushStaged(adb, serial: serial, source: assets.appendingPathComponent(name), stage: stage, name: name, owner: owner) }
            if let timeoutResource { try pushStaged(adb, serial: serial, source: timeoutResource, stage: stage, name: "zte-timeout", owner: owner) }
            try pushStaged(adb, serial: serial, source: key.appendingPathExtension("pub"), stage: stage, name: "id_ed25519.pub", owner: owner)
            try pushStaged(adb, serial: serial, source: startup, stage: stage, name: "start-agent.sh", owner: owner)
            try verify()
            journal.remoteStage = paths.stage; journal.remoteJournal = paths.journal
            journal.installRequested = true; journal.phase = "install-requested"; try saveJSON(journal, pending)
            _ = try adb.shell(serial, "set -eu; umask 077; set -C; printf '%s\\n' " + shellQuote(owner) + " > " + shellQuote(stage + "/.install-requested"))
            let publicData = try Data(contentsOf: key.appendingPathExtension("pub"))
            let arguments = [stage + "/setup-agent.sh"] + installFlags + [stage, proof.identity.cid, hashes["zte-agent"]!, hashes["dropbear"]!, digest(publicData)] + Array(policy.dropFirst())
            update("Устанавливаю доступ по собственному SSH-ключу…", 0.65)
            let installAnswer: String
            do { installAnswer = try adb.shell(serial, "sh " + arguments.map(shellQuote).joined(separator: " "), timeout: 100) }
            catch {
                if reinstall, (try? reconcileForcedRollback(adb, serial: serial, paths: paths, id: id, policy: policy, directory: directory)) != nil {
                    throw IMEIError.message(Self.rollbackRestoredMessage)
                }
                throw error
            }
            try require(installAnswer.split(separator: "\n").contains(Substring("INSTALL_READY " + remoteJournal)), "Установщик не подтвердил готовность; автоматического повтора нет")
            journal.phase = "ready"; journal.remoteJournal = remoteJournal; try saveJSON(journal, pending)
        }
        try verify()
        let hostPublic = try adb.shell(serial, shellQuote(paths.dropbearKey) + " -y -f /etc/dropbear/dropbear_ed25519_host_key")
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
        let answer = try ssh.run(paths.commitCommand(id: id, policy: policy), input: nil, timeout: 40)
        try require(answer.status == 0 && CommandText.decode(answer.stdout).split(separator: "\n").contains(Substring("INSTALL_COMMITTED " + remoteJournal)), "Журнал установки не завершён; он сохранён для проверки")
        try sshVerify()
        journal.phase = "complete"; journal.remoteJournal = remoteJournal
        _ = try? adb.shell(serial, "rm -f " + ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh", "id_ed25519.pub", "start-agent.sh", "zte-timeout", "legacy-agent.private.sh", ".owner", ".install-requested"].map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage))
        update("SSH и агент проверены. Операции с NV, картой и прошивкой проверяются отдельно.", 1)
        return try finishSetup(journal, id: journal.id, directory: directory, cleanComponents: journal.cleanComponents == true,
            result: SetupResult(connection: connection, state: nil, identity: proof.identity, firmware: proof.webIdentity?.firmware ?? "unknown", suffix: ""))
    }
    @discardableResult
    func verifyAccessAgent(_ ssh: RemoteTransport, proof: DiagnosticDeviceProof, profile: String, expectedHash: String, password: String, reuseExisting: Bool = false) throws -> String {
        let allowed = AccessAgentReusePolicy.allowedHashes(latest: expectedHash, proof: proof, profile: profile, reuseExisting: reuseExisting)
        let command = AccessAgentProcessProof.command(discovery: profile == "linux-arm64-access", host: host)
        func processProof() throws -> AccessAgentProcessProof {
            let result = try ssh.run(command, input: nil, timeout: 15)
            try require(result.status == 0, "Не подтверждён процесс установленного агента или режим discovery")
            return try AccessAgentProcessProof.parse(result.stdout, allowedHashes: allowed)
        }
        let before = try processProof()
        try authenticateAgent(transport: ssh, password: password)
        let response = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
        try require(response.status == 0, "Проверка SSH после входа не завершена")
        let after = try AccessIdentity.parse(response.stdout)
        try require(after.identity == proof.identity && after.routerHash == proof.routerHash && after.bootID == proof.bootID, "Во время проверки доступа изменился модем, загрузка или компоненты")
        try require(try processProof() == before, "Процесс или файл агента изменился во время проверки входа; подготовка остановлена")
        return before.diskHash
    }

}
